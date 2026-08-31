; Bounded action-semantics machine for checkpoint issue #54.
;
; This model starts after a checkpoint reservation has reached action
; selection.  It checks the scoped :continue/:yield/:fault/:cancel contract:
; the plan key is exactly [actor,site-id,hit], the selected action is admitted
; by the site's declared capabilities, hit/sequence/event publication precedes
; dispatch, cancellation is sticky for the actor without publishing repeated
; events, reset clears that sticky state, and stale-generation work mutates no
; recorder.
;
; Domain: actors {0,1}, site ids {10,11}, hits {1,2}, generations {0,1},
; actions {continue,yield,fault,cancel}, scenarios {0..7}.  The model omits
; scheduler fairness, exception payload representation, barriers, manifests,
; replay, and minimization; those remain runtime or later-model obligations.
;
; Scenarios: 0 nonmatching plan key, 1 undeclared yield, 2 continue,
; 3 yield, 4 fault, 5 sticky cancel and a later checkpoint, 6 cancel/reset/
; continue, 7 stale-generation reservation.
; Implementations: 0 reference, 1 ignores hit in plan lookup, 2 bypasses
; capabilities, 3 dispatches before event publication, 4 loses sticky cancel,
; 5 reset retains sticky cancel, 6 stale generation can commit, 7 makes cancel
; global instead of actor-local.
; Expected: unsat, seven mutant SAT results, seven non-vacuity SAT results.
(set-logic QF_LIA)

; Action tags: 0 continue, 1 yield, 2 fault, 3 cancel.
(declare-const implementation Int)
(declare-const scenario Int)

; One planned occurrence and the checkpoint that attempts to select it.
(declare-const plan-actor Int)
(declare-const plan-site Int)
(declare-const plan-hit Int)
(declare-const plan-action Int)
(declare-const call-actor Int)
(declare-const call-site Int)
(declare-const call-hit Int)
(declare-const exact-plan-key Bool)
(declare-const implementation-plan-key Bool)
(declare-const expected-action Int)
(declare-const selected-action Int)

; Declared action capabilities and admission.
(declare-const cap-continue Bool)
(declare-const cap-yield Bool)
(declare-const cap-fault Bool)
(declare-const cap-cancel Bool)
(declare-const selected-action-declared Bool)
(declare-const token-generation Int)
(declare-const current-generation Int)
(declare-const generation-current Bool)
(declare-const accepted-first Bool)

; First checkpoint publication and terminal dispatch.
(declare-const first-hit-delta Int)
(declare-const first-seq-delta Int)
(declare-const first-event-delta Int)
(declare-const first-dispatch-count Int)
(declare-const first-event-order Int)
(declare-const first-dispatch-order Int)
(declare-const first-dispatch-action Int)

; Actor cancellation state and a later checkpoint by the same actor.
(declare-const sticky-before Bool)
(declare-const sticky-after-first Bool)
(declare-const second-hit-delta Int)
(declare-const second-seq-delta Int)
(declare-const second-event-delta Int)
(declare-const second-dispatch-count Int)
(declare-const second-dispatch-action Int)
(declare-const sibling-sticky-after-first Bool)
(declare-const sibling-hit-delta Int)
(declare-const sibling-seq-delta Int)
(declare-const sibling-event-delta Int)
(declare-const sibling-dispatch-action Int)

; Reset publishes generation 1 with a fresh recorder and cleared actor state.
(declare-const reset-occurs Bool)
(declare-const reset-generation Int)
(declare-const sticky-after-reset Bool)
(declare-const post-reset-hit-delta Int)
(declare-const post-reset-seq-delta Int)
(declare-const post-reset-event-delta Int)
(declare-const post-reset-dispatch-action Int)

; Shared, bi-directionally defined violation predicates.
(declare-const selection-violation Bool)
(declare-const capability-violation Bool)
(declare-const publication-violation Bool)
(declare-const dispatch-order-violation Bool)
(declare-const sticky-cancel-violation Bool)
(declare-const actor-scope-violation Bool)
(declare-const reset-clear-violation Bool)
(declare-const stale-generation-violation Bool)
(declare-const checkpoint-action-violation Bool)

(assert (! (and (<= 0 implementation) (<= implementation 7))
  :named eight-implementation-domain))
(assert (! (and (<= 0 scenario) (<= scenario 7))
  :named eight-scenario-bound))
