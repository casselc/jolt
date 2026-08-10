;; Self-checking focused gate for the socket-free evaluation engine and the
;; public nREPL compatibility adapter. Runs as a multi-form source file so the
;; new namespaces are loaded from the current Jolt tree.
(ns jolt.eval-engine-test
  (:require [jolt.eval]
            [jolt.nrepl]))

(def failures (atom []))

(defn check [label expected actual]
  (when-not (= expected actual)
    (swap! failures conj [label expected actual])))

;; A minimal persistent adapter: it owns the dynamic namespace/history values,
;; delegates one exact form to jolt.eval, then commits the evaluator's explicit
;; post-form namespace coordinate and the updated history for its next call.
;; This is deliberately test scaffolding, not another public REPL API.
(defn start-session []
  (atom {:namespace (the-ns 'jolt.eval-engine-test)
         :one :session-old-1
         :two :session-old-2
         :three :session-old-3
         :error nil}))

(defn session-evaluate! [session code]
  (let [{:keys [namespace one two three error]} @session]
    (binding [*ns* namespace
              *1 one
              *2 two
              *3 three
              *e error]
      (let [result (jolt.eval/evaluate
                    {:code code
                     :ns (str (ns-name *ns*))
                     :allow-unresolved-vars? false
                     :capture-out? true
                     :capture-err? true})]
        (jolt.eval/record-history! :thread result)
        (reset! session {:namespace (the-ns (symbol (:ns result)))
                         :one *1
                         :two *2
                         :three *3
                         :error *e})
        result))))

(binding [*1 :old-1 *2 :old-2 *3 :old-3 *e nil]
  (let [form "(do (print \"stdout\") (binding [*out* *err*] (print \"stderr\")) {:answer 42})"
        result (jolt.eval/evaluate
                {:code form
                 :ns "jolt.eval-engine-test"
                 :allow-unresolved-vars? false
                 :capture-out? true
                 :capture-err? true})]
    (jolt.eval/record-history! :thread result)
    (check :success-status :ok (:status result))
    (check :raw-value {:answer 42} (:value result))
    (check :exact-form form (:form result))
    (check :namespace "jolt.eval-engine-test" (:ns result))
    (check :stdout "stdout" (:out result))
    (check :stderr "stderr" (:err result))
    (check :elapsed true (and (integer? (:ms result))
                              (not (neg? (:ms result)))))
    (check :success-exception nil (:exception result))
    (check :success-backtrace nil (:backtrace result))
    (check :history-success [{:answer 42} :old-1 :old-2]
           [*1 *2 *3]))

  (jolt.host/enable-trace!)
  (let [form "(do (defn eval-engine-boom [] (/ 1 0)) (eval-engine-boom))"
        result (jolt.eval/evaluate
                 {:code form
                 :allow-unresolved-vars? false
                 :capture-out? true
                 :capture-err? true})]
    (jolt.eval/record-history! :thread result)
    (check :error-status :error (:status result))
    (check :error-value nil (:value result))
    (check :raw-exception true (some? (:exception result)))
    (check :history-error (:exception result) *e)
    (check :error-form form (:form result))
    (check :backtrace-captured true
           (and (string? (:backtrace result))
                (not= "" (:backtrace result))))))

;; When capture is disabled the caller's live writers receive the output and
;; the result reports no captured stream.
(let [out-writer (java.io.StringWriter.)
      err-writer (java.io.StringWriter.)
      result (binding [*out* out-writer *err* err-writer]
               (jolt.eval/evaluate
                {:code "(do (print \"live-out\") (binding [*out* *err*] (print \"live-err\")) :ok)"
                 :allow-unresolved-vars? false
                 :capture-out? false
                 :capture-err? false}))]
  (check :uncaptured-out nil (:out result))
  (check :uncaptured-err nil (:err result))
  (check :live-out "live-out" (str out-writer))
  (check :live-err "live-err" (str err-writer)))

;; An explicit loaded namespace is selected and reported.
(create-ns 'jolt.eval-engine-target)
(let [result (jolt.eval/evaluate
              {:code "(+ 20 22)"
               :ns "jolt.eval-engine-target"
               :allow-unresolved-vars? false
               :capture-out? true
               :capture-err? true})]
  ;; `in-ns` takes effect while this form is evaluating on Jolt, so qualify the
  ;; already-defined checker for the remainder of this enclosing form.
  (jolt.eval-engine-test/check
   :selected-namespace "jolt.eval-engine-target" (:ns result))
  (jolt.eval-engine-test/check :selected-value 42 (:value result)))
(in-ns 'jolt.eval-engine-test)

;; Namespace-changing forms execute inside a real session-owned *ns* binding.
;; The evaluator must report the namespace before its private capture bindings
;; unwind; the adapter persists that explicit coordinate across calls.
(let [session (start-session)
      ns-result (session-evaluate! session "(ns jolt.eval-engine-session-target)")
      def-result (session-evaluate! session "(def answer 42)")
      value-result (session-evaluate! session "answer")
      error-result (session-evaluate!
                    session
                    "(throw (ex-info \"session-boom\" {:session true}))")
      history-before-recovery (select-keys @session [:one :two :three :error])
      recovery-result (session-evaluate! session "[answer *1 (ex-data *e)]")]
  (check :session-ns-status :ok (:status ns-result))
  (check :session-ns-coordinate
         "jolt.eval-engine-session-target" (:ns ns-result))
  (check :session-ns-persisted
         "jolt.eval-engine-session-target"
         (str (ns-name (:namespace @session))))
  (check :session-def-status :ok (:status def-result))
  (check :session-def-resolves 42 (:value value-result))
  (check :session-error-status :error (:status error-result))
  (check :session-error-namespace
         "jolt.eval-engine-session-target" (:ns error-result))
  (check :session-error-keeps-success-history
         [42 'answer "jolt.eval-engine-session-target"
          "jolt.eval-engine-session-target"]
         [(:one history-before-recovery)
          (:name (meta (:two history-before-recovery)))
          (str (ns-name (:ns (meta (:two history-before-recovery)))))
          (str (ns-name (:three history-before-recovery)))])
  (check :session-error-history
         {:session true}
         (ex-data (:error history-before-recovery)))
  (check :session-recovery-status :ok (:status recovery-result))
  (check :session-recovery-value
         [42 42 {:session true}] (:value recovery-result))
  (check :session-recovery-namespace
         "jolt.eval-engine-session-target" (:ns recovery-result)))
(in-ns 'jolt.eval-engine-test)

;; in-ns has the same continuation semantics as ns. Exercise it independently
;; so a later macro-only workaround cannot accidentally satisfy this gate.
(let [session (start-session)
      result (session-evaluate!
              session "(in-ns 'jolt.eval-engine-in-ns-target)")
      def-result (session-evaluate! session "(def in-ns-answer 43)")
      value-result (session-evaluate! session "in-ns-answer")]
  (check :session-in-ns-status :ok (:status result))
  (check :session-in-ns-coordinate
         "jolt.eval-engine-in-ns-target" (:ns result))
  (check :session-in-ns-def-status :ok (:status def-result))
  (check :session-in-ns-resolves 43 (:value value-result)))
(in-ns 'jolt.eval-engine-test)

;; Root history is the existing nREPL contract. Restore it so this focused file
;; does not leak its probe into later smoke cases.
(let [old-1 *1 old-2 *2 old-3 *3 old-e *e]
  (try
    (let [result (jolt.eval/evaluate
                  {:code "43"
                   :allow-unresolved-vars? true
                   :capture-out? true
                   :capture-err? false})]
      (jolt.eval/record-history! :root result)
      (check :root-status :ok (:status result))
      (check :root-history 43 *1))
    (let [result (jolt.eval/evaluate
                  {:code "(throw (ex-info \"root-boom\" {:root true}))"
                   :allow-unresolved-vars? true
                   :capture-out? true
                   :capture-err? false})]
      (jolt.eval/record-history! :root result)
      (check :root-error-status :error (:status result))
      (check :root-error-history (:exception result) *e))
    (finally
      (alter-var-root #'*1 (constantly old-1))
      (alter-var-root #'*2 (constantly old-2))
      (alter-var-root #'*3 (constantly old-3))
      (alter-var-root #'*e (constantly old-e)))))

;; The public nREPL evaluator retains its exact result shape and stringifies the
;; raw value only at the adapter boundary.
(let [result (jolt.nrepl/evaluate
              "(do (print \"wire\") {:answer 42})" nil)]
  (check :nrepl-keys #{:value :out :ns :err} (set (keys result)))
  (check :nrepl-value "{:answer 42}" (:value result))
  (check :nrepl-out "wire" (:out result))
  (check :nrepl-ns "jolt.eval-engine-test" (:ns result))
  (check :nrepl-error nil (:err result)))

(let [result (jolt.nrepl/evaluate
              "(do (defn nrepl-old-trace [] (throw (ex-info \"nrepl-boom\" {:nrepl true}))) (nrepl-old-trace))"
              nil)]
  (check :nrepl-error-value nil (:value result))
  (check :nrepl-error-out "" (:out result))
  (check :nrepl-error-ns "jolt.eval-engine-test" (:ns result))
  (check :nrepl-error-string true
         (and (string? (:err result)) (not= "" (:err result))))
  (check :nrepl-error-history true
         (= {:nrepl true} (ex-data *e)))
  (check :nrepl-error-backtrace true
         (let [backtrace (jolt.nrepl/last-error-backtrace)]
           (and (string? backtrace) (not= "" backtrace)))))

;; *e watches used by tooling must observe the trace for the exception being
;; installed, never the stale trace from the preceding failure.
(let [observed (atom nil)
      old-backtrace (jolt.nrepl/last-error-backtrace)
      watch-key ::backtrace-order]
  (add-watch #'*e watch-key
             (fn [_ _ _ new-error]
               (when (= {:watch-order true} (ex-data new-error))
                 (reset! observed (jolt.nrepl/last-error-backtrace)))))
  (try
    (jolt.nrepl/evaluate
     "(do (defn nrepl-watch-trace [] (throw (ex-info \"watch-order\" {:watch-order true}))) (nrepl-watch-trace))"
     nil)
    (check :nrepl-watch-saw-new-frame true
           (and (string? @observed)
                (some? (re-find #"nrepl-watch-trace" @observed))))
    (check :nrepl-watch-did-not-see-old-trace false
           (= old-backtrace @observed))
    (finally (remove-watch #'*e watch-key))))

;; Preserve the prior nREPL behavior for blank namespace request values: ignore
;; them instead of trying to resolve a whitespace symbol.
(let [before (str (ns-name *ns*))
      result (jolt.nrepl/evaluate "7" "   ")]
  (check :nrepl-blank-ns before (:ns result)))

(if (empty? @failures)
  (println "EVAL-ENGINE OK")
  (do (doseq [[label expected actual] @failures]
        (println "eval-engine FAIL" label
                 "expected" (pr-str expected)
                 "actual" (pr-str actual)))
      (println "EVAL-ENGINE FAIL" (count @failures))))
