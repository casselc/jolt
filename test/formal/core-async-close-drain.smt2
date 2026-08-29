; P2: bounded public-close ownership, drain liveness, and xrf completion events.
;
; Implementation 0 is the reference, 1 drops pending puts at close, and 2 emits
; duplicate xrf completion events. Capacity is 0 or 1; q0 is buffered data and
; p0 is one or two active admitted puts. Three scheduled takes suffice to drain
; q0+p0 <= 3. Reducer abort and inactive alts registrations are out of scope.
; sN counts pending inputs stepped; eN counts completion invocations.
;
; All checks use the same transition and violation. Expected: unsat (reference),
; sat (drop mutant), sat (duplicate-completion mutant), sat (boundary).
(set-logic QF_LIA)

(declare-const implementation Int)
(declare-const cap Int)
(declare-const q0 Int)
(declare-const p0 Int)
(declare-const q1 Int)
(declare-const p1 Int)
(declare-const d1 Int)
(declare-const s1 Int)
(declare-const e1 Int)
(declare-const q2-pre Int)
(declare-const p2-pre Int)
(declare-const q2 Int)
(declare-const p2 Int)
(declare-const d2 Int)
(declare-const s2 Int)
(declare-const e2 Int)
(declare-const q3-pre Int)
(declare-const p3-pre Int)
(declare-const q3 Int)
(declare-const p3 Int)
(declare-const d3 Int)
(declare-const s3 Int)
(declare-const e3 Int)
(declare-const q4-pre Int)
(declare-const p4-pre Int)
(declare-const q4 Int)
(declare-const p4 Int)
(declare-const d4 Int)
(declare-const s4 Int)
(declare-const e4 Int)
(declare-const close-drain-violation Bool)

(assert (! (and (<= 0 implementation) (<= implementation 2))
           :named implementation-domain))
(assert (! (or (= cap 0) (= cap 1)) :named capacity-domain))
(assert (! (and (<= 0 q0) (<= q0 cap)) :named initial-queue-domain))
(assert (! (and (<= 1 p0) (<= p0 2)) :named initial-pending-domain))

; Public close performs one notification pass. Reference/duplicate modes promote
; one pending input when a capacity-one channel has room. The drop mutant clears
; pending ownership without stepping it.
(assert (! (= q1
              (ite (= implementation 1)
                   q0
                   (ite (and (= cap 1) (< q0 cap) (> p0 0))
                        (+ q0 1)
                        q0)))
           :named close-queue-transition))
(assert (! (= p1
              (ite (= implementation 1)
                   0
                   (ite (and (= cap 1) (< q0 cap) (> p0 0))
                        (- p0 1)
                        p0)))
           :named close-pending-transition))
(assert (! (= d1 0) :named close-delivery-count))
(assert (! (= s1 (ite (= implementation 1) 0 (- p0 p1)))
           :named close-step-count))
(assert (! (= e1
              (ite (= p1 0) (ite (= implementation 2) 2 1) 0))
           :named close-completion-events))

; Take 1 consumes q first, otherwise one pending value directly. Capacity one
; then promotes one remaining pending value into the free slot.
(assert (! (= d2 (+ d1 (ite (or (> q1 0) (> p1 0)) 1 0)))
           :named take-1-delivery))
(assert (! (= q2-pre (ite (> q1 0) (- q1 1) q1))
           :named take-1-queue-before-promotion))
(assert (! (= p2-pre
              (ite (> q1 0) p1 (ite (> p1 0) (- p1 1) p1)))
           :named take-1-pending-before-promotion))
(assert (! (= q2
              (ite (and (= cap 1) (< q2-pre cap) (> p2-pre 0))
                   (+ q2-pre 1)
                   q2-pre))
           :named take-1-queue-after-promotion))
(assert (! (= p2
              (ite (and (= cap 1) (< q2-pre cap) (> p2-pre 0))
                   (- p2-pre 1)
                   p2-pre))
           :named take-1-pending-after-promotion))
(assert (! (= s2 (+ s1 (- p1 p2))) :named take-1-step-count))
(assert (! (= e2
              (ite (and (= e1 0) (= p2 0))
                   (ite (= implementation 2) 2 1)
                   e1))
           :named take-1-completion-events))

