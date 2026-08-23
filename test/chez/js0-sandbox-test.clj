(ns js0-sandbox-test
  (:require [jolt.sandbox :as sandbox]))

(def failures (atom []))
(defn ok [label value] (when-not value (swap! failures conj label)))
(defn denied? [f] (try (f) false (catch :default _ true)))

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
      (ok "context healthy after interrupt" (= 3 (sandbox/evaluate! a "(+ 1 2)"))))))

(if (empty? @failures)
  (println "JS0-SANDBOX OK")
  (do (doseq [f @failures] (println "FAIL" f))
      (throw (ex-info "JS0 sandbox failures" {:failures @failures}))))
