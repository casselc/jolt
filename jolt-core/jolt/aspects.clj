(ns jolt.aspects
  "Build-selected, provider-neutral instrumentation aspects.

  Manifests are inert EDN owned by the instrumented library. A separately
  selected provider maps each manifest role to one qualified runtime advice
  var. The compiler resolves and validates that material before a build, then
  this namespace rewrites selected call or function-entry IR before optimization.

  V1 supports resolved var-call join points and fixed-arity qualified function
  entries. Both selectors are deterministic and strict, and neither depends on
  source positions."
  (:require [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [jolt.ir :as ir]))

(def ^:private schema-version 1)
(def ^:private weaver-version "jolt.aspect-ir/v1")

(defn invoke-around
  "Run synchronous instrumentation advice without allowing it to change the
  application operation's result, exception identity, or execution count.

  Advice receives `[join-point proceed]`. Missing, repeated, or failing advice
  fails open: the operation still runs exactly once. If the operation itself
  throws, that exact exception is rethrown even when advice also fails."
  [advice join-point operation]
  (clojure.core/__invoke-instrumentation-around advice join-point operation))

(defn invoke-around-args
  "The explicit `:args-v1` advice contract. `evaluated-args` is the vector of
  original call arguments after their ordinary left-to-right evaluation.
  Advice receives `[join-point evaluated-args proceed]`; application execution
  and fail-open behavior are otherwise identical to `invoke-around`."
  [advice join-point evaluated-args operation]
  (clojure.core/__invoke-instrumentation-around
    advice join-point evaluated-args operation))

(defn invoke-around-replace-args
  "The explicit `:replace-args-v1` advice contract. Advice sees the original
  evaluated argument vector and may call `proceed` with either no arguments or
  one exact-arity replacement vector. Invalid replacement advice fails open to
  the original vector before application execution."
  [advice join-point evaluated-args operation]
  (clojure.core/__invoke-instrumentation-around-replace-args
    advice join-point evaluated-args operation))

(defn- fail [message data]
  (throw (ex-info (str "jolt aspects: " message) data)))

(defn- qualified-symbol? [x]
  (and (symbol? x) (some? (namespace x))))

(defn- reject-unknown-keys [label value allowed data]
  (let [unknown (seq (remove allowed (keys value)))]
    (when unknown
      (fail (str label " contains unsupported keys")
            (assoc data :unknown (vec (sort-by str unknown)))))))

(defn- canonical-str [x]
  (cond
    (map? x) (str "{" (str/join " "
                           (map (fn [[k v]] (str (canonical-str k) " " (canonical-str v)))
                                (sort-by (comp pr-str key) x))) "}")
    (vector? x) (str "[" (str/join " " (map canonical-str x)) "]")
    (set? x) (str "#{" (str/join " " (map canonical-str (sort-by pr-str x))) "}")
    (seq? x) (str "(" (str/join " " (map canonical-str x)) ")")
    :else (pr-str x)))

(defn- stable-identity [s]
  ;; Artifact/cache separation needs a deterministic full-content identity, not
  ;; a cryptographic claim. Two independent modular lanes keep this compiler
  ;; tier portable (java.security is supplied only by the optional crypto lib).
  (let [step (fn [[a b] ch]
               [(mod (+ (* a 16777619) (int ch)) 4294967291)
                (mod (+ (* b 65599) (int ch)) 4294967279)])
        [a b] (reduce step [2166136261 5381] s)]
    (str "v1-" a "-" b "-" (count s))))

(defn- resource-text [resource]
  (when-not (string? resource)
    (fail "selection :resource must be a string" {:resource resource}))
  (if-let [url (io/resource resource)]
    (slurp url)
    (fail (str "manifest resource not found: " resource) {:resource resource})))

(defn- provider-var-symbol [provider]
  (cond
    (qualified-symbol? provider) provider
    (symbol? provider) (symbol (str provider) "aspect-provider")
    :else (fail "selection providers must be namespaces or qualified var symbols"
                {:provider provider})))

(defn- normalize-consumer-roles [roles consumer]
  (cond
    (= :all roles) :all

    (and (vector? roles) (seq roles))
    (do
      (when-not (every? keyword? roles)
        (fail "selection consumer :roles must contain only keywords"
              {:consumer consumer :roles roles}))
      (when-not (= (count roles) (count (distinct roles)))
        (fail "selection consumer :roles must be unique"
              {:consumer consumer :roles roles}))
      ;; Role order does not affect advice order. Normalize it so equivalent
      ;; filters have the same build identity and report representation.
      (vec (sort-by str roles)))

    :else
    (fail "selection consumer :roles must be :all or a non-empty vector"
          {:consumer consumer :roles roles})))

(defn- selection-consumers [selection]
  (let [provider? (contains? selection :provider)
        providers? (contains? selection :providers)
        consumers? (contains? selection :consumers)
        forms (count (filter true? [provider? providers? consumers?]))]
    (when-not (= 1 forms)
      (fail (str "aspect selection needs exactly one of :provider, :providers, "
                 "or :consumers")
            {:selection selection}))
    (let [raw-consumers
          (cond
            provider? [{:provider (:provider selection) :roles :all}]

            providers?
            (do
              (when-not (and (vector? (:providers selection))
                             (seq (:providers selection)))
                (fail "selection :providers must be a non-empty vector"
                      {:providers (:providers selection)}))
              (mapv #(hash-map :provider % :roles :all) (:providers selection)))

            :else
            (do
              (when-not (and (vector? (:consumers selection))
                             (seq (:consumers selection)))
                (fail "selection :consumers must be a non-empty vector"
                      {:consumers (:consumers selection)}))
              (:consumers selection)))
          consumers
          (mapv
            (fn [selection-ordinal consumer]
              (when-not (map? consumer)
                (fail "each selection consumer must be a map"
                      {:consumer consumer}))
              (reject-unknown-keys "selection consumer" consumer
                                   #{:provider :roles} {:consumer consumer})
              (when-not (contains? consumer :provider)
                (fail "selection consumer needs :provider"
                      {:consumer consumer}))
              (when-not (contains? consumer :roles)
                (fail "selection consumer needs explicit :roles"
                      {:consumer consumer}))
              {:selection-ordinal selection-ordinal
               :provider-var (provider-var-symbol (:provider consumer))
               :roles (normalize-consumer-roles (:roles consumer) consumer)})
            (range 1 (inc (count raw-consumers)))
            raw-consumers)
          provider-vars (mapv :provider-var consumers)]
      (when-not (= (count provider-vars) (count (distinct provider-vars)))
        (fail "selection consumers must name unique providers"
              {:providers provider-vars}))
      consumers)))

(defn- selection-provider-symbols [selection]
  ;; Retained as a narrow compatibility helper for callers/tests that only need
  ;; the selected build roots. Resolution itself uses the richer descriptors.
  (mapv :provider-var (selection-consumers selection)))

(defn- provider-source [provider-ns]
  (let [base (str/replace provider-ns "." "/")]
    (or (when-let [u (io/resource (str base ".clj"))] (slurp u))
        (when-let [u (io/resource (str base ".cljc"))] (slurp u))
        ;; Resolution below is authoritative. Keep a stable sentinel for a
        ;; provider supplied by a preloaded/host namespace without source.
        "::source-unavailable::")))

(defn- validate-manifest [resource manifest]
  (when-not (map? manifest)
    (fail "manifest must be an EDN map" {:resource resource}))
  (reject-unknown-keys "manifest" manifest #{:schema :library :aspects}
                       {:resource resource})
  (when-not (= schema-version (:schema manifest))
    (fail "unsupported manifest schema" {:resource resource
                                          :expected schema-version
                                          :actual (:schema manifest)}))
  (when-not (and (map? (:library manifest))
                 (symbol? (get-in manifest [:library :id]))
                 (string? (get-in manifest [:library :version])))
    (fail "manifest :library needs symbolic :id and string :version"
          {:resource resource :library (:library manifest)}))
  (reject-unknown-keys "manifest :library" (:library manifest) #{:id :version}
                       {:resource resource})
  (when-not (and (vector? (:aspects manifest)) (seq (:aspects manifest)))
    (fail "manifest :aspects must be a non-empty vector" {:resource resource}))
  (doseq [aspect (:aspects manifest)]
    (let [m (:match aspect)
          call? (and (map? m) (contains? m :call))
          entry? (and (map? m) (contains? m :entry))
          expected (get-in aspect [:expect :matches])]
      (when-not (map? aspect)
        (fail "each manifest aspect must be a map" {:resource resource :aspect aspect}))
      (reject-unknown-keys "aspect" aspect #{:id :match :advice-role :expect}
                           {:resource resource :aspect (:id aspect)})
      (when-not (keyword? (:id aspect))
        (fail "aspect :id must be a keyword" {:resource resource :aspect aspect}))
      (when-not (keyword? (:advice-role aspect))
        (fail "aspect :advice-role must be a keyword" {:resource resource :aspect aspect}))
      (when-not (and (map? m)
                     (int? (:arity m)) (not (neg? (:arity m)))
                     (or (and call? (not entry?) (symbol? (:ns m))
                              (qualified-symbol? (:call m)))
                         (and entry? (not call?)
                              (qualified-symbol? (:entry m)))))
        (fail (str "v1 :match needs either symbolic :ns plus qualified :call, "
                   "or qualified :entry, and a non-negative integer :arity")
              {:resource resource :aspect (:id aspect) :match m}))
      (reject-unknown-keys "aspect :match" m
                           (if call? #{:ns :call :arity} #{:entry :arity})
                           {:resource resource :aspect (:id aspect)})
      (when-not (map? (:expect aspect))
        (fail "aspect :expect must be a map" {:resource resource :aspect (:id aspect)}))
      (reject-unknown-keys "aspect :expect" (:expect aspect) #{:matches}
                           {:resource resource :aspect (:id aspect)})
      (when-not (and (int? expected) (pos? expected))
        (fail "v1 :expect needs a positive integer :matches"
              {:resource resource :aspect (:id aspect) :expect (:expect aspect)}))))
  manifest)

(defn- validate-provider [provider-var provider]
  (when-not (and (map? provider) (= schema-version (:schema provider))
                 (map? (:libraries provider)) (map? (:roles provider)))
    (fail "provider var must contain {:schema 1 :libraries {...} :roles {...}}"
          {:provider provider-var}))
  (reject-unknown-keys "provider" provider #{:schema :libraries :roles}
                       {:provider provider-var})
  (doseq [[library version] (:libraries provider)]
    (when-not (and (symbol? library) (string? version))
      (fail "provider :libraries must map library symbols to exact version strings"
            {:provider provider-var :library library :version version})))
  (doseq [[role advice] (:roles provider)]
    (when-not (keyword? role)
      (fail "provider role names must be keywords"
            {:provider provider-var :role role}))
    (cond
      (qualified-symbol? advice) nil

      (map? advice)
      (do
        (reject-unknown-keys "provider role" advice #{:fn :contract}
                             {:provider provider-var :role role})
        (when-not (qualified-symbol? (:fn advice))
          (fail "provider contracted role :fn must be a qualified advice symbol"
                {:provider provider-var :role role :fn (:fn advice)}))
        (when-not (contains? #{:args-v1 :replace-args-v1} (:contract advice))
          (fail "unsupported provider role contract"
                {:provider provider-var :role role :contract (:contract advice)})))

      :else
      (fail "provider roles must map to a qualified advice symbol or a contracted role map"
            {:provider provider-var :role role :advice advice})))
  provider)

(defn- normalize-role [role-value]
  (if (map? role-value)
    {:advice (:fn role-value) :contract (:contract role-value)}
    {:advice role-value :contract :proceed-v1}))

(defn resolve-build-config
  "Resolve and validate deps.edn :jolt/build :aspects selections.

  A provider may name a namespace (whose `aspect-provider` var is used) or a
  qualified provider var. Legacy :provider/:providers selections apply each
  provider to every manifest role. Explicit :consumers selections require a
  fail-closed :roles filter per ordered provider. Returns nil for a plain build.
  The returned value is host-neutral data suitable for the host build API."
  [selections report-path]
  (when (seq selections)
    (when-not (vector? selections)
      (fail ":jolt/build :aspects must be a vector" {:aspects selections}))
    (let [resolved
          (mapv
            (fn [{:keys [resource] :as selection}]
              (when-not (map? selection)
                (fail "each aspect selection must be a map" {:selection selection}))
              (reject-unknown-keys "aspect selection" selection
                                   #{:resource :provider :providers :consumers}
                                   {:selection selection})
              (let [manifest-text (resource-text resource)
                    manifest (validate-manifest resource (edn/read-string manifest-text))
                    library (:library manifest)
                    manifest-roles (set (map :advice-role (:aspects manifest)))
                    selected-consumers (selection-consumers selection)
                    _ (doseq [{:keys [provider-var roles]} selected-consumers
                              :when (not= :all roles)]
                        (let [unknown (vec (remove manifest-roles roles))]
                          (when (seq unknown)
                            (fail "selection consumer names roles absent from the manifest"
                                  {:provider provider-var :resource resource
                                   :roles unknown}))))
                    providers
                    (mapv
                      (fn [{:keys [provider-var roles selection-ordinal]}]
                        (let [provider-value
                              (if-let [v (requiring-resolve provider-var)]
                                (validate-provider provider-var @v)
                                (fail "provider var not found" {:provider provider-var}))
                              provider-ns (namespace provider-var)
                              supported-version
                              (get (:libraries provider-value) (:id library))]
                          (when-not (= (:version library) supported-version)
                            (fail "provider is incompatible with the manifest library revision"
                                  {:provider provider-var :library (:id library)
                                   :manifest-version (:version library)
                                   :provider-version supported-version}))
                          {:provider-var provider-var
                           :provider-ns provider-ns
                           :provider-bytes (provider-source provider-ns)
                           :selection-ordinal selection-ordinal
                           :selected-roles roles
                           :roles (:roles provider-value)}))
                      selected-consumers)]
                {:resource resource
                 :manifest-bytes manifest-text
                 :providers providers
                 :library (:library manifest)
                 :aspects
                 (->> (:aspects manifest)
                      (keep
                        (fn [aspect]
                          (let [role (:advice-role aspect)
                                applicable
                                (filterv
                                  (fn [{:keys [selected-roles]}]
                                    (or (= :all selected-roles)
                                        (some #(= role %) selected-roles)))
                                  providers)]
                            (when (seq applicable)
                              {:id (:id aspect)
                               :resource resource
                               :library (:library manifest)
                               :match (:match aspect)
                               :advice-role role
                               :expect (:expect aspect)
                               :consumers
                               (mapv
                                 (fn [ordinal {:keys [provider-var roles selected-roles
                                                      selection-ordinal]}]
                                   (let [role-value (get roles role)]
                                     (when-not role-value
                                       (fail "provider does not implement selected advice role"
                                             {:provider provider-var :resource resource
                                              :aspect (:id aspect) :role role}))
                                     (merge {:ordinal ordinal
                                             :selection-ordinal selection-ordinal
                                             :provider provider-var
                                             :roles selected-roles}
                                            (normalize-role role-value))))
                                 (range 1 (inc (count applicable)))
                                 applicable)}))))
                      vec)}))
            selections)
          aspects (vec (mapcat :aspects resolved))
          ids (map :id aspects)]
      (when-not (= (count ids) (count (distinct ids)))
        (fail "selected aspect ids must be unique" {:ids (vec ids)}))
      (let [material {:weaver weaver-version
                      :selections
                      (mapv (fn [{:keys [resource manifest-bytes providers]}]
                              {:resource resource
                               :manifest-bytes manifest-bytes
                               :providers
                               (mapv #(select-keys % [:provider-var :provider-bytes
                                                     :selection-ordinal :selected-roles])
                                     providers)})
                            resolved)
                      :aspects aspects}
            identity (stable-identity (canonical-str material))]
        {:schema schema-version
         :weaver weaver-version
         :identity identity
         ;; Both the mapping-var namespace and every runtime advice namespace
         ;; are explicit build roots. They need not be required by app source.
         :providers (vec (distinct
                           (concat
                             (mapcat (fn [selection]
                                       (map :provider-ns (:providers selection)))
                                     resolved)
                             (map (comp namespace :advice)
                                  (mapcat :consumers aspects)))))
         :aspects (vec (sort-by (comp str :id) aspects))
         :report report-path}))))

(defn configure-unit! [unit config]
  (reset! (:aspects unit) (vec (or (:aspects config) [])))
  (reset! (:aspect-build-identity unit) (or (:identity config) "plain"))
  (reset! (:aspect-matches unit) {})
  nil)

(defn provider-namespaces [config]
  (vec (or (:providers config) [])))

(defn build-identity [config]
  (or (:identity config) "plain"))

(defn- split-fqn [sym]
  [(namespace sym) (name sym)])

(defn- call-match? [owner-ns {:keys [ns call arity]} node]
  (let [f (:fn node)
        [call-ns call-name] (split-fqn call)]
    (and (= :invoke (:op node))
         (= (str ns) owner-ns)
         (= :var (:op f))
         (= call-ns (:ns f))
         (= call-name (:name f))
         (= arity (count (:args node))))))

(defn- call-site [owner-ns aspect node ordinal]
  {:aspect (:id aspect)
   :within owner-ns
   :call (get-in aspect [:match :call])
   :arity (count (:args node))
   :ordinal ordinal
   ;; Absolute checkout paths make reports needlessly machine-specific.
   :position (select-keys (:pos node) [:line :column])})

(defn- entry-match? [node aspect arity]
  (let [[entry-ns entry-name] (split-fqn (get-in aspect [:match :entry]))]
    (and (= :def (:op node))
         (= :fn (get-in node [:init :op]))
         (nil? (:rest arity))
         (= entry-ns (:ns node))
         (= entry-name (:name node))
         (= (get-in aspect [:match :arity]) (count (:params arity))))))

(defn- entry-site [node aspect arity ordinal]
  {:aspect (:id aspect)
   :within (:ns node)
   :entry (get-in aspect [:match :entry])
   :arity (count (:params arity))
   :ordinal ordinal
   :position (select-keys (:pos node) [:line :column])})

(defn- fresh-local [unit]
  (str "aspect_arg__" (swap! (:fresh-counter unit) inc)))

(defn- aspect-consumers [aspect]
  (or (seq (:consumers aspect))
      [{:ordinal 1
        :provider (:provider aspect)
        :advice (:advice aspect)
        :contract (or (:contract aspect) :proceed-v1)}]))

(defn- runtime-site-id [unit site]
  (stable-identity
    (canonical-str {:build-identity @(:aspect-build-identity unit)
                    :site site})))

(defn- join-point [unit aspect consumer site]
  (merge (select-keys aspect [:id :library :advice-role :match])
         {:build-identity @(:aspect-build-identity unit)
          :site-id (runtime-site-id unit site)
          :site site}
         (select-keys consumer [:provider :advice :contract :ordinal])))

(defn- call-consumer-invoke [unit aspect consumer consumers node names site]
  (let [[advice-ns advice-name] (split-fqn (:advice consumer))
        pos (:pos node)
        evaluated-args (ir/vector-node (mapv ir/local names))
        replace-args? (= :replace-args-v1 (:contract consumer))
        replacement-names (when replace-args?
                            (mapv (fn [_] (fresh-local unit)) names))
        operation-names (or replacement-names names)
        operation (if-let [next-consumer (first consumers)]
                    (call-consumer-invoke unit aspect next-consumer
                                          (next consumers) node operation-names site)
                    (assoc node :args (mapv ir/local operation-names)))
        advice-ref (cond-> (ir/var-ref advice-ns advice-name) pos (assoc :pos pos))
        join-point-node (ir/quote-node (join-point unit aspect consumer site))
        operation-fn (cond->
                       (ir/fn-node nil [{:params (or replacement-names [])
                                        :body operation}])
                       pos (assoc :pos pos))
        helper-name (if replace-args?
                      "__invoke-instrumentation-around-replace-args"
                      "__invoke-instrumentation-around")
        helper-args (if (contains? #{:args-v1 :replace-args-v1}
                                   (:contract consumer))
                      [advice-ref join-point-node evaluated-args operation-fn]
                      [advice-ref join-point-node operation-fn])
        invoke (ir/invoke (ir/var-ref "clojure.core" helper-name) helper-args)]
    (cond-> invoke pos (assoc :pos pos))))

(defn- advice-invoke [unit aspect node site]
  (let [pos (:pos node)
        names (mapv (fn [_] (fresh-local unit)) (:args node))
        bindings (mapv vector names (:args node))
        consumers (aspect-consumers aspect)
        invoke (call-consumer-invoke unit aspect (first consumers)
                                     (next consumers) node names site)
        wrapped (if (seq bindings) (ir/let-node bindings invoke) invoke)]
    (cond-> wrapped pos (assoc :pos pos))))

(defn- remap-hints [hints old-names new-names]
  (let [by-name (into {} (map vector old-names new-names))]
    (mapv (fn [[name hint]] [(get by-name name name) hint]) hints)))

(defn- entry-consumer-invoke
  [unit aspect consumer consumers arity pos original-names names site]
  (let [[advice-ns advice-name] (split-fqn (:advice consumer))
        evaluated-args (ir/vector-node (mapv ir/local names))
        replace-args? (= :replace-args-v1 (:contract consumer))
        replacement-names (when replace-args?
                            (mapv (fn [_] (fresh-local unit)) names))
        operation-inputs (or replacement-names names)
        operation-body
        (if-let [next-consumer (first consumers)]
          (entry-consumer-invoke unit aspect next-consumer (next consumers)
                                 arity pos original-names operation-inputs site)
          ;; The local loop is the original function's recur target. Moving the
          ;; body directly into proceed's zero-arity thunk would retarget recur
          ;; to that thunk and change advice lifecycle semantics.
          {:op :loop
           :bindings (mapv (fn [name input] [name (ir/local input)])
                           original-names operation-inputs)
           :body (:body arity)})
        operation-arity (cond-> {:params (or replacement-names [])
                                 :body operation-body}
                          (and replace-args? (seq (:nhints arity)))
                          (assoc :nhints (remap-hints (:nhints arity)
                                                     original-names replacement-names)))
        operation-fn (ir/fn-node nil [operation-arity])
        advice-ref (cond-> (ir/var-ref advice-ns advice-name)
                     pos (assoc :pos pos))
        helper-name (if replace-args?
                      "__invoke-instrumentation-around-replace-args"
                      "__invoke-instrumentation-around")
        helper-args (if (contains? #{:args-v1 :replace-args-v1}
                                   (:contract consumer))
                      [advice-ref (ir/quote-node (join-point unit aspect consumer site))
                       evaluated-args operation-fn]
                      [advice-ref (ir/quote-node (join-point unit aspect consumer site))
                       operation-fn])]
    (cond-> (ir/invoke (ir/var-ref "clojure.core" helper-name) helper-args)
      pos (assoc :pos pos))))

(defn- entry-advice-body [unit aspect arity pos site]
  (let [names (:params arity)
        consumers (aspect-consumers aspect)]
    (entry-consumer-invoke unit aspect (first consumers) (next consumers)
                           arity pos names names site)))

(defn- weave-entry-def [unit aspects node]
  (if (and (= :def (:op node)) (= :fn (get-in node [:init :op])))
    (let [entry-aspects (filterv #(contains? (:match %) :entry) aspects)
          arities (get-in node [:init :arities])
          woven-arities
          (when (seq entry-aspects)
            (mapv
              (fn [arity]
                (let [matches (filterv #(entry-match? node % arity) entry-aspects)]
                  (when (> (count matches) 1)
                    (fail "multiple selected aspects match the same function entry"
                          {:site (entry-site node (first matches) arity 0)
                           :aspects (mapv :id matches)}))
                  (if-let [aspect (first matches)]
                    (let [ordinal (inc (count (get @(:aspect-matches unit)
                                                   (:id aspect))))
                          site (entry-site node aspect arity ordinal)]
                      (swap! (:aspect-matches unit) update (:id aspect)
                             (fnil conj []) site)
                      (assoc arity :body
                             (entry-advice-body unit aspect arity (:pos node) site)))
                    arity)))
              arities))]
      (if woven-arities
        (assoc-in node [:init :arities] woven-arities)
        node))
    node))

(defn weave
  "Rewrite resolved calls selected for this compilation unit.

  Runs bottom-up exactly once, before optimization. Generated advice calls are
  not revisited by this walk. Match counts are accumulated for the build's
  fail-closed finalization and deterministic report."
  [unit root]
  (let [aspects @(:aspects unit)
        owner-ns (str (:ns root))]
    (if (or (:aspect-woven root) (empty? aspects) (str/blank? owner-ns))
      root
      (letfn [(walk [node]
                (let [node (ir/map-ir-children walk node)
                      matches (filterv #(and (contains? (:match %) :call)
                                             (call-match? owner-ns (:match %) node))
                                       aspects)]
                  (when (> (count matches) 1)
                    (fail "multiple selected aspects match the same call site"
                          {:site (call-site owner-ns (first matches) node 0)
                           :aspects (mapv :id matches)}))
                  (if-let [aspect (first matches)]
                    (let [ordinal (inc (count (get @(:aspect-matches unit) (:id aspect))))
                          site (call-site owner-ns aspect node ordinal)]
                      (swap! (:aspect-matches unit) update (:id aspect)
                             (fnil conj []) site)
                      (advice-invoke unit aspect node site))
                    node)))]
        (assoc (weave-entry-def unit aspects (walk root)) :aspect-woven true)))))

(defn prepare-build-report!
  "Validate exact match counts and return the deterministic EDN weave report.

  This deliberately performs no filesystem writes. The host build validates
  before native compilation, then publishes the returned report only after the
  output artifact succeeds."
  [unit config]
  (when config
    (let [matches @(:aspect-matches unit)]
      (doseq [aspect (:aspects config)]
        (let [expected (get-in aspect [:expect :matches])
              actual (count (get matches (:id aspect)))]
          (when-not (= expected actual)
            (fail (if (zero? actual) "aspect matched no join points"
                                      "aspect match count was ambiguous")
                  {:aspect (:id aspect) :expected expected :actual actual
                   :match (:match aspect)}))))
      {:schema schema-version
       :weaver (:weaver config)
       :identity (:identity config)
       :aspects
       (mapv (fn [aspect]
               (let [consumers (vec (aspect-consumers aspect))
                     first-consumer (first consumers)]
                 {:id (:id aspect)
                  :resource (:resource aspect)
                  :library (:library aspect)
                  :advice-role (:advice-role aspect)
                  ;; Retained for report schema-v1 readers. :consumers is the
                  ;; authoritative ordered chain when more than one is present.
                  :advice (:advice first-consumer)
                  :contract (:contract first-consumer)
                  :consumers consumers
                  :match (:match aspect)
                  :sites (vec (sort-by :ordinal (get matches (:id aspect))))}))
             (:aspects config))})))

(defn publish-build-report!
  "Atomically publish a previously validated report after artifact success."
  [config report]
  (when (and config report)
    (when-let [parent (.getParentFile (io/file (:report config)))]
      (.mkdirs parent))
    ;; Jolt's spit writes through a sibling temporary and renames on success.
    (spit (:report config) (str (canonical-str report) "\n"))
    report))

(defn finish-build!
  "Compatibility entry point: validate and immediately publish the report."
  [unit config]
  (when-let [report (prepare-build-report! unit config)]
    (publish-build-report! config report)))
