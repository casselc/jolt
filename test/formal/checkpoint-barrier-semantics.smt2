; Bounded exact-actor checkpoint-barrier semantics.
;
; Live-source facts modeled from host/chez/checkpoints.ss:
; - checkpoint-preallocate-rounds constructs generation-owned rounds and the
;   selector/actor indexes before publication (lines 352-378).
; - checkpoint-record-commit! publishes the event and immutable decision before
;   checkpoint-dispatch! can enter a barrier.
; - checkpoint-round-await! records actors by identity, makes a retake
;   idempotent, and releases on the final unique arrival.
; - checkpoint-round-break! changes only pending to broken and wakes waiters;
;   reset and cancel apply that operation to every selected round.
; - fault dispatch does not touch a round.
; - reset clock closure and barrier arrival share a generation terminal
;   arbiter. Reset publishes fresh only after closure, while an already
;   committed decision retains its preallocated old round and observes closure
;   before it may record an arrival or release that round.
;
; Domain: two actors {A=0,B=1}, two distinct preallocated rounds {0,1},
; generations {old=0,fresh=1}, and ten one-operation scenarios {0..9}.
; Arrival sets are two-bit masks.  The model checks direct transitions and
; bounded one-operation effects; it omits scheduler fairness, mutex/CV
; implementation, exception payloads, manifests, and arbitrary-length traces.
;
; Scenarios: 0 first A arrival in round 0; 1 A retake; 2 final B arrival in
; round 0; 3 reset with both rounds pending; 4 cancel affecting both pending
; rounds; 5 fault; 6 old decision retaken after reset; 7 final B arrival in
; round 1; 8 retake of an already released round; 9 final B decision committed
; before reset but dispatched only after the old generation clock is closed.
;
; Implementations: 0 reference; 1 loses generation ownership/preallocation;
; 2 arrives before event publication; 3 counts a duplicate actor; 4 releases
; twice; 5 changes released to broken; 6 both releases and breaks; 7 reset
; misses one pending round/waiter; 8 cancel misses one affected round/waiter;
; 9 fault breaks a round; 10 an old decision targets/mutates the fresh round;
; 11 ignores clock closure and releases from a delayed final arrival.
; Expected checks: one reference UNSAT, eleven mutant SAT, eight non-vacuity SAT.
(set-logic ALL)

(declare-datatypes ((RoundState 0)) (((pending) (released) (broken))))

(declare-const implementation Int)
(declare-const scenario Int)

; Static preallocation and generation ownership.
(declare-const old-round-count Int)
(declare-const fresh-round-count Int)
(declare-const round0-id Int)
(declare-const round1-id Int)
(declare-const round0-owner Int)
(declare-const round1-owner Int)
(declare-const fresh-round0-owner Int)
(declare-const fresh-round1-owner Int)
(declare-const decision-round-id Int)
(declare-const decision-round-owner Int)

; The bounded operation and its two old-generation rounds.
(declare-const is-arrival Bool)
(declare-const arrival-round Int)
(declare-const arrival-actor Int)
(declare-const event-order Int)
(declare-const arrival-order Int)
(declare-const r0-before RoundState)
(declare-const r1-before RoundState)
(declare-const r0-after RoundState)
(declare-const r1-after RoundState)
(declare-const r0-mask-before Int)
(declare-const r1-mask-before Int)
(declare-const r0-mask-after Int)
(declare-const r1-mask-after Int)
(declare-const unique-before Int)
(declare-const unique-after Int)
(declare-const release-count Int)
(declare-const break-count Int)
(declare-const wake-r0 Bool)
(declare-const wake-r1 Bool)

; A reset-published generation starts independently and is not reachable
; through an old committed decision.
(declare-const fresh-r0-state RoundState)
(declare-const fresh-r1-state RoundState)
(declare-const fresh-r0-mask Int)
(declare-const fresh-r1-mask Int)

; Scenario classifications.
(declare-const does-reset Bool)
(declare-const does-cancel Bool)
(declare-const does-fault Bool)
(declare-const stale-retake Bool)
(declare-const close-before-arrival Bool)
(declare-const affects-r0 Bool)
(declare-const affects-r1 Bool)

