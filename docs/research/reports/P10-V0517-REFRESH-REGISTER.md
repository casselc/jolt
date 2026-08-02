# P10 — v0.5.17 refresh register (P1 facts re-verified)

**Provenance:** `jolt-runtime-engineer` subagent, session
`ses_03fabf181ffey963aAQ9f2A0wU`, model `openai/gpt-5.6-sol` (high), 2026-08-01.
**Citation root:** `/home/chuck/ai-src/worktrees/jolt-v0517-reference` (`V17` —
upstream v0.5.17 at `da59e49dbe8c810e05aa2ce900a95c5a1ef0c9fe`, detached).
**Status:** UNREVIEWED working report; supersedes P1 citations where they differ.
From this point, charter citations should prefer V17 line numbers.
**Method:** read-only source audit; no builds, tests, edits, or git mutations.

---

# v0.5.17 Refresh Register

## 1. Ordinary `:invoke` evaluation order — **CONFIRMED**

- Analyzer preserves source operand order in `:fn` followed by a `mapv` of arguments. `V17/jolt-core/jolt/analyzer.clj:1030-1037`
- `needs-order?`/`ordered-call` still force observable operands through sequential Scheme `let*` bindings; backend explicitly notes Chez application order is unspecified. `V17/jolt-core/jolt/backend_scheme.clj:429-473`
- Dynamic calls order `[callee & args]` together. Optimized calls omit the callee only when statically known; argument ordering still uses `ordered-call`. `V17/jolt-core/jolt/backend_scheme.clj:878-899`; `V17/jolt-core/jolt/backend_scheme.clj:1029-1086`
- Collection invocation orders the computed collection before key/default operands. `V17/jolt-core/jolt/backend_scheme.clj:1051-1060`

## 2. IR annotation/source-metadata surface — **CHANGED**

- Load-bearing absence remains: no provenance, expansion-parent, site-ID, operation/resource-ID, or assumptions field; `:pos` remains the only source-position key in the optional annotation list. `V17/jolt-core/jolt/ir.clj:100-108`; `V17/jolt-core/jolt/ir.clj:149-168`
- However, "only `:pos` carries source metadata" is no longer literally true: a top-level `:def` receives both `:pos` and a `:meta` map containing `:line/:column/:file`; `:meta-expr` is rebuilt from that merged metadata. `V17/jolt-core/jolt/analyzer.clj:417-432`
- This duplication is Var/source-location metadata, not expansion lineage or durable semantic identity. Closed CSIR/provenance work remains new work. `V17/jolt-core/jolt/ir.clj:149-168`

## 3. Host interop operand order — **CONFIRMED**

- `:host-new` emits operands directly into `(host-new …)` without `ordered-call`. `V17/jolt-core/jolt/backend_scheme.clj:1271-1273`
- `:host-call` emits target and arguments directly into `jolt-host-call` or `record-method-dispatch`. `V17/jolt-core/jolt/backend_scheme.clj:1313-1322`
- Side-effecting constructor/method operand order remains host-dependent/opaque. `V17/jolt-core/jolt/backend_scheme.clj:429-432`
- Qualified static-method invocation is different: an ordinary `:invoke` specialization and orders its arguments. `V17/jolt-core/jolt/backend_scheme.clj:1064-1068`

## 4. Macro phase, call-site position, opaque expanders — **CONFIRMED**

- Macro expansion precedes special-form/interop/invocation dispatch; expansion recursively re-analyzed. `V17/jolt-core/jolt/analyzer.clj:961-973`
- Position propagation copies an unpositioned list expansion's call-site location, recursively per level; location, not lineage. `V17/host/chez/host-contract.ss:236-253`
- `&form`/`&env` dynamically installed; expander from resolved Var root invoked as runtime closure. `V17/host/chez/host-contract.ss:267-295`
- No macro-definition digest or expansion-parent on that path; no IR field. `V17/host/chez/host-contract.ss:285-295`; `V17/jolt-core/jolt/ir.clj:149-168`

## 5. Atom semantics — **CONFIRMED**

- Each atom owns value, watches, validator, per-atom mutex; `swap!` user function runs outside. `V17/host/chez/atoms.ss:14-24`
- `swap!` reads/computes outside the lock, validates before publication, retries identity (`eq?`) CAS; successful store under mutex is the linearization point. `V17/host/chez/atoms.ss:79-98`
- `reset!` and value-equality `compare-and-set!` publish under the same mutex. `V17/host/chez/atoms.ss:100-116`
- Watches run after publication, insertion order, outside the mutation lock; watch failure cannot roll publication back. `V17/host/chez/atoms.ss:65-69`; `V17/host/chez/atoms.ss:90-105`

