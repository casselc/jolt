(ns jolt.sandbox
  "Isolated, capability-bounded evaluation over a persistent SCI Context.

   This namespace is not part of Jolt's normal evaluator and does not project
   Jolt namespaces or host handles into SCI. Requiring it needs vendored SCI and
   SCI's declared dependencies on the active source roots."
  (:require [sci.core :as sci]))

;; Positive, reviewed language surface. Special forms are included because SCI
;; also checks them when :allow is present. Deliberate exclusions include eval,
;; loading, namespace operations, host interop, doc/apropos, and letfn (which
;; expands through SCI internals outside this reviewed coordinate).
(def ^:private base-allow-vocabulary
  '#{def do fn fn* if let let* loop loop* quote recur
     defn defn- -> ->> as-> cond cond-> cond->> condp if-let if-not if-some
     some-> some->> when when-first when-let when-not when-some
     = not= not and or < <= > >= compare
     * + - / abs dec inc max min mod quot rem even? odd? neg? pos? zero?
     boolean? char? coll? contains? empty? every? fn? integer? keyword? map?
     nil? number? seq? sequential? set? some some? string? symbol? vector?
     hash-map hash-set list list* set vec vector zipmap
     assoc assoc-in dissoc get get-in update update-in merge merge-with
     select-keys keys vals find key val
     concat conj cons count distinct drop drop-last drop-while filter filterv
     first flatten frequencies group-by interleave interpose into juxt last
     map mapcat mapv nth partition partition-all peek pop range reduce
     reduce-kv remove rest reverse second seq sort sort-by split-at take
     take-last take-while
     apply comp complement constantly identity partial
     format name namespace pr-str str subs symbol keyword println})

(def profiles
  "Closed maxima for the supported ContextSpec profiles. Effects classify
   replay behavior; they never grant authority."
  {:agent/minimal
   {:profile/id :agent/minimal :profile/max-capabilities #{}}
   :agent/project-read
   {:profile/id :agent/project-read
    :profile/max-capabilities #{:project/read :project/list :project/search
                                :project/stat}}
   :agent/project-develop
   {:profile/id :agent/project-develop
    :profile/max-capabilities #{:project/read :project/list :project/search
                                :project/stat :project/edit}}})

(defn inert
  "Canonicalize a value into the receipt domain.

   Accepts nil, booleans, strings, exact integers, keywords, symbols, vectors,
   and maps recursively. Rejects ambiguous numeric values, lazy/list values,
   functions, vars, references, classes, and other live host objects."
  [x]
  (cond
    (nil? x) nil
    (boolean? x) x
    (string? x) x
    (keyword? x) x
    (symbol? x) x
    (and (integer? x) (not (float? x))) x
    (vector? x) (mapv inert x)
    (map? x) (into {}
                   (map (fn [[k v]] [(inert k) (inert v)]))
                   (sort-by (comp pr-str key) x))
    :else (throw (ex-info "Non-canonical receipt value"
                          {:jolt.sandbox/value-type (str (type x))
                           :jolt.sandbox/value (pr-str x)}))))

(defn- resolve-context-spec
  [operations {:keys [profile requested-capabilities authorized-capabilities]
               :or {requested-capabilities nil authorized-capabilities nil}}]
  (let [profile-data (get profiles profile)
        ops-by-id (into {} (map (juxt :id identity)) operations)
        op-ids (set (keys ops-by-id))]
    (when-not profile-data
      (throw (ex-info "Unknown profile"
                      {:jolt.sandbox/error :unknown-profile :profile profile})))
    (let [profile-max (:profile/max-capabilities profile-data)
          requested (set (or requested-capabilities
                             (when authorized-capabilities
                               authorized-capabilities)
                             op-ids))
          authorized (set (or authorized-capabilities requested))]
      (when-not (every? authorized requested)
        (throw (ex-info "Requested capabilities exceed authorization"
                        {:jolt.sandbox/error :over-request
                         :requested requested :authorized authorized})))
      (when-not (every? profile-max authorized)
        (throw (ex-info "Authorized capabilities exceed profile maximum"
                        {:jolt.sandbox/error :profile-exceeded
                         :profile profile :authorized authorized
                         :profile-max profile-max
                         :excess (remove profile-max authorized)})))
      (when-not (every? op-ids authorized)
        (throw (ex-info "Authorized capabilities not in provided operations"
                        {:jolt.sandbox/error :missing-operation
                         :authorized authorized :available op-ids
                         :missing (remove op-ids authorized)})))
      {:profile profile
       :profile-data profile-data
       :requested-capabilities requested
       :authorized-capabilities authorized
       ;; Dispatch and attestation deliberately share this single live source.
       :authorized authorized
       :operations operations})))

