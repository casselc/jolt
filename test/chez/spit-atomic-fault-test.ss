;; Ownership/failure and permission contract for jolt-spit's atomic replacement.
;; Every injected failure happens after O_EXCL made the temp visible. Assertions
;; run in-process, before exit can hide descriptor leaks.
(import (chezscheme))
(load "host/chez/run-gate-harness.ss")
(load "host/chez/loader.ss")

(define args (cdr (command-line)))
(unless (= (length args) 1)
  (error 'spit-atomic-fault-test "expected ROOT" args))
(define root (car args))
(define failures '())
(define (check label pred)
  (unless pred (set! failures (cons label failures))))
(define (read-text path)
  (let ((p (open-file-input-port path)))
    (let ((s (utf8->string (get-bytevector-all p)))) (close-port p) s)))
(define (write-text path text)
  (let ((p (open-file-output-port path (file-options no-fail))))
    (put-bytevector p (string->utf8 text)) (close-port p)))

(define original-temp-path spit-temp-path)
(define original-open-port spit-open-output-port)
(define original-write spit-write-output!)
(define original-flush spit-flush-output!)
(define original-close-port spit-close-output!)
(define original-close-fd spit-close-fd!)
(define original-publish spit-publish-temp-result)
(define current-temp "")
(set! spit-temp-path
  (lambda (target stamp n) current-temp))

(define c-fcntl
  (and (not (eq? (sa-os-family) 'windows))
       (jolt-foreign-proc-safe "fcntl" '(int int) 'int)))
(define (fd-closed? fd)
  ;; F_GETFD on a descriptor closed by cleanup returns -1/EBADF. No pathname
  ;; operation is allowed between cleanup and this check, so reuse cannot mask it.
  (if c-fcntl (= -1 (c-fcntl fd 1)) #t))

(define (restore-seams!)
  (set! spit-open-output-port original-open-port)
  (set! spit-write-output! original-write)
  (set! spit-flush-output! original-flush)
  (set! spit-close-output! original-close-port)
  (set! spit-close-fd! original-close-fd)
  (set! spit-publish-temp-result original-publish))

(define (prepare! label)
  (set! current-temp (string-append root "/" label ".tmp"))
  (guard (_ (#t #f)) (delete-file current-temp))
  (let ((target (string-append root "/" label ".txt")))
    (write-text target "sentinel")
    target))

(define (post-failure! label target raised? observed-temp? closed?)
  (check (string-append label ": exception propagated") raised?)
  (check (string-append label ": failure occurred while temp existed") observed-temp?)
  (check (string-append label ": owner closed before process exit") closed?)
  (check (string-append label ": temp removed") (not (file-exists? current-temp)))
  (check (string-append label ": target unchanged")
         (string=? (read-text target) "sentinel")))

;; Port acquisition failure: ownership has not transferred, so raw fd cleanup
;; happens exactly once and is proven closed immediately with F_GETFD.
(let* ((label "port-acquire") (target (prepare! label))
       (saved-fd #f) (close-count 0) (observed? #f) (raised? #f))
  (dynamic-wind
    (lambda ()
      (set! spit-open-output-port
        (lambda (fd)
          (set! saved-fd fd) (set! observed? (file-exists? current-temp))
          (error 'injected "port acquisition")))
      (set! spit-close-fd!
        (lambda (fd) (set! close-count (+ close-count 1)) (original-close-fd fd))))
    (lambda () (guard (_ (#t (set! raised? #t))) (jolt-spit target "new")))
    restore-seams!)
  (post-failure! label target raised? observed?
                 (and (= close-count 1) saved-fd (fd-closed? saved-fd))))

(define (run-port-fault label install!)
  (let ((target (prepare! label)) (saved-port #f) (close-count 0)
        (observed? #f) (raised? #f))
    (dynamic-wind
      (lambda ()
        (set! spit-open-output-port
          (lambda (fd)
            (let ((p (original-open-port fd))) (set! saved-port p) p)))
        (set! spit-close-output!
          (lambda (p) (set! close-count (+ close-count 1))
            (original-close-port p)))
        (install! (lambda () (set! observed? (file-exists? current-temp)))
                  (lambda () (set! close-count (+ close-count 1)))))
      (lambda () (guard (_ (#t (set! raised? #t))) (jolt-spit target "new")))
      restore-seams!)
    (post-failure! label target raised? observed?
                   (and (= close-count 1) saved-port (port-closed? saved-port)))))

(run-port-fault "write"
  (lambda (observe! note-close!)
    (set! spit-write-output!
      (lambda (p text) (observe!) (error 'injected "write")))))
(run-port-fault "flush"
  (lambda (observe! note-close!)
    (set! spit-flush-output!
      (lambda (p) (observe!) (error 'injected "flush")))))
(run-port-fault "close"
  (lambda (observe! note-close!)
    (set! spit-close-output!
      (lambda (p)
        (observe!) (note-close!)
        ;; Model a close that released its descriptor and then reported failure.
        ;; The ownership state must prevent dynamic-wind cleanup closing it again.
        (original-close-port p)
        (error 'injected "close")))))

;; Publish sees a closed port and a live temp; native failure must remove only
;; the temp and preserve the old destination.
(let* ((label "publish") (target (prepare! label))
       (saved-port #f) (observed? #f) (closed-at-publish? #f) (raised? #f))
  (dynamic-wind
    (lambda ()
      (set! spit-open-output-port
        (lambda (fd) (let ((p (original-open-port fd))) (set! saved-port p) p)))
      (set! spit-publish-temp-result
        (lambda (tmp dst)
          (set! observed? (file-exists? tmp))
          (set! closed-at-publish? (and saved-port (port-closed? saved-port)))
          (values 'error 13))))
    (lambda () (guard (_ (#t (set! raised? #t))) (jolt-spit target "new")))
    restore-seams!)
  (post-failure! label target raised? observed? closed-at-publish?))

;; A continuation escape exercises the dynamic-wind path independently of a
;; raised condition.
(let* ((label "nonlocal") (target (prepare! label))
       (saved-port #f) (observed? #f) (escaped? #f))
  (dynamic-wind
    (lambda ()
      (set! spit-open-output-port
        (lambda (fd) (let ((p (original-open-port fd))) (set! saved-port p) p))))
    (lambda ()
      (when
        (eq? (call/cc
               (lambda (escape)
                 (set! spit-write-output!
                   (lambda (p text)
                     (set! observed? (file-exists? current-temp))
                     (escape 'escaped)))
                 (jolt-spit target "new")))
             'escaped)
        (set! escaped? #t)))
    restore-seams!)
  (post-failure! label target escaped? observed?
                 (and saved-port (port-closed? saved-port))))

;; New-file permissions match FileOutputStream/spit: 0666 filtered by umask.
;; Replacement preserves a pre-existing target mode on supported POSIX ABIs.
(when (and c-umask fs-c-chmod fs-stat-layout-known?)
  (let ((old-umask (c-umask #o027))
        (new-target (string-append root "/new-mode.txt")))
    (dynamic-wind
      (lambda () #f)
      (lambda () (jolt-spit new-target "new"))
      (lambda () (c-umask old-umask)))
    (check "new target respects umask"
           (= #o640 (bitwise-and (fs-stat-mode new-target) #o777))))
  (let ((target (string-append root "/replace-mode.txt")))
    (write-text target "old")
    (fs-c-chmod target #o604)
    (let ((old-umask (c-umask #o077)))
      (dynamic-wind
        (lambda () #f)
        (lambda () (jolt-spit target "new"))
        (lambda () (c-umask old-umask))))
    (check "replacement preserves existing target mode"
           (= #o604 (bitwise-and (fs-stat-mode target) #o777)))))

(set! spit-temp-path original-temp-path)
(if (null? failures)
    (begin (display "SPIT-ATOMIC-FAULT-TEST OK\n") (exit 0))
    (begin
      (for-each (lambda (f) (printf "FAIL: ~a\n" f)) (reverse failures))
      (exit 1)))
