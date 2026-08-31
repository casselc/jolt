(ns app.core
  (:require [jolt.checkpoints :as checkpoints]))

(defn checkpointed []
  (do
    (checkpoints/checkpoint! :test.erasure/site #{:continue :yield :barrier :fault :cancel})
    "ok"))

(defn -main [& _]
  (println (checkpointed)))