(defn effective-authority
  "Return an inert description of the context's current effective authority."
  [state]
  (let [{:keys [profile requested-capabilities operations authorized]} @state]
    (inert
      {:jolt.sandbox/profile (str profile)
       :jolt.sandbox/requested (vec (sort (map str requested-capabilities)))
       :jolt.sandbox/authorized (vec (sort (map str authorized)))
       :jolt.sandbox/operations
       (vec (sort-by :op/id
                     (map (fn [{:keys [id name effect]}]
                            {:op/id (str id) :op/name (str name)
                             :op/effect effect})
                          (filterv #(contains? authorized (:id %))
                                   operations))))})))

(defn- coordinate-form [x]
  (cond
    (vector? x) [:vector (mapv coordinate-form x)]
    (map? x) [:map (->> x
                         (map (fn [[k v]] [(coordinate-form k)
                                           (coordinate-form v)]))
                         (sort-by (fn [[k _]]
                                    (binding [*print-length* nil
                                              *print-level* nil]
                                      (pr-str k))))
                         vec)]
    :else x))

(defn canonical-coordinate
  "Deterministic exact coordinate for an inert authority description."
  [authority-desc]
  (str "js0:"
       (binding [*print-length* nil *print-level* nil]
         (pr-str (coordinate-form (inert authority-desc))))))

(def language-surface-version 1)

(defn language-surface
  "Trusted inert description of the static reviewed SCI language surface.
   It performs no SCI or host introspection and contains no projected handles."
  []
  (inert
    {:jolt.sandbox.surface/lang "js0-pure-sci"
     :jolt.sandbox.surface/version language-surface-version
     :jolt.sandbox.surface/count (count base-allow-vocabulary)
     :jolt.sandbox.surface/symbols
     (vec (sort (map str base-allow-vocabulary)))}))

(defn language-coordinate
  "Deterministic versioned coordinate for the reviewed pure language surface."
  []
  (str "js0-lang/v" language-surface-version ":"
       (binding [*print-length* nil *print-level* nil]
         (pr-str (coordinate-form (language-surface))))))

(defn- checked-operations [operations]
  (let [effects #{:pure :observation :actuation}
        ops (vec operations)]
    (doseq [{:keys [id name effect fn]} ops]
      (when-not (and id (symbol? name) (effects effect) (ifn? fn))
        (throw (ex-info "Invalid semantic operation descriptor"
                        {:jolt.sandbox/error :invalid-operation
                         :id id :name name :effect effect}))))
    (when-not (= (count ops) (count (set (map :id ops))))
      (throw (ex-info "Duplicate semantic operation id"
                      {:jolt.sandbox/error :duplicate-id})))
    (when-not (= (count ops) (count (set (map :name ops))))
      (throw (ex-info "Duplicate projected semantic operation name"
                      {:jolt.sandbox/error :duplicate-name})))
    ops))

(defn- receipt [id args result]
  {:op/id id :op/args (inert (vec args)) :op/result (inert result)})

(defn- error-receipt [id args error]
  {:op/id id :op/args (inert (vec args)) :op/error (str error)})

