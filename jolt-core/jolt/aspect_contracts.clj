(ns jolt.aspect-contracts
  "One compiler ABI for generated aspect helper calls.

  The weaver and every IR consumer derive helper shape from this table. This
  prevents a new advice contract from silently becoming opaque or incorrectly
  summarized in a later nanopass.")

(def contracts
  {:proceed-v1
   {:helper-name "__invoke-instrumentation-around"
    :helper-argc 3
    :advice-index 0
    :join-point-index 1
    :operation-index 2
    :advice-argc 2
    :evaluated-args? false
    :replacement-args? false
    :control? false}

   :args-v1
   {:helper-name "__invoke-instrumentation-around"
    :helper-argc 4
    :advice-index 0
    :join-point-index 1
    :evaluated-args-index 2
    :operation-index 3
    :advice-argc 3
    :evaluated-args? true
    :replacement-args? false
    :control? false}

   :replace-args-v1
   {:helper-name "__invoke-instrumentation-around-replace-args"
    :helper-argc 4
    :advice-index 0
    :join-point-index 1
    :evaluated-args-index 2
    :operation-index 3
    :advice-argc 3
    :evaluated-args? true
    :replacement-args? true
    :control? false}

   :control-v1
   {:helper-name "__invoke-instrumentation-control"
    :helper-argc 4
    :advice-index 0
    :join-point-index 1
    :evaluated-args-index 2
    :operation-index 3
    :advice-argc 3
    :evaluated-args? true
    :replacement-args? true
    :control? true}})

(def contracted-provider-contracts
  "Contracts accepted in an explicit provider role map. :proceed-v1 remains
  the shorthand selected by a bare qualified advice symbol."
  #{:args-v1 :replace-args-v1 :control-v1})

(defn contract-spec [contract]
  (when-let [spec (get contracts contract)]
    (assoc spec
           :contract contract
           :helper-fqn (str "clojure.core/" (:helper-name spec)))))

(def helper-call-specs
  (into {}
        (map (fn [[contract spec]]
               [[(str "clojure.core/" (:helper-name spec))
                 (:helper-argc spec)]
                (assoc spec
                       :contract contract
                       :helper-fqn
                       (str "clojure.core/" (:helper-name spec)))])
             contracts)))

(def helper-fqns
  (set (map first (keys helper-call-specs))))

(defn helper-call-spec [helper-fqn argc]
  (get helper-call-specs [helper-fqn argc]))

(defn helper-fqn? [fqn]
  (contains? helper-fqns fqn))
