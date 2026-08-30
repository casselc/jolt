;; Independent-process worker for spit-atomic-test.sh.  The candidate seam is
;; fixed deliberately so both runtimes first ask O_EXCL for the same sibling.
;; The rename seam is only a barrier: all allocation, writing, cleanup, and
;; publication remain the production jolt-spit implementation.
(import (chezscheme))
(load "host/chez/run-gate-harness.ss")
(load "host/chez/loader.ss")

(define args (cdr (command-line)))
(unless (= (length args) 3)
  (error 'spit-atomic-worker "expected ROLE ROOT MODE" args))
(define role (list-ref args 0))
(define root (list-ref args 1))
(define mode (list-ref args 2))
(define target (string-append root "/target.txt"))
(define ready (string-append root "/ready-" role))
(define allow (string-append root "/allow-" role))
(define attempts (string-append root "/attempts-" role))

(define (write-marker path text mode)
  (let ((p (open-output-file path mode)))
    (put-string p text)
    (newline p)
    (close-port p)))

(define (wait-for path)
  (let loop ()
    (unless (file-exists? path)
      (sleep (make-time 'time-duration 1000000 0))
      (loop))))

(set! spit-tmp-counter 0)
(set! spit-temp-path
  (lambda (target stamp n)
    (string-append target ".spit-tmp-fixed-" (number->string n))))

(define original-open fs-open-file-exclusive-result)
(set! fs-open-file-exclusive-result
  (lambda (path mode-bits)
    (if (string=? mode "create-error")
        (begin
          (write-marker attempts (string-append path " error 13") 'append)
          (values 'error 13 #f))
        (let-values (((status native-error fd)
                      (original-open path mode-bits)))
          (write-marker attempts
                        (string-append path " " (symbol->string status) " "
                                       (number->string native-error))
                        'append)
          (values status native-error fd)))))

(define original-publish spit-publish-temp-result)
(set! spit-publish-temp-result
  (lambda (from to)
    (write-marker ready from 'replace)
    (wait-for allow)
    (original-publish from to)))

(guard (e (#t
           (printf "RESULT ~a ERROR ~a\n" role
                   (if (condition? e) (condition-message e) e))
           (exit 23)))
  (jolt-spit target (make-string 1048576 (string-ref role 0)))
  (printf "RESULT ~a OK\n" role)
  (exit 0))
