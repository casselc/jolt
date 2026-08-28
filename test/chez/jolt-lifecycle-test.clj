;; Focused gate for jolt.lifecycle/once-action. Run:
;;   bin/jolt run test/chez/jolt-lifecycle-test.clj
(ns jolt-lifecycle-test)

(load-file "test/chez/support/jolt/test/history.clj")
(require '[jolt.fibers :as fib]
         '[jolt.lifecycle :as lifecycle]
         '[jolt.test.history :as history])

(def failures (atom []))

(defn fail! [label data]
  (swap! failures conj (str label ": " (pr-str data))))

(defn check! [label predicate data]
  (when-not predicate
    (fail! label data)))

(def timeout-token ::timeout)

(defn await! [label awaitable]
  (let [value (deref awaitable 10000 timeout-token)]
    (when (identical? timeout-token value)
      (fail! (str label " timed out") {}))
    value))

(defn once-step [state operation]
  (let [observed (:output operation)]
    (cond
      (nil? (:outcome state)) {:state {:outcome observed}}
      (= (:outcome state) observed) {:state state}
      :else nil)))

(def incompatible-history
  [{:seq 0 :id :a :phase :invoke :op :call}
   {:seq 1 :id :b :phase :invoke :op :call}
   {:seq 2 :id :a :phase :return :output :returned}
   {:seq 3 :id :b :phase :return :output :thrown}])

(check! "once model rejects callers observing different outcomes"
        (not (history/linearizable? {:outcome nil} once-step incompatible-history))
        {:events incompatible-history})

;; Sequential identity is part of the contract, including the actual object and
;; Throwable rather than an equal value or reconstructed exception.
(let [runs (atom 0)
      object (atom :object)
      action (lifecycle/once-action #(do (swap! runs inc) object))]
  (check! "sequential calls execute once" (= 1 (do (action) (action) @runs))
          {:runs @runs})
  (check! "sequential calls return the identical object"
          (and (identical? object (action))
               (identical? (action) (action)))
          {}))

(let [runs (atom 0)
      error (ex-info "same failure" {:test :once-action})
      action (lifecycle/once-action #(do (swap! runs inc) (throw error)))
      observed (mapv (fn [_]
                       (try (action) nil (catch Throwable caught caught)))
                     (range 3))]
  (check! "sequential throws execute once" (= 1 @runs) {:runs @runs})
  (check! "sequential calls rethrow the identical object"
          (every? #(identical? error %) observed)
          {:observed observed}))

;; Cancellation of the winning future interrupts the action body. The future
;; itself reports cancellation, but the action still publishes that one
;; InterruptedException to every other and later caller instead of stranding
;; them on an unfulfilled outcome promise.
(let [body-entered (promise)
      never (promise)
      runs (atom 0)
      action (lifecycle/once-action
              #(do
                 (swap! runs inc)
                 (deliver body-entered true)
                 @never))
      winner (future (action))]
  (await! "cancelled winner body entered" body-entered)
  (let [waiter (future
                 (try (action) nil (catch Throwable error error)))]
    (check! "winning future accepts cancellation"
            (future-cancel winner) {})
    (let [first-error (await! "cancelled winner waiter" waiter)
          repeated-error (try (action) nil (catch Throwable error error))]
      (check! "cancelled body executes once" (= 1 @runs) {:runs @runs})
      (check! "cancellation publishes an interruption"
              (instance? InterruptedException first-error)
              {:observed first-error})
      (check! "cancellation publishes the identical error"
              (identical? first-error repeated-error)
              {:first first-error :repeated repeated-error}))))

(defn launch [kind f]
  [kind (if (= :fiber kind) (fib/spawn f) (future (f)))])

(defn join-worker [[kind handle]]
  (if (= :fiber kind) (fib/join handle) @handle))

(defn concurrent-case! [label mode]
  (let [contenders 8
        ready-count (atom 0)
        all-ready (promise)
        start (promise)
        invoked-count (atom 0)
        all-invoked (promise)
        body-entered (promise)
        release-body (promise)
        body-runs (atom 0)
        returned-object (atom :returned-object)
        thrown-object (ex-info "concurrent failure" {:test label})
        journal (history/journal)
        action (lifecycle/once-action
                (fn []
                  (swap! body-runs inc)
                  (deliver body-entered true)
                  @release-body
                  (if (= :return mode)
                    returned-object
                    (throw thrown-object))))
        worker (fn [id]
                 (when (= contenders (swap! ready-count inc))
                   (deliver all-ready true))
                 @start
                 (history/record! journal {:id id :phase :invoke :op :call})
                 (when (= contenders (swap! invoked-count inc))
                   (deliver all-invoked true))
                 (let [observed
                       (try
                         {:kind :returned :object (action)}
                         (catch Throwable error
                           {:kind :thrown :object error}))]
                   (history/record! journal
                                    {:id id :phase :return
                                     :output (:kind observed)})
                   observed))
        ;; Cross the two supported scheduling domains in one history: threads
        ;; block on the promise while fibers park without pinning a carrier.
        workers (mapv (fn [id]
                        (launch (if (even? id) :fiber :thread)
                                #(worker id)))
                      (range contenders))]
    (await! (str label " workers ready") all-ready)
    (deliver start true)
    (await! (str label " invocations recorded") all-invoked)
    (await! (str label " body entered") body-entered)
    (deliver release-body true)
    (let [observed (mapv join-worker workers)
          events @journal
          expected-kind (if (= :return mode) :returned :thrown)
          expected-object (if (= :return mode) returned-object thrown-object)]
      (check! (str label " body executes once") (= 1 @body-runs)
              {:body-runs @body-runs :events events})
      (check! (str label " every caller observes the outcome kind")
              (every? #(= expected-kind (:kind %)) observed)
              {:observed observed})
      (check! (str label " every caller observes identical object")
              (every? #(identical? expected-object (:object %)) observed)
              {:observed observed})
      (check! (str label " journal is contiguous")
              (history/contiguous? events) {:events events})
      (check! (str label " history is linearizable")
              (history/linearizable? {:outcome nil} once-step events)
              {:events events}))))

(concurrent-case! "concurrent return" :return)
(concurrent-case! "concurrent throw" :throw)

(if (empty? @failures)
  (println "JOLT-LIFECYCLE-TEST OK")
  (do
    (doseq [failure @failures]
      (println "FAIL:" failure))
    (println "JOLT-LIFECYCLE-TEST FAILED:" (count @failures))
    (System/exit 1)))