(assert (! (and (<= 0 plan-actor) (<= plan-actor 1)
                (<= 0 call-actor) (<= call-actor 1)
                (<= 10 plan-site) (<= plan-site 11)
                (<= 10 call-site) (<= call-site 11)
                (<= 1 plan-hit) (<= plan-hit 2)
                (<= 1 call-hit) (<= call-hit 2))
  :named bounded-plan-key-domain))
(assert (! (and (<= 0 plan-action) (<= plan-action 3)
                (<= 0 selected-action) (<= selected-action 3)
                (<= 0 expected-action) (<= expected-action 3))
  :named four-action-domain))

; Scenario 0 leaves the nonmatching key symbolic so actor, site, and hit are
; all represented in the exact selector. Other scenarios use [0,10,1].
(assert (= plan-actor 0))
(assert (= plan-site 10))
(assert (= plan-hit 1))
(assert (= call-actor (ite (= scenario 0) call-actor 0)))
(assert (= call-site (ite (= scenario 0) call-site 10)))
(assert (= call-hit (ite (= scenario 0) call-hit 1)))
(assert (! (=> (= scenario 0)
  (not (and (= call-actor plan-actor)
            (= call-site plan-site)
            (= call-hit plan-hit))))
  :named nonmatching-key-scenario))
(assert (! (= exact-plan-key
  (and (= call-actor plan-actor)
       (= call-site plan-site)
       (= call-hit plan-hit)))
  :named exact-actor-site-hit-selection))
(assert (= implementation-plan-key
  (ite (= implementation 1)
       (and (= call-actor plan-actor) (= call-site plan-site))
       exact-plan-key)))

; Each positive scenario selects its named action. The negative-key scenario
; carries a fault plan so ignoring the hit component is observably different
; from the default continue action.
(assert (= plan-action
  (ite (= scenario 0) 2
    (ite (= scenario 1) 1
      (ite (= scenario 2) 0
        (ite (= scenario 3) 1
          (ite (= scenario 4) 2
            (ite (or (= scenario 5) (= scenario 6)) 3 0))))))))
(assert (= expected-action (ite exact-plan-key plan-action 0)))
(assert (! (= selected-action
  (ite implementation-plan-key plan-action 0))
  :named selection-by-exact-plan-key))

; The undeclared-action fixture advertises only continue. Every other fixture
; declares the action that exact selection produces.
(assert (= cap-continue true))
(assert (= cap-yield (not (= scenario 1))))
(assert (= cap-fault true))
(assert (= cap-cancel true))
(assert (! (= selected-action-declared
  (ite (= selected-action 0) cap-continue
    (ite (= selected-action 1) cap-yield
      (ite (= selected-action 2) cap-fault cap-cancel))))
  :named selected-action-capability))

; Scenario 7 presents a generation-0 reservation after reset published
; generation 1. All other first checkpoints are current in generation 0.
(assert (= token-generation 0))
(assert (= current-generation (ite (= scenario 7) 1 0)))
(assert (= generation-current (= token-generation current-generation)))
(assert (= sticky-before false))
(assert (! (= accepted-first
  (and (not sticky-before)
       (or selected-action-declared (= implementation 2))
       (or generation-current (= implementation 6))))
  :named capability-and-generation-admission))

; A successful first checkpoint atomically increments hit and sequence,
; appends exactly one event, then performs the selected terminal dispatch.
; Rejected and stale checkpoints do none of these things.
(assert (= first-hit-delta (ite accepted-first 1 0)))
(assert (= first-seq-delta (ite accepted-first 1 0)))
(assert (= first-event-delta (ite accepted-first 1 0)))
(assert (= first-dispatch-count (ite accepted-first 1 0)))
(assert (= first-dispatch-action selected-action))
(assert (= first-event-order (ite accepted-first 1 0)))
(assert (= first-dispatch-order
  (ite accepted-first
       (ite (and (= implementation 3) (= scenario 4)) 0 2)
       0)))
(assert (! (and (= first-hit-delta first-seq-delta)
                (= first-seq-delta first-event-delta)
                (= first-event-delta first-dispatch-count))
  :named commit-event-dispatch-cardinality))

; The first cancel publication makes cancellation sticky. In scenario 5, the
; actor's later checkpoint observes that state before registration: it emits no
; hit, sequence, or event and re-dispatches the same cancel action. Mutant 4
; loses the sticky state and admits the later default-continue checkpoint.
(assert (= sticky-after-first
  (and accepted-first (= selected-action 3) (not (= implementation 4)))))
(assert (= second-hit-delta
  (ite (= scenario 5) (ite sticky-after-first 0 1) 0)))
