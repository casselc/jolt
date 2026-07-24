; Historical executor admission: shutdown publication and queue admission were
; not one atomic decision.  A worker can observe shutdown plus an empty queue,
; terminate, and a later submit can still append a task.
;
; Expected: SAT.  The model is the bounded counterexample.

(declare-const shutdown_publish_step Int)
(declare-const worker_exit_step Int)
(declare-const shutdown_return_step Int)
(declare-const enqueue_step Int)

(assert (! (and (<= 0 shutdown_publish_step)
                (<= shutdown_publish_step 3)
                (<= 0 worker_exit_step)
                (<= worker_exit_step 3)
                (<= 0 shutdown_return_step)
                (<= shutdown_return_step 3)
                (<= 0 enqueue_step)
                (<= enqueue_step 3))
           :named bounded_steps))
(assert (! (distinct shutdown_publish_step worker_exit_step
                     shutdown_return_step enqueue_step)
           :named distinct_transitions))
(assert (! (< shutdown_publish_step worker_exit_step)
           :named worker_observes_shutdown_and_empty))
(assert (! (< worker_exit_step shutdown_return_step)
           :named shutdown_waits_for_worker_exit))
(assert (! (< shutdown_return_step enqueue_step)
           :named submission_occurs_after_shutdown_returns))

; The historical enqueue path did not consult shutdown.
(declare-const implementation_accepts Bool)
(assert (! (= implementation_accepts true)
           :named unconditional_enqueue))

(declare-const stranded_task Bool)
(assert (! (= stranded_task
              (and implementation_accepts
                   (< worker_exit_step enqueue_step)))
           :named stranded_definition))
(assert (! stranded_task :named stranded_task_query))
