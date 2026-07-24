(ns concurrent-ffi-stress
  "Opt-in concurrent FFI stress reduction.

  Observed baseline under investigation (not an enforced checkout):
    upstream SHA: 260a392a795089de3fb5ab700b386a334f01c051
    observed host: Linux x86_64 (WSL2), 64-bit pointers
    installed comparison runtime: jolt v0.4.15

  Override the recorded baseline with the first argument or
  JOLT_OBSERVED_BASELINE_SHA.

  This is intentionally separate from executor-fidelity work. It uses an
  explicitly bounded fixed pool and records the exact foreign signatures and
  collect-safe setting below. On the baseline host this reduced case has not
  reproduced the larger socket workload's `nonrecoverable invalid memory
  reference`; keep that distinction when extending it.")

(require '[jolt.ffi :as ffi])

(ffi/load-library)
(ffi/defcfn c-getpid "getpid" [] :int)
(ffi/defcfn c-usleep "usleep" [:uint] :int :blocking)

(def concurrency 64)
(def iterations 200)
(def pool-size 32)
(def watchdog-ms 60000)
(def default-observed-baseline "260a392a795089de3fb5ab700b386a334f01c051")

(defn worker [id]
  (dotimes [_ iterations]
    (when-not (pos? (c-getpid))
      (throw (ex-info "getpid returned a non-positive pid" {:worker id})))
    (when-not (zero? (c-usleep 100))
      (throw (ex-info "usleep failed" {:worker id}))))
  id)

(defn -main [& args]
  (let [executor (java.util.concurrent.Executors/newFixedThreadPool pool-size)
        observed-baseline (or (first args)
                              (System/getenv "JOLT_OBSERVED_BASELINE_SHA")
                              default-observed-baseline)
        started-at (System/currentTimeMillis)
        outcome
        (try
          (let [futures (mapv #(.submit executor (fn [] (worker %))) (range concurrency))
                ;; Executor Future.get has no effective timeout in the current
                ;; host shim. Wait for all results inside a native Jolt future,
                ;; whose timed deref supplies the watchdog.
                completion (future (mapv #(.get %) futures))
                completed (deref completion watchdog-ms ::timed-out)]
            (if (= ::timed-out completed)
              (do (future-cancel completion)
                  {:status :timed-out :completed 0})
              {:status :ok :completed (count completed)}))
          (catch Throwable t
            {:status :failed :completed 0 :error (.getMessage t)})
          (finally
            ;; Always release worker threads, including task failure and timeout.
            (.shutdownNow executor)
            (.awaitTermination executor 1000)))
        elapsed (- (System/currentTimeMillis) started-at)
        result (merge
                 {:observed-baseline-sha observed-baseline
                  :runtime (System/getProperty "jolt.version")
                  :os (System/getProperty "os.name")
                  :arch (or (System/getProperty "os.arch") "x86_64 (recorded host)")
                  :pointer-bits (* 8 (ffi/sizeof :pointer))
                  :executor {:type :fixed :workers pool-size}
                  :watchdog-ms watchdog-ms
                  :concurrency concurrency
                  :iterations iterations
                  :calls [{:symbol "getpid" :signature [[] :int] :collect-safe false}
                          {:symbol "usleep" :signature [[:uint] :int] :collect-safe true}]
                  :elapsed-ms elapsed}
                 outcome)
        ok? (and (= :ok (:status result))
                 (= concurrency (:completed result)))]
    (println result)
    (flush)
    (System/exit (if ok? 0 (if (= :timed-out (:status result)) 124 1)))))

(apply -main *command-line-args*)
