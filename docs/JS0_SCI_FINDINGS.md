# JS0 SCI — current-runtime addendum

## Record scope

This is a new evidence record for branch `js1-runtime-current-upstream`, derived
from an initially clean `upstream/main` at `ea3313a0` on 2026-08-24. It does not
amend the historical JS0 freeze (`04dd42db`) or post-JS0 language-surface change
(`619ef196`), and it does not claim that either historical record ran against
this baseline.

The implementation was re-derived from those two revisions against current
source rather than cherry-picked. No tag, historical branch, vendor pin,
submodule, or upstream configuration was changed.

## Current-runtime result

**PASS for the focused JS0 evaluator contract.** Current Jolt can load SCI's
ordinary source path and create persistent, isolated SCI Contexts with a closed
positive language allowlist, ContextSpec profile maxima, explicit capability
authorization, dispatch-time rechecks, inert authority descriptions, canonical
receipts, fail-closed replay, cooperative interruption, and a trusted inert
language-surface coordinate.

The pinned current language coordinate remains:

```text
js0-lang/v1:[:map [[:jolt.sandbox.surface/count 156] ... [:jolt.sandbox.surface/version 1]]]
```

`test/chez/js0-sandbox-test.clj` pins the complete string rather than this
abbreviation, and verifies that it is independent of map iteration and caller
print bindings.

## Re-derived compatibility changes

SCI's current vendored source at `32d62a5` needs four general host seams:

1. `clojure.core/imap-cons`, referenced by SCI's ordinary record/deftype path,
   resolves to Jolt's existing `conj` semantics.
2. Private `clojure.core/system-newline`, read by SCI's printer, is the runtime's
   portable LF value.
3. `Thread/currentThread().getId()` returns Chez's stable numeric id for the
   current thread.
4. SCI's optimized numeric path can call the required
   `clojure.lang.Numbers` unary, binary, predicate, and comparison statics; each
   routes to Jolt's existing numeric-tower operator.

These host registrations do not grant SCI authority. `jolt.sandbox` supplies
only the reviewed pure symbols and per-context `project/*` wrappers, and every
wrapper checks current authorization independently of projection.

## Deliberately omitted superseded work

* **Quoted Class literals:** no backend edit or JS0 quote test was reintroduced.
  Current upstream already has `form-class-value?` handling in
  `jolt.backend-scheme/emit-quoted`, rebuilding through `jolt-class-for`; that is
  the more complete current mechanism and remains unchanged.
* **Time-zone/TZ work:** no historical TZ change was reintroduced. Current
  upstream owns process-global TZ save/restore and serialization in
  `host/chez/java/tz-primitives.ss`; none of those files changed here.

## Authority and replay contract

Named profiles have explicit closed capability maxima:

* `:agent/minimal`: no semantic operations;
* `:agent/project-read`: exactly project read/list/search/stat;
* `:agent/project-develop`: those four plus project edit.

Context creation enforces `requested ⊆ authorized ⊆ profile maximum`, and every
authorized ID must name a supplied operation. Projection is not authorization:
all supplied wrappers may be present, but a call takes one state snapshot and
rechecks its ID against the current effective set. The state swap in `revoke!`
is the revocation linearization point; a dispatch observes authority wholly
before or after that swap. Forks derive from current authority and receive no
parent SCI definitions or receipts.

Receipts admit only nil, booleans, strings, exact integers, keywords, symbols,
vectors, and maps recursively. Floats, ratios, lists/lazy seqs, functions,
references, classes, and opaque host values are rejected. Map entries and
coordinate forms are canonicalized independent of map order and print limits.
Replay validates operation and arguments before advancing its cursor, never
calls the host for replayed observations/actuations/errors, rejects exhaustion
and leftovers, and lets pure operations run without transcript entries.

This is an in-memory evaluator protocol, not a durable receipt format or a
scheduler/simulation policy. Scheduling, search, faults, replay worlds, and
other simulation policy remain outside core.

## Nested interruption contract

`jolt-run-interruptible` now tracks active timer borrows in an owner-tagged,
per-thread dynamic stack. Chez thread parameters are inherited, so the owner tag
makes a parent's inherited stack empty in a child. Installing and arming the
handler activates one borrow frame; every exit crosses the dynamic-wind
after-thunk, which disarms, pops, and restores it.

