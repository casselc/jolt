; Non-vacuity: the monitor permits two useful callers to complete sequentially.

(declare-const a_enter Int)
(declare-const a_exit Int)
(declare-const b_enter Int)
(declare-const b_exit Int)

(assert (! (= a_enter 0) :named caller_a_enters))
(assert (! (= a_exit 2) :named caller_a_completes))
(assert (! (= b_enter 3) :named caller_b_enters_after_release))
(assert (! (= b_exit 5) :named caller_b_completes))
(assert (! (or (< a_exit b_enter)
               (< b_exit a_enter))
           :named process_monitor_serializes_complete_transactions))

(declare-const both_completed Bool)
(assert (! (= both_completed
              (and (< a_enter a_exit)
                   (< b_enter b_exit)))
           :named both_completed_definition))
(assert (! both_completed :named useful_sequential_execution))
