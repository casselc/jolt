; P4a: fixed bounded reducer reservation / claim / close / commit histories.
;
; Source facts: ac-notify!'s FIFO putter drain and reducer call are at
; host/chez/java/async.ss:226-267; accepted-after-reduced is at 364-373; public
; close and exactly-once completion are at 349-385.  This model describes the
; reserve -> compute outside the leaf lock -> validate -> commit shape intended
; to replace the current under-lock invocation.
;
; Bound: two inputs admitted at time 0 and event times -1 (absent) or 0..12.
; Input 1's reducer step parks across public close; a sibling progresses before
; it finishes.  Normal and reduced-first histories are both in the reference.
;
; implementation 0 is reference.  1..12 are executable bad histories:
; concurrent reservation, close-dropped token, early completion, duplicate
; completion, stale-token mutation, stuck completed work, duplicate step,
; tail-before-head reservation/commit, step-after-reduced, compute under the
; counted lock, completion under the counted lock, and a foreign claimant that
; adopts another execution context's reserved token.
;
; Limits: these are fixed bounded event histories with a stuck internal-progress
; control, not a general scheduler or fairness model.  It abstracts values,
; reducer outputs, exceptions and
; concrete mutex mechanics; P4b separately models staged output/ex-handler
; publication.  Runtime checkpoint histories remain an implementation gate.
(set-logic QF_LIA)

(declare-const implementation Int)
(declare-const reduced-first Bool)
(declare-const reserve1 Int)
(declare-const start1 Int)
(declare-const finish1 Int)
(declare-const commit1 Int)
(declare-const wake1 Int)
(declare-const reserve2 Int)
(declare-const start2 Int)
(declare-const finish2 Int)
(declare-const commit2 Int)
(declare-const accept2 Int)
(declare-const wake2 Int)
(declare-const close-time Int)
(declare-const sibling-time Int)
(declare-const completion-time Int)
(declare-const completion-count Int)
(declare-const step1-count Int)
(declare-const step2-count Int)
(declare-const claim1-count Int)
(declare-const claim2-count Int)
(declare-const delivery1-count Int)
(declare-const delivery2-count Int)
(declare-const token1-live-after-close Bool)
(declare-const stale-token-mutations Int)
(declare-const active-final Int)
(declare-const step1-lock-held Bool)
(declare-const step2-lock-held Bool)
(declare-const completion-lock-held Bool)
(declare-const claimant-is-driver Bool)
(declare-const overlap Bool)
(declare-const lifecycle-violation Bool)

(assert (! (and (<= 0 implementation) (<= implementation 12))
           :named implementation-domain))

; Machine-check the documented -1/0..12 event domain.
(assert (! (and
             (<= -1 reserve1) (<= reserve1 12)
             (<= -1 start1) (<= start1 12)
             (<= -1 finish1) (<= finish1 12)
             (<= -1 commit1) (<= commit1 12)
             (<= -1 wake1) (<= wake1 12)
             (<= -1 reserve2) (<= reserve2 12)
             (<= -1 start2) (<= start2 12)
             (<= -1 finish2) (<= finish2 12)
             (<= -1 commit2) (<= commit2 12)
             (<= -1 accept2) (<= accept2 12)
             (<= -1 wake2) (<= wake2 12)
             (<= -1 close-time) (<= close-time 12)
             (<= -1 sibling-time) (<= sibling-time 12)
             (<= -1 completion-time) (<= completion-time 12))
           :named event-time-domain))

; Event history.  The tail-before-head mutant has a serial but reversed history.
; Every other history reserves head 1, parks in its reducer step, closes, lets a
; sibling progress, and then finishes head 1.
(assert (! (= reserve1 (ite (= implementation 8) 5 1))
           :named reserve1-event))
(assert (! (= start1 (ite (= implementation 8) 6 2))
           :named start1-event))
(assert (! (= close-time (ite (= implementation 8) 7 3))
           :named close-event))
(assert (! (= sibling-time (ite (= implementation 8) 8 4))
           :named sibling-event))
(assert (! (= finish1 (ite (= implementation 8) 9 5))
           :named finish1-event))
(assert (! (= commit1
              (ite (= implementation 6) -1
                (ite (= implementation 8) 10 6)))
           :named commit1-event))
