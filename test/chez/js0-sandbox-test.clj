(ns js0-sandbox-test
  (:require [jolt.sandbox :as sandbox]))

(def failures (atom []))
(defn ok [label value] (when-not value (swap! failures conj label)))
(defn denied? [f] (try (f) false (catch :default _ true)))
(defn interrupted? [e]
  ;; SCI decorates host errors with location data, so retain the causal walk
  ;; rather than mistaking any prompt evaluation failure for cancellation.
  (loop [e e n 0]
    (and e (< n 8)
         (or (:jolt/interrupted (ex-data e))
             (recur (ex-cause e) (inc n))))))

(let [world (atom {"a" "old"}) writes (atom 0) failures-at-host (atom 0)
      ops [{:id :math/inc :name 'inc* :effect :pure :fn inc}
           {:id :world/read :name 'read :effect :observation :fn #(get @world %)}
           {:id :world/write :name 'write :effect :actuation
            :fn (fn [k v] (swap! writes inc) (swap! world assoc k v) v)}
           {:id :world/fail :name 'fail :effect :observation
            :fn (fn [] (swap! failures-at-host inc) (throw (ex-info "fixture failure" {})))}]
      a (sandbox/create-context ops) b (sandbox/create-context [])]
  ;; Functional persistent SCI computation.
  (sandbox/evaluate! a "(def x 41)")
  (ok "persistent def" (= 42 (sandbox/evaluate! a "(+ x 1)")))
  (sandbox/evaluate! a "(defn twice [f x] (f (f x)))")
  (ok "closure/function" (= 12 (sandbox/evaluate! a "(twice inc 10)")))
  (ok "collections/lazy" (= [2 3 4] (sandbox/evaluate! a "(vec (map inc [1 2 3]))")))
  (ok "composition" (= 6 (sandbox/evaluate! a "(-> 4 inc inc)")))
  ;; Projection is narrow and contexts isolate both definitions and authority.
  (ok "projected wrapper" (= "old" (sandbox/evaluate! a "(project/read \"a\")")))
  (ok "unprojected host absent" (denied? #(sandbox/evaluate! a "(jolt.sandbox/inert \"a\")")))
  (ok "trusted sibling absent" (denied? #(sandbox/evaluate! a "(jolt.host/getenv \"HOME\")")))
  (ok "other context definition absent" (denied? #(sandbox/evaluate! b "x")))
  (ok "other context authority absent" (denied? #(sandbox/evaluate! b "(project/read \"a\")")))
  ;; Record then replay an observation and actuation while changing the world.
  (sandbox/set-mode! a :record)
  (sandbox/evaluate! a "(defn f [] (let [v (project/read \"a\")] (project/write \"a\" \"recorded\") [v \"recorded\"])) (f)")
  (let [history (sandbox/receipts a) write-count @writes]
    (reset! world {"a" "new-world"})
    (sandbox/load-receipts! a history) (sandbox/set-mode! a :replay)
    (ok "replay substitutes receipts"
        (= ["old" "recorded"]
           (sandbox/evaluate! a "(defn f [] (let [v (project/read \"a\")] (project/write \"a\" \"recorded\") [v \"recorded\"])) (f)")))
    (ok "replay does not actuate" (= write-count @writes))
    ;; Divergence is fail-closed.
    (sandbox/load-receipts! a history) (sandbox/set-mode! a :replay)
    (ok "replay changed args denied" (denied? #(sandbox/evaluate! a "(project/read \"different\")")))
    (sandbox/load-receipts! a []) (sandbox/set-mode! a :replay)
    (ok "replay exhaustion denied" (denied? #(sandbox/evaluate! a "(project/read \"a\")")))
    (sandbox/load-receipts! a history) (sandbox/set-mode! a :replay)
    (ok "replay unconsumed denied" (denied? #(sandbox/evaluate! a "42"))))
  ;; Historical errors are receipts too and replay without another host call.
  (sandbox/load-receipts! a []) (sandbox/set-mode! a :record)
  (ok "operation error is raised while recording" (denied? #(sandbox/evaluate! a "(project/fail)")))
  (let [error-history (sandbox/receipts a) calls @failures-at-host]
    (sandbox/load-receipts! a error-history) (sandbox/set-mode! a :replay)
    (ok "recorded operation error replays" (denied? #(sandbox/evaluate! a "(project/fail)")))
    (ok "recorded error does not reobserve" (= calls @failures-at-host)))
  ;; SCI core cannot reach Jolt's live image or dynamic loader.
  (sandbox/set-mode! a :normal)
  (doseq [source ["(eval '(+ 1 2))" "(clojure.core/eval '(+ 1 2))"
                  "(load-string \"(+ 1 2)\")" "(clojure.core/load-string \"(+ 1 2)\")"
                  "(require '[jolt.ffi])" "(clojure.core/require '[jolt.ffi])" "(jolt.process/sh \"id\")"
                  "(jolt.fs/delete \"x\")" "(System/getenv \"HOME\")"]]
    (ok (str "authority denied " source) (denied? #(sandbox/evaluate! a source))))
  ;; Real stop, not timeout: run eval in a worker, interrupt it, then reuse ctx.
  (let [token (jolt.host/make-interrupt)
        f (future (try (sandbox/evaluate! a "(loop [] (recur))" token)
                       (catch :default e e)))]
    (Thread/sleep 20) (jolt.host/interrupt! token)
    (let [r (deref f 2000 ::timeout)]
      (ok "runaway evaluation stops" (not= ::timeout r))
      (ok "runaway evaluation reports interruption" (interrupted? r))
      (ok "context healthy after interrupt" (= 3 (sandbox/evaluate! a "(+ 1 2)"))))))

;; ═══════════════════════════════════════════════════════════════════════════
;; Reviewed language surface: trusted inert description + versioned coordinate
;; ═══════════════════════════════════════════════════════════════════════════

(let [surface (sandbox/language-surface)
      symbols (:jolt.sandbox.surface/symbols surface)]
  ;; Shape and schema.
  (ok "surface: lang id"
      (= "js0-pure-sci" (:jolt.sandbox.surface/lang surface)))
  (ok "surface: version is the public version var"
      (= sandbox/language-surface-version
         (:jolt.sandbox.surface/version surface)))
  (ok "surface: count matches symbols"
      (= (:jolt.sandbox.surface/count surface) (count symbols)))
  (ok "surface: symbols are all plain strings" (every? string? symbols))
  (ok "surface: symbols sorted and distinct"
      (and (= symbols (vec (sort symbols)))
           (= (count symbols) (count (distinct symbols)))))
  ;; Membership spot checks across the reviewed categories.
  (doseq [s ["+" "def" "fn" "let" "loop" "quote" "recur" "->" "some->>"
             "map" "reduce" "assoc-in" "format" "println" "zipmap"]]
    (ok (str "surface: includes " s) (boolean (some #{s} symbols))))
  ;; Reviewed exclusions and dynamic-loader surface stay out of the
  ;; description.
  (doseq [s ["doc" "apropos" "letfn" "eval" "load-string" "require" "resolve"
             "ns" "in-ns" "import"]]
    (ok (str "surface: excludes " s) (not (some #{s} symbols))))
  ;; No host namespaces or projected operation handles leak into the pure
  ;; language description: the reviewed vocabulary is entirely unqualified
  ;; (the bare division symbol "/" is the single reviewed exception).
  (ok "surface: no namespaced symbol (no host/operation handle)"
      (not (some #(and (re-find #"/" %) (not= "/" %)) symbols)))
  ;; Inert by construction: the receipt-domain canonicalizer accepts the
  ;; description and is idempotent on it — no vars, functions, namespaces,
  ;; or other live handles.
  (ok "surface: inert round-trip" (= surface (sandbox/inert surface)))
  ;; The description is context-independent: it needs no live SCI Context and
  ;; is identical alongside one.
  (ok "surface: independent of any live context"
      (= surface (do (sandbox/create-context []) (sandbox/language-surface))))
  ;; Deterministic versioned coordinate.
  (let [coord (sandbox/language-coordinate)
        prefix (str "js0-lang/v" sandbox/language-surface-version ":")]
    (ok "coordinate: deterministic" (= coord (sandbox/language-coordinate)))
    (ok "coordinate: versioned scheme prefix"
        (= prefix (subs coord 0 (count prefix))))
    (ok "coordinate: independent of print bindings"
        (= coord (binding [*print-length* 1 *print-level* 1]
                   (sandbox/language-coordinate))))
    ;; Drift gate: any change to the reviewed vocabulary, the description
    ;; schema, or the version changes this exact string and fails here,
    ;; forcing explicit review of the frozen language surface.
    (ok "coordinate: pinned canonical form"
        (= coord "js0-lang/v1:[:map [[:jolt.sandbox.surface/count 156] [:jolt.sandbox.surface/lang \"js0-pure-sci\"] [:jolt.sandbox.surface/symbols [:vector [\"*\" \"+\" \"-\" \"->\" \"->>\" \"/\" \"<\" \"<=\" \"=\" \">\" \">=\" \"abs\" \"and\" \"apply\" \"as->\" \"assoc\" \"assoc-in\" \"boolean?\" \"char?\" \"coll?\" \"comp\" \"compare\" \"complement\" \"concat\" \"cond\" \"cond->\" \"cond->>\" \"condp\" \"conj\" \"cons\" \"constantly\" \"contains?\" \"count\" \"dec\" \"def\" \"defn\" \"defn-\" \"dissoc\" \"distinct\" \"do\" \"drop\" \"drop-last\" \"drop-while\" \"empty?\" \"even?\" \"every?\" \"filter\" \"filterv\" \"find\" \"first\" \"flatten\" \"fn\" \"fn*\" \"fn?\" \"format\" \"frequencies\" \"get\" \"get-in\" \"group-by\" \"hash-map\" \"hash-set\" \"identity\" \"if\" \"if-let\" \"if-not\" \"if-some\" \"inc\" \"integer?\" \"interleave\" \"interpose\" \"into\" \"juxt\" \"key\" \"keys\" \"keyword\" \"keyword?\" \"last\" \"let\" \"let*\" \"list\" \"list*\" \"loop\" \"loop*\" \"map\" \"map?\" \"mapcat\" \"mapv\" \"max\" \"merge\" \"merge-with\" \"min\" \"mod\" \"name\" \"namespace\" \"neg?\" \"nil?\" \"not\" \"not=\" \"nth\" \"number?\" \"odd?\" \"or\" \"partial\" \"partition\" \"partition-all\" \"peek\" \"pop\" \"pos?\" \"pr-str\" \"println\" \"quot\" \"quote\" \"range\" \"recur\" \"reduce\" \"reduce-kv\" \"rem\" \"remove\" \"rest\" \"reverse\" \"second\" \"select-keys\" \"seq\" \"seq?\" \"sequential?\" \"set\" \"set?\" \"some\" \"some->\" \"some->>\" \"some?\" \"sort\" \"sort-by\" \"split-at\" \"str\" \"string?\" \"subs\" \"symbol\" \"symbol?\" \"take\" \"take-last\" \"take-while\" \"update\" \"update-in\" \"val\" \"vals\" \"vec\" \"vector\" \"vector?\" \"when\" \"when-first\" \"when-let\" \"when-not\" \"when-some\" \"zero?\" \"zipmap\"]]] [:jolt.sandbox.surface/version 1]]]")))
  ;; The language coordinate scheme is disjoint from the per-context authority
  ;; coordinate scheme (js0:).
  (let [auth-coord (sandbox/canonical-coordinate
                     (sandbox/effective-authority (sandbox/create-context [])))]
    (ok "coordinate: authority scheme is js0:" (= "js0:" (subs auth-coord 0 4)))
    (ok "coordinate: language scheme disjoint from authority scheme"
        (and (not= "js0:" (subs (sandbox/language-coordinate) 0 4))
             (not= auth-coord (sandbox/language-coordinate))))))

(if (empty? @failures)
  (println "JS0-SANDBOX OK")
  (do (doseq [f @failures] (println "FAIL" f))
      (throw (ex-info "JS0 sandbox failures" {:failures @failures}))))