; Shared, bi-directionally defined violation components.
(declare-const preallocation-violation Bool)
(declare-const event-order-violation Bool)
(declare-const unique-arrival-violation Bool)
(declare-const final-release-violation Bool)
(declare-const transition-violation Bool)
(declare-const exclusive-terminal-violation Bool)
(declare-const reset-break-violation Bool)
(declare-const cancel-break-violation Bool)
(declare-const fault-effect-violation Bool)
(declare-const stale-generation-violation Bool)
(declare-const closed-clock-arrival-violation Bool)
(declare-const checkpoint-barrier-violation Bool)

(assert (! (and (<= 0 implementation) (<= implementation 11))
  :named twelve-implementation-domain))
(assert (! (and (<= 0 scenario) (<= scenario 9))
  :named ten-scenario-bound))
(assert (! (and (<= 0 r0-mask-before) (<= r0-mask-before 3)
                (<= 0 r1-mask-before) (<= r1-mask-before 3)
                (<= 0 r0-mask-after) (<= r0-mask-after 3)
                (<= 0 r1-mask-after) (<= r1-mask-after 3)
                (<= 0 fresh-r0-mask) (<= fresh-r0-mask 3)
                (<= 0 fresh-r1-mask) (<= fresh-r1-mask 3))
  :named two-actor-arrival-mask-domain))

; Exactly two distinct rounds are preallocated for each generation.  Mutant 1
; aliases round 1 to the fresh generation, violating old-generation ownership.
(assert (= old-round-count 2))
(assert (= fresh-round-count 2))
(assert (= round0-id 0))
(assert (= round1-id 1))
(assert (= round0-owner 0))
(assert (= round1-owner (ite (= implementation 1) 1 0)))
(assert (= fresh-round0-owner 1))
(assert (= fresh-round1-owner 1))
(assert (= decision-round-id 0))
(assert (= decision-round-owner
  (ite (and (= implementation 10) (= scenario 6)) 1 0)))
(assert (! (= preallocation-violation
  (or (not (= old-round-count 2))
      (not (= fresh-round-count 2))
      (= round0-id round1-id)
      (not (= round0-owner 0))
      (not (= round1-owner 0))
      (not (= fresh-round0-owner 1))
      (not (= fresh-round1-owner 1))))
  :named two-preallocated-generation-owned-rounds))

; Scenario classification and canonical pre-state.
(assert (= is-arrival (or (= scenario 0) (= scenario 1) (= scenario 2)
                          (= scenario 7) (= scenario 9))))
(assert (= arrival-round (ite (= scenario 7) 1 0)))
(assert (= arrival-actor
  (ite (or (= scenario 2) (= scenario 7) (= scenario 9)) 1 0)))
(assert (= does-reset (= scenario 3)))
(assert (= does-cancel (= scenario 4)))
(assert (= does-fault (= scenario 5)))
(assert (= stale-retake (= scenario 6)))
(assert (= close-before-arrival (= scenario 9)))
(assert (= affects-r0 (or does-reset does-cancel)))
(assert (= affects-r1 (or does-reset does-cancel)))

(assert (= r0-before
  (ite (= scenario 8) released
    (ite (= scenario 6) broken pending))))
(assert (= r1-before pending))
(assert (= r0-mask-before
  (ite (or (= scenario 1) (= scenario 2) (= scenario 3) (= scenario 4)
           (= scenario 5) (= scenario 6) (= scenario 9))
       1
    (ite (= scenario 8) 3 0))))
(assert (= r1-mask-before (ite (= scenario 7) 1 0)))

; Event publication precedes every first barrier-arrival attempt.  Mutant 2
; reverses that order in scenario 0.
(assert (= event-order (ite is-arrival 1 0)))
(assert (= arrival-order
  (ite is-arrival
       (ite (and (= implementation 2) (= scenario 0)) 0 2)
       0)))
(assert (! (= event-order-violation
  (and is-arrival (not (< event-order arrival-order))))
  :named event-before-arrival))

