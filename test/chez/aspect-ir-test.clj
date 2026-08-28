(ns aspect-ir-test
  (:require [clojure.edn :as edn]
            [clojure.test :refer [deftest is testing run-tests]]
            [jolt.aspects :as aspects]
            [jolt.ir :as ir]
            [jolt.passes.types :as types]))

(def config
  {:aspects
   [{:id :test/call
     :library {:id 'test/lib :version "v1"}
     :match {:ns 'app.core :call 'dep.lib/work :arity 2}
     :advice-role :test/around
     :advice 'provider.core/around
     :expect {:matches 1}}]})

(def args-config
  (assoc-in config [:aspects 0 :contract] :args-v1))

(def replace-args-config
  (assoc-in config [:aspects 0 :contract] :replace-args-v1))

(def manifest-fixture
  {:schema 1
   :library {:id 'test/lib :version "v1"}
   :aspects [{:id :test/call
              :match {:ns 'app.core :call 'dep.lib/work :arity 2}
              :advice-role :test/around
              :expect {:matches 1}}]})

(def provider-fixture
  {:schema 1
   :libraries {'test/lib "v1"}
   :roles {:test/around {:fn 'provider.core/around
                         :contract :args-v1}}})

(defn resolve-build-config-with [manifests provider selections]
  (with-redefs-fn
    {(ns-resolve 'jolt.aspects 'resource-text)
     (fn [resource] (pr-str (get manifests resource)))
     (ns-resolve 'jolt.aspects 'provider-source)
     (fn [_] "provider-source")
     (ns-resolve 'clojure.core 'requiring-resolve)
     (fn [provider-var]
       (when (= 'provider.core/aspect-provider provider-var)
         (atom provider)))}
    #(aspects/resolve-build-config selections nil)))

(defn resolve-error [manifests provider selections]
  (try
    (resolve-build-config-with manifests provider selections)
    nil
    (catch Exception e
      {:message (ex-message e) :data (ex-data e)})))

(def multi-consumer-config
  {:aspects
   [(-> (first (:aspects config))
        (dissoc :advice :contract)
        (assoc :consumers
               [{:ordinal 1
                :provider 'provider.outer/aspect-provider
                 :advice 'provider.outer/around
                 :contract :replace-args-v1}
                {:ordinal 2
                 :provider 'provider.middle/aspect-provider
                 :advice 'provider.middle/around
                 :contract :args-v1}
                {:ordinal 3
                 :provider 'provider.inner/aspect-provider
                 :advice 'provider.inner/around
                  :contract :replace-args-v1}]))]})

(def entry-config
  {:aspects
   [{:id :test/entry
     :library {:id 'test/lib :version "v1"}
     :match {:entry 'app.core/callback :arity 1}
     :advice-role :test/around
     :advice 'provider.core/around
     :contract :args-v1
     :expect {:matches 1}}]})

(defn entry-node []
  (assoc
    (ir/def-node
      "app.core" "callback"
      (ir/fn-node "callback"
                  [{:params ["x"]
                    :body {:op :recur :args [(ir/local "x")]}}]))
    :pos {:file "/private/checkout/core.clj" :line 30 :column 1}))

(defn invoke-node []
  (assoc (ir/invoke (ir/var-ref "dep.lib" "work")
                    [(ir/invoke (ir/var-ref "app.core" "left") [])
                     (ir/invoke (ir/var-ref "app.core" "right") [])])
         :pos {:file "/private/checkout/core.clj" :line 12 :column 7}))

(deftest resolved-call-weaving
  (let [unit (types/new-unit)
        _ (aspects/configure-unit! unit config)
        root (ir/def-node "app.core" "run" (invoke-node))
        woven (aspects/weave unit root)
        body (:init woven)
        bindings (:bindings body)
        helper (:body body)
        thunk (nth (:args helper) 2)
        original (get-in thunk [:arities 0 :body])]
    (is (:aspect-woven woven))
    (is (= :let (:op body)))
    (is (= 2 (count bindings)))
    (is (= ["left" "right"] (mapv #(get-in % [1 :fn :name]) bindings)))
    (is (= ["aspect_arg__1" "aspect_arg__2"] (mapv first bindings)))
    (is (= ["aspect_arg__1" "aspect_arg__2"] (mapv :name (:args original))))
    (is (= "clojure.core" (get-in helper [:fn :ns])))
    (is (= "__invoke-instrumentation-around" (get-in helper [:fn :name])))
    (is (= {:line 12 :column 7}
           (get-in @(:aspect-matches unit) [:test/call 0 :position])))
    (is (empty? (ir/tree-problems woven)))
    (is (= woven (aspects/weave unit woven)))))

(deftest args-contract-weaving
  (let [unit (types/new-unit)
        _ (aspects/configure-unit! unit args-config)
        woven (aspects/weave unit (ir/def-node "app.core" "run" (invoke-node)))
        body (:init woven)
        helper (:body body)
        evaluated-args (nth (:args helper) 2)
        thunk (nth (:args helper) 3)]
    (is (= ["left" "right"] (mapv #(get-in % [1 :fn :name]) (:bindings body))))
    (is (= :vector (:op evaluated-args)))
    (is (= ["aspect_arg__1" "aspect_arg__2"]
           (mapv :name (:items evaluated-args))))
    (is (= :args-v1 (get-in helper [:args 1 :form :contract])))
    (is (= ["aspect_arg__1" "aspect_arg__2"]
           (mapv :name (get-in thunk [:arities 0 :body :args]))))
    (is (empty? (ir/tree-problems woven)))
    (let [configured (assoc args-config :schema 1 :weaver "test/v1"
                                        :identity "args-contract" :report "/tmp/unused")
          report (aspects/prepare-build-report! unit configured)]
      (is (= :args-v1 (get-in report [:aspects 0 :contract]))))))

(deftest replace-args-contract-weaving
  (let [unit (types/new-unit)
        _ (aspects/configure-unit! unit replace-args-config)
        woven (aspects/weave unit (ir/def-node "app.core" "run" (invoke-node)))
        body (:init woven)
        helper (:body body)
        evaluated-args (nth (:args helper) 2)
        operation (nth (:args helper) 3)
        params (get-in operation [:arities 0 :params])
        target (get-in operation [:arities 0 :body])]
    (is (= ["left" "right"] (mapv #(get-in % [1 :fn :name]) (:bindings body))))
    (is (= "__invoke-instrumentation-around-replace-args"
           (get-in helper [:fn :name])))
    (is (= ["aspect_arg__1" "aspect_arg__2"]
           (mapv :name (:items evaluated-args))))
    (is (= ["aspect_arg__3" "aspect_arg__4"] params))
    (is (= params (mapv :name (:args target))))
    (is (= :replace-args-v1 (get-in helper [:args 1 :form :contract])))
    (is (empty? (ir/tree-problems woven)))
    (let [configured (assoc replace-args-config :schema 1 :weaver "test/v1"
                                                :identity "replace-args-contract"
                                                :report "/tmp/unused")
          report (aspects/prepare-build-report! unit configured)]
      (is (= :replace-args-v1 (get-in report [:aspects 0 :contract]))))))

(deftest ordered-multi-consumer-call-weaving
  (let [unit (types/new-unit)
        _ (aspects/configure-unit! unit multi-consumer-config)
        woven (aspects/weave unit (ir/def-node "app.core" "run" (invoke-node)))
        body (:init woven)
        outer (:body body)
        outer-operation (nth (:args outer) 3)
        middle (get-in outer-operation [:arities 0 :body])
        middle-operation (nth (:args middle) 3)
        inner (get-in middle-operation [:arities 0 :body])
        inner-operation (nth (:args inner) 3)
        target (get-in inner-operation [:arities 0 :body])]
    (is (= ["left" "right"]
           (mapv #(get-in % [1 :fn :name]) (:bindings body)))
        "application arguments are evaluated once outside the whole chain")
    (is (= "provider.outer" (get-in outer [:args 0 :ns])))
    (is (= 1 (get-in outer [:args 1 :form :ordinal])))
    (is (= 'provider.outer/aspect-provider
           (get-in outer [:args 1 :form :provider])))
    (is (= ["aspect_arg__3" "aspect_arg__4"]
           (get-in outer-operation [:arities 0 :params])))
    (is (= "provider.middle" (get-in middle [:args 0 :ns])))
    (is (= 2 (get-in middle [:args 1 :form :ordinal])))
    (is (= ["aspect_arg__3" "aspect_arg__4"]
           (mapv :name (get-in middle [:args 2 :items])))
        "outer replacements become the observational consumer's inputs")
    (is (= [] (get-in middle-operation [:arities 0 :params])))
    (is (= "provider.inner" (get-in inner [:args 0 :ns])))
    (is (= 3 (get-in inner [:args 1 :form :ordinal])))
    (is (= ["aspect_arg__3" "aspect_arg__4"]
           (mapv :name (get-in inner [:args 2 :items])))
        "non-replacing advice passes the current arguments downstream")
    (is (= ["aspect_arg__5" "aspect_arg__6"]
           (mapv :name (:args target)))
        "inner replacement arguments reach the application target")
    (is (= 1 (count (get @(:aspect-matches unit) :test/call)))
        "consumer count does not multiply logical join-point matches")
    (is (empty? (ir/tree-problems woven)))))

(deftest fixed-function-entry-weaving
  (let [unit (types/new-unit)
        _ (aspects/configure-unit! unit entry-config)
        woven (aspects/weave unit (entry-node))
        arity (get-in woven [:init :arities 0])
        helper (:body arity)
        evaluated-args (nth (:args helper) 2)
        operation (nth (:args helper) 3)
        operation-arity (get-in operation [:arities 0])
        loop-node (:body operation-arity)]
    (is (= ["x"] (:params arity)) "the public function signature is unchanged")
    (is (= "__invoke-instrumentation-around" (get-in helper [:fn :name])))
    (is (= :args-v1 (get-in helper [:args 1 :form :contract])))
    (is (= ["x"] (mapv :name (:items evaluated-args))))
    (is (= [] (:params operation-arity)))
    (is (= :loop (:op loop-node)))
    (is (= [["x" {:op :local :name "x"}]] (:bindings loop-node)))
    (is (= :recur (get-in loop-node [:body :op]))
        "the original recur remains inside the compiler-generated loop")
    (is (= {:line 30 :column 1}
           (get-in @(:aspect-matches unit) [:test/entry 0 :position])))
    (is (= 'app.core/callback
           (get-in @(:aspect-matches unit) [:test/entry 0 :entry])))
    (is (= "app.core"
           (get-in @(:aspect-matches unit) [:test/entry 0 :within])))
    (is (empty? (ir/tree-problems woven)))))

(deftest replace-args-function-entry-weaving
  (let [unit (types/new-unit)
        configured (assoc-in entry-config [:aspects 0 :contract]
                             :replace-args-v1)
        hinted (assoc-in (entry-node) [:init :arities 0 :nhints]
                         [["x" :long]])
        _ (aspects/configure-unit! unit configured)
        woven (aspects/weave unit hinted)
        helper (get-in woven [:init :arities 0 :body])
        operation-arity (get-in helper [:args 3 :arities 0])
        replacement (first (:params operation-arity))]
    (is (= "__invoke-instrumentation-around-replace-args"
           (get-in helper [:fn :name])))
    (is (= [[replacement :long]] (:nhints operation-arity))
        "replacement values retain the entry parameter's runtime coercion")
    (is (= [["x" {:op :local :name replacement}]]
           (get-in operation-arity [:body :bindings])))
    (is (empty? (ir/tree-problems woven)))))

(deftest ordered-multi-consumer-entry-weaving
  (let [unit (types/new-unit)
        configured
        {:aspects
         [(-> (first (:aspects entry-config))
              (dissoc :advice :contract)
              (assoc :consumers
                      [{:ordinal 1 :provider 'provider.outer/aspect-provider
                        :advice 'provider.outer/around
                        :contract :replace-args-v1}
                      {:ordinal 2 :provider 'provider.middle/aspect-provider
                       :advice 'provider.middle/around
                       :contract :args-v1}
                      {:ordinal 3 :provider 'provider.inner/aspect-provider
                       :advice 'provider.inner/around
                       :contract :replace-args-v1}]))]}
        hinted (assoc-in (entry-node) [:init :arities 0 :nhints] [["x" :long]])
        _ (aspects/configure-unit! unit configured)
        woven (aspects/weave unit hinted)
        outer (get-in woven [:init :arities 0 :body])
        outer-operation (nth (:args outer) 3)
        outer-param (first (get-in outer-operation [:arities 0 :params]))
        middle (get-in outer-operation [:arities 0 :body])
        middle-operation (nth (:args middle) 3)
        inner (get-in middle-operation [:arities 0 :body])
        inner-operation (nth (:args inner) 3)
        inner-param (first (get-in inner-operation [:arities 0 :params]))
        loop-node (get-in inner-operation [:arities 0 :body])]
    (is (= "provider.outer" (get-in outer [:args 0 :ns])))
    (is (= "provider.middle" (get-in middle [:args 0 :ns])))
    (is (= "provider.inner" (get-in inner [:args 0 :ns])))
    (is (= [outer-param] (mapv :name (get-in middle [:args 2 :items])))
        "outer entry replacement flows into observational advice")
    (is (= [] (get-in middle-operation [:arities 0 :params])))
    (is (= [outer-param] (mapv :name (get-in inner [:args 2 :items])))
        "observational entry advice passes the replacement downstream")
    (is (= [[outer-param :long]]
           (get-in outer-operation [:arities 0 :nhints])))
    (is (= [[inner-param :long]]
           (get-in inner-operation [:arities 0 :nhints])))
    (is (= :loop (:op loop-node)))
    (is (= [["x" {:op :local :name inner-param}]] (:bindings loop-node)))
    (is (= :recur (get-in loop-node [:body :op]))
        "one innermost compiler loop retains the original recur target")
    (is (= 1 (count (get @(:aspect-matches unit) :test/entry)))
        "the entry is reported once regardless of consumer count")
    (is (empty? (ir/tree-problems woven)))))

(deftest function-entry-exactness-and-overlap
  (doseq [node [(assoc (entry-node) :name "other")
                (assoc-in (entry-node) [:init :arities 0 :params] ["x" "y"])
                (assoc-in (entry-node) [:init :arities 0 :rest] "more")
                (assoc (entry-node) :init (ir/const :not-a-function))]]
    (let [unit (types/new-unit)
          _ (aspects/configure-unit! unit entry-config)
          woven (aspects/weave unit node)]
      (is (empty? @(:aspect-matches unit)))
      (is (= (:init node) (:init woven)))))
  (let [unit (types/new-unit)
        overlap (update entry-config :aspects conj
                        (assoc (first (:aspects entry-config)) :id :test/other-entry))
        _ (aspects/configure-unit! unit overlap)
        message (try
                  (aspects/weave unit (entry-node))
                  nil
                  (catch Exception e (ex-message e)))]
    (is (= "jolt aspects: multiple selected aspects match the same function entry"
           message))))

(deftest multi-arity-function-entry-weaving
  (let [base (first (:aspects entry-config))
        selected {:aspects
                  [(assoc base :id :test/entry-one
                               :match {:entry 'app.core/multi :arity 1})
                   (assoc base :id :test/entry-two
                               :match {:entry 'app.core/multi :arity 2})]}
        node (assoc
               (ir/def-node
                 "app.core" "multi"
                 (ir/fn-node "multi"
                             [{:params ["x"] :body (ir/local "x")}
                              {:params ["x" "y"] :body (ir/local "y")}]))
               :pos {:file "/private/checkout/core.clj" :line 40 :column 1})
        unit (types/new-unit)
        _ (aspects/configure-unit! unit selected)
        woven (aspects/weave unit node)
        arities (get-in woven [:init :arities])]
    (is (= [:test/entry-one :test/entry-two]
           (mapv #(get-in % [:body :args 1 :form :id]) arities)))
    (is (= [1 2] (mapv #(count (:params %)) arities))
        "entry selectors preserve and distinguish public arities")
    (is (= {:test/entry-one [1] :test/entry-two [1]}
           (into {} (map (fn [[id sites]] [id (mapv :ordinal sites)]))
                 @(:aspect-matches unit))))
    (is (empty? (ir/tree-problems woven)))))

(deftest manifest-selector-schema
  (let [validate-manifest (ns-resolve 'jolt.aspects 'validate-manifest)
        manifest (fn [match]
                   {:schema 1
                    :library {:id 'test/lib :version "v1"}
                    :aspects [{:id :test/selector
                               :match match
                               :advice-role :test/around
                               :expect {:matches 1}}]})]
    (is (= {:entry 'app.core/callback :arity 1}
           (get-in (validate-manifest
                     "test.edn"
                     (manifest {:entry 'app.core/callback :arity 1}))
                   [:aspects 0 :match])))
    (doseq [match [{:entry 'callback :arity 1}
                   {:ns 'app.core :call 'dep.lib/work
                    :entry 'app.core/callback :arity 1}
                   {:entry 'app.core/callback :arity -1}]]
      (is (= (str "jolt aspects: v1 :match needs either symbolic :ns plus "
                  "qualified :call, or qualified :entry, and a non-negative "
                  "integer :arity")
             (try
               (validate-manifest "test.edn" (manifest match))
               nil
               (catch Exception e (ex-message e))))))))

(deftest exact-resolved-match
  (doseq [node [(assoc (invoke-node) :fn (ir/var-ref "other.lib" "work"))
                (assoc (invoke-node) :args [(ir/const 1)])]]
    (let [unit (types/new-unit)
          _ (aspects/configure-unit! unit config)
          woven (aspects/weave unit (ir/def-node "app.core" "run" node))]
      (is (= node (:init woven)))
      (is (empty? @(:aspect-matches unit))))))

(deftest overlap-and-ordinal-safety
  (testing "two selected aspects cannot claim one call site"
    (let [unit (types/new-unit)
          overlapping (update config :aspects conj
                              (assoc (first (:aspects config)) :id :test/other))
          _ (aspects/configure-unit! unit overlapping)
          message (try
                    (aspects/weave unit (ir/def-node "app.core" "run" (invoke-node)))
                    nil
                    (catch Exception e (ex-message e)))]
      (is (= "jolt aspects: multiple selected aspects match the same call site" message))))
  (testing "one aspect numbers multiple sites in deterministic preorder"
    (let [unit (types/new-unit)
          _ (aspects/configure-unit! unit config)
          root (ir/def-node "app.core" "run"
                            (ir/do-node [(invoke-node)] (invoke-node)))]
      (aspects/weave unit root)
      (is (= [1 2] (mapv :ordinal (get @(:aspect-matches unit) :test/call)))))))

(deftest invoke-around-semantics
  (testing "provider result cannot replace the application result"
    (is (= 42 (aspects/invoke-around (fn [_ proceed] (proceed) :wrong) {:id :x} (fn [] 42)))))
  (testing "missing and failing advice fail open"
    (is (= :ran (aspects/invoke-around (fn [_ _] :skipped) {:id :x} (fn [] :ran))))
    (is (= :ran (aspects/invoke-around (fn [_ _] (throw (Exception. "advice")))
                                       {:id :x} (fn [] :ran)))))
  (testing "repeated proceed still executes the application exactly once"
    (let [calls (atom 0)]
      (is (= :ran
             (aspects/invoke-around (fn [_ proceed] (proceed) (proceed))
                                    {:id :x}
                                    (fn [] (swap! calls inc) :ran))))
      (is (= 1 @calls))))
  (testing "advice failure after proceed cannot replace a completed result"
    (let [calls (atom 0)]
      (is (= :ran
             (aspects/invoke-around (fn [_ proceed]
                                      (proceed)
                                      (throw (Exception. "after")))
                                    {:id :x}
                                    (fn [] (swap! calls inc) :ran))))
      (is (= 1 @calls))))
  (testing "an application exception retains identity"
    (let [boom (Exception. "app")
          seen (atom nil)]
      (try
        (aspects/invoke-around (fn [_ proceed] (proceed)) {:id :x} (fn [] (throw boom)))
        (catch Exception e (reset! seen e)))
      (is (identical? boom @seen)))))

(deftest invoke-around-args-semantics
  (testing "evaluated arguments reach advice after left-to-right evaluation"
    (let [events (atom [])
          args [(do (swap! events conj :left) "left")
                (do (swap! events conj :right) "right")]
          result (aspects/invoke-around-args
                   (fn [_ seen proceed]
                     (swap! events conj [:advice seen])
                     (proceed)
                     :replacement)
                   {:id :x} args
                   (fn [] (swap! events conj :operation) :application))]
      (is (= :application result))
      (is (= [:left :right [:advice ["left" "right"]] :operation] @events))))
  (testing "args advice skip, throw, and double proceed all fail open"
    (doseq [advice [(fn [_ _ _] :skip)
                    (fn [_ _ _] (throw (Exception. "advice")))
                    (fn [_ _ proceed] (proceed) (proceed))]]
      (let [calls (atom 0)]
        (is (= :application
               (aspects/invoke-around-args advice {:id :x} [:arg]
                                           (fn [] (swap! calls inc) :application))))
        (is (= 1 @calls)))))
  (testing "args advice preserves the application exception object"
    (let [boom (Exception. "app")
          seen (atom nil)]
      (try
        (aspects/invoke-around-args (fn [_ _ proceed] (proceed))
                                    {:id :x} [:arg] (fn [] (throw boom)))
        (catch Exception e (reset! seen e)))
      (is (identical? boom @seen)))))

(deftest invoke-around-replace-args-semantics
  (testing "zero proceed calls fail open to the original evaluated vector"
    (let [calls (atom [])]
      (is (= "left:right"
             (aspects/invoke-around-replace-args
               (fn [_ seen _] (is (= ["left" "right"] seen)) :skip)
               {:id :x} ["left" "right"]
               (fn [left right]
                 (swap! calls conj [left right])
                 (str left ":" right)))))
      (is (= [["left" "right"]] @calls))))
  (testing "one proceed call may supply one exact-arity replacement vector"
    (let [calls (atom [])]
      (is (= "new-left:new-right"
             (aspects/invoke-around-replace-args
               (fn [_ _ proceed] (proceed ["new-left" "new-right"]) :ignored)
               {:id :x} ["left" "right"]
               (fn [left right]
                 (swap! calls conj [left right])
                 (str left ":" right)))))
      (is (= [["new-left" "new-right"]] @calls))))
  (testing "non-vector and wrong-arity replacements fail open before execution"
    (doseq [replacement [:not-a-vector [] ["too" "many"]]]
      (let [calls (atom [])]
        (is (= :original
               (aspects/invoke-around-replace-args
                 (fn [_ _ proceed] (proceed replacement))
                 {:id :x} [:original]
                 (fn [value] (swap! calls conj value) value))))
        (is (= [:original] @calls)))))
  (testing "multiple proceed attempts still execute the target exactly once"
    (let [calls (atom [])]
      (is (= :replacement
             (aspects/invoke-around-replace-args
               (fn [_ _ proceed]
                 (proceed [:replacement])
                 (proceed [:second]))
               {:id :x} [:original]
               (fn [value] (swap! calls conj value) value))))
      (is (= [:replacement] @calls))))
  (testing "application result identity wins when advice throws after proceed"
    (let [sentinel (atom :application-result)
          calls (atom 0)
          result (aspects/invoke-around-replace-args
                   (fn [_ _ proceed]
                     (proceed [:replacement])
                     (throw (Exception. "after target")))
                   {:id :x} [:original]
                   (fn [_] (swap! calls inc) sentinel))]
      (is (identical? sentinel result))
      (is (= 1 @calls))))
  (testing "replacement execution preserves the application exception object"
    (let [boom (Exception. "app")
          seen (atom nil)]
      (try
        (aspects/invoke-around-replace-args
          (fn [_ _ proceed] (proceed [:replacement]))
          {:id :x} [:original]
          (fn [_] (throw boom)))
        (catch Exception e (reset! seen e)))
      (is (identical? boom @seen)))))

(deftest provider-role-schema
  (let [validate-provider (ns-resolve 'jolt.aspects 'validate-provider)
        base {:schema 1 :libraries {'test/lib "v1"}}]
    (testing "legacy symbol roles remain valid"
      (is (= 'provider.core/around
             (get-in (validate-provider 'provider.core/aspect-provider
                                        (assoc base :roles {:test/around 'provider.core/around}))
                     [:roles :test/around]))))
    (testing "the explicit args contract is valid"
      (is (= :args-v1
             (get-in (validate-provider
                       'provider.core/aspect-provider
                       (assoc base :roles {:test/around {:fn 'provider.core/around
                                                         :contract :args-v1}}))
                     [:roles :test/around :contract]))))
    (testing "the explicit replacement-args contract is valid"
      (is (= :replace-args-v1
             (get-in (validate-provider
                       'provider.core/aspect-provider
                       (assoc base :roles {:test/around
                                           {:fn 'provider.core/around
                                            :contract :replace-args-v1}}))
                     [:roles :test/around :contract]))))
    (doseq [[label role expected]
            [["unknown contract"
              {:fn 'provider.core/around :contract :args-v2}
              "jolt aspects: unsupported provider role contract"]
             ["unknown key"
              {:fn 'provider.core/around :contract :args-v1 :extra true}
              "jolt aspects: provider role contains unsupported keys"]]]
      (testing label
        (let [message (try
                        (validate-provider 'provider.core/aspect-provider
                                           (assoc base :roles {:test/around role}))
                        nil
                        (catch Exception e (ex-message e)))]
          (is (= expected message)))))))

(deftest build-config-cross-validation
  (let [selection {:resource "one.edn"
                   :provider 'provider.core/aspect-provider}]
    (testing "the harness resolves a compatible manifest and provider"
      (is (= [:test/call]
             (mapv :id
                   (:aspects
                     (resolve-build-config-with
                       {"one.edn" manifest-fixture}
                       provider-fixture
                       [selection]))))))
    (testing "manifest and provider library revisions must agree"
      (let [{:keys [message data]}
            (resolve-error
              {"one.edn" manifest-fixture}
              (assoc-in provider-fixture [:libraries 'test/lib] "v2")
              [selection])]
        (is (= "jolt aspects: provider is incompatible with the manifest library revision"
               message))
        (is (= {:manifest-version "v1" :provider-version "v2"}
               (select-keys data [:manifest-version :provider-version])))))
    (testing "every selected advice role must be implemented"
      (let [{:keys [message data]}
            (resolve-error {"one.edn" manifest-fixture}
                           (assoc provider-fixture :roles {})
                           [selection])]
        (is (= "jolt aspects: provider does not implement selected advice role"
               message))
        (is (= {:aspect :test/call :role :test/around}
               (select-keys data [:aspect :role])))))
    (testing "aspect ids are globally unique across selected manifests"
      (let [{:keys [message data]}
            (resolve-error
              {"one.edn" manifest-fixture "two.edn" manifest-fixture}
              provider-fixture
              [selection (assoc selection :resource "two.edn")])]
        (is (= "jolt aspects: selected aspect ids must be unique" message))
        (is (= [:test/call :test/call] (:ids data)))))))

(deftest selection-provider-schema
  (let [provider-symbols (ns-resolve 'jolt.aspects 'selection-provider-symbols)]
    (is (= ['provider.one/aspect-provider]
           (provider-symbols {:resource "a.edn" :provider 'provider.one})))
    (is (= ['provider.one/aspect-provider 'provider.two/custom]
           (provider-symbols {:resource "a.edn"
                              :providers ['provider.one 'provider.two/custom]})))
    (doseq [[selection expected]
            [[{:resource "a.edn"}
              "jolt aspects: aspect selection needs exactly one of :provider or :providers"]
             [{:resource "a.edn" :provider 'provider.one
               :providers ['provider.two]}
              "jolt aspects: aspect selection needs exactly one of :provider or :providers"]
             [{:resource "a.edn" :providers []}
              "jolt aspects: selection :providers must be a non-empty vector"]
             [{:resource "a.edn" :providers 'provider.one}
              "jolt aspects: selection :providers must be a non-empty vector"]
             [{:resource "a.edn" :providers ['provider.one 'provider.one/aspect-provider]}
              "jolt aspects: selection providers must be unique"]]]
      (is (= expected
             (try (provider-symbols selection)
                  nil
                   (catch Exception e (ex-message e))))))))

(deftest report-publication-follows-explicit-prepare
  (let [file (java.io.File/createTempFile "jolt-aspects" ".edn")
        path (.getAbsolutePath file)
        _ (.delete file)
        unit (types/new-unit)
        configured (assoc config :schema 1 :weaver "test/v1"
                                 :identity "test-identity" :report path)]
    (try
      (aspects/configure-unit! unit configured)
      (aspects/weave unit (ir/def-node "app.core" "run" (invoke-node)))
      (let [report (aspects/prepare-build-report! unit configured)]
        (is (not (.exists file)) "validation does not publish a report")
        (is (= :test/call (get-in report [:aspects 0 :id])))
        (aspects/publish-build-report! configured report)
        (is (.exists file))
        (is (= report (edn/read-string (slurp file)))))
      (finally
        (.delete file)))))

(deftest multi-consumer-report-is-one-logical-aspect
  (let [unit (types/new-unit)
        configured (assoc multi-consumer-config
                          :schema 1 :weaver "test/v1"
                          :identity "multi-consumer" :report "/tmp/unused")]
    (aspects/configure-unit! unit configured)
    (aspects/weave unit (ir/def-node "app.core" "run" (invoke-node)))
    (let [report (aspects/prepare-build-report! unit configured)
          aspect (get-in report [:aspects 0])]
      (is (= 1 (count (:aspects report))))
      (is (= [1 2 3] (mapv :ordinal (:consumers aspect))))
      (is (= ['provider.outer/aspect-provider 'provider.middle/aspect-provider
              'provider.inner/aspect-provider]
             (mapv :provider (:consumers aspect))))
      (is (= 'provider.outer/around (:advice aspect))
          "schema-v1 top-level compatibility names the outer consumer")
      (is (= [1] (mapv :ordinal (:sites aspect)))))))

(let [{:keys [fail error]} (run-tests)]
  (when (pos? (+ fail error)) (System/exit 1)))
