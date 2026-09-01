(ns instrumentation.native-error-audit-provider
  (:require [instrumentation.native-error-provider :as primary]))

(def ^:private journal-limit 4)
(def ^:private journal (atom []))

(defn- record! [event]
  (swap! journal
         (fn [events]
           (->> (conj events event)
                (take-last journal-limit)
                vec))))

(defn around [join-point evaluated-args proceed]
  (primary/assert-runtime-site! join-point)
  (record! [:audit-enter (:id join-point) evaluated-args])
  (let [value (proceed)]
    (record! [:audit-return (:id join-point) value])
    (println (str "audit-journal " (pr-str @journal)))
    :ignored-audit-result))

(def aspect-provider
  {:schema 1
   :libraries {'test/native-error-target "fixture-v1"}
   :roles {:test/native-error-around
           {:fn 'instrumentation.native-error-audit-provider/around
            :contract :args-v1}}})
