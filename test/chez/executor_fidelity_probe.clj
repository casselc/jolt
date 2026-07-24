(ns executor-fidelity-probe
  "Characterize the JVM-named executor constructors without changing their API.

  Forty submitted tasks block on one gate. The number which start before the
  gate opens exposes the implementation's actual parallelism. This is an opt-in
  evidence probe, not a conformance gate pinning the current fixed-32 behavior.
  The recorded baseline SHA is descriptive; override it with the first argument
  or JOLT_OBSERVED_BASELINE_SHA.")

(def task-count 40)
(def watchdog-ms 20000)
(def default-observed-baseline "260a392a795089de3fb5ab700b386a334f01c051")

(defn observe [label make-executor]
  (let [executor (make-executor)
        gate (promise)
        started (atom 0)]
    (try
      (let [futures (mapv (fn [_]
                            (.submit executor
                              (fn []
                                (swap! started inc)
                                @gate
                                :done)))
                          (range task-count))]
        ;; Give every available worker time to reach the shared gate.
        (Thread/sleep 250)
        (let [active-before-release @started
              _ (deliver gate true)
              completion (future (doseq [f futures] (.get f)) :done)
              completed (deref completion watchdog-ms ::timed-out)]
          (when (= ::timed-out completed)
            (future-cancel completion)
            (throw (ex-info "executor probe watchdog expired"
                            {:constructor label :watchdog-ms watchdog-ms})))
          {:constructor label
           :submitted task-count
           :started-before-release active-before-release}))
      (finally
        ;; Unblock queued/running tasks and terminate workers on every path.
        (deliver gate true)
        (.shutdownNow executor)
        (.awaitTermination executor 1000)))))

(defn -main [& args]
  (let [observed-baseline (or (first args)
                              (System/getenv "JOLT_OBSERVED_BASELINE_SHA")
                              default-observed-baseline)
        outcome
        (try
          {:status :ok
           :observations
           [(observe :cached
                     #(java.util.concurrent.Executors/newCachedThreadPool))
            (observe :virtual-per-task
                     #(java.util.concurrent.Executors/newVirtualThreadPerTaskExecutor))
            (observe :work-stealing
                     #(java.util.concurrent.Executors/newWorkStealingPool))]}
          (catch Throwable t
            {:status :failed :error (.getMessage t)}))
        result (merge {:observed-baseline-sha observed-baseline
                       :runtime (System/getProperty "jolt.version")
                       :watchdog-ms watchdog-ms}
                      outcome)]
    (println result)
    (flush)
    (System/exit (if (= :ok (:status result)) 0 1))))

(apply -main *command-line-args*)
