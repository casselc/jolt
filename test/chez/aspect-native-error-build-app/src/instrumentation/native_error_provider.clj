(ns instrumentation.native-error-provider)

(def ^:private journal-limit 4)
(def ^:private journal (atom []))
(def ^:private runtime-site (atom nil))

(defn assert-runtime-site! [join-point]
  (let [observed [(:build-identity join-point)
                  (:site-id join-point)
                  (:site join-point)]]
    (when-not (and (string? (first observed))
                   (string? (second observed))
                   (= (second observed) (get-in observed [2 :site-id])))
      (throw (ex-info "invalid native-error runtime site"
                      {:join-point join-point})))
    (when-let [prior @runtime-site]
      (when-not (= prior observed)
        (throw (ex-info "native-error site changed between consumers"
                        {:prior prior :join-point join-point}))))
    (reset! runtime-site observed)))

(defn- record! [event]
  (swap! journal
         (fn [events]
           (->> (conj events event)
                (take-last journal-limit)
                vec))))

(defn around [join-point evaluated-args proceed]
  (assert-runtime-site! join-point)
  (record! [:enter (:id join-point) evaluated-args])
  (let [value (proceed)]
    (record! [:return (:id join-point) value])
    (println (str "journal " (pr-str @journal)))
    ;; The compiler-owned advice contract must return the native operation's
    ;; exact [result native-error] vector, never this provider value.
    :ignored-provider-result))

(def aspect-provider
  {:schema 1
   :libraries {'test/native-error-target "fixture-v1"}
   :roles {:test/native-error-around
           {:fn 'instrumentation.native-error-provider/around
            :contract :args-v1}}})
