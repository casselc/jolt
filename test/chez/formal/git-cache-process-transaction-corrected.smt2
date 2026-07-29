; Corrected query: the complete same-process Git-cache transaction is admitted
; through one object monitor. The adjacent directory lock remains the separate
; cross-process publication authority.

(declare-const a_enter Int)
(declare-const a_exit Int)
(declare-const b_enter Int)
(declare-const b_exit Int)

(assert (! (and (<= 0 a_enter) (<= a_enter 7)
                (<= 0 a_exit)  (<= a_exit 7)
                (<= 0 b_enter) (<= b_enter 7)
                (<= 0 b_exit)  (<= b_exit 7))
           :named bounded_event_domain))
(assert (! (< a_enter a_exit) :named caller_a_transaction_order))
(assert (! (< b_enter b_exit) :named caller_b_transaction_order))
(assert (! (distinct a_enter a_exit b_enter b_exit)
           :named distinct_events))

; One monitor is held from initial durable inspection through reuse, repair, or
; publication completion, so either A exits before B enters or vice versa.
(assert (! (or (< a_exit b_enter)
               (< b_exit a_enter))
           :named process_monitor_serializes_complete_transactions))

(declare-const transaction_overlap Bool)
(assert (! (= transaction_overlap
              (and (< a_enter b_exit)
                   (< b_enter a_exit)))
           :named transaction_overlap_definition))

(declare-const violation Bool)
(assert (! (= violation transaction_overlap)
           :named violation_definition))
(assert (! violation :named overlapping_transaction_query))
