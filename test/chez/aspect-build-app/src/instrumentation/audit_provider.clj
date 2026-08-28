(ns instrumentation.audit-provider)

(def aspect-provider
  {:schema 1
   :libraries {'test/aspect-target "fixture-v1"}
   :roles {:test/around {:fn 'instrumentation.audit-provider/around
                         :contract :replace-args-v1}
           :test/entry-around {:fn 'instrumentation.audit-provider/entry-around
                               :contract :args-v1}
           :test/numeric-entry-around
           {:fn 'instrumentation.audit-provider/numeric-entry-around
            :contract :replace-args-v1}}})

(defn around [join-point evaluated-args proceed]
  (println (str "audit-before " (:id join-point)))
  (println (str "audit-args " (pr-str evaluated-args)))
  (let [original (first evaluated-args)
        value (proceed [(if (= "ok-woven" original)
                          "ok-woven-inner"
                          original)])]
    (println (str "audit-after " value))
    :ignored-audit-result))

(defn entry-around [join-point evaluated-args proceed]
  (println (str "entry-audit-before " (:id join-point)))
  (println (str "entry-audit-args " (pr-str evaluated-args)))
  (let [value (proceed)]
    (println (str "entry-audit-after " value))
    :ignored-audit-result))

(defn numeric-entry-around [join-point evaluated-args proceed]
  (println (str "numeric-audit-before " (:id join-point)))
  (println (str "numeric-audit-args " (pr-str evaluated-args)))
  (let [value (proceed [(inc (first evaluated-args))])]
    (println (str "numeric-audit-after " value))
    :ignored-audit-result))
