(require 'jolt.deps)

(def conflict-a
  {'fixture/provider-conflict-a
   {:local/root "test/chez/class-provider-conflict-a"}})

(def conflict-b
  {'fixture/provider-conflict-b
   {:local/root "test/chez/class-provider-conflict-b"}})

(defn conflict-data [deps]
  (try
    (jolt.deps/add-deps {:deps deps})
    nil
    (catch Throwable e (ex-data e))))

(let [before (vec (jolt.host/source-roots))
      data (conflict-data
             (into (array-map) (concat conflict-a conflict-b)))
      reversed-data (conflict-data
                      (into (array-map) (concat conflict-b conflict-a)))
      existing-origins (get-in data [:existing :origins])
      incoming-origin (get-in data [:incoming :origin])
      pass? (and (= data reversed-data)
                 (= :jolt.deps/class-provider-conflict (:type data))
                 (= "fixture.DependencyConflict" (:class data))
                 (= "fixture.provider-a"
                    (get-in data [:existing :provider]))
                 (= "fixture.provider-b"
                    (get-in data [:incoming :provider]))
                 (= 1 (count existing-origins))
                 (= :dependency (:kind (first existing-origins)))
                 (= :dependency (:kind incoming-origin))
                 (= before (vec (jolt.host/source-roots))))]
  (println "class-provider dependency conflict provenance="
           (boolean pass?))
  (System/exit (if pass? 0 1)))
