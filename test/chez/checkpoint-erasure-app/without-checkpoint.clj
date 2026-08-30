(ns app.core
  (:require [jolt.checkpoints :as checkpoints]))

(defn checkpointed []
  (do
    ;; The production checkpoint declaration is absent on this source line.
    "ok"))

(defn -main [& _]
  (println (checkpointed)))
