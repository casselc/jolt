(ns instrumentation.incomplete-provider)

(def aspect-provider
  {:schema 1
   :libraries {'test/aspect-target "fixture-v1"}
   ;; Deliberately lacks both entry roles for the fail-closed resolver proof.
   :roles {:test/around 'instrumentation.incomplete-provider/around}})

(defn around [_join-point proceed]
  (proceed))
