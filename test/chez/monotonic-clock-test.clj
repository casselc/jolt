(ns monotonic-clock-test
  "Characterize the monotonic clock behind jolt.host/monotonic-nanos and
  System/nanoTime.")

(def failures (atom 0))

(defn check [label expected actual]
  (if (= expected actual)
    (println "ok  " label)
    (do
      (swap! failures inc)
      (println "FAIL" label
               "\n  expected:" (pr-str expected)
               "\n  actual:  " (pr-str actual)))))

(defn check-pred [label pred actual]
  (if (pred actual)
    (println "ok  " label)
    (do
      (swap! failures inc)
      (println "FAIL" label "\n  value:" (pr-str actual)))))

(defn test-source []
  (check "monotonic-source reports the Chez monotonic-time interface"
         :chez-time-monotonic
         (jolt.host/monotonic-source)))

(defn test-non-decreasing []
  (let [samples 2000
        bad (loop [i 0
                   previous (jolt.host/monotonic-nanos)
                   failures 0]
              (if (>= i samples)
                failures
                (let [current (jolt.host/monotonic-nanos)]
                  (recur (inc i)
                         current
                         (if (< current previous)
                           (inc failures)
                           failures)))))]
    (check "single thread never steps backward in 2000 samples" 0 bad))

  (let [workers 8
        samples-per-worker 1000
        workers (doall
                  (for [_ (range workers)]
                    (future
                      (loop [i 0
                             previous (jolt.host/monotonic-nanos)
                             failures 0]
                        (if (>= i samples-per-worker)
                          failures
                          (let [current (jolt.host/monotonic-nanos)]
                            (recur (inc i)
                                   current
                                   (if (< current previous)
                                     (inc failures)
                                     failures))))))))
        bad (reduce + (map deref workers))]
    (check "eight concurrent readers never step backward" 0 bad)))

(defn test-resolution []
  (let [deltas (loop [i 0
                      previous (jolt.host/monotonic-nanos)
                      deltas []]
                 (if (>= i 5000)
                   deltas
                   (let [current (jolt.host/monotonic-nanos)]
                     (recur (inc i)
                            current
                            (conj deltas (- current previous))))))
        sub-millisecond (filter #(and (pos? %) (< % 1000000)) deltas)]
    (check-pred "observes a positive sub-millisecond delta"
                seq
                sub-millisecond)
    (when (seq sub-millisecond)
      (println "     smallest observed delta (ns):"
               (apply min sub-millisecond))))

  (let [samples (repeatedly 1000 #(jolt.host/monotonic-nanos))
        non-millisecond (remove #(zero? (mod % 1000000)) samples)]
    (check-pred "samples are not all exact millisecond multiples"
                seq
                non-millisecond)))

(defn test-system-clock-wiring []
  ;; The host reads bracket System/nanoTime when all three use the same
  ;; non-decreasing source. This avoids assuming anything about its arbitrary
  ;; origin or host uptime. The old epoch-based nanoTime falls outside.
  (let [before (jolt.host/monotonic-nanos)
        system (System/nanoTime)
        after (jolt.host/monotonic-nanos)]
    (check-pred "System/nanoTime uses the host monotonic source"
                #(and (<= before %) (<= % after))
                system)))

(defn test-elapsed-scale []
  (let [start (jolt.host/monotonic-nanos)
        _ (Thread/sleep 50)
        elapsed-nanos (- (jolt.host/monotonic-nanos) start)
        elapsed-millis (/ elapsed-nanos 1000000.0)]
    (println "     measured 50ms sleep (ms):" elapsed-millis)
    (check-pred "50ms sleep measures within [40,5000]ms"
                #(and (>= % 40.0) (<= % 5000.0))
                elapsed-millis)))

(defn -main [& _]
  (println "monotonic clock characterization")
  (println "--------------------------------")
  (test-source)
  (test-non-decreasing)
  (test-resolution)
  (test-system-clock-wiring)
  (test-elapsed-scale)
  (println "--------------------------------")
  (if (pos? @failures)
    (do
      (println "FAILED:" @failures)
      (System/exit 1))
    (do
      (println "all monotonic clock checks passed")
      (System/exit 0))))

(apply -main *command-line-args*)
