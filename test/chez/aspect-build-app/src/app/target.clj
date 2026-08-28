(ns app.target)

(defn operation [x]
  (println (str "operation " x))
  (if (= x "throw")
    (throw (ex-info "application failure" {:kind :application}))
    (str x "!")))
