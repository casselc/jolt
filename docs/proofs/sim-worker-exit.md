# Simulation worker-exit safety

## Bounded claim

For one successfully forked hooked-future worker, a controller-restoration
policy that waits for its successful `:exit` acknowledgement cannot permit
restoration while that worker may still execute its application body.

This is a sufficiency claim for the external `jolt-sim` restoration guard that
consumes the sim-image-only prerelease ABI 6 lifecycle seam. The runtime emits
the evidence and exposes only the unified
`install-controller! {:future f :ffi ffi :clock clock}` / `restore-controller!`
pair. One opaque strict-LIFO token owns all three effective controllers; there
are no public per-subcontroller install or restore operations.
`jolt.internal.sim/restore-controller!` is a **private-ABI** operation: the
runtime validates only that the presented token is the live, topmost
installation (stale/foreign/out-of-order tokens are rejected before any
mutation), but it does not itself decide, track, or wait for whether an
external controlled scope has drained enough to restore. That quiescence
policy — including waiting for this document's `:exit` acknowledgement before
calling `restore-controller!` — is the responsibility of the external `jolt-sim`
supervisor that consumes this seam, not a guarantee the runtime enforces on
its own.

The model covers snapshots formed from these facts:

- `:spawn` registration succeeded and one worker was forked;
- `:start` has admitted the worker's setup/start/body attempt;
- that attempt has or has not returned;
- cancellation has or has not won settlement;
- `:finish` has or has not been attempted by the worker that won settlement;
- the worker's `:exit` acknowledgement has or has not succeeded; and
- the enclosing controlled scope has requested closure.

It abstracts values, exceptions, task identity, callback code, and time between
milestones. It assumes no out-of-band thread termination. Pre-fork failures are
outside the Boolean model: executable tests require both a throwing `:spawn`
callback and a synchronous `fork-thread` failure to produce `:abort` without a
worker.

The queried violation is:

```text
restore-allowed AND body-may-still-execute
```

## Live source facts

The private overlay in `host/chez/sim/runtime.ss` establishes these facts:

1. `jolt-hooked-future-claim-terminal!` lets exactly one worker or canceller
   claim settlement.
2. `jolt-sim-future-cancel` publishes cancellation but does not interrupt the
   ordinary Chez worker.
3. Worker setup, start-hook, and body failures all return through one guarded
   attempt path.
4. A worker that loses settlement waits in
   `jolt-hooked-future-await-published!` until the winner publishes.
5. Only after its attempt has returned and settlement is observable does the
   worker attempt its supervisor-style `:exit` callback.
6. A failed synchronous `:spawn` callback or `fork-thread` call instead
   attempts `:abort` before rethrowing the original failure.
7. `jolt-sim-restore-controller!` validates strict LIFO identity under one
   mutex and otherwise trusts its caller: it carries no worker registry of its
   own and enforces no drain/quiescence condition beyond token validity. Any
   guarantee that restoration only happens once every worker spawned under
   that installation has exited is a property of the external caller (the
   `jolt-sim` supervisor), built on top of the `:exit` evidence below — not a
   property this file's `restore-controller!` proves by itself.

Waiting for publication before `:exit` is necessary. Losing the settlement
claim proves only that another thread began settlement; it does not prove that
the cancelling thread's callback has returned or that cancellation is visible.

## Negated query and controls

All safety models define the violation with equality and assert that flag. SAT
therefore means a concrete restoration-while-executing witness. UNSAT means no
such snapshot exists within this abstraction.

### Known-SAT terminal-only policy

This control releases ownership after terminal settlement alone:

```smt2
(declare-const spawned Bool)
(declare-const started Bool)
(declare-const attempt_returned Bool)
(declare-const canceled Bool)
(declare-const finish_emitted Bool)
(declare-const close_requested Bool)
(declare-const active_terminal Bool)
(declare-const body_may_execute Bool)
(declare-const restore_allowed Bool)
(declare-const violation Bool)

(assert (! (=> started spawned) :named start_after_spawn))
(assert (! (=> canceled spawned) :named cancel_after_spawn))
(assert (! (=> finish_emitted attempt_returned) :named finish_after_attempt))
(assert (! (=> finish_emitted (not canceled))
           :named canceled_worker_has_no_finish))
(assert (! (= active_terminal
              (and spawned (not (or canceled finish_emitted))))
           :named current_active_definition))
(assert (! (= body_may_execute
              (and spawned started (not attempt_returned)))
           :named executing_definition))
(assert (! (= restore_allowed
              (and close_requested (not active_terminal)))
           :named current_restore_definition))
(assert (! (= violation (and restore_allowed body_may_execute))
           :named violation_definition))
(assert (! violation :named query_restore_while_executing))
```

`chiasmus_lint` reports no errors on this spec. Solved against the checkpoint
that introduced this model, `chiasmus_verify` returned SAT:

```clojure
{:spawned true
 :started true
 :canceled true
 :finish-emitted false
 :attempt-returned false
 :close-requested true
 :active-terminal false
 :restore-allowed true
 :body-may-execute true
 :violation true}
```

