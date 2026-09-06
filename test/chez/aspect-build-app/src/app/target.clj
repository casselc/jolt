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

(defn ^{:jolt.aspects/id :test/byte-callback-entry
        :jolt.aspects/role :test/bytes-entry-around}
  byte-callback [^bytes bs]
  (println (str "byte-callback " (pr-str (vec bs))))
  ;; 255 narrows to signed byte -1. An empty array deliberately exercises the
  ;; same ArrayIndexOutOfBoundsException through both plain and woven builds.
  (aset-byte bs 1 255)
  bs)
