; Non-vacuity control for corrected byte Window slicing.
;
; The inclusive maximum capacity and a full-window slice must remain
; reachable. SAT with valid=true demonstrates that the corrected constraints
; did not make all useful slices impossible.

(declare-const capacity Int)
(declare-const parent_offset Int)
(declare-const parent_length Int)
(declare-const start Int)
(declare-const end Int)
(declare-const child_offset Int)
(declare-const child_length Int)

(assert (! (= capacity 16) :named maximum_capacity))
(assert (! (= parent_offset 0) :named full_parent_offset))
(assert (! (= parent_length 16) :named full_parent_length))
(assert (! (= start 0) :named full_slice_start))
(assert (! (= end 16) :named full_slice_end))
(assert (! (= child_offset (+ parent_offset start))
           :named corrected_child_offset))
(assert (! (= child_length (- end start))
           :named corrected_child_length))

(declare-const valid Bool)
(assert (! (= valid
              (and (<= 0 parent_offset)
                   (<= (+ parent_offset parent_length) capacity)
                   (<= 0 start)
                   (<= start end)
                   (<= end parent_length)
                   (= child_offset parent_offset)
                   (= child_length parent_length)))
           :named full_window_validity))
(assert (! valid :named nonvacuity_query))
