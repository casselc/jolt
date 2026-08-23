# JS0 — Functional SCI on Jolt

## Decision

**Verdict: PASS.** Jolt can host a persistent, explicitly capability-bounded,
cooperatively interruptible SCI evaluator for the JS0 contract. The context
starts from a positive pure-language allowlist; effective authority is data,
not projection accident; semantic dispatch independently rechecks it; and
nested interrupt regions restore their outer polling state. This is a JS0
evaluator result only, not Samizdat integration authorization.

## Coordinates and baseline

| item | coordinate/result |
| --- | --- |
| Jolt fork base | `615e52517042d62d0f92fb55f78a24e89bfe7af8` (`main`, `origin/main`) |
| JS0 branch / freeze tag | `js0-functional-sci` / `js0-functional-sci-freeze` (this evidence) |
| jolt-lang/jolt upstream main | `f09c008a` (not the fork baseline; upstream has independently advanced) |
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
* Profiles have closed explicit capability-ID maxima: `:agent/minimal` grants
  none; `:agent/project-read` grants only `:project/read`, `:project/list`,
  `:project/search`, and `:project/stat`; `:agent/project-develop` adds only
  `:project/edit`.  Thus a future observation such as `:network/get` is not
  admitted merely because it is an observation.
* Operations carry `:pure`, `:observation`, or `:actuation` classification.
  Effect selects replay treatment, never profile membership. Record mode stores
  ordered in-memory receipts `{id args result|error}` for observations and
  actuations; trusted pure operations execute normally during replay and do
  not consume a receipt.
* Observation replay returns the historical value after the fixture world is
  changed.  Actuation replay reconstructs its return without another write.
  A helper containing read and write is replayed at its operation leaves.
  Changed args, wrong/exhausted calls, unconsumed receipts, unreconstructable
  values, and recorded host errors fail closed.
* ContextSpec profiles enforce `requested ⊆ authorized ⊆ profile maximum`.
  The effective description and exact canonical coordinate use only inert data.
  A wrapper that remains projected after host-side capability revocation is
  refused by dispatch; a fork derives from current effective authority and
  cannot restore a revoked capability.
* The pure language is an explicit SCI `:allow` subset derived from bb4t's
  reviewed vocabulary. `letfn`, namespace discovery, `doc`, and
  `clojure.string` are deliberate JS0 exclusions; `loop`/`loop*` are included
  so the interruption test executes a real runaway computation.
* The representative denial slice covers bare and qualified `eval`,
  `load-string`, and `require`; Jolt FFI/process/fs names; `System/getenv`; and
  direct trusted-namespace references.  This establishes only the listed
  probes, not bb4t's 96-case corpus or a full static security proof.
* A worker evaluating a permitted `(loop [] (recur))` inside
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
/usr/local/bin/scheme --script host/chez/run-unit.ss
/usr/local/bin/scheme --script test/chez/js0-interrupt-nesting-test.ss
JOLT_CHEZ=/usr/local/bin/scheme JOLT_QUIET=1 ./bin/jolt run test/chez/js0-quote-class-literal-test.clj
JOLT_CHEZ=/usr/local/bin/scheme JOLT_QUIET=1 ./bin/jolt -Sdeps '<SCI paths/deps>' run test/chez/js0-sandbox-test.clj
JOLT_CHEZ=/usr/local/bin/scheme JOLT_QUIET=1 ./bin/jolt -Sdeps '<SCI paths/deps>' run test/chez/js0_authority_conformance_test.clj
```

Results: seed remint converged; self-host fixpoint held; SCI gate was 417/424;
the Chez unit gate was 1236/1236; nested interruption was 8/8; quote,
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
* There is no durable journal, session resume, filesystem capability, Samizdat,
  Mycelium, bbagent migration, or full bb4t catalog here. A receipt protocol
  version is required before durable transcripts can cross this freeze: older
  transcripts that recorded a host operation now classified `:pure` fail closed
  rather than being silently reinterpreted.
* The bb4t authority artifact was produced against a newer SCI revision.  Its
  96 cases cannot be claimed as cross-runtime parity from this slice.
* Only Linux/Chez 10.4.1 was executed.  macOS, Windows, release-image behavior,
  and interrupted foreign calls are unexecuted lanes.

## Recommendation and stop gate

Do not begin Samizdat integration automatically. The recommended next reviewed
experiment is JS1: replace only Samizdat's model-facing
live-image eval with one persistent Jolt/SCI Context, retaining its trusted
developer REPL.

Promote bb4t's profile attenuation, host-dispatch recheck, ordered receipt
divergence (`operation`, `args`, `exhausted`, `unconsumed`), historical-error,
canonical-value, and interruption-health tests into a shared cross-runtime
conformance suite rather than reimplementing them ad hoc.
