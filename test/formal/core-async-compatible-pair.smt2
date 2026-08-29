; P3: bounded selector proof for ac-compatible-pair.
;
; FIFO lists contain one or two active registrations. Handler ids are 0 or 1;
; equal ids model one mixed-alts handler on both sides. Selector 0 performs the
; production nested scan; selector 1 is the head/head-only mutant. All checks
; use the same candidates, selection variables, and violation.
; Expected: unsat (reference), sat (head-only mutant), sat (boundary).
(set-logic QF_LIA)

(declare-const selector Int)
(declare-const put-count Int)
(declare-const take-count Int)
(declare-const p0 Int)
(declare-const p1 Int)
(declare-const t0 Int)
(declare-const t1 Int)
(declare-const c00 Bool)
(declare-const c01 Bool)
(declare-const c10 Bool)
(declare-const c11 Bool)
(declare-const s00 Bool)
(declare-const s01 Bool)
(declare-const s10 Bool)
(declare-const s11 Bool)
(declare-const any-compatible Bool)
(declare-const selected Bool)
(declare-const self-pair Bool)
(declare-const multiple-pairs Bool)
(declare-const selector-violation Bool)

(assert (! (or (= selector 0) (= selector 1)) :named selector-domain))
(assert (! (and (<= 1 put-count) (<= put-count 2)
                (<= 1 take-count) (<= take-count 2))
           :named fifo-list-bounds))
(assert (! (and (<= 0 p0) (<= p0 1)
                (<= 0 p1) (<= p1 1)
                (<= 0 t0) (<= t0 1)
                (<= 0 t1) (<= t1 1))
           :named handler-id-domain))

(assert (! (= c00 (not (= p0 t0))) :named candidate-00))
(assert (! (= c01 (and (= take-count 2) (not (= p0 t1))))
           :named candidate-01))
(assert (! (= c10 (and (= put-count 2) (not (= p1 t0))))
           :named candidate-10))
(assert (! (= c11 (and (= put-count 2) (= take-count 2)
                       (not (= p1 t1))))
           :named candidate-11))
(assert (! (= any-compatible (or c00 c01 c10 c11))
           :named compatible-exists))

; Production selects the first candidate in nested FIFO order. The mutant only
; admits c00; all later selection variables remain false.
(assert (! (= s00 c00) :named selected-00))
(assert (! (= s01 (and (= selector 0) c01 (not c00)))
           :named selected-01))
(assert (! (= s10 (and (= selector 0) c10 (not (or c00 c01))))
           :named selected-10))
(assert (! (= s11 (and (= selector 0) c11 (not (or c00 c01 c10))))
           :named selected-11))
(assert (! (= selected (or s00 s01 s10 s11))
           :named selected-definition))
(assert (! (= self-pair
              (or (and s00 (= p0 t0))
                  (and s01 (= p0 t1))
                  (and s10 (= p1 t0))
                  (and s11 (= p1 t1))))
           :named self-pair-definition))
(assert (! (= multiple-pairs
              (or (and s00 (or s01 s10 s11))
                  (and s01 (or s10 s11))
                  (and s10 s11)))
           :named multiple-pairs-definition))
(assert (! (= selector-violation
              (or (and any-compatible (not selected))
                  self-pair
                  multiple-pairs))
           :named shared-selector-violation))

(push)
(assert (= selector 0))
(assert any-compatible)
(assert (! selector-violation :named reference-selector-counterexample))
(check-sat)
(pop)

; Known-SAT mutation: p0/t0 is self-incompatible; compatible p1/t0 is hidden.
(push)
(assert (= selector 1))
(assert (= put-count 2))
(assert (= take-count 1))
(assert (= p0 0))
(assert (= p1 1))
(assert (= t0 0))
(assert (! selector-violation :named head-only-mutant-witness))
(check-sat)
(pop)

; Boundary: production skips p0/t0 and selects p1/t0.
(push)
(assert (= selector 0))
(assert (= put-count 2))
(assert (= take-count 1))
(assert (= p0 0))
(assert (= p1 1))
(assert (= t0 0))
(assert s10)
(assert (not selector-violation))
(check-sat)
(pop)