(assert (! (= wake1 commit1) :named wake1-event))

; Tail lifecycle.  Concurrent-reservation overlaps the head.  Tail-before-head
; finishes tail first without overlap.  Reduced-first has no second reducer
; invocation and accepts its already-admitted owner after head commit.  The
; step-after-reduced mutant incorrectly runs it anyway.
(assert (! (= reserve2
              (ite (= implementation 8) 1
                (ite (= implementation 1) 2
                  (ite (= implementation 6) -1
                    (ite (and reduced-first (not (= implementation 9))) -1 7)))))
           :named reserve2-event))
(assert (! (= start2
              (ite (= implementation 8) 2
                (ite (= implementation 1) 3
                  (ite (= reserve2 -1) -1 8))))
           :named start2-event))
(assert (! (= finish2
              (ite (= implementation 8) 3
                (ite (= implementation 1) 4
                  (ite (= start2 -1) -1 9))))
           :named finish2-event))
(assert (! (= commit2
              (ite (= implementation 8) 4
                (ite (= implementation 1) 5
                  (ite (= finish2 -1) -1 10))))
           :named commit2-event))
(assert (! (= accept2
              (ite (and reduced-first
                        (not (= implementation 6))
                        (not (= implementation 9)))
                   7 -1))
           :named accept2-event))
(assert (! (= wake2 (ite (>= commit2 0) commit2 accept2))
           :named wake2-event))

; Completion is cumulative: one terminal event after the final resolution.  The
; early mutant fires while head computation is parked; duplicate fires twice.
(assert (! (= completion-time
              (ite (= implementation 3) 4
                (ite (= implementation 6) -1
                  (ite (or (= implementation 8)
                           (not reduced-first)
                           (= implementation 9))
                       11 8))))
           :named completion-event))
(assert (! (= completion-count
              (ite (= implementation 6) 0
                (ite (= implementation 4) 2 1)))
           :named completion-count-event))

; Claims, reducer steps and handler deliveries are explicit lifecycle events.
; The duplicate-step and step-after-reduced controls are reachable rather than
; dead branches hidden by a 0/1 domain.
(assert (! (= claim1-count 1) :named claim1-event))
(assert (! (= claim2-count (ite (= implementation 6) 0 1))
           :named claim2-event))
(assert (! (= step1-count (ite (= implementation 7) 2 1))
           :named step1-event-count))
(assert (! (= step2-count (ite (>= start2 0) 1 0))
           :named step2-event-count))
(assert (! (= delivery1-count (ite (= implementation 6) 0 1))
           :named delivery1-event-count))
(assert (! (= delivery2-count (ite (= implementation 6) 0 1))
           :named delivery2-event-count))

; Close preserves a pre-close reservation in every reference history.  Stale
; tokens are attempted after terminal state and must have zero mutation effect.
(assert (! (= token1-live-after-close (not (= implementation 2)))
           :named close-token-transition))
(assert (! (= stale-token-mutations (ite (= implementation 5) 1 0))
           :named stale-token-event))
(assert (! (= active-final (ite (= implementation 6) 1 0))
           :named final-active-reservations))

; User/generic reducer and completion code must execute outside the counted leaf
; mutex.  The two under-lock mutants make these clauses independently reachable.
(assert (! (= step1-lock-held (= implementation 10))
           :named step1-lock-state))
(assert (! (= step2-lock-held false) :named step2-lock-state))
(assert (! (= completion-lock-held (= implementation 11))
           :named completion-lock-state))
(assert (! (= claimant-is-driver (not (= implementation 12)))
           :named reservation-driver-identity))

; Invocation overlap is derived from the event intervals, not asserted as an
; independent semantic flag.  Intervals are closed while reducer code is live.
(assert (! (= overlap
              (and (>= start1 0) (>= finish1 start1)
                   (>= start2 0) (>= finish2 start2)
                   (<= start1 finish2) (<= start2 finish1)))
           :named derived-invocation-overlap))

