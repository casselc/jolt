; Bounded P4-style reservation/publication machine for checkpoint issue #54.
;
; The model isolates the current recorder data plane from the controller's
; public-call model. A reserved token carries its designated driver, site id,
; exact binding instance and epoch, reset generation, and recorder owner. The
; driver identity is checked against the immutable token immediately before
; taking the recorder lock. Under that lock the exact current binding and
; generation are revalidated, then hit/action assignment, CAS allocation on
; immutable generation state (open?,cut,next-seq), hit update, and append
; publication occur atomically. Reset CAS-closes the old generation before it
; publishes a new one; a later old-generation allocation therefore returns
; stale, while an allocation winner is ordered before reset. Snapshot CAS
; returns the prior cut/next pair and increments cut only before capture.
;
; Scenarios: 0 unbind/rebind invalidation, 1 duplicate commit, 2 allocation /
; append interleaving with snapshot, 3 reset-before-allocation from another
; context, 4 allocation winner ordered before reset.
; Implementations: 0 reference, 1 missing exact binding-instance check,
; 2 double commit, 3 split allocation/append snapshot, 4 caller-only reset.
; Expected: unsat sat sat sat sat sat sat sat.
(set-logic QF_LIA)

(declare-const implementation Int)
(declare-const scenario Int)
(declare-const history-step-count Int)
(declare-const reset-context Int)

; Token and live binding identity.
(declare-const token-phase-before Int)
(declare-const token-phase-after Int)
(declare-const token-driver Int)
(declare-const claimant Int)
(declare-const token-site-id Int)
(declare-const commit-site-id Int)
(declare-const token-actor Int)
(declare-const live-binding-actor Int)
(declare-const token-binding-instance Int)
(declare-const live-binding-instance Int)
(declare-const token-binding-epoch Int)
(declare-const live-binding-epoch Int)
(declare-const token-generation Int)
(declare-const live-binding-generation Int)
(declare-const active-generation Int)
(declare-const token-recorder Int)
(declare-const live-binding-recorder Int)
(declare-const active-recorder Int)
(declare-const binding-live Bool)
(declare-const exact-binding-check-enabled Bool)
(declare-const commit-authorized Bool)
(declare-const reset-occurs Bool)
(declare-const allocation-clock-open Bool)
(declare-const old-generation-open-after-reset Bool)
(declare-const publication-before-reset Bool)
(declare-const active-generation-open Bool)
(declare-const new-generation-published Bool)
(declare-const allocation-cas-won Bool)
(declare-const snapshot-cut-cas-won Bool)

; Drive/commit/publication counters, hit/action assignment, and CAS pair.
(declare-const drive-count Int)
(declare-const commit-count Int)
(declare-const hit-assignment-count Int)
(declare-const action-assignment-count Int)
(declare-const append-count Int)
(declare-const hit-before Int)
(declare-const hit-after Int)
(declare-const cut-before Int)
(declare-const next-seq-before Int)
(declare-const cut-after Int)
(declare-const next-seq-after Int)
(declare-const event-cut Int)
(declare-const event-seq Int)

; Snapshot chooses an active recorder and captures that recorder at one cut.
(declare-const snapshot-recorder Int)
(declare-const snapshot-capture-recorder Int)
(declare-const snapshot-clock-cut-before Int)
(declare-const snapshot-clock-next-seq-before Int)
(declare-const snapshot-cut Int)
(declare-const snapshot-next-seq Int)
(declare-const snapshot-clock-cut-after Int)
(declare-const snapshot-clock-next-seq-after Int)
(declare-const active-recorder-append-count Int)
(declare-const eligible-event-count Int)
(declare-const snapshot-captured-event-count Int)
(declare-const recorder-capture-lock-held Bool)

; Every property is defined, then joined into one shared violation predicate.
(declare-const phase-violation Bool)
(declare-const driver-violation Bool)
(declare-const binding-violation Bool)
(declare-const reset-violation Bool)
(declare-const reset-close-publication-violation Bool)
(declare-const exactly-once-violation Bool)
(declare-const commit-atomicity-violation Bool)
(declare-const cas-violation Bool)
(declare-const append-ownership-violation Bool)
(declare-const snapshot-violation Bool)
(declare-const recorder-machine-violation Bool)

(assert (! (and (<= 0 implementation) (<= implementation 4))
  :named implementation-domain))
(assert (! (and (<= 0 scenario) (<= scenario 4))
  :named bounded-five-scenario-domain))
(assert (= history-step-count
  (ite (= scenario 0) 6
    (ite (= scenario 1) 4
      (ite (= scenario 2) 5 6)))))
