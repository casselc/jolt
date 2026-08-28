(ns app.core
  ;; Intentionally does not require instrumentation.provider. The selected
  ;; provider must become a compiler-supplied closed-world build root.
  (:require [app.target :as target]))

(defn -main [& args]
  (let [x (or (first args) "ok")]
    (println "argument")
    (try
      (println (str "result " (target/operation x)))
      (catch Exception e
        (println (str "caught " (ex-message e) " " (:kind (ex-data e))))))))
