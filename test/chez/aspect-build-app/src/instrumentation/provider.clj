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

(def runtime-sites (atom {}))

(defn assert-runtime-site! [join-point]
  (let [site (:site join-point)
        site-id (:site-id join-point)
        aspect-id (:id join-point)]
    (when-not (and (string? (:build-identity join-point))
                   (string? site-id)
                   (= aspect-id (:aspect site)))
      (throw (ex-info "invalid runtime aspect site" {:join-point join-point})))
    (when-let [prior (get @runtime-sites aspect-id)]
      (when-not (= prior [(:build-identity join-point) site-id site])
        (throw (ex-info "runtime aspect site changed between consumers"
                        {:prior prior :join-point join-point}))))
    (swap! runtime-sites assoc aspect-id
           [(:build-identity join-point) site-id site])))

(defn around [join-point evaluated-args proceed]
  (assert-runtime-site! join-point)
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

(defn entry-around [join-point evaluated-args proceed]
  (assert-runtime-site! join-point)
  (println (str "entry-before " (:id join-point)))
  (println (str "entry-args " (pr-str evaluated-args)))
  (let [value (proceed)]
    (println (str "entry-after " value))
    :ignored-provider-result))

(defn numeric-entry-around [join-point evaluated-args proceed]
  (assert-runtime-site! join-point)
  (println (str "numeric-entry-before " (:id join-point)))
  (println (str "numeric-entry-args " (pr-str evaluated-args)))
  (let [value (proceed [(inc (first evaluated-args))])]
    (println (str "numeric-entry-after " value))
    :ignored-provider-result))
