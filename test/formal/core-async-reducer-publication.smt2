; P4b: bounded private staging / ex-handler / publication / EOF lifecycle.
;
; P4a owns reducer reservation and handler claims.  This companion model covers
; the state that must remain private while reducer, exception handler, and
; completion callback code executes outside the channel's counted leaf mutex.
;
; Bound: two admitted inputs; step 1 emits zero or two labeled outputs A1/A2,
; step 2 emits B1 when not reduced, and completion emits C.  Event time -1 means
; absent; live events are within 0..16.  The two A outputs also cover cap=1
; overproduction: the whole invocation batch stays private until one commit.
; Public close happens while step 1 is in flight.  A poll at time 4 must not see
; terminal nil/EOF; step/completion outputs publish only on validated commits and
; terminal EOF follows their drain.  New post-close puts reject immediately.
;
; implementation 0 is reference.  1..10 are executable bad histories: early
; step-output publication, stale-token publication, duplicate publication,
; ex-handler under lock, completion callback under lock, early EOF, early
; completion-output publication, post-close put acceptance, split/interleaved
; batch publication, and reversed intra-step output order.
;
; Limits: output payload equality, reducer cardinalities above two outputs/input,
; callback exceptions, concrete buffer mechanics and unbounded scheduling are abstracted.
; Runtime checkpoint histories must connect this event protocol to production.
(set-logic QF_LIA)

(declare-const implementation Int)
(declare-const reduced-first Bool)
(declare-const throws-first Bool)
(declare-const zero-output-first Bool)
(declare-const capacity Int)
(declare-const staged1-count Int)
(declare-const close-time Int)
(declare-const poll-time Int)
(declare-const step1-start Int)
(declare-const ex-start Int)
(declare-const sibling-time Int)
(declare-const ex-finish Int)
(declare-const step1-finish Int)
(declare-const stage1-time Int)
(declare-const commit1-time Int)
(declare-const publish1-time Int)
(declare-const publish1-count Int)
(declare-const stage1b-time Int)
(declare-const publish1b-time Int)
(declare-const publish1b-count Int)
(declare-const publish1-position Int)
(declare-const publish1b-position Int)
(declare-const stage2-time Int)
(declare-const commit2-time Int)
(declare-const publish2-time Int)
(declare-const publish2-count Int)
(declare-const publish2-position Int)
(declare-const accept2-time Int)
(declare-const completion-start Int)
(declare-const completion-stage Int)
(declare-const completion-commit Int)
(declare-const completion-publish Int)
(declare-const completion-publish-count Int)
(declare-const completion-publish-position Int)
(declare-const drain-time Int)
(declare-const eof-time Int)
(declare-const poll-terminal Bool)
(declare-const post-close-put-accepted Bool)
(declare-const token1-valid-at-commit Bool)
(declare-const stale-publish-count Int)
(declare-const ex-lock-held Bool)
(declare-const completion-lock-held Bool)
(declare-const publication-violation Bool)

(assert (! (and (<= 0 implementation) (<= implementation 10))
           :named implementation-domain))
(assert (! (= capacity 1) :named capacity-one-domain))
(assert (! (= staged1-count (ite zero-output-first 0 2))
           :named staged-step1-output-count))

