;; JS0 ContextSpec authority conformance test.
;;
;; Exercises the data-driven authority model in jolt.sandbox: profiles,
;; attenuation, over-request rejection, absent unrequested authorization,
;; context isolation, deny corpus, dispatch recheck, canonical receipt
;; domain, coordinate invariance, and all replay divergence modes.
;;
;; Run with:
;;   JOLT_CHEZ=/usr/local/bin/scheme JOLT_QUIET=1 ./bin/jolt \
;;     -Sdeps '{:paths ["vendor/sci/src"] :deps {borkdude/edamame {:mvn/version "1.5.39"}
;;       org.babashka/sci.impl.types {:mvn/version "0.0.3"}
;;       borkdude/graal.locking {:mvn/version "0.0.2"}}}' \
;;     run test/chez/js0_authority_conformance_test.clj

(ns js0-authority-conformance-test
  (:require [jolt.sandbox :as sandbox]))

;; ─── Test harness ───────────────────────────────────────────────────────

(def failures (atom []))
(defn ok [label value] (when-not value (swap! failures conj label)))
(defn denied? [f] (try (f) false (catch Throwable _ true)))
(defn throws-with? [pred f]
  (try (f) false (catch Throwable e (pred e))))

;; ─── Fixture operations ─────────────────────────────────────────────────

(def ^:private world (atom {"a" "old"}))
(def ^:private write-count (atom 0))
(def ^:private fail-count (atom 0))

