# Executor shutdown admission invariant

Checked on 2026-07-23 with Chiasmus/Z3 and the Chez runtime tests.

This is a bounded linearizability argument for the host executor's queue
boundary, not a proof of Chez scheduling or arbitrary Java concurrency.

## Source facts

- `host/chez/java/concurrency.ss` stores the shutdown flag, two-list FIFO queue,
  queue mutex, condition variable, and live-worker count in one executor state.
- Workers drain queued jobs before treating `shutdown + empty` as their exit
  condition.
- `executor-enqueue!` now tests shutdown and appends while holding the same queue
  mutex.
- `executor-shutdown!` publishes shutdown and wakes workers while holding that
  mutex.
- Both `execute` and `submit` use `executor-enqueue!`; a losing admission throws
  `java.util.concurrent.RejectedExecutionException` synchronously.

The linearization point is therefore acquisition of the queue mutex:

1. enqueue wins first: its task is visible in the queue and workers drain it,
   including during orderly shutdown; or
2. shutdown wins first: every later enqueue observes the flag and is rejected.

There is no third state in which shutdown has returned, all workers can exit,
and a later task is silently accepted.

## Checked models

| Model | Expected | Result meaning |
| --- | --- | --- |
| `executor-shutdown-admission-buggy.smt2` | SAT | Historical split publication/admission admits a task after worker exit. |
| `executor-shutdown-admission-corrected.smt2` | UNSAT | No accepted enqueue can linearize after shutdown returns in the bounded model. |
| `executor-shutdown-admission-nonvacuity.smt2` | SAT | The corrected gate still accepts and drains pre-shutdown work while rejecting later work. |

The executable control is the `concurrency` row in `test/chez/unit.edn`: both
`execute` and `submit` throw the named rejection after `.shutdown`, while the
existing termination row proves a task accepted before shutdown still drains.

## Limits

- The model assumes the queue mutex is mutually exclusive and released on a
  thrown Jolt value, as supplied by Chez `with-mutex`.
- It covers orderly `shutdown`, `close`, and the admission side of
  `shutdownNow`. It does not claim that `shutdownNow` interrupts a task already
  running; Jolt does not yet model Java thread interruption at that boundary.
- Worker fairness is a runtime assumption. The proof establishes that accepted
  work remains visible and is not orphaned by the shutdown admission race; it
  does not put a wall-clock bound on when a runnable worker executes it.
