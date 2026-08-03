(ns app.core)

(defn -main [& _]
  (println [(+ 20 22)
            @(future (+ 40 2))
            (integer? (jolt.host/mono-nanos))]))
