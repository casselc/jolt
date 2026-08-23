# JS0 — Functional SCI on Jolt

## Decision

**Verdict: REVISE.**  The central feasibility question is answered positively
for pure, interpreter-resident agent evaluation: Jolt now runs a real persistent
`sci.core` Context, projects narrow host wrappers, keeps two contexts separate,
records/replays semantic operation leaves, and truly interrupts a tight runaway
SCI loop.  The milestone must not be called PASS yet because the Context uses
SCI's broad standard-core default plus a deny list rather than a reviewed,
explicitly allowlisted capability catalog, and nested Jolt interruption has an
identified timer-restoration defect.  Neither limitation is hidden by this
evidence.

## Coordinates and baseline

| item | coordinate/result |
| --- | --- |
| Jolt | `615e52517042d62d0f92fb55f78a24e89bfe7af8` (local `main`, `origin/main`) |
| upstream/base | same commit; this checkout has no separate upstream remote |
| vendored SCI | `32d62a5136ad3dc148588752f5bcc4cc30b14752` |
| Chez evidence lane | Linux, Chez Scheme `10.4.1` (`/usr/local/bin/scheme`) |
| source compatibility gate | **417/424** forms; preserved gate passes its 416 floor |
| functional SCI path | **works**: normal `require` → `sci/init` → repeated `sci/eval-string*` |

The source-form gate and functional result are intentionally different claims.
The former remains a lenient source-loading signal; the latter exercises SCI's
ordinary dependency path and a real Context.

### Load-path blockers fixed

1. SCI's ordinary JVM `deftype` expansion references private
   `clojure.core/imap-cons`; Jolt now exposes the corresponding core Var.
2. SCI's printer reads private `clojure.core/system-newline`; Jolt exposes the
   LF platform value.
3. SCI's copy-var macro can quote a resolved Class value.  The Jolt emitter now
   reconstructs quoted Classes through `jolt-class-for`, rather than rejecting
   the value as an unsupported quoted literal.
4. SCI records `Thread/currentThread().getId()` in Context setup; Jolt's thread
   handle now provides `getId`.
5. SCI's optimized arithmetic invokes `clojure.lang.Numbers/*`; Jolt now maps
   those methods to its existing numeric-tower operations.

These are general Clojure/JVM-host compatibility changes, not JS0 test
special-cases.

## Demonstrated behavior

`test/chez/js0-sandbox-test.clj` exercises the experimental trusted facade in
`jolt-core/jolt/sandbox.clj`.

* Repeated evaluation in one Context retains `def` state; closures, local
  functions, threading, collections, and lazy `map` realized by `vec` work.
* A host fixture exposes only `project/read`, `project/write`, and
  `project/inc*` wrappers.  The backing functions and `jolt.sandbox`/`jolt.host`
  names are not projected.
* Context A has definitions and `project/read`; Context B has neither.  Their
  state and authority differ.
* Operations carry `:pure`, `:observation`, or `:actuation` classification.
  Record mode stores ordered in-memory receipts `{id args result|error}`.
  Replay executes surrounding SCI source while substituting receipt values and
  never invokes the fixture host function.
* Observation replay returns the historical value after the fixture world is
  changed.  Actuation replay reconstructs its return without another write.
  A helper containing read and write is replayed at its operation leaves.
  Changed args, wrong/exhausted calls, unconsumed receipts, unreconstructable
  values, and recorded host errors fail closed.
* The representative denial slice covers bare and qualified `eval`,
  `load-string`, and `require`; Jolt FFI/process/fs names; `System/getenv`; and
  direct trusted-namespace references.  This establishes only the listed
  probes, not bb4t's 96-case corpus or a full static security proof.
* A worker evaluating `(loop [] (recur))` inside
  `jolt.host/run-interruptible` is interrupted, returns rather than merely
  timing out, and the same SCI Context subsequently evaluates `(+ 1 2)`.

## Latency observations

One warm Linux run, measured inside one already-started Jolt process with
`System/nanoTime`; milliseconds, not a benchmark or percentile claim:

| action | ms |
| --- | ---: |
| SCI Context creation | 0.323 |
| first simple eval | 0.817 |
| second persistent eval | 0.411 |
| small helper/composition | 1.564 |
| semantic operation | 0.442 |
| record operation | 0.465 |
| replay operation | 0.435 |

Nothing in this single warm sample is surprising for an interactive REPL.

## Verification performed

```text
make remint CHEZ=/usr/local/bin/scheme
make selfhost CHEZ=/usr/local/bin/scheme
/usr/local/bin/scheme --script host/chez/run-sci.ss
JOLT_CHEZ=/usr/local/bin/scheme JOLT_QUIET=1 ./bin/jolt run test/chez/js0-quote-class-literal-test.clj
JOLT_CHEZ=/usr/local/bin/scheme JOLT_QUIET=1 ./bin/jolt -Sdeps '<SCI paths/deps>' run test/chez/js0-sandbox-test.clj
```

Results: seed remint converged; self-host fixpoint held; SCI gate was 417/424;
both JS0 tests printed `OK`.

## Remaining gaps and nonclaims

* `run-interruptible` is cooperative at Chez Scheme call back-edges.  It cannot
  force-stop a thread resident in a blocking/native foreign call.  It also has
  an identified nested-use defect: an inner invocation disarms the outer timer.
  JS0 proves the tight pure-loop case only.
* The current sandbox is deliberately experimental and uses SCI's standard
  language environment plus a deny list.  JS1 must replace this with a
  data-only, reviewed ContextSpec allowlist and canonical authority coordinate.
* There is no durable journal, session resume, filesystem capability, Samizdat,
  Mycelium, bbagent migration, or full bb4t catalog here.
* The bb4t authority artifact was produced against a newer SCI revision.  Its
  96 cases cannot be claimed as cross-runtime parity from this slice.
* Only Linux/Chez 10.4.1 was executed.  macOS, Windows, release-image behavior,
  and interrupted foreign calls are unexecuted lanes.

## Recommendation and stop gate

Do not begin Samizdat integration.  The smallest next experiment after the two
REVISE items are addressed is JS1: replace only Samizdat's model-facing
live-image eval with one persistent Jolt/SCI Context, retaining its trusted
developer REPL.

Promote bb4t's profile attenuation, host-dispatch recheck, ordered receipt
divergence (`operation`, `args`, `exhausted`, `unconsumed`), historical-error,
canonical-value, and interruption-health tests into a shared cross-runtime
conformance suite rather than reimplementing them ad hoc.
