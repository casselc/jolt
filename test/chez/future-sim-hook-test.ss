;; Ordinary Jolt future control-hook regression. Run:
;;   chez --script test/chez/future-sim-hook-test.ss
;;
;; The application forms below use clojure.core/future, deref, atoms, and
;; exceptions unchanged. Scheme is only the test controller that installs the
;; internal hook and releases task-start permits.
;;
;; The hook itself (jolt-future-hook-set!/-clear!, the id allocator, the
;; jolt-hooked-future record) lives in the simulation-only overlay
;; (host/chez/sim/runtime.ss), loaded explicitly below — NOT in
;; host/chez/java/concurrency.ss, which an ordinary release/debug binary loads
;; branch-free with no hook global at all. See
;; ordinary-future-no-sim-hook-test.ss for that base-image gate.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/ffi.ss")
(load "host/chez/sim/runtime.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a~n" name)))
(define (ev s) (jolt-compile-eval (string-append "(do " s ")") "user"))
(define (render s) (jolt-final-str (ev s)))
(define (is name s expected)
  (ok (string-append name " => " expected)
      (string=? (render s) expected)))

;; The future seam now ships only as part of the complete atomic ABI 6 overlay.
(ok "future hook is exposed through complete controller ABI"
    (and (var-cell-lookup "jolt.internal.sim" "capabilities")
         (= 6 (jolt-get (jolt-sim-capabilities) (keyword #f "abi-version")))))

;; The disabled path is ordinary Jolt and does not allocate simulation IDs.
(is "future works with hook disabled"
    "(deref (future (+ 20 22)))"
    "42")
(ok "default-disabled future allocated no simulation id"
    (= 1 (unbox jolt-future-next-id)))

;; Controller state. Spawn events are synchronous; start/finish/exit occur on
;; workers, while cancel occurs on the cancelling thread.
(define ctl-mu (make-mutex))
(define ctl-cv (make-condition))
(define ctl-events '())
(define ctl-allowed '())
(define ctl-allow-all? #f)
(define (event-symbol event)
  (cond ((eq? event fhk-spawn) 'spawn)
        ((eq? event fhk-start) 'start)
        ((eq? event fhk-finish) 'finish)
        ((eq? event fhk-cancel) 'cancel)
        ((eq? event fhk-exit) 'exit)
        ((eq? event fhk-abort) 'abort)
        (else 'unknown)))
(define (controller-hook event id parent)
  (with-mutex ctl-mu
    (let ((kind (event-symbol event)))
      (set! ctl-events (append ctl-events (list (list kind id parent))))
      (condition-broadcast ctl-cv)
      (when (eq? kind 'start)
        (let loop ()
          (unless (or ctl-allow-all? (memv id ctl-allowed))
            (condition-wait ctl-cv ctl-mu)
            (loop))))))
  jolt-nil)
(define (events-of kind)
  (with-mutex ctl-mu
    (filter (lambda (event) (eq? (car event) kind)) ctl-events)))
(define (events-for-id id)
  (with-mutex ctl-mu
    (filter (lambda (event) (= (cadr event) id)) ctl-events)))
(define (wait-until pred)
  (let ((deadline (ms->deadline 5000)))
    (with-mutex ctl-mu
      (let loop ()
        (cond
          ((pred ctl-events) #t)
          ((condition-wait ctl-cv ctl-mu deadline) (loop))
          (else (error 'wait-until "timed out waiting for hook event")))))))
(define (allow! id)
  (with-mutex ctl-mu
    (set! ctl-allowed (cons id ctl-allowed))
    (condition-broadcast ctl-cv)))
(define (allow-all!)
  (with-mutex ctl-mu
    (set! ctl-allow-all? #t)
    (condition-broadcast ctl-cv)))

(jolt-future-hook-set! controller-hook)
(ev "(def sim-order (atom []))")
(ev "(def sim-f1 (future (swap! sim-order conj :one) 1))")
(ev "(def sim-f2 (future (swap! sim-order conj :two) 2))")

(define first-spawns (events-of 'spawn))
(define id1 (cadr (list-ref first-spawns 0)))
(define id2 (cadr (list-ref first-spawns 1)))
(ok "hooked future ids are stable, unique, and positive"
    (and (positive? id1) (positive? id2) (not (= id1 id2))))
(ok "top-level futures have primordial parent zero"
    (and (= 0 (caddr (list-ref first-spawns 0)))
         (= 0 (caddr (list-ref first-spawns 1)))))
(is "ordinary future bodies remain gated before permit"
    "@sim-order"
    "[]")

;; Release the second ordinary future first, then the first.
(allow! id2)
(wait-until
 (lambda (events)
   (exists (lambda (event)
             (and (eq? (car event) 'finish) (= (cadr event) id2)))
           events)))
(is "controller selects second future first"
    "@sim-order"
    "[:two]")
(allow! id1)
(wait-until
 (lambda (events)
   (exists (lambda (event)
             (and (eq? (car event) 'finish) (= (cadr event) id1)))
           events)))
(is "controller then releases first future"
    "@sim-order"
    "[:two :one]")
(is "controlled futures retain ordinary deref results"
    "[(deref sim-f1) (deref sim-f2)]"
    "[1 2]")
(wait-until
 (lambda (events)
   (and (exists (lambda (event)
                  (and (eq? (car event) 'exit) (= (cadr event) id1)))
                events)
        (exists (lambda (event)
                  (and (eq? (car event) 'exit) (= (cadr event) id2)))
                events))))
(is "both futures remain realized when their exit events are observed"
    "[(realized? sim-f1) (realized? sim-f2)]"
    "[true true]")
(ok "each normal worker emits exactly spawn/start/finish/exit"
    (and (equal? (map car (events-for-id id1)) '(spawn start finish exit))
         (equal? (map car (events-for-id id2)) '(spawn start finish exit))))
(ok "each normal worker emits exit exactly once"
    (and (= 1 (length (filter (lambda (e) (eq? (car e) 'exit))
                              (events-for-id id1))))
         (= 1 (length (filter (lambda (e) (eq? (car e) 'exit))
                              (events-for-id id2))))))

;; A nested future's spawn is synchronous inside the outer ordinary body. Its
;; parent id must be the explicitly installed child task parameter, not zero.
(ev "(def sim-outer (future (let [inner (future 9)] (deref inner))))")
(define outer-spawns (events-of 'spawn))
(define outer-id (cadr (list-ref outer-spawns 2)))
(allow! outer-id)
(wait-until
 (lambda (events)
   (>= (length (filter (lambda (event) (eq? (car event) 'spawn)) events))
       4)))
(define nested-spawns (events-of 'spawn))
(define inner-event (list-ref nested-spawns 3))
(define inner-id (cadr inner-event))
(ok "nested future records its ordinary future parent"
    (= outer-id (caddr inner-event)))
(allow! inner-id)
(is "nested ordinary future completes after child permit"
    "(deref sim-outer)"
    "9")

;; Ordinary body failures remain ordinary future failures.
(allow-all!)
(ev "(def sim-body-failed (future (throw (ex-info \"body failed\" {:kind :body}))))")
(define body-failed-id
  (cadr (car (reverse (events-of 'spawn)))))
(is "body failure keeps future ExecutionException semantics"
    "(try (deref sim-body-failed) :not-thrown (catch ExecutionException e :wrapped))"
    ":wrapped")
(wait-until
 (lambda (events)
   (exists (lambda (event)
             (and (eq? (car event) 'exit)
                  (= (cadr event) body-failed-id)))
           events)))
(ok "body failure still emits one complete worker lifecycle"
    (equal? (map car (events-for-id body-failed-id))
            '(spawn start finish exit)))

;; A spawn-hook failure happens before fork and is not silently bypassed. The
;; paired :abort lets a controller discard any registration side effects.
(jolt-future-hook-errors-clear!)
(define spawn-sentinel (list 'spawn-sentinel))
(define spawn-failure-events '())
(jolt-future-hook-set!
 (lambda (event id parent)
   (set! spawn-failure-events
         (append spawn-failure-events (list (event-symbol event))))
   (if (eq? event fhk-spawn) (raise spawn-sentinel) jolt-nil)))
(ev "(def sim-spawn-body-ran (atom false))")
(ok "spawn-hook failure propagates synchronously unchanged"
    (guard (e (#t (eq? e spawn-sentinel)))
      (ev "(future (reset! sim-spawn-body-ran true))")
      #f))
(is "spawn-hook failure forks no application body"
    "@sim-spawn-body-ran"
    "false")
(ok "spawn-hook failure forks no worker and emits a balancing abort"
    (equal? spawn-failure-events '(spawn abort)))
(let ((errors (jolt-future-hook-errors-snapshot)))
  (ok "spawn-hook failure is retained for the supervisor"
      (and (= 1 (length errors))
           (eq? fhk-spawn (car (car errors)))
           (eq? spawn-sentinel (list-ref (car errors) 3)))))

;; A synchronous worker-creation failure has the same balancing :abort, but is
;; not itself a controller error. Temporarily replace only this test image's
;; Scheme binding; dynamic-wind restores it even if the assertion path raises.
(jolt-future-hook-errors-clear!)
(define fork-sentinel (list 'fork-sentinel))
(define fork-failure-events '())
(define original-fork-thread fork-thread)
(jolt-future-hook-set!
 (lambda (event id parent)
   (set! fork-failure-events
         (append fork-failure-events (list (event-symbol event))))
   jolt-nil))
(ev "(def sim-fork-failure-body-ran (atom false))")
(ok "fork failure propagates synchronously unchanged"
    (dynamic-wind
      (lambda ()
        (set! fork-thread (lambda (thunk) (raise fork-sentinel))))
      (lambda ()
        (guard (e ((eq? e fork-sentinel) #t) (#t #f))
          (ev "(future (reset! sim-fork-failure-body-ran true))")
          #f))
      (lambda () (set! fork-thread original-fork-thread))))
(is "fork failure cannot run the application body"
    "@sim-fork-failure-body-ran"
    "false")
(ok "fork failure emits spawn then abort and no worker events"
    (equal? fork-failure-events '(spawn abort)))
(ok "fork failure does not fabricate a controller-hook error"
    (null? (jolt-future-hook-errors-snapshot)))

;; Fail one worker-only setup setter after the fork. The guarded attempt must
;; publish an ordinary future failure and still reach finish/exit without ever
;; reporting start or running the application body.
(jolt-future-hook-errors-clear!)
(define setup-sentinel (list 'setup-sentinel))
(define setup-mu (make-mutex))
(define setup-cv (make-condition))
(define setup-events '())
(define setup-exited? #f)
(define original-task-parameter jolt-future-task-id)
(jolt-future-hook-set!
 (lambda (event id parent)
   (with-mutex setup-mu
     (set! setup-events
           (append setup-events (list (event-symbol event))))
     (when (eq? event fhk-exit)
       (set! setup-exited? #t)
       (condition-broadcast setup-cv)))
   jolt-nil))
(set! jolt-future-task-id
      (lambda args
        (if (null? args)
            (original-task-parameter)
            (raise setup-sentinel))))
(ev "(def sim-setup-failure-body-ran (atom false))")
(ev "(def sim-setup-failed
       (future (reset! sim-setup-failure-body-ran true)))")
(is "worker setup failure settles as an ordinary future failure"
    "(try @sim-setup-failed :not-thrown
       (catch ExecutionException e :wrapped))"
    ":wrapped")
(let ((deadline (ms->deadline 5000)))
  (with-mutex setup-mu
    (let loop ()
      (unless setup-exited?
        (unless (condition-wait setup-cv setup-mu deadline)
          (error 'setup-failure "timed out waiting for exit hook"))
        (loop)))))
(set! jolt-future-task-id original-task-parameter)
(is "worker setup failure skips the application body"
    "@sim-setup-failure-body-ran"
    "false")
(ok "worker setup failure emits spawn/finish/exit without start"
    (equal? setup-events '(spawn finish exit)))
(ok "worker setup failure is an application result, not a hook error"
    (null? (jolt-future-hook-errors-snapshot)))

;; A start-hook failure is captured into the future and must never leave deref
;; blocked. Its worker still exits once, after that failure is published.
(jolt-future-hook-errors-clear!)
(define start-sentinel (list 'start-sentinel))
(define start-failure-mu (make-mutex))
(define start-failure-cv (make-condition))
(define start-failure-events '())
(define start-failure-exit-entered? #f)
(define start-failure-exit-released? #f)
(jolt-future-hook-set!
 (lambda (event id parent)
   (with-mutex start-failure-mu
     (set! start-failure-events
           (append start-failure-events (list (event-symbol event))))
     (when (eq? event fhk-exit)
       (set! start-failure-exit-entered? #t)
       (condition-broadcast start-failure-cv)
       (let loop ()
         (unless start-failure-exit-released?
           (condition-wait start-failure-cv start-failure-mu)
           (loop)))))
   (if (eq? event fhk-start) (raise start-sentinel) jolt-nil)))
(ev "(def sim-start-body-ran (atom false))")
(ev "(def sim-start-failed (future (reset! sim-start-body-ran true)))")
(is "start-hook failure settles rather than timing out"
    "(try (deref sim-start-failed 1000 :timeout) :not-thrown (catch ExecutionException e :wrapped))"
    ":wrapped")
(is "start-hook failure skips the application body"
    "@sim-start-body-ran"
    "false")
(let ((deadline (ms->deadline 5000)))
  (with-mutex start-failure-mu
    (let loop ()
      (unless start-failure-exit-entered?
        (unless (condition-wait
                 start-failure-cv start-failure-mu deadline)
          (error 'start-failure-exit
                 "timed out waiting for exit hook"))
        (loop)))))
(ok "start failure is published before its exit callback"
    (jolt-future-done? (var-deref "user" "sim-start-failed")))
(ok "start failure emits spawn/start/finish/exit exactly once"
    (with-mutex start-failure-mu
      (equal? start-failure-events '(spawn start finish exit))))
(with-mutex start-failure-mu
  (set! start-failure-exit-released? #t)
  (condition-broadcast start-failure-cv))
(let ((errors (jolt-future-hook-errors-snapshot)))
  (ok "start-hook failure is retained for the supervisor"
      (and (= 1 (length errors))
           (eq? fhk-start (car (car errors)))
           (eq? start-sentinel (list-ref (car errors) 3)))))

;; :finish is a causal boundary: while the controller blocks it, deref cannot
;; observe the computed value.
(define finish-gate-mu (make-mutex))
(define finish-gate-cv (make-condition))
(define finish-entered? #f)
(define finish-released? #f)
(define exit-entered-count 0)
(define exit-released? #f)
(jolt-future-hook-set!
 (lambda (event id parent)
   (with-mutex finish-gate-mu
     (cond
       ((eq? event fhk-finish)
        (set! finish-entered? #t)
        (condition-broadcast finish-gate-cv)
        (let loop ()
          (unless finish-released?
            (condition-wait finish-gate-cv finish-gate-mu)
            (loop))))
       ((eq? event fhk-exit)
        (set! exit-entered-count (+ exit-entered-count 1))
        (condition-broadcast finish-gate-cv)
        (let loop ()
          (unless exit-released?
            (condition-wait finish-gate-cv finish-gate-mu)
            (loop))))))
   jolt-nil))
(ev "(def sim-finish-gated (future 42))")
(let ((deadline (ms->deadline 5000)))
  (with-mutex finish-gate-mu
    (let loop ()
      (unless finish-entered?
        (unless (condition-wait finish-gate-cv finish-gate-mu deadline)
          (error 'finish-gate "timed out waiting for finish hook"))
        (loop)))))
(is "deref cannot pass a blocked finish boundary"
    "(deref sim-finish-gated 25 :timeout)"
    ":timeout")
(with-mutex finish-gate-mu
  (set! finish-released? #t)
  (condition-broadcast finish-gate-cv))
(is "releasing finish publishes the ordinary result"
    "(deref sim-finish-gated)"
    "42")
(let ((deadline (ms->deadline 5000)))
  (with-mutex finish-gate-mu
    (let loop ()
      (unless (positive? exit-entered-count)
        (unless (condition-wait finish-gate-cv finish-gate-mu deadline)
          (error 'exit-gate "timed out waiting for exit hook"))
        (loop)))))
(is "the ordinary result is realized while exit remains blocked"
    "(realized? sim-finish-gated)"
    "true")
(ok "the normal worker attempts exit exactly once"
    (= 1 exit-entered-count))
(with-mutex finish-gate-mu
  (set! exit-released? #t)
  (condition-broadcast finish-gate-cv))

;; A task retains one hook snapshot even if the process hook changes while its
;; :start callback is blocked.
(define snapshot-mu (make-mutex))
(define snapshot-cv (make-condition))
(define snapshot-a '())
(define snapshot-b '())
(define snapshot-started? #f)
(define snapshot-released? #f)
(define snapshot-exited? #f)
(define (snapshot-a-hook event id parent)
  (with-mutex snapshot-mu
    (set! snapshot-a (append snapshot-a (list (event-symbol event))))
    (when (eq? event fhk-start)
      (set! snapshot-started? #t)
      (condition-broadcast snapshot-cv)
      (let loop ()
        (unless snapshot-released?
          (condition-wait snapshot-cv snapshot-mu)
          (loop))))
    (when (eq? event fhk-exit)
      (set! snapshot-exited? #t)
      (condition-broadcast snapshot-cv)))
  jolt-nil)
(define (snapshot-b-hook event id parent)
  (with-mutex snapshot-mu
    (set! snapshot-b (append snapshot-b (list (event-symbol event)))))
  jolt-nil)
(jolt-future-hook-set! snapshot-a-hook)
(ev "(def sim-snapshot-future (future :snapshot))")
(let ((deadline (ms->deadline 5000)))
  (with-mutex snapshot-mu
    (let loop ()
      (unless snapshot-started?
        (unless (condition-wait snapshot-cv snapshot-mu deadline)
          (error 'snapshot-hook "timed out waiting for start hook"))
        (loop)))))
(jolt-future-hook-set! snapshot-b-hook)
(with-mutex snapshot-mu
  (set! snapshot-released? #t)
  (condition-broadcast snapshot-cv))
(is "hook replacement does not split one future lifecycle"
    "(deref sim-snapshot-future)"
    ":snapshot")
(let ((deadline (ms->deadline 5000)))
  (with-mutex snapshot-mu
    (let loop ()
      (unless snapshot-exited?
        (unless (condition-wait snapshot-cv snapshot-mu deadline)
          (error 'snapshot-hook "timed out waiting for exit hook"))
        (loop)))))
(ok "original hook receives spawn, start, finish, and exit"
    (equal? snapshot-a '(spawn start finish exit)))
(ok "replacement hook receives no event from the existing future"
    (null? snapshot-b))

;; Cancellation is published only after its controller callback returns. Hold a
;; cancelling thread inside :cancel while the already-running body returns: the
;; losing worker must enter await-published! and may not emit :exit yet.
(jolt-future-hook-errors-clear!)
(define cancel-sentinel (list 'cancel-sentinel))
(define cancel-mu (make-mutex))
(define cancel-cv (make-condition))
(define cancel-events '())
(define cancel-entered? #f)
(define cancel-release? #f)
(define cancel-await-entered? #f)
(define cancel-exit-entered? #f)
(define cancel-exit-state #f)
(define cancel-call-done? #f)
(define cancel-call-result #f)
(define cancel-call-error #f)
(define original-await-published! jolt-hooked-future-await-published!)
(set! jolt-hooked-future-await-published!
      (lambda (f)
        (with-mutex cancel-mu
          (set! cancel-await-entered? #t)
          (condition-broadcast cancel-cv))
        (original-await-published! f)))
(define (cancel-hook event id parent)
  (with-mutex cancel-mu
    (set! cancel-events (append cancel-events (list (event-symbol event))))
    (when (eq? event fhk-cancel)
      (set! cancel-entered? #t)
      (condition-broadcast cancel-cv)
      (let loop ()
        (unless cancel-release?
          (condition-wait cancel-cv cancel-mu)
          (loop)))
      (raise cancel-sentinel))
    (when (eq? event fhk-exit)
      (let ((f (var-deref "user" "sim-cancelled")))
        (set! cancel-exit-state
              (list (jolt-future-done? f)
                    (jolt-future-cancelled? f))))
      (set! cancel-exit-entered? #t)
      (condition-broadcast cancel-cv)))
  jolt-nil)
(jolt-future-hook-set! cancel-hook)
(ev "(def sim-cancel-body-started (promise))")
(ev "(def sim-cancel-body-release (promise))")
(ev "(def sim-cancel-body-finished (promise))")
(ev "(def sim-cancelled
       (future
         (deliver sim-cancel-body-started true)
         @sim-cancel-body-release
         (deliver sim-cancel-body-finished :ran)))")
(is "the ordinary body starts before cancellation races it"
    "(deref sim-cancel-body-started 5000 :timeout)"
    "true")
(fork-thread
 (lambda ()
   (let ((r (guard (e (#t (cons #f e)))
              (cons #t
                    (jolt-sim-future-cancel
                     (var-deref "user" "sim-cancelled"))))))
     (with-mutex cancel-mu
       (if (car r)
           (set! cancel-call-result (cdr r))
           (set! cancel-call-error (cdr r)))
       (set! cancel-call-done? #t)
       (condition-broadcast cancel-cv)))))
(let ((deadline (ms->deadline 5000)))
  (with-mutex cancel-mu
    (let loop ()
      (unless cancel-entered?
        (unless (condition-wait cancel-cv cancel-mu deadline)
          (error 'cancel-hook "timed out waiting for cancel hook"))
        (loop)))))
(is "future remains unpublished while its cancel observer is blocked"
    "(realized? sim-cancelled)"
    "false")
(ok "cancel is observed after spawn/start and before worker exit"
    (with-mutex cancel-mu
      (equal? cancel-events '(spawn start cancel))))
(ev "(deliver sim-cancel-body-release true)")
(is "the non-interruptible body returns while cancellation is unpublished"
    "(deref sim-cancel-body-finished 5000 :timeout)"
    ":ran")
(let ((deadline (ms->deadline 5000)))
  (with-mutex cancel-mu
    (let loop ()
      (unless cancel-await-entered?
        (unless (condition-wait cancel-cv cancel-mu deadline)
          (error 'cancel-hook
                 "timed out waiting for losing worker publication wait"))
        (loop)))))
(ok "losing worker reached the publication wait without emitting exit"
    (with-mutex cancel-mu
      (and cancel-await-entered?
           (not cancel-exit-entered?)
           (equal? cancel-events '(spawn start cancel)))))
(is "body return alone cannot realize the future while cancel is blocked"
    "(realized? sim-cancelled)"
    "false")
(with-mutex cancel-mu
  (set! cancel-release? #t)
  (condition-broadcast cancel-cv))
(let ((deadline (ms->deadline 5000)))
  (with-mutex cancel-mu
    (let loop ()
      (unless (and cancel-call-done? cancel-exit-entered?)
        (unless (condition-wait cancel-cv cancel-mu deadline)
          (error 'cancel-hook
                 "timed out waiting for cancellation publication and exit"))
        (loop)))))
(ok "future-cancel succeeds after its failing observer is released"
    (and cancel-call-result (not cancel-call-error)))
(let ((errors (jolt-future-hook-errors-snapshot)))
  (ok "the failing cancel observer is latched without blocking publication"
      (and (= 1 (length errors))
           (eq? fhk-cancel (car (car errors)))
           (eq? cancel-sentinel (list-ref (car errors) 3)))))
(ok "cancel publication is complete before the worker's exit callback"
    (equal? cancel-exit-state '(#t #t)))
(is "cancelled future is marked cancelled after publication"
    "(future-cancelled? sim-cancelled)"
    "true")
(ok "cancel winner emits spawn/start/cancel/exit with no finish"
    (with-mutex cancel-mu
      (equal? cancel-events '(spawn start cancel exit))))
(ok "cancelled worker emits exit exactly once"
    (= 1 (length (filter (lambda (event) (eq? event 'exit))
                         cancel-events))))
(set! jolt-hooked-future-await-published! original-await-published!)
(jolt-future-hook-errors-clear!)

;; A finish observer failure happens before publication but must not replace the
;; ordinary result. It is retained as structured supervisor evidence.
(jolt-future-hook-errors-clear!)
(define finish-attempted? #f)
(define finish-sentinel (list 'finish-sentinel))
(jolt-future-hook-set!
 (lambda (event id parent)
   (when (eq? event fhk-finish)
     (set! finish-attempted? #t)
     (raise finish-sentinel))
   jolt-nil))
(is "finish-hook failure cannot replace settled future result"
    "(deref (future 77))"
    "77")
(ok "finish-hook failure was not silently skipped" finish-attempted?)
(let ((errors (jolt-future-hook-errors-snapshot)))
  (ok "finish-hook failure is retained for the supervisor"
      (and (= 1 (length errors))
           (eq? fhk-finish (car (car errors)))
           (eq? finish-sentinel (list-ref (car errors) 3)))))

;; Exit is supervisor acknowledgement after publication. Its observer may fail,
;; but that failure is latched and cannot replace the application result.
(jolt-future-hook-errors-clear!)
(define exit-failure-mu (make-mutex))
(define exit-failure-cv (make-condition))
(define exit-failure-count 0)
(define exit-sentinel (list 'exit-sentinel))
(jolt-future-hook-set!
 (lambda (event id parent)
   (when (eq? event fhk-exit)
     (with-mutex exit-failure-mu
       (set! exit-failure-count (+ exit-failure-count 1))
       (condition-broadcast exit-failure-cv))
     (raise exit-sentinel))
   jolt-nil))
(is "exit-hook failure cannot replace the published future result"
    "(deref (future 88))"
    "88")
(let ((deadline (ms->deadline 5000)))
  (with-mutex exit-failure-mu
    (let loop ()
      (unless (positive? exit-failure-count)
        (unless (condition-wait
                 exit-failure-cv exit-failure-mu deadline)
          (error 'exit-failure "timed out waiting for exit hook"))
        (loop)))))
(ok "the worker attempts a failing exit hook exactly once"
    (= 1 exit-failure-count))
(ok "the failing exit callback reaches the supervisor latch"
    (let loop ((attempt 0))
      (cond
        ((= 1 (length (jolt-future-hook-errors-snapshot))) #t)
        ((= attempt 5000) #f)
        (else
         (sleep (ms->duration 1))
         (loop (+ attempt 1))))))
(let ((errors (jolt-future-hook-errors-snapshot)))
  (ok "exit-hook failure is retained for the supervisor"
      (and (= 1 (length errors))
           (eq? fhk-exit (car (car errors)))
           (eq? exit-sentinel (list-ref (car errors) 3)))))

(jolt-future-hook-clear!)
(is "clearing hook restores ordinary future path"
    "(deref (future :ordinary))"
    ":ordinary")

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
