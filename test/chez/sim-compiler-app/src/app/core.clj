(ns app.core
  (:require [jolt.ffi :as ffi]))

(ffi/load-library)
(ffi/defcfn c-abs "abs" [:int] :int)
(ffi/defcfn c-abs-blocking "abs" [:int] :int :blocking)

(defn -main [& _]
  (println [(c-abs -40)
            (c-abs-blocking -2)
            @(future (+ 20 22))]))
