# Application Core Semantic Charter — Decision Memo

**Date:** 2026-08-01
**Status:** ACCEPTED by the user (Chuck) 2026-08-01, pending Phase 3 design challenge.
**Baseline:** Jolt v0.5.13 rebase candidate `021b0b729bdc11264864bc0033cb1b64b3cde5e3`.
**Grounding reports:** `reports/P1-SEMANTIC-FACTS-REGISTER.md`,
`reports/P2-DECISION-ALTERNATIVES-MEMO.md`, `reports/P3-FIRST-PROOF-TARGET-DESIGN.md`,
`reports/P4-EXECUTABLE-OBLIGATIONS-MATRIX.md`,
`reports/P5-RESEARCH-DOC-CLAIM-CHECKLIST.md` (same directory).
**Caveat:** subagent report citations have not yet been fully spot-verified by the
primary orchestrator; Phase 3 includes citation verification.

## Accepted decisions

### D1 — CSIR identity: A3 target design, A2-minimal first milestone
The charter adopts **A3** (compiler-owned semantic provenance graph; CSIR as a
normalized, versioned projection) as the target design, staged through an
**A2-shaped minimal CSIR v1** covering only the first pure fragment. P1
established that the current IR carries only optional `:pos` and no provenance,
site-ID, resource-ID, or assumption fields (`jolt-core/jolt/ir.clj:100-168`), so
every option is new compiler work; A1 (metadata on optimization IR) is rejected
because optimization passes can erase or duplicate semantic identity. The
site-ID rule applies to all stages: structural key derived from
`{CSIR-schema, namespace/logical definition, resolved binding path, normalized
expanded semantic-role path, macro-definition digest chain, operation tag}` —
never a line/column hash. Declared anchors may preserve identity across an
intentional refactor but must record old/new CSIR digests; an anchor never
asserts behavioral equivalence.

### D2 — Boundary taxonomy: B2 (conservative lane inference + explicit widening)
Lanes: `ordinary-core` / `Dynamic-opaque` / `host-capability` /
`simulation-handler`. Widening is mechanical: `eval`, dynamic resolution,
unknown macro expansion, raw host objects, and unregistered callbacks widen the
enclosing claim to `Dynamic-opaque`; no static coverage or proof claim crosses
it. A registered callback is host-capability unless its
thread/lifetime/ownership/serialization contract is declared. Unhandled
descriptors in a hermetic simulation fail closed. Production libraries never
depend on jolt-sim. P1 confirmed every widening trigger exists in live source
(`eval`/`load-string` via resident compiler; FFI direct-emit without
interception; dynamic var resolution).

### D3 — Evidence lattice: C2 (claim-relative partial order + bundles)
Evidence levels relate only for the same proposition, transition relation,
abstraction, and scope: `opaque ⊑ assumed`; `assumed ⊑ sampled` and
`assumed ⊑ monitored`; sampled and monitored incomparable; `bounded-complete`
above either only for a finished, uncapped exploration of that same finite
relation; `proved` above bounded-complete only with a checked certificate under
stated assumptions; `failed` is evidence for the negation, incomparable with
positive levels, and blocks promotion. Never-promote list: Hegel/sample pass →
proved; finite monitor pass → unbounded liveness; timeout → deadlock;
state-cap cutoff → bounded-complete; model result → implementation conformance
without a declared abstraction + coverage relation. Mandatory evidence-record
metadata: claim ID and proposition; level; source/model/CSIR digest; schema/IR
version; tool and checker version; transition-system/abstraction digest; bounds
and state-cap status; fairness; host/FFI and controlledness assumptions;
result; canonical replay coordinates (seed, choices/actions, trace digest,
witness); timestamp and target tuple.

### D4 — Effects v1: D2 (closed core descriptors, substitution/abortive handlers)
Core/stdlib descriptor schema `{family operation canonical-args operation-id
resource-id site-id assumptions}`. Handlers via `with-effect-handlers`:
dynamically scoped, innermost-first, strict-LIFO; a handler substitutes a
validated result or aborts. **No continuations exist at this layer** — neither
one-shot nor multi-shot. A default real capability handler remains production
behavior; jolt-sim optionally installs recording/model/fault handlers. At FFI
boundaries an adapter may map a closed descriptor to the current validated FFI
descriptor; the controller's `proceed` remains native fallback only and is not
a general effect continuation. Explicit non-goals: multi-shot continuations,
universal untyped `perform` map, handler-driven scheduler search, implicit
global handler composition.