## 6. Future/promise/delay settlement — **CONFIRMED**, with timeout-surface additions

- Future: worker success/failure linearizes at payload + `done?` publication under mutex; cancellation linearizes at `cancelled?` + `done?`; cancelled future does not interrupt/drain worker; late result ignored. `V17/host/chez/java/concurrency.ss:76-105`; `V17/host/chez/java/concurrency.ss:140-151`
- Timed deref uses absolute UTC deadline, rechecks after wakeups, returns timeout value if unsettled. `V17/host/chez/java/concurrency.ss:18-25`; `V17/host/chez/java/concurrency.ss:120-138`
- Promise: one-shot; value + `delivered?` publication under mutex is the linearization point; later deliveries return nil. `V17/host/chez/java/concurrency.ss:159-203`
- Delay: one forcing thread owns realization under mutex; success and exception terminal cached; failures rethrown without rerunning. `V17/host/chez/java/concurrency.ss:554-572`
- No scheduling fairness or bounded-settlement guarantee stated. `V17/host/chez/java/concurrency.ss:91-105`; `V17/host/chez/java/concurrency.ss:120-138`
- NEW: `TimeUnit` — seven units, truncating conversions, `sleep`; timeout/unit pairs normalized to ms. `V17/host/chez/java/concurrency.ss:27-74`
- Bounded `CountDownLatch.await`, executor `Future.get`, `awaitTermination`, `ReentrantLock.tryLock` honor timeout/unit; timed `Future.get` throws `TimeoutException`. `V17/host/chez/java/concurrency.ss:803-823`; `841-864`; `941-958`; `983-1000`
- `Thread.join` honors ms timeout, returns immediately for unstarted thread, absolute deadline, rejects negative timeouts. `V17/host/chez/java/concurrency.ss:732-787`
- These do NOT alter core future/promise/delay settlement behavior.

## 7. `jolt.host/mono-nanos` — **CHANGED** (new primitive)

- `mono-nanos` from Chez `current-time 'time-monotonic`; `time->nanos` = seconds×1e9 + nanosecond field, exact integer. `V17/host/chez/rt.ss:447-458`
- Origin arbitrary; declared guarantee: never steps; only differences for durations. `V17/host/chez/rt.ss:447-452`
- Representation nanoseconds; no 1ns physical resolution promised; actual resolution Chez/platform-dependent. `V17/host/chez/rt.ss:453-458`
- Wall time separate: `jolt.host/wall-nanos` (`time-utc`, ns since Unix epoch, may step under NTP). `V17/host/chez/rt.ss:441-457`
- `System/currentTimeMillis` wall-based; `System/nanoTime` delegates to `jolt-mono-nanos`. `V17/host/chez/java/host-static-methods.ss:259-273`

## 8. core.async — **CONFIRMED**

- Runtime-loaded stdlib overlay over native Chez primitives; `alts!`, pipelines, mult/mix/pub/sub. `V17/stdlib/clojure/core/async.clj:1-18`
- Native channels: mutex/condition blocking queues; `go`/`thread` real OS threads; blocking parking; shared heap. `V17/host/chez/java/async.ss:1-18`
- Channel state: queue, capacity/kind, closed, transducer, waiting-taker count, pending alt registrations. `V17/host/chez/java/async.ss:36-50`
- Non-priority `alts!` randomized start port; priority starts at port zero; one-shot claiming under channel→handler lock order. `V17/stdlib/clojure/core/async.clj:29-49`; `V17/host/chez/java/async.ss:85-98`
- `go-spawn` conveys dynamic bindings, clears inherited transactions, publishes non-nil result to capacity-one channel, closes on success or failure. `V17/host/chez/java/async.ss:495-525`

## 9. Dynamic-binding conveyance — **CONFIRMED**

- Per-thread identity-keyed stack in a Chez thread parameter; forked threads inherit; explicit snapshots. `V17/host/chez/dyn-binding.ss:4-22`
- `future-call` captures stack, clears inherited transaction, installs snapshot before body. `V17/host/chez/java/concurrency.ss:86-105`
- `Thread.start` and executor `submit`/`execute` same pattern. `V17/host/chez/java/concurrency.ss:744-760`; `919-930`

