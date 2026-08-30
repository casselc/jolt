(defn thrown-shape [cause f]
  (try
    [:ok (f)]
    (catch Throwable e
      (let [c (ex-cause e)]
        [:throw
         (.getName (class e))
         (some-> c class .getName)
         (some-> c ex-message)
         (identical? cause c)]))))

(defn outcome [f]
  (try
    [:ok (f)]
    (catch Throwable e
      [:throw (.getName (class e))])))

(defn completed-case []
  (let [ft (java.util.concurrent.FutureTask.
            ^java.util.concurrent.Callable (fn [] 16))]
    (.run ft)
    [(.get ft) (outcome #(deref ft))
     (instance? java.util.concurrent.Future ft)
     (instance? java.util.concurrent.RunnableFuture ft)
     (instance? java.lang.Runnable ft)
     (instance? clojure.lang.IDeref ft)]))

(defn failure-case []
  (let [cause (ex-info "future-host-oracle" {:case :failure})
        ft (java.util.concurrent.FutureTask.
            ^java.util.concurrent.Callable (fn [] (throw cause)))]
    (.run ft)
    [(thrown-shape cause #(.get ft))
     (thrown-shape cause #(deref ft))]))

(defn once-case []
  (let [runs (atom 0)
        ft (java.util.concurrent.FutureTask.
            ^java.util.concurrent.Callable (fn [] (swap! runs inc)))]
    (.run ft)
    (.run ft)
    [@runs (.get ft)]))

(defn timeout-case []
  (let [ft (java.util.concurrent.FutureTask.
            ^java.util.concurrent.Callable (fn [] :never-started))]
    [(outcome #(deref ft 5 :timeout))
     (try
       (.get ft 5 java.util.concurrent.TimeUnit/MILLISECONDS)
       :no-timeout
       (catch java.util.concurrent.TimeoutException _ :timeout))]))

(defn cancellation-case []
  (let [ft (java.util.concurrent.FutureTask.
            ^java.util.concurrent.Callable (fn [] :must-not-run))]
    [(.cancel ft false)
     (.isCancelled ft)
     (.isDone ft)
     (try (.get ft) :no-throw
          (catch java.util.concurrent.CancellationException _ :cancelled))
     (outcome #(deref ft))
     (do (.run ft) (.isCancelled ft))]))

(defn running-cancellation-case [may-interrupt?]
  (let [started (java.util.concurrent.CountDownLatch. 1)
        release (java.util.concurrent.CountDownLatch. 1)
        completions (atom 0)
        ft (java.util.concurrent.FutureTask.
            ^java.util.concurrent.Callable
            (fn []
              (.countDown started)
              (.await release)
              (swap! completions inc)))
        runner (Thread. #(.run ft))]
    (.start runner)
    (.await started)
    (let [cancelled? (.cancel ft may-interrupt?)]
      (.join runner 200)
      (let [alive-before-release? (.isAlive runner)]
        (.countDown release)
        (.join runner 2000)
        [cancelled? (.isCancelled ft) (.isDone ft)
         alive-before-release? (.isAlive runner) @completions
         (outcome #(.get ft))]))))

(defn runnable-result-case []
  (let [runs (atom 0)
        task (reify Runnable (run [_] (swap! runs inc)))
        ft (java.util.concurrent.FutureTask. task :runnable-result)]
    (.run ft)
    [@runs (outcome #(.get ft))
     (instance? java.util.concurrent.FutureTask ft)
     (instance? java.util.concurrent.RunnableFuture ft)]))

(defn interrupted-get-case []
  (let [ft (java.util.concurrent.FutureTask.
            ^java.util.concurrent.Callable (fn [] :never-started))
        entered (java.util.concurrent.CountDownLatch. 1)
        result (promise)
        t (Thread.
           (fn []
             (.countDown entered)
             (deliver result
                      (try
                        (.get ft)
                        :no-interrupt
                        (catch InterruptedException _ :interrupted)))))]
    (.start t)
    (.await entered)
    (.interrupt t)
    (.join t 2000)
    [(deref result 2000 :timeout) (.isAlive t)]))

(defn executor-case []
  (let [ex (java.util.concurrent.Executors/newFixedThreadPool 1)]
    (try
      (let [ok (.submit ex ^java.util.concurrent.Callable (fn [] 23))
            cause (ex-info "executor-future-oracle" {:case :failure})
            bad (.submit ex ^java.util.concurrent.Callable (fn [] (throw cause)))]
        [(instance? java.util.concurrent.ExecutorService ex)
         (instance? java.util.concurrent.Executor ex)
         (instance? java.util.concurrent.Future ok)
         (.get ok)
         (outcome #(deref ok))
         (thrown-shape cause #(.get bad))
         (thrown-shape cause #(deref bad))])
      (finally
        (.shutdown ex)
        (.awaitTermination ex 5 java.util.concurrent.TimeUnit/SECONDS)))))

(defn queued-cancellation-case []
  (let [ex (java.util.concurrent.Executors/newFixedThreadPool 1)
        started (java.util.concurrent.CountDownLatch. 1)
        release (java.util.concurrent.CountDownLatch. 1)
        runs (atom 0)]
    (try
      (let [blocker (.submit ex ^java.util.concurrent.Callable
                             (fn [] (.countDown started) (.await release) :blocker))
            _ (.await started)
            submitted (try
                        [:ok (.submit ex
                                      ^Runnable (reify Runnable (run [_] (swap! runs inc)))
                                      :queued-result)]
                        (catch Throwable e
                          [:throw (.getName (class e))]))]
        (if (= :throw (first submitted))
          (do
            (.countDown release)
            (.get blocker)
            [:submit-error (second submitted)])
          (let [queued (second submitted)
                cancelled? (.cancel queued false)]
            (.countDown release)
            (.get blocker)
            (.shutdown ex)
            (.awaitTermination ex 5 java.util.concurrent.TimeUnit/SECONDS)
            [:submitted cancelled? (.isCancelled queued) (.isDone queued) @runs
             (outcome #(.get queued))
             (instance? java.util.concurrent.Future queued)
             (instance? java.util.concurrent.RunnableFuture queued)
             (instance? java.util.concurrent.FutureTask queued)])))
      (finally
        (.countDown release)
        (.shutdownNow ex)))))

(defn method-present? [x method]
  (try
    (case method
      :get-queue (do (.getQueue x) true))
    (catch Throwable _ false)))

(defn hierarchy-case []
  (let [fixed (java.util.concurrent.Executors/newFixedThreadPool 1)
        single (java.util.concurrent.Executors/newSingleThreadExecutor)
        direct (java.util.concurrent.ThreadPoolExecutor.
                1 1 0 java.util.concurrent.TimeUnit/MILLISECONDS
                (java.util.concurrent.ArrayBlockingQueue. 2))]
    (try
      [(instance? java.lang.AutoCloseable fixed)
       (instance? java.util.concurrent.ExecutorService fixed)
       (instance? java.util.concurrent.Executor fixed)
       (instance? java.util.concurrent.ThreadPoolExecutor fixed)
       (instance? java.util.concurrent.ThreadPoolExecutor single)
       (instance? java.util.concurrent.ThreadPoolExecutor direct)
       (method-present? fixed :get-queue)
       (method-present? single :get-queue)
       (try
         (let [timeout (java.util.concurrent.TimeoutException.)]
           [:ok (instance? java.lang.Exception timeout)
            (instance? java.lang.Throwable timeout)])
         (catch Throwable e
           [:ctor-error (.getName (class e))]))]
      (finally
        (.shutdownNow fixed)
        (.shutdownNow single)
        (.shutdownNow direct)))))

(prn
 [[:completed (completed-case)]
  [:failure (failure-case)]
  [:once (once-case)]
  [:timeout (timeout-case)]
  [:cancellation (cancellation-case)]
  [:running-cancel-false (running-cancellation-case false)]
  [:running-cancel-true (running-cancellation-case true)]
  [:runnable-result (runnable-result-case)]
  [:interrupted-get (interrupted-get-case)]
  [:executor (executor-case)]
  [:queued-cancellation (queued-cancellation-case)]
  [:hierarchy (hierarchy-case)]])
