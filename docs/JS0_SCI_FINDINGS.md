# JS0 — Functional SCI on Jolt

## Decision

**Verdict: PASS.** Jolt can host a persistent, explicitly capability-bounded,
cooperatively interruptible SCI evaluator for the JS0 contract. The context
starts from a positive pure-language allowlist; effective authority is data,
not projection accident; semantic dispatch independently rechecks it; and
nested interrupt regions restore their outer polling state. This is a JS0
evaluator result only; no Samizdat claim is made or implied.

## Coordinates and baseline

| item | coordinate/result |
| --- | --- |
| Jolt base | `c4547b5e` (`upstream/main`), branch `js0-functional-sci-upstream` |
| semantic source | `0dfd069b` (final JS0 content, re-derived — not cherry-picked) |
| vendored SCI | `32d62a5136ad3dc148588752f5bcc4cc30b14752` |
| Chez evidence lane | Linux, Chez Scheme `10.4.1` (`/usr/local/bin/scheme`) |
| source compatibility gate | **417/424** forms; preserved gate passes its 416 floor |
| functional SCI path | **works**: `sci/init` → repeated `sci/eval-string*` on one Context |

The source-form gate and functional result are intentionally different claims.
The former remains a lenient source-loading signal; the latter exercises SCI's
ordinary dependency path and a real Context.

### Upstream supersessions retained

Upstream advanced past the original JS0 host patches in two places. The
re-derivation keeps the upstream mechanisms and adds only the JS0 behavior
tests:

1. **Quoted Class literals.** The original JS0 patch added a
   `java.lang.Class` arm to `emit-quoted`. Upstream's `emit-quoted` already
   reconstructs a quoted Class value through the runtime interner via
   `form-class-value?` → `(jolt-class-for "…")` — the same emit as the
   analyzer's `:class` leaf, with pooling and reader-form discrimination the
   JS0 arm did not have. `jolt-core/jolt/backend_scheme.clj` is therefore
   **unchanged**; `test/chez/js0-quote-class-literal-test.clj` passes against
   the upstream mechanism unmodified.
2. **Fiber-aware interrupt borrow.** Upstream's `jolt-run-interruptible`
   counts borrowed ticks against the fiber quantum, hands an expired quantum
   to the scheduler, and suspends the borrow across a park. That mechanism is
   **retained**. The JS0 nesting gate did prove one missing behavior in it —
   below.

### Host changes the JS0 tests proved necessary

1. SCI's ordinary JVM `deftype` expansion references private
   `clojure.core/imap-cons`; Jolt now exposes the corresponding core Var.
   Without it, `sci/impl/records.cljc:34` fails to compile.
2. SCI's printer reads private `clojure.core/system-newline`; Jolt exposes the
   LF platform value. Without it, `sci/impl/io.cljc:118` fails to compile.
3. SCI records `Thread/currentThread().getId()` in Context setup; Jolt's
   thread handle now provides `getId`. Without it, `sci.impl.opts/init`
   raises "No matching field found: getId".
4. SCI's optimized arithmetic invokes `clojure.lang.Numbers/*`; Jolt now maps
   those methods to its existing numeric-tower operators. Without it, the
   first arithmetic eval raises "No matching field or method:
   clojure.lang.Numbers/add".
5. **Off-fiber nested interrupt rearm.** Upstream's borrow restored the
   enclosing handler on exit from a nested `run-interruptible` but left the
   timer stopped off a fiber (`jolt-fiber-rearm-preempt!` is `set-timer 0`
   there), so an outer interrupt token was never polled again.
   `test/chez/js0-interrupt-nesting-test.ss` failed with "outer token was not
   polled after inner exit" on the unmodified upstream runtime. The patch adds
   an owner-tagged per-thread poll stack: a borrow's after-thunk re-arms the
   poll tick only when an enclosing borrow on the same thread had its handler
   restored; the fiber path and the park-time carrier disarm are unchanged.

Items 1–4 are general Clojure/JVM-host compatibility changes, not JS0 test
special-cases; item 5 is a correctness fix in the interrupt borrow's nested
extent, exercised by the nesting gate's normal-return, throw, and interrupt
terminal paths plus its two-worker token-isolation case.

## Demonstrated behavior

`test/chez/js0-sandbox-test.clj` exercises the experimental trusted facade in
`jolt-core/jolt/sandbox.clj`; `test/chez/js0_authority_conformance_test.clj`
pins the ContextSpec contract against the shared description in
`test/chez/js0-evaluator-conformance.edn`.

* Repeated evaluation in one Context retains `def` state; closures, local
  functions, threading, collections, and lazy `map` realized by `vec` work.
* A host fixture exposes only `project/*` wrappers. The backing functions and
  `jolt.sandbox`/`jolt.host` names are not projected.
* Context A has definitions and `project/read`; Context B has neither. Their
  state and authority differ.
* Profiles have closed explicit capability-ID maxima: `:agent/minimal` grants
  none; `:agent/project-read` grants only `:project/read`, `:project/list`,
  `:project/search`, and `:project/stat`; `:agent/project-develop` adds only
  `:project/edit`. Thus a future observation such as `:network/get` is not
  admitted merely because it is an observation.
* Operations carry `:pure`, `:observation`, or `:actuation` classification.
  Effect selects replay treatment, never profile membership. Record mode
  stores ordered in-memory receipts `{id args result|error}` for observations
  and actuations; trusted pure operations execute normally during replay and
  do not consume a receipt.
