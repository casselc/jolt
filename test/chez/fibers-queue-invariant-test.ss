;; Bounded diagnostics for the ready-queue/state product, plus the no-network
;; topology observed in the Samizdat integration: an OS request thread starts a
;; run fiber, that fiber starts a child fiber, and the child parks for a blocking
;; worker hand-off. Run with JOLT_FIBER_TRACE_LIMIT set so the ring is exercised.

(import (chezscheme))
(load "host/chez/locks.ss")
(define (rdr-default-modes!) (void))
(load "host/chez/fibers.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n" name)))

(define (mono-nanos)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000000000 (time-second t)) (time-nanosecond t))))
(define (now-secs) (/ (exact->inexact (mono-nanos)) 1000000000.0))
(define (wait-until pred secs)
  (let ((deadline (+ (now-secs) secs)))
    (let loop ()
      (cond ((pred) #t)
            ((> (now-secs) deadline) #f)
            (else (sleep (make-time 'time-duration 1000000 0)) (loop))))))
(define (string-contains-substr? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1)))))))

(jolt-fiber-carrier-count-set! 1)
(jolt-fiber-preempt-ticks-set! 100)

(printf "== deterministic invalid ready-queue transition ==\n")
(define bad-f (sa-fiber-spawn (lambda () 'still-runs)))
(define diag-port (open-output-string))
(define caught
  (parameterize ((current-error-port diag-port))
    (guard (e (#t e))
      ;; This is the precise impossible product seen at dispatch in the retained
      ;; integration logs: a queued fiber being changed to parked. The transition
      ;; seam must fail at this causal edge, before corrupting the queue.
      (jolt-fiber-transition! bad-f 'regression-forced-park 'parked)
      #f)))
(define diag-output (get-output-string diag-port))
(ok "queued -> parked is rejected at the transition" caught)
(ok "the report names only scheduler coordinates"
    (and (string-contains-substr? diag-output "where=regression-forced-park")
         (string-contains-substr? diag-output "carrier=0 fiber=1")
         (string-contains-substr? diag-output "queued=#t")))
(ok "the report does not retain the fiber body's value"
    (not (string-contains-substr? diag-output "still-runs")))
(ok "the rejected transition leaves the fiber ready"
    (eq? 'ready (jolt-fiber-state bad-f)))
(ok "the rejected transition leaves its one valid queue membership"
    (jolt-fiber-queued? bad-f))
(ok "the diagnostic ring follows its opt-in bound"
    (let ((n (length (jolt-fiber-trace-snapshot (jolt-fiber-carrier bad-f)))))
      (if jolt-fiber-trace-limit
          (and (> n 0) (<= n jolt-fiber-trace-limit))
          (= n 0))))

;; Exercise the same rejection from inside sa-fiber-resume's raw carrier lock.
;; The impossible parked+queued product stands in for the observed corruption;
;; resume changes it to ready, then its attempted duplicate enqueue is rejected.
;; Reporting must happen only after the raw lock is released.
(define locked-f (sa-fiber-spawn (lambda () 'locked-body-value)))
(jolt-fiber-state-set! locked-f 'parked)
(define locked-diag-port (open-output-string))
(define locked-caught
  (parameterize ((current-error-port locked-diag-port))
    (guard (e (#t e))
      (sa-fiber-resume locked-f)
      #f)))
(ok "an in-lock duplicate resume is rejected" locked-caught)
(define carrier-mu (jolt-carrier-mu (jolt-fiber-carrier locked-f)))
(define carrier-lock-live? #f)
(define carrier-lock-probe
  (fork-thread
    (lambda ()
      (set! carrier-lock-live? (jolt-lock! carrier-mu #f))
      (when carrier-lock-live? (jolt-unlock! carrier-mu)))))
(thread-join carrier-lock-probe)
(ok "the rejected in-lock transition releases the carrier mutex" carrier-lock-live?)
(ok "the in-lock report does not retain the fiber body's value"
    (not (string-contains-substr? (get-output-string locked-diag-port)
                                  "locked-body-value")))
(sa-fiber-run-all)
(ok "the diagnostic did not corrupt the queue"
    (and (eq? 'done (jolt-fiber-state bad-f))
         (not (jolt-fiber-queued? bad-f))
         (eq? 'done (jolt-fiber-state locked-f))
         (not (jolt-fiber-queued? locked-f))))

(printf "\n== wake during committed-park handoff ==\n")
(define handoff-observed (box #f))
(define handoff-completed (box #f))
(define handoff-f
  (sa-fiber-spawn
    (lambda ()
      (let ((f (jolt-current-fiber)))
        ;; Force the causal integrated window: the wait has committed to parked,
        ;; then an OS waker resumes it before it hands control to the scheduler.
        (jolt-fiber-park-commit! f 'regression-handoff-park)
        (thread-join (fork-thread (lambda () (sa-fiber-resume f))))
        (set-box! handoff-observed
                  (vector (jolt-fiber-state f) (jolt-fiber-queued? f)
                          (jolt-fiber-park-handoff? f)
                          (jolt-fiber-wake-pending? f)))
        (jolt-fiber-to-scheduler! f)
        (set-box! handoff-completed #t)
        'handoff-done))))
(sa-fiber-run-all)
(ok "a pre-switch wake stays pending and off the ready queue"
    (equal? (vector 'parked #f #t #t) (unbox handoff-observed)))
(ok "the scheduler publishes the pending wake exactly once"
    (and (unbox handoff-completed)
         (eq? 'done (jolt-fiber-state handoff-f))
         (not (jolt-fiber-queued? handoff-f))
         (not (jolt-fiber-park-handoff? handoff-f))
         (not (jolt-fiber-wake-pending? handoff-f))))
(define terminal-handoff-f
  (sa-fiber-spawn
    (lambda ()
      (let ((f (jolt-current-fiber)))
        (jolt-fiber-park-commit! f 'regression-terminal-handoff-park)
        (thread-join (fork-thread (lambda () (sa-fiber-resume f))))
        ;; Model cleanup winning before the carrier owns the parked fiber again.
        (jolt-fiber-done! f 'terminal-before-switch)))))
(sa-fiber-run-all)
(ok "terminal cleanup drops a pending wake without queue publication"
    (and (eq? 'done (jolt-fiber-state terminal-handoff-f))
         (not (jolt-fiber-queued? terminal-handoff-f))
         (not (jolt-fiber-park-handoff? terminal-handoff-f))
         (not (jolt-fiber-wake-pending? terminal-handoff-f))))

(printf "\n== condition-variable park seam handoff ==\n")
;; Route through jolt-cv-wait itself, but interpose only in this test after its
;; real condition-park commit.  The OS thread's resume is joined before the
;; helper returns, which deterministically forces the commit-to-switch window
;; that an ordinary condition waker reaches nondeterministically after taking
;; the waitable mutex.  The decision flag stands in for the state that such a
;; waker changes under that mutex; thread-join publishes it before the retake.
(define real-jolt-fiber-park-commit! jolt-fiber-park-commit!)
(define cv-seam-ready? (box #f))
(define cv-seam-result (box #f))
(set! jolt-fiber-park-commit!
  (lambda (f kind)
    (real-jolt-fiber-park-commit! f kind)
    (when (eq? kind 'condition-park)
      (thread-join
        (fork-thread
          (lambda ()
            (set-box! cv-seam-ready? #t)
            (sa-fiber-resume f)))))))
(define cv-seam-f
  (sa-fiber-spawn
    (lambda ()
      (let ((mu (make-mutex)) (cv (make-condition)))
        (set-box! cv-seam-result
                  (jolt-cv-wait
                    mu cv #f
                    (lambda (timed-out?)
                      (if (unbox cv-seam-ready?) 'woke jolt-cv-again))))
        'condition-seam-done))))
(sa-fiber-run-all)
(set! jolt-fiber-park-commit! real-jolt-fiber-park-commit!)
(ok "the real condition-variable seam survives a pre-switch OS-thread wake"
    (and (eq? 'woke (unbox cv-seam-result))
         (eq? 'done (jolt-fiber-state cv-seam-f))
         (not (jolt-fiber-queued? cv-seam-f))
         (not (jolt-fiber-park-handoff? cv-seam-f))
         (not (jolt-fiber-wake-pending? cv-seam-f))))

;; A promise-shaped handoff. Completion and commit-to-park are serialized by
;; one mutex, matching the contract used by promise deref and Ebb's first-park
;; gates without depending on either library in this host-level regression.
(define-record-type handoff
  (fields mu (mutable done?) (mutable waiter)))
(define (new-handoff) (make-handoff (make-mutex) #f #f))
(define (handoff-signal! h)
  (jolt-lock! (handoff-mu h))
  (handoff-done?-set! h #t)
  (let ((f (handoff-waiter h)))
    (handoff-waiter-set! h #f)
    (jolt-unlock! (handoff-mu h))
    (when f (sa-fiber-resume f))))
(define (handoff-await! h kind)
  (let ((f (jolt-current-fiber)))
    (unless f (error 'handoff-await! "fiber required"))
    (jolt-lock! (handoff-mu h))
    (if (handoff-done? h)
        (jolt-unlock! (handoff-mu h))
        (begin
          (handoff-waiter-set! h f)
          (jolt-fiber-transition! f kind 'parked)
          (jolt-unlock! (handoff-mu h))
          (jolt-fiber-to-scheduler! f)))))

(printf "\n== request thread -> run fiber -> child fiber -> blocking handoff ==\n")
(define rounds 300)
(define completed (box 0))
(define parents '())
(do ((i 0 (+ i 1))) ((= i rounds))
  ;; This gate's main thread is the HTTP request OS thread: it starts the run
  ;; fiber and blocks only until that fiber reports its first park.
  (let* ((request-first-park (new-handoff))
         (parent
          (sa-fiber-spawn
            (lambda ()
              (let ((child-first-park (new-handoff))
                    (child-done (new-handoff)))
                (sa-fiber-spawn
                  (lambda ()
                    (let ((blocking-result (new-handoff)))
                      (fork-thread
                        (lambda ()
                          (sleep (make-time 'time-duration 1000000 0))
                          (handoff-signal! blocking-result)))
                      ;; Ebb spawn-process releases its first-park gate just
                      ;; before waiting on the via result.
                      (handoff-signal! child-first-park)
                      (handoff-await! blocking-result 'blocking-handoff-park)
                      (handoff-signal! child-done)
                      'child-done)))
                ;; The request gets its durable run handle while the run fiber
                ;; is waiting for the child to reach its first park.
                (handoff-signal! request-first-park)
                (handoff-await! child-first-park 'child-start-park)
                (handoff-await! child-done 'child-result-park)
                (set-box! completed (+ 1 (unbox completed)))
                'run-done)))))
    (set! parents (cons parent parents))
    (jolt-fiber-ensure-carrier!)
    (unless (wait-until (lambda () (handoff-done? request-first-park)) 2.0)
      (set! fails (+ fails 1)))))

(ok "every run/child hierarchy completed without a stranded fiber"
    (wait-until (lambda () (= rounds (unbox completed))) 15.0))
(ok "every parent reached a terminal state"
    (andmap (lambda (f) (memq (jolt-fiber-state f) '(done dead))) parents))
(ok "the trace stayed within its configured bound"
    (let ((c (and (pair? parents) (jolt-fiber-carrier (car parents)))))
      (and c
           (let ((n (length (jolt-fiber-trace-snapshot c))))
             (if jolt-fiber-trace-limit
                 (<= n jolt-fiber-trace-limit)
                 (= n 0))))))

(jolt-fiber-pool-reset!)
(printf "\nfibers-queue-invariant-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "fibers-queue-invariant-test: PASS\n") (exit 0))
    (exit 1))
