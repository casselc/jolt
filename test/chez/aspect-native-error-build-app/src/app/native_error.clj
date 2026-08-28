(ns app.native-error
  (:require [jolt.ffi :as ffi]))

(ffi/defcfn block-fail
  "jolt_ne_block_fail"
  [:uint32 :int]
  :int
  {:blocking true :capture-native-error true})

(defn captured-failure [millis code]
  ;; The manifest selects this resolved foreign invocation, rather than the
  ;; ordinary Clojure wrapper call in app.core.
  (block-fail millis code))
