(ns app.core
  ;; Intentionally does not require instrumentation.provider. The selected
  ;; provider must become a compiler-supplied closed-world build root.
  (:require [app.target :as target]))

(defn evaluated-argument [x]
  (println "argument")
  x)

(defn -main [& args]
  (let [x (or (first args) "ok")]
    (try
      (println (str "result " (target/operation (evaluated-argument x))))
      (catch Exception e
        (println (str "caught " (ex-message e) " " (:kind (ex-data e))))))))
