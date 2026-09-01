(ns jolt.aspects
  "Build-selected, provider-neutral instrumentation aspects.

  Manifests are inert EDN owned by the instrumented library. A separately
  selected provider maps each manifest role to one qualified runtime advice
  var. The compiler resolves and validates that material before a build, then
  this namespace rewrites selected call or function-entry IR before optimization.

  V1 supports resolved var-call join points, optional cooperative call markers,
  and fixed-arity qualified function entries. Selectors are deterministic and
  strict, and none depends on source positions."
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

(defn invoke-control
  "The explicitly enabled, test-only `:control-v1` contract. Advice receives
  `[join-point evaluated-args proceed]`; its return or throw controls the
  application outcome. `proceed` is owner-thread, dynamic-extent, at-most-once,
  and accepts either no arguments or one exact-arity replacement vector."
  [advice join-point evaluated-args operation]
  (clojure.core/__invoke-instrumentation-control
    advice join-point evaluated-args operation))

(defn __at
  "Runtime fallback for the cooperative call-site marker. Compiled code removes
  this boundary in the analyzer; interpreted fallback still evaluates and
  returns the marked expression unchanged."
  [_declaration value]
  value)

(defmacro at
  "Mark one qualified or namespace-aliased call as a cooperative join point.

  The literal declaration is `{:id keyword :role keyword}`. Plain builds retain
  the call's ordinary behavior with no runtime wrapper. `jolt aspects manifest`
  emits the marker through the same schema-1 manifest ABI used by external
  instrumentation packs."
  [declaration expression]
  `(jolt.aspects/__at ~declaration ~expression))

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

(defn- validate-preset [resource preset]
  (when-not (map? preset)
    (fail "preset must be an EDN map" {:resource resource}))
  (reject-unknown-keys "preset" preset #{:schema :id :selections}
                       {:resource resource})
  (when-not (= schema-version (:schema preset))
    (fail "unsupported preset schema"
          {:resource resource :expected schema-version :actual (:schema preset)}))
  (when-not (keyword? (:id preset))
    (fail "preset :id must be a keyword" {:resource resource :id (:id preset)}))
  (when-not (and (vector? (:selections preset)) (seq (:selections preset)))
    (fail "preset :selections must be a non-empty vector" {:resource resource}))
  (doseq [selection (:selections preset)]
    (when-not (map? selection)
      (fail "each preset selection must be a map"
            {:resource resource :selection selection}))
    (reject-unknown-keys "preset selection" selection
                         #{:resource :provider :providers :consumers}
                         {:resource resource :selection selection})
    (when-not (contains? selection :resource)
      (fail "preset selection needs :resource"
            {:resource resource :selection selection})))
  preset)

(defn- expand-selection [selection]
  (when-not (map? selection)
    (fail "each aspect selection must be a map" {:selection selection}))
  (if (contains? selection :preset)
    (do
      (reject-unknown-keys "aspect preset selection" selection #{:preset}
                           {:selection selection})
      (let [resource (:preset selection)
            preset-text (resource-text resource)
            preset (validate-preset resource (edn/read-string preset-text))
            provenance {:id (:id preset)
                        :resource resource
                        :preset-bytes preset-text}]
        (mapv #(hash-map :selection % :preset provenance)
              (:selections preset))))
    [{:selection selection}]))

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
                              (qualified-symbol? (:call m))
                              (or (not (contains? m :marker))
                                  (keyword? (:marker m))))
                         (and entry? (not call?)
                              (qualified-symbol? (:entry m)))))
        (fail (str "v1 :match needs either symbolic :ns plus qualified :call, "
                   "or qualified :entry, and a non-negative integer :arity")
              {:resource resource :aspect (:id aspect) :match m}))
      (reject-unknown-keys "aspect :match" m
                           (if call? #{:ns :call :arity :marker}
                                     #{:entry :arity})
                           {:resource resource :aspect (:id aspect)})
      (when-not (map? (:expect aspect))
        (fail "aspect :expect must be a map" {:resource resource :aspect (:id aspect)}))
      (reject-unknown-keys "aspect :expect" (:expect aspect) #{:matches}
                           {:resource resource :aspect (:id aspect)})
      (when-not (and (int? expected) (pos? expected))
        (fail "v1 :expect needs a positive integer :matches"
              {:resource resource :aspect (:id aspect) :expect (:expect aspect)}))))
  manifest)

;; ---------------------------------------------------------------------------
;; The collector is dynamically scoped across the compiler's nested namespace
;; loads. Explicit owner namespaces keep annotations in transitive dependencies
;; from leaking into the package's published manifest.
(def ^:private ^:dynamic *declaration-sink* nil)
(def ^:private ^:dynamic *declaration-namespaces* #{})

(defn- manifest-from-declarations [library declarations]
  (when-not (and (map? library)
                 (symbol? (:id library))
                 (string? (:version library)))
    (fail "source manifest :library needs symbolic :id and string :version"
          {:library library}))
  (reject-unknown-keys "source manifest :library" library #{:id :version}
                       {:library library})
  (let [aspects (->> declarations (sort-by (comp str :id)) vec)
        ids (map :id aspects)]
    (when-not (= (count ids) (count (distinct ids)))
      (fail "cooperative join-point ids must be unique" {:ids (vec ids)}))
    (when (empty? aspects)
      (fail "source manifest found no cooperative join-point declarations" {}))
    (validate-manifest "<generated>"
                       {:schema schema-version
                        :library library
                        :aspects aspects})))

(defn render-manifest
  "Render generated manifest data deterministically, including a final newline."
  [manifest]
  (let [render-aspect
        (fn [aspect]
          (str "{:id " (pr-str (:id aspect))
               "\n   :match " (canonical-str (:match aspect))
               "\n   :advice-role " (pr-str (:advice-role aspect))
               "\n   :expect " (canonical-str (:expect aspect)) "}"))]
    (str "{:schema " (:schema manifest)
         "\n :library " (canonical-str (:library manifest))
         "\n :aspects\n ["
         (str/join "\n  " (map render-aspect (:aspects manifest)))
         "]}\n")))

(defn collect-manifest
  "Compile configured annotation-owning namespaces and return their manifest.

  `compile!` receives each namespace symbol. Annotation discovery observes the
  same analyzed IR the weaver sees, after ordinary namespace resolution and
  macro expansion. The caller chooses the compile output location."
  [authoring compile!]
  (when-not (map? authoring)
    (fail "deps.edn :jolt/aspects must be a map" {:jolt/aspects authoring}))
  (reject-unknown-keys "deps.edn :jolt/aspects" authoring
                       #{:library :manifest :namespaces} {:jolt/aspects authoring})
  (let [namespaces (:namespaces authoring)]
    (when-not (and (vector? namespaces) (seq namespaces)
                   (every? #(and (symbol? %) (nil? (namespace %))) namespaces))
      (fail "deps.edn :jolt/aspects :namespaces needs a non-empty vector of namespace symbols"
            {:namespaces namespaces}))
    (when-not (= (count namespaces) (count (distinct namespaces)))
      (fail "deps.edn :jolt/aspects :namespaces must be unique"
            {:namespaces namespaces}))
    (let [sink (atom {})]
      (binding [*declaration-sink* sink
                *declaration-namespaces* (set namespaces)]
        (doseq [ns-name namespaces]
          (compile! ns-name)))
      (manifest-from-declarations (:library authoring) (vals @sink)))))

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
        (when-not (contains? #{:args-v1 :replace-args-v1 :control-v1}
                             (:contract advice))
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
  qualified provider var. A `{:preset resource-name}` selection expands a
  package-owned preset into ordinary selections before validation. Legacy
  :provider/:providers selections apply each
  provider to every manifest role. Explicit :consumers selections require a
  fail-closed :roles filter per ordered provider. Test-only `:control-v1`
  consumers additionally require explicit build opt-in. Returns nil for a plain
  build. The returned value is host-neutral data suitable for the host build API."
  ([selections report-path]
   (resolve-build-config selections report-path false))
  ([selections report-path allow-control-aspects?]
  (when-not (contains? #{nil false true} allow-control-aspects?)
    (fail ":jolt/build :allow-control-aspects must be boolean"
          {:allow-control-aspects allow-control-aspects?}))
  (when (seq selections)
    (when-not (vector? selections)
      (fail ":jolt/build :aspects must be a vector" {:aspects selections}))
    (let [expanded-selections (vec (mapcat expand-selection selections))
          resolved
          (mapv
            (fn [{:keys [selection preset]}]
              (let [{:keys [resource]} selection]
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
                 :preset preset
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
                      vec)})))
            expanded-selections)
          aspects (vec (mapcat :aspects resolved))
          ids (map :id aspects)]
      (when-not (= (count ids) (count (distinct ids)))
        (fail "selected aspect ids must be unique" {:ids (vec ids)}))
      (let [control-consumers
            (vec (for [aspect aspects
                       consumer (:consumers aspect)
                       :when (= :control-v1 (:contract consumer))]
                   {:aspect (:id aspect) :provider (:provider consumer)}))]
        (when (and (seq control-consumers) (not= true allow-control-aspects?))
          (fail "control advice requires :jolt/build :allow-control-aspects true"
                {:consumers control-consumers})))
      (let [material {:weaver weaver-version
                      :allow-control-aspects (boolean allow-control-aspects?)
                      :selections
                      (mapv (fn [{:keys [resource preset manifest-bytes providers]}]
                              {:resource resource
                               :preset preset
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
         :control-enabled? (boolean allow-control-aspects?)
         :presets (->> resolved
                       (keep :preset)
                       (map #(select-keys % [:id :resource]))
                       distinct
                       vec)
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
         :report report-path})))))

(defn- aspect-consumers [aspect]
  (or (seq (:consumers aspect))
      [{:ordinal 1
        :provider (:provider aspect)
        :advice (:advice aspect)
        :contract (or (:contract aspect) :proceed-v1)}]))

(defn configure-unit! [unit config]
  (let [control-consumers
        (vec (for [aspect (:aspects config)
                   consumer (aspect-consumers aspect)
                   :when (= :control-v1 (:contract consumer))]
               {:aspect (:id aspect) :provider (:provider consumer)}))]
    (when (and (seq control-consumers)
               (not= true (:control-enabled? config)))
      (fail "control advice reached compiler without explicit enablement"
            {:consumers control-consumers})))
  (reset! (:aspects unit) (vec (or (:aspects config) [])))
  (reset! (:aspect-build-identity unit) (or (:identity config) "plain"))
  (reset! (:aspect-matches unit) {})
  nil)

(defn provider-namespaces [config]
  (vec (or (:providers config) [])))

(defn build-identity [config]
  (or (:identity config) "plain"))

(defn plan-data
  "Return the stable, source-free aspect selection plan for a resolved build.

  Provider and manifest source bytes participate in the build identity during
  resolution but are deliberately absent here. The plan is therefore safe to
  print, diff, cache as evidence, or hand to tooling before compilation."
  [config]
  (if-not config
    {:schema schema-version
     :weaver weaver-version
     :status :plain
     :identity "plain"
     :control-enabled? false
     :presets []
     :providers []
     :aspects []}
    {:schema (:schema config)
     :weaver (:weaver config)
     :status :instrumented
     :identity (:identity config)
     :control-enabled? (:control-enabled? config)
     :presets (vec (:presets config))
     :providers (vec (:providers config))
     :aspects
     (mapv (fn [aspect]
             (-> (select-keys aspect
                              [:id :resource :library :match :advice-role :expect])
                 (assoc :consumers
                        (mapv #(select-keys % [:ordinal :selection-ordinal
                                              :provider :roles :advice :contract])
                              (aspect-consumers aspect)))))
           (:aspects config))}))

(defn- valid-site-position? [position]
  (and (map? position)
       (empty? (remove #{:line :column} (keys position)))
       (every? integer? (vals position))))

(defn- site-identity [build-identity site]
  (stable-identity
    (canonical-str {:build-identity build-identity
                    :site site})))

(defn- validate-observed-site [plan aspect site]
  (when-not (map? site)
    (fail "build report site must be a map"
          {:aspect (:id aspect) :site-type (type site)}))
  (reject-unknown-keys "build report site" site
                       #{:aspect :within :call :entry :marker
                         :arity :ordinal :position :site-id}
                       {:aspect (:id aspect)})
  (let [match (:match aspect)
        call? (contains? match :call)
        marker (:marker match)
        target (if call? (:call match) (:entry match))
        expected-within (if call? (str (:ns match)) (namespace target))
        base-site (select-keys
                    site
                    (cond-> [:aspect :within (if call? :call :entry)
                             :arity :ordinal :position]
                      marker (conj :marker)))
        expected-site-id (site-identity (:identity plan) base-site)]
    (when-not (and (= (:id aspect) (:aspect site))
                   (= expected-within (:within site))
                   (= target (get site (if call? :call :entry)))
                   (= (:arity match) (:arity site))
                   (integer? (:ordinal site))
                   (pos? (:ordinal site))
                   (valid-site-position? (:position site))
                   (= call? (contains? site :call))
                   (= (not call?) (contains? site :entry))
                   (= marker (:marker site))
                   (= (some? marker) (contains? site :marker))
                   (= expected-site-id (:site-id site)))
      (fail "build report site does not match selected aspect"
            {:aspect (:id aspect) :ordinal (:ordinal site)}))
    (assoc base-site :site-id (:site-id site))))

(defn validate-build-report
  "Validate that a report is an observation of this exact static plan.

  Returns a bounded projection containing only aspect ids and source-free site
  identities suitable for display. A matching schema alone is insufficient:
  weaver, build identity, control opt-in, selected aspects, match counts, and
  each reported site must all agree with the plan."
  [plan report]
  (when-not (map? report)
    (fail "build report must be an EDN map" {:report-type (type report)}))
  (reject-unknown-keys "build report" report
                       #{:schema :weaver :identity :control-enabled? :aspects}
                       {})
  (doseq [[key expected] [[:schema (:schema plan)]
                          [:weaver (:weaver plan)]
                          [:identity (:identity plan)]
                          [:control-enabled? (boolean (:control-enabled? plan))]]]
    (when-not (= expected (get report key))
      (fail "build report does not match the selected build"
            {:field key :expected expected :actual (get report key)})))
  (when-not (vector? (:aspects report))
    (fail "build report :aspects must be a vector" {}))
  (let [planned (:aspects plan)
        reported (:aspects report)
        planned-ids (mapv :id planned)
        reported-ids (mapv :id reported)]
    (when-not (= planned-ids reported-ids)
      (fail "build report aspects do not match the selected build"
            {:expected planned-ids :actual reported-ids}))
    {:aspects
     (mapv
      (fn [aspect observed]
        (when-not (map? observed)
          (fail "build report aspect must be a map"
                {:aspect (:id aspect) :aspect-type (type observed)}))
        (let [sites (:sites observed)
              expected (get-in aspect [:expect :matches])]
          (when-not (vector? sites)
            (fail "build report aspect :sites must be a vector"
                  {:aspect (:id aspect)}))
          (when-not (= expected (count sites))
            (fail "build report site count does not match the selected aspect"
                  {:aspect (:id aspect) :expected expected :actual (count sites)}))
          (let [projected (mapv #(validate-observed-site plan aspect %) sites)
                ordinals (mapv :ordinal projected)]
            (when-not (= (vec (range 1 (inc (count projected)))) ordinals)
              (fail "build report site ordinals must be contiguous and ordered"
                    {:aspect (:id aspect) :ordinals ordinals}))
            {:id (:id aspect) :sites projected})))
      planned reported)}))

(defn explain-lines
  "Render a deterministic human explanation of plan and optional build report.

  A plan explains static selection. A report adds observed source sites from an
  actual compile; it is never treated as current merely because it exists."
  ([plan] (explain-lines plan nil nil))
  ([plan report] (explain-lines plan report nil))
  ([plan report report-label]
   (let [report (when report (validate-build-report plan report))
         reported (into {} (map (juxt :id identity)) (:aspects report))]
     (vec
      (concat
       [(str "aspect build: " (name (:status plan)))
        (str "identity: " (:identity plan))
        (str "control advice: " (if (:control-enabled? plan) "enabled" "disabled"))]
       (map (fn [{:keys [id resource]}]
              (str "preset " id " from " resource))
            (:presets plan))
       (when report [(str "observed report: " (or report-label "validated input"))])
       (mapcat
        (fn [aspect]
          (let [observed (get reported (:id aspect))
                sites (:sites observed)]
            (concat
             [(str "aspect " (:id aspect)
                   " library " (get-in aspect [:library :id])
                   "@" (get-in aspect [:library :version]))
              (str "  match " (pr-str (:match aspect))
                   " role " (:advice-role aspect))]
             (map (fn [consumer]
                    (str "  consumer " (:ordinal consumer) " "
                         (:provider consumer) " " (:contract consumer)
                         " -> " (:advice consumer)))
                  (:consumers aspect))
             (when observed
               (cons (str "  observed sites: " (count sites))
                     (map (fn [site] (str "    " (pr-str site))) sites))))))
        (:aspects plan)))))))

(defn- split-fqn [sym]
  [(namespace sym) (name sym)])

(defn- call-match? [owner-ns aspect node]
  (let [{:keys [ns call arity marker]} (:match aspect)
        f (:fn node)
        source-marker (:aspect-marker node)
        [call-ns call-name] (split-fqn call)]
    (and (= :invoke (:op node))
         (= (str ns) owner-ns)
         (= :var (:op f))
         (= call-ns (:ns f))
         (= call-name (:name f))
         (= arity (count (:args node)))
         (or (nil? marker)
             (and (= marker (:id source-marker))
                  (= (:advice-role aspect) (:role source-marker)))))))

(defn- call-site [owner-ns aspect node ordinal]
  (cond->
   {:aspect (:id aspect)
    :within owner-ns
    :call (get-in aspect [:match :call])
    :arity (count (:args node))
    :ordinal ordinal
    ;; Absolute checkout paths make reports needlessly machine-specific.
    :position (select-keys (:pos node) [:line :column])}
    (get-in aspect [:match :marker])
    (assoc :marker (get-in aspect [:match :marker]))))

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

(defn- runtime-site-id [unit site]
  (site-identity @(:aspect-build-identity unit) site))

(defn- runtime-site [unit site]
  ;; Compute from the report descriptor before attaching the identifier, then
  ;; publish the enriched record to both the report and every runtime consumer.
  (assoc site :site-id (runtime-site-id unit site)))

(defn- join-point [unit aspect consumer site]
  (merge (select-keys aspect [:id :library :advice-role :match])
         {:build-identity @(:aspect-build-identity unit)
          :site-id (:site-id site)
          :site site}
         (select-keys consumer [:provider :advice :contract :ordinal])))

(defn- call-consumer-invoke [unit aspect consumer consumers node names site]
  (let [[advice-ns advice-name] (split-fqn (:advice consumer))
        pos (:pos node)
        evaluated-args (ir/vector-node (mapv ir/local names))
        replace-args? (contains? #{:replace-args-v1 :control-v1}
                                 (:contract consumer))
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
        helper-name (case (:contract consumer)
                      :control-v1 "__invoke-instrumentation-control"
                      :replace-args-v1 "__invoke-instrumentation-around-replace-args"
                      "__invoke-instrumentation-around")
        helper-args (if (contains? #{:args-v1 :replace-args-v1 :control-v1}
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
        replace-args? (contains? #{:replace-args-v1 :control-v1}
                                 (:contract consumer))
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
        helper-name (case (:contract consumer)
                      :control-v1 "__invoke-instrumentation-control"
                      :replace-args-v1 "__invoke-instrumentation-around-replace-args"
                      "__invoke-instrumentation-around")
        helper-args (if (contains? #{:args-v1 :replace-args-v1 :control-v1}
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
                    ;; Build form weaving is sequential. This read followed by
                    ;; swap! therefore yields deterministic per-aspect ordinals;
                    ;; parallel form weaving would need one atomic record-site
                    ;; operation instead of preserving this assumption.
                    (let [ordinal (inc (count (get @(:aspect-matches unit)
                                                   (:id aspect))))
                          site (runtime-site
                                 unit (entry-site node aspect arity ordinal))]
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

(defn- entry-declaration [node]
  (when-some [declaration (:aspect-entry node)]
    (when-not (and (= :def (:op node)) (= :fn (get-in node [:init :op])))
      (fail "aspect entry declaration requires a function definition"
            {:namespace (:ns node) :definition (:name node)}))
      (let [data {:namespace (:ns node) :definition (:name node)
                  :declaration declaration}]
        (when-not (map? declaration)
          (fail "aspect entry metadata must be a literal map" data))
        (reject-unknown-keys "aspect entry metadata" declaration
                             #{:id :role :arity} data)
        (when-not (keyword? (:id declaration))
          (fail "annotated entry :id must be a keyword" data))
        (when-not (keyword? (:role declaration))
          (fail "annotated entry :role must be a keyword" data))
        (let [arities (get-in node [:init :arities])
              _ (when (some :rest arities)
                  (fail "annotated function entries must be fixed arity" data))
              available (mapv #(count (:params %)) arities)
              requested (:arity declaration)
              arity (cond
                      (some? requested)
                      (do
                        (when-not (and (int? requested) (not (neg? requested)))
                          (fail "annotated entry :arity must be a non-negative integer" data))
                        (when-not (= 1 (count (filter #(= requested %) available)))
                          (fail "annotated entry :arity must select exactly one function arity"
                                (assoc data :available-arities available)))
                        requested)

                      (= 1 (count available)) (first available)

                      :else
                      (fail "multi-arity annotated entry needs explicit :arity"
                            (assoc data :available-arities available)))]
          {:id (:id declaration)
           :match {:entry (symbol (:ns node) (:name node)) :arity arity}
           :advice-role (:role declaration)
           :expect {:matches 1}}))))

(defn- marker-declaration [owner-ns node]
  (when-some [declaration (:aspect-marker node)]
    (let [f (:fn node)
          data {:namespace owner-ns :declaration declaration}]
      (when-not (and (= :invoke (:op node)) (= :var (:op f)))
        (fail "jolt.aspects/at must resolve to a var call" data))
      {:id (:id declaration)
       :match {:ns (symbol owner-ns)
               :call (symbol (:ns f) (:name f))
               :arity (count (:args node))
               :marker (:id declaration)}
       :advice-role (:role declaration)
       :expect {:matches 1}})))

(defn- record-declaration! [site declaration]
  (swap! *declaration-sink*
         (fn [observed]
           (if-some [prior (get observed site)]
             (do
               (when-not (= prior declaration)
                 (fail "cooperative join point changed while compiling"
                       {:site site :first prior :later declaration}))
               observed)
             (assoc observed site declaration)))))

(defn- collect-declarations! [root]
  (let [owner-ns (str (or (:ns root) (:fnsrc-ns root)))
        root-site [:root owner-ns (:name root) (:pos root)]]
    (when (and *declaration-sink*
               (contains? *declaration-namespaces* (symbol owner-ns)))
      (when-some [entry (entry-declaration root)]
        (when-not (map? (:pos root))
          (fail "cooperative entry declaration has no compiler source position"
                {:entry (get-in entry [:match :entry])}))
        (record-declaration! [:entry root-site] entry))
      (letfn [(walk [node path]
                (when-some [marker (marker-declaration owner-ns node)]
                  (when-not (and (= :def (:op root))
                                 (= :fn (get-in root [:init :op])))
                    (fail "cooperative call declarations must be inside a function definition"
                          {:call (get-in marker [:match :call])
                           :namespace owner-ns}))
                  (when-not (map? (:pos root))
                    (fail "cooperative call declaration has no compiler source position"
                          {:call (get-in marker [:match :call])}))
                  (record-declaration! [:call root-site path] marker))
                (let [child-index (atom -1)]
                  (ir/reduce-ir-children
                   (fn [acc child]
                     (walk child (conj path (swap! child-index inc)))
                     acc)
                   nil node)))]
        (walk root [])))))

(defn weave
  "Rewrite resolved calls selected for this compilation unit.

  Runs bottom-up exactly once, before optimization. Generated advice calls are
  not revisited by this walk. Match counts are accumulated for the build's
  fail-closed finalization and deterministic report."
  [unit root]
  (collect-declarations! root)
  (let [aspects @(:aspects unit)
        owner-ns (str (or (:ns root) (:fnsrc-ns root)))]
    (if (or (:aspect-woven root) (empty? aspects) (str/blank? owner-ns))
      root
      (letfn [(walk [node]
                (let [node (ir/map-ir-children walk node)
                      matches (filterv #(and (contains? (:match %) :call)
                                             (call-match? owner-ns % node))
                                       aspects)]
                  (when (> (count matches) 1)
                    (fail "multiple selected aspects match the same call site"
                          {:site (call-site owner-ns (first matches) node 0)
                           :aspects (mapv :id matches)}))
                  (if-let [aspect (first matches)]
                    ;; See weave-entry-def: ordinals rely on the build's
                    ;; sequential form walk, while swap! owns publication.
                    (let [ordinal (inc (count (get @(:aspect-matches unit) (:id aspect))))
                          site (runtime-site
                                 unit (call-site owner-ns aspect node ordinal))]
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
       :control-enabled? (boolean (:control-enabled? config))
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
