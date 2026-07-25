(ns cpapp.undeclared)

;; A closed build must reject application/provider ownership that was not part
;; of the reconciled dependency metadata, before it can enter the flat program.
(jolt.host/register-class-providers!
  {"fixture.BuildTimeUndeclared" 'cpfixture.missing-provider})

(defn -main [& _]
  (println "undeclared provider mapping escaped build freeze"))
