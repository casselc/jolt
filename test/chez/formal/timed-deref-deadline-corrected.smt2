; Corrected timed latch rule: state ready at entry or a condition wake before
; the absolute deadline can produce a value. Once condition-wait reports
; timeout, mutex reacquisition and later state cannot change that outcome.
;
; Expected: UNSAT for a returned post-deadline value.

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
           :named valid_deadline))
(assert (! (< deadline_step mutex_reacquire_step)
           :named timeout_may_precede_reacquisition))

(declare-const ready_at_entry Bool)
(assert (! (= ready_at_entry
              (< completion_step entry_check_step))
           :named entry_state_observation))

(declare-const signaled_before_deadline Bool)
(assert (! (= signaled_before_deadline
              (and (< entry_check_step completion_step)
                   (< completion_step deadline_step)))
           :named condition_wait_result))

(declare-const implementation_returns_value Bool)
(assert (! (= implementation_returns_value
              (or ready_at_entry signaled_before_deadline))
           :named timeout_is_terminal))

(declare-const completion_after_deadline Bool)
(assert (! (= completion_after_deadline
              (< deadline_step completion_step))
           :named late_completion_definition))

(declare-const violation Bool)
(assert (! (= violation
              (and implementation_returns_value completion_after_deadline))
           :named post_deadline_value_definition))
(assert (! violation :named post_deadline_value_query))