(assert (! (and (<= 1 history-step-count) (<= history-step-count 6))
  :named six-step-machine-bound))

; All scenarios begin with context 1 as the token's designated driver.
(assert (! (= token-phase-before 1) :named reserve-token-phase))
(assert (! (= token-driver 1) :named designated-driver))
(assert (= claimant 1))
(assert (= reset-context 0))
(assert (! (and (<= 0 token-driver) (<= token-driver 1)
                (<= 0 claimant) (<= claimant 1)
                (<= 0 reset-context) (<= reset-context 1))
  :named two-context-domain))
(assert (= token-site-id 20))
(assert (= commit-site-id 20))
(assert (= token-actor 0))
(assert (= live-binding-actor 0))
(assert (! (and (<= 0 token-actor) (<= token-actor 1)
                (<= 0 live-binding-actor) (<= live-binding-actor 1))
  :named two-actor-domain))
(assert (= token-binding-instance 10))
(assert (= token-binding-epoch 0))
(assert (= token-generation 0))
(assert (= token-recorder 0))

; Rebind creates a new binding instance within the same reset epoch. Reset
; advances the generation and creates a new recorder. The caller-only mutant
; incorrectly preserves context 1's old binding across a reset by context 0.
(assert (! (= live-binding-instance (ite (= scenario 0) 11 10))
  :named unbind-rebind-binding-instance))
(assert (= live-binding-epoch 0))
(assert (= live-binding-generation 0))
(assert (= reset-occurs (or (= scenario 3) (= scenario 4))))
(assert (= publication-before-reset (= scenario 4)))
(assert (! (= active-generation (ite reset-occurs 1 0))
  :named reset-generation-and-recorder))
(assert (= active-recorder (ite reset-occurs 1 0)))
(assert (= live-binding-recorder 0))
(assert (= binding-live
  (ite (= scenario 3) (= implementation 4) true)))
(assert (! (= allocation-clock-open
  (or (not (= scenario 3)) (= implementation 4)))
  :named allocation-cas-observes-open-generation))
(assert (! (= old-generation-open-after-reset
  (and reset-occurs (= implementation 4) (= scenario 3)))
  :named reset-closes-old-generation-before-publish))
(assert (= new-generation-published reset-occurs))
(assert (= active-generation-open true))
(assert (! (= exact-binding-check-enabled
  (not (= implementation 1)))
  :named exact-binding-instance-and-epoch))

; Commit-time validation under recorder ownership requires the reserved phase,
; designated driver and site, a live exact binding instance+epoch, and the
; binding's generation/recorder.
; Mutant 1 removes only the binding-instance identity check; the epoch check
; remains, so the witness specifically exercises unbind/rebind invalidation.
(assert (= commit-authorized
  (and (= token-phase-before 1)
       (= claimant token-driver)
       (= commit-site-id token-site-id)
       (= token-actor live-binding-actor)
       binding-live
       (or (not exact-binding-check-enabled)
           (= token-binding-instance live-binding-instance))
       (= token-binding-epoch live-binding-epoch)
       (= token-generation live-binding-generation)
       (= token-recorder live-binding-recorder))))
(assert (! (= allocation-cas-won
  (and commit-authorized allocation-clock-open))
  :named generation-clock-cas-ordering))

; The duplicate-commit mutant drives the same reserved token twice. A valid
; reference drive commits once; stale/unbound/rebound reservations assign no
; hit or action and transition to stale.
(assert (= drive-count
  (ite (= implementation 2) 2 1)))
(assert (= commit-count
  (ite allocation-cas-won (ite (= implementation 2) 2 1) 0)))
(assert (= hit-assignment-count commit-count))
(assert (= action-assignment-count commit-count))
(assert (= append-count commit-count))
(assert (= token-phase-after (ite (> append-count 0) 3 2)))

; Event allocation CAS returns the current (cut,next-seq), stamps the event with
; that pair, preserves cut, and increments only next-seq. Hit update and append
; publication are part of the same recorder-owned commit.
(assert (= cut-before 0))
(assert (= next-seq-before 1))
(assert (= hit-before 0))
(assert (= event-cut cut-before))
(assert (= event-seq next-seq-before))
(assert (! (and (= cut-after cut-before)
                (= next-seq-after (+ next-seq-before commit-count)))
  :named cas-allocation-pair))
(assert (= hit-after (+ hit-before hit-assignment-count)))

