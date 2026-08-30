(ns effect-summary-ir-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is run-tests testing]]
            [jolt.aspect-contracts :as aspect-contracts]
            [jolt.ir :as ir]
            [jolt.passes.effects :as effects]))

(defn unit []
  {:effect-phase-roots (atom {:plain {} :woven {} :optimized {}})
   :effect-analysis-context (atom nil)
   :effect-source-ids (atom {})
   :effect-declarations (atom {})
   :effect-reports (atom {})
   :effect-findings (atom [])
   :aspect-build-identity (atom "plain")})

(defn fixed-def [fqn argc body]
  (let [[ns name] (str/split fqn #"/" 2)]
    (ir/def-node ns name
                 (ir/fn-node name
                             [{:params (mapv #(str "p" %) (range argc))
                               :body body}]))))

(defn variadic-def [fqn min-argc body]
  (let [[ns name] (str/split fqn #"/" 2)]
    (ir/def-node ns name
                 (ir/fn-node name
                             [{:params (mapv #(str "p" %) (range min-argc))
                               :rest "more"
                               :body body}]))))

(defn call [fqn args]
  (let [[ns name] (str/split fqn #"/" 2)]
    (ir/invoke (ir/var-ref ns name) args)))

(defn summary [report fqn]
  (some #(when (and (= :var-arity (get-in % [:subject :kind]))
                    (= fqn (get-in % [:subject :fqn])))
           %)
        (:summaries report)))

(defn subject-summary [report kind fqn]
  (some #(when (and (= kind (get-in % [:subject :kind]))
                    (= fqn (get-in % [:subject :fqn])))
           %)
        (:summaries report)))

(deftest every-aspect-contract-has-one-round-trip-helper-shape
  (doseq [contract (sort (keys aspect-contracts/contracts))]
    (let [spec (aspect-contracts/contract-spec contract)]
      (is (= contract
             (:contract
               (aspect-contracts/helper-call-spec
                 (:helper-fqn spec) (:helper-argc spec)))))))
  (is (= (set (map :helper-fqn
                   (map aspect-contracts/contract-spec
                        (keys aspect-contracts/contracts))))
         aspect-contracts/helper-fqns)))

(deftest direct-and-transitive-effects-use-a-whole-unit-fixpoint
  (let [u (unit)
        root (fixed-def "app/root" 0 (call "app/middle" []))
        middle (fixed-def "app/middle" 0 (call "app/leaf" []))
        leaf (fixed-def "app/leaf" 0 (call "runtime/dispatch" []))]
    (effects/configure-declarations!
      u {"runtime/dispatch" {:effects #{:jolt.effect/user-dispatch}}})
    ;; Deliberately record callers before callees: forward order cannot affect
    ;; the unit closure.
    (doseq [node [root middle leaf]]
      (effects/record-phase! u :plain node))
    (let [report (effects/finalize-phase! u :plain)]
      (is (empty? (get-in (summary report "app/root") [:direct :effects])))
      (is (= #{:jolt.effect/user-dispatch}
             (get-in (summary report "app/root") [:closure :effects])))
      (is (false? (get-in (summary report "app/root") [:closure :unknown?]))))))

(deftest dynamic-invocation-fails-closed-with-a-witness
  (let [u (unit)
        node (fixed-def "app/run" 1
                        (assoc (ir/invoke (ir/local "p0") [])
                               :pos {:file "run.clj" :line 7 :column 3}))]
    (effects/record-phase! u :plain node)
    (let [s (summary (effects/finalize-phase! u :plain) "app/run")]
      (is (= #{:jolt.effect/user-dispatch} (get-in s [:direct :effects])))
      (is (= [{:kind :dynamic-invoke
               :position {:line 7 :column 3}}]
             (get-in s [:direct :opaque-calls])))
      (is (true? (get-in s [:closure :unknown?]))))))

(deftest deferred-function-body-is-not-an-immediate-effect
  (let [u (unit)
        node (fixed-def "app/make-callback" 0
                        (ir/fn-node nil [{:params []
                                         :body (ir/invoke (ir/local "unknown") [])}]))]
    (effects/record-phase! u :plain node)
    (let [s (summary (effects/finalize-phase! u :plain) "app/make-callback")]
      (is (empty? (get-in s [:direct :effects])))
      (is (false? (get-in s [:closure :unknown?]))))))

(deftest top-level-initializers-and-bare-forms-are-explicit-subjects
  (let [u (unit)
        init (assoc (ir/def-node "app" "db" (call "runtime/open" []))
                    :pos {:file "/checkout/app.clj" :line 3 :column 1})
        bare (assoc (call "runtime/register" [])
                    :fnsrc-ns "app"
                    :pos {:file "/checkout/app.clj" :line 8 :column 1})]
    (effects/configure-declarations!
      u {"runtime/open" {:effects #{:effect/open}}
         "runtime/register" {:effects #{:effect/register}}})
    (doseq [node [init bare]] (effects/record-phase! u :plain node))
    (let [report (effects/finalize-phase! u :plain)
          init-summary (subject-summary report :var-init "app/db")
          top-summary (some #(when (= :top-level-form
                                      (get-in % [:subject :kind])) %)
                            (:summaries report))]
      (is (= #{:effect/open} (get-in init-summary [:closure :effects])))
      (is (= #{:effect/register} (get-in top-summary [:closure :effects])))
      (is (= {:line 8 :column 1}
             (get-in top-summary [:subject :position])))
      (is (not (str/includes? (pr-str report) "/checkout"))))))

(deftest declare-metadata-evaluation-is-not-dropped-by-the-ir-contract
  (let [u (unit)
        declaration {:op :def :ns "app" :name "later" :no-init true
                     :meta-expr (call "runtime/meta" [])
                     :pos {:line 4 :column 1}}]
    (effects/configure-declarations!
      u {"runtime/meta" {:effects #{:effect/meta}}})
    (effects/record-phase! u :plain declaration)
    (is (= #{:effect/meta}
           (get-in (subject-summary (effects/finalize-phase! u :plain)
                                    :var-init "app/later")
                   [:closure :effects])))))

(deftest repeated-phase-observation-must-be-identical
  (let [u (unit)
        positioned #(assoc % :fnsrc-ns "app" :pos {:line 5 :column 2})]
    (effects/record-phase! u :plain (positioned (call "app/first" [])))
    (is (thrown-with-msg?
          clojure.lang.ExceptionInfo
          #"effect subject changed within one phase"
          (effects/record-phase! u :plain
                                 (positioned (call "app/later" [])))))))

(deftest distinct-source-files-cannot-collide-at-the-same-position
  (let [u (unit)
        positioned (fn [file target]
                     (assoc (call target [])
                            :fnsrc-ns "app"
                            :pos {:file file :line 5 :column 2}))]
    (effects/record-phase! u :plain (positioned "/one/src/app.clj" "app/first"))
    (effects/record-phase! u :plain (positioned "/two/src/app.clj" "app/second"))
    (let [report (effects/finalize-phase! u :plain)
          subjects (mapv :subject (:summaries report))
          rendered (pr-str report)]
      (is (= 2 (count subjects)))
      (is (= #{{:ordinal 0} {:ordinal 1}} (set (map :source-id subjects))))
      (is (not (str/includes? rendered "/one")))
      (is (not (str/includes? rendered "/two"))))))

(deftest compiler-mode-context-starts-a-fresh-evidence-epoch
  (let [u (unit)
        positioned #(assoc % :fnsrc-ns "app" :pos {:line 5 :column 2})]
    (effects/configure-analysis-context! u {:inline-enabled? true})
    (effects/record-phase! u :optimized
                           (positioned (call "app/inlined-result" [])))
    (effects/configure-analysis-context! u {:inline-enabled? false})
    (effects/record-phase! u :optimized
                           (positioned (call "app/original-call" [])))
    (let [report (effects/finalize-phase! u :optimized)]
      (is (= {:inline-enabled? false} @(:effect-analysis-context u)))
      (is (= #{{:fqn "app/original-call" :argc 0}}
             (get-in (first (:summaries report)) [:direct :callees]))))))

(deftest optimized-top-level-tree-keeps-the-woven-root-identity
  (let [u (unit)
        woven (assoc (call "app/boot" [])
                     :fnsrc-ns "app"
                     :pos {:file "/checkout/app.clj" :line 9 :column 1})
        optimized (assoc (call "runtime/require" [(ir/quote-node 'app.dynamic)])
                         :pos {:file "/checkout/app.clj" :line 4 :column 16})]
    (effects/configure-declarations!
      u {"app/boot" {:effects #{:effect/boot}}
         "runtime/require" {:effects #{:effect/require}}})
    (effects/record-phase! u :woven woven true)
    (effects/record-phase! u :optimized optimized true woven)
    (let [woven-subject (get-in (first (:summaries
                                         (effects/finalize-phase! u :woven)))
                                [:subject])
          optimized-summary (first (:summaries
                                     (effects/finalize-phase! u :optimized)))]
      (is (= woven-subject (:subject optimized-summary)))
      (is (= #{:effect/require}
             (get-in optimized-summary [:closure :effects]))))))

(deftest variadic-target-is-resolved-by-minimum-arity
  (let [u (unit)
        root (fixed-def "app/root" 0
                        (call "app/collect" [(ir/const 1) (ir/const 2)]))
        collect (variadic-def "app/collect" 1 (call "runtime/dispatch" []))]
    (effects/configure-declarations!
      u {"runtime/dispatch" {:effects #{:jolt.effect/user-dispatch}}})
    (doseq [node [root collect]] (effects/record-phase! u :plain node))
    (is (= #{:jolt.effect/user-dispatch}
           (get-in (summary (effects/finalize-phase! u :plain) "app/root")
                   [:closure :effects])))))

(deftest unresolved-and-redefinable-targets-remain-unknown
  (testing "missing direct target"
    (let [u (unit)]
      (effects/record-phase! u :plain
                             (fixed-def "app/root" 0 (call "missing/work" [])))
      (let [s (summary (effects/finalize-phase! u :plain) "app/root")]
        (is (true? (get-in s [:closure :unknown?])))
        (is (= #{{:kind :unresolved-var :fqn "missing/work" :argc 0}}
               (get-in s [:closure :unresolved]))))))
  (testing "closed-world opt-out"
    (let [u (unit)
          node (assoc (fixed-def "app/redef" 0 (ir/const nil))
                      :meta {:redef true})]
      (effects/record-phase! u :plain node)
      (is (true? (get-in (summary (effects/finalize-phase! u :plain) "app/redef")
                         [:closure :unknown?]))))))

(deftest woven-helper-composes-advice-operation-and-site-evidence
  (let [u (unit)
        target (fixed-def "app/target" 0 (call "runtime/park" []))
        advice (fixed-def "obs/advice" 2 (call "runtime/log" []))
        plain-root (fixed-def "app/root" 0 (call "app/target" []))
        join-point {:site-id "site-1"}
        operation (ir/fn-node nil [{:params [] :body (call "app/target" [])}])
        woven-root
        (fixed-def "app/root" 0
                   (ir/invoke
                     (ir/var-ref "clojure.core" "__invoke-instrumentation-around")
                     [(ir/var-ref "obs" "advice")
                      (assoc (ir/quote-node join-point) :aspect-site-id "site-1")
                      operation]))]
    (effects/configure-declarations!
      u {"runtime/park" {:effects #{:jolt.effect/park}}
         "runtime/log" {:effects #{:jolt.effect/log}}})
    (doseq [node [target advice plain-root]]
      (effects/record-phase! u :plain node))
    (doseq [node [target advice woven-root]]
      (effects/record-phase! u :woven node)
      (effects/record-phase! u :optimized node))
    (is (= #{:jolt.effect/park}
           (get-in (summary (effects/finalize-phase! u :plain) "app/root")
                   [:closure :effects])))
    (let [woven (summary (effects/finalize-phase! u :woven) "app/root")]
      (is (= #{:jolt.effect/park :jolt.effect/log :jolt.effect/user-dispatch}
             (get-in woven [:closure :effects])))
      (is (= #{"site-1"} (get-in woven [:closure :aspect-sites])))
      (is (false? (get-in woven [:closure :unknown?]))))
    (is (= [] (effects/verify-transition! u :plain :woven)))
    (is (= [] (effects/verify-transition! u :woven :optimized)))
    (is (= [] (:findings (effects/verify-phases! u))))))

(deftest unsupported-aspect-helper-shape-fails-closed
  (let [u (unit)
        node (fixed-def
               "app/root" 0
               (assoc
                 (ir/invoke
                   (ir/var-ref "clojure.core" "__invoke-instrumentation-around")
                   [(ir/var-ref "obs" "advice") (ir/quote-node {})])
                 :pos {:line 12 :column 4}))]
    (effects/record-phase! u :plain node)
    (let [s (summary (effects/finalize-phase! u :plain) "app/root")]
      (is (= #{:jolt.effect/user-dispatch} (get-in s [:direct :effects])))
      (is (= [{:kind :aspect-helper-shape
               :position {:line 12 :column 4}}]
             (get-in s [:direct :opaque-calls])))
      (is (true? (get-in s [:closure :unknown?]))))))

(deftest ambiguous-callable-definitions-never-use-map-order
  (let [u (unit)
        root (fixed-def "app/root" 0 (call "app/dup" []))
        first-def (assoc (fixed-def "app/dup" 0 (call "runtime/first" []))
                         :pos {:file "/a/dup.clj" :line 1 :column 1})
        second-def (assoc (fixed-def "app/dup" 0 (call "runtime/second" []))
                          :pos {:file "/b/dup.clj" :line 1 :column 1})]
    (effects/configure-declarations!
      u {"runtime/first" {:effects #{:effect/first}}
         "runtime/second" {:effects #{:effect/second}}})
    (doseq [node [root first-def second-def]]
      (effects/record-phase! u :plain node))
    (let [closure (get-in (summary (effects/finalize-phase! u :plain) "app/root")
                          [:closure])]
      (is (true? (:unknown? closure)))
      (is (empty? (:effects closure))))))

(deftest optimized-phase-cannot-lose-aspect-site-or-gain-effect
  (let [u (unit)
        base (fixed-def "app/root" 0 (ir/const nil))
        site-node
        (fixed-def "app/root" 0
                   (ir/invoke
                     (ir/var-ref "clojure.core" "__invoke-instrumentation-around")
                     [(ir/var-ref "obs" "advice")
                      (assoc (ir/quote-node {:site-id "site-1"})
                             :aspect-site-id "site-1")
                      (ir/fn-node nil [{:params [] :body (ir/const nil)}])]))
        added (fixed-def "app/root" 0
                         (ir/do-node [(call "runtime/new-effect" [])]
                                     (ir/invoke (ir/local "f") [])))]
    (effects/configure-declarations!
      u {"obs/advice" {:effects #{}}
         "runtime/new-effect" {:effects #{:jolt.effect/new}}})
    (effects/record-phase! u :plain base)
    (effects/record-phase! u :woven site-node)
    (effects/record-phase! u :optimized added)
    (let [rules (set (map :rule
                          (effects/verify-transition! u :woven :optimized)))]
      (is (contains? rules :jolt.rule/aspect-sites-preserved))
      (is (contains? rules :jolt.rule/optimization-adds-no-effect))
      (is (contains? rules :jolt.rule/optimization-adds-no-unknown)))))

(deftest phase-coverage-cannot-disappear-or-pass-vacuously
  (let [u (unit)
        node (fixed-def "app/root" 0 (ir/const nil))]
    (effects/record-phase! u :plain node)
    (let [rules (set (map :rule
                          (effects/verify-transition! u :plain :woven)))]
      (is (contains? rules :jolt.rule/phase-subjects-preserved)))
    (is (thrown-with-msg?
          clojure.lang.ExceptionInfo
          #"phase invariant failed"
          (effects/verify-phases! u)))))

(deftest optimization-may-refine-an-unknown-summary
  (let [u (unit)
        unknown (fixed-def "app/root" 0 (ir/invoke (ir/local "f") []))
        known (fixed-def "app/root" 0 (call "runtime/known" []))]
    (effects/configure-declarations!
      u {"runtime/known" {:effects #{:effect/known}}})
    (effects/record-phase! u :woven unknown)
    (effects/record-phase! u :optimized known)
    (is (empty? (effects/verify-transition! u :woven :optimized)))))

(deftest recursive-call-graph-converges
  (let [u (unit)
        a (fixed-def "app/a" 0 (call "app/b" []))
        b (fixed-def "app/b" 0
                     (ir/do-node [(call "runtime/dispatch" [])]
                                 (call "app/a" [])))]
    (effects/configure-declarations!
      u {"runtime/dispatch" {:effects #{:jolt.effect/user-dispatch}}})
    (doseq [node [a b]] (effects/record-phase! u :plain node))
    (let [report (effects/finalize-phase! u :plain)]
      (is (= #{:jolt.effect/user-dispatch}
             (get-in (summary report "app/a") [:closure :effects])))
      (is (false? (get-in (summary report "app/a") [:closure :unknown?]))))))

(deftest opaque-witnesses-propagate-through-callers
  (let [u (unit)
        root (fixed-def "app/root" 0 (call "app/leaf" []))
        leaf (fixed-def "app/leaf" 0
                        (assoc {:op :host-call
                                :target (ir/local "receiver")
                                :method "work"
                                :args []}
                               :pos {:line 9 :column 4}))]
    (doseq [node [root leaf]] (effects/record-phase! u :plain node))
    (let [closure (get-in (summary (effects/finalize-phase! u :plain) "app/root")
                          [:closure])]
      (is (true? (:unknown? closure)))
      (is (= #{{:kind :host-call :position {:line 9 :column 4}}}
             (:unknown-witnesses closure))))))

(deftest build-evidence-is-deterministic-and-set-free
  (let [u (unit)
        b (fixed-def "z/b" 0 (call "runtime/b" []))
        a (fixed-def "a/a" 0 (call "runtime/a" []))]
    ;; The build report also records the exact declaration boundary that made an
    ;; otherwise external call known.
    (reset! (:aspect-build-identity u) "test-build")
    (effects/configure-declarations!
      u {"runtime/b" {:effects #{:effect/z :effect/a}}
         "runtime/a" {:effects #{:effect/b}}})
    (doseq [phase [:plain :woven :optimized]
            node [b a]]
      (effects/record-phase! u phase node))
    (let [first-report (effects/prepare-build-report! u)
          second-report (effects/prepare-build-report! u)
          rendered (pr-str first-report)]
      (is (= first-report second-report))
      (is (= "test-build" (:build-identity first-report)))
      (is (= {:plain-to-woven :effects-preserved
              :woven-to-optimized :may-refinement
              :effect-elimination-certificates? false}
             (:analysis-contract first-report)))
      (is (= ["runtime/a" "runtime/b"]
             (mapv :fqn (:declarations first-report))))
      (is (= [:effect/a :effect/z]
             (get-in first-report [:declarations 1 :effects])))
      (is (= {:subjects 4 :subject-kinds {:var-arity 2 :var-init 2}}
             (get-in first-report [:phases 0 :coverage])))
      (is (not (str/includes? rendered "#{"))))))

(let [{:keys [fail error]} (run-tests)]
  (when (pos? (+ fail error)) (System/exit 1)))
