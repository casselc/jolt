; P1: bounded ownership proof for alt-claim-pair!.
;
; Domain and abstraction:
; - exactly two distinct handlers A and B, both initially active;
; - owner 0 = active/unclaimed, 1 = this rendezvous pair, 2 = competitor;
; - implementation 0 acquires both handler locks before either commit;
; - implementation 1 claims A before acquiring B, exposing one interleaving;
; - the competitor attempts B between those two acquisition points.
;
; All three checks use the same transition and partial-ownership violation.
; Expected: unsat (atomic reference), sat (sequential mutant), sat (boundary).
(set-logic QF_LIA)

(declare-const implementation Int)
(declare-const id-a Int)
(declare-const id-b Int)
(declare-const pre-a Int)
(declare-const pre-b Int)
(declare-const lock-a-held-at-interleave Bool)
(declare-const lock-b-held-at-interleave Bool)
(declare-const competitor-attempts-b Bool)
(declare-const competitor-owns-b Bool)
(declare-const pair-owns-a Bool)
(declare-const pair-owns-b Bool)
(declare-const pair-success Bool)
(declare-const post-a Int)
(declare-const post-b Int)
(declare-const ownership-violation Bool)

(assert (! (or (= implementation 0) (= implementation 1))
           :named implementation-domain))
(assert (! (< id-a id-b) :named stable-distinct-lock-order))
(assert (! (= pre-a 0) :named handler-a-initially-active))
(assert (! (= pre-b 0) :named handler-b-initially-active))

; Both implementations hold A at the modeled interleaving point. The atomic
; implementation already holds B; the sequential mutant has not acquired it.
(assert (! (= lock-a-held-at-interleave true) :named pair-holds-a))
(assert (! (= lock-b-held-at-interleave (= implementation 0))
           :named atomic-pair-holds-b))
(assert (! (= competitor-attempts-b true)
           :named competitor-scheduled-between-claims))
(assert (! (= competitor-owns-b
              (and competitor-attempts-b
                   (not lock-b-held-at-interleave)
                   (= pre-b 0)))
           :named competitor-transition))

; Atomic: ownership changes only if both pre-states are active.
; Sequential mutant: A changes first; B changes only if the competitor did not.
(assert (! (= pair-owns-a
              (ite (= implementation 0)
                   (and (= pre-a 0) (= pre-b 0))
                   (= pre-a 0)))
           :named pair-transition-a))
(assert (! (= pair-owns-b
              (ite (= implementation 0)
                   (and (= pre-a 0) (= pre-b 0))
                   (and (= pre-b 0) (not competitor-owns-b))))
           :named pair-transition-b))
(assert (! (= pair-success (and pair-owns-a pair-owns-b))
           :named pair-success-definition))
(assert (! (= post-a (ite pair-owns-a 1 pre-a)) :named post-owner-a))
(assert (! (= post-b
              (ite pair-owns-b 1 (ite competitor-owns-b 2 pre-b)))
           :named post-owner-b))

; A rendezvous pair may own both handlers or neither, never exactly one.
(assert (! (= ownership-violation (xor (= post-a 1) (= post-b 1)))
           :named shared-ownership-violation))

(push)
(assert (= implementation 0))
(assert (! ownership-violation :named atomic-reference-counterexample))
(check-sat)
(pop)

; Known-SAT mutation: A belongs to the pair while the competitor owns B.
(push)
(assert (= implementation 1))
(assert (! ownership-violation :named sequential-mutant-witness))
(check-sat)
(pop)

; Boundary/non-vacuity: atomic locking excludes the competitor and claims both.
(push)
(assert (= implementation 0))
(assert pair-success)
(assert (= post-a 1))
(assert (= post-b 1))
(assert (not ownership-violation))
(check-sat)
(pop)
