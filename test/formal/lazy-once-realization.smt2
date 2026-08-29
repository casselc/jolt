; Bounded fiber-safe lazy/tail once-realization protocol.
; Evidence target: chucklehead-dev/jolt-aspect-packs#18.
;
; Live-source facts abstracted here:
;   * host/chez/java/concurrency.ss:jolt-delay-force currently keeps one object
;     monitor owner across an arbitrary (and parkable) thunk and deliberately
;     preserves same-owner monitor reentrancy.
;   * host/chez/java/concurrency.ss:monitor-enter!/monitor-exit! records a fiber
;     identity (not its carrier thread), commits a waiter before parking, retakes
;     the decision after wake, and wakes contenders when the owner releases.
;   * host/chez/locks.ss:jolt-lock-wait performs the switch outside the
;     bookkeeping mutex, so a fiber never parks while holding a counted lock.
;   * host/chez/lazy-bridge.ss:force-lazyseq needs shared terminal value/error;
;     host/chez/seq.ss:seq-more needs a shared terminal value but deliberately
;     retries a thrown tail. Neither may run its thunk/tail under a mutex that
;     dynamic-wind releases at a fiber park.
;
; This is a deliberately small, symmetric two-context scenario. Actor 0 wins an
; unrealized cell, actor 1 contends, actor 0 terminates, and actor 1 is scheduled
; after the protocol wake. `recursive` permits actor 0 to force the same cell
; while it owns realization. That is reentrant execution, not a second owner.
; Nested computation may update record-private candidate fields, and the outer
; computation may replace those fields, but no contender can observe them while
; the gate remains owned. The one externally visible publication happens at the
; outermost release; after that release the terminal outcome cannot change.
;
; State: 0 unrealized, 1 running, 2 terminal value, 3 terminal error.
; Record: 0 lazyseq (value/error terminal), 1 cseq tail (value terminal; error
; releases back to unrealized and is retriable, preserving current parity).
; Gate properties apply to both record kinds: one owner per attempt, reentrant
; depth, outermost release, and wake. Outcome policy is record-owned: only a
; terminal outcome is an external publication. A cseq error ends one attempt,
; wakes the waiter, and permits a new single-owner attempt.
; Outer counted-lock rule: a successful first claim or same-owner reentry may
; occur at outer depth 0 or 1 because neither parks. A distinct-owner contender
; may register/park only at outer depth 0. Implementation: 0 reference, 1 admits
; a distinct second owner, 2 accepts a non-owner publication, 3 overwrites a
; terminal outcome, 4 loses the wake, 5 omits the contended-wait guard.
;
; Liveness is conditional, not scheduler magic: the owner terminates within this
; bound and the woken waiter gets a bounded fair turn. The waiter then observes a
; shared terminal outcome or the cseq retry state. Infinite same-owner
; recursion, owner death/abandonment, cancellation, timeout, and weak-memory
; ordering outside the gate are not modeled. The protocol must provide the wake;
; the scheduler assumption only says a woken waiter runs.
;
; All mutation checks assert the same `once-violation` predicate. Expected:
;   unsat sat sat sat sat sat sat sat sat sat
; for reference, five mutants, recursive value, lazy error, cseq retry, and
; outer-lock uncontended-entry boundaries.
(set-logic QF_LIA)

(declare-const implementation Int)
(declare-const record-kind Int)
(declare-const recursive Bool)
(declare-const terminal-kind Int)
(declare-const terminal-payload Int)

(declare-const state-0 Int)
(declare-const state-owner-entered Int)
(declare-const owner-after-enter Int)
(declare-const state-contended Int)
(declare-const owner-after-contend Int)
(declare-const depth-after-reentrant-enter Int)
(declare-const depth-after-nested-exit Int)
(declare-const depth-after-outer-exit Int)
(declare-const owner-after-outer-exit Int)
(declare-const owner-executions Int)
(declare-const contender-executions Int)
(declare-const waiter-registered Bool)
(declare-const claimant-outer-lock-depth Int)
(declare-const contender-outer-lock-depth Int)

(declare-const publisher Int)
(declare-const externally-visible-publications Int)
(declare-const state-published Int)
(declare-const payload-published Int)
(declare-const owner-terminated Bool)
(declare-const wake-issued Bool)
(declare-const terminal-published Bool)

(declare-const fair-waiter-turn Bool)
(declare-const waiter-proceeded Bool)
(declare-const waiter-observed-state Int)
(declare-const waiter-observed-payload Int)
(declare-const state-after-post-release-write Int)
(declare-const payload-after-post-release-write Int)

(declare-const distinct-owner-violation Bool)
(declare-const ownership-shape-violation Bool)
(declare-const guarded-wait-violation Bool)
(declare-const publisher-violation Bool)
(declare-const terminal-stability-violation Bool)
(declare-const waiter-liveness-violation Bool)
(declare-const shared-outcome-violation Bool)
(declare-const once-violation Bool)

