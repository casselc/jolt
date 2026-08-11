;; Focused self-checking gate for the socket-free evaluator and the public
;; nREPL compatibility adapter. A persistent adapter owns history bindings but
;; deliberately does not bind *ns*: `:ns` and the returned `:ns` are the sole
;; namespace coordinate across evaluations.
(ns jolt.eval-engine-test
  (:require [jolt.eval]
            [jolt.nrepl]))

(def failures (atom []))

(defn check [label expected actual]
  (when-not (= expected actual)
    (swap! failures conj [label expected actual])))

(defn start-session []
  (atom {:ns "jolt.eval-engine-test"
         :one :old-1
         :two :old-2
         :three :old-3
         :error nil}))

(defn session-evaluate! [session code]
  (let [{:keys [ns one two three error]} @session]
    ;; Do not add *ns* here. Jolt's evaluator owns its runtime namespace
    ;; coordinate; binding *ns* would mask an in-ns/ns change on v0.7.1.
    (binding [*1 one *2 two *3 three *e error]
      (let [result (jolt.eval/evaluate
                    {:code code
                     :ns ns
                     :allow-unresolved-vars? false
                     :capture-out? true
                     :capture-err? true})]
        (jolt.eval/record-history! :thread result)
        (reset! session {:ns (:ns result)
                         :one *1
                         :two *2
                         :three *3
                         :error *e})
        result))))

;; Exact raw value, streams, timing, and thread-local history.
(let [session (start-session)
      form "(do (print \"stdout\") (binding [*out* *err*] (print \"stderr\")) {:answer 42})"
      result (session-evaluate! session form)]
  (check :success-status :ok (:status result))
  (check :raw-value {:answer 42} (:value result))
  (check :exact-form form (:form result))
  (check :stdout "stdout" (:out result))
  (check :stderr "stderr" (:err result))
  (check :elapsed true (and (integer? (:ms result))
                            (not (neg? (:ms result)))))
  (check :success-shape [nil nil] [(:exception result) (:backtrace result)])
  (check :success-history [{:answer 42} :old-1 :old-2]
         (mapv @session [:one :two :three])))

;; A namespace-changing form must move the coordinate returned to the session;
;; later defs and reads resolve there without any host dynamic-binding patch.
(let [session (start-session)
      ns-result (session-evaluate! session "(ns jolt.eval-engine-session-target)")
      def-result (session-evaluate! session "(def answer 42)")
      value-result (session-evaluate! session "answer")
      error-result (session-evaluate!
                    session
                    "(throw (ex-info \"session-boom\" {:session true}))")
      before-recovery @session
      recovery-result (session-evaluate! session "[answer *1 (ex-data *e)]")]
  (check :session-ns-status :ok (:status ns-result))
  (check :session-ns-coordinate "jolt.eval-engine-session-target" (:ns ns-result))
  (check :session-ns-persisted "jolt.eval-engine-session-target" (:ns @session))
  (check :session-def-status :ok (:status def-result))
  (check :session-def-resolves 42 (:value value-result))
  (check :session-error-status :error (:status error-result))
  (check :session-error-ns "jolt.eval-engine-session-target" (:ns error-result))
  (check :session-error-keeps-success-history 42 (:one before-recovery))
  (check :session-error-history {:session true} (ex-data (:error before-recovery)))
  (check :session-recovery [42 42 {:session true}] (:value recovery-result)))