; Unique-arrival cardinality is derived from actor membership.  Scenarios 0/7
; add a missing actor, scenario 1 retakes A idempotently, and scenario 2 adds B.
(assert (= unique-before
  (ite (= arrival-round 0)
       (ite (or (= r0-mask-before 0)) 0
         (ite (= r0-mask-before 3) 2 1))
       (ite (= r1-mask-before 0) 0
         (ite (= r1-mask-before 3) 2 1)))))
(assert (= unique-after
  (ite is-arrival
       (ite (and close-before-arrival (not (= implementation 11)))
            unique-before
         (ite (and (= implementation 3) (= scenario 1)) 2
         (ite (and (= arrival-actor 0)
                   (or (= (ite (= arrival-round 0) r0-mask-before r1-mask-before) 1)
                       (= (ite (= arrival-round 0) r0-mask-before r1-mask-before) 3)))
              unique-before
           (ite (and (= arrival-actor 1)
                     (or (= (ite (= arrival-round 0) r0-mask-before r1-mask-before) 2)
                         (= (ite (= arrival-round 0) r0-mask-before r1-mask-before) 3)))
                unique-before
                (+ unique-before 1)))))
       unique-before)))

; Arrival masks are the observable identity set.  Mutant 3 falsely adds B on
; A's retake, matching its incorrect cardinality of two.
(assert (= r0-mask-after
  (ite (= scenario 0) 1
    (ite (= scenario 1) (ite (= implementation 3) 3 1)
      (ite (= scenario 2) 3
        (ite (= scenario 9) (ite (= implementation 11) 3 1)
        (ite (or (= scenario 3) (= scenario 4) (= scenario 5)
                 (= scenario 6) (= scenario 8))
             r0-mask-before
             0)))))))
(assert (= r1-mask-after (ite (= scenario 7) 3 r1-mask-before)))
(assert (! (= unique-arrival-violation
  (or (and (= scenario 0) (not (and (= unique-after 1) (= r0-mask-after 1))))
      (and (= scenario 1) (not (and (= unique-after 1) (= r0-mask-after 1))))
      (and (= scenario 2) (not (and (= unique-after 2) (= r0-mask-after 3))))
      (and (= scenario 7) (not (and (= unique-after 2) (= r1-mask-after 3))))))
  :named unique-actor-arrival-and-idempotent-retake))

; Reference terminal effects. Final unique arrival releases exactly once;
; reset/cancel break both affected pending rounds exactly once; all other
; operations have no terminal effect. Mutants selectively perturb these facts.
(assert (= release-count
  (ite (or (= scenario 2) (= scenario 7)
           (and (= implementation 11) close-before-arrival))
       (ite (and (= implementation 4) (= scenario 2)) 2 1)
       0)))
(assert (= break-count
  (ite (or does-reset does-cancel) 2
    (ite close-before-arrival
         (ite (= implementation 11) 0 1)
    (ite (and (= implementation 6) (= scenario 2)) 1
      (ite (and (= implementation 9) does-fault) 1 0))))))

(assert (= r0-after
  (ite close-before-arrival
       (ite (= implementation 11) released broken)
    (ite (= scenario 2) released
    (ite (= scenario 3) broken
      (ite (= scenario 4) broken
        (ite (and (= implementation 9) does-fault) broken
          (ite (= scenario 8)
               (ite (= implementation 5) broken released)
               r0-before))))))))
(assert (= r1-after
  (ite (= scenario 7) released
    (ite (= scenario 3) (ite (= implementation 7) pending broken)
      (ite (= scenario 4) (ite (= implementation 8) pending broken)
           r1-before)))))

(assert (= wake-r0 (or does-reset does-cancel close-before-arrival
                            (and (= implementation 9) does-fault))))
(assert (= wake-r1
  (or (and does-reset (not (= implementation 7)))
      (and does-cancel (not (= implementation 8))))))