(assert (! (and (<= 0 implementation) (<= implementation 5))
           :named implementation-domain))
(assert (! (or (= record-kind 0) (= record-kind 1))
           :named record-kind-domain))
(assert (! (or (= terminal-kind 2) (= terminal-kind 3))
           :named terminal-kind-domain))
(assert (! (and (<= 10 terminal-payload) (<= terminal-payload 11))
           :named terminal-payload-domain))
(assert (! (and (<= 0 claimant-outer-lock-depth)
                (<= claimant-outer-lock-depth 1))
           :named claimant-outer-lock-depth-domain))
(assert (! (= contender-outer-lock-depth (ite (= implementation 5) 1 0))
           :named contended-wait-guard-mutation))

; First force atomically claims the unrealized cell for actor 0.
(assert (! (= state-0 0) :named initial-unrealized))
(assert (! (= state-owner-entered 1) :named claim-enters-running))
(assert (! (= owner-after-enter 0) :named first-claimer-is-owner))
(assert (! (= owner-executions (ite recursive 2 1))
           :named same-owner-recursion-executes-reentrantly))
(assert (! (= depth-after-reentrant-enter (ite recursive 2 1))
           :named same-owner-recursion-increments-depth))
(assert (! (= depth-after-nested-exit 1)
           :named nested-exit-keeps-outer-ownership))

; Actor 1 arrives while actor 0 is running. The reference keeps actor 0 as the
; sole owner and registers actor 1. Mutant 1 incorrectly lets actor 1 execute.
(assert (! (= state-contended 1) :named contention-remains-running))
(assert (! (= owner-after-contend owner-after-enter)
           :named contention-does-not-transfer-owner))
(assert (! (= contender-executions (ite (= implementation 1) 1 0))
           :named distinct-owner-mutation))
(assert (! waiter-registered :named contender-registers-before-wait))

; The owner terminates in-bounds. Mutant 2 accepts actor 1 as publisher. The
; value/error kind and payload are otherwise unconstrained within finite domains.
(assert (! owner-terminated :named bounded-owner-termination-assumption))
(assert (! (= publisher (ite (= implementation 2) 1 0))
           :named publication-actor))
(assert (! (= terminal-published
              (or (= terminal-kind 2) (= record-kind 0)))
           :named record-specific-terminal-policy))
(assert (! (= externally-visible-publications
              (ite terminal-published (ite (= implementation 3) 2 1) 0))
           :named one-outermost-publication-except-overwrite-mutant))
(assert (! (= state-published (ite terminal-published terminal-kind 0))
           :named terminal-or-retry-state-publication))
(assert (! (= payload-published (ite terminal-published terminal-payload -1))
           :named terminal-or-absent-payload-publication))
(assert (! (= depth-after-outer-exit 0) :named outermost-release-clears-depth))
(assert (! (= owner-after-outer-exit -1) :named outermost-release-clears-owner))

; Outermost release wakes the registered waiter in every implementation except
; the lost-wake mutant. This wake is required even when cseq publishes no terminal
; outcome and returns to retryable state. Fairness only schedules a woken waiter.
(assert (! (= wake-issued (not (= implementation 4)))
           :named publication-wake))
(assert (! fair-waiter-turn :named bounded-fair-waiter-turn-assumption))
(assert (! (= waiter-proceeded (and wake-issued fair-waiter-turn))
           :named waiter-retries-after-wake))
(assert (! (= waiter-observed-state
              (ite waiter-proceeded state-published 1))
           :named waiter-observes-terminal-state))
(assert (! (= waiter-observed-payload
              (ite waiter-proceeded payload-published -1))
           :named waiter-observes-terminal-payload))

; The terminal outcome below is the state after OUTERMOST release. Recursive
; candidate writes occurred while state remained running and were not externally
; visible. Reference and every mutant except 3 reject a post-release overwrite.
(assert (! (= state-after-post-release-write
              (ite (= implementation 3)
                   (ite (= state-published 2) 3 2)
                   state-published))
           :named post-release-write-cannot-change-terminal-kind))
(assert (! (= payload-after-post-release-write
              (ite (= implementation 3)
                   (ite (= payload-published 10) 11 10)
                   payload-published))
           :named post-release-write-cannot-change-terminal-payload))

; The negated bounded claim. Every helper is defined bi-directionally. Distinct
; ownership is per attempt: after a cseq error releases to state 0, actor 1 may
; legitimately claim a new attempt; it may not execute while actor 0 owns this one.
(assert (! (= distinct-owner-violation
              (and (> owner-executions 0) (> contender-executions 0)))
           :named distinct-owner-violation-definition))
(assert (! (= ownership-shape-violation
              (or (< depth-after-reentrant-enter 1)
                  (not (= depth-after-nested-exit 1))
                  (not (= depth-after-outer-exit 0))
                  (not (= owner-after-outer-exit -1))))
           :named ownership-shape-violation-definition))