; Take 2.
(assert (! (= d3 (+ d2 (ite (or (> q2 0) (> p2 0)) 1 0)))
           :named take-2-delivery))
(assert (! (= q3-pre (ite (> q2 0) (- q2 1) q2))
           :named take-2-queue-before-promotion))
(assert (! (= p3-pre
              (ite (> q2 0) p2 (ite (> p2 0) (- p2 1) p2)))
           :named take-2-pending-before-promotion))
(assert (! (= q3
              (ite (and (= cap 1) (< q3-pre cap) (> p3-pre 0))
                   (+ q3-pre 1)
                   q3-pre))
           :named take-2-queue-after-promotion))
(assert (! (= p3
              (ite (and (= cap 1) (< q3-pre cap) (> p3-pre 0))
                   (- p3-pre 1)
                   p3-pre))
           :named take-2-pending-after-promotion))
(assert (! (= s3 (+ s2 (- p2 p3))) :named take-2-step-count))
(assert (! (= e3
              (ite (and (= e2 0) (= p3 0))
                   (ite (= implementation 2) 2 1)
                   e2))
           :named take-2-completion-events))

; Take 3.
(assert (! (= d4 (+ d3 (ite (or (> q3 0) (> p3 0)) 1 0)))
           :named take-3-delivery))
(assert (! (= q4-pre (ite (> q3 0) (- q3 1) q3))
           :named take-3-queue-before-promotion))
(assert (! (= p4-pre
              (ite (> q3 0) p3 (ite (> p3 0) (- p3 1) p3)))
           :named take-3-pending-before-promotion))
(assert (! (= q4
              (ite (and (= cap 1) (< q4-pre cap) (> p4-pre 0))
                   (+ q4-pre 1)
                   q4-pre))
           :named take-3-queue-after-promotion))
(assert (! (= p4
              (ite (and (= cap 1) (< q4-pre cap) (> p4-pre 0))
                   (- p4-pre 1)
                   p4-pre))
           :named take-3-pending-after-promotion))
(assert (! (= s4 (+ s3 (- p3 p4))) :named take-3-step-count))
(assert (! (= e4
              (ite (and (= e3 0) (= p4 0))
                   (ite (= implementation 2) 2 1)
                   e3))
           :named take-3-completion-events))

; Conservation detects dropped ownership. Completion may occur only after every
; admitted pending input stepped, and exactly one completion event must be seen.
(assert (! (= close-drain-violation
              (or (not (= (+ d1 q1 p1) (+ q0 p0)))
                  (not (= (+ d2 q2 p2) (+ q0 p0)))
                  (not (= (+ d3 q3 p3) (+ q0 p0)))
                  (not (= (+ d4 q4 p4) (+ q0 p0)))
                  (and (> e1 0) (< s1 p0))
                  (and (> e2 0) (< s2 p0))
                  (and (> e3 0) (< s3 p0))
                  (and (> e4 0) (< s4 p0))
                  (> e1 1) (> e2 1) (> e3 1) (> e4 1)
                  (not (= d4 (+ q0 p0)))
                  (not (= q4 0))
                  (not (= p4 0))
                  (not (= s4 p0))
                  (not (= e4 1))))
           :named shared-close-drain-violation))

(push)
(assert (= implementation 0))
(assert (! close-drain-violation :named reference-close-counterexample))
(check-sat)
(pop)

; Known-SAT mutation: close drops an admitted input without stepping it.
(push)
(assert (= implementation 1))
(assert (= cap 1))
(assert (= q0 0))
(assert (= p0 1))
(assert (! close-drain-violation :named drop-pending-mutant-witness))
(check-sat)
(pop)

; Known-SAT mutation: completion emits twice when pending becomes empty.
(push)
(assert (= implementation 2))
(assert (= cap 0))
(assert (= q0 0))
(assert (= p0 1))
(assert (! close-drain-violation :named duplicate-completion-mutant-witness))
(check-sat)
(pop)

; Maximum boundary: one buffered plus two pending values drain in three takes;
; both pending inputs step and exactly one completion event is observed.
(push)
(assert (= implementation 0))
(assert (= cap 1))
(assert (= q0 1))
(assert (= p0 2))
(assert (= d4 3))
(assert (= q4 0))
(assert (= p4 0))
(assert (= s4 2))
(assert (= e4 1))
(assert (not close-drain-violation))
(check-sat)
(pop)
