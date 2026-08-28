(ns jolt.aspects
  "Build-selected, provider-neutral instrumentation aspects.

  Manifests are inert EDN owned by the instrumented library. A separately
  selected provider maps each manifest role to one qualified runtime advice
  var. The compiler resolves and validates that material before a build, then
  this namespace rewrites resolved call IR before optimization.

  V1 deliberately supports only resolved var-call join points. It is small
  enough to keep matching deterministic and strict while establishing a public
  compiler extension point that does not depend on source positions."
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
    :else (fail "selection :provider must be a namespace or qualified var symbol"
                {:provider provider})))

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
          expected (get-in aspect [:expect :matches])]
      (when-not (map? aspect)
        (fail "each manifest aspect must be a map" {:resource resource :aspect aspect}))
      (reject-unknown-keys "aspect" aspect #{:id :match :advice-role :expect}
                           {:resource resource :aspect (:id aspect)})
      (when-not (keyword? (:id aspect))
        (fail "aspect :id must be a keyword" {:resource resource :aspect aspect}))
      (when-not (keyword? (:advice-role aspect))
        (fail "aspect :advice-role must be a keyword" {:resource resource :aspect aspect}))
      (when-not (and (map? m) (symbol? (:ns m))
                     (qualified-symbol? (:call m))
                     (int? (:arity m)) (not (neg? (:arity m))))
        (fail "v1 :match needs symbolic :ns, qualified :call, and non-negative integer :arity"
              {:resource resource :aspect (:id aspect) :match m}))
      (reject-unknown-keys "aspect :match" m #{:ns :call :arity}
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
    (when-not (and (keyword? role) (qualified-symbol? advice))
      (fail "provider roles must map keywords to qualified advice symbols"
            {:provider provider-var :role role :advice advice})))
  provider)

(defn resolve-build-config
  "Resolve and validate deps.edn :jolt/build :aspects selections.

  A provider may name a namespace (whose `aspect-provider` var is used) or a
  qualified provider var. Returns nil for a plain build. The returned value is
  host-neutral data suitable for passing into the host build API."
  [selections report-path]
  (when (seq selections)
    (when-not (vector? selections)
      (fail ":jolt/build :aspects must be a vector" {:aspects selections}))
    (let [resolved
          (mapv
            (fn [{:keys [resource provider] :as selection}]
              (when-not (map? selection)
                (fail "each aspect selection must be a map" {:selection selection}))
              (reject-unknown-keys "aspect selection" selection #{:resource :provider}
                                   {:selection selection})
              (let [manifest-text (resource-text resource)
                    manifest (validate-manifest resource (edn/read-string manifest-text))
                    provider-var (provider-var-symbol provider)
                    provider-value (if-let [v (requiring-resolve provider-var)]
                                     (validate-provider provider-var @v)
                                     (fail "provider var not found" {:provider provider-var}))
                    provider-ns (namespace provider-var)
                    roles (:roles provider-value)
                    library (:library manifest)
                    supported-version (get (:libraries provider-value) (:id library))]
                (when-not (= (:version library) supported-version)
                  (fail "provider is incompatible with the manifest library revision"
                        {:provider provider-var :library (:id library)
                         :manifest-version (:version library)
                         :provider-version supported-version}))
                {:resource resource
                 :manifest-bytes manifest-text
                 :provider-var provider-var
                 :provider-ns provider-ns
                 :provider-bytes (provider-source provider-ns)
                 :library (:library manifest)
                 :aspects
                 (mapv (fn [aspect]
                         (let [role (:advice-role aspect)
                               advice (get roles role)]
                           (when-not advice
                             (fail "provider does not implement selected advice role"
                                   {:provider provider-var :resource resource
                                    :aspect (:id aspect) :role role}))
                           {:id (:id aspect)
                            :resource resource
                            :library (:library manifest)
                            :match (:match aspect)
                            :advice-role role
                            :advice advice
                            :expect (:expect aspect)}))
                       (:aspects manifest))}))
            selections)
          aspects (vec (mapcat :aspects resolved))
          ids (map :id aspects)]
      (when-not (= (count ids) (count (distinct ids)))
        (fail "selected aspect ids must be unique" {:ids (vec ids)}))
      (let [material {:weaver weaver-version
                      :selections (mapv #(select-keys % [:resource :manifest-bytes
                                                        :provider-var :provider-bytes]) resolved)
                      :aspects aspects}
            identity (stable-identity (canonical-str material))]
        {:schema schema-version
         :weaver weaver-version
         :identity identity
         ;; Both the mapping-var namespace and every runtime advice namespace
         ;; are explicit build roots. They need not be required by app source.
         :providers (vec (distinct
                           (concat (map :provider-ns resolved)
                                   (map (comp namespace :advice) aspects))))
         :aspects (vec (sort-by (comp str :id) aspects))
         :report report-path}))))