; Machine-check the documented event bound; -1 is the only absence sentinel.
(assert (! (and
             (<= -1 close-time) (<= close-time 16)
             (<= -1 poll-time) (<= poll-time 16)
             (<= -1 step1-start) (<= step1-start 16)
             (<= -1 ex-start) (<= ex-start 16)
             (<= -1 sibling-time) (<= sibling-time 16)
             (<= -1 ex-finish) (<= ex-finish 16)
             (<= -1 step1-finish) (<= step1-finish 16)
             (<= -1 stage1-time) (<= stage1-time 16)
             (<= -1 stage1b-time) (<= stage1b-time 16)
             (<= -1 commit1-time) (<= commit1-time 16)
             (<= -1 publish1-time) (<= publish1-time 16)
             (<= -1 publish1b-time) (<= publish1b-time 16)
             (<= -1 stage2-time) (<= stage2-time 16)
             (<= -1 commit2-time) (<= commit2-time 16)
             (<= -1 publish2-time) (<= publish2-time 16)
             (<= -1 accept2-time) (<= accept2-time 16)
             (<= -1 completion-start) (<= completion-start 16)
             (<= -1 completion-stage) (<= completion-stage 16)
             (<= -1 completion-commit) (<= completion-commit 16)
             (<= -1 completion-publish) (<= completion-publish 16)
             (<= -1 drain-time) (<= drain-time 16)
             (<= -1 eof-time) (<= eof-time 16))
           :named event-time-domain))

; Step 1 is in flight across close.  If it throws, its ex-handler itself parks
; while a sibling progresses; otherwise those ex events are absent.
(assert (! (= step1-start 1) :named step1-start-event))
(assert (! (= close-time 2) :named close-event))
(assert (! (= poll-time 4) :named post-close-poll-event))
(assert (! (= ex-start (ite throws-first 3 -1)) :named ex-start-event))
(assert (! (= sibling-time 4) :named sibling-progress-event))
(assert (! (= ex-finish (ite throws-first 5 -1)) :named ex-finish-event))
(assert (! (= step1-finish 5) :named step1-finish-event))

; Reducer/ex-handler outputs A1,A2 remain a private ordered batch until the
; reserved token validates and commits.  Early publish precedes staging; stale
; publish adds an invalid terminal publication; duplicate repeats A1.  The split
; mutant publishes A1, then B1, then A2; the reverse mutant swaps A1/A2 slots.
(assert (! (= stage1-time (ite zero-output-first -1 5)) :named stage1-event))
(assert (! (= stage1b-time (ite zero-output-first -1 5)) :named stage1b-event))
(assert (! (= commit1-time 6) :named commit1-event))
(assert (! (= publish1-time
              (ite zero-output-first -1 (ite (= implementation 1) 4 6)))
           :named publish1-event))
(assert (! (= publish1b-time
              (ite zero-output-first -1 (ite (= implementation 9) 10 6)))
           :named publish1b-event))
(assert (! (= publish1-count
              (ite zero-output-first 0 (ite (= implementation 3) 2 1)))
           :named publish1-count-event))
(assert (! (= publish1b-count (ite zero-output-first 0 1))
           :named publish1b-count-event))
(assert (! (= publish1-position
              (ite zero-output-first -1 (ite (= implementation 10) 2 1)))
           :named publish1-position-event))
(assert (! (= publish1b-position
              (ite zero-output-first -1
                (ite (= implementation 10) 1
                  (ite (= implementation 9) 3 2))))
           :named publish1b-position-event))
(assert (! (= token1-valid-at-commit true) :named token1-validation-event))
(assert (! (= stale-publish-count (ite (= implementation 2) 1 0))
           :named stale-publication-event))

; The tail either stages/commits one normal output or, after reduced, is accepted
; without another reducer invocation/output.
(assert (! (= stage2-time (ite reduced-first -1 9)) :named stage2-event))
(assert (! (= commit2-time (ite reduced-first -1 10)) :named commit2-event))
(assert (! (= publish2-time (ite reduced-first -1 10)) :named publish2-event))
(assert (! (= publish2-count (ite reduced-first 0 1))
           :named publish2-count-event))
(assert (! (= publish2-position
              (ite reduced-first -1
                (ite zero-output-first 1 (ite (= implementation 9) 2 3))))
           :named publish2-position-event))
(assert (! (= accept2-time (ite reduced-first 7 -1))
           :named accepted-after-reduced-event))

