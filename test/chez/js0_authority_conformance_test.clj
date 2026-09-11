;; Current-runtime ContextSpec and authority conformance gate.
(ns js0-authority-conformance-test
  (:require [jolt.sandbox :as sandbox]))

(def failures (atom []))
(defn ok [label value] (when-not value (swap! failures conj label)))
(defn denied? [f] (try (f) false (catch Throwable _ true)))
(defn causal-error-is? [kind e]
  ;; SCI adds source-location exceptions around host failures. The sandbox error
  ;; remains on the causal chain and is the contract being asserted.
  (loop [e e n 0]
    (and e (< n 8)
         (or (= kind (:jolt.sandbox/error (ex-data e)))
             (recur (ex-cause e) (inc n))))))
(defn error-is? [kind f]
  (try (f) false
       (catch Throwable e (causal-error-is? kind e))))

(def world (atom {"a" "old"}))
(def writes (atom 0))
(def host-failures (atom 0))
(def pure-op {:id :math/inc :name 'inc* :effect :pure :fn inc})
(def read-op {:id :project/read :name 'read :effect :observation
              :fn #(get @world %)})
(def list-op {:id :project/list :name 'list* :effect :observation
              :fn #(vec (sort (keys @world)))})
(def search-op {:id :project/search :name 'search :effect :observation
                :fn (fn [v]
                      (vec (filter #(= v (get @world %))
                                   (sort (keys @world)))))})
(def stat-op {:id :project/stat :name 'stat :effect :observation
              :fn (fn [k]
                    (if (= k "fail")
                      (do (swap! host-failures inc)
                          (throw (ex-info "fixture failure" {})))
                      {:exists (contains? @world k)}))})
(def edit-op {:id :project/edit :name 'edit :effect :actuation
              :fn (fn [k v]
                    (swap! writes inc)
                    (swap! world assoc k v)
                    v)})
(def network-op {:id :network/get :name 'network-get :effect :observation
                 :fn (fn [_] "network")})
(def read-caps #{:project/read :project/list :project/search :project/stat})
(def develop-caps (conj read-caps :project/edit))
(def all-ops [pure-op read-op list-op search-op stat-op edit-op network-op])

;; Closed profile maxima and attenuation.
(ok "minimal maximum is closed" (= #{} (get-in sandbox/profiles
                                                 [:agent/minimal
                                                  :profile/max-capabilities])))
(ok "read maximum is closed" (= read-caps (get-in sandbox/profiles
                                                   [:agent/project-read
                                                    :profile/max-capabilities])))
(ok "develop maximum is closed"
    (= develop-caps (get-in sandbox/profiles
                            [:agent/project-develop
                             :profile/max-capabilities])))

(let [minimal (sandbox/create-context
                {:operations all-ops :profile :agent/minimal
                 :authorized-capabilities #{}})
      read-only (sandbox/create-context
                  {:operations all-ops :profile :agent/project-read
                   :authorized-capabilities read-caps})
      attenuated (sandbox/create-context
                   {:operations all-ops :profile :agent/project-develop
                    :authorized-capabilities #{:project/read}})
      develop (sandbox/create-context
                {:operations all-ops :profile :agent/project-develop
                 :authorized-capabilities develop-caps})]
  (ok "minimal retains pure language"
      (= 2 (sandbox/evaluate! minimal "(+ 1 1)")))
  (ok "minimal denies projected pure operation"
      (denied? #(sandbox/evaluate! minimal "(project/inc* 1)")))
  (ok "minimal denies observation"
      (denied? #(sandbox/evaluate! minimal "(project/read \"a\")")))
  (ok "read permits exact observations"
      (= ["old" ["a"] ["a"] {:exists true}]
         [(sandbox/evaluate! read-only "(project/read \"a\")")
          (sandbox/evaluate! read-only "(project/list*)")
          (sandbox/evaluate! read-only "(project/search \"old\")")
          (sandbox/evaluate! read-only "(project/stat \"a\")")]))
  (ok "read denies actuation"
      (denied? #(sandbox/evaluate! read-only
                                   "(project/edit \"b\" \"x\")")))
  (ok "read denies future observation outside exact maximum"
      (denied? #(sandbox/evaluate! read-only
                                   "(project/network-get \"x\")")))
  (ok "attenuated read remains available"
      (= "old" (sandbox/evaluate! attenuated "(project/read \"a\")")))
  (ok "attenuation removes profile-permitted edit"
      (denied? #(sandbox/evaluate! attenuated
                                   "(project/edit \"b\" \"x\")")))
  (ok "develop permits actuation"
      (= "new" (sandbox/evaluate! develop
                                  "(project/edit \"b\" \"new\")"))))

(ok "minimal rejects over-profile authorization"
    (error-is? :profile-exceeded
               #(sandbox/create-context
                  {:operations all-ops :profile :agent/minimal
                   :authorized-capabilities #{:project/read}})))
(ok "read rejects actuation authorization"
    (error-is? :profile-exceeded
               #(sandbox/create-context
                  {:operations all-ops :profile :agent/project-read
                   :authorized-capabilities (conj read-caps :project/edit)})))
(ok "requested must be authorized"
    (error-is? :over-request
               #(sandbox/create-context
                  {:operations all-ops :profile :agent/project-develop
                   :requested-capabilities #{:project/read :project/edit}
                   :authorized-capabilities #{:project/read}})))
(ok "authorized capability must have an operation"
    (error-is? :missing-operation
               #(sandbox/create-context
                  {:operations [read-op] :profile :agent/project-read
                   :authorized-capabilities #{:project/read :project/stat}})))
(ok "unknown profile rejected"
    (error-is? :unknown-profile
               #(sandbox/create-context
                  {:operations [] :profile :agent/unknown
                   :authorized-capabilities #{}})))
(ok "duplicate operation id rejected"
    (error-is? :duplicate-id
               #(sandbox/create-context [pure-op (assoc pure-op :name 'other)])))
(ok "duplicate projected name rejected"
    (error-is? :duplicate-name
               #(sandbox/create-context
                  [pure-op (assoc pure-op :id :math/other)])))

;; Definitions and authority are context-local.
(let [a (sandbox/create-context
          {:operations all-ops :profile :agent/project-read
           :authorized-capabilities #{:project/read}})
      b (sandbox/create-context
          {:operations [] :profile :agent/minimal
           :authorized-capabilities #{}})]
  (sandbox/evaluate! a "(def private-to-a 9)")
  (ok "definition isolated" (denied? #(sandbox/evaluate! b "private-to-a")))
  (ok "authority isolated"
      (denied? #(sandbox/evaluate! b "(project/read \"a\")"))))

;; A projected wrapper is not authority: dispatch rechecks the live state.
(let [ctx (sandbox/create-context
            {:operations all-ops :profile :agent/project-develop
             :authorized-capabilities #{:project/read :project/edit}})]
  (ok "edit works before revocation"
      (= "before" (sandbox/evaluate! ctx
                                    "(project/edit \"r\" \"before\")")))
  (sandbox/revoke! ctx :project/edit)
  (ok "projected wrapper denied after revocation"
      (denied? #(sandbox/evaluate! ctx
                                   "(project/edit \"r\" \"after\")")))
  (ok "unrevoked operation remains available"
      (= "old" (sandbox/evaluate! ctx "(project/read \"a\")")))
  (ok "authority attestation reflects revocation"
      (not (some #{":project/edit"}
                 (:jolt.sandbox/authorized
                   (sandbox/effective-authority ctx)))))
  (let [child (sandbox/fork-context ctx)]
    (ok "fork cannot restore revoked authority"
        (denied? #(sandbox/evaluate! child
                                    "(project/edit \"r\" \"fork\")")))
    (ok "fork retains current unrevoked authority"
        (= "old" (sandbox/evaluate! child "(project/read \"a\")")))
    (ok "fork has no parent definitions"
        (do (sandbox/evaluate! ctx "(def parent-only 1)")
            (denied? #(sandbox/evaluate! child "parent-only"))))))

;; Canonical values and authority coordinates.
(doseq [[label value]
        [["nil" nil] ["boolean" true] ["string" "s"] ["integer" 42]
         ["bigint" 42N] ["keyword" :k] ["symbol" 's]
         ["vector" [1 "s" nil]] ["map" {:b 2 :a 1}]]]
  (ok (str "inert accepts " label) (= value (sandbox/inert value))))
(doseq [[label value]
        [["float" 1.5] ["ratio" 1/2] ["list" '(1 2)]
         ["lazy seq" (map inc [1 2])] ["atom" (atom 1)]
         ["function" (fn [])] ["class" java.lang.String]]]
  (ok (str "inert rejects " label) (denied? #(sandbox/inert value))))
(ok "nested inert maps are order-independent"
    (= [{:a 1 :b 2}] (sandbox/inert [{:b 2 :a 1}])))

(let [coord (fn [ops]
              (let [ctx (sandbox/create-context
                          {:operations ops :profile :agent/project-read
                           :authorized-capabilities
                           #{:project/read :project/stat}})]
                (sandbox/canonical-coordinate
                  (sandbox/effective-authority ctx))))
      c1 (coord (shuffle all-ops))
      c2 (coord (reverse all-ops))]
  (ok "authority coordinate order-invariant" (= c1 c2))
  (ok "authority coordinate print-binding independent"
      (= c1 (binding [*print-length* 1 *print-level* 1]
              (coord all-ops))))
  (ok "authority coordinate changes with authority"
      (not= c1
            (sandbox/canonical-coordinate
              (sandbox/effective-authority
                (sandbox/create-context
                  {:operations all-ops :profile :agent/project-develop
                   :authorized-capabilities #{:project/edit}}))))))

;; Replay: observation and actuation substitution, every divergence category,
;; and historical errors. Host counts prove replay performs no second effect.
(reset! world {"a" "old"})
(reset! writes 0)
(reset! host-failures 0)
(let [ctx (sandbox/create-context
            {:operations all-ops :profile :agent/project-develop
             :authorized-capabilities
             #{:project/read :project/stat :project/edit}})]
  (sandbox/set-mode! ctx :record)
  (sandbox/evaluate! ctx
    "[(project/read \"a\") (project/edit \"a\" \"recorded\")]")
  (let [history (sandbox/receipts ctx) write-count @writes]
    (reset! world {"a" "changed"})
    (sandbox/load-receipts! ctx history)
    (sandbox/set-mode! ctx :replay)
    (ok "replay substitutes observation and actuation"
        (= ["old" "recorded"]
           (sandbox/evaluate!
             ctx
             "[(project/read \"a\") (project/edit \"a\" \"recorded\")]")))
    (ok "replay performs no second actuation" (= write-count @writes))

    (sandbox/load-receipts! ctx history)
    (sandbox/set-mode! ctx :replay)
    (ok "replay operation mismatch fails closed"
        (error-is? :operation-mismatch
                   #(sandbox/evaluate! ctx "(project/stat \"a\")")))
    (sandbox/load-receipts! ctx history)
    (sandbox/set-mode! ctx :replay)
    (ok "replay argument mismatch fails closed"
        (error-is? :args-mismatch
                   #(sandbox/evaluate! ctx "(project/read \"different\")")))
    (sandbox/load-receipts! ctx [])
    (sandbox/set-mode! ctx :replay)
    (ok "replay exhaustion fails closed"
        (error-is? :exhausted
                   #(sandbox/evaluate! ctx "(project/read \"a\")")))
    (sandbox/load-receipts! ctx history)
    (sandbox/set-mode! ctx :replay)
    (ok "unconsumed replay fails closed"
        (error-is? :unconsumed #(sandbox/evaluate! ctx "42"))))

  (sandbox/load-receipts! ctx [])
  (sandbox/set-mode! ctx :record)
  (ok "host operation error recorded"
      (denied? #(sandbox/evaluate! ctx "(project/stat \"fail\")")))
  (let [history (sandbox/receipts ctx) calls @host-failures]
    (sandbox/load-receipts! ctx history)
    (sandbox/set-mode! ctx :replay)
    (ok "historical operation error replayed"
        (error-is? :recorded-operation-error
                   #(sandbox/evaluate! ctx "(project/stat \"fail\")")))
    (ok "error replay performs no second observation"
        (= calls @host-failures))))

;; Effects control transcript treatment, not authority membership.
(let [ctx (sandbox/create-context [pure-op])]
  (sandbox/set-mode! ctx :record)
  (ok "pure operation executes in record mode"
      (= 2 (sandbox/evaluate! ctx "(project/inc* 1)")))
  (ok "pure operation emits no receipt" (empty? (sandbox/receipts ctx)))
  (sandbox/set-mode! ctx :replay)
  (ok "pure operation executes in replay mode"
      (= 3 (sandbox/evaluate! ctx "(project/inc* 2)"))))

;; Representative escape surface remains absent from an authorized context.
(let [ctx (sandbox/create-context
            {:operations all-ops :profile :agent/project-develop
             :authorized-capabilities develop-caps})]
  (doseq [source ["(eval '(+ 1 2))" "(load-string \"1\")"
                  "(require '[jolt.ffi])" "(jolt.eval/eval \"1\")"
                  "(jolt.ffi/call nil)" "(jolt.process/sh \"id\")"
                  "(jolt.fs/delete \"x\")" "(System/getenv \"HOME\")"
                  "(Runtime/getRuntime)" "(Class/forName \"java.lang.String\")"
                  "(alter-var-root #'x identity)" "(intern 'user 'x 1)"
                  "(import 'java.io.File)" "(new java.lang.String \"x\")"
                  "(.toString 1)"]]
    (ok (str "deny surface: " source)
        (denied? #(sandbox/evaluate! ctx source)))))

(if (empty? @failures)
  (println "JS0-AUTHORITY-CONFORMANCE OK")
  (do (doseq [f @failures] (println "FAIL" f))
      (throw (ex-info "JS0 authority conformance failures"
                      {:failures @failures}))))
