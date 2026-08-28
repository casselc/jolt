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
