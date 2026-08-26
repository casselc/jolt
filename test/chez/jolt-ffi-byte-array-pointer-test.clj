(ns jolt-ffi-byte-array-pointer-test
  (:require [jolt.fibers :as fib]
            [jolt.ffi :as ffi]))

(def failures (atom []))
(defmacro check [label expr]
  `(when-not ~expr (swap! failures conj ~label)))

;; A fiber park switches through the host dynamic-wind that owns the native
;; pointer. The first exit must copy back and unlock; resumption must fail before
;; callback code can observe the retired address. Keep this in a public Jolt
;; test rather than the Scheme gate-boot evaluator so it exercises the real
;; fiber namespace and the exception that a library caller sees.
(let [a (byte-array [1 2])
      resumed? (atom false)
      result
      (try
        (fib/join
          (fib/spawn
            (fn []
              (ffi/with-byte-array-pointer
                a :out
                (fn [p _]
                  (ffi/write p :uint8 0 202)
                  (fib/yield)
                  (reset! resumed? true))))))
        :did-not-throw
        (catch Throwable e
          [(.getName (class e)) (ex-message e)]))]
  (check "parked callback cleanup and rejection"
         (and (= ["java.lang.IllegalStateException"
                  "jolt.ffi: scoped byte-array pointer continuation cannot be re-entered"]
                 result)
              (= [-54 0] (vec a))
              (false? @resumed?))))

(if (empty? @failures)
  (do (println "JOLT-FFI-BYTE-ARRAY-POINTER-TEST OK")
      (flush)
      (System/exit 0))
  (do (doseq [failure @failures] (println "FAIL:" failure))
      (flush)
      (System/exit 1)))
