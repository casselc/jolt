(ns instrumentation.control-provider
  (:require [instrumentation.provider :as provider]))

(def aspect-provider
  {:schema 1
   :libraries {'test/aspect-target "fixture-v1"}
   :roles {:test/around {:fn 'instrumentation.control-provider/control
                         :contract :control-v1}}})

(defn control [join-point evaluated-args proceed]
  ;; The downstream fixture consumer checks this exact build/site tuple again.
  (provider/assert-runtime-site! join-point)
  (case (first evaluated-args)
    "control-return" "injected"
    "control-throw" (throw (ex-info "injected failure" {:kind :injected}))
    "control-replace" (proceed ["replaced"])
    (proceed)))
