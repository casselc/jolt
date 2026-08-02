(ns sim-controller-image-test
  (:require [jolt.ffi :as ffi]))

(ffi/load-library nil)
(ffi/defcfn missing-native "jolt_v0513_missing_native_symbol" [:int32] :int64)
(ffi/defcfn close-captured "close" [:int32] :int32
  {:capture-native-error true})

(def failures (atom []))
(defn check [label pred]
  (when-not pred (swap! failures conj label)))

(defn -main [& _]
  (check "sim image exports no independent subcontroller installers"
         (every? nil?
                 (map resolve
                      '[jolt.internal.sim/install-ffi-controller!
                        jolt.internal.sim/install-ffi-routing-controller!
                        jolt.internal.sim/restore-ffi-controller!
                        jolt.internal.sim/install-clock-controller!
                        jolt.internal.sim/install-clock-routing-controller!
                        jolt.internal.sim/restore-clock-controller!])))
  (let [seen (atom [])
        lifecycle (atom [])
        exited (promise)
        token
        (jolt.internal.sim/install-controller!
         {:future (fn [event task parent]
                    (swap! lifecycle conj [event task parent])
                    (when (= event :exit) (deliver exited true)))
          :ffi (fn [descriptor proceed]
                 (swap! seen conj descriptor)
                 (if (= "jolt_v0513_missing_native_symbol" (:symbol descriptor))
                   77
                   (proceed)))
          :clock (fn [_descriptor _proceed] 424242)})]
    (try
      (check "one install controls future lifecycle"
             (= 42 (deref (future 42) 5000 ::future-timeout)))
      (check "future spawn was observed"
             (boolean (some #(= :spawn (first %)) @lifecycle)))
      ;; Restoration is not allowed after settlement alone; wait for the worker's
      ;; post-publication :exit acknowledgement with a bounded deadline.
      (check "future exit acknowledgement before restore"
             (= true (deref exited 5000 ::exit-timeout)))
      (check "modeled missing symbol never resolves" (= 77 (missing-native 9)))
      (let [[result native-error] (close-captured -1)
            captured (last @seen)]
        (check "native proceed result" (= -1 result))
        (check "atomic native error captured" (and (integer? native-error)
                                                    (pos? native-error)))
        (check "exact scalar widths preserved"
               (= [[:int32] :int32 true]
                  [(:argument-types captured)
                   (:return-type captured)
                   (:capture-native-error? captured)])))
      (check "central System/nanoTime interception" (= 424242 (System/nanoTime)))
      (check "host monotonic interception"
             (= 424242 (jolt.host/monotonic-nanos)))
      (check "supervisor clock bypass"
             (not= 424242 (jolt.internal.sim/supervisor-monotonic-nanos)))
      (finally
        (jolt.internal.sim/restore-controller! token))))
  (if (seq @failures)
    (do (doseq [f @failures] (println "FAIL:" f))
        (System/exit 1))
    (do (println "sim controller image: all checks passed")
        (System/exit 0))))

(apply -main *command-line-args*)
