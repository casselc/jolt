(ns jolt-ffi-arena-trace-test
  (:require [hegel.core :as h]
            [hegel.generator :as g]
            [hegel.trace :as trace]
            [jolt.ffi :as ffi]))

(def resource-lifecycle
  (trace/event-model
   :ffi-arena-resource-lifecycle
   {:scope :resource-id
    :initial :unseen
    :step (fn [state event]
            (case [state (:event event)]
              [:unseen :allocate] :live
              [:live :free] :closed
              :invalid))
    :invariant (fn [state _event] (not= :invalid state))
    :final #(= :closed %)}))

(def reverse-release
  (trace/rule
   :ffi-arena-reverse-release
   (fn [events]
     (= (->> events
             (filter #(= :allocate (:event %)))
             (mapv :resource-id)
             rseq
             vec)
        (->> events
             (filter #(= :free (:event %)))
             (mapv :resource-id))))))

(def trace-rules
  [(trace/contiguous-sequence :ffi-arena-complete-journal 1)
   resource-lifecycle
   reverse-release])

(defn- record! [events sequence event]
  (let [event (assoc event :seq (swap! sequence inc))]
    (swap! events conj event)
    event))

(defn- exercise-arena!
  "Run one modeled arena scope. fail-at is a zero-based allocation index or nil;
  throw-body? throws after every requested allocation succeeds. Returns the
  semantic ownership trace after checking it against the shared Hegel rules."
  [sizes fail-at throw-body?]
  (let [events (atom [])
        sequence (atom 0)
        next-resource (atom 0)
        allocation-index (atom -1)
        failure (atom nil)]
    (with-redefs
      [ffi/alloc
       (fn [_byte-count]
         (let [index (swap! allocation-index inc)]
           (when (= fail-at index)
             (throw (ex-info "modeled allocation failure"
                             {:type ::allocation-failure
                              :allocation-index index})))
           (let [resource-id (swap! next-resource inc)]
             (record! events sequence
                      {:event :allocate :resource-id resource-id})
             resource-id)))
       ffi/free
       (fn [resource-id]
         (record! events sequence {:event :free :resource-id resource-id})
         nil)]
      (try
        (ffi/with-arena [allocate!]
          (doseq [size sizes]
            (allocate! size))
          (when throw-body?
            (throw (ex-info "modeled body failure" {:type ::body-failure})))
          :returned)
        (catch Throwable error
          (reset! failure error))))
    (let [completed (if (nil? fail-at) (count sizes) fail-at)
          expected-type (cond
                          (some? fail-at) ::allocation-failure
                          throw-body? ::body-failure
                          :else nil)]
      (when-not (= expected-type (some-> @failure ex-data :type))
        (throw (ex-info "arena propagated the wrong modeled outcome"
                        {:hegel/origin
                         "jolt-ffi-arena-trace/modeled-outcome"
                         :expected expected-type
                         :actual (some-> @failure ex-data :type)})))
      (when-not (= completed (count (filter #(= :allocate (:event %)) @events)))
        (throw (ex-info "arena trace recorded the wrong allocation count"
                        {:hegel/origin
                         "jolt-ffi-arena-trace/allocation-count"
                         :expected completed
                         :events @events})))
      (trace/check! @events trace-rules {:max-events 32}))))

(defn- generated-lifecycle-check! []
  (h/run-test!
   {:name "jolt-core/ffi-arena-linear-lifecycle"
    :test-cases 200
    :seed 20260828
    :database ""
    :verbosity :quiet}
   (fn [_]
     (let [sizes (h/draw! (g/vector {:max-size 16} (g/integer 0 4096)))
           fail-at (when (and (seq sizes) (h/draw! (g/boolean)))
                     (h/draw! (g/integer 0 (dec (count sizes)))))
           throw-body? (and (nil? fail-at) (h/draw! (g/boolean)))]
       (exercise-arena! sizes fail-at throw-body?)))))

(defn -main [& _]
  ;; Fixed witnesses keep all three exits explicit even if generator behavior
  ;; changes. The property then explores and shrinks their sizes and positions.
  (exercise-arena! [8 16 32] nil false)
  (exercise-arena! [8 16 32] nil true)
  (exercise-arena! [8 16 32] 1 false)
  (let [result (generated-lifecycle-check!)]
    (when-not (:passed? result)
      (throw (ex-info "generated arena lifecycle check failed"
                      {:result result}))))
  (println "JOLT-FFI-ARENA-TRACE-TEST OK")
  (flush))

(-main)
