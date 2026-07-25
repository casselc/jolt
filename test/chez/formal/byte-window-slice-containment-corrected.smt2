; Bounded counterexample query for an immutable byte Window slice.
;
; Domain:
;   backing capacity, parent offset, parent length, and relative slice bounds
;   are integers from 0 through 16.
;
; A SAT result would be a valid parent and valid relative half-open slice whose
; corrected child descriptor is negative, escapes its parent, or escapes the
; backing capacity. UNSAT means no such counterexample exists in this domain.

(declare-const capacity Int)
(declare-const parent_offset Int)
(declare-const parent_length Int)
(declare-const start Int)
(declare-const end Int)

(assert (! (and (<= 0 capacity) (<= capacity 16))
           :named capacity_domain))
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
           :named corrected_child_offset))
(assert (! (= child_length (- end start))
           :named corrected_child_length))

(declare-const violation Bool)
(assert (! (= violation
              (or (< child_offset parent_offset)
                  (< child_length 0)
                  (> (+ child_offset child_length)
                     (+ parent_offset parent_length))
                  (> (+ child_offset child_length) capacity)))
           :named containment_violation_definition))
(assert (! violation :named containment_counterexample_query))