(defn configure-unit! [unit config]
  (reset! (:aspects unit) (vec (or (:aspects config) [])))
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

(defn- site [owner-ns aspect node ordinal]
  {:aspect (:id aspect)
   :within owner-ns
   :call (get-in aspect [:match :call])
   :arity (count (:args node))
   :ordinal ordinal
   ;; Absolute checkout paths make reports needlessly machine-specific.
   :position (select-keys (:pos node) [:line :column])})

(defn- fresh-local [unit]
  (str "aspect_arg__" (swap! (:fresh-counter unit) inc)))

(defn- advice-invoke [unit aspect node]
  (let [[advice-ns advice-name] (split-fqn (:advice aspect))
        pos (:pos node)
        join-point (select-keys aspect [:id :library :advice-role :match])
        names (mapv (fn [_] (fresh-local unit)) (:args node))
        bindings (mapv vector names (:args node))
        operation (assoc node :args (mapv ir/local names))
        invoke (ir/invoke
                 (ir/var-ref "clojure.core" "__invoke-instrumentation-around")
                 [(cond-> (ir/var-ref advice-ns advice-name) pos (assoc :pos pos))
                  (ir/quote-node join-point)
                  (cond-> (ir/fn-node nil [{:params [] :body operation}]) pos (assoc :pos pos))])
        wrapped (if (seq bindings) (ir/let-node bindings invoke) invoke)]
    (cond-> wrapped pos (assoc :pos pos))))

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
                      matches (filterv #(call-match? owner-ns (:match %) node) aspects)]
                  (when (> (count matches) 1)
                    (fail "multiple selected aspects match the same call site"
                          {:site (site owner-ns (first matches) node 0)
                           :aspects (mapv :id matches)}))
                  (if-let [aspect (first matches)]
                    (let [ordinal (inc (count (get @(:aspect-matches unit) (:id aspect))))]
                      (swap! (:aspect-matches unit) update (:id aspect)
                             (fnil conj []) (site owner-ns aspect node ordinal))
                      (advice-invoke unit aspect node))
                    node)))]
        (assoc (walk root) :aspect-woven true)))))

(defn finish-build!
  "Validate exact match counts and write the deterministic EDN weave report."
  [unit config]
  (when config
    (let [matches @(:aspect-matches unit)]
      (doseq [aspect (:aspects config)]
        (let [expected (get-in aspect [:expect :matches])
              actual (count (get matches (:id aspect)))]
          (when-not (= expected actual)
            (fail (if (zero? actual) "aspect matched no call sites"
                                      "aspect match count was ambiguous")
                  {:aspect (:id aspect) :expected expected :actual actual
                   :match (:match aspect)}))))
      (let [report {:schema schema-version
                    :weaver (:weaver config)
                    :identity (:identity config)
                    :aspects
                    (mapv (fn [aspect]
                            {:id (:id aspect)
                             :resource (:resource aspect)
                             :library (:library aspect)
                             :advice-role (:advice-role aspect)
                             :advice (:advice aspect)
                             :match (:match aspect)
                             :sites (vec (sort-by :ordinal (get matches (:id aspect))))})
                          (:aspects config))}]
        (when-let [parent (.getParentFile (io/file (:report config)))]
          (.mkdirs parent))
        (spit (:report config) (str (canonical-str report) "\n"))
        report))))
