(ns alloc-gate
  "Allocation regression gate.

  Wall-clock measurement on a shared host carries a run-to-run spread, so a
  single-sample timing comparison can sit below the noise floor. Chez's
  allocation counter does not: the same work allocates the same number of bytes
  every run (verified byte-identical across repeats). This gate therefore
  asserts on ALLOCATED BYTES, which needs no repeats, no medians, and no
  spread analysis.

  What it catches: a change that makes a hot path allocate more — boxing that
  was previously avoided, a primitive that stopped being a primitive, an
  intermediate sequence that used to be fused. Those are exactly the regressions
  a timing gate is worst at detecting, because each one alone is inside the
  noise.

  What it does NOT catch: work that got slower without allocating more (a
  generic dispatch replacing a primitive of the same allocation profile, worse
  cache behaviour, more instructions). Allocation is a proxy, not a cost model.
  Pair it with timing when a change is expected to move time but not bytes.

  Usage:
    joltc test/chez/alloc-gate.clj                     compare to baseline
    ALLOC_GATE_RECORD=1 joltc test/chez/alloc-gate.clj  rewrite the baseline"
  (:require [jolt.perf :as perf]
            [clojure.string :as str]))

(def ^:private baseline-path "test/chez/alloc-baseline.edn")

;; Allowed growth before a case fails. The counter is exact, so this is not a
;; noise allowance — it is slack for unrelated compiler drift between commits.
(def ^:private tolerance 0.02)

(defn- measure
  "Bytes allocated by running (f) `n` times, net of the harness."
  [n f]
  (perf/collect!)
  (let [before (perf/bytes-allocated)]
    (dotimes [_ n] (f))
    (- (perf/bytes-allocated) before)))

;; Cases are chosen to cover the paths this repository has actually measured:
;; byte views, wrapping coercions, and the generic-vs-fixnum arithmetic split.
(def ^:private cases
  [["vec-range-10"        1000 #(vec (range 10))]
   ["unchecked-byte"     10000 #(unchecked-byte 200)]
   ["unchecked-short"    10000 #(unchecked-short 40000)]
   ["bit-and-mask"       10000 #(bit-and 200 0xff)]
   ["generic-add"        10000 #(+ 1000000 2000000)]
   ["str-concat"          1000 #(str "a" "b" "c")]
   ["map-filter-reduce"    200 #(reduce + (filter even? (map inc (range 50))))]
   ["assoc-small-map"     1000 #(assoc {:a 1 :b 2} :c 3)]
   ;; Pins the byte-array BACKING at one byte per element. A byte-array is backed
   ;; by a Chez bytevector; if it ever regresses to a boxed vector of fixnums this
   ;; jumps ~8x (100 * 1000 elements: ~120KB on a bytevector, ~820KB on a vector),
   ;; which is far outside the tolerance. Divide by 100 * 1000 for bytes/element.
   ["byte-array-1000"      100 #(byte-array 1000)]])

(defn- run-all []
  (reduce (fn [acc [name n f]] (assoc acc name (measure n f))) {} cases))

(defn -main [& _]
  (let [record? (= "1" (System/getenv "ALLOC_GATE_RECORD"))
        actual (run-all)]
    (if record?
      (do (spit baseline-path (pr-str (into (sorted-map) actual)))
          (println "recorded" (count actual) "cases to" baseline-path))
      (let [baseline (read-string (slurp baseline-path))
            rows (for [[name got] (sort actual)
                       :let [want (get baseline name)]]
                   (cond
                     (nil? want) [:new name got nil]
                     (> got (* want (+ 1.0 tolerance))) [:fail name got want]
                     (< got (* want (- 1.0 tolerance))) [:improved name got want]
                     :else [:ok name got want]))
            failures (filter #(= :fail (first %)) rows)]
        (doseq [[status name got want] rows]
          (println (format "  [%s] %-20s %10d bytes%s"
                           (str/upper-case (clojure.core/name status))
                           name got
                           (if want
                             (let [pct (if (zero? want)
                                         0.0
                                         (* 100.0 (/ (- got want) (double want))))]
                               (str "  (baseline " want ", "
                                    (if (neg? pct) "" "+")
                                    (format "%.1f" pct) "%)"))
                             "  (no baseline)"))))
        (println)
        (if (seq failures)
          (do (println "alloc gate:" (count failures) "case(s) allocate more than baseline")
              (System/exit 1))
          (println "alloc gate:" (count rows) "case(s) within tolerance"))))))

(-main)
