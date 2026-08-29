; Bounded two-context ownership/progress model for jolt logical mutexes.
; Evidence target: chucklehead-dev/jolt-aspect-packs#27.
;
; Live-source facts represented:
;   * host/chez/locks.ss:jolt-logical-mutex-try-enter/owner! changes owner and
;     depth under one bookkeeping mutex; same-owner entry increments depth.
;   * jolt-logical-mutex-wait! asserts zero counted locks before its sole
;     jolt-cv-wait, retakes the ownership decision after every wake, and claims
;     only an unowned mutex.
;   * jolt-logical-mutex-exit! permits only the owner (plus the separately
;     runtime-tested terminal-unwind identity), clears on outermost exit, and
;     wakes under the bookkeeping mutex that guards the decision.
;   * caller payload writes precede outermost release; a waiter acquires the
;     same bookkeeping mutex before reading the published payload.
;
; Domain/bounds: actors {0,1}; one initial claim by actor 0; optional one
; same-owner reentry; one distinct contender; one outermost exit; one bounded
; fair turn for the registered waiter. Infinite owner execution, cancellation,
; timeouts, interrupts, condition variables, more than two contenders, and weak
; memory behavior outside this acquire/release boundary are omitted.
;
; `implementation`: 0 reference; 1 admits a second owner; 2 accepts a
; non-owner outer release; 3 loses the release wake; 4 fails reentrant depth;
; 5 waits while a counted lock is held; 6 exposes stale payload after acquire;
; 7 loses release-before-registration by parking after its decision sees free.
; Every mutant uses the same `logical-mutex-violation` query.
;
; Expected statuses:
;   unsat sat sat sat sat sat sat sat sat sat sat
; reference counterexample, seven mutants, then three non-vacuity boundaries.
(set-logic QF_LIA)

(declare-const implementation Int)
(declare-const recursive Bool)
(declare-const release-before-registration Bool)
(declare-const claimant-counted-depth Int)
(declare-const contender-counted-depth Int)

(declare-const owner-after-claim Int)
(declare-const depth-after-claim Int)
(declare-const depth-after-reentry Int)
(declare-const depth-after-nested-exit Int)
(declare-const contender-executions Int)
(declare-const waiter-registered Bool)
(declare-const waiter-registered-at-release Bool)
(declare-const waiter-sees-free-after-release Bool)

(declare-const releaser Int)
(declare-const owner-after-outer-exit Int)
(declare-const depth-after-outer-exit Int)
(declare-const owner-terminated Bool)
(declare-const wake-issued Bool)
(declare-const fair-waiter-turn Bool)
(declare-const waiter-proceeded Bool)

(declare-const payload-before-release Int)
(declare-const payload-seen-after-acquire Int)

(declare-const double-owner-violation Bool)
(declare-const non-owner-release-violation Bool)
(declare-const reentrancy-depth-violation Bool)
(declare-const ownership-clear-violation Bool)
(declare-const counted-wait-violation Bool)
(declare-const waiter-progress-violation Bool)
(declare-const publication-violation Bool)
(declare-const logical-mutex-violation Bool)

(assert (! (and (<= 0 implementation) (<= implementation 7))
           :named implementation-domain))
(assert (! (and (<= 0 claimant-counted-depth) (<= claimant-counted-depth 1))
           :named claimant-counted-depth-domain))
(assert (! (= contender-counted-depth (ite (= implementation 5) 1 0))
           :named guarded-contender-depth))

; Actor 0 claims. Same-owner recursion is the only permitted second execution.
(assert (! (= owner-after-claim 0) :named initial-claim-owner))
(assert (! (= depth-after-claim 1) :named initial-claim-depth))
(assert (! (= depth-after-reentry
              (ite recursive (ite (= implementation 4) 1 2) 1))
           :named reentrant-depth-transition))
(assert (! (= depth-after-nested-exit 1)
           :named nested-exit-retains-outer-depth))
(assert (! (= contender-executions (ite (= implementation 1) 1 0))
           :named distinct-contender-execution))
(assert (! waiter-registered :named contender-registers-before-wait))
(assert (! (= waiter-registered-at-release
              (and waiter-registered (not release-before-registration)))
           :named registration-release-order))
(assert (! (= waiter-sees-free-after-release release-before-registration)
           :named late-waiter-retakes-free-decision))

; The owner writes, exits outermost, and releases its ownership. Mutant 2 makes
; actor 1 the releaser; clearing still occurs so the violation is specifically
; authorization rather than a manufactured uncleared state.
(assert (! (= releaser (ite (= implementation 2) 1 0))
           :named outermost-release-actor))
(assert (! (= owner-after-outer-exit -1)
           :named outermost-release-clears-owner))
