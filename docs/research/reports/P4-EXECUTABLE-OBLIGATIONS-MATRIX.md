# P4 — Executable Obligations Matrix (charter → jolt-hegel)

**Provenance:** `property-testing` subagent, session `ses_0400e9f45ffe91J6BPnLROGN95`,
model `zai-coding-plan/glm-5.2` (high), 2026-08-01.
**Inputs:** `/home/chuck/ai-src/jolt-hegel` (read-only source audit) + research plan
and gradual-formalism vision docs.
**Status:** UNREVIEWED working report; API claims carry repo citations but have not
yet been independently re-verified by the primary orchestrator.
**Method:** read-only review. No build or test result is claimed.

---

# Executable Obligations Matrix: Jolt Application Core Charter → jolt-hegel API

**Honesty baseline (applies to every row):** jolt-hegel exposes **no exhaustive/coverage mode**. `:test-cases` is a *maximum*, choice-tree exhaustion is not a documented completeness guarantee, and there is no "explore-all" flag (`src/hegel/core.clj:250`, `:test-cases`; `src/hegel/ffi.clj:670-682` state-machine takes only rule/invariant names, no enumeration control). Therefore **no Hegel row can be `bounded-complete`**, and `monitored` belongs to a runtime/jolt-sim trace monitor, not Hegel. Every green Hegel run is `sampled`.

**Replay record fields available today** (`src/hegel/core.clj:348-434`, `src/hegel/ffi.clj:197,793`): result `:passed? :status :seed(str) :test-cases :valid/invalid/overrun/interesting-test-cases :n-failures :failures :final :observed-failures :flaky? :error :health-check-failure?`; per-failure `:origin :reproduction-blob :status :value :exception :reproduced?`; stateful adds `:hegel.stateful/trace`. **Public cross-process replay = `:seed` only**; the blob drives the in-process automatic final replay (`core.clj:313-327`) and is *not* exposed as a standalone replay API in `hegel.core`.

---

### Row 1 — Pure value/equality/hash laws (reflexivity/symmetry/transitivity of `=`, hash-consistency, compare antisymmetry/totality over bounded values)
- **Generate/shrink:** canonical immutable Jolt values; assert `(= x x)`, `(=> (= a b) (= (hash a) (hash b)))`, compare laws. Pure.
- **Stateful model?** No.
- **Replay fields used:** `:seed`, `:failures[].reproduction-blob`, `:final[]`.
- **Evidence level:** `sampled` — engine draws a subset of the value domain; no exhaustive enumeration over even a finite bounded set.
- **Current-API fit:** **partial** — equality/hash properties run fine via `h/run-test!` (`core.clj:348`). Leaf/collection generators exist (`g/map :796`, `g/vector :698`, `g/set :761`, `g/hmap :832`, `g/tuple :674`). **No `g/keyword`/`g/symbol`/`g/recursive`** — keyword/symbol leaves must be hand-built via `g/fmap`+`g/string` (`:566`), and bounded-depth nesting must be hand-rolled via `g/bind`/`g/one-of` (`:577,:631`). The entire public generator surface is `src/hegel/generator.clj:1-865`; nothing else is exported.

### Row 2 — Evaluation-order sensitivity detection (small programs whose result differs under order changes)
- **Generate/shrink:** program ASTs; run under ≥2 evaluators (e.g. left-to-right vs right-to-left) in one property body; compare observable result/exception.
- **Stateful model?** No (pure differential), though `g/let`/`g/bind` drive dependent construction.
- **Replay fields used:** `:seed`, `:origin` (stable, value-free), `:final[]`.
- **Evidence level:** `sampled` — differential sampling of generated programs.
- **Current-API fit:** **partial** — the differential comparison is a supported hand-written pattern (`draw!` then run two interpreters), seed/pin + minimized replay supported. But **no built-in expression/AST generator and no recursive generator combinator** (`generator.clj:1-865`); the program generator must be authored from scratch.