; Publication belongs to the token recorder. Only publications to the active
; generation/recorder count toward that recorder's physical snapshot; the
; separate ownership property rejects a publication by a stale binding.
(assert (! (= active-recorder-append-count
  (ite (and (> append-count 0)
            (= token-recorder active-recorder)
            (= token-generation active-generation))
       append-count 0))
  :named append-publication-under-recorder-ownership))

; Snapshot CAS returns the active generation's prior cut/next-seq, increments
; only cut, then captures the same recorder under its mutex. Eligible appended
; events have event-cut <= returned cut. Mutant 3 omits the recorder capture
; lock, so it can observe allocated next-seq without the eligible append.
(assert (= snapshot-recorder active-recorder))
(assert (= snapshot-capture-recorder active-recorder))
(assert (! (= snapshot-cut-cas-won
  (and (= snapshot-recorder active-recorder) active-generation-open))
  :named snapshot-current-open-generation-cas))
(assert (= snapshot-clock-cut-before 0))
(assert (= snapshot-clock-next-seq-before
  (+ active-recorder-append-count 1)))
(assert (= snapshot-cut snapshot-clock-cut-before))
(assert (= snapshot-next-seq snapshot-clock-next-seq-before))
(assert (= snapshot-clock-cut-after (+ snapshot-cut 1)))
(assert (= snapshot-clock-next-seq-after snapshot-next-seq))
(assert (! (and (= snapshot-cut snapshot-clock-cut-before)
                (= snapshot-next-seq snapshot-clock-next-seq-before)
                (= snapshot-clock-cut-after (+ snapshot-clock-cut-before 1))
                (= snapshot-clock-next-seq-after
                   snapshot-clock-next-seq-before))
  :named snapshot-cut-cas-return-and-advance))
(assert (= eligible-event-count
  (ite (and (> active-recorder-append-count 0)
            (<= event-cut snapshot-cut))
       active-recorder-append-count 0)))
(assert (! (= recorder-capture-lock-held
  (not (and (= implementation 3) (= scenario 2))))
  :named snapshot-recorder-capture-lock))
(assert (= snapshot-captured-event-count
  (ite recorder-capture-lock-held eligible-event-count 0)))
(assert (! (and (= snapshot-recorder active-recorder)
                (= snapshot-capture-recorder snapshot-recorder)
                (= snapshot-clock-cut-after (+ snapshot-cut 1))
                (= snapshot-clock-next-seq-after snapshot-next-seq))
  :named snapshot-cut-and-per-recorder-capture))

; The named property definitions below are the only inputs to the shared
; violation predicate used by every reference and mutant query.
(assert (= phase-violation
  (or (not (= token-phase-before 1))
      (and (> append-count 0) (not (= token-phase-after 3)))
      (and (= append-count 0) (not (= token-phase-after 2))))))
(assert (= driver-violation
  (and (> drive-count 0)
       (or (not (= claimant token-driver))
           (not (= commit-site-id token-site-id))))))
(assert (= binding-violation
  (and (> commit-count 0)
       (or (not binding-live)
           (not (= token-binding-instance live-binding-instance))
           (not (= token-binding-epoch live-binding-epoch))))))
(assert (= reset-violation
  (and (> append-count 0)
       (not publication-before-reset)
       (or (not (= token-generation active-generation))
           (not (= token-recorder active-recorder))))))
(assert (= reset-close-publication-violation
  (and reset-occurs
       (or old-generation-open-after-reset
           (not new-generation-published)))))
(assert (= exactly-once-violation
  (or (> drive-count 1) (> commit-count 1) (> append-count 1)
      (not (= commit-count append-count)))))
(assert (! (= commit-atomicity-violation
  (or (not (= commit-count hit-assignment-count))
      (not (= commit-count action-assignment-count))
      (not (= commit-count append-count))
      (not (= (- hit-after hit-before) commit-count))))
  :named commit-time-hit-action-and-append))
(assert (= cas-violation
  (or (not (= cut-after cut-before))
      (not (= (- next-seq-after next-seq-before) commit-count))
      (and (> commit-count 0)
           (or (not (= event-cut cut-before))
               (not (= event-seq next-seq-before)))))))
(assert (= append-ownership-violation
  (and (> append-count 0)
       (or (not (= token-binding-instance live-binding-instance))
           (not (= token-binding-epoch live-binding-epoch))
           (and (not publication-before-reset)
                (or (not (= token-recorder active-recorder))
                    (not (= token-generation active-generation))))))))
