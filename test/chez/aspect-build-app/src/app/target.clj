(ns app.target)

(defn operation [x]
  (println (str "operation " x))
  (if (= x "throw")
    (throw (ex-info "application failure" {:kind :application}))
    (str x "!")))

(defn ^{:jolt.aspects/id :test/callback-entry
        :jolt.aspects/role :test/entry-around}
  callback [x]
  (println (str "callback " x))
  (cond
    (= x "recur") (recur "done")
    (= x "throw") (throw (ex-info "callback failure" {:kind :callback}))
    :else (str x "?")))

(defn invoke-callback [f x]
  ;; No resolved app.target/callback invocation exists for a call selector.
  (f x))

(defn ^{:jolt.aspects/id :test/numeric-callback-entry
        :jolt.aspects/role :test/numeric-entry-around}
  numeric-callback [^long x]
  (println (str "numeric-callback " x))
  (inc x))
