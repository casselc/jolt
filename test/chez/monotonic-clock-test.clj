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
         (jolt.host/monotonic-source))
  (check-pred "public monotonic clock returns an integer"
              integer?
              (jolt.host/monotonic-nanos))
  (check-pred "System/nanoTime returns an integer"
              integer?
              (System/nanoTime)))

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
        ws (doall
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
        timed-out ::timed-out
        results (mapv #(deref % 2000 timed-out) ws)
        timeouts (count (filter #(= timed-out %) results))]
    (check "eight concurrent readers finish within bounded waits"
           0
           timeouts)
    (when (zero? timeouts)
      (check "eight concurrent readers never step backward"
             0
             (reduce + results)))))

(defn report-resolution []
  ;; `nanoTime` specifies nanosecond units, not nanosecond resolution. Report
  ;; the observed resolution for platform evidence without rejecting a valid
  ;; coarse monotonic source.
  (let [deltas (loop [i 0
                      previous (jolt.host/monotonic-nanos)
                      deltas []]
                 (if (>= i 5000)
                   deltas
                   (let [current (jolt.host/monotonic-nanos)]
                     (recur (inc i)
                            current
                            (conj deltas (- current previous))))))
        positive (filter pos? deltas)]
    (if (seq positive)
      (println "     smallest observed positive delta (ns):"
               (apply min positive))
      (println "     no positive delta observed in 5000 immediate samples"))))

(defn test-system-clock-wiring []
  (let [before (jolt.host/monotonic-nanos)
        system (System/nanoTime)
        after (jolt.host/monotonic-nanos)]
    (check-pred "System/nanoTime uses the host monotonic source"
                #(and (<= before %) (<= % after))
                system)))

(defn test-elapsed-scale []
  ;; A stalled CI worker can make one real sleep arbitrarily late. Take up to
  ;; three bounded samples and require one to demonstrate the expected scale:
  ;; tens of milliseconds, not seconds (wrong unit) or nanos (unscaled).
  (let [timed-out ::timed-out
        samples
        (loop [remaining 3
               measured []]
          (if (zero? remaining)
            measured
            (let [sample
                  (deref
                   (future
                     (let [start (jolt.host/monotonic-nanos)
                           _ (Thread/sleep 50)
                           elapsed-nanos
                           (- (jolt.host/monotonic-nanos) start)]
                       (/ elapsed-nanos 1000000.0)))
                   10000
                   timed-out)]
              (recur (dec remaining) (conj measured sample)))))
        in-scale (filter #(and (number? %)
                               (>= % 40.0)
                               (<= % 5000.0))
                         samples)]
    (println "     measured 50ms sleep samples (ms):" (pr-str samples))
    (check-pred "one bounded 50ms sample measures within [40,5000]ms"
                seq
                in-scale)))

(defn -main [& _]
  (println "monotonic clock characterization")
  (println "--------------------------------")
  (test-source)
  (test-non-decreasing)
  (report-resolution)
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
