(ns instrumentation.provider)

(def aspect-provider
  {:schema 1
   :libraries {'test/aspect-target "fixture-v1"}
   :roles {:test/around 'instrumentation.provider/around}})

(defn around [join-point proceed]
  (println (str "advice-before " (:id join-point)))
  (let [value (proceed)]
    (println (str "advice-after " value))
    ;; The compiler-owned invoke-around contract preserves the app value.
    :ignored-provider-result))

(defn unrelated-advice [_ _]
  (throw (Exception. "tree shaking should remove this")))
