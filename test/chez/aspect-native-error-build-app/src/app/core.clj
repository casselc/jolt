(ns app.core
  (:require [app.native-error :as native-error]))

(defn -main [& _]
  ;; Three executions of one selected call site overflow the four-event journal.
  ;; The result vector proves advice cannot replace or reshape atomic capture.
  (let [results [(native-error/captured-failure 1 41)
                 (native-error/captured-failure 1 42)
                 (native-error/captured-failure 1 43)]]
    (println (str "results " (pr-str results)))))
