(ns jolt.passes.effects
  "Compilation-unit effect summaries for analyzed Jolt IR.

  This pass deliberately starts with effects visible in user/library IR:
  resolved calls, opaque invocation, and aspect join-point preservation.  The
  counted/logical mutex rules for the hand-written Chez runtime remain in
  host/chez/park-lock-check.ss; those mutex regions do not exist in this IR.

  Summaries are recomputed at :plain, :woven, and :optimized checkpoints.  The
  authoritative state lives on the compilation unit, not on IR nodes: inlining
  and scalar replacement are allowed to replace nodes wholesale."
  (:require [clojure.java.io :as io]
            [jolt.aspect-contracts :as aspect-contracts]
            [jolt.canonical-edn :as canonical]
            [jolt.ir :refer [reduce-ir-children closed-world-opt-out?]]))

(def phases #{:plain :woven :optimized})

;; Execution-transfer contracts are deliberately separate from ordinary effect
;; declarations. Calling one of these functions evaluates its arguments now,
;; but invokes the selected callable later/on another execution context. Folding
;; the callable body into the caller's immediate effects would make a monitor
;; around `go` appear to protect the go body, which is false. The transfer edge
;; instead points at a separately summarized deferred-arity subject.
(def execution-transfer-contracts
  {;; The CPS and fallback expansions of clojure.core.async/go.
   ["clojure.core.async/__sm-spawn" 1]
   {:argument 0 :kind :jolt.transfer/scheduled :carrier :selected-go-backend}
   ["clojure.core.async/go-spawn" 1]
   {:argument 0 :kind :jolt.transfer/scheduled :carrier :selected-go-backend}
   ;; Explicit carrier entry points used by thread-call/io-thread.
   ["clojure.core.async/thread-spawn" 1]
   {:argument 0 :kind :jolt.transfer/scheduled :carrier :thread}
   ["clojure.core.async/fiber-spawn" 1]
   {:argument 0 :kind :jolt.transfer/scheduled :carrier :fiber}
   ;; Public thread-call accepts an optional workload selector.
   ["clojure.core.async/thread-call" 1]
   {:argument 0 :kind :jolt.transfer/scheduled :carrier :workload-selected}
   ["clojure.core.async/thread-call" 2]
   {:argument 0 :kind :jolt.transfer/scheduled :carrier :workload-selected}})

;; Contextual consumers name the concrete effect classes whose preservation
;; they rely on. Keeping this registry beside the effect lattice prevents a new
;; region checker from silently depending on an effect that optimization is
;; still allowed to reveal only after weaving.
(def safety-critical-effects
  {:jolt.rule/optimization-preserves-scheduler-effects
   #{:jolt.effect/park
     :jolt.effect/native-block
     :jolt.effect/user-dispatch
     :jolt.effect/schedule
     :jolt.effect/checkpoint
     :jolt.effect/nonlocal-control}
   :jolt.rule/no-native-block-under-logical-monitor
   #{:jolt.effect/native-block}})

(defn effects-for-rule [rule]
  (get safety-critical-effects rule #{}))

;; Unknown is the top of the general may-effect lattice, so optimization may
;; refine it into an ordinary concrete effect. These effects are different:
;; they change whether execution may park a fiber, pin a carrier, or invoke
;; application-controlled code. A later structural region checker relies on
;; optimization never making one newly visible behind an earlier top.
(def optimization-protected-effects
  (effects-for-rule :jolt.rule/optimization-preserves-scheduler-effects))

(defn configure-analysis-context!
  "Select the compiler-mode epoch represented by unit's phase registries.
  Ordinary builds configure one context. Low-level pass harnesses may reuse a
  unit while changing linkage/optimization flags; a new context starts fresh
  evidence instead of comparing two different compiler configurations as if
  they were duplicate observations of one build."
  [unit context]
  (when-let [context-cell (get unit :effect-analysis-context)]
    (let [prior @context-cell]
      (when (not= prior context)
        (reset! context-cell context)
        (reset! (:effect-phase-roots unit)
                {:plain {} :woven {} :optimized {}})
        (reset! (:effect-reports unit) {})
        (reset! (:effect-findings unit) [])
        (when-let [source-ids (:effect-source-ids unit)]
          (reset! source-ids {})))))
  unit)

(defn- fqn [node]
  (str (get node :ns) "/" (get node :name)))

(defn- arity-shape [arity]
  (if (get arity :rest)
    {:variadic-min (count (get arity :params))}
    {:fixed (count (get arity :params))}))

(defn- subject [node arity source-id]
  (cond-> {:kind :var-arity
           :fqn (fqn node)
           :definition-position (select-keys (get node :pos) [:line :column])
           :arity (arity-shape arity)}
    source-id (assoc :source-id source-id)))

(defn- callable-subject [node shape source-id]
  (cond-> {:kind :var-arity
           :fqn (fqn node)
           :definition-position (select-keys (get node :pos) [:line :column])
           :arity shape}
    source-id (assoc :source-id source-id)))

(defn- initializer-subject [node source-id]
  (cond-> {:kind :var-init
           :fqn (fqn node)
           :definition-position (select-keys (get node :pos) [:line :column])}
    source-id (assoc :source-id source-id)))

(defn- position [node]
  ;; Build evidence is portable and source-neutral. The surrounding subject
  ;; identifies the function; line/column locate the call without publishing a
  ;; checkout path or making identical sources produce different bytes.
  (select-keys (get node :pos) [:line :column]))

(defn- top-level-subject [node source-id]
  ;; Reader positions remain stable while weave/optimization replace the root.
  ;; The namespace is stamped by analyze even when the root itself is not a def.
  (cond-> {:kind :top-level-form
           :namespace (str (or (get node :fnsrc-ns) (get node :ns) "<unknown>"))
           :op (get node :op)
           :position (position node)}
    source-id (assoc :source-id source-id)))

(defn- source-id!
  "Return a path-neutral source token stable for this compilation unit. The
  absolute reader path is used only as an internal key and never enters build
  evidence. First-observation order is deterministic in Jolt's serial compiler
  walk and remains shared by all three analysis phases."
  [unit node]
  (or (get node :effect-source-id)
      (when-let [file (get-in node [:pos :file])]
        (when-let [source-ids (:effect-source-ids unit)]
          (let [m (swap! source-ids
                         (fn [ids]
                           (if (contains? ids file)
                             ids
                             (assoc ids file {:ordinal (count ids)}))))]
            (get m file))))))

(defn- callee [node argc]
  {:fqn (fqn node) :argc argc})

(defn- join-site-id [node]
  (some (fn [arg]
          (when (= :quote (get arg :op))
            (or (get arg :aspect-site-id)
                (get-in arg [:form :site-id]))))
        (get node :args)))

(defn- node-evidence [node]
  {:effects #{}
   :callees #{}
   :transfers #{}
   :transfer-bodies []
   :aspect-sites (if-let [site-id (get node :aspect-site-id)] #{site-id} #{})
   :checkpoint-sites #{}
   :opaque-calls []})

(defn- merge-direct [a b]
  {:effects (into (get a :effects #{}) (get b :effects #{}))
   :callees (into (get a :callees #{}) (get b :callees #{}))
   :transfers (into (get a :transfers #{}) (get b :transfers #{}))
   :transfer-bodies (into (get a :transfer-bodies [])
                          (get b :transfer-bodies []))
   :aspect-sites (into (get a :aspect-sites #{}) (get b :aspect-sites #{}))
   :checkpoint-sites (into (get a :checkpoint-sites #{})
                           (get b :checkpoint-sites #{}))
   :opaque-calls (into (get a :opaque-calls []) (get b :opaque-calls []))})

(def empty-direct
  {:effects #{} :callees #{} :transfers #{} :transfer-bodies []
   :aspect-sites #{} :checkpoint-sites #{} :opaque-calls []})

(declare summarize-eval)

(defn- summarize-children [node]
  (reduce-ir-children
    (fn [acc child] (merge-direct acc (summarize-eval child)))
    (node-evidence node)
    node))

(defn- summarize-fn-body [fn-node]
  ;; Aspect operation thunks are generated with one arity.  Be conservative if
  ;; that invariant changes: every arity is potentially selected by the helper.
  (reduce (fn [acc arity]
            (merge-direct acc (summarize-eval (get arity :body))))
          empty-direct
          (get fn-node :arities)))

(defn- opaque-call [node kind]
  {:effects #{:jolt.effect/user-dispatch}
   :callees #{}
   :transfers #{}
   :transfer-bodies []
   :aspect-sites #{}
   :opaque-calls [{:kind kind :position (position node)}]})

(defn- ffi-call-effects [ffi-node]
  ;; A typed foreign-fn is a closed callable contract in the IR.  The native
  ;; operation is effectful even when it promises not to block; :blocking adds
  ;; the stronger carrier/scheduler hazard used by region verification.
  {:effects (cond-> #{:jolt.effect/native-call}
              (get ffi-node :blocking) (conj :jolt.effect/native-block))
   :callees #{}
   :transfers #{}
   :transfer-bodies []
   :aspect-sites #{}
   :opaque-calls []})

(defn- ffi-arity-shape [ffi-node]
  ;; :varargs is an ABI boundary marker, not an argument supplied by the Jolt
  ;; caller.  A foreign-fn binding still has the one concrete arity described by
  ;; the remaining signature entries.
  {:fixed (count (remove #(= "varargs" %) (get ffi-node :argtypes)))})

(defn- checkpoint-effects [dispositions]
  ;; The site table is authoritative for controller capability.  These effects
  ;; make that capability visible to compiler analyses without pretending that
  ;; installing a controller can strengthen a continue-only site later.
  (cond-> #{:jolt.effect/checkpoint}
    (or (contains? dispositions :yield)
        (contains? dispositions :barrier))
    (conj :jolt.effect/schedule)
    (contains? dispositions :barrier)
    (conj :jolt.effect/park)
    (or (contains? dispositions :fault)
        (contains? dispositions :cancel))
    (conj :jolt.effect/nonlocal-control)))

(defn- checkpoint-evidence [node]
  {:effects (checkpoint-effects (get node :dispositions))
   :callees #{}
   :transfers #{}
   :transfer-bodies []
   :aspect-sites #{}
   :checkpoint-sites #{{:id (get node :id)
                        :dispositions (get node :dispositions)}}
   :opaque-calls []})

(defn- transfer-origin-fqn [node]
  (or (some-> node :inline-chain first first)
      (get node :effect-owner-fqn)))

(defn- transfer-evidence [node target-fqn contract]
  (let [argument (get contract :argument)
        callable (nth (get node :args) argument nil)
        base {:kind (get contract :kind)
              :target target-fqn
              :argument argument
              :carrier (get contract :carrier)
              :site (position node)
              :origin-fqn (transfer-origin-fqn node)}]
    (if (= :fn (get callable :op))
      {:effects #{:jolt.effect/schedule}
       :callees #{}
       :transfers #{}
       :transfer-bodies
       (mapv (fn [arity]
               (assoc base
                      :arity (arity-shape arity)
                      :direct (summarize-eval (get arity :body))
                      :analysis-node (get arity :body)))
             (get callable :arities))
       :aspect-sites #{}
       :opaque-calls []}
      {:effects #{:jolt.effect/schedule}
       :callees #{}
       :transfers #{(assoc base :unknown? true)}
       :transfer-bodies []
       :aspect-sites #{}
       :opaque-calls []})))

(defn- summarize-invoke [node]
  (let [target (get node :fn)
        args (get node :args)
        target-fqn (when (= :var (get target :op)) (fqn target))
        children (summarize-children node)]
    (cond
      (aspect-contracts/helper-call-spec target-fqn (count args))
      ;; Weaving moves the original operation into a literal function and passes
      ;; advice as a var value.  A structural walk correctly treats function
      ;; construction as effect-free, so make the helper's synchronous behavior
      ;; explicit here: it may invoke both advice and operation.
      (let [contract (aspect-contracts/helper-call-spec target-fqn (count args))
            advice (nth args (:advice-index contract))
            operation (nth args (:operation-index contract))
            site-id (join-site-id node)
            advice-edge (if (= :var (get advice :op))
                          {:effects #{}
                           ;; Helper args are advice, join-point, optional
                           ;; evaluated-args, operation. Advice receives every
                           ;; helper argument after advice, including operation
                           ;; as its proceed argument.
                           :callees #{(callee advice (:advice-argc contract))}
                           :transfers #{}
                           :transfer-bodies []
                           :aspect-sites #{}
                           :opaque-calls []}
                          (opaque-call node :aspect-advice))
            operation-effects (if (= :fn (get operation :op))
                                (summarize-fn-body operation)
                                (opaque-call node :aspect-operation))]
        (merge-direct
          children
          (merge-direct
            advice-edge
            (merge-direct
              operation-effects
              {:effects #{:jolt.effect/user-dispatch}
               :callees #{}
               :transfers #{}
               :transfer-bodies []
               :aspect-sites (if site-id #{site-id} #{})
               :opaque-calls []}))))

      (and target-fqn (aspect-contracts/helper-fqn? target-fqn))
      (merge-direct children (opaque-call node :aspect-helper-shape))

      (= :ffi-fn (get target :op))
      (merge-direct children (ffi-call-effects target))

      (get execution-transfer-contracts [target-fqn (count args)])
      (merge-direct
        children
        (transfer-evidence
          node target-fqn
          (get execution-transfer-contracts [target-fqn (count args)])))

      target-fqn
      (merge-direct children
                    {:effects #{}
                     :callees #{(callee target (count args))}
                     :transfers #{}
                     :transfer-bodies []
                     :aspect-sites #{}
                     :opaque-calls []})

      :else
      (merge-direct children
                    (opaque-call node
                                 (if (contains? #{:host :host-static :ffi-fn}
                                                (get target :op))
                                   :host-invoke
                                   :dynamic-invoke))))))

(defn summarize-eval
  "Summarize effects incurred by evaluating node now. Function literal bodies
  are deferred and therefore excluded, except when an aspect helper explicitly
  invokes its generated operation thunk."
  [node]
  (cond
    (= :fn (get node :op)) empty-direct
    (= :ffi-callable (get node :op)) empty-direct
    ;; :checkpoint-decl deliberately falls through as an effect-free leaf.  It
    ;; is the source declaration recorded in :plain, before profile lowering.
    (= :checkpoint (get node :op)) (checkpoint-evidence node)
    (= :invoke (get node :op)) (summarize-invoke node)
    (= :host-call (get node :op))
    (merge-direct (summarize-children node) (opaque-call node :host-call))
    (= :host-new (get node :op))
    (merge-direct (summarize-children node) (opaque-call node :host-new))
    :else (summarize-children node)))

(defn- as-summary
  ([direct subject closed-world?]
   (as-summary direct subject closed-world? nil))
  ([direct subject closed-world? analysis-node]
   (cond-> (assoc direct
                  :subject subject
                  :closed-world? (if closed-world? true false))
     analysis-node (assoc :analysis-node analysis-node))))

(declare expand-direct-transfers)

(defn- transfer-owner [owner transfer]
  (cond
    (get transfer :origin-fqn)
    {:kind :var-origin :fqn (get transfer :origin-fqn)}

    (get owner :fqn)
    {:kind :var-origin :fqn (get owner :fqn)}

    (= :deferred-arity (get owner :kind))
    owner

    :else
    (select-keys owner [:kind :namespace :source-id :position])))

(defn- deferred-subject [owner transfer ordinal]
  {:kind :deferred-arity
   :owner (transfer-owner owner transfer)
   :transfer-kind (get transfer :kind)
   :target (get transfer :target)
   :argument (get transfer :argument)
   :carrier (get transfer :carrier)
   :site (get transfer :site)
   :ordinal ordinal
   :arity (get transfer :arity)})

(defn- transfer-ref [transfer subject]
  (assoc (select-keys transfer [:kind :target :argument :carrier :site])
         :subject subject))

(defn- expand-direct-transfers
  "Replace private literal-body records with public transfer edges and return
  separately analyzable deferred-arity summaries, recursively."
  [direct owner]
  (let [bodies (get direct :transfer-bodies [])
        base (dissoc direct :transfer-bodies)]
    (reduce
      (fn [[parent children] [ordinal transfer]]
        (let [child-subject (deferred-subject owner transfer ordinal)
              [child-direct descendants]
              (expand-direct-transfers (get transfer :direct) child-subject)
              child (as-summary child-direct child-subject true
                                (get transfer :analysis-node))]
          [(update parent :transfers conj (transfer-ref transfer child-subject))
           (into children (cons child descendants))]))
      [base []]
      (map-indexed vector bodies))))

(defn- expand-summary [summary]
  (let [[direct deferred]
        (expand-direct-transfers (dissoc summary :subject :closed-world?
                                         :analysis-node)
                                 (get summary :subject))
        root (merge direct
                    (select-keys summary [:subject :closed-world? :analysis-node]))]
    (into [root] deferred)))

(defn- definition-evaluation [node]
  ;; Def evaluation includes initializer construction/execution and evaluated
  ;; metadata. A function literal body remains deferred, but its metadata need
  ;; not be. This is distinct from every callable arity subject.
  (reduce (fn [acc child] (merge-direct acc (summarize-eval child)))
          empty-direct
          (filter some? [(get node :init) (get node :meta-expr)])))

(defn- source-identified-subject? [s]
  (boolean
    (seq (or (get s :definition-position)
             (get s :position)))))

(defn summarize-node
  "Return direct summaries for every runtime-evaluated top-level subject.
  Function defs produce a var-initializer subject plus one subject per arity;
  other initialized defs produce an initializer subject, and non-def roots use
  their namespace/source position. closed-world? applies only to callable
  arities because redefining a var does not make its already-run initializer
  dynamically dispatchable."
  ([node] (summarize-node node (not (closed-world-opt-out? (get node :meta))) nil))
  ([node closed-world?]
   (summarize-node node closed-world? nil))
  ([node closed-world? source-id]
   (summarize-node node closed-world? source-id node))
  ([node closed-world? source-id identity-node]
   (mapcat
     expand-summary
     (cond
       (and (= :def (get node :op)) (= :fn (get-in node [:init :op])))
       (into [(as-summary (definition-evaluation node)
                          (initializer-subject identity-node source-id) true)]
             (map (fn [arity]
                    (as-summary (summarize-eval (get arity :body))
                                (subject identity-node arity source-id) closed-world?
                                (get arity :body)))
                  (get-in node [:init :arities])))

       (and (= :def (get node :op)) (= :ffi-fn (get-in node [:init :op])))
       (let [ffi-node (get node :init)]
         [(as-summary (definition-evaluation node)
                      (initializer-subject identity-node source-id) true)
          (as-summary (ffi-call-effects ffi-node)
                      (callable-subject identity-node
                                        (ffi-arity-shape ffi-node)
                                        source-id)
                      closed-world?)])

       (and (= :def (get node :op)) (get node :init))
       [(as-summary (definition-evaluation node)
                    (initializer-subject identity-node source-id) true)]

       ;; Source declares currently carry static metadata only, but the IR schema
       ;; permits an evaluated :meta-expr on any def. Preserve that contract rather
       ;; than silently dropping a future/synthetic declare's metadata effects.
       (and (= :def (get node :op)) (get node :no-init))
       (if (get node :meta-expr)
         [(as-summary (definition-evaluation node)
                      (initializer-subject identity-node source-id) true)]
         [])

       :else
       [(as-summary (summarize-eval node)
                    (top-level-subject identity-node source-id) true node)]))))

(defn record-phase!
  "Record node's direct summaries at phase. Repeated identical observation is
  idempotent. A different summary for the same phase/subject is a compiler
  consistency failure rather than a last-write-wins overwrite."
  ([unit phase node] (record-phase! unit phase node
                                    (not (closed-world-opt-out? (get node :meta)))))
  ([unit phase node closed-world?]
   (record-phase! unit phase node closed-world? node))
  ([unit phase node closed-world? identity-node]
   (when-not (contains? phases phase)
     (throw (ex-info "unknown Jolt effect-analysis phase" {:phase phase})))
   (let [summaries (summarize-node node closed-world?
                                   (source-id! unit identity-node)
                                   identity-node)]
     (swap! (:effect-phase-roots unit)
            (fn [all]
              (assoc all phase
                     (reduce (fn [m summary]
                               (let [s (get summary :subject)]
                                 (if-let [prior (get m s)]
                                   (do
                                     ;; Source builds identify roots by their
                                     ;; reader position, so a disagreement means
                                     ;; two compiler paths summarized the same
                                     ;; source differently. Low-level Scheme gate
                                     ;; harnesses also reuse one unit across many
                                     ;; independent, string-analyzed roots that
                                     ;; carry no position; retain their historical
                                     ;; scratch replacement behavior.
                                     ;; :analysis-node is retained for later
                                     ;; contextual passes, but compiler-only
                                     ;; annotations on that tree (devirt/type
                                     ;; precision) may legitimately improve when
                                     ;; a low-level gate reanalyzes one source in
                                     ;; the same phase. Only the semantic direct
                                     ;; summary participates in consistency.
                                     (when (and (source-identified-subject? s)
                                                (not= (dissoc prior :analysis-node)
                                                      (dissoc summary :analysis-node)))
                                       (throw
                                         (ex-info
                                           (str
                                             "Jolt effect subject changed within one phase: "
                                             (pr-str
                                               {:phase phase :subject s
                                                :first (dissoc prior :subject)
                                                :later (dissoc summary :subject)}))
                                           {:phase phase :subject s
                                            :first prior :later summary})))
                                     ;; Retain the latest analysis tree even when
                                     ;; its semantic summary is unchanged.
                                     (if (= prior summary) m (assoc m s summary)))
                                   (assoc m s summary))))
                             (get all phase {})
                             summaries))))
     (swap! (:effect-reports unit) dissoc phase)
     summaries)))

(defn- validate-declaration-key! [key]
  (when-not
    (or (string? key)
        (and (vector? key)
             (= 2 (count key))
             (string? (nth key 0))
             (let [shape (nth key 1)]
               (and (map? shape)
                    (= 1 (count shape))
                    (or (and (contains? shape :fixed)
                             (integer? (get shape :fixed))
                             (not (neg? (get shape :fixed))))
                        (and (contains? shape :variadic-min)
                             (integer? (get shape :variadic-min))
                             (not (neg? (get shape :variadic-min)))))))))
    (throw (ex-info "invalid Jolt effect declaration key"
                    {:key key
                     :expected "fqn string or [fqn {:fixed n|:variadic-min n}]"}))))

(defn- validate-declaration! [key declaration]
  (validate-declaration-key! key)
  (when-not (and (map? declaration)
                 (set? (get declaration :effects #{}))
                 (every? keyword? (get declaration :effects #{}))
                 (or (not (contains? declaration :unknown?))
                     (boolean? (get declaration :unknown?))))
    (throw (ex-info "invalid Jolt effect declaration"
                    {:key key :declaration declaration}))))

(defn configure-declarations!
  "Install exact external effect declarations. A string key applies to every
  arity for compatibility; [fqn {:fixed n}] and
  [fqn {:variadic-min n}] are arity-aware. A declaration is
  {:effects #{...} :unknown? boolean}; omitted :unknown? means false."
  [unit declarations]
  (when-not (map? declarations)
    (throw (ex-info "Jolt effect declarations must be a map"
                    {:declarations declarations})))
  (doseq [[key declaration] declarations]
    (validate-declaration! key declaration))
  (reset! (:effect-declarations unit) declarations)
  (reset! (:effect-reports unit) {})
  unit)

(defn- matching-subject [summaries call]
  (let [f (get call :fqn)
        argc (get call :argc)
        candidates (filter (fn [s]
                             (and (= :var-arity (get-in s [:subject :kind]))
                                  (get s :closed-world?)
                                  (= f (get-in s [:subject :fqn]))))
                           (vals summaries))
        fixed (filterv #(= argc (get-in % [:subject :arity :fixed])) candidates)
        variadic (filterv (fn [s]
                            (let [n (get-in s [:subject :arity :variadic-min])]
                              (and n (>= argc n))))
                          candidates)
        matches (if (seq fixed) fixed variadic)]
    ;; Multiple closed-world definitions for one callable shape are not a
    ;; closed world. Fail conservatively instead of selecting map iteration
    ;; order and attributing another definition's behavior to the call.
    (when (= 1 (count matches)) (first matches))))

(defn- declared-effect [declarations call]
  (let [name (get call :fqn)
        argc (get call :argc)
        exact (get declarations [name {:fixed argc}])
        variadic
        (->> declarations
             (keep (fn [[key declaration]]
                     (when (and (vector? key)
                                (= name (nth key 0 nil))
                                (map? (nth key 1 nil))
                                (integer? (get (nth key 1) :variadic-min))
                                (>= argc (get (nth key 1) :variadic-min)))
                       [(get (nth key 1) :variadic-min) declaration])))
             (sort-by first >)
             first
             second)]
    (or exact variadic (get declarations name))))

(defn- declared-summary [declarations call]
  (when-let [d (declared-effect declarations call)]
    {:closure {:effects (get d :effects #{})
               :aspect-sites #{}
               :checkpoint-sites #{}
               :unresolved #{}
               :unknown-witnesses #{}
               :unknown? (if (get d :unknown?) true false)}}))

(defn- unresolved-witness [call]
  {:kind :unresolved-var :fqn (get call :fqn) :argc (get call :argc)})

(defn- close-one [summaries declarations summary]
  (let [start {:effects (get summary :effects #{})
               :aspect-sites (get summary :aspect-sites #{})
               :checkpoint-sites (get summary :checkpoint-sites #{})
               :transfers (get summary :transfers #{})
               :unresolved #{}
               :unknown-witnesses (set (get summary :opaque-calls))
               :unknown? (boolean
                           (or (not (get summary :closed-world?))
                               (seq (get summary :opaque-calls))))}]
    (reduce
      (fn [acc call]
        (let [target (matching-subject summaries call)
              external (when-not target (declared-summary declarations call))
              closure (cond target (get target :closure)
                            external (get external :closure)
                            :else {:effects #{} :aspect-sites #{}
                                   :checkpoint-sites #{}
                                   :unresolved #{} :unknown-witnesses #{}
                                   :unknown? true})
              missing-witness (when (and (not target) (not external))
                                (unresolved-witness call))]
          (cond-> {:effects (into (get acc :effects) (get closure :effects #{}))
                   :aspect-sites (into (get acc :aspect-sites)
                                       (get closure :aspect-sites #{}))
                   :checkpoint-sites (into (get acc :checkpoint-sites)
                                           (get closure :checkpoint-sites #{}))
                   :transfers (into (get acc :transfers #{})
                                    (get closure :transfers #{}))
                   :unresolved (into (get acc :unresolved #{})
                                     (get closure :unresolved #{}))
                   :unknown-witnesses
                   (into (get acc :unknown-witnesses #{})
                         (get closure :unknown-witnesses #{}))
                   :unknown? (or (get acc :unknown?) (get closure :unknown?))}
            missing-witness
            (assoc :unresolved (conj (get acc :unresolved #{}) missing-witness)
                   :unknown-witnesses
                   (conj (get acc :unknown-witnesses #{}) missing-witness)))))
      start
      (sort-by (fn [call] [(get call :fqn) (get call :argc)])
               (get summary :callees)))))

(defn- set-grows? [before after]
  (every? #(contains? after %) before))

(defn- closure-grows? [before after]
  (and (set-grows? (get before :effects #{}) (get after :effects #{}))
       (set-grows? (get before :aspect-sites #{}) (get after :aspect-sites #{}))
       (set-grows? (get before :checkpoint-sites #{})
                   (get after :checkpoint-sites #{}))
       (set-grows? (get before :transfers #{}) (get after :transfers #{}))
       (set-grows? (get before :unresolved #{}) (get after :unresolved #{}))
       (set-grows? (get before :unknown-witnesses #{})
                   (get after :unknown-witnesses #{}))
       (or (not (get before :unknown?)) (get after :unknown?))))

(defn- close-fixpoint [roots declarations]
  (let [initial (reduce-kv (fn [m k summary]
                             (assoc m k (assoc summary :closure
                                               {:effects (get summary :effects #{})
                                                :aspect-sites (get summary :aspect-sites #{})
                                                :checkpoint-sites
                                                (get summary :checkpoint-sites #{})
                                                :transfers (get summary :transfers #{})
                                                :unresolved #{}
                                                :unknown-witnesses
                                                (set (get summary :opaque-calls))
                                                :unknown? (boolean
                                                            (or (not (get summary :closed-world?))
                                                                (seq (get summary :opaque-calls))))})))
                           {} roots)
        cap (+ 1 (count roots))]
    (loop [i 0 summaries initial]
      (let [next (reduce-kv (fn [m k summary]
                              (assoc m k (assoc summary :closure
                                                (close-one summaries declarations summary))))
                            {} summaries)]
        (doseq [[k before] summaries]
          (when-not (closure-grows? (get before :closure)
                                    (get-in next [k :closure]))
            (throw (ex-info "Jolt effect closure is not monotone"
                            {:subject k
                             :before (get before :closure)
                             :after (get-in next [k :closure])}))))
        (cond
          (= summaries next) next
          (>= i cap)
          (throw (ex-info "Jolt effect summary fixpoint did not converge"
                          {:subjects (count roots)}))
          :else (recur (inc i) next))))))

(defn closed-phase-summaries
  "Return the authoritative, non-canonical closed summaries for phase, keyed by
  subject. Compiler analyses may consume internal analysis nodes from this map;
  build evidence continues to use finalize-phase!'s source-neutral schema."
  [unit phase]
  (when-not (contains? phases phase)
    (throw (ex-info "unknown Jolt effect-analysis phase" {:phase phase})))
  (close-fixpoint (get @(:effect-phase-roots unit) phase {})
                  @(:effect-declarations unit)))

(defn expression-closure-from
  "Close node's immediate evaluation behavior against already-closed summaries
  and external declarations. Contextual nanopasses use this form so one phase
  fixpoint can serve every expression they inspect."
  [summaries declarations node]
  (let [direct (assoc (summarize-eval node) :closed-world? true)]
    (close-one summaries declarations direct)))

(defn expression-closure
  "Close the immediate evaluation behavior of node against phase's unit call
  graph and external declarations. This is the shared substrate for contextual
  analyses such as logical lock regions; it preserves the effect pass's aspect
  helper and opaque-call semantics instead of re-deriving them."
  [unit phase node]
  (expression-closure-from (closed-phase-summaries unit phase)
                           @(:effect-declarations unit)
                           node))

(defn finalize-phase!
  "Compute and retain a deterministic closure report for phase. Missing direct
  callees and opaque calls remain unknown; declarations are the only escape."
  [unit phase]
  (when-not (contains? phases phase)
    (throw (ex-info "unknown Jolt effect-analysis phase" {:phase phase})))
  (let [closed (closed-phase-summaries unit phase)
        summaries (mapv (fn [s]
                          (let [closure (get s :closure)]
                            {:subject (get s :subject)
                             :direct {:effects (get s :effects)
                                      :callees (get s :callees)
                                      :transfers (get s :transfers)
                                      :aspect-sites (get s :aspect-sites)
                                      :checkpoint-sites (get s :checkpoint-sites)
                                      :opaque-calls (get s :opaque-calls)}
                             :closure closure}))
                        (sort-by (fn [s] (pr-str (get s :subject))) (vals closed)))
        report {:schema 1 :analysis "jolt.effects/v1" :phase phase
                :summaries summaries}]
    (swap! (:effect-reports unit) assoc phase report)
    report))

(defn phase-report [unit phase]
  (or (get @(:effect-reports unit) phase)
      (finalize-phase! unit phase)))

(defn- summaries-by-subject [report]
  (into {} (map (fn [s] [(get s :subject) s]) (get report :summaries))))

(defn- phase-stable-subject? [subject]
  ;; Deferred subjects are code identities discovered through transfer sites.
  ;; Optimization may prove a transfer unreachable and remove that subject;
  ;; ordinary callable/top-level subjects must remain phase-stable.
  (not= :deferred-arity (get subject :kind)))

(defn- subject-coverage-findings [from to a b]
  (let [ak (set (filter phase-stable-subject? (keys a)))
        bk (set (filter phase-stable-subject? (keys b)))
        missing (vec (sort-by pr-str (remove bk ak)))
        added (vec (sort-by pr-str (remove ak bk)))]
    (cond-> []
      (seq missing)
      (conj {:rule :jolt.rule/phase-subjects-preserved
             :from from :to to :missing missing})
      (seq added)
      (conj {:rule :jolt.rule/phase-subjects-stable
             :from from :to to :added added}))))

(defn verify-transition!
  "Verify semantic preservation between phase reports. Plain effects must remain
  possible after weaving. Optimization may refine a may-analysis by removing
  possibilities; it may add a concrete effect only when the woven summary was
  already unknown (top). It must not introduce unknown behavior, change the
  subject set, or lose woven aspect-site evidence."
  [unit from to]
  (let [a (summaries-by-subject (phase-report unit from))
        b (summaries-by-subject (phase-report unit to))
        subjects (sort-by pr-str (filter #(contains? b %) (keys a)))
        findings
        (reduce
          (fn [out subject]
            (let [ac (get-in a [subject :closure])
                  bc (get-in b [subject :closure])
                  missing (if (= from :plain)
                            (remove (get bc :effects) (get ac :effects))
                            [])
                  all-added (if (= to :optimized)
                              (remove (get ac :effects) (get bc :effects))
                              [])
                  added (if (get ac :unknown?)
                          (filter #(contains? optimization-protected-effects %)
                                  all-added)
                          all-added)
                  missing-witnesses
                  (if (= from :plain)
                    (remove (get bc :unknown-witnesses #{})
                            (get ac :unknown-witnesses #{}))
                    [])
                  added-witnesses
                  (if (= to :optimized)
                    (remove (get ac :unknown-witnesses #{})
                            (get bc :unknown-witnesses #{}))
                    [])
                  missing-unresolved
                  (if (= from :plain)
                    (remove (get bc :unresolved #{}) (get ac :unresolved #{}))
                    [])
                  added-unresolved
                  (if (= to :optimized)
                    (remove (get ac :unresolved #{}) (get bc :unresolved #{}))
                    [])
                  sites-changed (and (= from :woven) (= to :optimized)
                                     (not= (get ac :aspect-sites)
                                           (get bc :aspect-sites)))
                  checkpoints-changed
                  (and (= from :woven) (= to :optimized)
                       (not= (get ac :checkpoint-sites)
                             (get bc :checkpoint-sites)))
                  missing-transfers
                  (if (= from :plain)
                    (remove (get bc :transfers #{}) (get ac :transfers #{}))
                    [])
                  added-transfers
                  (if (= to :optimized)
                    (remove (get ac :transfers #{}) (get bc :transfers #{}))
                    [])
                  new-unknown (and (= to :optimized)
                                   (not (get ac :unknown?))
                                   (get bc :unknown?))]
              (cond-> out
                (seq missing) (conj {:rule :jolt.rule/plain-effect-preserved
                                     :subject subject :missing (vec missing)})
                (seq added) (conj {:rule :jolt.rule/optimization-adds-no-effect
                                   :subject subject :added (vec added)})
                (seq missing-witnesses)
                (conj {:rule :jolt.rule/plain-unknown-witness-preserved
                       :subject subject
                       :missing (vec (sort-by pr-str missing-witnesses))})
                (seq added-witnesses)
                (conj {:rule :jolt.rule/optimization-adds-no-unknown-witness
                       :subject subject
                       :added (vec (sort-by pr-str added-witnesses))})
                (seq missing-unresolved)
                (conj {:rule :jolt.rule/plain-unresolved-call-preserved
                       :subject subject
                       :missing (vec (sort-by pr-str missing-unresolved))})
                (seq added-unresolved)
                (conj {:rule :jolt.rule/optimization-adds-no-unresolved-call
                       :subject subject
                       :added (vec (sort-by pr-str added-unresolved))})
                (seq missing-transfers)
                (conj {:rule :jolt.rule/plain-transfer-preserved
                       :subject subject
                       :missing (vec (sort-by pr-str missing-transfers))})
                (seq added-transfers)
                (conj {:rule :jolt.rule/optimization-adds-no-transfer
                       :subject subject
                       :added (vec (sort-by pr-str added-transfers))})
                sites-changed (conj {:rule :jolt.rule/aspect-sites-preserved
                                     :subject subject
                                     :before (get ac :aspect-sites)
                                     :after (get bc :aspect-sites)})
                checkpoints-changed
                (conj {:rule :jolt.rule/checkpoint-sites-preserved
                       :subject subject
                       :before (get ac :checkpoint-sites)
                       :after (get bc :checkpoint-sites)})
                new-unknown (conj {:rule :jolt.rule/optimization-adds-no-unknown
                                   :subject subject}))))
          (subject-coverage-findings from to a b)
          subjects)]
    (swap! (:effect-findings unit) into findings)
    findings))

(defn verify-phases!
  "Finalize and verify every currently recorded compiler phase."
  [unit]
  (doseq [phase [:plain :woven :optimized]] (finalize-phase! unit phase))
  (let [empty-phases
        (keep (fn [phase]
                (when (empty? (get (phase-report unit phase) :summaries))
                  {:rule :jolt.rule/phase-has-subjects :phase phase}))
              [:plain :woven :optimized])
        findings (into (vec empty-phases)
                       (into (verify-transition! unit :plain :woven)
                             (verify-transition! unit :woven :optimized)))]
    (when (seq findings)
      (throw (ex-info "Jolt effect-analysis phase invariant failed"
                      {:findings findings})))
    {:schema 1
     :analysis "jolt.effects/verification-v1"
     :phases [:plain :woven :optimized]
     :findings []}))

(defn- ordered-set [xs]
  (vec (sort-by pr-str xs)))

(defn- canonical-checkpoint-sites [sites]
  (mapv (fn [site]
          {:id (get site :id)
           :dispositions (ordered-set (get site :dispositions))})
        (sort-by (comp str :id) sites)))

(defn- canonical-summary [summary]
  (let [direct (get summary :direct)
        closure (get summary :closure)]
    {:subject (get summary :subject)
     :direct {:effects (ordered-set (get direct :effects))
              :callees (vec (sort-by (fn [c] [(get c :fqn) (get c :argc)])
                                     (get direct :callees)))
              :transfers (vec (sort-by pr-str (get direct :transfers)))
              :aspect-sites (vec (sort (get direct :aspect-sites)))
              :checkpoint-sites
              (canonical-checkpoint-sites (get direct :checkpoint-sites))
              :opaque-calls (vec (sort-by pr-str (get direct :opaque-calls)))}
     :closure
     (cond-> {:effects (ordered-set (get closure :effects))
              :aspect-sites (vec (sort (get closure :aspect-sites)))
              :checkpoint-sites
              (canonical-checkpoint-sites (get closure :checkpoint-sites))
              :transfers (vec (sort-by pr-str (get closure :transfers)))
              :unknown? (if (get closure :unknown?) true false)}
       (seq (get closure :unresolved))
       (assoc :unresolved (vec (sort-by (fn [c] [(get c :fqn) (get c :argc)])
                                        (get closure :unresolved))))
       (seq (get closure :unknown-witnesses))
       (assoc :unknown-witnesses
              (vec (sort-by pr-str (get closure :unknown-witnesses)))))}))

(defn- canonical-phase [report]
  (let [summaries (mapv canonical-summary (get report :summaries))]
    {:phase (get report :phase)
     :coverage {:subjects (count summaries)
                :subject-kinds
                (into (sorted-map)
                      (map (fn [[kind xs]] [kind (count xs)])
                           (group-by #(get-in % [:subject :kind]) summaries)))}
     :summaries summaries}))

(defn prepare-build-report!
  "Validate the completed unit and return deterministic, source-neutral effect
  evidence. This does no I/O so a failed native build cannot publish evidence
  for an artifact that was never produced."
  [unit]
  (let [verification (verify-phases! unit)]
    {:schema 1
     :analysis "jolt.effects/build-v1"
     :build-identity @(:aspect-build-identity unit)
     :analysis-context (when-let [cell (get unit :effect-analysis-context)] @cell)
     :analysis-contract
     {:plain-to-woven :effects-preserved
      :woven-to-optimized :may-refinement
      :execution-transfers :separate-deferred-subjects
      :effect-elimination-certificates? false}
     :execution-contracts
     (mapv (fn [[[fqn argc] contract]]
             (assoc contract :fqn fqn :arity {:fixed argc}))
           (sort-by (comp pr-str first) execution-transfer-contracts))
     :declarations
     (mapv (fn [[key declaration]]
             (let [[name arity] (if (vector? key) key [key nil])]
               (cond-> {:fqn name
                        :effects (ordered-set (get declaration :effects #{}))
                        :unknown? (if (get declaration :unknown?) true false)}
                 arity (assoc :arity arity))))
           (sort-by (comp pr-str first) @(:effect-declarations unit)))
     :phases (mapv (fn [phase]
                     (canonical-phase (phase-report unit phase)))
                   [:plain :woven :optimized])
     :verification verification}))

(defn publish-build-report!
  "Atomically publish prepared effect evidence after the output artifact exists."
  [path report]
  (when-let [parent (.getParentFile (io/file path))]
    (.mkdirs parent))
  ;; Jolt's spit owns sibling-temp creation, flush, and atomic replacement.
  (spit path (str (canonical/canonical-str report) "\n"))
  report)