; Completion is another generic callback with privately staged output.  It starts
; only after both admitted inputs resolve and publishes only at validated commit.
; The early-completion-output mutant runs and publishes it while step 1 is parked.
(assert (! (= completion-start
              (ite (= implementation 7) 3
                (ite reduced-first 8 11)))
           :named completion-start-event))
(assert (! (= completion-stage
              (ite (= implementation 7) 4
                (ite reduced-first 8 11)))
           :named completion-stage-event))
(assert (! (= completion-commit
              (ite (= implementation 7) 4
                (ite reduced-first 8 11)))
           :named completion-commit-event))
(assert (! (= completion-publish completion-commit)
           :named completion-publish-event))
(assert (! (= completion-publish-count 1)
           :named completion-publish-count-event))
(assert (! (= completion-publish-position
              (ite reduced-first
                   (ite zero-output-first 1 3)
                   (ite zero-output-first 2 4)))
           :named completion-publish-position-event))

; EOF is distinct from closing.  All staged/published outputs drain first.  The
; early-EOF mutant exposes terminal nil at the post-close poll while work remains.
(assert (! (= drain-time
              (ite (= implementation 7) 12
                (ite reduced-first 9 12)))
           :named output-drain-event))
(assert (! (= eof-time
              (ite (= implementation 6) 4
                (ite reduced-first 10 13)))
           :named terminal-eof-event))
(assert (! (= poll-terminal (<= eof-time poll-time))
           :named derived-poll-terminal))
(assert (! (= post-close-put-accepted (= implementation 8))
           :named post-close-put-result))

; Generic callbacks are never executed under the counted leaf mutex.
(assert (! (= ex-lock-held (= implementation 4))
           :named ex-handler-lock-state))
(assert (! (= completion-lock-held (= implementation 5))
           :named completion-lock-state))

; One shared counterexample predicate.
(assert (! (= publication-violation
              (or
                ; close happens while step/ex-handler work is in flight and a
                ; sibling can progress outside the leaf lock
                (not (< step1-start close-time))
                (not (< close-time step1-finish))
                (and throws-first
                     (or (< ex-start close-time)
                         (not (< ex-start sibling-time))
                         (not (< sibling-time ex-finish))))
                ; A1/A2 staging is private, atomic and intra-step ordered at one
                ; validated commit; zero-output steps publish nothing
                (and zero-output-first
                     (or (>= stage1-time 0) (>= stage1b-time 0)
                         (>= publish1-time 0) (>= publish1b-time 0)
                         (not (= publish1-count 0))
                         (not (= publish1b-count 0))
                         (not (= publish1-position -1))
                         (not (= publish1b-position -1))))
                (and (not zero-output-first)
                     (or (< publish1-time stage1-time)
                         (< publish1b-time stage1b-time)
                         (< publish1-time commit1-time)
                         (< publish1b-time commit1-time)
                         (not (= publish1-time publish1b-time))
                         (not (= publish1-count 1))
                         (not (= publish1b-count 1))
                         (not (= publish1-position 1))
                         (not (= publish1b-position 2))))
                (not token1-valid-at-commit)
                (not (= stale-publish-count 0))
                (and (not reduced-first)
                     (or (< publish2-time stage2-time)
                         (< publish2-time commit2-time)
                         (not (= publish2-count 1))
                         (not (= publish2-position
                                 (ite zero-output-first 1 3)))))
                (and reduced-first
                     (or (>= stage2-time 0) (>= publish2-time 0)
                         (not (= publish2-count 0)) (< accept2-time 0)))
                ; completion starts only after every admitted input resolution;
                ; its staged output publishes once at/after completion commit
                (<= completion-start commit1-time)
                (and (not reduced-first) (<= completion-start commit2-time))
                (and reduced-first (<= completion-start accept2-time))
                (< completion-stage completion-start)
                (< completion-publish completion-stage)
                (< completion-publish completion-commit)
                (not (= completion-publish-count 1))
                (not (= completion-publish-position
                        (ite reduced-first
                             (ite zero-output-first 1 3)
                             (ite zero-output-first 2 4))))
                ; closing is not EOF: poll/take stays non-terminal until all
                ; step/completion outputs publish and drain; new puts reject
                poll-terminal
                (<= eof-time drain-time)
                (<= eof-time publish1-time)
                (and (not reduced-first) (<= eof-time publish2-time))
                (<= eof-time completion-publish)
                post-close-put-accepted
                ; callback lock boundary
                (and throws-first ex-lock-held)
                completion-lock-held))
           :named shared-publication-violation))

