(ns jolt.passes.regions
  "Contextual structural-region analysis over Jolt IR and effect summaries.

  This pass intentionally distinguishes logical object monitors from Chez's
  counted runtime mutexes. A Jolt logical monitor may span a fiber park; a known
  carrier-blocking native call is forbidden while it is held. Bare
  monitor-enter/monitor-exit forms require control-flow pairing and are reported
  as explicit limitations rather than being mis-modeled as lexical regions."
  (:require [jolt.ir :refer [reduce-ir-children]]
            [jolt.passes.effects :as effects]))

(def phases [:plain :woven :optimized])
(def monitor-helper "jolt.host/with-monitor")
(def bare-monitor-ops #{"jolt.host/monitor-enter" "jolt.host/monitor-exit"})

(defn- fqn [node]
  (when (= :var (get node :op))
    (str (get node :ns) "/" (get node :name))))

(defn- position [node]
  (select-keys (get node :pos) [:line :column]))

(defn- empty-result []
  {:regions [] :findings [] :limitations []})

(defn- merge-results [a b]
  {:regions (into (get a :regions []) (get b :regions []))
   :findings (into (get a :findings []) (get b :findings []))
   :limitations (into (get a :limitations []) (get b :limitations []))})

(defn- merge-all [xs]
  (reduce merge-results (empty-result) xs))

(defn- fixed-zero-arity-body [node]
  (when (and (= :fn (get node :op))
             (= 1 (count (get node :arities))))
    (let [arity (first (get node :arities))]
      (when (and (empty? (get arity :params))
                 (not (get arity :rest)))
        (get arity :body)))))

(defn- call-boundary? [node]
  (contains? #{:invoke :host-call :host-new} (get node :op)))

(defn- canonical-effects [xs]
  (vec (sort-by str xs)))

(declare scan-node)

(defn- scan-children [ctx node regions]
  (reduce-ir-children
    (fn [acc child]
      (merge-results acc (scan-node ctx child regions)))
    (empty-result)
    node))

(defn- scan-call [ctx node regions]
  (if (empty? regions)
    (empty-result)
    (let [closure (effects/expression-closure-from
                    (get ctx :summaries) (get ctx :declarations) node)
          effect-set (get closure :effects #{})
          observation {:subject (get ctx :subject)
                       :region-stack (vec regions)
                       :site (position node)
                       :effects (canonical-effects effect-set)
                       :unknown? (if (get closure :unknown?) true false)}
          blocking? (contains? effect-set :jolt.effect/native-block)
          unknown? (get closure :unknown?)]
      {:regions [observation]
       :findings
       (if blocking?
         [{:rule :jolt.rule/no-native-block-under-logical-monitor
           :subject (get ctx :subject)
           :region-stack (vec regions)
           :site (position node)
           :effects (canonical-effects effect-set)}]
         [])
       :limitations
       (if unknown?
         [{:rule :jolt.rule/unknown-call-under-logical-monitor
           :subject (get ctx :subject)
           :region-stack (vec regions)
           :site (position node)
           :unknown-witnesses
           (vec (sort-by pr-str (get closure :unknown-witnesses #{})))}]
         [])})))

(defn- scan-monitor-helper [ctx node regions]
  (let [args (get node :args)
        lock-node (nth args 0 nil)
        thunk-node (nth args 1 nil)
        body (fixed-zero-arity-body thunk-node)
        outer-evaluation (merge-all
                           [(scan-node ctx (get node :fn) regions)
                            (if lock-node
                              (scan-node ctx lock-node regions)
                              (empty-result))])
        region {:kind :jolt.region/logical-monitor
                :site (position node)}]
    (if (and (= 2 (count args)) body)
      (merge-results outer-evaluation
                     (scan-node ctx body (conj regions region)))
      (merge-results
        outer-evaluation
        {:regions [] :findings []
         :limitations
         [{:rule :jolt.rule/unsupported-monitor-helper-shape
           :subject (get ctx :subject)
           :site (position node)
           :argc (count args)}]}))))

(defn- scan-bare-monitor [ctx node regions]
  (merge-results
    (scan-children ctx node regions)
    {:regions [] :findings []
     :limitations
     [{:rule :jolt.rule/bare-monitor-requires-control-flow-analysis
       :subject (get ctx :subject)
       :operation (fqn (get node :fn))
       :site (position node)}]}))

(defn- scan-node [ctx node regions]
  (let [op (get node :op)
        target (when (= :invoke op) (fqn (get node :fn)))]
    (cond
      ;; Function construction is effect-free. The one exception is the
      ;; with-monitor contract below, which synchronously invokes its literal
      ;; operation thunk and therefore scans that body in region context.
      (= :fn op) (empty-result)
      (= target monitor-helper) (scan-monitor-helper ctx node regions)
      (contains? bare-monitor-ops target) (scan-bare-monitor ctx node regions)
      (call-boundary? node) (scan-call ctx node regions)
      :else (scan-children ctx node regions))))

(defn analyze-phase
  "Return deterministic logical-region observations, hard findings, and
  explicit analysis limitations for one compiler phase."
  [unit phase]
  (let [summaries (effects/closed-phase-summaries unit phase)
        declarations @(:effect-declarations unit)
        analyzed
        (for [[subject summary] (sort-by (comp pr-str first) summaries)
              :let [node (get summary :analysis-node)]
              :when node]
          (scan-node {:subject subject
                      :summaries summaries
                      :declarations declarations}
                     node []))
        result (merge-all analyzed)]
    {:phase phase
     :coverage {:subjects (count summaries)
                :analyzed-subjects (count (filter #(get (second %) :analysis-node)
                                                  summaries))}
     :regions (vec (sort-by pr-str (distinct (:regions result))))
     :findings (vec (sort-by pr-str (distinct (:findings result))))
     :limitations (vec (sort-by pr-str (distinct (:limitations result))))}))

(defn prepare-build-report!
  "Prepare structural-region evidence. Known native blocking under a logical
  monitor is a compiler safety failure; explicit CFG limitations remain visible
  in evidence without pretending the lexical pass proved them safe."
  [unit]
  (let [phase-reports (mapv #(analyze-phase unit %) phases)
        findings (vec (mapcat :findings phase-reports))]
    (when (seq findings)
      (throw (ex-info "Jolt region-analysis invariant failed"
                      {:findings findings})))
    {:schema 1
     :analysis "jolt.regions/build-v1"
     :build-identity @(:aspect-build-identity unit)
     :analysis-contract
     {:lexical-region-stacks? true
      :transitive-effects? true
      :interprocedural-region-stacks? false
      :bare-monitor-control-flow? false}
     :phases phase-reports
     :verification {:analysis "jolt.regions/verification-v1"
                    :phases phases
                    :findings []}}))

(defn publish-build-report!
  "Publish prepared region evidence through the effect pass's atomic writer."
  [path report]
  (effects/publish-build-report! path report))
