;; host/chez/sim/runtime.ss — private simulation-only runtime overlay.
;;
;; Loaded only by the `sim` Jolt image and by applications that image builds.
;; Ordinary release/debug images remain free of simulation state and branches.
;;
;; The overlay currently adds a private future-lifecycle seam around the real
;; Jolt future implementation. It deliberately exposes no public or versioned
;; controller surface yet; FFI, clock, and the complete exact controller ABI
;; land in later, independently reviewed commits.

(define jolt-sim-runtime-image? #t)

;; === future lifecycle hook ===================================================
;; A disabled-by-default observability + gating seam over the centralized
;; fork-thread future path (host/chez/java/concurrency.ss's jolt-future-call).
;; When a hook fn (a jolt IFn) is installed via jolt-future-hook-set!, each
;; ordinary future-call fires lifecycle events to it (called with jolt values):
;;   (:spawn  id parent)  on the SPAWNING thread, before the worker forks
;;   (:start  id parent)  on the WORKER thread, BEFORE the body runs — the hook
;;                        MAY BLOCK here (e.g. park on a promise) so a single
;;                        controller chooses which ordinary future begins
;;   (:finish id parent)  on the WORKER thread, AFTER its guarded attempt ends
;;                        (body result or pre-body setup/start failure), BEFORE
;;                        the result is published
;;   (:cancel id parent)  on the CANCELLING thread, BEFORE cancellation is
;;                        published; exactly one of :finish/:cancel wins
;;   (:exit   id parent)  on the WORKER thread, AFTER the winning result or
;;                        cancellation is published; every forked worker
;;                        attempts exactly one exit callback, even when start
;;                        or the body failed or cancellation won
;;   (:abort  id parent)  on the SPAWNING thread if :spawn registration or the
;;                        subsequent fork fails; no worker exists for that task
;; `id` is a stable, unique, positive int (1, 2, 3, …; never recycled) assigned
;; per future-call; `parent` is the task id in effect on the spawning thread (0 for
;; the primordial thread / any thread that is not itself a hooked future). A
;; :spawn hook failure propagates synchronously before any worker is forked. A
;; :start hook failure is captured as that future's failure, so deref cannot hang
;; and the body is not run. Terminal-hook failures never replace the application
;; result/cancellation; they are retained in a structured supervisor-error latch.
;; Dynamic bindings, cancellation, and ExecutionException propagation are
;; otherwise identical to the fast path. This is a TEST/simulation hook, not an
;; application task DSL — it is deliberately kept off the clojure.core/jolt.host
;; surface (install/clear through the Scheme procs below).
(define-record-type jolt-hooked-future
  (parent jolt-future)
  (fields hook task-id parent-id (mutable settling?))
  (nongenerative jolt-hooked-future-v1))

(define jolt-future-hook (box #f))           ; #f (disabled) or a jolt hook fn
(define jolt-future-id-mu (make-mutex))      ; guards the monotonic id counter
(define jolt-future-next-id (box 1))
;; This thread's task id (0 outside any hooked future). A future whose body spawns
;; another future reports this id as the child's parent.
(define jolt-future-task-id (make-thread-parameter 0))
(define fhk-spawn  (keyword #f "spawn"))
(define fhk-start  (keyword #f "start"))
(define fhk-finish (keyword #f "finish"))
(define fhk-cancel (keyword #f "cancel"))
(define fhk-exit   (keyword #f "exit"))
(define fhk-abort  (keyword #f "abort"))
(define jolt-future-hook-error-mu (make-mutex))
(define jolt-future-hook-errors '())

(define (jolt-future-current-task-id) (jolt-future-task-id))
(define (jolt-future-alloc-id!)
  (with-mutex jolt-future-id-mu
    (let ((n (unbox jolt-future-next-id)))
      (set-box! jolt-future-next-id (+ n 1))
      n)))
(define (jolt-future-hook-set! f) (set-box! jolt-future-hook f) jolt-nil)
(define (jolt-future-hook-clear!) (set-box! jolt-future-hook #f) jolt-nil)
(define (jolt-future-hook-error-record! event id parent e)
  (with-mutex jolt-future-hook-error-mu
    (set! jolt-future-hook-errors
          (cons (list event id parent e) jolt-future-hook-errors)))
  #f)
(define (jolt-future-hook-errors-snapshot)
  (with-mutex jolt-future-hook-error-mu
    (reverse jolt-future-hook-errors)))
(define (jolt-future-hook-errors-clear!)
  (with-mutex jolt-future-hook-error-mu
    (set! jolt-future-hook-errors '()))
  jolt-nil)
(define (jolt-future-hook-invoke hook event id parent)
  (guard (e (#t
             (jolt-future-hook-error-record! event id parent e)
             (raise e)))
    (jolt-invoke hook event id parent)))
(define (jolt-future-hook-terminal-invoke hook event id parent)
  (guard (e (#t (jolt-future-hook-error-record! event id parent e)))
    (jolt-invoke hook event id parent)))

(define (jolt-hooked-future-claim-terminal! f)
  (with-mutex (jolt-future-mu f)
    (if (or (jolt-future-done? f) (jolt-hooked-future-settling? f))
        #f
        (begin
          (jolt-hooked-future-settling?-set! f #t)
          #t))))

(define (jolt-hooked-future-publish-result! f r)
  (with-mutex (jolt-future-mu f)
    (jolt-future-ok?-set! f (car r))
    (jolt-future-payload-set! f (cdr r))
    (jolt-hooked-future-settling?-set! f #f)
    (jolt-future-done?-set! f #t)
    (condition-broadcast (jolt-future-cv f))))

;; A worker that loses the terminal claim to future-cancel must not publish its
;; computed result, but its :exit acknowledgement still has to follow the
;; canceller's :cancel callback and publication. claim-terminal! alone is not
;; that boundary: the winner invokes its hook outside the mutex before setting
;; done?. Wait on the future's existing condition so :exit observes the
;; published terminal state in both winner cases.
(define (jolt-hooked-future-await-published! f)
  (with-mutex (jolt-future-mu f)
    (let loop ()
      (unless (jolt-future-done? f)
        (condition-wait (jolt-future-cv f) (jolt-future-mu f))
        (loop)))))

;; Hook-aware future-call: with NO hook installed this defers to the base
;; jolt-future-call unchanged (no id, no wrapped record, no extra locking).
;; When a hook fn is installed it observes :spawn/:start, one of
;; :finish/:cancel, and the worker's final :exit acknowledgement. It may block
;; at :start so a controller can order ordinary futures — see the seam above.
(define (jolt-sim-future-call thunk)
  (let ((hook (unbox jolt-future-hook)))
    (if (not hook)
        (jolt-future-call thunk)
        (let* ((snap (dyn-binding-stack))
               (parent (jolt-future-task-id))
               (id (jolt-future-alloc-id!))
               (f (make-jolt-hooked-future
                   #f #f #f jolt-nil (make-mutex) (make-condition)
                   hook id parent #f)))
          ;; :spawn fires synchronously on this thread before the worker forks,
          ;; so any gate the hook arms for `id` is in place before :start runs.
          ;; Fail closed before the fork: a controller that cannot register this
          ;; task must not let the ordinary future escape uncontrolled. If
          ;; registration or fork-thread itself fails, :abort balances the
          ;; announced id so an external controller need not guess whether a
          ;; worker still exists.
          (guard (e (#t
                     (jolt-future-hook-terminal-invoke
                      hook fhk-abort id parent)
                     (raise e)))
            (jolt-future-hook-invoke hook fhk-spawn id parent)
            (fork-thread
             (lambda ()
               ;; Capture worker setup and a start-hook failure in the same
               ;; result channel as a body failure. The body is skipped and
               ;; deref observes ordinary ExecutionException semantics instead
               ;; of hanging, while the worker still reaches :exit.
               (let ((r (guard (e (#t (cons #f e)))
                          (*txn* #f)
                          (dyn-binding-stack snap)
                          ;; This body's spawns report id as their parent.
                          (jolt-future-task-id id)
                          (jolt-future-hook-invoke hook fhk-start id parent)
                          (cons #t (jolt-invoke thunk)))))
                 ;; Exactly one terminal claimant wins. Its hook runs before
                 ;; the result/cancellation becomes visible, and never while
                 ;; holding the future mutex, so the controller is a causal
                 ;; boundary without creating a hook/mutex deadlock.
                 (when (jolt-hooked-future-claim-terminal! f)
                   (jolt-future-hook-terminal-invoke
                    hook fhk-finish id parent)
                   (jolt-hooked-future-publish-result! f r))
                 ;; If cancellation won while this non-interruptible worker was
                 ;; running, wait until its :cancel hook and publication finish.
                 ;; :exit is supervisor-style: its failure is latched and cannot
                 ;; replace the already-published result or cancellation.
                 (jolt-hooked-future-await-published! f)
                 (jolt-future-hook-terminal-invoke
                  hook fhk-exit id parent)))))
          f))))

;; Hook-aware future-cancel: a hooked future's cancellation is a terminal event,
;; published only after the controller's :cancel observer runs; any other future
;; (no hook was installed when it was spawned) defers to the base jolt-future-cancel.
(define (jolt-sim-future-cancel f)
  (if (jolt-hooked-future? f)
      (if (jolt-hooked-future-claim-terminal! f)
          (begin
            (jolt-future-hook-terminal-invoke
             (jolt-hooked-future-hook f)
             fhk-cancel
             (jolt-hooked-future-task-id f)
             (jolt-hooked-future-parent-id f))
            (with-mutex (jolt-future-mu f)
              (jolt-future-cancelled?-set! f #t)
              (jolt-hooked-future-settling?-set! f #f)
              (jolt-future-done?-set! f #t)
              (condition-broadcast (jolt-future-cv f)))
            #t)
          #f)
      (jolt-future-cancel f)))

(def-var! "clojure.core" "future-call" jolt-sim-future-call)
(def-var! "clojure.core" "future-cancel" jolt-sim-future-cancel)
