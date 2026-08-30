;; The tagged-table method registry accepts arbitrary tags. Non-keyword tags are
;; normalized through str rendering, which can run user code. This gate pins the
;; boundary: normalization may park and reenter registration, while only the
;; registry lookup/create/member writes run under hsc-mu.
(ns tagged-method-registration-test
  (:require [jolt.fibers :as fib]
            [jolt.host :as host]
            [jolt.scheme :as scheme]))

(def failures (atom []))

(defmacro check-eq [label got want]
  `(do
     (print (str "  .. " ~label "\n"))
     (flush)
     (let [g# ~got w# ~want]
       (when-not (= g# w#)
         (swap! failures conj
                (str ~label ": want " (pr-str w#) " got " (pr-str g#)))))))

(defn call-method [tag method]
  (try
    (let [obj (host/tagged-table tag)]
      (case method
        :parked (.parked obj)
        :nested (.nested obj)
        :left (.left obj)
        :right (.right obj)
        :only (.only obj)))
    (catch Throwable e
      [:error (.getName (class e)) (ex-message e)])))

(defn fiber-state [f]
  (try
    (fib/state f)
    (catch Throwable e
      [:error (.getName (class e)) (ex-message e)])))

(deftype ParkingReentrantTag [entered release locks-seen calls]
  Object
  (toString [_]
    (swap! calls inc)
    (swap! locks-seen conj (scheme/call "jolt-locks-held"))
    (deliver entered true)
    @release
    ;; Reenter the same registry after a real fiber park. This is safe only when
    ;; tag rendering is outside hsc-mu.
    (clojure.core/__register-class-methods!
      :tagged-method-test/nested
      {"nested" (fn [_] :nested-ok)})
    "tagged-method-test/parking"))

(let [entered (promise)
      release (promise)
      locks-seen (atom [])
      calls (atom 0)
      tag (ParkingReentrantTag. entered release locks-seen calls)
      registration
      (fib/spawn
        (fn []
          (try
            (clojure.core/__register-class-methods!
              tag {"parked" (fn [_] :parked-ok)})
            :registered
            (catch Throwable e
              [:error (.getName (class e)) (ex-message e)]))))
      entered-result (deref entered 2000 ::not-entered)
      state-before-release
      (loop [deadline (+ (System/nanoTime) 2000000000)]
        (let [s (fiber-state registration)]
          (if (or (= s :parked) (>= (System/nanoTime) deadline))
            s
            (do (Thread/yield) (recur deadline)))))
      _ (deliver release true)
      registration-result (fib/join registration 2000 ::timed-out)]
  (check-eq "custom tag rendering parks and reenters outside counted locks"
            [entered-result state-before-release @locks-seen @calls
             registration-result
             (call-method "tagged-method-test/parking" :parked)
             (call-method :tagged-method-test/nested :nested)]
            [true :parked [0] 1 :registered :parked-ok :nested-ok]))

;; Exercise the leaf critical section from real threads. Same-tag batches must
;; accumulate rather than race two inner tables; distinct tags must remain
;; independent. The start barrier makes every worker ready before release.
(let [start (promise)
      ready (atom 0)
      worker (fn [tag members]
               (future
                 (try
                   (swap! ready inc)
                   @start
                   (clojure.core/__register-class-methods! tag members)
                   :done
                   (catch Throwable e
                     [:error (.getName (class e)) (ex-message e)]))))
      same-left (worker :tagged-method-test/same
                        {"left" (fn [_] :left-ok)})
      same-right (worker :tagged-method-test/same
                         {"right" (fn [_] :right-ok)})
      distinct-left (worker :tagged-method-test/distinct-left
                            {"only" (fn [_] :distinct-left-ok)})
      distinct-right (worker :tagged-method-test/distinct-right
                             {"only" (fn [_] :distinct-right-ok)})
      ready-result
      (loop [deadline (+ (System/nanoTime) 2000000000)]
        (if (or (= 4 @ready) (>= (System/nanoTime) deadline))
          @ready
          (do (Thread/yield) (recur deadline))))
      _ (deliver start true)
      results (mapv #(deref % 2000 ::timed-out)
                    [same-left same-right distinct-left distinct-right])]
  (check-eq "concurrent same-tag and distinct-tag registration preserves methods"
            [ready-result results
             (call-method :tagged-method-test/same :left)
             (call-method :tagged-method-test/same :right)
             (call-method :tagged-method-test/distinct-left :only)
             (call-method :tagged-method-test/distinct-right :only)]
            [4 [:done :done :done :done]
             :left-ok :right-ok :distinct-left-ok :distinct-right-ok]))

(if (empty? @failures)
  (println "TAGGED-METHOD-REGISTRATION-TEST OK")
  (do
    (doseq [f @failures] (println "FAIL:" f))
    (println "TAGGED-METHOD-REGISTRATION-TEST FAILED:" (count @failures))
    (throw (ex-info "tagged-method registration test failed"
                    {:failures @failures}))))