(assert (! (= final-release-violation
  (or (and (= scenario 2)
           (not (and (= unique-after 2) (= release-count 1)
                     (= r0-after released))))
      (and (= scenario 7)
           (not (and (= unique-after 2) (= release-count 1)
                     (= r1-after released))))
      (and (or (= scenario 0) (= scenario 1))
           (not (and (= release-count 0) (= r0-after pending))))))
  :named final-unique-arrival-releases-once))

; Only pending may transition to released/broken; terminal rounds are stable.
(assert (! (= transition-violation
  (or (and (= r0-before released) (not (= r0-after released)))
      (and (= r0-before broken) (not (= r0-after broken)))
      (and (= r1-before released) (not (= r1-after released)))
      (and (= r1-before broken) (not (= r1-after broken)))))
  :named pending-only-terminal-transitions))
(assert (! (= exclusive-terminal-violation
  (and (> release-count 0) (> break-count 0)))
  :named release-and-break-mutually-exclusive))

(assert (! (= reset-break-violation
  (and does-reset
       (not (and (= r0-after broken) (= r1-after broken)
                 (= break-count 2) wake-r0 wake-r1))))
  :named reset-breaks-every-pending-round-and-wakes))
(assert (! (= cancel-break-violation
  (and does-cancel
       (not (and (= r0-after broken) (= r1-after broken)
                 (= break-count 2) wake-r0 wake-r1))))
  :named cancel-breaks-every-affected-pending-round-and-wakes))
(assert (! (= fault-effect-violation
  (and does-fault
       (not (and (= r0-after r0-before) (= r1-after r1-before)
                 (= r0-mask-after r0-mask-before)
                 (= r1-mask-after r1-mask-before)
                 (= release-count 0) (= break-count 0)
                 (not wake-r0) (not wake-r1)))))
  :named fault-has-no-barrier-effect))

; The fresh generation remains empty/pending. Mutant 10 redirects the retained
; old decision and records an arrival in fresh round 0.
(assert (= fresh-r0-state pending))
(assert (= fresh-r1-state pending))
(assert (= fresh-r0-mask
  (ite (and (= implementation 10) stale-retake) 1 0)))
(assert (= fresh-r1-mask 0))
(assert (! (= stale-generation-violation
  (and stale-retake
       (not (and (= decision-round-id 0) (= decision-round-owner 0)
                 (= r0-after broken) (= r0-mask-after r0-mask-before)
                 (= fresh-r0-state pending) (= fresh-r1-state pending)
                 (= fresh-r0-mask 0) (= fresh-r1-mask 0)))))
  :named old-decision-retains-old-round-and-cannot-mutate-fresh-generation))

; Once reset closes the old clock, a retained but not-yet-dispatched final
; decision must break the old pending round before recording its actor. Mutant
; 11 omits that closed-clock arbitration and incorrectly releases the quorum.
(assert (! (= closed-clock-arrival-violation
  (and close-before-arrival
       (not (and (= r0-before pending) (= r0-mask-before 1)
                 (= r0-after broken) (= r0-mask-after 1)
                 (= unique-after 1) (= release-count 0) (= break-count 1)
                 wake-r0
                 (= fresh-r0-state pending) (= fresh-r0-mask 0)))))
  :named closed-clock-arrival-breaks-before-release))

; One shared counterexample predicate is used by the reference and every mutant.
(assert (! (= checkpoint-barrier-violation
  (or preallocation-violation
      event-order-violation
      unique-arrival-violation
      final-release-violation
      transition-violation
      exclusive-terminal-violation
      reset-break-violation
      cancel-break-violation
      fault-effect-violation
      stale-generation-violation
      closed-clock-arrival-violation))
  :named shared-checkpoint-barrier-violation))

; Reference: no bounded counterexample exists.
(push)
(assert (! (= implementation 0) :named reference-implementation))
(assert (! checkpoint-barrier-violation
  :named reference-checkpoint-barrier-counterexample-query))
(check-sat)
(pop)