* Observation replay returns the historical value after the fixture world is
  changed. Actuation replay reconstructs its return without another write.
  A helper containing read and write is replayed at its operation leaves.
  Changed args, wrong/exhausted calls, unconsumed receipts, unreconstructable
  values, and recorded host errors fail closed.
* ContextSpec profiles enforce `requested ⊆ authorized ⊆ profile maximum`.
  The effective description and exact canonical coordinate use only inert
  data. A wrapper that remains projected after host-side capability
  revocation is refused by dispatch; a fork derives from current effective
  authority and cannot restore a revoked capability.
* The pure language is an explicit SCI `:allow` subset derived from bb4t's
  reviewed vocabulary. `letfn`, namespace discovery, `doc`, and
  `clojure.string` are deliberate JS0 exclusions; `loop`/`loop*` are included
  so the interruption test executes a real runaway computation.
* The representative denial slice covers bare and qualified `eval`,
  `load-string`, and `require`; Jolt FFI/process/fs names; `System/getenv`;
  and direct trusted-namespace references. This establishes only the listed
  probes, not bb4t's 96-case corpus or a full static security proof.
* A worker evaluating a permitted `(loop [] (recur))` inside
  `jolt.host/run-interruptible` is interrupted, returns rather than merely
  timing out, and the same SCI Context subsequently evaluates `(+ 1 2)`.

## Verification performed

The vendored `vendor/grenadine` checkout in this working tree is a pre-existing
dirty gitlink (v0.1.5 `b205b74` against the pinned v0.1.7 `77992327`) and does
not contain `grenadine.require-deps`, which upstream `jolt.deps` now requires
— so `bin/jolt run` cannot load the CLI's deps namespace here and the
documented `-Sdeps` invocation is unrunnable in this tree. The .clj gates were
run through `bin/jolt -e` with the documented SCI dependency roots
(`vendor/sci/src` plus the maven-extracted `edamame-1.5.39`,
`sci.impl.types-0.0.3`, `graal.locking-0.0.2`, and edamame's
`tools.reader-1.5.2` dependency) prepended to the install roots — the same
root set `-Sdeps` resolution produces. The dirty gitlinks were not modified.

```text
make selfhost CHEZ=/usr/local/bin/scheme
sh host/chez/manifest-check.sh
/usr/local/bin/scheme --script host/chez/run-sci.ss
/usr/local/bin/scheme --script host/chez/run-unit.ss
/usr/local/bin/scheme --script test/chez/js0-interrupt-nesting-test.ss
/usr/local/bin/scheme --script test/chez/values-test.ss
/usr/local/bin/scheme --script host/chez/run-gosm.ss
/usr/local/bin/scheme --script test/chez/thread-safety-test.ss
/usr/local/bin/scheme --script test/chez/async-timer-test.ss
/usr/local/bin/scheme --script test/chez/fibers-{test,state-test,chan-test,go-test,pool-test,io-test,sm-test,preempt-test,lock-test,monitor-test}.ss
/usr/local/bin/scheme --script test/chez/async-io-thread-test.ss
JOLT_QUIET=1 ./bin/jolt -e '(load-file "test/chez/js0-quote-class-literal-test.clj")'
# with the five SCI dependency roots prepended via jolt.host/set-source-roots!:
JOLT_QUIET=1 ./bin/jolt -e '<set-source-roots! form> (load-file "test/chez/js0-sandbox-test.clj")'
JOLT_QUIET=1 ./bin/jolt -e '<set-source-roots! form> (load-file "test/chez/js0_authority_conformance_test.clj")'
```

Results: self-host fixpoint held (rebuild == checked-in seed; no seed-baked
source changed, so no remint was required); manifest check passed; SCI gate
417/424; unit gate 1373/1394 — the 21 failures are all `(require 'jolt.deps)`
cases failing identically on the pristine tree (the grenadine gitlink skew
above), as is the `fibers-process-io-test` failure (the `vendor/process`
gitlink skew); values 108/108; gosm 116/116; thread-safety 42/42; async-timer
16/16; every listed fibers gate passed; nested interruption 8/8; quote,
functional sandbox, and authority conformance gates printed `OK`.

## Remaining gaps and nonclaims

* Interruption is cooperative at Chez Scheme call back-edges. It cannot
  force-stop a thread resident in a blocking/native foreign call. JS0 proves a
  tight pure SCI loop and nested timer restoration only.
* A child thread spawned *inside* an already-active interruptible extent is not
  a supported or executed JS0 pattern; JS0's concurrent-token evidence uses
  independently entered worker extents.
* The ContextSpec/catalog is deliberately small. It is not full bb4t corpus
  parity, durable policy storage, or an API stability promise. The shared
  contract description is `test/chez/js0-evaluator-conformance.edn`.
* There is no durable journal, session resume, filesystem capability,
  Samizdat, Mycelium, bbagent migration, or full bb4t catalog here — and no
  Samizdat claim of any kind follows from this result. A receipt protocol
  version is required before durable transcripts can cross this freeze: older
  transcripts that recorded a host operation now classified `:pure` fail
  closed rather than being silently reinterpreted.
* The bb4t authority artifact was produced against a newer SCI revision. Its
  96 cases cannot be claimed as cross-runtime parity from this slice.
* Only Linux/Chez 10.4.1 was executed. macOS, Windows, release-image behavior,
  and interrupted foreign calls are unexecuted lanes.
* The two vendored gitlink skews (`vendor/grenadine` v0.1.5 vs pinned v0.1.7,
  `vendor/process`) predate this branch and are unrelated to the JS0 content;
  they cost the `jolt.deps` unit cases, the process-IO fiber gate, and the
  literal `bin/jolt run` invocation documented in the test headers.
