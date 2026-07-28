; Historical timed deref rechecked latch state after condition-wait reported a
; timeout and reacquired the mutex. A completion after the deadline but before
; mutex reacquisition could therefore be returned as a successful value.
;
; Expected: SAT. The bounded witness is entry 0, deadline 1, completion 2,
; mutex reacquisition 3.

(declare-const entry_check_step Int)
(declare-const deadline_step Int)
(declare-const completion_step Int)
(declare-const mutex_reacquire_step Int)

(assert (! (and (<= 0 entry_check_step) (<= entry_check_step 3)
                (<= 0 deadline_step) (<= deadline_step 3)
                (<= 0 completion_step) (<= completion_step 3)
                (<= 0 mutex_reacquire_step) (<= mutex_reacquire_step 3))
           :named bounded_steps))
(assert (! (distinct entry_check_step deadline_step
                     completion_step mutex_reacquire_step)
           :named distinct_events))
(assert (! (< entry_check_step deadline_step)
           :named wait_begins_before_deadline))
(assert (! (< deadline_step completion_step)
           :named completion_is_late))
(assert (! (< completion_step mutex_reacquire_step)
           :named producer_wins_mutex_before_waiter))

(declare-const signaled_before_deadline Bool)
(assert (! (= signaled_before_deadline
              (< completion_step deadline_step))
           :named condition_wait_result))

(declare-const ready_at_final_recheck Bool)
(assert (! (= ready_at_final_recheck
              (< completion_step mutex_reacquire_step))
           :named final_state_observation))

(declare-const implementation_returns_value Bool)
(assert (! (= implementation_returns_value
              (or signaled_before_deadline
                  (and (not signaled_before_deadline)
                       ready_at_final_recheck)))
           :named historical_final_recheck))

(declare-const violation Bool)
(assert (! (= violation
              (and implementation_returns_value
                   (not signaled_before_deadline)))
           :named post_deadline_value_definition))
(assert (! violation :named post_deadline_value_query))
