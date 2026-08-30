(ns region-ir-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is run-tests testing]]
            [jolt.ir :as ir]
            [jolt.passes.effects :as effects]
            [jolt.passes.regions :as regions]))

(defn unit []
  {:effect-phase-roots (atom {:plain {} :woven {} :optimized {}})
   :effect-analysis-context (atom nil)
   :effect-source-ids (atom {})
   :effect-declarations (atom {})
   :effect-reports (atom {})
   :effect-findings (atom [])
   :aspect-build-identity (atom "plain")})

(defn call [fqn args]
  (let [[ns name] (str/split fqn #"/" 2)]
    (ir/invoke (ir/var-ref ns name) args)))

(defn fixed-def [fqn body]
  (let [[ns name] (str/split fqn #"/" 2)]
    (ir/def-node ns name (ir/fn-node name [{:params [] :body body}]))))

(defn locking [body]
  (assoc (call "jolt.host/with-monitor"
               [(ir/local "lock")
                (ir/fn-node nil [{:params [] :body body}])])
         :pos {:line 4 :column 3}))

(defn record! [u phase node]
  (effects/record-phase! u phase node)
  u)

(deftest logical-monitor-records-parks-without-misclassifying-them
  (let [u (unit)
        park (assoc (call "runtime/park" []) :pos {:line 5 :column 5})
        node (fixed-def "app/run" (locking park))]
    (effects/configure-declarations!
      u {"runtime/park" {:effects #{:jolt.effect/park}}})
    (record! u :plain node)
    (let [report (regions/analyze-phase u :plain)
          observation (first (:regions report))]
      (is (= 1 (count (:regions report))))
      (is (= [:jolt.effect/park] (:effects observation)))
      (is (= :jolt.region/logical-monitor
             (get-in observation [:region-stack 0 :kind])))
      (is (empty? (:findings report)))
      (is (empty? (:limitations report))))))

(deftest nested-lexical-monitors-retain-the-ordered-region-stack
  (let [u (unit)
        park (assoc (call "runtime/park" []) :pos {:line 7 :column 9})
        inner (assoc (locking park) :pos {:line 6 :column 5})
        outer (assoc (locking inner) :pos {:line 5 :column 3})
        node (fixed-def "app/run" outer)]
    (effects/configure-declarations!
      u {"runtime/park" {:effects #{:jolt.effect/park}}})
    (record! u :plain node)
    (let [observation (first (:regions (regions/analyze-phase u :plain)))]
      (is (= 2 (count (:region-stack observation))))
      (is (= [{:line 5 :column 3} {:line 6 :column 5}]
             (mapv :site (:region-stack observation)))))))

(deftest native-carrier-blocking-under-monitor-is-a-hard-finding
  (let [u (unit)
        block (assoc (call "runtime/block" []) :pos {:line 8 :column 7})
        node (fixed-def "app/run" (locking block))]
    (effects/configure-declarations!
      u {"runtime/block" {:effects #{:jolt.effect/native-call
                                     :jolt.effect/native-block}}})
    (record! u :plain node)
    (let [finding (first (:findings (regions/analyze-phase u :plain)))]
      (is (= :jolt.rule/no-native-block-under-logical-monitor
             (:rule finding)))
      (is (= {:line 8 :column 7} (:site finding))))
    (doseq [phase [:woven :optimized]] (record! u phase node))
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"region-analysis invariant failed"
                          (regions/prepare-build-report! u)))))

(deftest unresolved-call-under-monitor-is-an-explicit-limitation
  (let [u (unit)
        node (fixed-def "app/run"
                        (locking (assoc (call "unknown/work" [])
                                        :pos {:line 12 :column 9})))]
    (record! u :plain node)
    (let [report (regions/analyze-phase u :plain)
          limitation (first (:limitations report))]
      (is (empty? (:findings report)))
      (is (= :jolt.rule/unknown-call-under-logical-monitor
             (:rule limitation)))
      (is (= [{:kind :unresolved-var :fqn "unknown/work" :argc 0}]
             (:unknown-witnesses limitation))))))

(deftest bare-monitor-halves-are-not-pretended-to-be-a-lexical-region
  (let [u (unit)
        enter (assoc (call "jolt.host/monitor-enter" [(ir/local "lock")])
                     :pos {:line 3 :column 3})
        park (assoc (call "runtime/park" []) :pos {:line 4 :column 3})
        exit (assoc (call "jolt.host/monitor-exit" [(ir/local "lock")])
                    :pos {:line 5 :column 3})
        node (fixed-def "app/run" (ir/do-node [enter park] exit))]
    (effects/configure-declarations!
      u {"runtime/park" {:effects #{:jolt.effect/park}}})
    (record! u :plain node)
    (let [report (regions/analyze-phase u :plain)]
      (is (empty? (:regions report)))
      (is (empty? (:findings report)))
      (is (= ["jolt.host/monitor-enter" "jolt.host/monitor-exit"]
             (mapv :operation (:limitations report))))
      (is (every? #(= :jolt.rule/bare-monitor-requires-control-flow-analysis
                      (:rule %))
                  (:limitations report))))))

(deftest ordinary-function-literals-remain-deferred
  (let [u (unit)
        callback (ir/fn-node nil
                             [{:params []
                               :body (locking (call "runtime/block" []))}])
        node (fixed-def "app/make-callback" callback)]
    (effects/configure-declarations!
      u {"runtime/block" {:effects #{:jolt.effect/native-block}}})
    (record! u :plain node)
    (let [report (regions/analyze-phase u :plain)]
      (is (empty? (:regions report)))
      (is (empty? (:findings report)))
      (is (empty? (:limitations report))))))

(deftest scheduled-body-owns-its-own-monitor-region
  (let [u (unit)
        block (assoc (call "runtime/block" []) :pos {:line 9 :column 9})
        callback (ir/fn-node nil [{:params ["k"] :body (locking block)}])
        spawn (assoc (call "clojure.core.async/__sm-spawn" [callback])
                     :pos {:line 7 :column 5})
        node (fixed-def "app/run" spawn)]
    (effects/configure-declarations!
      u {"runtime/block" {:effects #{:jolt.effect/native-block}}})
    (record! u :plain node)
    (let [report (regions/analyze-phase u :plain)
          finding (first (:findings report))]
      (is (= 3 (get-in report [:coverage :subjects])))
      (is (= :jolt.rule/no-native-block-under-logical-monitor
             (:rule finding)))
      (is (= :deferred-arity (get-in finding [:subject :kind])))
      (is (= {:line 9 :column 9} (:site finding))))))

(deftest outer-monitor-does-not-leak-into-scheduled-execution
  (let [u (unit)
        block (assoc (call "runtime/block" []) :pos {:line 9 :column 9})
        callback (ir/fn-node nil [{:params [] :body block}])
        spawn (assoc (call "clojure.core.async/go-spawn" [callback])
                     :pos {:line 7 :column 5})
        node (fixed-def "app/run" (locking spawn))]
    (effects/configure-declarations!
      u {"runtime/block" {:effects #{:jolt.effect/native-block}}})
    (record! u :plain node)
    (let [report (regions/analyze-phase u :plain)
          observation (first (:regions report))]
      (is (= [:jolt.effect/schedule] (:effects observation)))
      (is (empty? (:findings report)))
      (is (empty? (:limitations report))))))

(deftest clean-three-phase-report-is-deterministic
  (let [u (unit)
        node (fixed-def "app/run"
                        (locking (call "runtime/park" [])))]
    (reset! (:aspect-build-identity u) "build-1")
    (effects/configure-declarations!
      u {"runtime/park" {:effects #{:jolt.effect/park}}})
    (doseq [phase [:plain :woven :optimized]] (record! u phase node))
    (let [a (regions/prepare-build-report! u)
          b (regions/prepare-build-report! u)]
      (is (= a b))
      (is (= "jolt.regions/build-v1" (:analysis a)))
      (is (= "build-1" (:build-identity a)))
      (is (= {:lexical-region-stacks? true
              :transitive-effects? true
              :declared-execution-transfers? true
              :interprocedural-region-stacks? false
              :bare-monitor-control-flow? false}
             (:analysis-contract a)))
      (is (= [:plain :woven :optimized]
             (mapv :phase (:phases a)))))))

(let [{:keys [fail error]} (run-tests)]
  (when (pos? (+ fail error)) (System/exit 1)))
