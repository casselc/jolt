(ns jolt-ffi-aggregate-test)

(require '[jolt.ffi :as ffi])

(ffi/load-library)
(ffi/load-library (System/getenv "JOLT_FFI_AGGREGATE_HELPER"))

(def date-type
  [:by-value [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]])

;; The public macros require literal signature data, so keep the descriptor
;; inline rather than referring to date-type in these declarations.
(def date-score
  (ffi/foreign-fn "jolt_agg_date_score"
                  [[:by-value [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]]
                  :int64))
(def make-date
  (ffi/foreign-fn "jolt_agg_make_date" [:int32 :uint8 :uint8]
                  [:by-value [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]))

(def failures (atom []))
(defmacro check [label expr]
  `(when-not ~expr (swap! failures conj ~label)))

(let [input (ffi/alloc 8) output (ffi/alloc 8)]
  (try
    (ffi/write input :int32 0 -123456789)
    (ffi/write input :uint8 4 250)
    (ffi/write input :uint8 5 251)
    (check "public by-value argument"
           (= -1234567864749 (date-score input)))
    (check "public by-value return"
           (= [output 2026 7 23]
              [(make-date output 2026 7 23)
               (ffi/read output :int32 0)
               (ffi/read output :uint8 4)
               (ffi/read output :uint8 5)]))
    (finally (ffi/free input) (ffi/free output))))

(if (empty? @failures)
  (do (println "JOLT-FFI-AGGREGATE-TEST OK") (flush) (System/exit 0))
  (do (doseq [failure @failures] (println "FAIL:" failure))
      (flush)
      (System/exit 1)))