; Known-SAT semantic mutations, all through the same violation query.
(push)
(assert (= implementation 1)) (assert (= scenario 0))
(assert (! checkpoint-barrier-violation :named generation-ownership-mutant-query))
(check-sat) (pop)
(push)
(assert (= implementation 2)) (assert (= scenario 0))
(assert (! checkpoint-barrier-violation :named arrival-before-event-mutant-query))
(check-sat) (pop)
(push)
(assert (= implementation 3)) (assert (= scenario 1))
(assert (! checkpoint-barrier-violation :named duplicate-arrival-mutant-query))
(check-sat) (pop)
(push)
(assert (= implementation 4)) (assert (= scenario 2))
(assert (! checkpoint-barrier-violation :named multiple-release-mutant-query))
(check-sat) (pop)
(push)
(assert (= implementation 5)) (assert (= scenario 8))
(assert (! checkpoint-barrier-violation :named terminal-rewrite-mutant-query))
(check-sat) (pop)
(push)
(assert (= implementation 6)) (assert (= scenario 2))
(assert (! checkpoint-barrier-violation :named release-and-break-mutant-query))
(check-sat) (pop)
(push)
(assert (= implementation 7)) (assert (= scenario 3))
(assert (! checkpoint-barrier-violation :named incomplete-reset-mutant-query))
(check-sat) (pop)
(push)
(assert (= implementation 8)) (assert (= scenario 4))
(assert (! checkpoint-barrier-violation :named incomplete-cancel-mutant-query))
(check-sat) (pop)
(push)
(assert (= implementation 9)) (assert (= scenario 5))
(assert (! checkpoint-barrier-violation :named fault-effects-mutant-query))
(check-sat) (pop)
(push)
(assert (= implementation 10)) (assert (= scenario 6))
(assert (! checkpoint-barrier-violation :named stale-fresh-mutation-mutant-query))
(check-sat) (pop)
(push)
(assert (= implementation 11)) (assert (= scenario 9))
(assert (! checkpoint-barrier-violation :named closed-clock-release-mutant-query))
(check-sat) (pop)

; Non-vacuity: valid executions remain reachable without asserting a violation.
(push)
(assert (= implementation 0)) (assert (= scenario 1))
(assert (! (and (= unique-before 1) (= unique-after 1)
                (= r0-mask-after 1) (= release-count 0))
  :named idempotent-retake-nonvacuity-query))
(check-sat) (pop)
(push)
(assert (= implementation 0)) (assert (= scenario 2))
(assert (! (and (= r0-after released) (= release-count 1) (= break-count 0))
  :named round0-release-nonvacuity-query))
(check-sat) (pop)
(push)
(assert (= implementation 0)) (assert (= scenario 7))
(assert (! (and (= r1-after released) (= release-count 1) (= r0-after pending))
  :named round1-isolation-nonvacuity-query))
(check-sat) (pop)
(push)
(assert (= implementation 0)) (assert (= scenario 3))
(assert (! (and (= r0-after broken) (= r1-after broken) wake-r0 wake-r1)
  :named reset-break-nonvacuity-query))
(check-sat) (pop)
(push)
(assert (= implementation 0)) (assert (= scenario 4))
(assert (! (and (= r0-after broken) (= r1-after broken) wake-r0 wake-r1)
  :named cancel-break-nonvacuity-query))
(check-sat) (pop)
(push)
(assert (= implementation 0)) (assert (= scenario 5))
(assert (! (and (= r0-after pending) (= r0-mask-after 1)
                (= break-count 0) (not wake-r0))
  :named fault-no-effect-nonvacuity-query))
(check-sat) (pop)
(push)
(assert (= implementation 0)) (assert (= scenario 6))
(assert (! (and (= decision-round-owner 0) (= r0-after broken)
                (= fresh-r0-state pending) (= fresh-r0-mask 0))
  :named stale-old-round-nonvacuity-query))
(check-sat) (pop)
(push)
(assert (= implementation 0)) (assert (= scenario 9))
(assert (! (and (= r0-after broken) (= r0-mask-after 1)
                (= release-count 0) (= break-count 1) wake-r0
                (= fresh-r0-state pending) (= fresh-r0-mask 0))
  :named closed-clock-arrival-nonvacuity-query))
(check-sat) (pop)
