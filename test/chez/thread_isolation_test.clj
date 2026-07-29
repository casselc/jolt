;; thread_isolation_test.clj — per-thread isolation through the PUBLIC API.
;;
;;   jolt run test/chez/thread_isolation_test.clj
;;
;; test/chez/thread-slot-test.ss gates the same properties at the host level,
;; where it can compare the storage objects themselves. This gate is the other
;; half: it goes through the surface real code uses — `future`, `proxy
;; [ThreadLocal]`, `Thread/interrupted`, `jolt.codec.binary` — and asserts that
;; the isolation survives the whole stack.
;;
;; Every case initializes on the PARENT before the futures are created. That
;; ordering is the point. A Chez thread parameter hands a forked thread the
;; parent's CURRENT value, so state the parent has already touched is exactly
;; the state that leaks; a gate that spawned first would miss the defect
;; entirely. It is also what makes these deterministic — there is no sleep, no
;; retry, no widened timeout, and no assumption about the interleaving.

(ns thread-isolation-test
  (:require [jolt.codec.binary :as b]))

(def ^:private state (atom {:checks 0 :failures []}))

(defn- check! [label pred]
  (swap! state (fn [s]
                 (-> s
                     (update :checks inc)
                     (cond-> (not pred) (update :failures conj label))))))

(def ^:private workers 8)

;; Fan out and join. `deref` on every future is the barrier — the parent cannot
;; observe a result before that worker has produced it.
(defn- fan-out [n f]
  (mapv deref (mapv (fn [i] (future (f i))) (range n))))

;; ---------------------------------------------------------------------------
;; 1. the IEEE scratch behind f64 raw-bit conversion
;; ---------------------------------------------------------------------------
;; The defect the review reproduced through this exact surface: f64-bits stages
;; through one reusable eight-byte buffer, and under a plain thread parameter
;; every future shared the parent's copy. 12 futures gave 11 failures.

;; Convert once on the parent so the scratch exists BEFORE any future is made.
(def ^:private parent-warmup (b/f64-bits 1.0))
(check! "the parent's own conversion is correct" (= parent-warmup 0x3FF0000000000000))

