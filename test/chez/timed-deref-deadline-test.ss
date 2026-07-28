;; Deterministic control for timed condition waits.
;;
;; condition-wait reacquires the supplied mutex before it returns.  This gate
;; forces a producer to own that mutex across the deadline, complete late, and
;; release it only afterward.  The historical final state recheck then reports
;; success; the corrected helper preserves the timeout result.

(import (chezscheme))
(load "host/chez/run-gate-harness.ss")

(define (historical-wait-until-ready? ready? cv mu deadline)
  (let loop ()
    (cond ((ready?) #t)
          ((condition-wait cv mu deadline) (loop))
          (else (ready?))))) ; rejected control: late state erases timeout

(define (await-box b mu cv)
  (with-mutex mu
    (let loop ()
      (unless (unbox b)
        (condition-wait cv mu)
        (loop)))))

(define (publish-box! b mu cv value)
  (with-mutex mu
    (set-box! b value)
    (condition-broadcast cv)))

;; The worker signals entered while it owns mu, then calls waiter.  Once the
;; controller observes entered, acquiring mu proves the worker has reached
;; condition-wait and released it.  The controller retains mu past the absolute
;; deadline, publishes readiness, and only then lets the waiter reacquire.
(define (forced-completion waiter timeout-ms hold-ms)
  (let ((mu (make-mutex))
        (cv (make-condition))
        (ready (box #f))
        (entered-mu (make-mutex))
        (entered-cv (make-condition))
        (entered (box #f))
        (done-mu (make-mutex))
        (done-cv (make-condition))
        (done (box #f))
        (result (box 'unset)))
    (fork-thread
      (lambda ()
        (with-mutex mu
          (publish-box! entered entered-mu entered-cv #t)
          (set-box! result
            (waiter (lambda () (unbox ready))
                    cv
                    mu
                    (ms->deadline timeout-ms))))
        (publish-box! done done-mu done-cv #t)))
    (await-box entered entered-mu entered-cv)
    (with-mutex mu
      (when (> hold-ms 0) (sleep (ms->duration hold-ms)))
      (set-box! ready #t)
      (condition-broadcast cv))
    (await-box done done-mu done-cv)
    (unbox result)))

(gate-check "historical final recheck admits a post-deadline completion"
            (forced-completion historical-wait-until-ready? 100 180)
            #t)
(gate-check "corrected helper preserves timeout across mutex reacquisition"
            (forced-completion jolt-wait-until-ready? 100 180)
            #f)
(gate-check "corrected helper admits a completion signaled before the deadline"
            (forced-completion jolt-wait-until-ready? 500 0)
            #t)

(let ((mu (make-mutex)) (cv (make-condition)))
  (gate-check "corrected helper admits state ready at entry"
              (with-mutex mu
                (jolt-wait-until-ready? (lambda () #t) cv mu (ms->deadline 100)))
              #t))

(gate-summary "timed-deref-deadline")

