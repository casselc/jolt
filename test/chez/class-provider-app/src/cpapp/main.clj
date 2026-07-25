(ns cpapp.main
  (:require [cpfixture.state :as state]
            [cpapp.java-buffer :as java-buffer]
            [cpapp.acme-buffer :as acme-buffer])
  (:import [fixture LazyStatics LazyCtor]
           [java.nio.charset StandardCharsets]
           [nested Deep]))

(def failures (atom []))

(defn check [label pred]
  (when-not pred
    (swap! failures conj label)))

(defn thrown [f]
  (try
    (f)
    nil
    (catch Throwable e e)))

(defn provider-counts []
  (mapv state/load-count
        [:static :ctor :buffer :standard-charsets :acme-buffer]))

(defn await-provider-state [class-name pred]
  (loop [remaining 200]
    (let [s (jolt.host/class-provider-state class-name)]
      (cond
        (pred s) s
        (zero? remaining) s
        :else (do
                (Thread/sleep 5)
                (recur (dec remaining)))))))

(defn run-positive! []
  (let [before (provider-counts)]
    (check :static-value (= :lazy-static LazyStatics/VALUE))
    (check :static-exact-one (= 1 (LazyStatics/loadCount)))
    (let [x (LazyCtor. 42)]
      (check :ctor-member (= 42 (.value x)))
      (check :ctor-class (= "fixture.LazyCtor" (.getName (class x))))
      (check :ctor-instance (instance? LazyCtor x)))

    ;; Two namespaces import different classes named ByteBuffer. Their analyzer
    ;; IR and runtime tables must remain exact and independent.
    (check :java-byte-buffer (= [:java-provider 2]
                                (java-buffer/provider-value)))
    (check :acme-byte-buffer (= [:acme :payload]
                                (acme-buffer/provider-value)))
    (check :canonical-import-forms
           (= ["java.nio.ByteBuffer."
               "java.nio.ByteBuffer/allocate"
               "java.nio.ByteBuffer"
               "java.nio.ByteBuffer"
               "java.nio.ByteBuffer"]
              (java-buffer/canonical-import-forms)))

    ;; Class.forName participates in the same bounded provider lookup, which is
    ;; important for optional-dependency feature probes.
    (check :for-name
           (= "java.nio.charset.StandardCharsets"
              (.getName (Class/forName
                          "java.nio.charset.StandardCharsets"))))
    (check :standard-charsets (= "US-ASCII" StandardCharsets/US_ASCII))
    (check :transitive-provider (= :transitive-provider Deep/VALUE))
    (check :positive-load-counts (= [1 1 1 1 1] (provider-counts)))
    (println "class-provider positive before=" before
             "after=" (provider-counts))))

