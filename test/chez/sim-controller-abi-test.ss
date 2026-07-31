;; jolt.internal.sim controller ABI regression. Run:
;;   chez --script test/chez/sim-controller-abi-test.ss
;;
;; The application forms below use clojure.core/future, atom, promise, and
;; ordinary defn unchanged. jolt.internal.sim/* is a sim-image-only internal
;; namespace layered over the future lifecycle hook (host/chez/sim/runtime.ss,
;; "=== future lifecycle hook ===") that lets ORDINARY Jolt source resolve and
;; drive a simulation controller (capabilities probe, lifecycle + FFI
;; install/restore, error projection) instead of a test harness reaching into
;; Scheme internals — NOT a public application DSL. See
;; ordinary-future-no-sim-hook-test.ss for the base-image gate proving this
;; whole namespace and its Scheme internals are absent with the overlay
;; unloaded.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
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
(define (jget m k) (pmap-get m k jolt-nil))

;; === capabilities: exact ABI v3 and stable ===================================
(is "abi-version is exactly integer 3"
    "(:abi-version (jolt.internal.sim/capabilities))" "3")
(is "future-lifecycle capability is unchanged true"
    "(:future-lifecycle (jolt.internal.sim/capabilities))" "true")
(is "controller-errors capability is true"
    "(:controller-errors (jolt.internal.sim/capabilities))" "true")
(is "events capability is the exact ordered lifecycle set"
    "(:events (jolt.internal.sim/capabilities))"
    "[:spawn :start :finish :cancel :exit :abort]")
(is "ffi-interception descriptor-version is exactly integer 2"
    "(:descriptor-version (:ffi-interception (jolt.internal.sim/capabilities)))" "2")
(is "ffi-interception kinds is the exact set"
    "(:kinds (:ffi-interception (jolt.internal.sim/capabilities)))"
    "[:foreign-function :native-operation]")
(is "ffi-interception arguments capability is exactly :live"
    "(:arguments (:ffi-interception (jolt.internal.sim/capabilities)))" ":live")
(is "ffi-interception task identities are future-lifecycle ids"
    "(:task-identity (:ffi-interception (jolt.internal.sim/capabilities)))"
    ":future-lifecycle")
(is "ffi-interception native-operations is the exact ordered set"
    "(:native-operations (:ffi-interception (jolt.internal.sim/capabilities)))"
    "[:load-library :loaded? :alloc :free :read :write :sizeof :read-bytes :write-bytes :read-array :write-array :ptr->string :string->ptr]")
(is "ffi-interception map carries exactly five keys"
    "(count (:ffi-interception (jolt.internal.sim/capabilities)))" "5")
(is "capabilities map carries exactly five keys"
    "(count (jolt.internal.sim/capabilities))" "5")
(is "capabilities is stable across repeated calls"
    "(= (jolt.internal.sim/capabilities) (jolt.internal.sim/capabilities))" "true")

;; --- dynamic resolution + invocation from ordinary Jolt source --------------
;; A fully-qualified call resolves with no prior require (jolt.internal.sim has
;; vars the moment this overlay loads, exactly like jolt.host/jolt.ffi above),
;; and an aliased require resolves + invokes the SAME ABI.
(ev "(require '[jolt.internal.sim :as sim])")
(is "aliased capabilities call resolves and invokes the same ABI"
    "(:abi-version (sim/capabilities))" "3")

;; === lifecycle observation through install-controller! =======================
(ev "(def sim-abi-events (atom []))")
(ev "(def sim-abi-normal-exited (promise))")
(ev "(defn sim-abi-controller [event id parent]
       (swap! sim-abi-events conj [event id parent])
       (when (= event :exit)
         (deliver sim-abi-normal-exited true)))")
(ev "(def sim-abi-token (jolt.internal.sim/install-controller! sim-abi-controller))")
(is "an installed controller does not disturb an ordinary future's result"
    "(deref (future (+ 1 2)))" "3")
(is "the normal worker reaches its post-publication exit callback"
    "(deref sim-abi-normal-exited 5000 :timeout)" "true")
(is "the controller observed spawn/start/finish/exit in order"
    "(mapv first @sim-abi-events)" "[:spawn :start :finish :exit]")
(is "the controller's lifecycle events share the same task id"
    "(apply = (mapv second @sim-abi-events))" "true")
(is "the top-level future reports the primordial parent zero"
    "(every? zero? (mapv #(nth % 2) @sim-abi-events))" "true")
(ev "(jolt.internal.sim/restore-controller! sim-abi-token)")
(is "restoring returns to the unhooked baseline"
    "(deref (future :ordinary))" ":ordinary")
(is "no further events arrive once restored"
    "(count @sim-abi-events)" "4")

;; --- :cancel observation through install-controller! -------------------------
;; Mirrors the start-gate idiom future-sim-hook-test.ss uses, but the gate lives
;; in ordinary Jolt (a promise) instead of a raw Scheme mutex/condition.
(ev "(reset! sim-abi-events [])")
(ev "(def sim-abi-cancel-gate (promise))")
(ev "(def sim-abi-cancel-started (promise))")
(ev "(def sim-abi-cancel-exited (promise))")
(ev "(def sim-abi-cancel-ref (atom nil))")
(ev "(defn sim-abi-cancel-controller [event id parent]
       (swap! sim-abi-events conj [event id parent])
       (when (= event :start)
         (deliver sim-abi-cancel-started true)
         @sim-abi-cancel-gate)
       (when (= event :exit)
         (deliver sim-abi-cancel-exited
                  [(realized? @sim-abi-cancel-ref)
                   (future-cancelled? @sim-abi-cancel-ref)])))")
(ev "(def sim-abi-cancel-token (jolt.internal.sim/install-controller! sim-abi-cancel-controller))")
(ev "(def sim-abi-cancelled (future :unreachable))")
(ev "(reset! sim-abi-cancel-ref sim-abi-cancelled)")
(is "the controller observes :start before the future can be cancelled"
    "(deref sim-abi-cancel-started 5000 :timeout)" "true")
(is "cancelling a start-gated future succeeds"
    "(future-cancel sim-abi-cancelled)" "true")
(is "cancel is the last event before the parked worker is released"
    "(mapv first @sim-abi-events)" "[:spawn :start :cancel]")
(ev "(deliver sim-abi-cancel-gate true)") ; release the parked worker
(is "exit observes the already-published cancellation"
    "(deref sim-abi-cancel-exited 5000 :timeout)" "[true true]")
(is "cancel-wins emits one exit after cancel and no finish"
    "(mapv first @sim-abi-events)" "[:spawn :start :cancel :exit]")
(is "the cancelled worker emits exit exactly once"
    "(count (filter #(= :exit (first %)) @sim-abi-events))" "1")
(ev "(jolt.internal.sim/restore-controller! sim-abi-cancel-token)")

;; === nested exact restore, including a preexisting low-level hook ===========
;; A hook installed directly through the existing low-level
;; jolt-future-hook-set! (e.g. by a test harness or another Scheme-level
;; caller) BEFORE any Jolt-level install-controller! runs must be the EXACT
;; hook install-controller!/restore-controller! nests over and restores back
;; to — not merely "no hook"/#f.
(define low-level-events '())
(define low-level-mu (make-mutex))
(define low-level-cv (make-condition))
(define (event-symbol-ll event)
  (cond ((eq? event fhk-spawn) 'spawn)
        ((eq? event fhk-start) 'start)
        ((eq? event fhk-finish) 'finish)
        ((eq? event fhk-cancel) 'cancel)
        ((eq? event fhk-exit) 'exit)
        ((eq? event fhk-abort) 'abort)
        (else 'unknown)))
(define (low-level-hook event id parent)
  (with-mutex low-level-mu
    (set! low-level-events (cons (event-symbol-ll event) low-level-events))
    (condition-broadcast low-level-cv))
  jolt-nil)
(define (await-low-level-event-count n)
  (let ((deadline (ms->deadline 5000)))
    (with-mutex low-level-mu
      (let loop ()
        (cond
          ((>= (length low-level-events) n) #t)
          ((condition-wait low-level-cv low-level-mu deadline) (loop))
          (else #f))))))
(jolt-future-hook-set! low-level-hook)
(is "the preexisting low-level hook observes an unhooked baseline future"
    "(deref (future 1))" "1")
(ok "the baseline worker reaches exit"
    (await-low-level-event-count 4))
(ok "the low-level hook fired spawn/start/finish/exit for the baseline future"
    (with-mutex low-level-mu
      (equal? (reverse low-level-events) '(spawn start finish exit))))
(with-mutex low-level-mu (set! low-level-events '()))

(ev "(def sim-abi-nested-events (atom []))")
(ev "(def sim-abi-nested-exited (promise))")
(ev "(defn sim-abi-nested-controller [event id parent]
       (swap! sim-abi-nested-events conj [event id parent])
       (when (= event :exit)
         (deliver sim-abi-nested-exited true)))")
(ev "(def sim-abi-nested-token (jolt.internal.sim/install-controller! sim-abi-nested-controller))")
(is "the nested Jolt-level controller takes over from the low-level hook"
    "(deref (future 2))" "2")
(is "the nested controller observes worker exit"
    "(deref sim-abi-nested-exited 5000 :timeout)" "true")
(is "the nested controller observed the nested future"
    "(count @sim-abi-nested-events)" "4")
(ok "the low-level hook received no events while nested"
    (null? low-level-events))

(ev "(jolt.internal.sim/restore-controller! sim-abi-nested-token)")
(is "restoring after nesting reinstates ordinary futures"
    "(deref (future 3))" "3")
(ok "the restored low-level hook observes worker exit"
    (await-low-level-event-count 4))
(ok "the exact preexisting low-level hook fired again after restore"
    (equal? (reverse low-level-events) '(spawn start finish exit)))
(is "the nested Jolt controller received no further events after restore"
    "(count @sim-abi-nested-events)" "4")

(jolt-future-hook-clear!)
(with-mutex low-level-mu (set! low-level-events '()))

;; === out-of-order and repeated restore fail closed ===========================
(ev "(defn sim-abi-await-count [counter n]
       (loop [attempt 0]
         (cond
           (>= @counter n) @counter
           (= attempt 5000) :timeout
           :else (do (Thread/sleep 1) (recur (inc attempt))))))")
(ev "(def sim-abi-outer-count (atom 0))")
(ev "(def sim-abi-inner-count (atom 0))")
(ev "(defn sim-abi-outer-controller [event id parent] (swap! sim-abi-outer-count inc))")
(ev "(defn sim-abi-inner-controller [event id parent] (swap! sim-abi-inner-count inc))")
(ev "(def sim-abi-outer-token (jolt.internal.sim/install-controller! sim-abi-outer-controller))")
(ev "(def sim-abi-inner-token (jolt.internal.sim/install-controller! sim-abi-inner-controller))")
(is "the innermost installation is the active controller"
    "(do (deref (future :x)) (sim-abi-await-count sim-abi-inner-count 4))" "4")
(is "the outer controller has received no events while nested"
    "@sim-abi-outer-count" "0")

(ok "an out-of-order restore of the outer (non-top) token fails"
    (guard (e (#t #t))
      (ev "(jolt.internal.sim/restore-controller! sim-abi-outer-token)")
      #f))
(is "the failed out-of-order restore left the inner controller active"
    "(do (deref (future :y)) (sim-abi-await-count sim-abi-inner-count 8))" "8")
(is "the failed out-of-order restore changed nothing about the outer controller"
    "@sim-abi-outer-count" "0")

(ev "(jolt.internal.sim/restore-controller! sim-abi-inner-token)")
(is "restoring the inner token reinstates the outer controller"
    "(do (deref (future :z)) (sim-abi-await-count sim-abi-outer-count 4))" "4")

(ok "repeating a restore of the already-restored inner token fails"
    (guard (e (#t #t))
      (ev "(jolt.internal.sim/restore-controller! sim-abi-inner-token)")
      #f))
(is "the failed repeated restore left the outer controller active"
    "(do (deref (future :w)) (sim-abi-await-count sim-abi-outer-count 8))" "8")

(ev "(jolt.internal.sim/restore-controller! sim-abi-outer-token)")
(is "the final, in-order restore returns to the unhooked baseline"
    "(deref (future :done))" ":done")

;; === controller-errors projection + clear ====================================
;; :error must be the ORIGINAL condition the failing hook raised, unwrapped by
;; nobody — proven with identity (eq?), not by re-deriving a value from it.
(define sim-abi-error-sentinel (list 'sim-abi-error-sentinel))
(define sim-abi-error-events '())
(define (sim-abi-raw-failing-hook event id parent)
  (set! sim-abi-error-events (append sim-abi-error-events (list event)))
  (if (eq? event fhk-spawn) (raise sim-abi-error-sentinel) jolt-nil))

(ev "(jolt.internal.sim/clear-controller-errors!)")
(is "controller-errors is empty before any failure"
    "(count (jolt.internal.sim/controller-errors))" "0")

(define sim-abi-err-token (jolt-sim-install-controller! sim-abi-raw-failing-hook))
(ok "a spawn-hook failure through install-controller! propagates synchronously"
    (guard (e (#t #t)) (ev "(future :never)") #f))
(ok "a spawn-hook failure forks no worker and emits a balancing abort"
    (equal? sim-abi-error-events (list fhk-spawn fhk-abort)))

(let ((errs (ev "(jolt.internal.sim/controller-errors)")))
  (ok "controller-errors captured exactly one entry"
      (= 1 (pvec-cnt errs)))
  (let ((entry (pvec-nth-d errs 0 jolt-nil)))
    (ok "the captured entry's event is :spawn"
        (eq? (jget entry jolt-sim-kw-event) fhk-spawn))
    (ok "the captured entry's task id is a positive integer"
        (let ((tid (jget entry jolt-sim-kw-task))) (and (number? tid) (> tid 0))))
    (ok "the captured entry's parent is the primordial task id zero"
        (equal? (jget entry jolt-sim-kw-parent) 0))
    (ok "the captured entry's error is the exact original condition"
        (eq? (jget entry jolt-sim-kw-error) sim-abi-error-sentinel))))

(jolt-sim-restore-controller! sim-abi-err-token)
(ev "(jolt.internal.sim/clear-controller-errors!)")
(is "clearing empties the controller-errors collection"
    "(count (jolt.internal.sim/controller-errors))" "0")

;; An :exit observer failure happens strictly after publication. It must be
;; latched as supervisor evidence without replacing the already-visible result.
(ev "(def sim-abi-exit-attempted (promise))")
(ev "(defn sim-abi-exit-failing-controller [event id parent]
       (when (= event :exit)
         (deliver sim-abi-exit-attempted true)
         (throw (ex-info \"exit failed\" {:kind :exit}))))")
(ev "(def sim-abi-exit-token
       (jolt.internal.sim/install-controller! sim-abi-exit-failing-controller))")
(is "exit-hook failure cannot replace the published future result"
    "(deref (future 91))" "91")
(is "the exit hook was attempted after result publication"
    "(deref sim-abi-exit-attempted 5000 :timeout)" "true")
(is "the exit-hook failure reaches the controller-error latch"
    "(loop [attempt 0]
       (cond
         (= 1 (count (jolt.internal.sim/controller-errors))) 1
         (= attempt 5000) :timeout
         :else (do (Thread/sleep 1) (recur (inc attempt)))))"
    "1")
(let ((errs (ev "(jolt.internal.sim/controller-errors)")))
  (ok "the exit-hook failure is the only latched controller error"
      (= 1 (pvec-cnt errs)))
  (ok "the projected controller error identifies :exit"
      (eq? (jget (pvec-nth-d errs 0 jolt-nil) jolt-sim-kw-event) fhk-exit)))
(ev "(jolt.internal.sim/restore-controller! sim-abi-exit-token)")
(ev "(jolt.internal.sim/clear-controller-errors!)")

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