### D5 — First proof target: capacity-one mailbox (send/receive/close, no timeout)
Per P3's design: pure two-task cooperative model, capacity one, fixed messages
`[:a :b]`, `max-steps 7`, unreduced BFS on the existing jolt-sim cooperative
kernel + `explore-states`. Controls: buggy known-SAT variant
(`close`-drops-full-slot; expected 5-step witness); corrected control must
finish BFS with no state cap (`:state-limit` is inconclusive, never a pass);
non-vacuity via required reachable-state classes (blocked consumer, blocked
producer, close-before-drain path, drain-before-close path, completed terminal)
plus exact visited/terminal/edge counts in the proof record; literal replay +
monitor + regression fixtures. TCB: model encoding, kernel
transition/classification, BFS explorer, canonical projection, trace
validator/replay, monitor — each with its own control; nothing is "proved".
Timeout/cancel is the next extension, not part of the first claim. Execution is
a separate bounded jolt-sim task (not this lane); the F3-vs-F4 tension is
resolved by scope: this is the charter's pure-model target and displaces no
HTTP/Maelstrom runtime-lane work.

### D6 — Initial pure fragment: P1 §§1–5 core, with named exclusions
Included: literals (per D8 exclusions), `let*`/`loop*`/`fn*`/`recur`, ordinary
ordered `:invoke` (P1: observably left-to-right,
`backend_scheme.clj:429-473,909-930`), `if`/`do`, `quote`, selected
`throw`/`try`/`catch`/`finally`. Excluded: concurrency primitives, FFI, host
interop (P1: interop operand order is UNSPECIFIED — unordered bare Scheme
application), `eval`/`load-string`, dynamic resolution, raw host values, and
the unresolved reader/equality corners (D7/D8). The charter's
deterministic-evaluation-order statement covers ordinary invoke only; interop
order is recorded as host-dependent/opaque.

### D7 — Numeric-`=` authority: conformance register over README prose
`test/conformance/SPEC.md` + `known-divergences.edn` (executable-derived) are
authoritative where they conflict with README prose (numeric category-blind
`1` vs `1N`). A README correction is upstream hygiene, not this lane.

### D8 — `#=` reader conflict: outside formal-core
Classify opaque/excluded; reader-eval is excluded from the fragment anyway. No
charter semantics for `#=` beyond exclusion.

### D9 — Hegel gaps: hand-build generators in-project; route concurrency/time to jolt-sim
Hand-build recursive/AST and keyword/symbol generators in the consuming test
project (G1); real-concurrency/time obligations (cross-task transient escape,
multi-thread atom linearizability, deref timeouts) route to jolt-sim and are
never Hegel obligations (G2); defer jolt-hegel API additions (`:max-steps`,
arg-persisting traces, named-corpus replay) until the differential loop exists
(G3–G5). Every Hegel result is `sampled`, never completeness.

### D10 — Baseline record: charter pins 0.5.13 candidate
This lane pins `021b0b72`. The jolt-sim lane owns its own 0.5.13 pivot and
remint; no compatibility claims across the 0.5.12/0.5.13 gap from this lane.

## Rejected alternatives (summary)

- A1 (annotate optimization IR): identity not durable through passes.
- B1 (opt-in annotations): unsound by omission. B3 (capability-only profile):
  over-constrains ordinary Jolt today.
- C1 (total-order badge): unsound ordering implication. C3 (ledger only):
  invites downstream overclaiming.
- D1 (FFI-controller only): no vocabulary above FFI. D3 (delimited control):
  deferred entirely.
- D5 alternative (bounded equality/hash consistency first): blocked by D7
  authority conflict; exercises no scheduling/replay semantics.

## Phase 3 design challenge

- Claude CLI (Sonnet, high effort, plan mode, read-only, budget $10 authorized
  by user) — vendor-independent challenge: citation spot-verification, weakest
  claims, overclaims, charter blockers. Result: pending.
- `jolt-deep-reviewer` (Kimi K3, read-only, in-session) — fresh-context internal
  challenge on the same material. Result: pending.
