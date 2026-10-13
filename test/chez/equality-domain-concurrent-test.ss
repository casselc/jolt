;; Cold weak-table access/publication is synchronized; warm snapshots stay
;; lock-free and callbacks stay outside counted locks. Deterministic witnesses
;; plus bounded native-thread registration/lookup stress, not a formal proof.
(import (chezscheme))
(load "host/chez/rt.ss")
(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
;; Fail safely against the old mechanism before executing its unsafe race.
(ok "synchronized metadata seams exist"
    (and (top-level-bound? 'eq-domain-metadata-ref)
         (top-level-bound? 'eq-domain-metadata-mark!)))
(unless (= fails 0) (exit 1))
(define original-ref eq-domain-metadata-ref)
(define original-mark eq-domain-metadata-mark!)
(define reads 0)
(define writes 0)
(define locked? #t)
(set! eq-domain-metadata-ref
  (lambda (arm) (set! reads (+ reads 1))
    (set! locked? (and locked? (> (jolt-locks-held) 0)))
    (original-ref arm)))
(set! eq-domain-metadata-mark!
  (lambda (arm) (set! writes (+ writes 1))
    (set! locked? (and locked? (> (jolt-locks-held) 0)))
    (original-mark arm)))
(define callbacks-unlocked? #t)
(define (unclaimed a b)
  (set! callbacks-unlocked? (and callbacks-unlocked? (= (jolt-locks-held) 0)))
  #f)
(register-value-eq-arm! unclaimed (lambda (a b) #f))
(define captured jolt-eq-arms)
(define cold (eq-scalar-arms captured))
(ok "actual metadata read and write hold counted lock"
    (and (> reads 0) (> writes 0) locked?))
(define previous-reads reads)
;; Lock-depth edges are syntax on 0.8.19+, not replaceable procedures. Poison
;; the actual cold-path mutex instead: any attempted acquire raises, whereas a
;; genuinely warm lookup does not consult it. Restore before registration/stress.
(define original-metadata-mu eq-domain-metadata-mu)
(define original-lock-depth (jolt-locks-held))
(define warm-answer #f)
(define warm-threw? #f)
(define cold-rejected? #f)
(dynamic-wind
  (lambda () (set! eq-domain-metadata-mu #f))
  (lambda ()
    (guard (e (#t (set! warm-threw? #t)))
      (set! warm-answer (eq-scalar-arms captured)))
    ;; Positive control: changing only registry identity forces the cold path,
    ;; which must attempt this same poisoned mutex and fail.
    (guard (e (#t (set! cold-rejected? #t)))
      (eq-scalar-arms (cons (cons unclaimed (lambda (a b) #f)) captured))))
  (lambda ()
    (set! eq-domain-metadata-mu original-metadata-mu)
    ;; The deliberately invalid mutex raises in the acquire before-thunk,
    ;; before a lock exists or its after-thunk is installed. Reset only this
    ;; injected witness's depth so later real-lock assertions remain meaningful.
    (set-virtual-register! jolt-vreg-locks original-lock-depth)))
(ok "warm lookup returns identical immutable snapshot" (eq? cold warm-answer))
(ok "warm lookup does not acquire metadata mutex" (not warm-threw?))
(ok "cold control rejects poisoned metadata mutex" cold-rejected?)
(ok "warm lookup performs no table reads" (= reads previous-reads))
(define original-snapshot eq-scalar-arm-snapshot)
(register-eq-arm! (lambda (a b)
                   (set! callbacks-unlocked? (and callbacks-unlocked? (= (jolt-locks-held) 0)))
                   (and (procedure? a) (string? b)))
                 (lambda (a b)
                   (set! callbacks-unlocked? (and callbacks-unlocked? (= (jolt-locks-held) 0)))
                   #t))
(ok "legacy claiming handler remains live" (jolt=2 car "legacy"))
(ok "registration probes and equality callbacks run unlocked" callbacks-unlocked?)
(ok "registration creates a fresh complete snapshot" (not (eq? original-snapshot eq-scalar-arm-snapshot)))
;; Direct trusted registry restore remains identity-sensitive, as before.
(set! jolt-eq-arms captured)
(ok "restored registry rebuilds matching snapshot" (equal? cold (eq-scalar-arms captured)))
(set! eq-domain-metadata-ref original-ref)
(set! eq-domain-metadata-mark! original-mark)

(define mu (make-mutex))
(define done 0)
(define errors 0)
(define (finish thunk)
  (guard (e (#t (with-mutex mu (set! errors (+ errors 1))))) (thunk))
  (with-mutex mu (set! done (+ done 1))))
(define before (length jolt-eq-arms))
;; Every registration predicate is false: no callbacks can redefine comparison
;; answers, and public concurrency must preserve all 200 admitted arms.
(do ((t 0 (+ t 1))) ((= t 2))
  (fork-thread (lambda () (finish (lambda ()
    (do ((i 0 (+ i 1))) ((= i 100))
      (register-value-eq-arm! (lambda (a b) #f) (lambda (a b) #f))))))))
(do ((t 0 (+ t 1))) ((= t 2))
  (fork-thread (lambda () (finish (lambda ()
    (do ((i 0 (+ i 1))) ((= i 1000))
      (unless (and (not (jolt=2 car "child")) (not (jolt=2 "child" car)))
        (error 'domain-race "changed equality"))))))))
(define start (current-time 'time-monotonic))
(let await ()
  (unless (with-mutex mu (= done 4))
    (let ((elapsed (time-difference (current-time 'time-monotonic) start)))
      (when (> (time-second elapsed) 20) (error 'domain-race "deadline")))
    (sleep (make-time 'time-duration 1000000 0))
    (await)))
(ok "bounded concurrent registrations/readers complete" (= errors 0))
(ok "concurrent publications retain every admitted registration"
    (= (+ before 200) (length jolt-eq-arms)))
(ok "metadata remains weak rather than retaining retired arms"
    (hashtable-weak? eq-value-domain-arms))
(printf "equality-domain-concurrent: ~a/~a assertions passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
