# Simulation worker-exit safety

## Bounded claim

For one successfully forked hooked-future worker, a controller-restoration
policy that waits for its `:exit` acknowledgement must not permit restoration
while that worker may still execute its application body.

This is a sufficiency claim for the external `jolt-sim` restoration guard that
will consume the new lifecycle event. The core runtime in this slice exposes
the evidence; it does not itself prevent a caller from restoring a controller
early.

The model covers snapshots formed from these lifecycle facts:

- `:spawn` registration succeeded and one worker was successfully forked;
- `:start` has admitted its start hook/body attempt;
- the worker's guarded setup/start/body attempt has or has not returned;
- cancellation has or has not won terminal publication;
- `:finish` has or has not been emitted by a worker that won publication;
- the proposed `:exit` acknowledgement has or has not been attempted; and
- the enclosing controlled scope has requested closure.

The domain is one successfully forked worker and at most the six ordered
milestones needed for the normal witness. It abstracts values, exceptions,
task identity, controller callback code, and the time between milestones. It
assumes the worker is not forcibly killed by an operation outside the future
API. Pre-fork failures are outside the Boolean model: the runtime balances an
attempted `:spawn` with `:abort`, and executable tests cover both a throwing
spawn callback and a synchronous `fork-thread` failure.

The observable violation is:

```text
restore-allowed AND body-may-still-execute
```

## Live source facts

The model uses these source facts from `host/chez/sim/runtime.ss`:

1. `jolt-hooked-future-claim-terminal!` lets exactly one worker/canceller begin
   terminal publication.
2. `jolt-sim-future-cancel` invokes `:cancel` after winning the claim and then
   publishes cancellation. It does not interrupt the worker.
3. Before this change, a worker that lost the claim skipped the complete
   `:finish`/publish branch and emitted no later acknowledgement.
4. Worker setup, start-hook, and body failures are all captured as the worker's
   result attempt, so they reach the same post-attempt path.
5. The new worker path waits for the shared future's published `done?` state,
   then attempts one supervisor-style `:exit` callback.
6. If the synchronous `:spawn` callback or the following `fork-thread` call
   fails, no worker escapes and the spawning thread attempts `:abort` before
   rethrowing the original failure.

The wait is necessary. A failed `claim-terminal!` only proves that another
thread started settlement; without waiting for `done?`, a worker could emit
`:exit` before the cancelling thread's `:cancel` callback or publication.

## Negated query and controls

All safety checks define the violation flag with equality and assert that same
flag. SAT therefore means a concrete restoration-while-executing witness;
UNSAT means none exists within this abstraction.

### Known-SAT current behavior

The current-behavior control models restoration from terminal ownership only:

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
(assert (! (=> finish_emitted attempt_returned)
           :named finish_after_attempt))
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
(assert (! (= violation
              (and restore_allowed body_may_execute))
           :named violation_definition))
(assert (! violation :named query_restore_while_executing))
```

`chiasmus_lint` returned no errors. `chiasmus_verify` returned SAT with the
source-realizable witness:

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

This is the concrete ordering `spawn -> start -> cancel -> scope close`, with
the non-interruptible body still running.

### Proposed worker-exit tracking

The corrected model retains successfully forked worker ownership from `:spawn`
through `:exit`:

```smt2
(declare-const spawned Bool)
(declare-const started Bool)
(declare-const attempt_returned Bool)
(declare-const canceled Bool)
(declare-const finish_emitted Bool)
(declare-const exit_emitted Bool)
(declare-const close_requested Bool)
(declare-const unexited Bool)
(declare-const body_may_execute Bool)
(declare-const restore_allowed Bool)
(declare-const violation Bool)

(assert (! (=> started spawned) :named start_after_spawn))
(assert (! (=> canceled spawned) :named cancel_after_spawn))
(assert (! (=> finish_emitted attempt_returned)
           :named finish_after_attempt))
(assert (! (=> finish_emitted (not canceled))
           :named canceled_worker_has_no_finish))
(assert (! (=> exit_emitted attempt_returned)
           :named exit_after_worker_attempt))
(assert (! (= unexited
              (and spawned (not exit_emitted)))
           :named unexited_definition))
(assert (! (= body_may_execute
              (and spawned started (not attempt_returned)))
           :named executing_definition))
(assert (! (= restore_allowed
              (and close_requested (not unexited)))
           :named proposed_restore_definition))
(assert (! (= violation
              (and restore_allowed body_may_execute))
           :named violation_definition))
(assert (! violation :named query_restore_while_executing))
```

`chiasmus_lint` returned no errors. `chiasmus_verify` returned UNSAT with:

```text
exit_after_worker_attempt
unexited_definition
executing_definition
proposed_restore_definition
violation_definition
query_restore_while_executing
```

The bounded interpretation is only that no modeled snapshot can both retain a
possibly executing body and satisfy the proposed restoration guard.

### Non-vacuity

The same schema was constrained to:

```clojure
{:spawned true
 :started true
 :attempt-returned true
 :canceled false
 :finish-emitted true
 :exit-emitted true
 :close-requested true}
```

`chiasmus_verify` returned SAT with `restore-allowed=true`,
`body-may-execute=false`, and `violation=false`. The corrected rule therefore
allows restoration after a normal exited worker; it is not a deny-all model.

A second SAT control changed only `started=false`, retaining
`attempt-returned=true`, `finish-emitted=true`, and `exit-emitted=true`. This
is the guarded worker-setup-failure path: the model permits
`spawn -> finish -> exit` without requiring a `:start` event, still with
`restore-allowed=true` and no violation.

## Executable oracle

The Scheme gates must establish facts the Boolean model abstracts:

- normal result, body failure, worker-setup failure, and start-hook failure each
  attempt exactly one `:exit`; setup failure takes the modeled
  `spawn -> finish -> exit` path without `:start`;
- cancel wins before the non-interruptible worker returns, yet `:exit` occurs
  only after `:cancel` and published cancellation;
- spawn-hook failure and synchronous worker-creation failure each fork no
  application worker and emit a balancing `:abort`, not `:exit`;
- a cancel-hook failure is latched without preventing cancellation publication
  or the later `:exit`;
- an exit-hook failure is latched without replacing result/cancellation; and
- the ordinary runtime still contains none of the simulation overlay.

Run:

```sh
make futuresimhook ordinaryfuturenosim simcontrollerabi simfficontrollerabi
```

The external `jolt-sim` adapter must separately track announced tasks through
either pre-fork `:abort` or post-worker `:exit`, and a scheduler wrapper must
drain every worker before its controlled thunk returns. The ABI events alone
do not impose that policy.

## Remaining gaps

This is not a proof of scheduler liveness, exhaustive interleaving coverage,
callback termination, arbitrary thread interruption, or physical OS-thread
termination. `:exit` proves that the hooked worker completed its guarded
setup/start/body attempt and observed terminal publication before the exit
callback. Under Chez's synchronous `fork-thread` contract, `:abort` records
that the failed call did not return a worker after an attempted registration;
the model does not prove the host primitive's failure atomicity. A controller
that blocks forever inside `:start`, `:finish`, `:cancel`, `:exit`, or `:abort`
can still prevent drainage. Controllers must not wait for `:exit` inside their
own `:cancel` callback because publication follows that callback.
