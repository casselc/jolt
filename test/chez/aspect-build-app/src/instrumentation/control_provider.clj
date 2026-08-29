(ns instrumentation.control-provider)

(def aspect-provider
  {:schema 1
   :libraries {'test/aspect-target "fixture-v1"}
   :roles {:test/around {:fn 'instrumentation.control-provider/control
                         :contract :control-v1}}})

(defn control [_join-point evaluated-args proceed]
  (case (first evaluated-args)
    "control-return" "injected"
    "control-throw" (throw (ex-info "injected failure" {:kind :injected}))
    "control-replace" (proceed ["replaced"])
    (proceed)))
