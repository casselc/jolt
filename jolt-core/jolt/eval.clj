(ns jolt.eval
  "Socket-free evaluation semantics shared by Jolt's interactive adapters.

  `evaluate` evaluates one exact source string. Adapters choose the namespace,
  unresolved-var policy, REPL history target, and whether stdout/stderr are
  captured. The engine does not know about terminals, sockets, bencode,
  simulation, or any remote protocol.

  A persistent adapter must treat `:ns` as the sole evaluator namespace
  coordinate. In particular, it must not dynamically bind `*ns*` around this
  call: Jolt's evaluator selects and reports the namespace through its
  thread-local runtime coordinate, while the adapter persists the returned
  `:ns` for the next call."
  (:require [clojure.string :as str]))

(defn err-msg
  "Best-effort message for an exception or raw Chez condition."
  [e]
  (or (ex-message e)
      (try ((resolve 'jolt.host/condition-message) e)
           (catch :default _ nil))
      (pr-str e)))

(defn record-history!
  "Records one `evaluate` result in thread-local or root REPL history.

  Kept separate from evaluation so an adapter's output-capture lifetime ends
  before Var watches run during history mutation."
  [history-mode {:keys [status value exception]}]
  (case history-mode
    :thread
    (if (= :error status)
      (var-set #'*e exception)
      (do (var-set #'*3 *2)
          (var-set #'*2 *1)
          (var-set #'*1 value)))

    :root
    (if (= :error status)
      (alter-var-root #'*e (constantly exception))
      (do (alter-var-root #'*3 (constantly *2))
          (alter-var-root #'*2 (constantly *1))
          (alter-var-root #'*1 (constantly value))))

    nil nil
    (throw (ex-info "Unknown Jolt evaluation history mode"
                    {:type ::invalid-history-mode
                     :history-mode history-mode}))))

(defn evaluate
  "Evaluates one exact source string and returns a closed result map.

  Options:

  - `:code` is the source string;
  - `:ns` selects an already-loaded namespace when present;
  - `:allow-unresolved-vars?` selects the analyzer policy; and
  - `:capture-out?` / `:capture-err?` capture the corresponding stream.

  A successful result contains the raw value under `:value`; an error contains
  the raw thrown value under `:exception` and the backtrace captured at the
  catch site. Uncaptured streams retain their caller bindings and remain live."
  [{:keys [code ns allow-unresolved-vars? capture-out? capture-err?]}]
  (when-not (string? code)
    (throw (ex-info "Jolt evaluation code must be a string"
                    {:type ::invalid-code
                     :value-class (str (class code))})))
  (let [out-writer (when capture-out? (java.io.StringWriter.))
        err-writer (when capture-err? (java.io.StringWriter.))
        started (System/nanoTime)
        result
        (binding [*out* (or out-writer *out*)
                  *err* (or err-writer *err*)
                  *allow-unresolved-vars* (boolean allow-unresolved-vars?)]
          (try
            ;; Preserve jolt.nrepl's current behavior: an unknown requested
            ;; namespace is ignored rather than created or rejected.
            (when (and ns (not (str/blank? ns)) (find-ns (symbol ns)))
              (in-ns (symbol ns)))
            {:status :ok
             :value (load-string code)
             :exception nil
             :backtrace nil}
            (catch :default e
              {:status :error
               :value nil
               :exception e
               :backtrace (jolt.host/backtrace-string)})))
        elapsed-ms (quot (- (System/nanoTime) started) 1000000)]
    (assoc result
           :form code
           :ns (str (ns-name *ns*))
           :ms elapsed-ms
           :out (when out-writer (str out-writer))
           :err (when err-writer (str err-writer)))))