(assert (= second-seq-delta second-hit-delta))
(assert (= second-event-delta second-hit-delta))
(assert (= second-dispatch-count (ite (= scenario 5) 1 0)))
(assert (= second-dispatch-action
  (ite (= scenario 5) (ite sticky-after-first 3 0) 0)))

; Cancellation is sticky only in the cancelling actor's recorder. A global
; cancellation mutant incorrectly blocks actor 1's independent checkpoint.
(assert (= sibling-sticky-after-first
  (and (= scenario 5) (= implementation 7))))
(assert (= sibling-hit-delta
  (ite (= scenario 5) (ite sibling-sticky-after-first 0 1) 0)))
(assert (= sibling-seq-delta sibling-hit-delta))
(assert (= sibling-event-delta sibling-hit-delta))
(assert (= sibling-dispatch-action
  (ite (= scenario 5) (ite sibling-sticky-after-first 3 0) 0)))

; Scenario 6 resets after a recorded cancel. The new generation's recorder has
; no sticky cancellation, and its first continue checkpoint publishes once.
(assert (= reset-occurs (= scenario 6)))
(assert (! (= reset-generation (ite reset-occurs 1 0))
  :named reset-publishes-fresh-generation))
(assert (= sticky-after-reset
  (and reset-occurs sticky-after-first (= implementation 5))))
(assert (= post-reset-hit-delta
  (ite reset-occurs (ite sticky-after-reset 0 1) 0)))
(assert (= post-reset-seq-delta post-reset-hit-delta))
(assert (= post-reset-event-delta post-reset-hit-delta))
(assert (= post-reset-dispatch-action
  (ite reset-occurs (ite sticky-after-reset 3 0) 0)))

; Define every component both ways, then join them into the single predicate
; used by the reference and every mutation query.
(assert (= selection-violation (not (= selected-action expected-action))))
(assert (= capability-violation
  (and accepted-first (not selected-action-declared))))
(assert (= publication-violation
  (or (not (= first-hit-delta first-seq-delta))
      (not (= first-seq-delta first-event-delta))
      (not (= first-event-delta first-dispatch-count))
      (and accepted-first (not (= first-event-delta 1)))
      (and (not accepted-first) (not (= first-event-delta 0))))))
(assert (! (= dispatch-order-violation
  (and accepted-first (not (< first-event-order first-dispatch-order))))
  :named event-before-terminal-dispatch))
(assert (! (= sticky-cancel-violation
  (and (= scenario 5)
       (or (not sticky-after-first)
           (not (= second-hit-delta 0))
           (not (= second-seq-delta 0))
           (not (= second-event-delta 0))
           (not (= second-dispatch-count 1))
           (not (= second-dispatch-action 3)))))
  :named sticky-cancel-no-later-publication))
(assert (! (= actor-scope-violation
  (and (= scenario 5)
       (or sibling-sticky-after-first
           (not (= sibling-hit-delta 1))
           (not (= sibling-seq-delta 1))
           (not (= sibling-event-delta 1))
           (not (= sibling-dispatch-action 0)))))
  :named sticky-cancel-actor-scope))
(assert (! (= reset-clear-violation
  (and reset-occurs
       (or sticky-after-reset
           (not (= post-reset-hit-delta 1))
           (not (= post-reset-seq-delta 1))
           (not (= post-reset-event-delta 1))
           (not (= post-reset-dispatch-action 0)))))
  :named reset-clears-sticky-cancel))
(assert (= stale-generation-violation
  (and (= scenario 7)
       (or accepted-first
           (not (= first-hit-delta 0))
           (not (= first-seq-delta 0))
           (not (= first-event-delta 0))
           (not (= first-dispatch-count 0))))))
(assert (! (= checkpoint-action-violation
  (or selection-violation capability-violation publication-violation
      dispatch-order-violation sticky-cancel-violation actor-scope-violation
      reset-clear-violation stale-generation-violation))
  :named shared-checkpoint-action-violation))

; No bounded scenario violates the reference implementation.
(push)
(assert (= implementation 0))
(assert (! checkpoint-action-violation
  :named reference-action-counterexample-query))
(check-sat)
(pop)

; A global sticky flag incorrectly suppresses another actor's checkpoint.
(push)
(assert (= implementation 7))
(assert (= scenario 5))
(assert (! checkpoint-action-violation
  :named global-cancel-mutant-query))
(check-sat)
(pop)