Terminal behavior is the same for normal return, a body throw, the interrupt
escape, and a fiber park unwind. A real off-fiber nested exit re-arms the
restored outer poll tick. During a park, enclosing after-thunks immediately
continue unwinding and leave the carrier timer disarmed. Fiber exits retain the
existing scheduler-quantum rearm, so this change does not widen the scheduler's
starvation window.

There is no queue to drain and no background resource to shut down: a terminal
extent disarms its borrowed tick, and the regression workers are joined after
their terminal state is observed. Fairness assumptions are limited to Chez
eventually scheduling each forked OS thread and polling engine timers at
procedure-call/loop back-edges. Blocking or native foreign calls remain only
cooperatively interruptible when they return to Scheme.

## Source-loading classification

The four `host/chez/*.ss` edits are runtime-loaded host behavior. Although
`jolt.sandbox` lives under `jolt-core/`, it is not one of the namespaces in
`ei-compiler-ns-files` or `ei-prelude-ns-files` in
`host/chez/emit-image.ss`; it is isolated and loaded only when explicitly
required with SCI dependencies available. Therefore this change does not alter
the checked-in seed and `make remint` is not required. The self-host fixpoint was
still run and remained byte-identical.

## Verification on this exact working tree

Environment: Linux, Chez Scheme 10.4.1 at `/usr/local/bin/scheme`; submodules at
their current upstream pins, including SCI `32d62a5`.

```text
git diff --check
  PASS

sh host/chez/manifest-check.sh
  manifest check: passed

make selfhost CHEZ=/usr/local/bin/scheme
  mint: 0 form(s) skipped
  self-host fixpoint: rebuild == checked-in seed

/usr/local/bin/scheme --script host/chez/run-sci.ss
  SCI load: 417/424 forms ok (7 fail), above the preserved 416 floor

/usr/local/bin/scheme --script test/chez/js0-interrupt-nesting-test.ss
  8/8 interrupt nesting assertions passed

JOLT_CHEZ=/usr/local/bin/scheme JOLT_QUIET=1 ./bin/jolt -Sdeps \
  '{:paths ["vendor/sci/src"] :deps {borkdude/edamame {:mvn/version "1.5.39"} org.babashka/sci.impl.types {:mvn/version "0.0.3"} borkdude/graal.locking {:mvn/version "0.0.2"}}}' \
  run test/chez/js0-sandbox-test.clj
  JS0-SANDBOX OK

JOLT_CHEZ=/usr/local/bin/scheme JOLT_QUIET=1 ./bin/jolt -Sdeps \
  '{:paths ["vendor/sci/src"] :deps {borkdude/edamame {:mvn/version "1.5.39"} org.babashka/sci.impl.types {:mvn/version "0.0.3"} borkdude/graal.locking {:mvn/version "0.0.2"}}}' \
  run test/chez/js0_authority_conformance_test.clj
  JS0-AUTHORITY-CONFORMANCE OK

/usr/local/bin/scheme --script host/chez/run-unit.ss
  unit gate: 1394/1394 passed

/usr/local/bin/scheme --script test/chez/values-test.ss
  values-test: 108/108 passed

/usr/local/bin/scheme --script host/chez/run-gosm.ss
  gosm gate: 116/116 passed

/usr/local/bin/scheme --script test/chez/thread-safety-test.ss
  thread-safety-test: 42 checks, 0 failures

/usr/local/bin/scheme --script test/chez/async-timer-test.ss
  16 checks, 0 failed

/usr/local/bin/scheme --script test/chez/fibers-test.ss
  fibers-test: 45 checks, 0 failures

/usr/local/bin/scheme --script test/chez/fibers-preempt-test.ss
  fibers-preempt-test: 66 checks, 0 failures

/usr/local/bin/scheme --script test/chez/fibers-monitor-test.ss
  fibers-monitor-test: 21 checks, 0 failures
  (the gate intentionally prints caught go-body `race` exceptions)
```

## Unrun gates and nonclaims

The full `make test`/`make ci`, release/debug standalone builds, tree-shake/AOT
lanes, the complete historical fiber matrix, macOS, Windows, and interrupted
native-call behavior were not run. `make remint` was not run because no source
in either seed emission list changed. The superseded quoted-Class and TZ tests
were intentionally not added to this current-runtime slice.

This result is not a full bb4t corpus proof, durable authorization service,
Samizdat claim, simulator, or guarantee that arbitrary native calls can be
cancelled.
