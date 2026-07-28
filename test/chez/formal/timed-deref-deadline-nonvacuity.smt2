; Non-vacuity controls for the corrected rule. It must retain all useful paths:
; state ready at entry, a completion during the wait but before the deadline,
; and a genuine timeout despite a completion before mutex reacquisition.
;
; Expected: SAT.

(declare-const ready_at_entry_completion Int)
(declare-const ready_at_entry_check Int)
(assert (! (< ready_at_entry_completion ready_at_entry_check)
           :named pre_delivered_path))

(declare-const wait_entry Int)
(declare-const wait_completion Int)
(declare-const wait_deadline Int)
(assert (! (and (< wait_entry wait_completion)
                (< wait_completion wait_deadline))
           :named pre_deadline_signal_path))

(declare-const timeout_deadline Int)
(declare-const late_completion Int)
(declare-const timeout_reacquire Int)
(assert (! (and (<= 0 ready_at_entry_completion)
                (<= ready_at_entry_completion 3)
                (<= 0 ready_at_entry_check)
                (<= ready_at_entry_check 3)
                (<= 0 wait_entry) (<= wait_entry 3)
                (<= 0 wait_completion) (<= wait_completion 3)
                (<= 0 wait_deadline) (<= wait_deadline 3)
                (<= 0 timeout_deadline) (<= timeout_deadline 3)
                (<= 0 late_completion) (<= late_completion 3)
                (<= 0 timeout_reacquire) (<= timeout_reacquire 3))
           :named bounded_steps))
(assert (! (and (< timeout_deadline late_completion)
                (< late_completion timeout_reacquire))
           :named post_deadline_reacquire_path))

(declare-const ready_at_entry_returns_value Bool)
(assert (! (= ready_at_entry_returns_value
              (< ready_at_entry_completion ready_at_entry_check))
           :named pre_delivered_result))

(declare-const pre_deadline_returns_value Bool)
(assert (! (= pre_deadline_returns_value
              (and (< wait_entry wait_completion)
                   (< wait_completion wait_deadline)))
           :named pre_deadline_result))

(declare-const late_completion_returns_timeout Bool)
(assert (! (= late_completion_returns_timeout
              (< timeout_deadline late_completion))
           :named timeout_result))

(assert (! (and ready_at_entry_returns_value
                pre_deadline_returns_value
                late_completion_returns_timeout)
           :named useful_paths_query))
