(ns jolt.sandbox
  "JS0 experimental trusted facade over a persistent, closed SCI Context.

   This namespace is not loaded by Jolt's normal evaluator.  Requiring it needs
   the vendored SCI source and its declared dependencies on Jolt's source roots."
  (:require [sci.core :as sci]
            [jolt.host]))

;; These names are denied even if a future SCI default adds them.  Jolt host
;; namespaces are not supplied to SCI at all; denial is defense in depth, not a
;; substitute for the projection boundary below.
(def ^:private denied
  '[eval load-string load-reader require use import new proxy reify
    alter-var-root var-set intern set!
    jolt.host jolt.eval jolt.ffi jolt.process jolt.fs jolt.nrepl
    System Runtime Class Thread])

(defn- inert [x]
  ;; Receipts may only carry values whose replay does not reintroduce a live host
  ;; object.  Map keys are canonicalized too; map equality is order-independent.
  (cond
    (or (nil? x) (boolean? x) (string? x) (number? x) (keyword? x) (symbol? x)) x
    (vector? x) (mapv inert x)
    (map? x) (into {} (map (fn [[k v]] [(inert k) (inert v)])) x)
    (seq? x) (mapv inert x)
    :else (throw (ex-info "Semantic operation returned an unreconstructable value"
                          {:jolt.sandbox/value-type (str (type x))}))))

(defn- checked-operations [operations]
  (let [effects #{:pure :observation :actuation}
        ops (vec operations)]
    (doseq [{:keys [id name effect fn]} ops]
      (when-not (and id (symbol? name) (effects effect) (ifn? fn))
        (throw (ex-info "Invalid semantic operation descriptor"
                        {:id id :name name :effect effect}))))
    (when-not (= (count ops) (count (set (map :id ops))))
      (throw (ex-info "Duplicate semantic operation id" {})))
    ops))

(defn- receipt [id args result]
  {:op/id id :op/args (inert (vec args)) :op/result (inert result)})

(defn- error-receipt [id args error]
  {:op/id id :op/args (inert (vec args)) :op/error (str error)})

(defn- wrapper [state descriptor]
  (fn [& args]
    (let [{:keys [mode receipts cursor]} @state
          {:keys [id fn]} descriptor
          args (inert (vec args))]
      (case mode
        :normal (inert (apply fn args))
        :record (try
                  (let [result (inert (apply fn args))]
                    (swap! receipts conj (receipt id args result))
                    result)
                  (catch :default error
                    ;; A historical operation failure is just as observable as a
                    ;; result.  Record it before rethrowing so replay never calls
                    ;; the host in an attempt to rediscover it.
                    (swap! receipts conj (error-receipt id args error))
                    (throw error)))
        :replay (let [i @cursor rs @receipts]
                  (when (>= i (count rs))
                    (throw (ex-info "Replay receipt exhaustion"
                                    {:jolt.sandbox/error :exhausted :op/id id :index i})))
                  (let [r (nth rs i)]
                    (when-not (= id (:op/id r))
                      (throw (ex-info "Replay operation mismatch"
                                      {:jolt.sandbox/error :operation-mismatch
                                       :expected (:op/id r) :actual id})))
                    (when-not (= args (:op/args r))
                      (throw (ex-info "Replay operation arguments mismatch"
                                      {:jolt.sandbox/error :args-mismatch
                                       :op/id id :expected (:op/args r) :actual args})))
                    (swap! cursor inc)
                    (if (:op/error r)
                      (throw (ex-info (:op/error r)
                                      {:jolt.sandbox/error :recorded-operation-error
                                       :op/id id}))
                      (:op/result r))))))))

(defn create-context
  "Creates a persistent SCI context. Operations are trusted descriptors of the
   shape {:id keyword-or-string :name symbol :effect kw :fn host-fn}.  Only their
   wrappers are visible to model code as project/<name>."
  [operations]
  (let [operations (checked-operations operations)
        state (atom {:operations operations :mode :normal :receipts (atom []) :cursor (atom 0)})
        projected (into {} (map (fn [op] [(:name op) (wrapper state op)]) operations))
        sci-ctx (sci/init {:namespaces {'project projected} :deny denied})]
    (swap! state assoc :sci-context sci-ctx)
    state))

(defn set-mode! [state mode]
  (when-not (#{:normal :record :replay} mode)
    (throw (ex-info "Unknown sandbox mode" {:mode mode})))
  (swap! state assoc :mode mode)
  (when (= :replay mode) (reset! (:cursor @state) 0))
  state)

(defn receipts [state] @(:receipts @state))

(defn load-receipts! [state rs]
  (reset! (:receipts @state) (mapv inert rs))
  (reset! (:cursor @state) 0)
  state)

(defn evaluate!
  "Evaluates source in the same SCI Context on every invocation.  In replay mode,
   an otherwise-successful evaluation fails if it leaves historical receipts.
   `token`, when supplied, is a Jolt interrupt token and stops computation rather
   than merely ending the caller's wait."
  ([state source] (evaluate! state source nil))
  ([state source token]
   (let [run #(sci/eval-string* (:sci-context @state) source)
         value (if token (jolt.host/run-interruptible token run) (run))]
     (when (= :replay (:mode @state))
       (let [used @(:cursor @state) total (count @(:receipts @state))]
         (when-not (= used total)
           (throw (ex-info "Replay has unconsumed receipts"
                           {:jolt.sandbox/error :unconsumed
                            :consumed used :total total})))))
     value)))

(defn fork-context
  "A new SCI Context with the same authority descriptors but no definitions or
   receipts from `state`."
  [state]
  (create-context (:operations @state)))
