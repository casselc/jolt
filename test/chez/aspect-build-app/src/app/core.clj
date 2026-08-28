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
      (if (= x "entry-number")
        (println (str "result "
                      (target/invoke-callback target/numeric-callback 40)))
        (let [result (target/operation (evaluated-argument x))
              callback-input (cond
                               (= x "entry-recur") "recur"
                               (= x "entry-throw") "throw"
                               :else result)]
          (println (str "result "
                        (target/invoke-callback target/callback callback-input)))))
      (catch Exception e
        (println (str "caught " (ex-message e) " " (:kind (ex-data e))))))))