### Row 3 — Transient-region scoping (no escape, no use-after-`persistent!`, task-local confinement) over a bounded operation model
- **Generate/shrink:** operation sequences (`new`, `conj!`, `persistent!`, attempted use-after-persist as buggy control); invariants assert no escape.
- **Stateful model?** Yes — `hs/run!`/`hs/rule`/`hs/invariant` (`stateful.clj:255,:39,:70`).
- **Replay fields used:** `:seed`, `:hegel.stateful/trace` (rule names, `stateful.clj:304`), `:failures[].origin`.
- **Evidence level:** `sampled` over the *sequential* model. Genuine **task-local confinement / cross-task escape cannot be reached by Hegel** — `hs/run!` executes one rule sequence sequentially per case; there is no thread/task interleaving.
- **Current-API fit:** **partial** — sequential state-machine model supported; real cross-task confinement is **missing** here and belongs to jolt-sim schedule control (one `run-test!` is sequential, README:233-237).

### Row 4 — Atom laws (linearizable swap!/reset!/compare-and-set!, validator-before-publication, watch-after-publication) over bounded concurrent schedules
- **Generate/shrink:** atom operation sequences against a model; invariants for the single-threaded/model-expressible contract.
- **Stateful model?** Yes for the operation model. **Bounded concurrent schedules are not a Hegel capability.**
- **Replay fields used:** `:seed`, `:hegel.stateful/trace`, `:observed-failures` (for flaky/outcome-nondeterminism, `core.clj:226-241`).
- **Evidence level:** `sampled` for the sequential model. Genuine **multi-thread linearizability under contention is not reachable** — Hegel picks a sequential rule sequence; it does not spawn threads or interleave.
- **Current-API fit:** **partial** — model-level atom contract supported via `hs/run!`; real concurrent linearizability is **missing** and requires jolt-sim deterministic schedules or real-thread tests. (Note: Hegel's `:flaky? true` path exists precisely because real nondeterminism is out of scope — `core.clj:338-343`.)

### Row 5 — Promise/delay/future settlement laws (exactly-once settlement, cached failure, deref timeout behavior)
- **Generate/shrink:** settlement-count sequences (deliver 0/1/2+); cached-failure scenarios (deref twice → same exception); timeout scenarios.
- **Stateful model?** Yes for exactly-once settlement (deliver-counter model).
- **Replay fields used:** `:seed`, `:hegel.stateful/trace`, `:failures[].reproduction-blob`.
- **Evidence level:** `sampled` for settlement/cached-failure. **deref timeout behavior is not reachable** — Hegel has no virtual/real clock and the skill mandates "deterministic protocol signals, never sleeps" (no clock control in `core.clj:243-281` options).
- **Current-API fit:** **partial** — exactly-once + cached-failure as models supported; real-deadline timeout semantics **missing** (needs jolt-sim virtual time or real-time tests outside Hegel).

### Row 6 — The differential loop: source → reference evaluator → compiled-Jolt
- **Generate/shrink:** programs; run through both evaluators; compare; minimize counterexample; persist.
- **Stateful model?** No (pure differential), though program gen uses `g/bind`/`g/one-of`.
- **Replay fields used:** `:seed` (public replay coordinate), `:derandomize?` + `:database-key`/`:name` for stable derived seeds (`core.clj:243-271`), `:database` for libhegel-owned prior-failure persistence (`core.clj:266`), `:failures[].reproduction-blob`/`:origin`, `:final[]`.
- **Evidence level:** `sampled` — differential testing is sampling by construction.
- **Current-API fit:** **partial** — seed/pin + minimized-replay fully supported; the differential comparison is a supported hand-written pattern. **Program generation has no built-in AST/recursive generator** (must hand-build), and **named-corpus persistence is partial**: you get seed + libhegel-internal failure DB replay, but no public API to save/replay a *named corpus* of interesting programs across runs (no such API in `core.clj`/`report.clj`/`generator.clj`).

---

## Direct questions

**Q1 — Generator-domain support for canonical immutable Jolt values (nested maps/vectors/sets with keyword/symbol leaves):**
- **Present:** collection combinators `g/vector` (`generator.clj:698`), `g/map` (`:796`), `g/set` (`:761`), `g/sorted-set` (`:788`), `g/sorted-map` (`:824`), `g/hmap` (`:832`), `g/tuple` (`:674`), `g/list` (`:753`); composition `g/fmap` (`:566`), `g/bind` (`:577`), `g/one-of` (`:631`), `g/optional` (`:648`), `g/just` (`:613`), `g/sampled-from` (`:618`).
- **Missing:** no `g/keyword`, no `g/symbol`, no `g/recursive`/sized-nesting combinator, no `g/any`. Keyword/symbol leaves and bounded-depth nesting must be hand-built (e.g. `(g/fmap keyword (g/string {...}))`, manual fixed-depth recursion via `g/bind`). Verified the complete public surface is `src/hegel/generator.clj:1-865` with nothing further exported from `hegel.core`/`hegel.stateful`/`hegel.report`/`hegel.clojure-test`.

**Q2 — What is missing for shrinking operation sequences under a stateful model:**
- **What works:** `hs/run!` generates and shrinks rule sequences; the test suite demonstrates minimization to `[:inc :inc]` and `[:open :close]` (`test/hegel/test_runner.clj:905-967`); shrinking is engine-managed and automatic (`stateful.clj:280-284`).
- **Missing / opaque:**
  1. **No user-settable sequence-length / `:max-steps` bound.** `new-state-machine!` takes only rule and invariant names (`ffi.clj:670-682`); the 50-attempt cap is libhegel-internal, not exposed (`test_runner.clj:1001-1005`). A model-declared `:max-steps` (vision doc) cannot be enforced via Hegel.
  2. **No swarm/rule-subset control.** libhegel picks the nonempty swarm subset automatically; you cannot pin a specific schedule or rule subset to reproduce a particular interleaving.
  3. **Persisted trace is rule names only, not arguments.** `:hegel.stateful/trace` is `(:name item)` (`stateful.clj:304`) — minimized arg values are re-derived from `:seed` on replay, not stored in the trace. A stable regression corpus of operation sequences therefore depends on seed + trace, with args not independently persisted.
  4. **No concurrent-schedule shrinking.** Rules run sequentially; multi-thread interleaving shrinking is out of scope (jolt-sim).

---

## Docs-vs-repo reconciliation
- Skill/api.md and README accurately describe the implemented surface. No contradictions found in the generator, stateful, replay, or flakiness contracts — all verified against source. The one nuance the docs understate: the **reproduction blob is an in-process final-replay mechanism** (`core.clj:313-327`, `ffi.clj:425`); the only *public, cross-process* replay handle is `:seed` (`core.clj:384,392`; README:218-226).

## Gaps requiring user decision
- **G1.** Row 1/2/6 need a recursive/AST generator (and `g/keyword`/`g/symbol` leaves). Decide: hand-build in the consuming project, or propose adding these combinators to jolt-hegel (out of scope to design here).
- **G2.** Rows 3/4/5 all hit a Hegel ceiling at real concurrency/time (cross-task transient escape, multi-thread atom linearizability, deref timeouts). Decide whether those obligations route to **jolt-sim** (schedule/virtual-time control) and are simply *not* Hegel obligations — and label their evidence `monitored`/`bounded-complete` only via jolt-sim, never Hegel.
- **G3.** Operation-sequence shrinking has no exposed `:max-steps` bound and rule-subset/length are engine-opaque. Decide whether a model-declared step bound is a jolt-hegel API addition or a jolt-model/jolt-sim concern (current repo: missing from Hegel).
- **G4.** Persisted minimized traces carry rule names but not arg values; replay re-derives args from seed. Decide whether a self-contained minimized operation-sequence corpus record (args included) is required — if so, it is **missing** today.
- **G5.** No public named-corpus / regression-replay API exists (only `:seed` + libhegel-internal failure DB). Decide whether the differential loop (Row 6) needs an explicit corpus-persistence layer above Hegel.