(defn run-concurrency! []
  ;; A closed binary initializes its explicit provider closure before -main, so
  ;; only source mode can observe the live join. Both modes still prove that two
  ;; callers see the same value and provider initialization occurs exactly once.
  (if (zero? (state/load-count :concurrent))
    (let [first-result (future fixture.Concurrent/VALUE)
          loading (await-provider-state
                    "fixture.Concurrent"
                    #(= :loading (:state %)))
          second-result (future fixture.Concurrent/VALUE)
          joined (await-provider-state
                   "fixture.Concurrent"
                   #(pos? (:stable-waiters %)))]
      (check :concurrent-observed-loading (= :loading (:state loading)))
      (check :concurrent-observed-join (pos? (:stable-waiters joined)))
      (check :concurrent-first (= :concurrent @first-result))
      (check :concurrent-second (= :concurrent @second-result)))
    (let [first-result (future fixture.Concurrent/VALUE)
          second-result (future fixture.Concurrent/VALUE)]
      (check :concurrent-aot-first (= :concurrent @first-result))
      (check :concurrent-aot-second (= :concurrent @second-result))))
  (check :concurrent-exact-one (= 1 (state/load-count :concurrent))))

(defn run-errors! []
  (jolt.host/register-class-providers!
    {"fixture.MissingAfterLoad" 'cpfixture.missing-provider
     "fixture.ConcurrentFailure" 'cpfixture.failing-provider
     "fixture.StagedAtomicTrigger" 'cpfixture.atomic-provider
     "fixture.CycleA" 'cpfixture.cycle-a
     "fixture.CycleB" 'cpfixture.cycle-b})

  ;; Identical declarations are idempotent; a different provider for the exact
  ;; canonical class fails closed.
  (jolt.host/register-class-providers!
    {"fixture.Conflict" 'cpfixture.missing-provider})
  (jolt.host/register-class-providers!
    {"fixture.Conflict" 'cpfixture.missing-provider})
  (let [e (thrown
            #(jolt.host/register-class-providers!
               {"fixture.Conflict" 'cpfixture.static-provider}))]
    (check :conflict-thrown (some? e))
    (check :conflict-type
           (= :class-provider-conflict
              (get-in (ex-data e) [:jolt/error :type]))))

  ;; Runtime registration enforces the same exact dotted-name boundary as
  ;; deps.edn resolution. In particular it cannot create alternate spellings
  ;; for one provider-owned class.
  (doseq [class-name ["Unqualified"
                      ".fixture.Invalid"
                      "fixture.Invalid."
                      "fixture..Invalid"
                      "fixture/Invalid"]]
    (let [e (thrown
              #(jolt.host/register-class-providers!
                 {class-name 'cpfixture.missing-provider}))]
      (check [:invalid-provider-class class-name] (some? e))
      (check [:invalid-provider-class-type class-name]
             (= :invalid-class-provider
                (get-in (ex-data e) [:jolt/error :type])))))

  ;; Whole-map registration preflights every key. A conflict on one class must
  ;; not partially install another class from the same batch.
  (jolt.host/register-class-providers!
    {"fixture.Atomic" 'cpfixture.missing-provider})
  (let [e (thrown
            #(jolt.host/register-class-providers!
               {"fixture.Atomic" 'cpfixture.static-provider
                "other.Atomic" 'cpfixture.static-provider}))]
    (check :atomic-conflict-thrown (some? e))
    (check :atomic-conflict-type
           (= :class-provider-conflict
              (get-in (ex-data e) [:jolt/error :type]))))
  (check :atomic-conflict-no-partial-registration
         (nil?
           (thrown
             #(jolt.host/register-class-providers!
                {"other.Atomic" 'cpfixture.missing-provider}))))

  (check :staged-atomic-provider-conflict
         (= :class-provider-conflict fixture.StagedAtomicTrigger/VALUE))
  (check :staged-atomic-no-partial-registration
         (nil?
           (thrown
             #(jolt.host/register-class-providers!
                {"fixture.StagedPartial" 'cpfixture.static-provider}))))

  ;; Import collisions are namespace-local. Different namespaces may import the
  ;; two ByteBuffers above; one namespace may not bind both to the same alias.
  (let [e (thrown
            #(load-string
               "(ns cpapp.import-conflict (:import [com.acme ByteBuffer] [java.nio ByteBuffer]))"))]
    (check :import-conflict-thrown (some? e))
    (check :import-conflict-type
           (= :class-import-conflict
              (get-in (ex-data e) [:jolt/error :type]))))
  (check :import-conflict-no-partial-registration
         (nil?
           (thrown
             #(load-string
                "(ns cpapp.import-conflict (:import [java.nio ByteBuffer])) (def recovered ByteBuffer)"))))

  (let [unmapped (thrown (fn [] fixture.NoProvider/VALUE))]
    (check :unmapped-thrown (some? unmapped))
    (check :unmapped-not-provider-error
           (nil? (get-in (ex-data unmapped) [:jolt/error :type]))))

  (let [first-miss (thrown (fn [] fixture.MissingAfterLoad/VALUE))
        second-miss (thrown (fn [] fixture.MissingAfterLoad/VALUE))]
    (check :missing-provider-first (some? first-miss))
    (check :missing-provider-second (some? second-miss))
    (check :missing-provider-exact-one (= 1 (state/load-count :missing))))

  (let [first-result
        (future (thrown (fn [] fixture.ConcurrentFailure/VALUE)))
        loading
        (await-provider-state
          "fixture.ConcurrentFailure"
          #(= :loading (:state %)))
        second-result
        (future (thrown (fn [] fixture.ConcurrentFailure/VALUE)))
        joined
        (await-provider-state
          "fixture.ConcurrentFailure"
          #(pos? (:stable-waiters %)))
        first-error @first-result
        second-error @second-result
        leaked (thrown (fn [] fixture.PartialRegistration/VALUE))]
    (check :failed-concurrent-observed-loading
           (= :loading (:state loading)))
    (check :failed-concurrent-observed-join
           (pos? (:stable-waiters joined)))
    (check :failed-concurrent-first (some? first-error))
    (check :failed-concurrent-second (some? second-error))
    (check :failed-concurrent-same-message
           (= (ex-message first-error) (ex-message second-error)))
    (check :failed-concurrent-exact-one
           (= 1 (state/load-count :failing)))
    (check :failed-concurrent-no-partial-registration
           (some? leaked)))

  (let [cycle (thrown (fn [] fixture.CycleA/VALUE))
        data (:jolt/error (ex-data cycle))]
    (check :cycle-thrown (some? cycle))
    (check :cycle-type (= :class-provider-cycle (:type data)))
    (check :cycle-path
           (= ["cpfixture.cycle-a"
               "cpfixture.cycle-b"
               "cpfixture.cycle-a"]
              (:path data))))
  (println "class-provider errors checked"))

(defn -main [& args]
  (run-positive!)
  (run-concurrency!)
  (when (= "errors" (first args))
    (run-errors!))
  (if (seq @failures)
    (do
      (println "class-provider FAIL" @failures)
      (System/exit 1))
    (do
      (println "class-provider PASS")
      (System/exit 0))))