(in-ns 'jolt.eval-engine-test)

;; Exercise in-ns independently of the ns macro.
(let [session (start-session)
      result (session-evaluate! session "(in-ns 'jolt.eval-engine-in-ns-target)")
      _ (session-evaluate! session "(def in-ns-answer 43)")
      value-result (session-evaluate! session "in-ns-answer")]
  (check :session-in-ns-status :ok (:status result))
  (check :session-in-ns-coordinate "jolt.eval-engine-in-ns-target" (:ns result))
  (check :session-in-ns-resolves 43 (:value value-result)))
(in-ns 'jolt.eval-engine-test)

;; An exception is raw, updates *e only, and captures its backtrace at the catch
;; site. A later success retains *e, as ordinary REPL history does.
(jolt.host/enable-trace!)
(let [session (start-session)
      error-result (session-evaluate!
                    session
                    "(do (defn eval-engine-boom [] (/ 1 0)) (eval-engine-boom))")
      error (:exception error-result)
      success-result (session-evaluate! session "(+ 20 22)")]
  (check :error-status :error (:status error-result))
  (check :error-value nil (:value error-result))
  (check :raw-exception true (some? error))
  (check :error-history error (:error @session))
  (check :backtrace-captured true
         (and (string? (:backtrace error-result))
              (not= "" (:backtrace error-result))))
  (check :recovery-status :ok (:status success-result))
  (check :error-survives-success error (:error @session)))

;; Uncaptured streams retain the caller's live writers.
(let [out-writer (java.io.StringWriter.)
      err-writer (java.io.StringWriter.)
      result (binding [*out* out-writer *err* err-writer]
               (jolt.eval/evaluate
                {:code "(do (print \"live-out\") (binding [*out* *err*] (print \"live-err\")) :ok)"
                 :ns "jolt.eval-engine-test"
                 :allow-unresolved-vars? false
                 :capture-out? false
                 :capture-err? false}))]
  (check :uncaptured-result [nil nil] [(:out result) (:err result)])
  (check :live-out "live-out" (str out-writer))
  (check :live-err "live-err" (str err-writer)))

;; The public nREPL adapter retains its exact wire-facing shape and stringifies
;; the raw value only at that boundary.
(let [result (jolt.nrepl/evaluate
              "(do (print \"wire\") {:answer 42})"
              "jolt.eval-engine-test")]
  (check :nrepl-keys #{:value :out :ns :err} (set (keys result)))
  (check :nrepl-value "{:answer 42}" (:value result))
  (check :nrepl-out "wire" (:out result))
  (check :nrepl-ns "jolt.eval-engine-test" (:ns result))
  (check :nrepl-error nil (:err result)))

;; The refactored nREPL error boundary retains the existing closed wire shape,
;; installs the raw exception in root *e*, and publishes the matching backtrace
;; before a tooling watch can observe that exception.
(let [result (jolt.nrepl/evaluate
              (str "(do (print \"before-boom\") "
                   "(defn nrepl-error-trace [] "
                   "(throw (ex-info \"nrepl-boom\" {:nrepl true}))) "
                   "(nrepl-error-trace))")
              "jolt.eval-engine-test")
      installed-error *e]
  (check :nrepl-error-keys #{:value :out :ns :err} (set (keys result)))
  (check :nrepl-error-value nil (:value result))
  (check :nrepl-error-out "before-boom" (:out result))
  (check :nrepl-error-ns "jolt.eval-engine-test" (:ns result))
  (check :nrepl-error-string true
         (and (string? (:err result))
              (not= "" (:err result))))
  (check :nrepl-error-history {:nrepl true} (ex-data installed-error))
  (check :nrepl-error-backtrace true
         (let [backtrace (jolt.nrepl/last-error-backtrace)]
           (and (string? backtrace) (not= "" backtrace))))
  (let [success (jolt.nrepl/evaluate "(+ 20 22)" "jolt.eval-engine-test")]
    (check :nrepl-success-after-error "42" (:value success))
    (check :nrepl-error-survives-success installed-error *e)))

(let [observed (atom nil)
      old-backtrace (jolt.nrepl/last-error-backtrace)
      watch-key ::backtrace-order]
  (add-watch #'*e watch-key
             (fn [_ _ _ new-error]
               (when (= {:watch-order true} (ex-data new-error))
                 (reset! observed (jolt.nrepl/last-error-backtrace)))))
  (try
    (jolt.nrepl/evaluate
     (str "(do (defn nrepl-watch-trace [] "
          "(throw (ex-info \"watch-order\" {:watch-order true}))) "
          "(nrepl-watch-trace))")
     "jolt.eval-engine-test")
    (check :nrepl-watch-saw-new-frame true
           (and (string? @observed)
                (some? (re-find #"nrepl-watch-trace" @observed))))
    (check :nrepl-watch-did-not-see-old-trace false
           (= old-backtrace @observed))
    (finally (remove-watch #'*e watch-key))))

;; Blank and unknown requested namespaces remain compatibility no-ops. They do
;; not create a namespace or replace the evaluator's current coordinate.
(let [before (str (ns-name *ns*))
      blank (jolt.nrepl/evaluate "7" "   ")
      missing-name "jolt.eval-engine-missing-target"
      missing (jolt.nrepl/evaluate "8" missing-name)]
  (check :nrepl-blank-ns before (:ns blank))
  (check :nrepl-unknown-ns before (:ns missing))
  (check :nrepl-unknown-ns-not-created nil (find-ns (symbol missing-name))))

(if (empty? @failures)
  (println "EVAL-ENGINE OK")
  (do (doseq [[label expected actual] @failures]
        (println "eval-engine FAIL" label
                 "expected" (pr-str expected)
                 "actual" (pr-str actual)))
      (println "EVAL-ENGINE FAIL" (count @failures))))
