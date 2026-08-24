# JS0 SCI — current-runtime addendum

## Record scope

This is the current evidence record for branch `js1-runtime-current-upstream`,
rebased onto an initially clean `upstream/main` at `edda7aec` on 2026-08-24.
The implementation was re-derived against current source rather than
cherry-picked. No tag, historical branch, vendor pin, submodule, or upstream
configuration was changed.

The historical JS0 records are distinct and unamended; this file does not
claim that any of them ran against this baseline:

* the original JS0 freeze — tag `js0-functional-sci-freeze`;
* JS0 re-derived on upstream `c4547b5e` — tag
  `js0-functional-sci-upstream-freeze` (contains `04dd42db`), plus the
  post-JS0 language-surface change `619ef196` on branch
  `js0-functional-sci-upstream`;
* the immediately superseded current-runtime record (baseline `ea3313a0`) —
  `c83196f2`, reachable from tag `js1-runtime-pre-upstream-sci-merge`.

Only this file, on this branch, claims the `edda7aec` baseline.

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

## Compatibility seams are upstream at this baseline

SCI's vendored source at `32d62a5` needs four general host seams, and all four
are upstream behavior at `edda7aec` — this branch adds no host changes for
SCI:

1. `clojure.core/imap-cons`, referenced by SCI's ordinary record/deftype path,
   resolves to Jolt's existing `conj` semantics (upstream `92c110bc`,
   PR #721).
2. Private `clojure.core/system-newline`, read by SCI's printer, is the
   runtime's portable LF value (same upstream change).
