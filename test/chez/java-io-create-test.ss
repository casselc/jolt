;; java.io.File creation parity and race regression gate. The first five
;; booleans/length are the JVM oracle for the same operation sequence:
;; [true false true false 0]. Collision and injected-error cases give the old
;; check-then-truncate/check-then-mkdir implementations deterministic teeth.
(import (chezscheme))
(load "host/chez/run-gate-harness.ss")
(load "host/chez/loader.ss")

(define failures '())
(define (check label pred)
  (unless pred (set! failures (cons label failures))))
(define (read-text path)
  (let ((p (open-file-input-port path)))
    (let ((s (utf8->string (get-bytevector-all p))))
      (close-port p)
      s)))
(define (write-text path text)
  (let ((p (open-file-output-port path (file-options no-fail))))
    (put-bytevector p (string->utf8 text))
    (close-port p)))
(define (file-call path method)
  (car (jfile-method (make-jfile path) method '())))

(define root
  (npath-string-of (nio-files-create-temp (list "jolt-java-io-create-test-") #t)))
(define deep (string-append root "/a/b"))
(define new-file (string-append root "/new-file"))
(define oracle
  (list (file-call deep "mkdirs")
        (file-call deep "mkdirs")
        (file-call new-file "createNewFile")
        (file-call new-file "createNewFile")
        (file-call new-file "length")))
(check "public File creation sequence matches JVM oracle"
       (equal? oracle '(#t #f #t #f 0)))

;; createNewFile is exclusive: a second call cannot truncate the winner.
(write-text new-file "winner")
(check "createNewFile reports an existing winner" (not (file-call new-file "createNewFile")))
(check "createNewFile preserves winner content" (string=? (read-text new-file) "winner"))

;; Force createTempFile's first candidate to an existing sentinel. It must retry
;; only the collision and leave the winner untouched.
(define collision (string-append root "/temp-collision.tmp"))
(write-text collision "temp-winner")
(define original-temp-path file-temp-path)
(define temp-attempts 0)
(define temp-result #f)
(dynamic-wind
  (lambda ()
    (set! file-temp-path
      (lambda (dir prefix suffix n)
        (set! temp-attempts (+ temp-attempts 1))
        (if (= temp-attempts 1)
            collision
            (original-temp-path dir prefix suffix n)))))
  (lambda ()
    (set! temp-result
      (file-create-temp "abc" ".tmp" (make-jfile root))))
  (lambda () (set! file-temp-path original-temp-path)))
(check "createTempFile retries exactly one forced collision" (= temp-attempts 2))
(check "createTempFile does not return the colliding name"
       (not (string=? (jfile-path temp-result) collision)))
(check "createTempFile preserves the race winner"
       (string=? (read-text collision) "temp-winner"))

;; Non-collision failures are neither retried nor flattened into success.
(define original-open fs-c-open-exclusive)
(define denied-attempts 0)
(define denied-raised? #f)
(dynamic-wind
  (lambda ()
    (set! fs-c-open-exclusive (lambda _ (values -1 13)))
    (set! file-temp-path
      (lambda _
        (set! denied-attempts (+ denied-attempts 1))
        (string-append root "/denied-temp"))))
  (lambda ()
    (guard (e (#t (set! denied-raised? #t)))
      (file-create-temp "abc" ".tmp" (make-jfile root))))
  (lambda ()
    (set! fs-c-open-exclusive original-open)
    (set! file-temp-path original-temp-path)))
(check "createTempFile propagates a non-collision failure" denied-raised?)
(check "createTempFile does not retry a non-collision failure" (= denied-attempts 1))

(define original-mkdir fs-c-mkdir)
(define mkdir-calls 0)
(dynamic-wind
  (lambda ()
    (set! fs-c-mkdir
      (lambda _ (set! mkdir-calls (+ mkdir-calls 1)) (values -1 13))))
  (lambda ()
    (check "mkdirs returns false for a permission-style failure"
           (not (mkdirs! (string-append root "/denied/child")))))
  (lambda () (set! fs-c-mkdir original-mkdir)))
(check "mkdirs does not retry a non-ENOENT failure" (= mkdir-calls 1))

(aot-delete-tree root)
(if (null? failures)
    (begin (display "JAVA-IO-CREATE-TEST OK\n") (exit 0))
    (begin
      (for-each (lambda (f) (printf "FAIL: ~a\n" f)) (reverse failures))
      (exit 1)))
