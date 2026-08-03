(ns runtime-eval.core
  (:require [jolt.ffi]))

(defn -main [& _]
  (let [token
        (jolt.internal.sim/install-controller!
         {:future (fn [_event _task _parent] nil)
          :ffi (fn [descriptor proceed]
                 (if (= "jolt_v0517_runtime_eval_missing" (:symbol descriptor))
                   909
                   (proceed)))
          :clock (fn [_descriptor proceed] (proceed))})]
    (try
      ;; This defcfn is analyzed/emitted by the compiler embedded in the built
      ;; application, not by the sim compiler that built the app.
      (eval '(def runtime-missing
               (jolt.ffi/__cfn
                "jolt_v0517_runtime_eval_missing" [:int32] :int64)))
      (let [f (resolve 'runtime-missing)
            result (f 7)]
        (if (= 909 result)
          (println "sim runtime eval: modeled missing symbol")
          (do (println "FAIL: unexpected runtime-eval result" result)
              (System/exit 1))))
      (finally
        (jolt.internal.sim/restore-controller! token)))))
