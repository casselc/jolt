;; Pause the actual registration body immediately after its epoch bump. This
;; exposes a stale cache stamped with the NEW epoch, not merely an overlapping
;; call returning an old method. No production timing hooks are introduced.
(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0)
(define failures 0)
(define (ok name condition)
  (set! total (+ total 1))
  (unless condition (set! failures (+ failures 1)) (printf "FAIL: ~a\n" name)))
(define (now)
  (let ((t (current-time 'time-monotonic)))
    (+ (time-second t) (/ (time-nanosecond t) 1000000000.0))))
(define (await predicate)
  (let ((deadline (+ (now) 10)))
    (let loop ()
      (cond ((predicate) #t)
            ((> (now) deadline) (error 'registration-test "coordination deadline"))
            (else (sleep (make-time 'time-duration 1000000 0)) (loop))))))
(define state-mu (make-mutex))
(define paused? #f)
(define release? #f)
(define writer-done? #f)
(define reader-done? #f)
(define reader-started? #f)
(define worker-errors '())
(define selected #f)
(define reader-id #f)
(define reader-probes 0)
(define reader-lookup-locked? #t)
(define epoch-at-pause #f)
(define proto "registration-test/Protocol")
(define method "read")
(define original (lambda (obj) 'original))
(define replacement (lambda (obj) 'replacement))
(define (state predicate) (with-mutex state-mu (predicate)))
(define (registration-test-pause!)
  (with-mutex state-mu
    (set! epoch-at-pause jolt-proto-epoch)
    (set! paused? #t))
  (await (lambda () (state (lambda () release?)))))

;; Read the production definition and insert exactly one test-only checkpoint
;; into its real critical section. Fail closed if that source shape changes.
(define registration-form
  (call-with-input-file "host/chez/protocols.ss"
    (lambda (port)
      (let loop ()
        (let ((form (read port)))
          (cond ((eof-object? form) (error 'registration-test "registration definition missing"))
                ((and (pair? form) (eq? 'define (car form))
                      (pair? (cadr form)) (eq? 'register-protocol-method (caadr form))) form)
                (else (loop))))))))
(define critical-section (caddr registration-form))
(unless (and (equal? (car critical-section) 'jolt-with-mutex)
             (equal? (cadr critical-section) 'rec-tbl-mu)
             (equal? (caddr critical-section)
               '(set! jolt-proto-epoch (fx+ jolt-proto-epoch 1))))
  (error 'registration-test "production epoch publication shape changed"))
(define checkpoint-definition
  (append (list (car registration-form) (cadr registration-form)
            (append (list (car critical-section) (cadr critical-section)
                          (caddr critical-section) '(registration-test-pause!))
                    (cdddr critical-section)))
          (cdddr registration-form)))

(register-protocol-method "java.lang.String" proto method original)
;; Warm the method-key interner before the writer owns rec-tbl-mu, so an
;; unrelated cold interning lock cannot hide the memo publication defect.
(ok "warm call selects original" (eq? original (protocol-resolve proto method "receiver")))
(define old-epoch jolt-proto-epoch)
(eval checkpoint-definition)
(fork-thread
  (lambda ()
    (guard (e (#t (with-mutex state-mu (set! worker-errors (cons e worker-errors)))))
      (register-protocol-method "java.lang.String" proto method replacement))
    (with-mutex state-mu (set! writer-done? #t))))
(await (lambda () (state (lambda () paused?))))
(ok "writer paused after exactly one epoch bump" (= epoch-at-pause (+ old-epoch 1)))
(ok "writer has not yet published the new method"
    (eq? original (find-protocol-method "java.lang.String" proto method)))
(define original-lookup find-protocol-method)
(set! find-protocol-method
  (lambda (tag pn mn)
    (when (and reader-id (= reader-id (get-thread-id)) (string=? pn proto))
      (set! reader-probes (+ reader-probes 1))
      (set! reader-lookup-locked? (and reader-lookup-locked? (> (jolt-locks-held) 0))))
    (original-lookup tag pn mn)))
(fork-thread
  (lambda ()
    (guard (e (#t (with-mutex state-mu (set! worker-errors (cons e worker-errors)))))
      (with-mutex state-mu
        (set! reader-id (get-thread-id))
        (set! reader-started? #t))
      (set! selected (protocol-resolve proto method "receiver")))
    (with-mutex state-mu (set! reader-done? #t))))
(await (lambda () (state (lambda () reader-started?))))
;; On the unmodified resolver a complete miss/fill can occur while the writer
;; is paused. On the repaired resolver, the registry mutex must be owned by
;; its lookup, so release immediately rather than waiting for a blocked reader.
(when (equal? (getenv "PROTOCOL_RESOLVE_CONTROL") "unlocked")
  (await (lambda () (state (lambda () reader-done?)))))
(with-mutex state-mu (set! release? #t))
(await (lambda () (state (lambda () (and writer-done? reader-done?)))))
(ok "both workers completed without exception" (null? worker-errors))
(ok "reader really exercised a cold registry lookup" (> reader-probes 0))
(ok "reader captured method and epoch inside the registration mutex" reader-lookup-locked?)
(ok "overlapping selection is a real registered implementation"
    (or (eq? selected original) (eq? selected replacement)))
(ok "registration really published the replacement"
    (eq? replacement (find-protocol-method "java.lang.String" proto method)))
(ok "completed registration invalidates every subsequent memo hit"
    (let loop ((n 0))
      (or (= n 10)
          (and (eq? replacement (protocol-resolve proto method "receiver"))
               (loop (+ n 1))))))
(printf "protocol-resolve-registration: ~a/~a checks passed\n" (- total failures) total)
(exit (if (zero? failures) 0 1))
