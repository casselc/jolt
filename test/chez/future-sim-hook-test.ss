;; Ordinary Jolt future control-hook regression. Run:
;;   chez --script test/chez/future-sim-hook-test.ss
;;
;; The application forms below use clojure.core/future, deref, atoms, and
;; exceptions unchanged. Scheme is only the test controller that installs the
;; internal hook and releases task-start permits.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

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

;; The disabled path is ordinary Jolt and does not allocate simulation IDs.
(is "future works with hook disabled"
    "(deref (future (+ 20 22)))"
    "42")
(ok "default-disabled future allocated no simulation id"
    (= 1 (unbox jolt-future-next-id)))

;; Controller state. Spawn events are synchronous; start/finish occur on workers.
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
(is "finish event follows future settlement"
    "[(realized? sim-f1) (realized? sim-f2)]"
    "[true true]")

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
(is "body failure keeps future ExecutionException semantics"
    "(try (deref sim-body-failed) :not-thrown (catch ExecutionException e :wrapped))"
    ":wrapped")

;; A spawn-hook failure happens before fork and is not silently bypassed.
(jolt-future-hook-errors-clear!)
(define spawn-sentinel (list 'spawn-sentinel))
(jolt-future-hook-set!
 (lambda (event id parent)
   (if (eq? event fhk-spawn) (raise spawn-sentinel) jolt-nil)))
(ev "(def sim-spawn-body-ran (atom false))")
(ok "spawn-hook failure propagates synchronously unchanged"
    (guard (e (#t (eq? e spawn-sentinel)))
      (ev "(future (reset! sim-spawn-body-ran true))")
      #f))
(is "spawn-hook failure forks no application body"
    "@sim-spawn-body-ran"
    "false")
(let ((errors (jolt-future-hook-errors-snapshot)))
  (ok "spawn-hook failure is retained for the supervisor"
      (and (= 1 (length errors))
           (eq? fhk-spawn (car (car errors)))
           (eq? spawn-sentinel (list-ref (car errors) 3)))))

;; A start-hook failure is captured into the future and must never leave deref
;; blocked. The timed deref makes a regression terminate as :timeout.
(jolt-future-hook-errors-clear!)
(define start-sentinel (list 'start-sentinel))
(jolt-future-hook-set!
 (lambda (event id parent)
   (if (eq? event fhk-start) (raise start-sentinel) jolt-nil)))
(ev "(def sim-start-body-ran (atom false))")
(ev "(def sim-start-failed (future (reset! sim-start-body-ran true)))")
(is "start-hook failure settles rather than timing out"
    "(try (deref sim-start-failed 1000 :timeout) :not-thrown (catch ExecutionException e :wrapped))"
    ":wrapped")
(is "start-hook failure skips the application body"
    "@sim-start-body-ran"
    "false")
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
(jolt-future-hook-set!
 (lambda (event id parent)
   (when (eq? event fhk-finish)
     (with-mutex finish-gate-mu
       (set! finish-entered? #t)
       (condition-broadcast finish-gate-cv)
       (let loop ()
         (unless finish-released?
           (condition-wait finish-gate-cv finish-gate-mu)
           (loop)))))
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

;; A task retains one hook snapshot even if the process hook changes while its
;; :start callback is blocked.
(define snapshot-mu (make-mutex))
(define snapshot-cv (make-condition))
(define snapshot-a '())
(define snapshot-b '())
(define snapshot-started? #f)
(define snapshot-released? #f)
(define (snapshot-a-hook event id parent)
  (with-mutex snapshot-mu
    (set! snapshot-a (append snapshot-a (list (event-symbol event))))
    (when (eq? event fhk-start)
      (set! snapshot-started? #t)
      (condition-broadcast snapshot-cv)
      (let loop ()
        (unless snapshot-released?
          (condition-wait snapshot-cv snapshot-mu)
          (loop)))))
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
(ok "original hook receives spawn, start, and finish"
    (equal? snapshot-a '(spawn start finish)))
(ok "replacement hook receives no event from the existing future"
    (null? snapshot-b))

;; Cancellation is a terminal event published only after the controller sees
;; it. A worker already parked in :start remains an ordinary non-interruptible
;; worker and is explicitly released after the cancellation assertion.
(define cancel-mu (make-mutex))
(define cancel-cv (make-condition))
(define cancel-events '())
(define cancel-started? #f)
(define cancel-release-start? #f)
(define (cancel-hook event id parent)
  (with-mutex cancel-mu
    (set! cancel-events (append cancel-events (list (event-symbol event))))
    (when (eq? event fhk-start)
      (set! cancel-started? #t)
      (condition-broadcast cancel-cv)
      (let loop ()
        (unless cancel-release-start?
          (condition-wait cancel-cv cancel-mu)
          (loop)))))
  jolt-nil)
(jolt-future-hook-set! cancel-hook)
(ev "(def sim-cancel-body-ran (atom false))")
(ev "(def sim-cancel-body-finished (promise))")
(ev "(def sim-cancelled
       (future
         (reset! sim-cancel-body-ran true)
         (deliver sim-cancel-body-finished :ran)))")
(let ((deadline (ms->deadline 5000)))
  (with-mutex cancel-mu
    (let loop ()
      (unless cancel-started?
        (unless (condition-wait cancel-cv cancel-mu deadline)
          (error 'cancel-hook "timed out waiting for start hook"))
        (loop)))))
(is "future-cancel wins while the body is start-gated"
    "(future-cancel sim-cancelled)"
    "true")
(ok "controller observes cancel before future-cancel returns"
    (memq 'cancel cancel-events))
(is "cancelled future is marked cancelled"
    "(future-cancelled? sim-cancelled)"
    "true")
(is "start-gated body has not escaped before controller release"
    "@sim-cancel-body-ran"
    "false")
(with-mutex cancel-mu
  (set! cancel-release-start? #t)
  (condition-broadcast cancel-cv))
(is "releasing a cancelled non-interruptible worker lets it exit"
    "(deref sim-cancel-body-finished 1000 :timeout)"
    ":ran")
(ok "cancel winner suppresses a second finish terminal event"
    (not (memq 'finish cancel-events)))

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

(jolt-future-hook-clear!)
(is "clearing hook restores ordinary future path"
    "(deref (future :ordinary))"
    ":ordinary")

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