(assert (! (= depth-after-outer-exit 0)
           :named outermost-release-clears-depth))
(assert (! owner-terminated :named bounded-owner-termination-assumption))
(assert (! (= payload-before-release 73) :named owner-payload-write))

; Wake plus a bounded fair turn is sufficient progress. Fairness schedules only
; a waiter the protocol actually woke; it does not create the wake.
(assert (! (= wake-issued
              (and waiter-registered-at-release (not (= implementation 3))))
           :named outermost-release-wake))
(assert (! fair-waiter-turn :named bounded-fair-waiter-turn-assumption))
(assert (! (= waiter-proceeded
              (and waiter-registered
                   fair-waiter-turn
                   (or wake-issued
                       (and waiter-sees-free-after-release
                            (not (= implementation 7))))))
           :named waiter-progress-transition))
(assert (! (= payload-seen-after-acquire
              (ite waiter-proceeded
                   (ite (= implementation 6) 0 payload-before-release)
                   -1))
           :named acquire-observes-published-payload))

; Negated bounded claim. All result flags are equalities, not free implications.
(assert (! (= double-owner-violation
              (> contender-executions 0))
           :named double-owner-violation-definition))
(assert (! (= non-owner-release-violation
              (not (= releaser owner-after-claim)))
           :named non-owner-release-violation-definition))
(assert (! (= reentrancy-depth-violation
              (or (and recursive (not (= depth-after-reentry 2)))
                  (not (= depth-after-nested-exit 1))))
           :named reentrancy-depth-violation-definition))
(assert (! (= ownership-clear-violation
              (or (not (= owner-after-outer-exit -1))
                  (not (= depth-after-outer-exit 0))))
           :named ownership-clear-violation-definition))
(assert (! (= counted-wait-violation
              (and waiter-registered (> contender-counted-depth 0)))
           :named counted-wait-violation-definition))
(assert (! (= waiter-progress-violation
              (and waiter-registered owner-terminated fair-waiter-turn
                   (not waiter-proceeded)))
           :named waiter-progress-violation-definition))
(assert (! (= publication-violation
              (and waiter-proceeded
                   (not (= payload-seen-after-acquire payload-before-release))))
           :named publication-violation-definition))
(assert (! (= logical-mutex-violation
              (or double-owner-violation
                  non-owner-release-violation
                  reentrancy-depth-violation
                  ownership-clear-violation
                  counted-wait-violation
                  waiter-progress-violation
                  publication-violation))
           :named logical-mutex-violation-definition))

; Reference counterexample query: no violation in the bounded protocol.
(push)
(assert (= implementation 0))
(assert (! logical-mutex-violation :named reference-counterexample-query))
(check-sat)
(pop)

; Known-SAT mutants, all through the exact same violation predicate.
(push)
(assert (= implementation 1))
(assert (! logical-mutex-violation :named double-owner-mutant-query))
(check-sat)
(pop)

(push)
(assert (= implementation 2))
(assert (! logical-mutex-violation :named non-owner-release-mutant-query))
(check-sat)
(pop)

(push)
(assert (= implementation 3))
(assert (not release-before-registration))
(assert (! logical-mutex-violation :named lost-wake-mutant-query))
(check-sat)
(pop)

(push)
(assert (= implementation 4))
(assert recursive)
(assert (! logical-mutex-violation :named reentrant-depth-mutant-query))
(check-sat)
(pop)

(push)
(assert (= implementation 5))
(assert (! logical-mutex-violation :named counted-wait-mutant-query))
(check-sat)
(pop)

(push)
(assert (= implementation 6))
(assert (! logical-mutex-violation :named stale-publication-mutant-query))
(check-sat)
(pop)

; Known-SAT: release happens in enter!'s failed-try -> wait gap, but a broken
; waiter parks instead of retaking the guarded decision and claiming free state.
(push)
(assert (= implementation 7))
(assert release-before-registration)
(assert (! logical-mutex-violation :named release-before-registration-mutant-query))
(check-sat)
(pop)

; Non-vacuity controls are valid reference executions, not injected violations.
(push)
(assert (= implementation 0))
(assert recursive)
(assert (= depth-after-reentry 2))
(assert (not logical-mutex-violation))
(check-sat)
(pop)

(push)
(assert (= implementation 0))
(assert waiter-proceeded)
(assert release-before-registration)
(assert (= payload-seen-after-acquire 73))
(assert (not logical-mutex-violation))
(check-sat)
(pop)

; An uncontended fast claim while the caller holds an unrelated counted lock
; remains reachable; only the distinct-owner contended boundary is guarded.
(push)
(assert (= implementation 0))
(assert (= claimant-counted-depth 1))
(assert (= contender-counted-depth 0))
(assert (not logical-mutex-violation))
(check-sat)
(pop)