The witness is `spawn -> start -> cancel -> scope close` while the
non-interruptible body still runs.

### Worker-exit policy

The corrected model retains ownership from successful `:spawn` through
successful `:exit`:

```smt2
(declare-const spawned Bool)
(declare-const started Bool)
(declare-const attempt_returned Bool)
(declare-const canceled Bool)
(declare-const finish_emitted Bool)
(declare-const exit_emitted Bool)
(declare-const close_requested Bool)
(declare-const unexited_worker Bool)
(declare-const body_may_execute Bool)
(declare-const restore_allowed Bool)
(declare-const violation Bool)

(assert (! (=> started spawned) :named start_after_spawn))
(assert (! (=> canceled spawned) :named cancel_after_spawn))
(assert (! (=> finish_emitted attempt_returned) :named finish_after_attempt))
(assert (! (=> finish_emitted (not canceled))
           :named canceled_worker_has_no_finish))
(assert (! (=> exit_emitted attempt_returned) :named exit_after_attempt))
(assert (! (= unexited_worker (and spawned (not exit_emitted)))
           :named unexited_definition))
(assert (! (= body_may_execute
              (and spawned started (not attempt_returned)))
           :named executing_definition))
(assert (! (= restore_allowed
              (and close_requested (not unexited_worker)))
           :named corrected_restore_definition))
(assert (! (= violation (and restore_allowed body_may_execute))
           :named violation_definition))
(assert (! violation :named query_restore_while_executing))
```

`chiasmus_lint` reports no errors on this spec. Solved against the checkpoint
that introduced this model, `chiasmus_verify` returned UNSAT with this core:

```text
exit_after_attempt
unexited_definition
executing_definition
corrected_restore_definition
violation_definition
query_restore_while_executing
```

The bounded result says only that a modeled snapshot cannot both retain a
possibly executing body and satisfy the exit-based restoration guard. The
runtime facts in the section above are unchanged since that checkpoint, so this
result still bounds the current ABI 6 `host/chez/sim/runtime.ss`; this revision
does not re-run the solver and claims no new SAT/UNSAT evidence beyond what is
recorded here.

### Non-vacuity

A normal lifecycle constrained to spawned, started, attempt-returned, finish,
exit, and close all true returned SAT with `restore-allowed=true`,
`body-may-execute=false`, and `violation=false`.

A pre-start setup-failure lifecycle constrained to `started=false` and the same
spawned, attempt-returned, finish, exit, and close facts also returned SAT with
restoration allowed and no violation. The corrected policy therefore permits
both normal `spawn -> start -> finish -> exit` and guarded
`spawn -> finish -> exit` completion; it is not a deny-all model.

## Executable oracle

The Scheme gates establish facts abstracted by the Boolean model:

- normal results, body failures, setup failures, and start-hook failures each
  attempt one `:exit`;
- cancellation can settle while a non-interruptible body still runs, but
  `:exit` follows both body-attempt return and published cancellation;
- spawn-hook and synchronous fork failures run no body and emit `:abort`;
- callback failures are supervisor-latched without replacing ordinary future
  results, exceptions, or cancellation;
- one future retains one controller snapshot and nested futures retain their
  parent task identity;
- `jolt-sim-restore-controller!` itself enforces only strict-LIFO token
  identity, nothing about worker quiescence — that policy lives entirely in
  the external `jolt-sim` supervisor, on top of the `:exit` evidence above; and
- ordinary images contain none of the private overlay.

Run:

```sh
make -j1 ordinaryfuturenosim futuresimhook simcontrolleratomic simimagesmoke
```

On 2026-08-01 this revision ran those focused gates on Linux x86-64 with
threaded Chez 10.4.1: `ordinaryfuturenosim` passed 53/53,
`futuresimhook` passed 60/60, `simcontrolleratomic` passed 97/97, and the
normal-vs-sim image smoke passed its isolated-overlay and distinct-cache-key
checks. The compiler-emission gate separately passed 4/4. No Windows result is
claimed by this record yet.

## Remaining gaps

This is not a proof of scheduler liveness, exhaustive interleaving coverage,
callback termination, arbitrary thread interruption, or physical OS-thread
termination. `:exit` says that no more application body can run after the
callback begins; the wrapper removes the physical Chez thread from the live
thread registry only when the callback returns. A failing `:exit` callback must
poison external restoration rather than count as an acknowledgement. A
controller that blocks forever in any callback can still prevent drainage.

The focused nested-FFI-during-proceed gate is a synthetic synchronous native
thunk witness: it proves that controller-phase reentry remains rejected while a
proceeded native phase can synchronously enter a nested controlled FFI call with
strict-LIFO proceed tokens. A bounded real `qsort`/SQLite-UDF callback fixture is
still pending and is not claimed by this record.

This document's model is scoped to future worker-exit safety only. It makes no
claim about the separate monotonic-clock domain-sharing behavior exercised by
`test/chez/sim-controller-atomic-test.ss` (nested composite installs sharing one
outermost scope's clock domain, and a fresh outermost scope's ability to start
that domain at any virtual origin) — that behavior is pinned by its own
executable assertions, not by a model in this file.
