(ns app.core
  (:require [jolt.checkpoints :as checkpoints]))

(defn checkpointed []
  (do
    (checkpoints/checkpoint! :test.erasure/site #{:continue})
    "ok"))

(defn -main [& _]
  (println (checkpointed)))