3. `Thread/currentThread().getId()` returns Chez's stable numeric id for the
   current thread, and a Thread handle answers about the thread it stands for
   (upstream `726df564` PR #722, `dbb9fdb3` PR #727).
4. SCI's optimized numeric path can call the required
   `clojure.lang.Numbers` unary, binary, predicate, and comparison statics;
   each routes to Jolt's existing numeric-tower operator (upstream `c26a5de2`,
   PR #723).

The sandbox conformance suite pins these seams with discriminating rows,
including checked-overflow promotion (Jolt's one exact-integer type promotes
past 2^63 where the JVM's `Numbers` ops throw — the documented numeric-model
divergence), unchecked 64-bit wraparound (which must match the JVM exactly),
and `Numbers/equiv` as category-free value equality. A wrapping checked op, a
promoting unchecked op, or a category-checking `equiv` fails those rows.

These host behaviors do not grant SCI authority. `jolt.sandbox` supplies only
the reviewed pure symbols and per-context `project/*` wrappers, and every
wrapper checks current authorization independently of projection.

## Deliberately omitted superseded work

* **Quoted Class literals:** no backend edit or JS0 quote test was
  reintroduced. Current upstream already has `form-class-value?` handling in
  `jolt.backend-scheme/emit-quoted`, rebuilding through `jolt-class-for`; that
  is the more complete current mechanism and remains unchanged.
* **Time-zone/TZ work:** no historical TZ change was reintroduced. Current
  upstream owns process-global TZ save/restore and serialization in
  `host/chez/java/tz-primitives.ss`; none of those files changed here.

## Authority and replay contract

Named profiles have explicit closed capability maxima:

* `:agent/minimal`: no semantic operations;
* `:agent/project-read`: exactly project read/list/search/stat;
* `:agent/project-develop`: those four plus project edit.

Context creation enforces `requested ⊆ authorized ⊆ profile maximum`, and
every authorized ID must name a supplied operation. Projection is not
authorization: all supplied wrappers may be present, but a call takes one
state snapshot and rechecks its ID against the current effective set. The
state swap in `revoke!` is the revocation linearization point; a dispatch
observes authority wholly before or after that swap. Forks derive from
current authority and receive no parent SCI definitions or receipts.

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

The interrupt-borrow contract is upstream behavior at this baseline
(`5fe1813b`, PR #724) and is pinned by the portable upstream gate
`test/chez/interrupt-nesting-test.ss` (Make target `interruptnest`, part of
`make ci`). The branch-local duplicate `js0-interrupt-nesting-test.ss` is
removed: the portable gate is a strict superset, adding the child-thread
assertion that an inherited poll stack confers no ownership.

The contract, as pinned by that gate: `jolt-run-interruptible` tracks active
timer borrows in an owner-tagged, per-thread dynamic stack. Chez thread
parameters are inherited, so the owner tag makes a parent's inherited stack
empty in a child. Installing and arming the handler activates one borrow
frame; every exit crosses the dynamic-wind after-thunk, which disarms, pops,
and restores it.

Terminal behavior is the same for normal return, a body throw, the interrupt
escape, and a fiber park unwind. A real off-fiber nested exit re-arms the
restored outer poll tick. During a park, enclosing after-thunks immediately
continue unwinding and leave the carrier timer disarmed. Fiber exits retain
the existing scheduler-quantum rearm, so the scheduler's starvation window is
unchanged.

There is no queue to drain and no background resource to shut down: a
terminal extent disarms its borrowed tick, and the gate's workers are joined
after their terminal state is observed. Fairness assumptions are limited to
Chez eventually scheduling each forked OS thread and polling engine timers at
procedure-call/loop back-edges. Blocking or native foreign calls remain only
cooperatively interruptible when they return to Scheme.

## Acceptance lane

`make scievaluator` is the runnable acceptance target for this contract. It
executes the sandbox and authority conformance suites plus the current
upstream SCI functional and nested-interrupt gates' test files:

* `test/chez/js0-sandbox-test.clj` (also `make js0sandbox`),
* `test/chez/js0_authority_conformance_test.clj` (also `make js0authority`),
* `test/chez/sci-functional-test.clj` (the `scifunctional` gate's file),
* `test/chez/interrupt-nesting-test.ss` (the `interruptnest` gate's file).

The Clojure suites run through `bin/jolt` in script mode with the same
`-Sdeps` local-root form as `scifunctional`, so the lane does not depend on
the standalone-binary build. The lane is opt-in: `make ci` and `make test`
are unchanged. `test/chez/js0-evaluator-conformance.edn` (version 3) is the
assertion manifest for this record against this baseline.

## Source-loading classification

The evaluator slice of this branch is `jolt-core/jolt/sandbox.clj`, the
conformance tests, and this document. `jolt.sandbox` is not one of the
namespaces in `ei-compiler-ns-files` or `ei-prelude-ns-files` in
`host/chez/emit-image.ss`; it is isolated and loaded only when explicitly
required with SCI dependencies available. No seed-emitted source changed, so
the checked-in seed is unaltered and `make remint` is not required. The
self-host fixpoint was still run and remained byte-identical.

## Verification on this exact working tree

Environment: Linux, Chez Scheme 10.4.1 at `/usr/local/bin/scheme`; submodules
at their current upstream pins, including SCI `32d62a5`.

```text
git diff --check
  PASS

sh host/chez/manifest-check.sh
  manifest check: passed

make testbin CHEZ=/usr/local/bin/scheme
  build-jolt: stdlib-fasl skip jolt.sandbox — requires sci/core.{jolt,clj,cljc}
    from vendored SCI, absent from the install roots at build time
  build-jolt: wrote target/release/jolt

make scievaluator CHEZ=/usr/local/bin/scheme
  JS0-SANDBOX OK                       (includes the discriminating Numbers
                                        overflow/equiv rows)
  JS0-AUTHORITY-CONFORMANCE OK
  SCI-FUNCTIONAL-TEST OK
  9/9 interrupt nesting assertions passed

make selfhost CHEZ=/usr/local/bin/scheme
  mint: 0 form(s) skipped
  self-host fixpoint: rebuild == checked-in seed

/usr/local/bin/scheme --script host/chez/run-sci.ss
  SCI load: 417/424 forms ok (7 fail), above the preserved 416 floor

/usr/local/bin/scheme --script host/chez/run-unit.ss
  unit gate: 1425/1425 passed

/usr/local/bin/scheme --script test/chez/values-test.ss
  values-test: 108/108 passed

/usr/local/bin/scheme --script host/chez/run-gosm.ss
  gosm gate: 116/116 passed

/usr/local/bin/scheme --script test/chez/thread-safety-test.ss
  thread-safety-test: 42 checks, 0 failure(s)

/usr/local/bin/scheme --script test/chez/async-timer-test.ss
  16 checks, 0 failed

/usr/local/bin/scheme --script test/chez/fibers-test.ss
  fibers-test: 45 checks, 0 failure(s)

/usr/local/bin/scheme --script test/chez/fibers-preempt-test.ss
  fibers-preempt-test: 66 checks, 0 failure(s)

/usr/local/bin/scheme --script test/chez/fibers-monitor-test.ss
  fibers-monitor-test: 21 checks, 0 failure(s)
  (the gate intentionally prints caught go-body `race` exceptions)
```

## Manifest and standalone-build closure

The two branch-local manifest drifts are closed on this tree. The generated
`jolt.host` surface now includes the scoped-process export
`process-scope-run`. The stdlib-fasl closed-world manifest records
`jolt.sandbox` with the project's verified `skip` convention: build-time
source-root discovery finds the namespace, but its load requires
`sci/core.{jolt,clj,cljc}` from vendored SCI, which is intentionally absent
from the install roots. The standalone build therefore excludes this
evaluator-specific namespace rather than accidentally trying to bake it.

Both the host manifest gate and `make testbin` pass after these entries. This
closure changes neither the evaluator contract nor seed-emitted source, so it
does not require reminting.

## Unrun gates and nonclaims

The full `make test`/`make ci`, debug standalone build, tree-shake/AOT
lanes, the complete historical fiber matrix, macOS, Windows, and interrupted
native-call behavior were not run. `make remint` was not run because no source
in either seed emission list changed. The superseded quoted-Class and TZ tests
were intentionally not added to this current-runtime slice.

This result is not a full bb4t corpus proof, durable authorization service,
Samizdat claim, simulator, or guarantee that arbitrary native calls can be
cancelled.
