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

(let [{:keys [fail error]} (run-tests)]
  (when (pos? (+ fail error)) (System/exit 1)))
