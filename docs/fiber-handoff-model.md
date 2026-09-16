# Fiber park handoff: a bounded executable specification

This specification accompanies [aspect-packs #137](https://github.com/chucklehead-dev/jolt-aspect-packs/issues/137).
The original failure was not simply an invalid queue entry: a wake published a
fiber before its original execution had returned to the scheduler. That fiber
could still change its state after publication. A model that treats parking as
one atomic operation silently removes this window.

The executable state machine is [fiber_handoff.qnt](../spec/fiber_handoff.qnt).
Its separate [test module](../spec/fiber_handoff_test.qnt) contains readable
scenarios, reachability predicates, and intentional mutations. The prose here
is a reading guide, not a second copy of the model to keep synchronized.

## What the record means

There is one target fiber and one carrier, sharing a single `State` record.
`lifecycle` is Ready, Running, Parked, Done, or Dead. `owner` answers a different
question: is the fiber still executing its escape/unwind, or has the carrier
fully regained control? Ready does **not** imply carrier ownership.

`queued`, `head`, and `link` classify membership without exposing pointers.
In this singleton queue, the target is either the head or absent; its successor
link is clear. Successor/self link classifications exist for corruption
controls, not to claim that a singleton proves multi-entry queue correctness.

`parkHandoff` protects the period between committing a park and the scheduler
closing the handoff. `wakePending` remembers a wake privately. `continuation`
distinguishes a captured continuation, a state-machine step, and no continuation;
it does not model executable code or prove continuation semantics.

`publications` is a ghost counter for pending-wake publication. `events` is a
finite history of transition families, used only for coverage. `parkedOnce`
and `yieldedOnce` bound this model to one park and one yield/preemption cycle.
These are explicit model bounds, not runtime restrictions.

## Read the transitions in this order

1. `dequeue` removes a Ready head while the carrier owns execution, and clears
   membership/link metadata. `dispatch` gives execution to the fiber.
2. `parkCommit` changes Running to Parked and opens the handoff. Ownership
   remains with the fiber. Choosing Captured or SmStep abstracts the subsequent
   continuation/step installation; the installation microsteps are not checked.
3. `pendingWake` records a wake without changing lifecycle or queue membership.
   Multiple early wakes coalesce in the implementation; the model represents
   their observable effect once, not repeated ignored API calls.
4. `returnToScheduler` transfers execution ownership. It deliberately does not
   publish the pending wake or clear the handoff.
5. `publishPending` closes a still-Parked pending handoff and atomically makes
   the fiber Ready and queued, counting one publication. Alternatively,
   `closeUnwokenHandoff` closes an unwoken park; `lateWake` later publishes it.
6. `yieldEnqueue` deliberately makes the fiber Ready and queued **before**
   execution returns. This is a valid window because the carrier cannot dequeue
   while its own thread is still executing that fiber. Preemption uses the same
   abstract transition. The original park bug cannot be fixed by forbidding all
   fiber-owned Ready/queued states.
7. `finish` publishes Done/Dead and abstracts clearing the continuation before
   escape. Finishing during a park unwind is admitted as a conservative
   overapproximation (including both outcomes). Only after carrier return can
   `terminalCleanup` discard an obsolete pending wake without enqueueing.

The return/publication split is observable: other threads may wake after the
carrier has returned but before it acquires its queue mutex. Handoff-close and
pending publication/discard remain one action because the implementation holds
the same mutex throughout them. No action models an interleaving inside that lock.

## Source correspondence

Grounding revision: `casselc/jolt@3d6a291542af11f8741cb2bfd965e639d71281da`
(diagnostics PR #81, stacked on the scheduler repair).

| Model operation | Grounded implementation in `host/chez/fibers.ss` |
| --- | --- |
| `parkCommit` | `jolt-fiber-park-commit!`; direct/condition parking sites |
| `pendingWake`, `lateWake` | `jolt-fiber-resume/source` |
| `returnToScheduler` | return from `jolt-fiber-run`, after scheduler escape |
| `publishPending`, `closeUnwokenHandoff`, terminal discard | `jolt-fiber-complete-park-handoff!` |
| queue membership changes | `jolt-fiber-enqueue!/locked`, `jolt-fiber-dequeue!` |
| `dispatch` | `jolt-fiber-resume*`, `dispatch-running` |
| `yieldEnqueue` | `sa-fiber-yield`, preemption handler |
| `finish` | `jolt-fiber-finish!`, Done/Dead escape wrappers |
| continuation classification | `jolt-fiber-continuation-class`, `jolt-fiber-to-scheduler!`, state-machine park sites |

The condition parking entry point is `host/chez/locks.ss:509`, which calls
`jolt-fiber-park-commit! f 'condition-park` before leaving the waitable mutex.

The mutex model is atomic shared state, not a lock implementation. Pinned
carrier ownership and interrupt exclusion around yield are assumptions grounded
in the source. There is no crash/recovery, time, transport, raw pointer, ring,
payload, serialization, multiple-fiber, or multiple-carrier model. This does not
prove memory safety, fairness, no lost wake across arbitrary repeated parks,
pool reset behavior, lock-order correctness, or correctness of every parking site.

## Safety and non-vacuity

The safety conjunction checks queued ⇒ Ready, off-queue ⇒ clear link, a Ready
queued head, handoff privacy, at-most-once pending publication, and terminal
cleanup with no queue/pending wake retained. Pending wakes must remain unpublished.
Terminal states may briefly retain a pending wake **before cleanup**; forbidding
that intermediate state would hide the discard path rather than verify it.

Reachability predicates cover every major action, both terminal outcomes, both
continuation families, the valid fiber-owned queue window, private early wake,
later publication, and terminal discard. Every predicate was reached in the
recorded sampled run. They are state reachability checks, not liveness proofs.

The intentionally buggy test enqueues an early wake while still fiber-owned:
the same `safety` predicate becomes false through `earlyWakePrivate`. Its next
pre-switch Parked mutation also violates queued ⇒ Ready. A sampled run with
`--step buggyStep --invariant safety` must exit nonzero; the production `step`
never contains that mutation. An additional link mutation and corrupt-head
rejection control exercise the queue predicates directly.

`dequeue` is guarded by Ready lifecycle and carrier ownership. It therefore
does not execute an illegal-state dequeue or model the runtime's fail-loud
rejected dispatch. Its rejection controls check the guard, not diagnostic or
recovery behavior after corruption; reachability and sampling are not proofs
across arbitrary repeated park/yield cycles.

## Running the small checks

Quint 0.32.0 was used. No Apalache/exhaustive verification was run.

```sh
quint typecheck spec/fiber_handoff.qnt
quint typecheck spec/fiber_handoff_test.qnt
quint test spec/fiber_handoff_test.qnt --max-samples 1 --seed 137
quint run spec/fiber_handoff_test.qnt --invariant safety \
  --witnesses readyQueuedFiberOwned earlyPending publishedOnce pendingDiscarded \
    dequeued dispatched parkCommitted returned closed lateWoken yielded preempted \
    finished cleaned doneReached deadReached capturedPark smPark \
  --max-samples 10000 --max-steps 25 --seed 137 --verbosity 1
quint run spec/fiber_handoff_test.qnt --step buggyStep --invariant safety \
  --max-samples 100 --max-steps 8 --seed 137
```

The last command is the expected-red control, not a normal green check.
The opt-in `make fiber-handoff-model` runs typechecking, deterministic tests,
and sampling only; it is not part of compiler CI or the default test target.
Use the workspace's pinned-Chez wrapper for Make even though these commands
do not build Jolt. If the relevant scheduler semantics change, revisit this
model and source map, then repeat its focused checks. Do not treat unchanged
compiler CI as model conformance evidence.

Tool detail: typed action parameters require an explicit `: bool` return type.
In Quint 0.32, `action.fail()` does not establish a subsequent state frame;
rejection tests therefore end at `.fail()`. Mid-scenario rejection expectations
use the pure guard, with separate end-of-test action rejection controls.

## Recorded bounded results

On the grounding revision plus these uncommitted model files, both files
typechecked and all 12 deterministic tests passed. The 10,000-trace, 25-step
sampled run found no safety violation. Selected reachability counts were:
fiber-owned Ready/queued 3,993; early private wake 1,214; pending publication
1,021; terminal pending discard 799. All 18 requested witnesses had nonzero
coverage. The buggy-step run failed as expected at step 4, immediately after
early enqueue. These results are sampled evidence, not an exhaustive proof.

The complete opt-in Make target was also run successfully through the pinned
Chez wrapper, reusing the diagnostics worktree's pinned makes bootstrap with
`M=/home/chuck/ai-src/worktrees/jolt-fiber-dispatch-diagnostics-137/.cache/makes`
to avoid a fresh bootstrap download.
