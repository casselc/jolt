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
(define (fiber-event f kind)
  (let ((fiber-id (jolt-fiber-diag-id f)))
    (let loop ((events (reverse
                         (jolt-fiber-trace-snapshot
                           (jolt-fiber-carrier f)))))
      (cond ((null? events) #f)
            ((and (= fiber-id (vector-ref (car events) 2))
                  (eq? kind (vector-ref (car events) 3)))
             (car events))
            (else (loop (cdr events)))))))

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
         (string-contains-substr? diag-output "queued=#t")
         (string-contains-substr? diag-output "queue-link=clear")
         (string-contains-substr? diag-output "handoff=#f pending=#f")
         (string-contains-substr? diag-output "wake-source=unspecified")
         (string-contains-substr? diag-output "continuation=none")))
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

(printf "\n== bounded queue-link and dispatch diagnostics ==\n")
(define link-f (sa-fiber-spawn (lambda () 'link-body-secret)))
(define link-c (jolt-fiber-carrier link-f))
(ok "the link-class fixture owns the queue head"
    (eq? link-f (jolt-fiber-dequeue! link-c)))
(jolt-fiber-next-set! link-f link-f)
(define link-port (open-output-string))
(define link-caught
  (parameterize ((current-error-port link-port))
    (guard (e (#t e))
      (jolt-fiber-enqueue! link-c link-f 'regression-stale-link)
      #f)))
(define link-output (get-output-string link-port))
(ok "a stale self-link is classified without rendering the link"
    (and link-caught
         (string-contains-substr? link-output "queue-link=self")
         (not (string-contains-substr? link-output "link-body-secret"))
         (not (string-contains-substr? link-output "#<"))))
(jolt-fiber-next-set! link-f #f)
(jolt-fiber-enqueue! link-c link-f 'fixture-requeue)
(sa-fiber-run-all)

(define dispatch-f (sa-fiber-spawn (lambda () 'dispatch-body-secret)))
(ok "the dispatch fixture is detached from the queue"
    (eq? dispatch-f (jolt-fiber-dequeue! (jolt-fiber-carrier dispatch-f))))
(jolt-fiber-state-set! dispatch-f 'parked)
(jolt-fiber-k-set! dispatch-f (lambda () 'continuation-secret))
(jolt-fiber-result-set! dispatch-f 'result-secret)
(jolt-fiber-error-set! dispatch-f 'error-secret)
(define dispatch-port (open-output-string))
(define dispatch-caught
  (parameterize ((current-error-port dispatch-port))
    (guard (e (#t e))
      (jolt-fiber-resume* dispatch-f)
      #f)))
(define dispatch-output (get-output-string dispatch-port))
(ok "invalid dispatch reports a bounded continuation class"
    (and dispatch-caught
         (string-contains-substr? dispatch-output "where=dispatch")
         (string-contains-substr? dispatch-output "continuation=captured")
         (not (string-contains-substr? dispatch-output "continuation-secret"))
         (not (string-contains-substr? dispatch-output "dispatch-body-secret"))
         (not (string-contains-substr? dispatch-output "result-secret"))
         (not (string-contains-substr? dispatch-output "error-secret"))))
(jolt-fiber-k-set! dispatch-f #f)
(jolt-fiber-sm-set! dispatch-f (lambda () 'step-secret))
(ok "continuation classification distinguishes a pending SM step"
    (eq? 'state-machine-step (jolt-fiber-continuation-class dispatch-f)))
(jolt-fiber-sm-set! dispatch-f 'running)
(ok "continuation classification distinguishes an executing SM driver"
    (eq? 'state-machine-running (jolt-fiber-continuation-class dispatch-f)))
(jolt-fiber-sm-set! dispatch-f #f)
(jolt-fiber-next-set! dispatch-f link-f)
(ok "a non-self queue link is classified without retaining its identity"
    (eq? 'linked (jolt-fiber-queue-link-class dispatch-f)))
(jolt-fiber-next-set! dispatch-f #f)
(jolt-fiber-error-set! dispatch-f #f)
(jolt-fiber-state-set! dispatch-f 'ready)
(jolt-fiber-enqueue! (jolt-fiber-carrier dispatch-f) dispatch-f 'fixture-requeue)
(sa-fiber-run-all)

(define default-resume-f
  (sa-fiber-spawn
    (lambda ()
      (jolt-fiber-park!)
      'default-resume-done)))
(sa-fiber-run-all)
(sa-fiber-resume default-resume-f)
(define default-resume-event (fiber-event default-resume-f 'resume-enqueue))
(ok "the public one-argument resume seam defaults to unspecified"
    (or (not jolt-fiber-trace-limit)
        (and default-resume-event
             (eq? 'unspecified (vector-ref default-resume-event 11)))))
(sa-fiber-run-all)

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
        (thread-join
          (fork-thread (lambda () (jolt-fiber-resume/source f 'test))))
        (set-box! handoff-observed
                  (vector (jolt-fiber-state f) (jolt-fiber-queued? f)
                          (jolt-fiber-park-handoff? f)
                          (jolt-fiber-wake-pending? f)
                          (jolt-fiber-pending-wake-source f)))
        (jolt-fiber-to-scheduler! f)
        (set-box! handoff-completed #t)
        'handoff-done))))
(sa-fiber-run-all)
(ok "a labeled pre-switch wake stays pending and off the ready queue"
    (equal? (vector 'parked #f #t #t 'test) (unbox handoff-observed)))
(define handoff-pending-event (fiber-event handoff-f 'resume-pending))
(define handoff-enqueue-event (fiber-event handoff-f 'pending-resume-enqueue))
(ok "ring events contain only bounded scheduler scalar metadata"
    (andmap
      (lambda (event)
        (and (= 14 (vector-length event))
             (andmap (lambda (v) (or (integer? v) (symbol? v) (boolean? v)))
                     (vector->list event))))
      (jolt-fiber-trace-snapshot (jolt-fiber-carrier handoff-f))))
(ok "the pending trace carries only handoff and wake metadata"
    (or (not jolt-fiber-trace-limit)
        (and handoff-pending-event handoff-enqueue-event
             (vector-ref handoff-pending-event 9)
             (vector-ref handoff-pending-event 10)
             (eq? 'test (vector-ref handoff-pending-event 11))
             (eq? 'test (vector-ref handoff-pending-event 12))
             (eq? 'none (vector-ref handoff-pending-event 13))
             (not (vector-ref handoff-enqueue-event 9))
             (not (vector-ref handoff-enqueue-event 10))
             (eq? 'test (vector-ref handoff-enqueue-event 11))
             (eq? 'none (vector-ref handoff-enqueue-event 12))
             (eq? 'captured (vector-ref handoff-enqueue-event 13)))))
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
        (thread-join
          (fork-thread (lambda () (jolt-fiber-resume/source f 'cancellation))))
        ;; Model cleanup winning before the carrier owns the parked fiber again.
        (jolt-fiber-done! f 'terminal-before-switch)))))
(sa-fiber-run-all)
(ok "terminal cleanup drops a pending wake without queue publication"
    (and (eq? 'done (jolt-fiber-state terminal-handoff-f))
         (not (jolt-fiber-queued? terminal-handoff-f))
         (not (jolt-fiber-park-handoff? terminal-handoff-f))
         (not (jolt-fiber-wake-pending? terminal-handoff-f))))
(define terminal-drop-event
  (fiber-event terminal-handoff-f 'pending-wake-drop))
(ok "terminal cleanup records the dropped cancellation wake as metadata"
    (or (not jolt-fiber-trace-limit)
        (and terminal-drop-event
             (eq? 'cancellation (vector-ref terminal-drop-event 11))
             (eq? 'none (vector-ref terminal-drop-event 12)))))

(printf "\n== synthetic scheduler counter-controls (not timer/via/cancel integration) ==\n")
;; These rows inject source labels at the scheduler seam. They do not invoke
;; core.async timeout, Ebb via/blk, or cancellation APIs; those actual paths
;; remain integration qualification gaps, not claims made by this source gate.
(define (run-forced-handoff-schedule park-kind sources expected-source)
  (let ((observed (box #f))
        (resumes (box 0)))
    (let ((f
           (sa-fiber-spawn
             (lambda ()
               (let ((me (jolt-current-fiber)))
                 (jolt-fiber-park-commit! me park-kind)
                 (let ((threads
                        (map (lambda (source)
                               (fork-thread
                                 (lambda ()
                                   (jolt-fiber-resume/source me source))))
                             sources)))
                   (for-each thread-join threads))
                 (set-box! observed
                           (vector (jolt-fiber-state me)
                                   (jolt-fiber-queued? me)
                                   (jolt-fiber-pending-wake-source me)))
                 (jolt-fiber-to-scheduler! me)
                 (set-box! resumes (+ 1 (unbox resumes)))
                 'schedule-done)))))
      (sa-fiber-run-all)
      (and (equal? (vector 'parked #f expected-source) (unbox observed))
           (= 1 (unbox resumes))
           (eq? 'done (jolt-fiber-state f))
           (not (jolt-fiber-queued? f))
           (or (not jolt-fiber-trace-limit)
               (let ((event (fiber-event f 'pending-resume-enqueue)))
                 (and event (eq? expected-source (vector-ref event 11)))))))))
(ok "timer-labelled scheduler counter-control wakes exactly once"
    (run-forced-handoff-schedule 'timer-completion '(timer) 'timer))
(ok "process-labelled scheduler counter-control wakes exactly once"
    (run-forced-handoff-schedule 'blocking-handback '(process) 'process))
(ok "completion/cancellation-labelled scheduler counter-control collapses wakes"
    (run-forced-handoff-schedule
      'completion-cancellation '(process cancellation) 'multiple))
(ok "unknown wake-source values collapse without retaining the value"
    (run-forced-handoff-schedule
      'unknown-source (list (vector 'wake-source-secret)) 'other))

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
(dynamic-wind
  (lambda ()
    (set! jolt-fiber-park-commit!
      (lambda (f kind)
        (real-jolt-fiber-park-commit! f kind)
        (when (and (eq? f cv-seam-f) (eq? kind 'condition-park))
          (thread-join
            (fork-thread
              (lambda ()
                (set-box! cv-seam-ready? #t)
                (jolt-fiber-resume/source f 'condition))))))))
  (lambda () (sa-fiber-run-all))
  (lambda ()
    (set! jolt-fiber-park-commit! real-jolt-fiber-park-commit!)))
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
(define handoff-before-switch-hook (lambda (h f) (void)))
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
          (jolt-fiber-park-commit! f kind)
          (jolt-unlock! (handoff-mu h))
          (handoff-before-switch-hook h f)
          (jolt-fiber-to-scheduler! f)))))

(printf "\n== deterministic OS starter -> parent -> child handoff ==\n")
(define topology-blocker (new-handoff))
(define topology-child-done (new-handoff))
(define topology-parent (box #f))
(define topology-observed (box #f))
(define topology-completed (box #f))
(define real-handoff-before-switch-hook handoff-before-switch-hook)
(dynamic-wind
  (lambda ()
    (set! handoff-before-switch-hook
      (lambda (h f)
        (when (eq? h topology-blocker)
          ;; The worker completes after the real commit and mutex release, but
          ;; is joined before the switch: publication must remain pending.
          (thread-join (fork-thread (lambda () (handoff-signal! h))))
          (set-box! topology-observed
            (vector (jolt-fiber-state f) (jolt-fiber-queued? f)
                    (jolt-fiber-park-handoff? f)
                    (jolt-fiber-wake-pending? f)))))))
  (lambda ()
    (thread-join
      (fork-thread
        (lambda ()
          (set-box! topology-parent
            (sa-fiber-spawn
              (lambda ()
                (sa-fiber-spawn
                  (lambda ()
                    (handoff-await! topology-blocker 'topology-child-park)
                    (handoff-signal! topology-child-done)
                    'child-done))
                (handoff-await! topology-child-done 'topology-parent-park)
                (set-box! topology-completed #t)
                'parent-done))))))
    (sa-fiber-run-all))
  (lambda ()
    (set! handoff-before-switch-hook real-handoff-before-switch-hook)))
(ok "the faithful handoff helper prevents premature queue publication"
    (equal? (vector 'parked #f #t #t) (unbox topology-observed)))
(ok "the OS-started parent and child make exactly-once progress"
    (and (unbox topology-completed)
         (eq? 'done (jolt-fiber-state (unbox topology-parent)))))

(printf "\n== non-vacuous supported-floor preemption counter-control ==\n")
(define floor-preempts-before (jolt-fiber-preempts))
(define floor-compute-f
  (sa-fiber-spawn
    (lambda ()
      (let loop ((i 0))
        (if (= i 20000) i (loop (+ i 1)))))))
(sa-fiber-run-all)
(define floor-preempt-event (fiber-event floor-compute-f 'preempt-ready))
(ok "bounded compute actually preempts at the supported floor"
    (and (= jolt-fiber-preempt-ticks-min (jolt-fiber-preempt-ticks))
         (> (jolt-fiber-preempts) floor-preempts-before)
         (eq? 'done (jolt-fiber-state floor-compute-f))
         (= 20000 (jolt-fiber-result floor-compute-f))
         (or (not jolt-fiber-trace-limit)
             (and floor-preempt-event
                  (eq? 'running (vector-ref floor-preempt-event 4))
                  (eq? 'ready (vector-ref floor-preempt-event 5))))))

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
