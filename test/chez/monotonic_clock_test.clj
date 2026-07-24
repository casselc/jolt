(ns monotonic-clock-test
  "Characterization of the monotonic clock behind jolt.host/monotonic-nanos and
  System/nanoTime.

  Before this change nanoTime was (* 1000000 (currentTimeMillis)): wall-clock AND
  truncated to milliseconds. That is unsound for deadlines twice over -- it can jump
  backwards when NTP steps the clock, and it cannot resolve any interval shorter than
  a millisecond (two adjacent calls reported a delta of exactly 0).

  These tests are expected to FAIL on a build without the monotonic clock, which is
  the point: they are the gate, not decoration.

  Honest limitation: independence from a wall-clock ADJUSTMENT is not directly
  testable without root (we cannot step the system clock). Test 4 substitutes the
  falsifiable half -- proving the two clocks are different sources by their
  magnitudes -- and the residual is recorded in the docs rather than claimed."
  (:require [clojure.string :as str]))

(def failures (atom 0))

(defn check [label expected actual]
  (if (= expected actual)
    (println "ok  " label)
    (do (swap! failures inc)
        (println "FAIL" label "\n  expected:" (pr-str expected) "\n  actual:  " (pr-str actual)))))

(defn check-pred [label pred actual]
  (if (pred actual)
    (println "ok  " label)
    (do (swap! failures inc)
        (println "FAIL" label "\n  value:" (pr-str actual)))))

;; --- 1. a true monotonic source is actually in use -------------------------
;; If Chez on this platform had no 'time-monotonic we fall back to the wall clock,
;; and every promise below degrades. Assert we are not silently in that mode.
(defn test-source []
  (check "monotonic-source is a real monotonic counter"
         :monotonic (jolt.host/monotonic-source)))

;; --- 2. non-decreasing, including under concurrency ------------------------
;; Each worker checks its OWN sequence: that is the property a deadline depends on.
;; A cross-thread global ordering is not guaranteed by any clock and is not asserted.
(defn test-non-decreasing []
  (let [samples 2000
        a (loop [i 0 prev (jolt.host/monotonic-nanos) bad 0]
            (if (>= i samples)
              bad
              (let [n (jolt.host/monotonic-nanos)]
                (recur (inc i) n (if (< n prev) (inc bad) bad)))))]
    (check "single-threaded: no backward step in 2000 samples" 0 a))

  (let [workers 8
        per 1000
        fs (doall (for [_ (range workers)]
                    (future
                      (loop [i 0 prev (jolt.host/monotonic-nanos) bad 0]
                        (if (>= i per)
                          bad
                          (let [n (jolt.host/monotonic-nanos)]
                            (recur (inc i) n (if (< n prev) (inc bad) bad))))))))
        bad (reduce + (map deref fs))]
    (check (str "concurrent: no backward step across " workers " workers x " per) 0 bad)))

;; --- 3. finer than the old millisecond projection --------------------------
;; Two independent falsifications of "this is still millisecond-truncated":
;;   (a) some adjacent pair differs by less than 1ms but is not equal;
;;   (b) not every sample is an exact multiple of 1e6 -- the old projection
;;       always was, by construction.
(defn test-resolution []
  (let [deltas (loop [i 0 prev (jolt.host/monotonic-nanos) acc []]
                 (if (>= i 5000)
                   acc
                   (let [n (jolt.host/monotonic-nanos)]
                     (recur (inc i) n (conj acc (- n prev))))))
        sub-ms (filter #(and (pos? %) (< % 1000000)) deltas)]
    (check-pred "observed a positive sub-millisecond delta" seq sub-ms)
    (when (seq sub-ms)
      (println "     smallest observed delta (ns):" (apply min sub-ms))))

  (let [samples (repeatedly 1000 #(jolt.host/monotonic-nanos))
        non-ms (remove #(zero? (mod % 1000000)) samples)]
    (check-pred "not every sample is an exact millisecond multiple" seq non-ms)))

;; --- 4. a different source from the wall clock -----------------------------
;; We cannot step the system clock without root, so we prove the falsifiable part:
;; the monotonic value is boot/process-relative and therefore nowhere near the
;; epoch-derived value. The old implementation made these two identical.
(defn test-distinct-source []
  (let [mono (jolt.host/monotonic-nanos)
        wall (* 1000000 (System/currentTimeMillis))]
    (check-pred "monotonic value is not epoch-derived"
                #(< % (/ wall 1000)) mono)
    (println "     monotonic:" mono " wall-ns:" wall)
    (check-pred "System/nanoTime tracks the monotonic source, not the wall clock"
                #(< % (/ wall 1000)) (System/nanoTime))))

;; --- 5. elapsed time is accurate ---------------------------------------------
;; A monotonic clock that never goes backwards but also never advances correctly
;; would pass everything above. Pin the scale.
(defn test-elapsed []
  (let [t0 (jolt.host/monotonic-nanos)
        _ (Thread/sleep 50)
        dt (- (jolt.host/monotonic-nanos) t0)
        ms (/ dt 1000000.0)]
    (println "     measured for a 50ms sleep (ms):" ms)
    (check-pred "50ms sleep measures within [40,200]ms"
                #(and (>= % 40.0) (<= % 200.0)) ms)))

(defn -main [& _]
  (println "monotonic clock characterization")
  (println "--------------------------------")
  (test-source)
  (test-non-decreasing)
  (test-resolution)
  (test-distinct-source)
  (test-elapsed)
  (println "--------------------------------")
  (if (pos? @failures)
    (do (println "FAILED:" @failures) (System/exit 1))
    (do (println "all monotonic clock checks passed") (System/exit 0))))

(apply -main *command-line-args*)
