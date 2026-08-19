(ns jolt-ffi-layout-test)

(require '[jolt.ffi :as ffi])

(def failures (atom []))
(defmacro check [label expr]
  `(when-not ~expr (swap! failures conj ~label)))
(defn rejects? [f]
  (try (f) false (catch Throwable _ true)))

(def date-layout
  (ffi/layout [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]))
(def nested-layout
  (ffi/layout [:struct [[:tag :uint8]
                       [:date [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]
                       [:tail :uint16]]]))

(check "flat size" (= 8 (ffi/layout-size date-layout)))
(check "flat alignment" (= 4 (ffi/layout-alignment date-layout)))
(check "keyword path" (= 4 (ffi/field-offset date-layout :month)))
(check "nested struct offset" (= 4 (ffi/field-offset nested-layout [:date])))
(check "nested scalar offset" (= 4 (ffi/field-offset nested-layout [:date :year])))
(check "descriptor data" (= [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]
                            (:descriptor date-layout)))

(let [p (ffi/alloc (ffi/layout-size nested-layout))]
  (try
    (ffi/write-field p nested-layout [:date :year] -2147483648)
    (ffi/write-field p nested-layout [:date :month] 255)
    (ffi/write-field p nested-layout :tail 65535)
    (check "signed field roundtrip"
           (= -2147483648 (ffi/read-field p nested-layout [:date :year])))
    (check "byte field roundtrip"
           (= 255 (ffi/read-field p nested-layout [:date :month])))
    (check "unsigned field roundtrip"
           (= 65535 (ffi/read-field p nested-layout :tail)))
    (finally (ffi/free p))))

(check "unknown path rejects"
       (rejects? #(ffi/field-offset date-layout :missing)))
(check "struct read rejects"
       (rejects? #(ffi/read-field ffi/null nested-layout :date)))
(check "invalid layout rejects"
       (rejects? #(ffi/layout-size {})))

(if (empty? @failures)
  (do (println "JOLT-FFI-LAYOUT-TEST OK") (flush) (System/exit 0))
  (do (doseq [failure @failures] (println "FAIL:" failure))
      (flush)
      (System/exit 1)))
