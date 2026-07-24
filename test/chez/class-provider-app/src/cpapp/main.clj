(ns cpapp.main
  (:require [cpfixture.catalog :as catalog]))

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
  (mapv catalog/load-count [:static :ctor :buffer :standard-charsets]))

(defn run-positive! []
  (let [before (provider-counts)]
    (check :static-value (= :lazy-static fixture.LazyStatics/VALUE))
    (check :static-exact-one (= 1 (fixture.LazyStatics/loadCount)))
    (let [x (fixture.LazyCtor. 42)]
      (check :ctor-member (= 42 (.value x)))
      (check :ctor-class (= "fixture.LazyCtor" (.getName (class x))))
      (check :ctor-instance (instance? fixture.LazyCtor x)))
    ;; ByteBuffer is already built in.  Only the missing extension member should
    ;; trigger its provider, and the second call must use the registered method.
    (let [b (ByteBuffer/allocate 4)]
      (.position b 2)
      (check :known-class-extension (= [:provider 2] (.providerMarker b)))
      (check :known-class-exact-one (= [:provider 2] (.providerMarker b))))
    ;; Class.forName participates in the same bounded provider lookup, which is
    ;; important for optional-dependency feature probes.
    (check :for-name
           (= "java.nio.charset.StandardCharsets"
              (.getName (Class/forName "java.nio.charset.StandardCharsets"))))
    (check :standard-charsets (= "US-ASCII" StandardCharsets/US_ASCII))
    (check :positive-load-counts (= [1 1 1 1] (provider-counts)))
    (println "class-provider positive before=" before
             "after=" (provider-counts))))

(defn run-errors! []
  (catalog/register-error-providers!)
  ;; Identical declarations are idempotent; a different provider for either the
  ;; canonical or auto-reserved short spelling fails closed.
  (jolt.host/register-class-providers!
   {"fixture.Conflict" 'cpfixture.missing-provider})
  (jolt.host/register-class-providers!
   {"fixture.Conflict" 'cpfixture.missing-provider})
  (let [e (thrown #(jolt.host/register-class-providers!
                    {"fixture.Conflict" 'cpfixture.static-provider}))]
    (check :conflict-thrown (some? e))
    (check :conflict-type
           (= :class-provider-conflict (get-in (ex-data e) [:jolt/error :type]))))

  ;; A conflict on the auto-reserved simple spelling must not leave the FQN
  ;; partially installed.  The follow-up declaration succeeds only when the
  ;; failed declaration changed neither key.
  (jolt.host/register-class-providers!
   {"Atomic" 'cpfixture.missing-provider})
  (let [e (thrown #(jolt.host/register-class-providers!
                    {"other.Atomic" 'cpfixture.static-provider}))]
    (check :atomic-conflict-thrown (some? e))
    (check :atomic-conflict-type
           (= :class-provider-conflict (get-in (ex-data e) [:jolt/error :type]))))
  (check :atomic-conflict-no-partial-registration
         (nil? (thrown #(jolt.host/register-class-providers!
                        {"other.Atomic" 'cpfixture.missing-provider}))))

  (let [unmapped (thrown (fn [] fixture.NoProvider/VALUE))]
    (check :unmapped-thrown (some? unmapped))
    (check :unmapped-not-provider-error
           (nil? (get-in (ex-data unmapped) [:jolt/error :type]))))

  (let [first-miss (thrown (fn [] fixture.MissingAfterLoad/VALUE))
        second-miss (thrown (fn [] fixture.MissingAfterLoad/VALUE))]
    (check :missing-provider-first (some? first-miss))
    (check :missing-provider-second (some? second-miss))
    (check :missing-provider-exact-one (= 1 (catalog/load-count :missing))))

  (let [cycle (thrown (fn [] fixture.CycleA/VALUE))
        data (:jolt/error (ex-data cycle))]
    (check :cycle-thrown (some? cycle))
    (check :cycle-type (= :class-provider-cycle (:type data)))
    (check :cycle-path
           (= ["cpfixture.cycle-a" "cpfixture.cycle-b" "cpfixture.cycle-a"]
              (:path data))))
  (println "class-provider errors checked"))

(defn -main [& args]
  (run-positive!)
  (when (= "errors" (first args))
    (run-errors!))
  (if (seq @failures)
    (do
      (println "class-provider FAIL" @failures)
      (System/exit 1))
    (do
      (println "class-provider PASS")
      (System/exit 0))))
