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
