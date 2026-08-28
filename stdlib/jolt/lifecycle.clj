;; jolt.lifecycle -- small, host-neutral lifecycle coordination primitives.
;;
;; This namespace does not define resource ownership or FFI teardown policy.
;; A library still owns ordering constraints such as unregister-before-free and
;; cancel-before-destroy; once-action only publishes one action outcome.
(ns jolt.lifecycle)

(defn once-action
  "Wrap zero-argument action f in a function that executes f at most once.

  Concurrent and repeated callers wait for the winning invocation and observe
  the identical returned object, or rethrow the identical Throwable object.
  Waiting on a fiber parks its carrier through the ordinary promise contract.

  The action must not reenter its own wrapper before it completes. Such a call
  would wait for the outcome that the same invocation still has to publish.
  Ordinary thrown values are published; process termination and native crashes
  are outside this in-process coordination contract."
  [f]
  (let [claimed? (atom false)
        outcome (promise)]
    (fn []
      (when (compare-and-set! claimed? false true)
        (deliver outcome
                 (try
                   [:returned (f)]
                   (catch Throwable error
                     [:thrown error]))))
      (let [[kind value] @outcome]
        (if (= :returned kind)
          value
          (throw value))))))