## 10. Telemetry — **CHANGED** (substantial primitive surface added)

- Low-level `jolt.host` observation surface: wall/monotonic clocks; CPU/real/GC counters; allocation/current/max memory; thread ID; Scheme version; machine type. `V17/host/chez/rt.ss:434-488`
- Prescribes wall start + monotonic elapsed for spans. `V17/host/chez/rt.ss:441-452`
- Does NOT implement canonical events, span/trace IDs, operation IDs, site IDs, replay coordinates. `thread-id` is host-thread identity, not semantic event identity. `V17/host/chez/rt.ss:455-488`
- No telemetry/OTel namespace under `stdlib/` or `jolt-core/`; changelog: primitives sufficient for a profiler, health endpoint, or external OTel exporter. `V17/CHANGELOG.md:36-59`

## (a) Compile spine — **CONFIRMED**

- `jolt.analyzer` → host-neutral `jolt.ir` → passes → `jolt.backend-scheme`. `V17/jolt-core/jolt/analyzer.clj:1-20`; `V17/jolt-core/jolt/ir.clj:1-8`; `V17/jolt-core/jolt/backend_scheme.clj:1-20`
- Runtime compilation: analyze, pass, emit. `V17/host/chez/compile-eval.ss:304-311`
- Bootstrap seed contains all three; joint byte-fixpoint seed. `V17/host/chez/seed/README.md:3-17`

## (b) Simulation/controller infrastructure — **REMOVED**

- No `host/chez/sim/` directory, controller ABI, lifecycle-event overlay, or `sim-worker-exit` proof record in v0.5.17; searches covered `host/chez/**`, `docs/**`, whole tree.
- Host contract exports reader/analyzer/optimization seams only. `V17/host/chez/host-contract.ss:568-632`
- Ordinary runtime loads concurrency, core.async, BigDecimal, source-registry directly, no sim overlay. `V17/host/chez/rt.ss:995-1013`
- The prior private future-lifecycle overlay cannot be cited or relied upon at this baseline.

## (c) 0.5.14–0.5.17 changelog survey

- Evaluation order: no entries. `V17/CHANGELOG.md:10-322`
- Equality/hash: 0.5.14 fixes `hash-combine` to hash its value argument; keyword `.hashCode` from hasheq to JVM-compatible hashCode (host API fix, not core `=`). `V17/CHANGELOG.md:288-297`
- Collections/errors: 0.5.14 `keys`/`vals` throw ClassCastException on non-entry elements. `V17/CHANGELOG.md:316-321`
- Error observation: 0.5.14 restores `:expected/:actual` in clojure.test reports; 0.5.16 positions analysis failures at innermost form. `V17/CHANGELOG.md:279-286`; `102-110`
- Reader: no entries.
- Concurrency/time: 0.5.16 adds TimeUnit, bounded waits, monotonic `System/nanoTime`, Thread.join fixes. `V17/CHANGELOG.md:49-68`; `119-131`
- Host String comparison: 0.5.17 `.compareTo` results integer instead of float. `V17/CHANGELOG.md:27-34`

## Charter impact

- **#2 CHANGED:** §4/§6 normalization must account for source keys duplicated into `:def :meta`/`:meta-expr`, not merely `:pos`; still no semantic identity. `V17/jolt-core/jolt/analyzer.clj:417-432`
- **#7 CHANGED:** §3/§4/§6 clock effects must distinguish host-capability wall timestamps from monotonic durations and record which primitive supplied each value. `V17/host/chez/rt.ss:441-458`
- **#10 CHANGED:** §3/§4/§6 — telemetry primitives are observation inputs, not canonical events or evidence identities; host thread IDs/counters are never evidence identities. `V17/host/chez/rt.ss:460-488`
- **(b) REMOVED:** §3/§4/§6 — no upstream lifecycle/controller seam exists at baseline; runtime seams are requested from the v0.5.17 runtime lane, not assumed. Does not alter the pure, timeout-free §7 proof target unless it later gains a runtime refinement relation. `V17/host/chez/host-contract.ss:568-632`; `V17/host/chez/rt.ss:995-1013`
- No CHANGED/REMOVED verdict alters §2 ordinary-invoke evaluation order; #1 confirmed.
