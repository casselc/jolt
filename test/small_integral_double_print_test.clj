(ns small-integral-double-print-test
  (:require [clojure.test :as test :refer [deftest is]]
            [jolt.scheme :as scheme]))

;; Frozen baseline oracle inside the runtime. The optimized public formatter
;; does not call this for admitted values, but it remains authoritative for
;; every declined shape. Test the rebuilt runtime, not a test-installed overlay.
(def general (scheme/eval-string "jolt-flonum->string-general"))
(def render (scheme/eval-string "jolt-flonum->string"))

(deftest admitted-integers-retain-exact-text
  (doseq [value (concat (map double (range -10000 10001))
                       [9999999.0 -9999999.0])]
    (is (= (general value) (render value)))))

(deftest excluded-boundaries-retain-general-formatting
  (doseq [value [0.0 -0.0 0.5 -0.5 0.9999999999999999 -0.9999999999999999
                1.0000000000000002 -1.0000000000000002
                9999999.5 -9999999.5 10000000.0 -10000000.0
                10000001.0 -10000001.0 0.001 -0.001 0.0001 -0.0001
                Double/MIN_VALUE Double/MAX_VALUE Double/POSITIVE_INFINITY
                Double/NEGATIVE_INFINITY Double/NaN]]
    (is (= (general value) (render value)))))

(deftest public-number-rendering-retains-layout
  (is (= ["1.0" "-42.0" "9999999.0" "1.0E7" "-0.0" "0.0"]
         (mapv str [1.0 -42.0 9999999.0 10000000.0 -0.0 0.0])))
  (is (= "42.0" (Double/toString 42.0)))
  (is (= "-42.0" (pr-str -42.0))))

(deftest formatter-fast-path-is-nonvacuous-and-bounded
  (is (= 4
         (scheme/eval-string
          "(let ((original jolt-fixnum->string) (calls 0))
             (dynamic-wind
               (lambda () (set! jolt-fixnum->string
                 (lambda (n) (set! calls (+ calls 1)) (original n))))
               (lambda ()
                 (for-each jolt-flonum->string
                   '(1.0 -1.0 42.0 9999999.0 0.0 -0.0 0.5
                     9999999.5 10000000.0 +inf.0 +nan.0))
                 calls)
               (lambda () (set! jolt-fixnum->string original))))"))))

(defn -main [& _]
  (let [result (test/run-tests 'small-integral-double-print-test)]
    (System/exit (if (zero? (+ (:fail result) (:error result))) 0 1))))