(assert (! (= guarded-wait-violation
              (and waiter-registered (> contender-outer-lock-depth 0)))
           :named guarded-wait-violation-definition))
(assert (! (= publisher-violation
              (ite terminal-published
                   (or (not (= publisher owner-after-contend))
                       (not (= externally-visible-publications 1)))
                   (not (= externally-visible-publications 0))))
           :named publisher-violation-definition))
(assert (! (= terminal-stability-violation
              (and terminal-published
                   (or (not (= state-after-post-release-write state-published))
                       (not (= payload-after-post-release-write payload-published)))))
           :named terminal-stability-violation-definition))
(assert (! (= waiter-liveness-violation
              (and waiter-registered owner-terminated fair-waiter-turn
                   (or (not wake-issued) (not waiter-proceeded))))
           :named waiter-liveness-violation-definition))
(assert (! (= shared-outcome-violation
              (and terminal-published waiter-proceeded
                   (or (not (= waiter-observed-state state-after-post-release-write))
                       (not (= waiter-observed-payload payload-after-post-release-write)))))
           :named shared-outcome-violation-definition))
(assert (! (= once-violation
              (or distinct-owner-violation
                  ownership-shape-violation
                  guarded-wait-violation
                  publisher-violation
                  terminal-stability-violation
                  waiter-liveness-violation
                  shared-outcome-violation))
           :named shared-once-violation-definition))

; Reference counterexample query: no bounded violation exists.
(push)
(assert (= implementation 0))
(assert (! once-violation :named reference-counterexample-query))
(check-sat)
(pop)

; Known-SAT: a distinct contender executes while actor 0 still owns the cell.
(push)
(assert (= implementation 1))
(assert (! once-violation :named double-owner-mutant-query))
(check-sat)
(pop)

; Known-SAT: actor 1 publishes actor 0's realization.
(push)
(assert (= implementation 2))
(assert (= terminal-kind 2))
(assert (! once-violation :named non-owner-publisher-mutant-query))
(check-sat)
(pop)

; Known-SAT: a later write overwrites the terminal outcome after outermost release.
(push)
(assert (= implementation 3))
(assert recursive)
(assert (= terminal-kind 2))
(assert (! once-violation :named unstable-terminal-mutant-query))
(check-sat)
(pop)

; Known-SAT: owner terminates but the registered waiter is never woken.
(push)
(assert (= implementation 4))
(assert (! once-violation :named lost-wake-mutant-query))
(check-sat)
(pop)

; Known-SAT: the missing guard registers a contender while it holds an outer
; counted lock, making the park edge reachable at forbidden depth one.
(push)
(assert (= implementation 5))
(assert (! once-violation :named missing-contended-wait-guard-mutant-query))
(check-sat)
(pop)

; Reachable value boundary: same owner executes recursively, the contender never
; executes, exactly one value becomes externally visible, and the waiter shares it.
(push)
(assert (= implementation 0))
(assert (= record-kind 1))
(assert recursive)
(assert (= terminal-kind 2))
(assert (= terminal-payload 10))
(assert (= owner-executions 2))
(assert (= depth-after-reentrant-enter 2))
(assert (= depth-after-nested-exit 1))
(assert (= depth-after-outer-exit 0))
(assert (= contender-executions 0))
(assert (= externally-visible-publications 1))
(assert waiter-proceeded)
(assert (= waiter-observed-state 2))
(assert (= waiter-observed-payload 10))
(assert (not once-violation))
(check-sat)
(pop)

; Reachable guard boundary: actor 0 claims and reenters immediately while holding
; one outer counted lock. Neither successful edge parks. The later distinct actor
; arrives at outer depth zero, so only that actor may register and wait.
(push)
(assert (= implementation 0))
(assert (= claimant-outer-lock-depth 1))
(assert recursive)
(assert (= depth-after-reentrant-enter 2))
(assert (= contender-outer-lock-depth 0))
(assert waiter-registered)
(assert (not guarded-wait-violation))
(assert (not once-violation))
(check-sat)
(pop)

; Reachable lazyseq error boundary: lazyseq caches and shares terminal failure.
(push)
(assert (= implementation 0))
(assert (= record-kind 0))
(assert recursive)
(assert (= terminal-kind 3))
(assert (= terminal-payload 11))
(assert waiter-proceeded)
(assert (= waiter-observed-state 3))
(assert (= waiter-observed-payload 11))
(assert (not once-violation))
(check-sat)
(pop)

; Reachable cseq error boundary: parity is retry, not a terminal error. The
; waiter wakes, observes unrealized state, and may become owner of a new attempt.
(push)
(assert (= implementation 0))
(assert (= record-kind 1))
(assert (= terminal-kind 3))
(assert (not terminal-published))
(assert (= externally-visible-publications 0))
(assert waiter-proceeded)
(assert (= waiter-observed-state 0))
(assert (= waiter-observed-payload -1))
(assert (= owner-after-outer-exit -1))
(assert (not once-violation))
(check-sat)
(pop)
