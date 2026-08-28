;; Semantic-history gate for core concurrency.  Run:
;;   bin/jolt run test/chez/concurrency-history-test.clj
;;
;; The simultaneous deliverers create a real OS-thread race, but the oracle is
;; timing-independent: every observed history must admit a legal single-value
;; promise linearization.
(ns concurrency-history-test)

(load-file "test/chez/support/jolt/test/history.clj")
(require '[jolt.test.history :as history])

(def failures (atom []))

(defn fail! [label data]
  (swap! failures conj (str label ": " (pr-str data))))

(defn promise-step [state operation]
  (let [{:keys [input output]} operation]
    (cond
      (and (not (:delivered? state)) (= :won output))
      {:state {:delivered? true :value input}}

      (and (:delivered? state) (= :lost output))
      {:state state}

      :else nil)))

(def overlapping-illegal-history
  [{:seq 0 :id :a :phase :invoke :op :deliver :input :a}
   {:seq 1 :id :b :phase :invoke :op :deliver :input :b}
   {:seq 2 :id :a :phase :return :output :won}
   {:seq 3 :id :b :phase :return :output :won}])

(when (history/linearizable?
       {:delivered? false :value nil}
       promise-step
       overlapping-illegal-history)
  (fail! "checker accepted two overlapping delivery winners"
         {:events overlapping-illegal-history}))

(when-not (= [:b :a]
             (history/linearization
              {:delivered? false :value nil}
              promise-step
              [{:seq 0 :id :a :phase :invoke :op :deliver :input :a}
               {:seq 1 :id :b :phase :invoke :op :deliver :input :b}
               {:seq 2 :id :b :phase :return :output :won}
               {:seq 3 :id :a :phase :return :output :lost}]))
  (fail! "checker did not reorder overlapping operations to find a witness" {}))

(let [real-time-illegal
      [{:seq 0 :id :a :phase :invoke :op :deliver :input :a}
       {:seq 1 :id :a :phase :return :output :lost}
       {:seq 2 :id :b :phase :invoke :op :deliver :input :b}
       {:seq 3 :id :b :phase :return :output :won}]]
  (when (history/linearizable?
         {:delivered? false :value nil}
         promise-step
         real-time-illegal)
    (fail! "checker reordered operations across a real-time boundary"
           {:events real-time-illegal})))

(defn run-round! [round contenders]
  (let [p (promise)
        start (promise)
        all-ready (promise)
        ready (atom 0)
        journal (history/journal)
        workers
        (mapv
         (fn [value]
           (future
             (when (= contenders (swap! ready inc))
               (deliver all-ready true))
             @start
             (let [id [round value]]
               (history/record! journal
                                {:id id :phase :invoke
                                 :op :deliver :input value})
               (let [result (deliver p value)]
                 (history/record! journal
                                  {:id id :phase :return
                                   :output (if (identical? result p)
                                             :won
                                             :lost)})))))
         (range contenders))]
    @all-ready
    (deliver start true)
    (doseq [worker workers] @worker)
    (let [events @journal
          ops (history/operations events)
          winners (filter #(= :won (:output %)) ops)
          witness (history/linearization
                   {:delivered? false :value nil}
                   promise-step
                   events)]
      (when-not (history/contiguous? events)
        (fail! "journal sequence is not contiguous"
               {:round round :events events}))
      (when-not (= 1 (count winners))
        (fail! "promise did not have exactly one delivery winner"
               {:round round :events events}))
      (when-not witness
        (fail! "promise history is not linearizable"
               {:round round :events events}))
      (when (= 1 (count winners))
        (let [winner-value (:input (first winners))]
          (when-not (= winner-value @p)
            (fail! "promise value differs from delivery winner"
                   {:round round
                    :winner winner-value
                    :observed @p
                    :events events})))))))

;; Enough repeated, barrier-released contenders to exercise overlapping native
;; delivery without making this a soak test.  There are no sleeps or timeouts in
;; the correctness path.
(doseq [round (range 64)]
  (run-round! round 8))

(if (empty? @failures)
  (println "CONCURRENCY-HISTORY-TEST OK")
  (do
    (doseq [failure @failures]
      (println "FAIL:" failure))
    (println "CONCURRENCY-HISTORY-TEST FAILED:" (count @failures))
    (System/exit 1)))
