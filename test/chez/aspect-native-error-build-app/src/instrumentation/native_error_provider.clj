(ns instrumentation.native-error-provider)

(def ^:private journal-limit 4)
(def ^:private journal (atom []))

(defn- record! [event]
  (swap! journal
         (fn [events]
           (->> (conj events event)
                (take-last journal-limit)
                vec))))

(defn around [join-point evaluated-args proceed]
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
