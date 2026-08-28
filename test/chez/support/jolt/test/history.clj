(ns jolt.test.history)

;; A deliberately small, test-only semantic-history surface.  An application
;; or aspect records operation invocation/return events; the checker searches
;; the bounded partial order for a sequential-model witness.  It knows nothing
;; about threads, fibers, OTEL, or a particular resource.

(def ^:private max-operations 10)

(defn journal
  "Return a fresh append-only semantic event journal."
  []
  (atom []))

(defn record!
  "Append event to journal and return the published event.  :seq is assigned
  atomically and is therefore a strictly contiguous observation order."
  [journal event]
  (peek
   (swap! journal
          (fn [events]
            (conj events (assoc event :seq (count events)))))))

(defn- malformed! [message data]
  (throw (ex-info message (assoc data :type :jolt.test.history/malformed))))

(defn- validate-event! [event]
  (when-not (contains? event :id)
    (malformed! "event needs an operation id" {:event event}))
  (when-not (#{:invoke :return} (:phase event))
    (malformed! "event phase must be :invoke or :return" {:event event}))
  (when-not (and (integer? (:seq event)) (not (neg? (:seq event))))
    (malformed! "event needs a non-negative integer sequence" {:event event}))
  (when (and (= :invoke (:phase event)) (not (contains? event :op)))
    (malformed! "invocation needs an operation" {:event event}))
  (when (and (= :return (:phase event)) (not (contains? event :output)))
    (malformed! "return needs an output" {:event event})))

(defn operations
  "Pair :invoke and :return events by :id.

  An invocation supplies :op and may supply :input.  A return supplies
  :output.  Every operation must have exactly one invocation followed by
  exactly one return.  The result is ordered by invocation sequence."
  [events]
  (doseq [event events]
    (validate-event! event))
  (let [by-id (group-by :id events)]
    (->> by-id
         (map
          (fn [[id es]]
            (let [invokes (filter #(= :invoke (:phase %)) es)
                  returns (filter #(= :return (:phase %)) es)]
              (when-not (= 1 (count invokes))
                (malformed! "operation needs exactly one invocation"
                            {:id id :events es}))
              (when-not (= 1 (count returns))
                (malformed! "operation needs exactly one return"
                            {:id id :events es}))
              (let [invoke (first invokes)
                    return (first returns)]
                (when-not (< (:seq invoke) (:seq return))
                  (malformed! "operation returned before it was invoked"
                              {:id id :invoke invoke :return return}))
                {:id id
                 :op (:op invoke)
                 :input (:input invoke)
                 :output (:output return)
                 :invoke-seq (:seq invoke)
                 :return-seq (:seq return)}))))
         (sort-by :invoke-seq)
         vec)))

(defn contiguous?
  "True when events carry the journal's strict 0..n-1 sequence."
  [events]
  (= (range (count events)) (map :seq events)))

(defn linearization
  "Return one legal sequential ordering of a bounded concurrent history, or
  nil when none exists.

  initial is the model's initial state.  (step state operation) returns
  {:state next-state} when the operation/result is legal at that point, and
  nil otherwise.  Real-time order is preserved: an operation that returned
  before another was invoked must precede it.  Overlapping operations may be
  tried in either order."
  [initial step events]
  (let [ops (operations events)
        _ (when (> (count ops) max-operations)
            (malformed! "history exceeds the bounded checker limit"
                        {:operation-count (count ops)
                         :maximum max-operations}))
        predecessors
        (into {}
              (map (fn [op]
                     [(:id op)
                      (->> ops
                           (filter #(< (:return-seq %) (:invoke-seq op)))
                           (map :id)
                           set)]))
              ops)]
    (letfn [(search [state remaining chosen witness]
              (if (empty? remaining)
                witness
                (some
                 (fn [op]
                   (when (every? chosen (get predecessors (:id op)))
                     (when-let [transition (step state op)]
                       (when-not (contains? transition :state)
                         (malformed! "model transition needs :state"
                                     {:operation op :transition transition}))
                       (search (:state transition)
                               (remove #(= (:id %) (:id op)) remaining)
                               (conj chosen (:id op))
                               (conj witness (:id op))))))
                 remaining)))]
      (search initial ops #{} []))))

(defn linearizable?
  "True when linearization finds a sequential-model witness."
  [initial step events]
  (some? (linearization initial step events)))