(assert (= snapshot-violation
  (or (not snapshot-cut-cas-won)
      (not (= snapshot-recorder active-recorder))
      (not (= snapshot-capture-recorder snapshot-recorder))
      (not recorder-capture-lock-held)
      (not (= snapshot-clock-cut-after (+ snapshot-cut 1)))
      (not (= snapshot-clock-next-seq-after snapshot-next-seq))
      (not (= snapshot-next-seq (+ active-recorder-append-count 1)))
      (not (= snapshot-captured-event-count eligible-event-count)))))
(assert (! (= recorder-machine-violation
  (or phase-violation driver-violation binding-violation reset-violation
      reset-close-publication-violation exactly-once-violation
      commit-atomicity-violation cas-violation append-ownership-violation
      snapshot-violation))
  :named shared-recorder-machine-violation))

; No scenario in the reference machine can violate the shared predicate.
(push)
(assert (= implementation 0))
(assert (! recorder-machine-violation
  :named reference-machine-counterexample-query))
(check-sat)
(pop)

; A stale reservation from the prior binding instance becomes publishable.
(push)
(assert (= implementation 1))
(assert (= scenario 0))
(assert (! recorder-machine-violation
  :named missing-binding-instance-mutant-query))
(check-sat)
(pop)

; One reservation is claimed, committed, and appended twice.
(push)
(assert (= implementation 2))
(assert (= scenario 1))
(assert (! recorder-machine-violation :named double-commit-mutant-query))
(check-sat)
(pop)

; Snapshot observes allocated next-seq without the eligible append because the
; same-recorder capture lock was removed.
(push)
(assert (= implementation 3))
(assert (= scenario 2))
(assert (! recorder-machine-violation
  :named split-allocate-append-snapshot-mutant-query))
(check-sat)
(pop)

; Reset by context 0 leaves context 1 able to publish into the old recorder.
(push)
(assert (= implementation 4))
(assert (= scenario 3))
(assert (! recorder-machine-violation :named caller-only-reset-mutant-query))
(check-sat)
(pop)

; Non-vacuity: the reference commits once and snapshots the published prefix.
(push)
(assert (= implementation 0))
(assert (= scenario 1))
(assert (= drive-count 1))
(assert (= commit-count 1))
(assert (= hit-assignment-count 1))
(assert (= action-assignment-count 1))
(assert (= append-count 1))
(assert (= hit-after 1))
(assert (= token-phase-after 3))
(assert (= snapshot-cut 0))
(assert (= snapshot-next-seq 2))
(assert (= snapshot-clock-cut-after 1))
(assert (= eligible-event-count 1))
(assert (= snapshot-captured-event-count 1))
(assert (not recorder-machine-violation))
(assert (! true :named reference-commit-nonvacuity-query))
(check-sat)
(pop)

; Non-vacuity: reset invalidates the old binding globally and snapshots the new
; empty recorder at its own cut.
(push)
(assert (= implementation 0))
(assert (= scenario 3))
(assert (not binding-live))
(assert (= drive-count 1))
(assert (not allocation-clock-open))
(assert (not old-generation-open-after-reset))
(assert new-generation-published)
(assert (not allocation-cas-won))
(assert (= token-phase-after 2))
(assert (= hit-assignment-count 0))
(assert (= action-assignment-count 0))
(assert (= append-count 0))
(assert (= active-generation 1))
(assert (= active-recorder 1))
(assert (= snapshot-capture-recorder 1))
(assert (= snapshot-cut 0))
(assert (= snapshot-next-seq 1))
(assert (= snapshot-clock-cut-after 1))
(assert (= snapshot-captured-event-count 0))
(assert (not recorder-machine-violation))
(assert (! true :named reference-reset-nonvacuity-query))
(check-sat)
(pop)

; Non-vacuity: allocation wins on the old open generation, then reset closes it
; and publishes a new empty recorder. The old event is ordered before reset and
; is absent from the new recorder's snapshot.
(push)
(assert (= implementation 0))
(assert (= scenario 4))
(assert publication-before-reset)
(assert allocation-clock-open)
(assert allocation-cas-won)
(assert (= commit-count 1))
(assert (= hit-assignment-count 1))
(assert (= action-assignment-count 1))
(assert (= append-count 1))
(assert (not old-generation-open-after-reset))
(assert new-generation-published)
(assert (= active-generation 1))
(assert (= snapshot-cut 0))
(assert (= snapshot-next-seq 1))
(assert (= snapshot-clock-cut-after 1))
(assert (= snapshot-captured-event-count 0))
(assert (not recorder-machine-violation))
(assert (! true :named reference-winner-before-reset-nonvacuity-query))
(check-sat)
(pop)
