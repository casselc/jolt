(ns jolt.canonical-edn
  "Deterministic EDN rendering for compiler evidence and build identities."
  (:require [clojure.string :as str]))

(defn canonical-str
  "Render maps and sets in a stable order while preserving ordinary EDN shapes."
  [x]
  (cond
    (map? x) (str "{" (str/join " "
                           (map (fn [[k v]]
                                  (str (canonical-str k) " " (canonical-str v)))
                                (sort-by (comp pr-str key) x))) "}")
    (vector? x) (str "[" (str/join " " (map canonical-str x)) "]")
    (set? x) (str "#{" (str/join " " (map canonical-str (sort-by pr-str x))) "}")
    (seq? x) (str "(" (str/join " " (map canonical-str x)) ")")
    :else (pr-str x)))
