(ns jolt.sandbox
  "JS0 data-driven ContextSpec authority model over a persistent, closed SCI Context.

   This namespace provides an authority-controlled evaluation context built on
   SCI.  It replaces the deny-list approach with a positive :allow list for the
   pure language vocabulary, and adds ContextSpec profiles for capability
   management.

   This namespace is not loaded by Jolt's normal evaluator.  Requiring it needs
   the vendored SCI source and its declared dependencies on Jolt's source roots."
  (:require [sci.core :as sci]))

;; ═══════════════════════════════════════════════════════════════════════════
;; Pure language vocabulary — explicit positive allow-list
;; ═══════════════════════════════════════════════════════════════════════════

(def ^:private base-allow-vocabulary
  "Explicit positive allow-list of symbols the SCI context may resolve.
   Based on Jolt-supported bb4t base allow semantics.  Every symbol here
   is pure: it computes over inert values and reaches nothing.

   Special forms (def, fn, if, let, do) are handled by the SCI analyzer
   before the permission gate, but are listed here for explicitness and
   defense in depth — SCI's check-permission! also gates them when :allow
   is set.

   Deliberately excluded from bb4t base-allow-core:
      apropos, doc — introspect the SCI context, leaking available surface
      clojure.string/* — require namespace alias setup not provided here
      letfn — SCI expands it through internal -new-var, which is not part of
               the reviewed pure surface on this SCI/Jolt coordinate"
  '#{;; special forms and binding
      def do fn fn* if let let* loop loop* quote recur
     ;; definition and threading macros
     defn defn- -> ->> as-> cond cond-> cond->> condp if-let if-not if-some
     some-> some->> when when-first when-let when-not when-some
     ;; logic and comparison
     = not= not and or < <= > >= compare
     ;; arithmetic
     * + - / abs dec inc max min mod quot rem
     even? odd? neg? pos? zero?
     ;; predicates
     boolean? char? coll? contains? empty? every? fn? integer? keyword? map?
     nil? number? seq? sequential? set? some some? string? symbol? vector?
     ;; construction
     hash-map hash-set list list* set vec vector zipmap
     ;; access and update
     assoc assoc-in dissoc get get-in update update-in merge merge-with
     select-keys keys vals find key val
     ;; sequences
     concat conj cons count distinct drop drop-last drop-while filter filterv
     first flatten frequencies group-by interleave interpose into juxt last
     map mapcat mapv nth partition partition-all peek pop range reduce
     reduce-kv remove rest reverse second seq sort sort-by split-at take
     take-last take-while
     ;; functional
     apply comp complement constantly identity partial
     ;; strings and naming
     format name namespace pr-str str subs symbol keyword
     ;; output
     println})

;; ═══════════════════════════════════════════════════════════════════════════
;; Profiles
;; ═══════════════════════════════════════════════════════════════════════════

(def profiles
  "Context profiles defining the exact maximum capability IDs each profile
   permits.  Effects classify replay behavior; they do not grant authority.

   Profile hierarchy:
     :agent/minimal       — no semantic operation capabilities
     :agent/project-read  — project read/list/search/stat
     :agent/project-develop — project-read plus project edit"
  {:agent/minimal
   {:profile/id :agent/minimal
    :profile/max-capabilities #{}}
   :agent/project-read
   {:profile/id :agent/project-read
    :profile/max-capabilities #{:project/read
                                :project/list
                                :project/search
                                :project/stat}}
   :agent/project-develop
   {:profile/id :agent/project-develop
    :profile/max-capabilities #{:project/read
                                :project/list
                                :project/search
                                :project/stat
                                :project/edit}}})

;; ═══════════════════════════════════════════════════════════════════════════
;; Canonical receipt domain
;; ═══════════════════════════════════════════════════════════════════════════

(defn inert
  "Canonicalize a value into the receipt domain.

   Accepted: nil, boolean, string, exact integer (long, bigint), keyword,
   symbol, vector (of inert values), map (inert keys and values, entries
   sorted canonically by pr-str of key).

   Rejected: floats, doubles, ratios, BigDecimal, lazy seqs, lists,
   live objects (atoms, refs, agents, vars, functions), opaque host
   values (regex patterns, class objects, etc.)."
  [x]
  (cond
    (nil? x) nil
    (boolean? x) x
    (string? x) x
    (keyword? x) x
    (symbol? x) x
    ;; Exact integers only: long, bigint.  (integer? 1.0) is false in
    ;; Clojure so the (not (float? ...)) guard is technically redundant
    ;; for ints, but makes the intent explicit and guards against
    ;; hypothetical numeric types.
    (and (integer? x) (not (float? x))) x
    (vector? x) (mapv inert x)
    (map? x)
    (into {}
          (map (fn [[k v]] [(inert k) (inert v)]))
          (sort-by (comp pr-str key) x))
    :else (throw (ex-info "Non-canonical receipt value"
                           {:jolt.sandbox/value-type (str (type x))
                            :jolt.sandbox/value (pr-str x)}))))

;; ═══════════════════════════════════════════════════════════════════════════
;; ContextSpec resolution
;; ═══════════════════════════════════════════════════════════════════════════

(defn- resolve-context-spec
  "Validate and resolve a ContextSpec against provided operations and profiles.

   Enforces:  requested ⊆ authorized ⊆ profile-max

   where profile-max is the profile's explicit set of capability IDs."
  [operations
   {:keys [profile requested-capabilities authorized-capabilities]
    :or {requested-capabilities nil
         authorized-capabilities nil}}]
  (let [profile-data (get profiles profile)
        ops-by-id (into {} (map (juxt :id identity)) operations)
        op-ids (set (keys ops-by-id))]
    (when-not profile-data
      (throw (ex-info "Unknown profile"
                      {:jolt.sandbox/error :unknown-profile
                       :profile profile})))
    (let [profile-max (:profile/max-capabilities profile-data)
          ;; Default: if neither specified, requested = authorized = available.
          ;; If only authorized specified, requested defaults to authorized (not
          ;; to all ops, which would make requested > authorized fail).
          requested (set (or requested-capabilities
                             (when authorized-capabilities authorized-capabilities)
                             op-ids))
          authorized (set (or authorized-capabilities requested))]
      ;; requested ⊆ authorized
      (when-not (every? authorized requested)
        (throw (ex-info "Requested capabilities exceed authorization"
                        {:jolt.sandbox/error :over-request
                         :requested requested
                         :authorized authorized})))
      ;; authorized ⊆ profile-max
      (when-not (every? profile-max authorized)
        (let [excess (remove profile-max authorized)]
          (throw (ex-info "Authorized capabilities exceed profile maximum"
                          {:jolt.sandbox/error :profile-exceeded
                           :profile profile
                           :authorized authorized
                           :profile-max profile-max
                           :excess excess}))))
      ;; All authorized caps must exist in provided operations
      (when-not (every? op-ids authorized)
        (let [missing (remove op-ids authorized)]
          (throw (ex-info "Authorized capabilities not in provided operations"
                          {:jolt.sandbox/error :missing-operation
                           :authorized authorized
                           :available op-ids
                           :missing missing}))))
      {:profile profile
       :profile-data profile-data
       :requested-capabilities requested
       :authorized-capabilities authorized
       :authorized authorized
       :operations operations})))

;; ═══════════════════════════════════════════════════════════════════════════
;; Inert authority description and deterministic coordinate
;; ═══════════════════════════════════════════════════════════════════════════

(defn effective-authority
  "Build an inert, data-only description of a context's effective authority.
   Suitable for serialization, comparison, and coordination.

   The description is fully canonical: all collections are sorted and
   contain only receipt-domain values."
  [state]
  (let [{:keys [profile requested-capabilities operations authorized]} @state
        ;; Dispatch uses :authorized as its single live authority source.  The
        ;; description must read that same value so attenuation/revocation never
        ;; attests authority the wrapper no longer has.
        authorized-set authorized]
    (inert
      {:jolt.sandbox/profile (str profile)
       :jolt.sandbox/requested (vec (sort (map str requested-capabilities)))
       :jolt.sandbox/authorized (vec (sort (map str authorized-set)))
       :jolt.sandbox/operations
       (vec (sort-by :op/id
                     (map (fn [{:keys [id name effect]}]
                            {:op/id (str id)
                             :op/name (str name)
                             :op/effect effect})
                          (filterv (fn [{:keys [id]}]
                                     (contains? authorized-set id))
                                   operations))))})))

(defn- coordinate-form [x]
  ;; A vector-only structural representation fixes map ordering without relying
  ;; on caller print bindings or host map iteration order.
  (cond
    (vector? x) [:vector (mapv coordinate-form x)]
    (map? x) [:map (->> x
                         (map (fn [[k v]] [(coordinate-form k) (coordinate-form v)]))
                         (sort-by (fn [[k _]] (binding [*print-length* nil *print-level* nil]
                                                (pr-str k))))
                         vec)]
    :else x))

(defn canonical-coordinate
  "Deterministic exact coordinate from an authority description. The complete
   canonical form is retained instead of a short collision-prone hash."
  [authority-desc]
  (str "js0:"
       (binding [*print-length* nil *print-level* nil]
         (pr-str (coordinate-form (inert authority-desc))))))

;; ═══════════════════════════════════════════════════════════════════════════
;; Reviewed language surface — trusted inert description and versioned
;; coordinate
;; ═══════════════════════════════════════════════════════════════════════════

(def language-surface-version
  "Version of the language-surface description schema and its coordinate
   scheme.  Consumers (e.g. Samizdat safe doc/complete) pin or gate on this
   version.  Bump it when the description schema changes or the reviewed
   vocabulary is deliberately re-generated; a vocabulary change also changes
   the coordinate payload at any version."
  1)

(defn language-surface
  "Trusted, inert, data-only description of the reviewed pure SCI language
   surface (the base allow vocabulary).

   Derived solely from the reviewed static data in this namespace.  It never
   touches a live SCI Context, performs no SCI or host introspection, and
   contains no vars, functions, namespaces, or other host handles — every
   value is in the receipt domain (see `inert`).  Per-context projected
   operation names are host handles and are deliberately absent; they are
   attested per context by `effective-authority` instead.

   The description is fully canonical: symbols are strings sorted by `str`.
   Suitable for serialization, comparison, and as a completion corpus for
   Samizdat safe doc/complete.  Doc text is not included; consumers key
   their own documentation database by symbol name."
  []
  (inert
    {:jolt.sandbox.surface/lang "js0-pure-sci"
     :jolt.sandbox.surface/version language-surface-version
     :jolt.sandbox.surface/count (count base-allow-vocabulary)
     :jolt.sandbox.surface/symbols (vec (sort (map str base-allow-vocabulary)))}))

(defn language-coordinate
  "Deterministic versioned coordinate for the reviewed pure SCI language
   surface: the scheme prefix js0-lang/v<version>: followed by the complete
   canonical form of `language-surface`.  Same surface and version yield the
   same string on any host, independent of print bindings or map iteration
   order.  The js0-lang scheme is disjoint from the per-context authority
   coordinate scheme (js0:)."
  []
  (str "js0-lang/v" language-surface-version ":"
       (binding [*print-length* nil *print-level* nil]
         (pr-str (coordinate-form (language-surface))))))

;; ═══════════════════════════════════════════════════════════════════════════
;; Operation validation
;; ═══════════════════════════════════════════════════════════════════════════

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

;; ═══════════════════════════════════════════════════════════════════════════
;; Receipts
;; ═══════════════════════════════════════════════════════════════════════════

(defn- receipt [id args result]
  {:op/id id :op/args (inert (vec args)) :op/result (inert result)})

(defn- error-receipt [id args error]
  {:op/id id :op/args (inert (vec args)) :op/error (str error)})

;; ═══════════════════════════════════════════════════════════════════════════
;; Operation wrapper with dispatch recheck
;; ═════════════════════════════════════════════════════════════════════════

(defn- wrapper [state descriptor]
  (fn [& args]
    ;; One snapshot is the authorization linearization point: a dispatch uses
    ;; either authority before a concurrent revoke or authority after it, never
    ;; a mixed mode/transcript/authorization state.
    (let [{:keys [mode receipts cursor authorized]} @state
          {:keys [id effect fn]} descriptor
          ;; RECHECK: read the CURRENT authorized set from @state so that
          ;; runtime revocation is immediately effective.  The wrapper is
          ;; projected into the SCI context (fixture presence), but the
          ;; recheck is the real authority gate.
           _ (when-not (contains? authorized id)
              (throw (ex-info "Operation not authorized for this context"
                              {:jolt.sandbox/error :unauthorized
                               :op/id id})))
          ;; Canonicalize arguments AFTER the capability recheck.
          args (inert (vec args))]
      ;; Pure operations are deterministic and execute in every mode.  Effects
      ;; select replay treatment only; profile authority is exclusively ID-based.
      (if (= :pure effect)
        (inert (apply fn args))
        (case mode
          :normal (inert (apply fn args))
          :record (try
                    (let [result (inert (apply fn args))]
                      (swap! receipts conj (receipt id args result))
                      result)
                    (catch Throwable error
                      ;; A historical operation failure is just as observable as a
                      ;; result.  Record it before rethrowing so replay never calls
                      ;; the host in an attempt to rediscover it.
                      (swap! receipts conj (error-receipt id args error))
                      (throw error)))
          :replay (let [i @cursor rs @receipts]
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
                                         :op/id id
                                         :expected (:op/args r)
                                         :actual args})))
                      (swap! cursor inc)
                      (if (:op/error r)
                        (throw (ex-info (:op/error r)
                                        {:jolt.sandbox/error :recorded-operation-error
                                         :op/id id}))
                        (:op/result r)))))))))

;; ═══════════════════════════════════════════════════════════════════════════
;; Context creation
;; ═══════════════════════════════════════════════════════════════════════════

(defn create-context
  "Creates a persistent SCI context with authority control.

   Accepts either:

   1. A vector of operation descriptors (legacy API):
      All operations are authorized under a private, unprofiled compatibility
      maximum. New callers should use a context-spec and an explicit profile.

   2. A context-spec map:
      {:operations              vector of operation descriptors
       :profile                 profile keyword
       :requested-capabilities   set of operation IDs (default: all)
       :authorized-capabilities  set of operation IDs (default: requested)}

   Operation descriptor shape:
     {:id keyword-or-string :name symbol :effect :pure/:observation/:actuation
      :fn host-fn}

   Operations are projected into the SCI context as project/<name>.
   ALL provided operations are projected (fixture presence), but each
   wrapper independently rechecks the authorized set before execution.
   The :allow set is the base vocabulary plus namespaced operation symbols.

   This ensures fixture trusted operation presence does not authorize
   absent capability — the wrapper recheck is the real gate."
  [ops-or-spec]
  (let [legacy? (vector? ops-or-spec)
        raw-ops (if legacy? ops-or-spec (:operations ops-or-spec))
        operations (checked-operations raw-ops)
        op-ids (set (map :id operations))
        resolved (if legacy?
                   ;; Preserve the original trusted vector API without widening
                   ;; any named profile's exact maximum.
                   {:profile :legacy/unprofiled
                    :profile-data {:profile/id :legacy/unprofiled
                                   :profile/max-capabilities op-ids}
                    :requested-capabilities op-ids
                    :authorized-capabilities op-ids
                    :authorized op-ids
                    :operations operations}
                   (resolve-context-spec operations ops-or-spec))
        {:keys [authorized operations]} resolved
        state (atom (merge resolved
                           {:mode :normal
                            :receipts (atom [])
                            :cursor (atom 0)}))
        ;; Project ALL operations so fixture presence is visible.
        ;; The wrapper independently rechecks authorized set at dispatch.
        projected (into {}
                       (map (fn [op] [(:name op) (wrapper state op)])
                            operations))
        ;; Build SCI :allow set: base vocabulary + namespaced operation symbols.
        ;; SCI's check-permission! checks (contains? allow check-sym) where
        ;; check-sym = (strip-core-ns sym).  For (project/read ...),
        ;; the sym is project/read which is NOT stripped (not clojure.core),
        ;; so we must include the fully qualified project/<name> symbol.
        op-allow (into #{} (map (fn [op]
                                  (symbol "project" (str (:name op))))
                              operations))
        allow-set (into base-allow-vocabulary op-allow)
        sci-ctx (sci/init {:namespaces {'project projected}
                           :allow allow-set})]
    (swap! state assoc :sci-context sci-ctx)
    state))

;; ═══════════════════════════════════════════════════════════════════════════
;; Context management
;; ═══════════════════════════════════════════════════════════════════════════

(defn set-mode! [state mode]
  (when-not (#{:normal :record :replay} mode)
    (throw (ex-info "Unknown sandbox mode"
                    {:jolt.sandbox/error :unknown-mode :mode mode})))
  (swap! state assoc :mode mode)
  (when (= :replay mode) (reset! (:cursor @state) 0))
  state)

(defn revoke!
  "Removes a presently effective capability. Existing SCI Vars remain only as
   inert wrappers whose independent host-side dispatch check denies them."
  [state capability]
  ;; This swap is the revocation linearization point. Keep every authority
  ;; layer attenuated so requested ⊆ authorized remains true after revocation.
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
  "Evaluates source in the same SCI Context on every invocation.  In
   replay mode, an otherwise-successful evaluation fails if it leaves
   historical receipts.
   `token`, when supplied, is a Jolt interrupt token and stops
   computation rather than merely ending the caller's wait."
  ([state source] (evaluate! state source nil))
  ([state source token]
   (let [run #(sci/eval-string* (:sci-context @state) source)
          value (if token
                  ;; Never catch an interruption here: treating a genuine
                  ;; cancellation as a missing host seam would re-run model
                  ;; code after cancellation, including a runaway loop.
                  (jolt.host/run-interruptible token run)
                  (run))]
     (when (= :replay (:mode @state))
       (let [used @(:cursor @state) total (count @(:receipts @state))]
         (when-not (= used total)
           (throw (ex-info "Replay has unconsumed receipts"
                           {:jolt.sandbox/error :unconsumed
                            :consumed used :total total})))))
     value)))

(defn fork-context
  "A new SCI Context with the same authority descriptors but no
   definitions or receipts from `state`."
  [state]
  (let [s @state]
    (if (= :legacy/unprofiled (:profile s))
      ;; Rebuild legacy contexts through their private compatibility path, then
      ;; attenuate before returning the child so a revoked capability is never
      ;; observable there.
      (let [child (create-context (vec (:operations s)))]
        (doseq [capability (remove (:authorized s)
                                   (map :id (:operations s)))]
          (revoke! child capability))
        child)
      (create-context
        {:operations (:operations s)
         :profile (:profile s)
         ;; Fork from current effective authority, never the creation-time grant.
         :requested-capabilities
         (set (filter (:authorized s)
                      (or (:requested-capabilities s) (:requested s))))
         :authorized-capabilities (:authorized s)}))))