; A selector that ignores hit applies a plan to a different occurrence.
(push)
(assert (= implementation 1))
(assert (= scenario 0))
(assert (= call-actor plan-actor))
(assert (= call-site plan-site))
(assert (not (= call-hit plan-hit)))
(assert (! checkpoint-action-violation
  :named ignore-hit-selector-mutant-query))
(check-sat)
(pop)

; An undeclared yield is accepted and published.
(push)
(assert (= implementation 2))
(assert (= scenario 1))
(assert (! checkpoint-action-violation
  :named capability-bypass-mutant-query))
(check-sat)
(pop)

; A fault is dispatched before its event is visible.
(push)
(assert (= implementation 3))
(assert (= scenario 4))
(assert (! checkpoint-action-violation
  :named dispatch-before-event-mutant-query))
(check-sat)
(pop)

; The first cancel does not fence the actor's later checkpoint.
(push)
(assert (= implementation 4))
(assert (= scenario 5))
(assert (! checkpoint-action-violation
  :named nonsticky-cancel-mutant-query))
(check-sat)
(pop)

; Reset carries cancellation into the new generation.
(push)
(assert (= implementation 5))
(assert (= scenario 6))
(assert (! checkpoint-action-violation
  :named reset-retains-cancel-mutant-query))
(check-sat)
(pop)

; An old-generation reservation mutates after reset.
(push)
(assert (= implementation 6))
(assert (= scenario 7))
(assert (! checkpoint-action-violation
  :named stale-generation-mutation-mutant-query))
(check-sat)
(pop)

; Non-vacuity: each admitted action publishes once before its dispatch.
(push)
(assert (= implementation 0))
(assert (= scenario 2))
(assert (= selected-action 0))
(assert accepted-first)
(assert (= first-event-delta 1))
(assert (< first-event-order first-dispatch-order))
(assert (not checkpoint-action-violation))
(assert (! true :named continue-action-nonvacuity-query))
(check-sat)
(pop)

(push)
(assert (= implementation 0))
(assert (= scenario 3))
(assert (= selected-action 1))
(assert accepted-first)
(assert (= first-event-delta 1))
(assert (< first-event-order first-dispatch-order))
(assert (not checkpoint-action-violation))
(assert (! true :named yield-action-nonvacuity-query))
(check-sat)
(pop)

(push)
(assert (= implementation 0))
(assert (= scenario 4))
(assert (= selected-action 2))
(assert accepted-first)
(assert (= first-event-delta 1))
(assert (< first-event-order first-dispatch-order))
(assert (not checkpoint-action-violation))
(assert (! true :named fault-action-nonvacuity-query))
(check-sat)
(pop)

(push)
(assert (= implementation 0))
(assert (= scenario 5))
(assert (= selected-action 3))
(assert accepted-first)
(assert (= first-event-delta 1))
(assert sticky-after-first)
(assert (= second-event-delta 0))
(assert (= second-dispatch-action 3))
(assert (= sibling-event-delta 1))
(assert (= sibling-dispatch-action 0))
(assert (not checkpoint-action-violation))
(assert (! true :named cancel-action-nonvacuity-query))
(check-sat)
(pop)

; Non-vacuity: reset clears cancellation and admits a new-generation action.
(push)
(assert (= implementation 0))
(assert (= scenario 6))
(assert reset-occurs)
(assert (not sticky-after-reset))
(assert (= post-reset-event-delta 1))
(assert (= post-reset-dispatch-action 0))
(assert (not checkpoint-action-violation))
(assert (! true :named reset-clear-nonvacuity-query))
(check-sat)
(pop)

; Non-vacuity: capability rejection is fail-closed without publication.
(push)
(assert (= implementation 0))
(assert (= scenario 1))
(assert (not selected-action-declared))
(assert (not accepted-first))
(assert (= first-event-delta 0))
(assert (not checkpoint-action-violation))
(assert (! true :named capability-rejection-nonvacuity-query))
(check-sat)
(pop)

; Non-vacuity: stale generation rejection leaves both dispatch and recorder
; publication absent.
(push)
(assert (= implementation 0))
(assert (= scenario 7))
(assert (not generation-current))
(assert (not accepted-first))
(assert (= first-hit-delta 0))
(assert (= first-seq-delta 0))
(assert (= first-event-delta 0))
(assert (= first-dispatch-count 0))
(assert (not checkpoint-action-violation))
(assert (! true :named stale-generation-rejection-nonvacuity-query))
(check-sat)
(pop)
