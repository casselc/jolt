; Non-vacuity control for the corrected gate.  One task is accepted before
; shutdown, remains drainable after shutdown, and a later task is rejected.
;
; Expected: SAT.

(declare-const enqueue_before_step Int)
(declare-const shutdown_step Int)
(declare-const shutdown_return_step Int)
(declare-const drain_step Int)
(declare-const worker_exit_step Int)
(declare-const enqueue_after_step Int)

(assert (! (and (<= 0 enqueue_before_step)
                (<= enqueue_before_step 5)
                (<= 0 shutdown_step)
                (<= shutdown_step 5)
                (<= 0 shutdown_return_step)
                (<= shutdown_return_step 5)
                (<= 0 drain_step)
                (<= drain_step 5)
                (<= 0 worker_exit_step)
                (<= worker_exit_step 5)
                (<= 0 enqueue_after_step)
                (<= enqueue_after_step 5))
           :named bounded_steps))
(assert (! (distinct enqueue_before_step shutdown_step shutdown_return_step
                     drain_step worker_exit_step enqueue_after_step)
           :named distinct_transitions))
(assert (! (< enqueue_before_step shutdown_step)
           :named first_task_admitted))
(assert (! (< shutdown_step shutdown_return_step)
           :named shutdown_returns_after_publication))
(assert (! (< shutdown_step drain_step)
           :named admitted_queue_drains_during_shutdown))
(assert (! (< drain_step worker_exit_step)
           :named worker_exits_only_after_drain))
(assert (! (< shutdown_return_step enqueue_after_step)
           :named later_submission))

(declare-const accepted_before Bool)
(assert (! (= accepted_before
              (< enqueue_before_step shutdown_step))
           :named accepted_before_definition))
(declare-const rejected_after Bool)
(assert (! (= rejected_after
              (< shutdown_step enqueue_after_step))
           :named rejected_after_definition))
(declare-const admitted_task_drained Bool)
(assert (! (= admitted_task_drained
              (and accepted_before (< drain_step worker_exit_step)))
           :named drain_definition))

(assert (! accepted_before :named accepted_before_witness))
(assert (! rejected_after :named rejected_after_witness))
(assert (! admitted_task_drained :named drain_witness))