(def ^:private pure-inc-op
  {:id :math/inc :name 'inc* :effect :pure :fn inc})

(def ^:private observe-op
  {:id :world/read :name 'read :effect :observation
   :fn #(get @world %)})

(def ^:private actuate-op
  {:id :world/write :name 'write :effect :actuation
   :fn (fn [k v] (swap! write-count inc) (swap! world assoc k v) v)})

(def ^:private fail-op
  {:id :world/fail :name 'fail :effect :observation
   :fn (fn [] (swap! fail-count inc) (throw (ex-info "fixture failure" {})))})

(def ^:private all-ops [pure-inc-op observe-op actuate-op fail-op])
(def ^:private read-ops [pure-inc-op observe-op fail-op])
(def ^:private pure-ops [pure-inc-op])

;; ═════════════════════════════════════════════════════════════════════════
;; 1. Base vocabulary and :allow construction
;; ═════════════════════════════════════════════════════════════════════════

(let [ctx (sandbox/create-context pure-ops)]
  (ok "allow: pure computation works"
      (= 42 (sandbox/evaluate! ctx "(+ 1 41)")))
  (ok "allow: def works"
      (do (sandbox/evaluate! ctx "(def x 10)") true))
  (ok "allow: defn + closure works"
      (= 4 (sandbox/evaluate! ctx "(defn twice [f x] (f (f x))) (twice inc 2)")))
  (ok "allow: vector literal"
      (= [1 2 3] (sandbox/evaluate! ctx "[1 2 3]")))
  (ok "allow: map literal"
      (= {:a 1} (sandbox/evaluate! ctx "{:a 1}")))
  (ok "allow: threading macro"
      (= 6 (sandbox/evaluate! ctx "(-> 4 inc inc)")))
  (ok "allow: let binding"
      (= 3 (sandbox/evaluate! ctx "(let [x 1 y 2] (+ x y))"))))

;; ═════════════════════════════════════════════════════════════════════════
;; 2. Profiles
;; ═════════════════════════════════════════════════════════════════════════

;; :agent/minimal — only :pure effects allowed
(let [ctx (sandbox/create-context
           {:operations all-ops
            :profile :agent/minimal
            :authorized-capabilities #{:math/inc}})]
  (ok "profile minimal: pure op works"
      (= 2 (sandbox/evaluate! ctx "(project/inc* 1)")))
  (ok "profile minimal: observation denied by recheck"
      (denied? #(sandbox/evaluate! ctx "(project/read \"a\")")))
  (ok "profile minimal: actuation denied by recheck"
      (denied? #(sandbox/evaluate! ctx "(project/write \"b\" \"new\")"))))

;; :agent/project-read — :pure + :observation allowed
(let [ctx (sandbox/create-context
           {:operations all-ops
            :profile :agent/project-read
            :authorized-capabilities #{:math/inc :world/read}})]
  (ok "profile read: pure works"
      (= 2 (sandbox/evaluate! ctx "(project/inc* 1)")))
  (ok "profile read: observation works"
      (= "old" (sandbox/evaluate! ctx "(project/read \"a\")")))
  (ok "profile read: actuation denied by recheck"
      (denied? #(sandbox/evaluate! ctx "(project/write \"b\" \"new\")"))))

;; :agent/project-develop — :pure + :observation + :actuation allowed
(let [ctx (sandbox/create-context
           {:operations all-ops
            :profile :agent/project-develop
            :authorized-capabilities #{:math/inc :world/read :world/write}})]
  (ok "profile develop: pure works"
      (= 2 (sandbox/evaluate! ctx "(project/inc* 1)")))
  (ok "profile develop: observation works"
      (= "old" (sandbox/evaluate! ctx "(project/read \"a\")")))
  (ok "profile develop: actuation works"
      (do (sandbox/evaluate! ctx "(project/write \"b\" \"new\")")
          (= "new" (get @world "b")))))

;; ═════════════════════════════════════════════════════════════════════════
;; 3. Attenuation: authorized narrower than profile max
;; ═════════════════════════════════════════════════════════════════════════

;; Profile allows actuation but we only authorize pure + observation.
;; Requested defaults to authorized when only authorized is specified.
(let [ctx (sandbox/create-context
           {:operations all-ops
            :profile :agent/project-develop
            :authorized-capabilities #{:math/inc :world/read}})]
  (ok "attenuation: pure works"
      (= 2 (sandbox/evaluate! ctx "(project/inc* 1)")))
  (ok "attenuation: observation works"
      (= "old" (sandbox/evaluate! ctx "(project/read \"a\")")))
  (ok "attenuation: actuation denied (attenuated out)"
      (denied? #(sandbox/evaluate! ctx "(project/write \"b\" \"new\")"))))

;; ═════════════════════════════════════════════════════════════════════════
;; 4. Rejected over-request: authorized exceeds profile max
;; ═════════════════════════════════════════════════════════════════════════

(ok "over-request: minimal rejects observation"
    (throws-with?
      #(some-> % ex-data :jolt.sandbox/error)
      #(sandbox/create-context
         {:operations all-ops
          :profile :agent/minimal
          :authorized-capabilities #{:math/inc :world/read}})))

(ok "over-request: read rejects actuation"
    (throws-with?
      #(some-> % ex-data :jolt.sandbox/error)
      #(sandbox/create-context
         {:operations all-ops
          :profile :agent/project-read
          :authorized-capabilities #{:math/inc :world/read :world/write}})))

;; ═════════════════════════════════════════════════════════════════════════
;; 5. Absent unrequested authorization
;; ═════════════════════════════════════════════════════════════════════════

;; Profile allows observation+actuation but only pure is requested/authorized.
;; Observation and actuation operations are present in the fixture but NOT
;; callable because they are absent from the authorized set.
(let [ctx (sandbox/create-context
           {:operations all-ops
            :profile :agent/project-develop
            :requested-capabilities #{:math/inc}
            :authorized-capabilities #{:math/inc}})]
  (ok "unrequested: pure works"
      (= 2 (sandbox/evaluate! ctx "(project/inc* 1)")))
  (ok "unrequested: observation present but denied by recheck"
      (denied? #(sandbox/evaluate! ctx "(project/read \"a\")")))
  (ok "unrequested: actuation present but denied by recheck"
      (denied? #(sandbox/evaluate! ctx "(project/write \"b\" \"new\")"))))

;; ═════════════════════════════════════════════════════════════════════════
;; 6. Context isolation
;; ═════════════════════════════════════════════════════════════════════════

(do
  (reset! world {"a" "old"})
  (let [a (sandbox/create-context
            {:operations all-ops
             :profile :agent/project-develop
             :authorized-capabilities #{:math/inc :world/read :world/write}})
        b (sandbox/create-context
            {:operations pure-ops
             :profile :agent/minimal
             :authorized-capabilities #{:math/inc}})]
    (sandbox/evaluate! a "(def isolated-val 99)")
    (ok "isolation: def in a not visible in b"
        (denied? #(sandbox/evaluate! b "isolated-val")))
    (ok "isolation: operation in a not in b"
        (denied? #(sandbox/evaluate! b "(project/read \"a\")")))
    (ok "isolation: b can still compute"
        (= 2 (sandbox/evaluate! b "(project/inc* 1)")))))

;; ═════════════════════════════════════════════════════════════════════════
;; 7. Deny corpus — Jolt namespaces, eval, load, require, ffi, process,
;;    fs, env, host mutation
;; ═════════════════════════════════════════════════════════════════════════

(reset! world {"a" "old"})
(let [ctx (sandbox/create-context
           {:operations all-ops
            :profile :agent/project-develop
            :authorized-capabilities #{:math/inc :world/read :world/write :world/fail}})]
  ;; Clojure core escape hatches
  (doseq [src ["(eval '(+ 1 2))" "(clojure.core/eval '(+ 1 2))"]]
    (ok (str "deny corpus: " src) (denied? #(sandbox/evaluate! ctx src))))
  ;; Loading / requiring
  (doseq [src ["(load-string \"(+ 1 2)\")" "(clojure.core/load-string \"(+ 1 2)\")"
               "(require '[jolt.ffi])" "(clojure.core/require '[jolt.ffi])"]]
    (ok (str "deny corpus: " src) (denied? #(sandbox/evaluate! ctx src))))
  ;; Jolt-internal namespaces (not supplied to SCI)
  (doseq [src ["(jolt.host/getenv \"HOME\")" "(jolt.eval/eval \"1\")"
               "(jolt.ffi/call ...)" "(jolt.process/sh \"id\")"
               "(jolt.fs/delete \"x\")"]]
    (ok (str "deny corpus: " src) (denied? #(sandbox/evaluate! ctx src))))
  ;; Host class access
  (doseq [src ["(System/getenv \"HOME\")" "(Runtime.getRuntime)"
               "(Class/forName \"java.lang.String\")"]]
    (ok (str "deny corpus: " src) (denied? #(sandbox/evaluate! ctx src))))
  ;; Mutation primitives
  (doseq [src ["(alter-var-root #'x identity)" "(var-set)" "(intern 'user 'y 1)"
               "(set! *print-meta* true)" "(import 'java.io.File)"]]
    (ok (str "deny corpus: " src) (denied? #(sandbox/evaluate! ctx src))))
  ;; Interop
  (doseq [src ["(new java.lang.String \"x\")" "(.toString 1)"]]
    (ok (str "deny corpus: " src) (denied? #(sandbox/evaluate! ctx src)))))

;; ═════════════════════════════════════════════════════════════════════════
;; 8. Dispatch recheck: wrapper rechecks effective capability at call time
;; ═════════════════════════════════════════════════════════════════════════

(do
  (reset! world {"a" "old"})
  (let [ctx (sandbox/create-context
            {:operations all-ops
             :profile :agent/project-develop
             :authorized-capabilities #{:math/inc :world/read :world/write}})]
    ;; Both operations work initially
    (ok "recheck: write works before revocation"
        (do (sandbox/evaluate! ctx "(project/write \"b\" \"revoked\")") true))
    ;; Revoke write capability while its SCI wrapper remains projected.
    (sandbox/revoke! ctx :world/write)
    (ok "recheck: write denied after revocation"
        (denied? #(sandbox/evaluate! ctx "(project/write \"c\" \"nope\")")))
    (ok "recheck: read still works after write revocation"
        (= "old" (sandbox/evaluate! ctx "(project/read \"a\")")))
    (ok "recheck: coordinate reflects revocation"
        (not (some #{":world/write"}
                   (:jolt.sandbox/authorized (sandbox/effective-authority ctx)))))))

;; ═════════════════════════════════════════════════════════════════════════
;; 9. Canonical receipt domain
;; ═════════════════════════════════════════════════════════════════════════

(ok "receipt domain: nil" (nil? (sandbox/inert nil)))
(ok "receipt domain: bool" (true? (sandbox/inert true)))
(ok "receipt domain: string" (= "hi" (sandbox/inert "hi")))
(ok "receipt domain: exact int" (= 42 (sandbox/inert 42)))
(ok "receipt domain: bigint" (= 42N (sandbox/inert 42N)))
(ok "receipt domain: keyword" (= :foo (sandbox/inert :foo)))
(ok "receipt domain: symbol" (= 'bar (sandbox/inert 'bar)))
(ok "receipt domain: vector" (= [1 "two" nil] (sandbox/inert [1 "two" nil])))

;; Canonical map ordering: keys sorted by pr-str
(ok "receipt domain: map canonical order"
    (= {:a 1 :b 2} (sandbox/inert {:b 2 :a 1})))

;; Nested canonical ordering
(ok "receipt domain: nested map order"
    (= [{:a 1 :b 2} {:x 3}]
       (sandbox/inert [{:b 2 :a 1} {:x 3}])))

;; Rejections
(ok "receipt domain: float rejected"
    (denied? #(sandbox/inert 1.5)))
(ok "receipt domain: double rejected"
    (denied? #(sandbox/inert (double 1))))
(ok "receipt domain: ratio rejected"
    (denied? #(sandbox/inert 1/2)))
(ok "receipt domain: lazy seq rejected"
    (denied? #(sandbox/inert (map inc [1 2 3]))))
(ok "receipt domain: atom rejected (live object)"
    (denied? #(sandbox/inert (atom 1))))
(ok "receipt domain: fn rejected (live object)"
    (denied? #(sandbox/inert (fn []))))

;; ═════════════════════════════════════════════════════════════════════════
;; 10. Effective authority description and coordinate
;; ═════════════════════════════════════════════════════════════════════════

(do
  (reset! world {"a" "old"})
  (let [ctx (sandbox/create-context
            {:operations all-ops
             :profile :agent/project-read
             :authorized-capabilities #{:math/inc :world/read}})
        auth (sandbox/effective-authority ctx)]
    (ok "authority: profile in description"
        (= ":agent/project-read" (:jolt.sandbox/profile auth)))
    (ok "authority: authorized in description"
        (= #{":math/inc" ":world/read"} (set (:jolt.sandbox/authorized auth))))
    (ok "authority: operations match authorized"
        (= 2 (count (:jolt.sandbox/operations auth))))
    (ok "authority: is inert data"
        (let [leaves (atom [])
              walk (fn walk [x]
                (cond (coll? x) (doseq [c x] (walk c))
                      :else (swap! leaves conj x)))]
          (walk auth)
          (every? #(or (nil? %) (string? %) (keyword? %)
                         (boolean? %) (integer? %)
                         (vector? %) (map? %))
                @leaves)))))

;; ═════════════════════════════════════════════════════════════════════════
;; 11. Canonical coordinate — order invariance and divergence
;; ═════════════════════════════════════════════════════════════════════════

(let [coord-1 (let [c (sandbox/create-context
                      {:operations (shuffle all-ops)
                       :profile :agent/project-read
                       :authorized-capabilities #{:math/inc :world/read}})]
                (sandbox/canonical-coordinate (sandbox/effective-authority c)))
      coord-2 (let [c (sandbox/create-context
                      {:operations (reverse all-ops)
                       :profile :agent/project-read
                       :authorized-capabilities #{:math/inc :world/read}})]
                (sandbox/canonical-coordinate (sandbox/effective-authority c)))
      coord-diff (let [c (sandbox/create-context
                          {:operations all-ops
                           :profile :agent/project-develop
                           :authorized-capabilities #{:world/write}})]
                   (sandbox/canonical-coordinate (sandbox/effective-authority c)))]
   (ok "coordinate: order invariant" (= coord-1 coord-2))
   (ok "coordinate: independent of print bindings"
       (= coord-1
          (binding [*print-length* 1 *print-level* 1]
            (sandbox/canonical-coordinate
             (sandbox/effective-authority
              (sandbox/create-context
               {:operations all-ops :profile :agent/project-read
                :authorized-capabilities #{:math/inc :world/read}}))))))
   (ok "coordinate: diverges with different capabilities"
      (not= coord-1 coord-diff)))

;; ═════════════════════════════════════════════════════════════════════════
;; 12. Replay semantics — all divergence modes
;; ═════════════════════════════════════════════════════════════════════════

(do
  (reset! world {"a" "old"})
  (reset! write-count 0)
  (let [ctx (sandbox/create-context
            {:operations all-ops
             :profile :agent/project-develop
             :authorized-capabilities #{:math/inc :world/read :world/write :world/fail}})]
    ;; Record an observation and actuation
    (sandbox/set-mode! ctx :record)
    (sandbox/evaluate! ctx
      "(defn f [] (let [v (project/read \"a\")] (project/write \"a\" \"recorded\") [v \"recorded\"])) (f)")
    (let [history (sandbox/receipts ctx)
          wc @write-count]
      ;; Replay against a changed world
      (reset! world {"a" "new-world"})
      (sandbox/load-receipts! ctx history)
      (sandbox/set-mode! ctx :replay)
      (ok "replay: substitutes receipts"
          (= ["old" "recorded"]
             (sandbox/evaluate! ctx
               "(defn f [] (let [v (project/read \"a\")] (project/write \"a\" \"recorded\") [v \"recorded\"])) (f)")))
      (ok "replay: does not actuate"
          (= wc @write-count))

      ;; Divergence: changed args
      (sandbox/load-receipts! ctx history)
      (sandbox/set-mode! ctx :replay)
      (ok "replay: changed args denied"
          (denied? #(sandbox/evaluate! ctx "(project/read \"different\")")))

      ;; Divergence: exhaustion
      (sandbox/load-receipts! ctx [])
      (sandbox/set-mode! ctx :replay)
      (ok "replay: exhaustion denied"
          (denied? #(sandbox/evaluate! ctx "(project/read \"a\")")))

      ;; Divergence: unconsumed receipts
      (sandbox/load-receipts! ctx history)
      (sandbox/set-mode! ctx :replay)
      (ok "replay: unconsumed denied"
          (denied? #(sandbox/evaluate! ctx "42")))

      ;; Error receipt: recorded operation error replays without host call
      (sandbox/load-receipts! ctx [])
      (sandbox/set-mode! ctx :record)
      (ok "replay: operation error raised while recording"
          (denied? #(sandbox/evaluate! ctx "(project/fail)")))
      (let [error-history (sandbox/receipts ctx)
            fc @fail-count]
        (sandbox/load-receipts! ctx error-history)
        (sandbox/set-mode! ctx :replay)
        (ok "replay: recorded error replays"
            (denied? #(sandbox/evaluate! ctx "(project/fail)")))
        (ok "replay: recorded error does not reobserve"
            (= fc @fail-count))))))

;; ═════════════════════════════════════════════════════════════════════════
;; 13. Legacy vector API backward compatibility
;; ═════════════════════════════════════════════════════════════════════════

(do
  (reset! world {"a" "old"})
  (let [a (sandbox/create-context all-ops)
        b (sandbox/create-context [])]
    (ok "legacy: persistent def"
        (= 42 (do (sandbox/evaluate! a "(def x 41)")
                 (sandbox/evaluate! a "(+ x 1)"))))
    (ok "legacy: closure/function"
        (= 12 (sandbox/evaluate! a "(defn twice [f x] (f (f x))) (twice inc 10)")))
    (ok "legacy: projected wrapper"
        (= "old" (sandbox/evaluate! a "(project/read \"a\")")))
    (ok "legacy: other context definition absent"
        (denied? #(sandbox/evaluate! b "x")))
    (ok "legacy: other context authority absent"
        (denied? #(sandbox/evaluate! b "(project/read \"a\")")))))

;; ═════════════════════════════════════════════════════════════════════════
;; 14. Unknown profile rejection
;; ═════════════════════════════════════════════════════════════════════════

(ok "profile: unknown rejected"
    (throws-with?
      #(some-> % ex-data :jolt.sandbox/error)
      #(sandbox/create-context
         {:operations pure-ops
          :profile :agent/nonexistent})))

(ok "operation: duplicate projected name rejected"
    (throws-with?
      #(some-> % ex-data :jolt.sandbox/error)
      #(sandbox/create-context
         [{:id :one :name 'same :effect :pure :fn identity}
          {:id :two :name 'same :effect :pure :fn identity}])))

;; ═════════════════════════════════════════════════════════════════════════
;; 15. Requested exceeds authorized (requested ⊆ authorized violation)
;; ═════════════════════════════════════════════════════════════════════════

(ok "spec: requested exceeds authorized"
    (throws-with?
      #(some-> % ex-data :jolt.sandbox/error)
      #(sandbox/create-context
         {:operations all-ops
          :profile :agent/project-develop
          :requested-capabilities #{:math/inc :world/read :world/write}
          :authorized-capabilities #{:math/inc}})))

;; ═════════════════════════════════════════════════════════════════════════
;; 16. Fork preserves authority, not definitions
;; ═════════════════════════════════════════════════════════════════════════

(do
  (reset! world {"a" "old"})
  (let [a (sandbox/create-context
            {:operations all-ops
             :profile :agent/project-read
             :authorized-capabilities #{:math/inc :world/read}})]
    (sandbox/evaluate! a "(def only-in-a 42)")
    (let [b (sandbox/fork-context a)]
      (ok "fork: authority preserved"
          (= 2 (sandbox/evaluate! b "(project/inc* 1)")))
      (ok "fork: observation preserved"
          (= "old" (sandbox/evaluate! b "(project/read \"a\")")))
      (ok "fork: definition not shared"
          (denied? #(sandbox/evaluate! b "only-in-a"))))))

;; ═════════════════════════════════════════════════════════════════════════
;; Summary
;; ═════════════════════════════════════════════════════════════════════════

(defn -main []
  (if (empty? @failures)
    (println "JS0-AUTHORITY-CONFORMANCE OK")
    (do (doseq [f @failures] (println "FAIL" f))
         (throw (ex-info "JS0 authority conformance failures"
                         {:failures @failures})))))

(-main)
