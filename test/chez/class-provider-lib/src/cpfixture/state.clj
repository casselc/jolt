(ns cpfixture.state)

(def loads (atom {}))

(defn note-load! [provider]
  (swap! loads update provider (fnil inc 0)))

(defn load-count [provider]
  (get @loads provider 0))