;; Each worker owns a distinct f64 bit pattern and converts it repeatedly. The
;; patterns are quiet NaNs with per-worker payloads: distinct as bits, and
;; numerically equal to nothing at all, so a corrupted read cannot pass by
;; coincidence the way two ordinary doubles might.
(let [iterations 200000
      results (fan-out workers
                (fn [i]
                  (let [bits (+ 0x7FF8000000000000 (* (inc i) 0x1111))
                        x (b/bits->f64 bits)]
                    (loop [k 0]
                      (cond
                        (= k iterations) :clean
                        (not= (b/f64-bits x) bits) {:corrupt i :at k :got (b/f64-bits x)}
                        :else (recur (inc k)))))))]
  (doseq [r results] (when-not (= r :clean) (println "  corruption:" r)))
  (check! (str workers " futures x " iterations " f64 conversions, no corruption")
          (every? #(= % :clean) results)))

;; The same through the array accessors, which stage nothing but share the
;; fail-closed IEEE gate: each worker round-trips its own pattern via its own
;; array, so a shared buffer would show up as another worker's bytes.
(let [results (fan-out workers
                (fn [i]
                  (let [bits (+ 0x7FF8000000000000 (* (inc i) 0x1111))
                        x (b/bits->f64 bits)
                        a (byte-array 8)]
                    (loop [k 0]
                      (if (= k 50000)
                        :clean
                        (do (b/put-f64-be! a 0 x)
                            (if (= (b/get-u64-be a 0) bits)
                              (recur (inc k))
                              {:corrupt i :at k})))))))]
  (check! "array f64 write/read is isolated across futures"
          (every? #(= % :clean) results)))

;; Same-thread reuse is preserved — the correction must not have turned the
;; scratch into a per-call allocation. A thread that converts repeatedly still
;; gets correct results, which is the observable half of reuse; the byte-level
;; evidence is in test/chez/codec-binary-alloc-bench.ss.
(check! "repeated same-thread conversion stays correct"
        (let [bits 0x7FF8000ABCDEF123
              x (b/bits->f64 bits)]
          (every? #(= % bits) (repeatedly 10000 (fn [] (b/f64-bits x))))))

;; ---------------------------------------------------------------------------
;; 2. java.lang.ThreadLocal
;; ---------------------------------------------------------------------------
;; ThreadLocal is defined not to inherit. A child's first .get must run
;; initialValue for itself even though the parent has already used its own.

(def ^:private tl-inits (atom 0))
(def ^:private tl (proxy [ThreadLocal] [] (initialValue [] (swap! tl-inits inc) :initial)))

(check! "the parent's first get runs initialValue" (= (.get tl) :initial))
(.set tl :parent-value)                          ; parent initializes FIRST
(check! "the parent's get returns what it set" (= (.get tl) :parent-value))

(check! "a child's get runs initialValue rather than inheriting"
        (every? #(= % :initial) (fan-out workers (fn [_] (.get tl)))))
(check! "the parent's value is unchanged by the children" (= (.get tl) :parent-value))

;; each child's set is visible only to itself, across many reads
(check! "each child's set stays local to that child"
        (every? true?
                (fan-out workers
                  (fn [i]
                    (let [mine (keyword (str "child-" i))]
                      (.set tl mine)
                      (every? #(= % mine) (repeatedly 5000 (fn [] (.get tl)))))))))
(check! "the parent's value survived every child's set" (= (.get tl) :parent-value))

;; remove restores the initialValue path for that thread only
(check! "remove makes the next get run initialValue again"
        (every? #(= % :initial)
                (fan-out workers (fn [_] (.set tl :scratch) (.remove tl) (.get tl)))))
(check! "the parent is still holding its own value" (= (.get tl) :parent-value))
(.remove tl)
(check! "the parent's remove restores its own initialValue" (= (.get tl) :initial))

;; InheritableThreadLocal is the class that DOES propagate; the correction must
;; keep the two distinguishable rather than making everything non-inheriting.
(def ^:private itl (proxy [InheritableThreadLocal] [] (initialValue [] :initial)))
(.set itl :parent-value)                         ; parent initializes FIRST
(check! "InheritableThreadLocal still hands children the parent's value"
        (every? #(= % :parent-value) (fan-out workers (fn [_] (.get itl)))))

;; ---------------------------------------------------------------------------
;; 3. thread interrupt flags
;; ---------------------------------------------------------------------------
;; The interrupt flag is per-thread. Under inheritance, futures created by a
;; parent that had already touched its own flag would all share one box: one
;; .interrupt would interrupt every worker, and `Thread/interrupted` — which
;; reads AND clears — would let one worker swallow another's pending interrupt.

;; The parent touches its own flag FIRST, which is what seeds the defect.
(Thread/interrupted)
(check! "the parent starts uninterrupted" (not (Thread/interrupted)))

;; Each worker interrupts ITSELF and confirms it observes exactly one interrupt:
;; a shared box would let a sibling's interrupt be consumed here as a second
;; one, or let this worker's own be consumed elsewhere and read as none.
(check! "each worker sees exactly its own interrupt"
        (every? true?
                (fan-out workers
                  (fn [_]
                    (let [t (Thread/currentThread)]
                      (.interrupt t)
                      (and (true? (Thread/interrupted))     ; set, and now cleared
                           (not (Thread/interrupted)))))))) ; nothing else pending

(check! "no worker's interrupt reached the parent" (not (Thread/interrupted)))

;; A worker that never interrupts itself must stay clean while its siblings do.
(check! "an uninterrupted worker is unaffected by its siblings"
        (every? true?
                (fan-out workers
                  (fn [i]
                    (let [t (Thread/currentThread)]
                      (when (even? i) (.interrupt t))
                      (if (even? i)
                        (true? (Thread/interrupted))
                        (not (Thread/interrupted))))))))
(check! "the parent is still uninterrupted at the end" (not (Thread/interrupted)))

;; A thread handle captured by the PARENT must still name the parent's flag, so
;; cross-thread .interrupt keeps working — isolation must not break the feature.
(let [parent-thread (Thread/currentThread)
      _ (fan-out 1 (fn [_] (.interrupt parent-thread)))]
  (check! "a worker can still interrupt the parent through its handle"
          (true? (Thread/interrupted)))
  (check! "and that interrupt was consumed" (not (Thread/interrupted))))

;; ---------------------------------------------------------------------------
;; 4. nested agent sends
;; ---------------------------------------------------------------------------
;; An action's nested sends are held until the action completes, and the holding
;; list is the signal for "an action is in flight on this thread". Under
;; inheritance a future spawned from inside an action saw the parent's list,
;; concluded IT was running in an action, and had its own sends held there — so
;; they dispatched only when the parent action finished. A future that waited on
;; the effect of its own send was really waiting on the action that spawned it.
;;
;; The check is deterministic and uses no sleep. `send` enqueues synchronously
;; when it dispatches directly, so once the future has signalled that its send
;; returned, the action is already on `target`'s queue and `await` (legal here —
;; the main thread is not in an action) drains it. If the send was withheld
;; instead, target's queue is empty, await returns at once, and target is still
;; at its initial value. Both outcomes are settled, not raced.

(let [target (agent 0)
      holder (agent :idle)
      sent (promise)
      release (promise)
      observed (promise)]
  (send holder (fn [s]
                 (future
                   (send target inc)
                   (deliver sent :sent))
                 @sent                            ; the future's send has returned
                 (deliver observed :action-still-running)
                 @release                         ; hold the action open
                 s))
  @sent
  (check! "the action is still in flight while we look" (= @observed :action-still-running))
  (await target)
  (check! "a future's send is dispatched, not held by the enclosing action"
          (= @target 1))
  (deliver release :go)
  (await holder)
  (check! "the holding action completed normally" (= @holder :idle))
  ;; and a send made by the action ITSELF is still held until it completes
  (let [t2 (agent 0)
        release2 (promise)
        checked (promise)]
    (send holder (fn [s]
                   (send t2 inc)                  ; nested: must be held
                   (deliver checked @t2)
                   @release2
                   s))
    (check! "the action's own nested send is still held while it runs"
            (= @checked 0))
    (deliver release2 :go)
    (await holder)
    (await t2)
    (check! "the nested send is flushed once the action completes" (= @t2 1))))

;; ---------------------------------------------------------------------------
;; Trace rings are host-internal (no public Clojure surface), so their isolation
;; is gated in test/chez/thread-slot-test.ss rather than here.
;; ---------------------------------------------------------------------------

(let [{:keys [checks failures]} @state]
  (doseq [f failures] (println "FAIL:" f))
  (println (str "thread isolation: " checks " checks, " (count failures) " failures"))
  (when (seq failures) (System/exit 1)))
