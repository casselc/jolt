# Timed latch deadline invariant

Checked on 2026-07-28 against the Jolt proposal fork based on
`46e1f74fc14f29283586900ef4b98c45375c0500`, with Chez 10.4.1,
Chiasmus/Z3, the host gate, and the public Clojure-facing unit suite.

This is a bounded result-selection argument for timed futures, promises, and
agent `await-for`. It is not a real-time scheduling proof.

## Contract

For a mutex-protected latch with one absolute deadline:

1. state already ready when the waiter acquires the mutex returns the value;
2. `condition-wait` returning true means the condition woke the waiter before
   the timeout, so the waiter rechecks state under the mutex; and
3. `condition-wait` returning false fixes this observation as a timeout.

The third rule is load-bearing. Chez releases the supplied mutex while waiting
and reacquires it before `condition-wait` returns. A producer can therefore:

1. complete strictly after the deadline;
2. acquire the mutex before the timed-out waiter reacquires it;
3. publish ready state; and
4. release the mutex so the waiter finally returns from `condition-wait`.

The historical future and promise paths inspected ready state again at step 4.
That turned the post-deadline completion into a successful timed deref.
`await-for` made the equivalent final queue/running-state check and could turn
the same race into `true`.

`jolt-wait-until-ready?` now centralizes the rule. A true condition result
loops and rechecks state. A false result returns false without inspecting state
again. Future deref, promise deref, and agent `await-for` all use that helper.
An eventual completion remains observable by a later deref or await; it simply
cannot retroactively change the timed call's result.

## Native evidence that exposed the bug

The first six-target jolt-tcp run using the shared immutable Chez toolchain,
[run 30402654336](https://github.com/casselc/jolt-tcp/actions/runs/30402654336),
passed on exact jolt-tcp source
`f571c3b725753c54acd656400a546ae640965423`.

A same-SHA warm-cache rerun,
[run 30403041301](https://github.com/casselc/jolt-tcp/actions/runs/30403041301),
failed the same assertion on both macOS architectures:

- the test's close arity had started and then slept for 150 ms;
- `stop-server` supplied a 25 ms timeout;
- expected error type: `:teensyp.server/stop-timeout`;
- actual error type: `nil`; and
- cleanup completed and the later idempotent stop observed the completion.

Linux and both native Windows lanes passed on that same revision. Every
unrelated TCP and Hegel property passed, including the monotonic wake-cursor
latency gate. Cache warmth changed scheduling pressure; it did not change the
source or dependency graph. The failure therefore remains concurrency evidence,
not a toolchain-cache defect.

The source diagnosis was the final state checks in
`jolt-future-deref-timed`, `jolt-promise-deref-timed`, and
`jolt-agent-await-for` in `host/chez/java/concurrency.ss`.

## Executable controls

`test/chez/timed-deref-deadline-test.ss` avoids relying on scheduler luck:

1. the waiter owns the latch mutex and announces entry;
2. the controller's subsequent mutex acquisition proves the waiter reached
   `condition-wait` and released it;
3. the controller holds that mutex beyond the deadline, publishes readiness,
   and releases it; and
4. the waiter then reacquires the mutex and observes the condition result.

The historical final-recheck control returns true under that schedule. The
corrected helper returns false under the identical schedule. Separate controls
prove that state ready at entry and a signal before the deadline still return
true.

Three `test/chez/unit.edn` rows exercise the public paths:

- promise timed deref returns its timeout sentinel, then a later deref returns
  the delivered value;
- future timed deref does the same; and
- agent `await-for` returns false, while a later `await` observes the drained
  action.

Run the focused gates with the pinned compiler:

```sh
CHEZ=/path/to/chez-10.4.1/bin/chez make timedderef
CHEZ=/path/to/chez-10.4.1/bin/chez make unit
```

The focused forced-schedule gate reports `4/4 passed`.

## Checked models

The model uses four ordered events: entry check, deadline, completion, and
mutex reacquisition. It abstracts future/promise payloads and agent queue state
to the same ready predicate because the implementation shares exactly that
wait rule.

| Model | Standalone Z3 | Chiasmus | Meaning |
| --- | --- | --- | --- |
| `timed-deref-deadline-buggy.smt2` | SAT | SAT | Pinned witness: entry 0, deadline 1, late completion 2, reacquisition 3; the final recheck returns the value. |
| `timed-deref-deadline-corrected.smt2` | UNSAT | UNSAT | No completion strictly after the deadline can produce a value under the corrected result rule. |
| `timed-deref-deadline-nonvacuity.smt2` | SAT | SAT | Ready-at-entry, pre-deadline signal, and post-deadline timeout paths all remain reachable. |

The corrected Chiasmus unsat core contains
`valid_deadline`, `entry_state_observation`, `condition_wait_result`,
`timeout_is_terminal`, `late_completion_definition`,
`post_deadline_value_definition`, and `post_deadline_value_query`.

To reproduce the standalone verdicts without modifying the checked files:

```sh
for f in test/chez/formal/timed-deref-deadline-*.smt2; do
  { sed -n '1,$p' "$f"; printf '(check-sat)\n'; } | z3 -in
done
```

Expected order: `sat`, `unsat`, `sat`.

## Limits

- The model assumes Chez's documented contract: `condition-wait` returns false
  for timeout, true for condition wake, and reacquires the mutex before return.
- Mutex exclusion, condition delivery, and the OS scheduler remain runtime
  assumptions. Reacquiring a mutex or getting scheduled can delay the physical
  return past the deadline; the proved claim is which result wins, not hard
  real-time latency.
- The corrected counterexample query assumes the waiter performed its initial
  protected state check before the deadline. State already ready when that
  first check finally runs still wins, matching the public deref contract; the
  model isolates the post-wait reacquisition race observed in jolt-tcp.
- `ms->deadline` currently expresses the relative API timeout as an absolute
  `time-utc` value accepted by Chez. Wall-clock adjustment behavior is outside
  this model; adopting a monotonic-to-relative wait loop would be a separate
  clock-source change.
- The model does not prove future interruption, agent fairness, TCP shutdown,
  or cleanup liveness. Their owning suites consume this latch result as an
  assumption and retain their own lifecycle evidence.