; One counterexample predicate for reference, all mutants, and all boundaries.
(assert (! (= lifecycle-violation
              (or
                ; event enabling and the parked close/sibling history
                (not (= reserve1 1))
                (not (< reserve1 start1))
                (not (< start1 close-time))
                (not (< close-time sibling-time))
                (not (< sibling-time finish1))
                overlap
                ; FIFO reservation/commit for the oldest admitted input
                (and (>= reserve2 0) (not (< reserve1 reserve2)))
                (and (>= commit2 0) (not (< commit1 commit2)))
                ; close preserves the already-reserved token; a commit requires it
                (not token1-live-after-close)
                (and (>= commit1 0) (not token1-live-after-close))
                ; each admitted input is claimed/delivered exactly once
                (not (= claim1-count 1)) (not (= claim2-count 1))
                (not (= delivery1-count 1)) (not (= delivery2-count 1))
                ; reducer invocation count and reduced-tail disposition
                (not (= step1-count 1))
                (and reduced-first
                     (or (not (= step2-count 0)) (< accept2 0)))
                (and (not reduced-first)
                     (or (not (= step2-count 1)) (>= accept2 0)))
                ; bounded progress: a finished computation commits and wakes;
                ; accepted-after-reduced wakes its owner
                (and (>= finish1 0)
                     (or (< commit1 finish1) (< wake1 commit1)))
                (and (>= finish2 0)
                     (or (< commit2 finish2) (< wake2 commit2)))
                (and (>= accept2 0) (< wake2 accept2))
                ; completion follows all admitted resolutions and occurs once
                (not (= completion-count 1))
                (and (>= completion-time 0)
                     (or (< commit1 0)
                         (<= completion-time commit1)
                         (and (>= commit2 0) (<= completion-time commit2))
                         (and (>= accept2 0) (<= completion-time accept2))))
                (< completion-time 0)
                ; terminal tokens are inert and no reservation remains
                (not (= stale-token-mutations 0))
                (not (= active-final 0))
                ; leaf-lock and exact-driver boundaries
                step1-lock-held step2-lock-held completion-lock-held
                (not claimant-is-driver)))
           :named shared-lifecycle-violation))

; Reference counterexample: both normal and reduced-first histories are covered.
(push)
(assert (= implementation 0))
(assert (! lifecycle-violation :named reference-lifecycle-counterexample))
(check-sat)
(pop)

; Known-SAT controls, each using shared-lifecycle-violation.
(push) (assert (= implementation 1)) (assert (not reduced-first))
(assert (! lifecycle-violation :named concurrent-reservation-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 2))
(assert (! lifecycle-violation :named close-drops-token-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 3))
(assert (! lifecycle-violation :named early-completion-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 4))
(assert (! lifecycle-violation :named duplicate-completion-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 5))
(assert (! lifecycle-violation :named stale-token-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 6)) (assert (not reduced-first))
(assert (! lifecycle-violation :named stuck-progress-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 7))
(assert (! lifecycle-violation :named duplicate-step-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 8)) (assert (not reduced-first))
(assert (! lifecycle-violation :named tail-before-head-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 9)) (assert reduced-first)
(assert (! lifecycle-violation :named step-after-reduced-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 10))
(assert (! lifecycle-violation :named compute-under-lock-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 11))
(assert (! lifecycle-violation :named completion-under-lock-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 12))
(assert (! lifecycle-violation :named foreign-token-claimant-mutant-query))
(check-sat) (pop)

; Non-vacuity: normal FIFO, reduced-tail acceptance, and the parked step / close /
; sibling-progress boundary are concrete satisfying histories.
(push) (assert (= implementation 0)) (assert (not reduced-first))
(assert (= reserve1 1)) (assert (= commit1 6))
(assert (= reserve2 7)) (assert (= commit2 10))
(assert (= completion-time 11)) (assert (not lifecycle-violation))
(check-sat) (pop)
(push) (assert (= implementation 0)) (assert reduced-first)
(assert (= step1-count 1)) (assert (= step2-count 0))
(assert (= accept2 7)) (assert (= delivery2-count 1))
(assert (= completion-time 8)) (assert (not lifecycle-violation))
(check-sat) (pop)
(push) (assert (= implementation 0)) (assert (not reduced-first))
(assert (= start1 2)) (assert (= close-time 3))
(assert (= sibling-time 4)) (assert (= finish1 5))
(assert (= commit1 6)) (assert (= wake1 6))
(assert (not step1-lock-held)) (assert (not lifecycle-violation))
(check-sat) (pop)
