(ns app.core
  ;; Intentionally does not require instrumentation.provider. The selected
  ;; provider must become a compiler-supplied closed-world build root.
  (:require [app.target :as target]
            [jolt.aspects :as aspects]))

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
