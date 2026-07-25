; Buggy control for byte Window slicing.
;
; The defect stores the relative end as the child length instead of end-start.
; The pinned valid witness is parent [0,1), empty tail slice [1,1). The buggy
; result is child [1,2), which escapes both its parent and capacity.

(declare-const capacity Int)
(declare-const parent_offset Int)
(declare-const parent_length Int)
(declare-const start Int)
(declare-const end Int)

(assert (! (= capacity 1) :named witness_capacity))
(assert (! (= parent_offset 0) :named witness_parent_offset))
(assert (! (= parent_length 1) :named witness_parent_length))
(assert (! (= start 1) :named witness_slice_start))
(assert (! (= end 1) :named witness_slice_end))

(assert (! (and (<= 0 parent_offset)
                (<= 0 parent_length)
                (<= (+ parent_offset parent_length) capacity))
           :named valid_parent))
(assert (! (and (<= 0 start)
                (<= start end)
                (<= end parent_length))
           :named valid_relative_slice))

(declare-const child_offset Int)
(declare-const child_length Int)
(assert (! (= child_offset (+ parent_offset start))
           :named child_offset_definition))
(assert (! (= child_length end)
           :named buggy_child_length))

(declare-const violation Bool)
(assert (! (= violation
              (or (< child_offset parent_offset)
                  (< child_length 0)
                  (> (+ child_offset child_length)
                     (+ parent_offset parent_length))
                  (> (+ child_offset child_length) capacity)))
           :named containment_violation_definition))
(assert (! violation :named expected_bug_witness))
