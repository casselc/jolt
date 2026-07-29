; Bug control: two callers in one Jolt process may enter the complete Git-cache
; inspection/repair transaction concurrently when no process-local monitor
; guards it. The filesystem lock still selects one publisher, but it cannot
; protect the runtime from overlapping host/Git work before that publication.

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

; The one-fault control: monitor serialization is omitted.
(assert (! true :named process_monitor_missing))

(declare-const transaction_overlap Bool)
(assert (! (= transaction_overlap
              (and (< a_enter b_exit)
                   (< b_enter a_exit)))
           :named transaction_overlap_definition))

(declare-const violation Bool)
(assert (! (= violation transaction_overlap)
           :named violation_definition))
(assert (! violation :named overlapping_transaction_query))
