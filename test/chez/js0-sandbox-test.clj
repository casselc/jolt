(ns js0-sandbox-test
  (:require [jolt.sandbox :as sandbox]))

(def failures (atom []))
(defn ok [label value] (when-not value (swap! failures conj label)))
(defn denied? [f] (try (f) false (catch Throwable _ true)))
(defn interrupted? [e]
  (loop [e e n 0]
    (and e (< n 8)
         (or (:jolt/interrupted (ex-data e))
             (recur (ex-cause e) (inc n))))))

;; Host seams required by SCI's ordinary source and Context initialization.
(ok "SCI compat: imap-cons Var"
    (some? (resolve 'clojure.core/imap-cons)))
(ok "SCI compat: system-newline Var"
    (= "\n" (deref (resolve 'clojure.core/system-newline))))
(ok "SCI compat: Thread.getId"
    (integer? (.getId (Thread/currentThread))))
(ok "SCI compat: Numbers unary/predicates"
    (= [2 0 2 0 true true true]
       [(clojure.lang.Numbers/inc 1)
        (clojure.lang.Numbers/dec 1)
        (clojure.lang.Numbers/unchecked_inc 1)
        (clojure.lang.Numbers/unchecked_dec 1)
        (clojure.lang.Numbers/isZero 0)
        (clojure.lang.Numbers/isPos 1)
        (clojure.lang.Numbers/isNeg -1)]))
(ok "SCI compat: Numbers binary/comparison"
    (= [3 -1 6 3 -1 6 1 true true true true true]
       [(clojure.lang.Numbers/add 1 2)
        (clojure.lang.Numbers/minus 1 2)
        (clojure.lang.Numbers/multiply 2 3)
        (clojure.lang.Numbers/unchecked_add 1 2)
        (clojure.lang.Numbers/unchecked_minus 1 2)
        (clojure.lang.Numbers/unchecked_multiply 2 3)
        (clojure.lang.Numbers/remainder 7 3)
        (clojure.lang.Numbers/lt 1 2)
        (clojure.lang.Numbers/gt 2 1)
        (clojure.lang.Numbers/lte 2 2)
        (clojure.lang.Numbers/gte 2 2)
        (clojure.lang.Numbers/equiv 2 2)]))
;; Discriminating overflow rows. Jolt has one exact-integer type (Chez
;; bignums auto-reduce), so the checked statics PROMOTE past 2^63 where the
;; JVM's Numbers ops throw ArithmeticException — the documented numeric-model
;; divergence (test/conformance/known-divergences.edn, corpus row 3754). A
;; wrapping or throwing implementation fails these rows.
(ok "SCI compat: Numbers checked overflow promotes exactly"
    (= [9223372036854775808N 9223372036854775808N
        -9223372036854775809N 18446744073709551616N -9223372036854775809N]
       [(clojure.lang.Numbers/add 9223372036854775807 1)
        (clojure.lang.Numbers/inc 9223372036854775807)
        (clojure.lang.Numbers/dec -9223372036854775808)
        (clojure.lang.Numbers/multiply 4611686018427387904 4)
        (clojure.lang.Numbers/minus -9223372036854775808 1)]))
;; The unchecked statics must WRAP at exactly 64 bits like the JVM; a
;; promoting implementation fails these rows.
(ok "SCI compat: Numbers unchecked overflow wraps at 64 bits"
    (= [-9223372036854775808 -9223372036854775808
        9223372036854775807 0 9223372036854775807]
       [(clojure.lang.Numbers/unchecked_add 9223372036854775807 1)
        (clojure.lang.Numbers/unchecked_inc 9223372036854775807)
        (clojure.lang.Numbers/unchecked_minus -9223372036854775808 1)
        (clojure.lang.Numbers/unchecked_multiply 4611686018427387904 4)
        (clojure.lang.Numbers/unchecked_dec -9223372036854775808)]))
;; equiv is category-free value equality (the JVM's == semantics): a
;; category-checking, =-like implementation fails the mixed-category rows.
(ok "SCI compat: Numbers equiv is value equality across categories"
    (= [true false true true true false]
       [(clojure.lang.Numbers/equiv 2 2)
        (clojure.lang.Numbers/equiv 1 2)
        (clojure.lang.Numbers/equiv 1 1.0)
        (clojure.lang.Numbers/equiv 1 1N)
        (clojure.lang.Numbers/equiv 5/2 2.5)
        (clojure.lang.Numbers/equiv 1 1.5)]))

(let [world (atom {"a" "old"}) writes (atom 0) failures-at-host (atom 0)
      ops [{:id :math/inc :name 'inc* :effect :pure :fn inc}
           {:id :world/read :name 'read :effect :observation
            :fn #(get @world %)}
           {:id :world/write :name 'write :effect :actuation
            :fn (fn [k v] (swap! writes inc) (swap! world assoc k v) v)}
           {:id :world/fail :name 'fail :effect :observation
            :fn (fn []
                  (swap! failures-at-host inc)
                  (throw (ex-info "fixture failure" {})))}]
      a (sandbox/create-context ops)
      b (sandbox/create-context [])]
  (sandbox/evaluate! a "(def x 41)")
  (ok "persistent def" (= 42 (sandbox/evaluate! a "(+ x 1)")))
  (sandbox/evaluate! a "(defn twice [f x] (f (f x)))")
  (ok "closure/function" (= 12 (sandbox/evaluate! a "(twice inc 10)")))
  (ok "collections/lazy"
      (= [2 3 4] (sandbox/evaluate! a "(vec (map inc [1 2 3]))")))
  (ok "composition" (= 6 (sandbox/evaluate! a "(-> 4 inc inc)")))

  (ok "projected wrapper"
      (= "old" (sandbox/evaluate! a "(project/read \"a\")")))
  (ok "trusted facade absent"
      (denied? #(sandbox/evaluate! a "(jolt.sandbox/inert \"a\")")))
  (ok "trusted sibling absent"
      (denied? #(sandbox/evaluate! a "(jolt.host/getenv \"HOME\")")))
  (ok "other context definition absent"
      (denied? #(sandbox/evaluate! b "x")))
  (ok "other context authority absent"
      (denied? #(sandbox/evaluate! b "(project/read \"a\")")))

  (sandbox/set-mode! a :record)
  (sandbox/evaluate!
    a
    "(defn f [] (let [v (project/read \"a\")] (project/write \"a\" \"recorded\") [v \"recorded\"])) (f)")
  (let [history (sandbox/receipts a) write-count @writes]
    (reset! world {"a" "new-world"})
    (sandbox/load-receipts! a history)
    (sandbox/set-mode! a :replay)
    (ok "replay substitutes receipts"
        (= ["old" "recorded"]
           (sandbox/evaluate!
             a
             "(defn f [] (let [v (project/read \"a\")] (project/write \"a\" \"recorded\") [v \"recorded\"])) (f)")))
    (ok "replay does not actuate" (= write-count @writes))
    (sandbox/load-receipts! a history)
    (sandbox/set-mode! a :replay)
    (ok "replay changed args denied"
        (denied? #(sandbox/evaluate! a "(project/read \"different\")")))
    (sandbox/load-receipts! a [])
    (sandbox/set-mode! a :replay)
    (ok "replay exhaustion denied"
        (denied? #(sandbox/evaluate! a "(project/read \"a\")")))
    (sandbox/load-receipts! a history)
    (sandbox/set-mode! a :replay)
    (ok "replay unconsumed denied"
        (denied? #(sandbox/evaluate! a "42"))))

  (sandbox/load-receipts! a [])
  (sandbox/set-mode! a :record)
  (ok "operation error is raised while recording"
      (denied? #(sandbox/evaluate! a "(project/fail)")))
  (let [error-history (sandbox/receipts a) calls @failures-at-host]
    (sandbox/load-receipts! a error-history)
    (sandbox/set-mode! a :replay)
    (ok "recorded operation error replays"
        (denied? #(sandbox/evaluate! a "(project/fail)")))
    (ok "recorded error does not reobserve" (= calls @failures-at-host)))

  (sandbox/set-mode! a :normal)
  (doseq [source ["(eval '(+ 1 2))" "(clojure.core/eval '(+ 1 2))"
                  "(load-string \"(+ 1 2)\")"
                  "(clojure.core/load-string \"(+ 1 2)\")"
                  "(require '[jolt.ffi])" "(clojure.core/require '[jolt.ffi])"
                  "(jolt.process/sh \"id\")" "(jolt.fs/delete \"x\")"
                  "(System/getenv \"HOME\")"]]
    (ok (str "authority denied " source)
        (denied? #(sandbox/evaluate! a source))))

  (let [token (jolt.host/make-interrupt)
        f (future
            (try (sandbox/evaluate! a "(loop [] (recur))" token)
                 (catch Throwable e e)))]
    (Thread/sleep 20)
    (jolt.host/interrupt! token)
    (let [r (deref f 2000 ::timeout)]
      (ok "runaway evaluation stops" (not= ::timeout r))
      (ok "runaway evaluation reports interruption" (interrupted? r))
      (ok "context healthy after interrupt"
          (= 3 (sandbox/evaluate! a "(+ 1 2)"))))))

(let [surface (sandbox/language-surface)
      symbols (:jolt.sandbox.surface/symbols surface)
      coord (sandbox/language-coordinate)]
  (ok "surface: language id"
      (= "js0-pure-sci" (:jolt.sandbox.surface/lang surface)))
  (ok "surface: version"
      (= sandbox/language-surface-version
         (:jolt.sandbox.surface/version surface)))
  (ok "surface: count/sort/distinct"
      (and (= (count symbols) (:jolt.sandbox.surface/count surface))
           (= symbols (vec (sort symbols)))
           (= (count symbols) (count (distinct symbols)))
           (every? string? symbols)))
  (doseq [s ["+" "def" "fn" "let" "loop" "quote" "recur" "->"
             "some->>" "map" "reduce" "assoc-in" "format" "println"
             "zipmap"]]
    (ok (str "surface includes " s) (some? (some #{s} symbols))))
  (doseq [s ["doc" "apropos" "letfn" "eval" "load-string" "require"
             "resolve" "ns" "in-ns" "import"]]
    (ok (str "surface excludes " s) (nil? (some #{s} symbols))))
  (ok "surface has no host/project handle"
      (not (some #(and (re-find #"/" %) (not= "/" %)) symbols)))
  (ok "surface is inert" (= surface (sandbox/inert surface)))
  (ok "surface is context independent"
      (= surface (do (sandbox/create-context []) (sandbox/language-surface))))
  (ok "language coordinate deterministic"
      (= coord (sandbox/language-coordinate)))
  (ok "language coordinate print-binding independent"
      (= coord (binding [*print-length* 1 *print-level* 1]
                 (sandbox/language-coordinate))))
  (ok "language coordinate pinned to current reviewed surface"
      (= coord
         "js0-lang/v1:[:map [[:jolt.sandbox.surface/count 156] [:jolt.sandbox.surface/lang \"js0-pure-sci\"] [:jolt.sandbox.surface/symbols [:vector [\"*\" \"+\" \"-\" \"->\" \"->>\" \"/\" \"<\" \"<=\" \"=\" \">\" \">=\" \"abs\" \"and\" \"apply\" \"as->\" \"assoc\" \"assoc-in\" \"boolean?\" \"char?\" \"coll?\" \"comp\" \"compare\" \"complement\" \"concat\" \"cond\" \"cond->\" \"cond->>\" \"condp\" \"conj\" \"cons\" \"constantly\" \"contains?\" \"count\" \"dec\" \"def\" \"defn\" \"defn-\" \"dissoc\" \"distinct\" \"do\" \"drop\" \"drop-last\" \"drop-while\" \"empty?\" \"even?\" \"every?\" \"filter\" \"filterv\" \"find\" \"first\" \"flatten\" \"fn\" \"fn*\" \"fn?\" \"format\" \"frequencies\" \"get\" \"get-in\" \"group-by\" \"hash-map\" \"hash-set\" \"identity\" \"if\" \"if-let\" \"if-not\" \"if-some\" \"inc\" \"integer?\" \"interleave\" \"interpose\" \"into\" \"juxt\" \"key\" \"keys\" \"keyword\" \"keyword?\" \"last\" \"let\" \"let*\" \"list\" \"list*\" \"loop\" \"loop*\" \"map\" \"map?\" \"mapcat\" \"mapv\" \"max\" \"merge\" \"merge-with\" \"min\" \"mod\" \"name\" \"namespace\" \"neg?\" \"nil?\" \"not\" \"not=\" \"nth\" \"number?\" \"odd?\" \"or\" \"partial\" \"partition\" \"partition-all\" \"peek\" \"pop\" \"pos?\" \"pr-str\" \"println\" \"quot\" \"quote\" \"range\" \"recur\" \"reduce\" \"reduce-kv\" \"rem\" \"remove\" \"rest\" \"reverse\" \"second\" \"select-keys\" \"seq\" \"seq?\" \"sequential?\" \"set\" \"set?\" \"some\" \"some->\" \"some->>\" \"some?\" \"sort\" \"sort-by\" \"split-at\" \"str\" \"string?\" \"subs\" \"symbol\" \"symbol?\" \"take\" \"take-last\" \"take-while\" \"update\" \"update-in\" \"val\" \"vals\" \"vec\" \"vector\" \"vector?\" \"when\" \"when-first\" \"when-let\" \"when-not\" \"when-some\" \"zero?\" \"zipmap\"]]] [:jolt.sandbox.surface/version 1]]]"))
  (let [auth-coord (sandbox/canonical-coordinate
                     (sandbox/effective-authority
                       (sandbox/create-context [])))]
    (ok "authority and language coordinate schemes are disjoint"
        (and (= "js0:" (subs auth-coord 0 4))
             (not= "js0:" (subs coord 0 4))
             (not= auth-coord coord)))))

(if (empty? @failures)
  (println "JS0-SANDBOX OK")
  (do (doseq [f @failures] (println "FAIL" f))
      (throw (ex-info "JS0 sandbox failures" {:failures @failures}))))
