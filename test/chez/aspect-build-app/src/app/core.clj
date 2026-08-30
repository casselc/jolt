(ns app.core
  ;; Intentionally does not require instrumentation.provider. The selected
  ;; provider must become a compiler-supplied closed-world build root.
  (:require [app.target :as target]
            [clojure.core.async :as async]
            [jolt.aspects :as aspects]))

;; A real compiler-visible primitive effect keeps the build evidence's positive
;; semantic signal non-vacuous.  The binding is not invoked by the fixture; its
;; typed callable contract alone must produce a precise :native-block summary.
(def c-usleep (jolt.ffi/__cfn "usleep" [:uint] :int :blocking))

(defn precise-native-effect []
  (c-usleep 0))

;; Real macroexpanded execution-transfer evidence. The body is never invoked by
;; the fixture binary, but the compiler must still retain it as a deferred
;; subject: scheduling is immediate; the native block happens on the selected
;; go carrier later.
(defn scheduled-native-effect []
  (async/go (precise-native-effect)))

(defn evaluated-argument [x]
  (println "argument")
  x)

(defn unmarked-operation [x]
  ;; The generated marker selector must not broaden to every otherwise
  ;; identical call in this namespace.
  (target/operation x))

(comment
  ;; Manifest discovery follows macro expansion. This syntax is discarded by
  ;; comment and must never become a published join point.
  (aspects/at {:id :test/discarded :role :test/around}
    (target/operation "discarded")))

(defn -main [& args]
  (when (some #(contains? (meta #'target/callback) %)
              [:jolt.aspects/id :jolt.aspects/role :jolt.aspects/arity])
    (throw (ex-info "compiler-only aspect metadata leaked into runtime Var metadata"
                    {:metadata (meta #'target/callback)})))
  (let [x (or (first args) "ok")]
    (try
      (if (= x "entry-number")
        (println (str "result "
                      (target/invoke-callback target/numeric-callback 40)))
        (let [result (aspects/at
                      {:id :test/target-call :role :test/around}
                      (target/operation (evaluated-argument x)))
              callback-input (cond
                               (= x "entry-recur") "recur"
                               (= x "entry-throw") "throw"
                               :else result)]
          (println (str "result "
                        (target/invoke-callback target/callback callback-input)))))
      (catch Exception e
        (println (str "caught " (ex-message e) " " (:kind (ex-data e))))))))