; Reference counterexample spans normal/reduced and throwing/non-throwing inputs.
(push)
(assert (= implementation 0))
(assert (! publication-violation :named reference-publication-counterexample))
(check-sat)
(pop)

; Known-SAT controls, all through shared-publication-violation.
(push) (assert (= implementation 1))
(assert (not zero-output-first))
(assert (! publication-violation :named early-output-publish-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 2))
(assert (! publication-violation :named stale-output-publish-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 3))
(assert (not zero-output-first))
(assert (! publication-violation :named duplicate-output-publish-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 4)) (assert throws-first)
(assert (! publication-violation :named ex-handler-under-lock-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 5))
(assert (! publication-violation :named completion-under-lock-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 6))
(assert (! publication-violation :named early-eof-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 7))
(assert (! publication-violation :named early-completion-output-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 8))
(assert (! publication-violation :named post-close-put-accepted-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 9)) (assert (not reduced-first))
(assert (not zero-output-first))
(assert (! publication-violation :named split-interleaved-batch-mutant-query))
(check-sat) (pop)
(push) (assert (= implementation 10))
(assert (not zero-output-first))
(assert (! publication-violation :named reversed-intra-step-order-mutant-query))
(check-sat) (pop)

; Non-vacuity: normal staged outputs, reduced tail, parking ex-handler, and the
; close/not-yet-EOF observation all remain reachable.
(push) (assert (= implementation 0)) (assert (not reduced-first))
(assert (not zero-output-first))
(assert (not throws-first)) (assert (= publish1-time 6))
(assert (= publish1b-time 6)) (assert (= publish1-position 1))
(assert (= publish1b-position 2)) (assert (= publish2-position 3))
(assert (= capacity 1)) (assert (= staged1-count 2))
(assert (= publish2-time 10)) (assert (= completion-publish-position 4))
(assert (= completion-publish 11))
(assert (= drain-time 12)) (assert (= eof-time 13))
(assert (not publication-violation)) (check-sat) (pop)
(push) (assert (= implementation 0)) (assert reduced-first)
(assert (not zero-output-first))
(assert (= accept2-time 7)) (assert (= stage2-time -1))
(assert (= completion-publish 8)) (assert (= eof-time 10))
(assert (not publication-violation)) (check-sat) (pop)
(push) (assert (= implementation 0)) (assert throws-first)
(assert (not zero-output-first))
(assert (= ex-start 3)) (assert (= sibling-time 4)) (assert (= ex-finish 5))
(assert (not ex-lock-held)) (assert (= publish1-time 6))
(assert (not publication-violation)) (check-sat) (pop)
(push) (assert (= implementation 0)) (assert (not reduced-first))
(assert (not zero-output-first))
(assert (= close-time 2)) (assert (= poll-time 4))
(assert (not poll-terminal)) (assert (= publish1-time 6))
(assert (= completion-publish 11)) (assert (= drain-time 12))
(assert (= eof-time 13)) (assert (not publication-violation))
(check-sat) (pop)
; Zero-output step still commits its input and permits completion/EOF without a
; phantom step-output publication.
(push) (assert (= implementation 0)) (assert zero-output-first)
(assert reduced-first) (assert (= publish1-count 0))
(assert (= publish1b-count 0)) (assert (= publish1-position -1))
(assert (= publish1b-position -1)) (assert (= completion-publish-position 1))
(assert (not publication-violation)) (check-sat) (pop)
