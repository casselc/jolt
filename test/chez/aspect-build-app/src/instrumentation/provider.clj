(ns instrumentation.provider)

(def aspect-provider
  {:schema 1
   :libraries {'test/aspect-target "fixture-v1"}
   :roles {:test/around {:fn 'instrumentation.provider/around
                         :contract :replace-args-v1}
           :test/entry-around {:fn 'instrumentation.provider/entry-around
                               :contract :args-v1}
           :test/numeric-entry-around
           {:fn 'instrumentation.provider/numeric-entry-around
            :contract :replace-args-v1}}})

(defn around [join-point evaluated-args proceed]
  (println (str "advice-before " (:id join-point)))
  (println (str "advice-args " (pr-str evaluated-args)))
  (let [original (first evaluated-args)]
    (cond
      (= "skip-outer" original)
      (println "advice-skip")

      (= "throw-outer" original)
      (do (println "advice-throw")
          (throw (Exception. "outer advice failure")))

      :else
      (let [value (proceed [(if (= "ok" original)
                              "ok-woven"
                              original)])]
        (println (str "advice-after " value))
        ;; The compiler-owned invoke-around contract preserves the app value.
        :ignored-provider-result))))

(defn unrelated-advice [_ _]
  (throw (Exception. "tree shaking should remove this")))

(defn entry-around [join-point evaluated-args proceed]
  (println (str "entry-before " (:id join-point)))
  (println (str "entry-args " (pr-str evaluated-args)))
  (let [value (proceed)]
    (println (str "entry-after " value))
    :ignored-provider-result))

(defn numeric-entry-around [join-point evaluated-args proceed]
  (println (str "numeric-entry-before " (:id join-point)))
  (println (str "numeric-entry-args " (pr-str evaluated-args)))
  (let [value (proceed [(inc (first evaluated-args))])]
    (println (str "numeric-entry-after " value))
    :ignored-provider-result))
