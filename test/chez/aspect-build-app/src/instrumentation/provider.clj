(ns instrumentation.provider)

(def aspect-provider
  {:schema 1
   :libraries {'test/aspect-target "fixture-v1"}
   :roles {:test/around {:fn 'instrumentation.provider/around
                         :contract :replace-args-v1}}})

(defn around [join-point evaluated-args proceed]
  (println (str "advice-before " (:id join-point)))
  (println (str "advice-args " (pr-str evaluated-args)))
  (let [original (first evaluated-args)
        value (proceed [(if (= "ok" original)
                          "ok-woven"
                          original)])]
    (println (str "advice-after " value))
    ;; The compiler-owned invoke-around contract preserves the app value.
    :ignored-provider-result))

(defn unrelated-advice [_ _]
  (throw (Exception. "tree shaking should remove this")))
