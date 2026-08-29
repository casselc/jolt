(ns aspect-ir-test
  (:require [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.test :refer [deftest is testing run-tests]]
            [jolt.aspects :as aspects]
            [jolt.fibers :as fibers]
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

(def control-config
  (-> config
      (assoc :control-enabled? true)
      (assoc-in [:aspects 0 :contract] :control-v1)))

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

(def filtered-complete-provider
  {:schema 1
   :libraries {'test/aspect-target "fixture-v1"}
   :roles {:test/around {:fn 'provider.complete/around
                         :contract :replace-args-v1}
           :test/entry-around {:fn 'provider.complete/entry-around
                               :contract :args-v1}
           :test/numeric-entry-around
           {:fn 'provider.complete/numeric-entry-around
            :contract :replace-args-v1}}})

(def filtered-second-provider
  {:schema 1
   :libraries {'test/aspect-target "fixture-v1"}
   :roles {:test/around 'provider.partial/around
           :test/entry-around 'provider.partial/entry-around
           :test/numeric-entry-around 'provider.partial/numeric-entry-around}})

(def filtered-incomplete-provider
  {:schema 1
   :libraries {'test/aspect-target "fixture-v1"}
   :roles {:test/around 'provider.incomplete/around}})

(def control-provider
  {:schema 1
   :libraries {'test/aspect-target "fixture-v1"}
   :roles {:test/around {:fn 'provider.control/around
                         :contract :control-v1}}})

(def aspect-fixture-resource
  "test/aspect-filter-probe.edn")

(def aspect-fixture-manifest
  {:schema 1
   :library {:id 'test/aspect-target :version "fixture-v1"}
   :aspects
   [{:id :test/target-call
     :match {:ns 'app.core :call 'app.target/operation :arity 1}
     :advice-role :test/around
     :expect {:matches 1}}
    {:id :test/callback-entry
     :match {:entry 'app.target/callback :arity 1}
     :advice-role :test/entry-around
     :expect {:matches 1}}
    {:id :test/numeric-callback-entry
     :match {:entry 'app.target/numeric-callback :arity 1}
     :advice-role :test/numeric-entry-around
     :expect {:matches 1}}]})

(defn resolve-aspect-fixture
  ([selection] (resolve-aspect-fixture selection false))
  ([selection allow-control-aspects?]
   (let [file (java.io.File/createTempFile "jolt-aspect-filter" ".edn")]
     (try
       (spit file (pr-str aspect-fixture-manifest))
       (with-redefs [io/resource
                     (fn [resource]
                       (when (= aspect-fixture-resource resource) file))]
         (aspects/resolve-build-config [selection] "/tmp/unused"
                                       allow-control-aspects?))
       (finally
         (.delete file))))))

(defn resolve-preset-fixture [preset]
  (let [manifest-file (java.io.File/createTempFile "jolt-aspect-manifest" ".edn")
        preset-file (java.io.File/createTempFile "jolt-aspect-preset" ".edn")
        preset-resource "test/aspect-standard-preset.edn"]
    (try
      (spit manifest-file (pr-str aspect-fixture-manifest))
      (spit preset-file (pr-str preset))
      (with-redefs [io/resource
                    (fn [resource]
                      (cond
                        (= aspect-fixture-resource resource) manifest-file
                        (= preset-resource resource) preset-file
                        :else nil))]
        (aspects/resolve-build-config [{:preset preset-resource}] "/tmp/unused"))
      (finally
        (.delete manifest-file)
        (.delete preset-file)))))

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
        join-point (get-in helper [:args 1 :form])
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
    (is (= "plain" (:build-identity join-point)))
    (is (string? (:site-id join-point)))
    (is (= (get-in @(:aspect-matches unit) [:test/call 0])
           (:site join-point)))
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

(deftest control-contract-weaving
  (let [unit (types/new-unit)
        _ (aspects/configure-unit! unit control-config)
        woven (aspects/weave unit (ir/def-node "app.core" "run" (invoke-node)))
        helper (get-in woven [:init :body])
        operation (nth (:args helper) 3)]
    (is (= "__invoke-instrumentation-control" (get-in helper [:fn :name])))
    (is (= :control-v1 (get-in helper [:args 1 :form :contract])))
    (is (= 2 (count (get-in operation [:arities 0 :params])))
        "control proceed can supply one exact-arity replacement vector")
    (is (empty? (ir/tree-problems woven)))))

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
        target (get-in inner-operation [:arities 0 :body])
        join-points (mapv #(get-in % [:args 1 :form]) [outer middle inner])]
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
    (is (apply = (map :site-id join-points))
        "all consumers share one logical runtime site identity")
    (is (apply = (map :site join-points)))
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
        join-point (get-in helper [:args 1 :form])
        evaluated-args (nth (:args helper) 2)
        operation (nth (:args helper) 3)
        operation-arity (get-in operation [:arities 0])
        loop-node (:body operation-arity)]
    (is (= ["x"] (:params arity)) "the public function signature is unchanged")
    (is (= "__invoke-instrumentation-around" (get-in helper [:fn :name])))
    (is (= :args-v1 (get-in helper [:args 1 :form :contract])))
    (is (= "plain" (:build-identity join-point)))
    (is (string? (:site-id join-point)))
    (is (= (get-in @(:aspect-matches unit) [:test/entry 0])
           (:site join-point)))
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
    (is (empty? (ir/tree-problems woven)))))

(deftest runtime-site-identity-is-reproducible-and-build-scoped
  (let [site-id (fn [identity]
                  (let [unit (types/new-unit)
                        configured (assoc config :identity identity)]
                    (aspects/configure-unit! unit configured)
                    (-> (aspects/weave unit
                                       (ir/def-node "app.core" "run" (invoke-node)))
                        :init :body :args second :form :site-id)))
        first-id (site-id "build-a")]
    (is (= first-id (site-id "build-a"))
        "the same selected build and report-compatible site reproduce exactly")
    (is (not= first-id (site-id "build-b"))
        "the build selection identity scopes replay selectors")))

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

(deftest invoke-control-semantics
  (testing "advice may replace the return or throw without running the target"
    (let [calls (atom 0)
          boom (Exception. "injected")
          returned (aspects/invoke-control
                     (fn [_ args _] [:replaced args])
                     {:id :x} [:original]
                     (fn [_] (swap! calls inc) :target))
          thrown (atom nil)]
      (try
        (aspects/invoke-control (fn [_ _ _] (throw boom))
                                {:id :x} [:original]
                                (fn [_] (swap! calls inc) :target))
        (catch Exception e (reset! thrown e)))
      (is (= [:replaced [:original]] returned))
      (is (identical? boom @thrown))
      (is (zero? @calls))))
  (testing "proceed runs once with original or exact-arity replacement arguments"
    (let [calls (atom [])]
      (is (= :advice-result
             (aspects/invoke-control
               (fn [_ _ proceed]
                 (is (= "new-left:new-right"
                        (proceed ["new-left" "new-right"])))
                 :advice-result)
               {:id :x} ["left" "right"]
               (fn [left right]
                 (swap! calls conj [left right])
                 (str left ":" right)))))
      (is (= [["new-left" "new-right"]] @calls))
      (is (= :original
             (aspects/invoke-control (fn [_ _ proceed] (proceed))
                                     {:id :x} [:original] identity)))))
  (testing "advice controls exceptions before and after target execution"
    (let [after (Exception. "after")
          application (Exception. "application")
          calls (atom 0)
          seen (fn [f]
                 (try (f) nil (catch Exception e e)))]
      (is (identical?
            after
            (seen #(aspects/invoke-control
                     (fn [_ _ proceed]
                       (proceed)
                       (throw after))
                     {:id :x} []
                     (fn [] (swap! calls inc) :ran)))))
      (is (= 1 @calls))
      (is (identical?
            application
            (seen #(aspects/invoke-control
                     (fn [_ _ proceed] (proceed))
                     {:id :x} []
                     (fn [] (throw application))))))
      (is (= :recovered
             (aspects/invoke-control
               (fn [_ _ proceed]
                 (try (proceed)
                      (catch Exception _ :recovered)))
               {:id :x} []
               (fn [] (throw application)))))))
  (testing "invalid, repeated, escaped, and cross-thread proceed fail closed"
    (let [calls (atom 0)
          escaped (atom nil)
          message-of (fn [f]
                       (try (f) nil (catch Exception e (ex-message e))))]
      (is (= "control advice supplied invalid replacement arguments"
             (message-of
               #(aspects/invoke-control (fn [_ _ proceed] (proceed []))
                                        {:id :x} [:one] identity))))
      (is (= "control advice invoked proceed more than once"
             (message-of
               #(aspects/invoke-control
                  (fn [_ _ proceed]
                    (proceed)
                    (proceed))
                  {:id :x} [:one]
                  (fn [_] (swap! calls inc) :ran)))))
      (is (= 1 @calls))
      (is (= :skipped
             (aspects/invoke-control
               (fn [_ _ proceed] (reset! escaped proceed) :skipped)
               {:id :x} [:one] identity)))
      (is (= "control advice invoked proceed outside its dynamic extent"
             (message-of #(@escaped))))
      (is (= "control advice invoked proceed from a non-owner execution context"
             (aspects/invoke-control
               (fn [_ _ proceed]
                 @(future (message-of proceed)))
               {:id :x} [:one] identity)))
      (let [retry-calls (atom 0)]
        (is (= "control advice invoked proceed more than once"
               (message-of
                 #(aspects/invoke-control
                    (fn [_ _ proceed]
                      (try (proceed []) (catch Exception _ nil))
                      (proceed [:one]))
                    {:id :x} [:one]
                    (fn [_] (swap! retry-calls inc) :ran)))))
        (is (zero? @retry-calls)
            "an invalid owner invocation poisons the one-shot capability"))))
  (testing "a different fiber on the same carrier is not the owner"
    (fibers/set-carrier-count! 1)
    (let [calls (atom 0)
          message-of (fn [f]
                       (try (f) nil (catch Exception e (ex-message e))))
          result
          (fibers/join
            (fibers/spawn
              (fn []
                (aspects/invoke-control
                  (fn [_ _ proceed]
                    (fibers/join
                      (fibers/spawn (fn [] (message-of proceed)))))
                  {:id :x} []
                  (fn [] (swap! calls inc) :target-ran)))))]
      (is (= "control advice invoked proceed from a non-owner execution context"
             result))
      (is (zero? @calls)))))

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
    (testing "the explicit control contract is valid"
      (is (= :control-v1
             (get-in (validate-provider
                       'provider.core/aspect-provider
                       (assoc base :roles {:test/around
                                           {:fn 'provider.core/around
                                            :contract :control-v1}}))
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

(deftest control-provider-requires-explicit-build-opt-in
  (let [selection {:resource aspect-fixture-resource
                   :consumers [{:provider 'aspect-ir-test/control-provider
                                :roles [:test/around]}]}
        message (try
                  (resolve-aspect-fixture selection)
                  nil
                  (catch Exception e (ex-message e)))
        enabled (resolve-aspect-fixture selection true)]
    (is (= (str "jolt aspects: control advice requires :jolt/build "
                ":allow-control-aspects true")
           message))
    (is (:control-enabled? enabled))
    (is (= :control-v1 (get-in enabled [:aspects 0 :consumers 0 :contract])))
    (is (= [:test/target-call] (mapv :id (:aspects enabled))))))

(deftest compiler-boundary-rechecks-control-opt-in
  (let [normalized
        {:aspects
         [{:id :test/control
           :consumers [{:ordinal 1
                        :provider 'provider.control/aspect-provider
                        :advice 'provider.control/around
                        :contract :control-v1}]}]}
        legacy {:aspects [{:id :test/control
                           :provider 'provider.control/aspect-provider
                           :advice 'provider.control/around
                           :contract :control-v1}]}
        message (fn [config]
                  (try
                    (aspects/configure-unit! (types/new-unit) config)
                    nil
                    (catch Exception e (ex-message e))))]
    (doseq [config [normalized legacy]]
      (is (= (str "jolt aspects: control advice reached compiler without "
                  "explicit enablement")
             (message config))))
    (is (nil? (message (assoc normalized :control-enabled? true))))))

(deftest control-opt-in-must-be-boolean
  (let [selection {:resource aspect-fixture-resource
                   :consumers [{:provider 'aspect-ir-test/control-provider
                                :roles [:test/around]}]}]
    (is (= "jolt aspects: :jolt/build :allow-control-aspects must be boolean"
           (try
             (resolve-aspect-fixture selection :yes)
             nil
             (catch Exception e (ex-message e)))))))

(deftest selection-provider-schema
  (let [provider-symbols (ns-resolve 'jolt.aspects 'selection-provider-symbols)
        selection-consumers (ns-resolve 'jolt.aspects 'selection-consumers)]
    (is (= ['provider.one/aspect-provider]
           (provider-symbols {:resource "a.edn" :provider 'provider.one})))
    (is (= ['provider.one/aspect-provider 'provider.two/custom]
           (provider-symbols {:resource "a.edn"
                              :providers ['provider.one 'provider.two/custom]})))
    (is (= [{:selection-ordinal 1
             :provider-var 'provider.one/aspect-provider
             :roles [:test/around :test/tool]}
            {:selection-ordinal 2
             :provider-var 'provider.two/custom
             :roles :all}]
           (selection-consumers
             {:resource "a.edn"
              :consumers [{:provider 'provider.one
                           :roles [:test/tool :test/around]}
                          {:provider 'provider.two/custom :roles :all}]})))
    (doseq [[selection expected]
            [[{:resource "a.edn"}
              (str "jolt aspects: aspect selection needs exactly one of :provider, "
                   ":providers, or :consumers")]
             [{:resource "a.edn" :provider 'provider.one
               :providers ['provider.two]}
              (str "jolt aspects: aspect selection needs exactly one of :provider, "
                   ":providers, or :consumers")]
             [{:resource "a.edn" :providers []}
              "jolt aspects: selection :providers must be a non-empty vector"]
             [{:resource "a.edn" :providers 'provider.one}
              "jolt aspects: selection :providers must be a non-empty vector"]
             [{:resource "a.edn" :providers ['provider.one 'provider.one/aspect-provider]}
              "jolt aspects: selection consumers must name unique providers"]
             [{:resource "a.edn" :consumers []}
              "jolt aspects: selection :consumers must be a non-empty vector"]
             [{:resource "a.edn" :consumers ['provider.one]}
              "jolt aspects: each selection consumer must be a map"]
             [{:resource "a.edn"
               :consumers [{:provider 'provider.one}]}
              "jolt aspects: selection consumer needs explicit :roles"]
             [{:resource "a.edn"
               :consumers [{:provider 'provider.one :roles []}]}
              (str "jolt aspects: selection consumer :roles must be :all or a "
                   "non-empty vector")]
             [{:resource "a.edn"
               :consumers [{:provider 'provider.one
                            :roles [:test/around :test/around]}]}
              "jolt aspects: selection consumer :roles must be unique"]
             [{:resource "a.edn"
               :consumers [{:provider 'provider.one :roles [:test/around]}
                           {:provider 'provider.one/aspect-provider :roles :all}]}
              "jolt aspects: selection consumers must name unique providers"]]]
      (is (= expected
             (try (provider-symbols selection)
                  nil
                  (catch Exception e (ex-message e))))))))

(deftest filtered-consumer-resolution
  (let [selection
        {:resource aspect-fixture-resource
         :consumers
         [{:provider 'aspect-ir-test/filtered-complete-provider :roles :all}
          {:provider 'aspect-ir-test/filtered-second-provider
           :roles [:test/around]}]}
        configured (resolve-aspect-fixture selection)
        by-id (into {} (map (juxt :id identity) (:aspects configured)))
        call-consumers (get-in by-id [:test/target-call :consumers])]
    (is (= 3 (count (:aspects configured))))
    (is (= ['aspect-ir-test/filtered-complete-provider
            'aspect-ir-test/filtered-second-provider]
           (mapv :provider call-consumers)))
    (is (= [1 2] (mapv :ordinal call-consumers)))
    (is (= [1 2] (mapv :selection-ordinal call-consumers)))
    (is (= [:all [:test/around]] (mapv :roles call-consumers)))
    (doseq [id [:test/callback-entry :test/numeric-callback-entry]]
      (is (= ['aspect-ir-test/filtered-complete-provider]
             (mapv :provider (get-in by-id [id :consumers]))))
      (is (= [1] (mapv :ordinal (get-in by-id [id :consumers])))))
    (testing "the weave report exposes normalized filters and both ordinals"
      (let [unit (types/new-unit)
            call-only (assoc configured :aspects [(get by-id :test/target-call)])
            target (ir/invoke (ir/var-ref "app.target" "operation")
                              [(ir/const "ok")])]
        (aspects/configure-unit! unit call-only)
        (aspects/weave unit (ir/def-node "app.core" "run" target))
        (let [report (aspects/prepare-build-report! unit call-only)
              consumers (get-in report [:aspects 0 :consumers])]
          (is (= [1 2] (mapv :ordinal consumers)))
          (is (= [1 2] (mapv :selection-ordinal consumers)))
          (is (= [:all [:test/around]] (mapv :roles consumers))))))
    (testing "selection order remains advice order at shared roles"
      (let [reversed (resolve-aspect-fixture
                       (update selection :consumers #(vec (reverse %))))
            reversed-call (first (filter #(= :test/target-call (:id %))
                                         (:aspects reversed)))]
        (is (= ['aspect-ir-test/filtered-second-provider
                'aspect-ir-test/filtered-complete-provider]
               (mapv :provider (:consumers reversed-call))))
        (is (not= (aspects/build-identity configured)
                  (aspects/build-identity reversed)))))
    (testing "role vector order is normalized in identity and reports"
      (let [with-two (assoc-in selection [:consumers 1 :roles]
                               [:test/numeric-entry-around :test/around])
            reversed-roles (assoc-in selection [:consumers 1 :roles]
                                      [:test/around :test/numeric-entry-around])
            a (resolve-aspect-fixture with-two)
            b (resolve-aspect-fixture reversed-roles)]
        (is (= (aspects/build-identity a) (aspects/build-identity b)))
        (is (= (:aspects a) (:aspects b)))))
    (testing "an explicit filter is artifact-visible even when equivalent to all"
      (let [all-roles [:test/around :test/entry-around
                       :test/numeric-entry-around]
            explicit (resolve-aspect-fixture
                       (assoc-in selection [:consumers 0 :roles] all-roles))]
        (is (= (mapv :id (:aspects configured))
               (mapv :id (:aspects explicit))))
        (is (not= (aspects/build-identity configured)
                  (aspects/build-identity explicit)))))
    (doseq [[label bad-selection expected]
            [["unknown manifest role"
              (assoc-in selection [:consumers 1 :roles] [:test/missing])
              "jolt aspects: selection consumer names roles absent from the manifest"]
             ["selected role missing from provider"
              (-> selection
                  (assoc-in [:consumers 1 :provider]
                            'aspect-ir-test/filtered-incomplete-provider)
                  (assoc-in [:consumers 1 :roles] [:test/entry-around]))
              "jolt aspects: provider does not implement selected advice role"]]]
      (testing label
        (is (= expected
               (try
                 (resolve-aspect-fixture bad-selection)
                 nil
               (catch Exception e (ex-message e)))))))))

(deftest package-owned-preset-resolution
  (let [selection {:resource aspect-fixture-resource
                   :providers ['aspect-ir-test/filtered-complete-provider
                               'aspect-ir-test/filtered-second-provider]}
        preset {:schema 1
                :id :test/standard
                :selections [selection]}
        direct (resolve-aspect-fixture selection)
        configured (resolve-preset-fixture preset)
        plan (aspects/plan-data configured)]
    (is (= [{:id :test/standard
             :resource "test/aspect-standard-preset.edn"}]
           (:presets configured)))
    (is (= (:presets configured) (:presets plan)))
    (is (= (:aspects direct) (:aspects configured))
        "a preset expands through the ordinary selection pipeline")
    (is (not= (aspects/build-identity direct)
              (aspects/build-identity configured))
        "preset provenance participates in artifact identity")
    (is (not (.contains (pr-str plan) ":preset-bytes"))
        "the printable plan omits preset source bytes")
    (is (some #(= (str "preset :test/standard from "
                       "test/aspect-standard-preset.edn") %)
              (aspects/explain-lines plan))))
  (doseq [[preset expected]
          [[{:schema 2 :id :test/bad :selections [{}]}
            "jolt aspects: unsupported preset schema"]
           [{:schema 1 :id 'test/bad :selections [{}]}
            "jolt aspects: preset :id must be a keyword"]
           [{:schema 1 :id :test/bad :selections []}
            "jolt aspects: preset :selections must be a non-empty vector"]
           [{:schema 1 :id :test/bad
             :selections [{:preset "nested.edn"}]}
            "jolt aspects: preset selection contains unsupported keys"]
           [{:schema 1 :id :test/bad :selections [{}]}
            "jolt aspects: preset selection needs :resource"]]]
    (is (= expected
           (try
             (resolve-preset-fixture preset)
             nil
             (catch Exception e (ex-message e)))))))

(deftest aspect-plan-is-source-free-and-explainable-before-or-after-build
  (let [selection {:resource aspect-fixture-resource
                   :consumers
                   [{:provider 'aspect-ir-test/filtered-complete-provider
                     :roles :all}
                    {:provider 'aspect-ir-test/filtered-second-provider
                     :roles [:test/around]}]}
        configured (resolve-aspect-fixture selection)
        plan (aspects/plan-data configured)
        call (first (filter #(= :test/target-call (:id %)) (:aspects plan)))
        site-for (fn [aspect]
                   (let [match (:match aspect)
                         call? (contains? match :call)
                         target (if call? (:call match) (:entry match))]
                     {:aspect (:id aspect)
                      :within (if call? (str (:ns match)) (namespace target))
                      (if call? :call :entry) target
                      :arity (:arity match)
                      :ordinal 1
                      :position {:line 12 :column 7}}))
        report {:schema (:schema plan)
                :weaver (:weaver plan)
                :identity (:identity plan)
                :control-enabled? (:control-enabled? plan)
                :aspects (mapv (fn [aspect]
                                 {:id (:id aspect) :sites [(site-for aspect)]})
                               (:aspects plan))}
        static-lines (aspects/explain-lines plan)
        observed-lines (aspects/explain-lines plan report "fixture.edn")]
    (is (= :instrumented (:status plan)))
    (is (= (:identity configured) (:identity plan)))
    (is (= [1 2] (mapv :ordinal (:consumers call))))
    (is (not-any? #(contains? % :provider-bytes) (:consumers call)))
    (is (not (.contains (pr-str plan) "manifest-bytes")))
    (is (not (contains? plan :report)))
    (is (some #(.startsWith % "aspect :test/target-call") static-lines))
    (is (not-any? #(.startsWith % "  observed sites:") static-lines))
    (is (some #(= "observed report: fixture.edn" %) observed-lines))
    (is (some #(= "  observed sites: 1" %) observed-lines))
    (is (some #(.contains % ":within \"app.core\"") observed-lines)))
  (is (= {:schema 1 :weaver "jolt.aspect-ir/v1" :status :plain
          :identity "plain" :control-enabled? false
          :presets [] :providers [] :aspects []}
         (aspects/plan-data nil))))

(deftest aspect-explain-rejects-stale-or-unbounded-reports
  (let [configured (resolve-aspect-fixture
                    {:resource aspect-fixture-resource
                     :provider 'aspect-ir-test/filtered-complete-provider})
        plan (aspects/plan-data configured)
        site-for (fn [aspect]
                   (let [match (:match aspect)
                         call? (contains? match :call)
                         target (if call? (:call match) (:entry match))]
                     {:aspect (:id aspect)
                      :within (if call? (str (:ns match)) (namespace target))
                      (if call? :call :entry) target
                      :arity (:arity match)
                      :ordinal 1
                      :position {:line 1 :column 1}}))
        report {:schema (:schema plan)
                :weaver (:weaver plan)
                :identity (:identity plan)
                :control-enabled? (:control-enabled? plan)
                :aspects (mapv (fn [aspect]
                                 {:id (:id aspect) :sites [(site-for aspect)]})
                               (:aspects plan))}
        message (fn [candidate]
                  (try
                    (aspects/explain-lines plan candidate)
                    nil
                    (catch Exception e (ex-message e))))]
    (is (= "jolt aspects: build report does not match the selected build"
           (message (assoc report :identity "stale"))))
    (is (= "jolt aspects: build report contains unsupported keys"
           (message (assoc report :unexpected "not rendered"))))
    (is (= "jolt aspects: build report site contains unsupported keys"
           (message (assoc-in report [:aspects 0 :sites 0 :secret] "not rendered"))))
    (is (= "jolt aspects: build report aspects do not match the selected build"
           (message (assoc-in report [:aspects 0 :id] :other/aspect))))))

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
