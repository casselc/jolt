; Expected result: SAT.
; Buggy loaded-libs update: two unrelated marks read the same initial set, each
; writes only its own addition, and the later stale write loses the other mark.
;
; Observed witness:
;   write_order=mark_a_then_b
;   final_has_a=false, final_has_b=true
;   lost_loaded_lib_mark=true, violation=true
;
; Chiasmus supplies check-sat/model extraction.

(declare-datatypes ()
  ((WriteOrder mark_a_then_b mark_b_then_a)))

(declare-const write_order WriteOrder)
(declare-const initial_has_a Bool)
(declare-const initial_has_b Bool)
(declare-const mark_a_requested Bool)
(declare-const mark_b_requested Bool)
(assert (! (= initial_has_a false)
           :named witness_initial_a_absent))
(assert (! (= initial_has_b false)
           :named witness_initial_b_absent))
(assert (! (= mark_a_requested true)
           :named mark_a_request_definition))
(assert (! (= mark_b_requested true)
           :named mark_b_request_definition))

(declare-const mark_a_stale_write_has_a Bool)
(declare-const mark_a_stale_write_has_b Bool)
(assert (! (= mark_a_stale_write_has_a
              (or initial_has_a mark_a_requested))
           :named mark_a_write_a_definition))
(assert (! (= mark_a_stale_write_has_b initial_has_b)
           :named mark_a_write_b_definition))
(declare-const mark_b_stale_write_has_a Bool)
(declare-const mark_b_stale_write_has_b Bool)
(assert (! (= mark_b_stale_write_has_a initial_has_a)
           :named mark_b_write_a_definition))
(assert (! (= mark_b_stale_write_has_b
              (or initial_has_b mark_b_requested))
           :named mark_b_write_b_definition))

(declare-const shared_mutex_or_atomic_update Bool)
(assert (! (= shared_mutex_or_atomic_update false)
           :named buggy_shared_update_disabled))

(declare-const final_has_a Bool)
(assert (! (= final_has_a
              (ite shared_mutex_or_atomic_update
                   (or initial_has_a mark_a_requested)
                   (ite (= write_order mark_a_then_b)
                        mark_b_stale_write_has_a
                        mark_a_stale_write_has_a)))
           :named final_a_definition))
(declare-const final_has_b Bool)
(assert (! (= final_has_b
              (ite shared_mutex_or_atomic_update
                   (or initial_has_b mark_b_requested)
                   (ite (= write_order mark_a_then_b)
                        mark_b_stale_write_has_b
                        mark_a_stale_write_has_b)))
           :named final_b_definition))

(declare-const both_marks_requested Bool)
(assert (! (= both_marks_requested
              (and mark_a_requested mark_b_requested))
           :named both_marks_requested_definition))
(declare-const lost_loaded_lib_mark Bool)
(assert (! (= lost_loaded_lib_mark
              (and both_marks_requested
                   (or (not final_has_a)
                       (not final_has_b))))
           :named lost_mark_definition))
(declare-const violation Bool)
(assert (! (= violation lost_loaded_lib_mark)
           :named violation_definition))

(assert (! (= write_order mark_a_then_b)
           :named witness_a_then_b_stale_writes))
(assert (! violation :named violation_query))