(defn- wrapper [state descriptor]
  (fn [& call-args]
    ;; This snapshot is the dispatch authorization linearization point: one call
    ;; observes one mode/transcript/authority generation. revoke! linearizes at
    ;; its state swap, so a concurrent dispatch is wholly before or after it.
    (let [{:keys [mode receipts cursor authorized]} @state
          {:keys [id effect fn]} descriptor
          _ (when-not (contains? authorized id)
              (throw (ex-info "Operation not authorized for this context"
                              {:jolt.sandbox/error :unauthorized :op/id id})))
          args (inert (vec call-args))]
      (if (= :pure effect)
        (inert (apply fn args))
        (case mode
          :normal (inert (apply fn args))
          :record
          (try
            (let [result (inert (apply fn args))]
              (swap! receipts conj (receipt id args result))
              result)
            (catch Throwable error
              (swap! receipts conj (error-receipt id args error))
              (throw error)))
          :replay
          (let [i @cursor rs @receipts]
            (when (>= i (count rs))
              (throw (ex-info "Replay receipt exhaustion"
                              {:jolt.sandbox/error :exhausted
                               :op/id id :index i})))
            (let [r (nth rs i)]
              (when-not (= id (:op/id r))
                (throw (ex-info "Replay operation mismatch"
                                {:jolt.sandbox/error :operation-mismatch
                                 :expected (:op/id r) :actual id})))
              (when-not (= args (:op/args r))
                (throw (ex-info "Replay operation arguments mismatch"
                                {:jolt.sandbox/error :args-mismatch
                                 :op/id id :expected (:op/args r)
                                 :actual args})))
              ;; Successful validation is the replay-consumption linearization
              ;; point. Replayed observation and actuation never call the host.
              (swap! cursor inc)
              (if (:op/error r)
                (throw (ex-info (:op/error r)
                                {:jolt.sandbox/error
                                 :recorded-operation-error
                                 :op/id id}))
                (:op/result r)))))))))

(defn create-context
  "Create a persistent SCI context.

   A ContextSpec enforces requested ⊆ authorized ⊆ profile maximum. Every
   supplied operation is projected as project/<name>, but every wrapper rechecks
   current effective authorization. The legacy vector form authorizes all listed
   operations under a private unprofiled compatibility maximum."
  [ops-or-spec]
  (let [legacy? (vector? ops-or-spec)
        operations (checked-operations
                     (if legacy? ops-or-spec (:operations ops-or-spec)))
        op-ids (set (map :id operations))
        resolved (if legacy?
                   {:profile :legacy/unprofiled
                    :profile-data {:profile/id :legacy/unprofiled
                                   :profile/max-capabilities op-ids}
                    :requested-capabilities op-ids
                    :authorized-capabilities op-ids
                    :authorized op-ids
                    :operations operations}
                   (resolve-context-spec operations ops-or-spec))
        state (atom (merge resolved
                           {:mode :normal
                            :receipts (atom [])
                            :cursor (atom 0)}))
        projected (into {}
                        (map (fn [op] [(:name op) (wrapper state op)])
                             operations))
        op-allow (into #{}
                       (map #(symbol "project" (str (:name %))) operations))
        sci-ctx (sci/init {:namespaces {'project projected}
                           :allow (into base-allow-vocabulary op-allow)})]
    (swap! state assoc :sci-context sci-ctx)
    state))

(defn set-mode! [state mode]
  (when-not (#{:normal :record :replay} mode)
    (throw (ex-info "Unknown sandbox mode"
                    {:jolt.sandbox/error :unknown-mode :mode mode})))
  (swap! state assoc :mode mode)
  (when (= :replay mode) (reset! (:cursor @state) 0))
  state)

(defn revoke!
  "Remove effective authority. Existing SCI Vars remain inert wrappers whose
   host-side dispatch recheck denies the revoked operation."
  [state capability]
  ;; This state swap is the revocation linearization point.
  (swap! state (fn [s]
                 (-> s
                     (update :requested-capabilities disj capability)
                     (update :authorized-capabilities disj capability)
                     (update :authorized disj capability))))
  state)

(defn receipts [state] @(:receipts @state))

(defn load-receipts! [state rs]
  (reset! (:receipts @state) (mapv inert rs))
  (reset! (:cursor @state) 0)
  state)

(defn evaluate!
  "Evaluate source in the context. Replay must consume its complete transcript.
   An optional Jolt interrupt token cooperatively stops computation."
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
  "Create an isolated SCI Context with current authority but no definitions or
   receipts from the parent. Revoked authority cannot be restored by a fork."
  [state]
  (let [s @state]
    (if (= :legacy/unprofiled (:profile s))
      (let [child (create-context (vec (:operations s)))]
        (doseq [capability (remove (:authorized s) (map :id (:operations s)))]
          (revoke! child capability))
        child)
      (create-context
        {:operations (:operations s)
         :profile (:profile s)
         :requested-capabilities
         (set (filter (:authorized s) (:requested-capabilities s)))
         :authorized-capabilities (:authorized s)}))))
