# P2 — Decision Alternatives Memo (semantic boundaries and claim discipline)

**Provenance:** `simulation-formalism-architect` subagent, session
`ses_0400ea2c9ffeIuhezqZdOrofZX`, model `openai/gpt-5.6-terra` (high), 2026-08-01.
**Inputs:** the four research documents + `jolt-sim` at `eb7bce4` (read-only).
**Status:** UNREVIEWED working report; recommendations are inputs to the user
decision session, not accepted decisions.
**Method:** read-only review. No build or test result is claimed.

---

# Decision Alternatives Memo — Jolt Application Core Semantic Charter

## Grounding and divergences found

- The implemented cooperative kernel is a finite transition system over task/world/time/budget state; it exposes enabled `:run` and forced earliest `:advance` actions, and distinguishes `:completed`, `:failed`, `:deadlock`, and `:step-limit` terminals (`kernel.clj:494-621`).
- Its canonical projection includes tasks, world, virtual integer time, consumed/max step budget; trace and step function are deliberately excluded (`kernel.clj:513-528`). Canonical trace values reject metadata, functions, records, and arbitrary host objects (`trace.clj:1-14`, `128-187`).
- Replay validates event shape, enabled choices, complete canonical projections, and terminal outcome (`kernel.clj:667-698`). Offline monitors are pure folds over validated trace documents and can return `:pass`, `:violation`, or `:inconclusive` (`monitor.clj:100-146`).
- The runtime adapter dynamically resolves, then requires an exact ABI-5 descriptor; its declared FFI routing `proceed` contract is zero-argument, single-use, dynamic-extent, and owner-thread-only (`runtime.clj:12-23`, `50-73`, `140-196`). **UNKNOWN:** the fenced source establishes the adapter's required contract, not the implementation of `jolt.internal.sim` inside a particular Jolt image.
- **Historical-source divergence:** the architecture review describes monitor dependence on `kernel`; current `monitor` imports only `trace`, whose source now owns document/schema validation (`jolt-sim-architecture-review-2026-08-01.md:101-104`; `monitor.clj:1-32`; `trace.clj:552-554`).
- **Baseline decision remains open:** the research plan intends a 0.5.13 candidate (`JOLT-FORMALIZABLE-APPLICATION-CORE-RESEARCH-PLAN-2026-08-01.md:25-31`), while the current simulator README names 0.5.12-derived `56d0694` (`README.md:15-37`). The Flow plan records this as an active pivot, not a resolved implementation fact (`JOLT-SIM-MAELSTROM-FLOW-IMPLEMENTATION-PLAN.md:139-145`).

## A. CSIR shape

### A1. Annotate the existing compiler optimization IR
Attach spans, expansion provenance, site/resource/operation IDs, and assumptions as IR metadata.
Preserve metadata through every optimization or emit a side manifest before a pass drops it.
Use a structural site key, not source offsets, for recompilation stability.
Production code remains independent of `jolt-sim`.
- **Costs:** lowest initial compiler change; metadata propagation audit.
- **Risks:** optimization cloning, fusion, inlining, and DCE can duplicate or erase semantic identity.
- **Evidence enabled:** source-to-optimized-code diagnostics; limited event attribution.
- **Explicit nonclaims:** no stable semantic artifact once a pass fails to preserve metadata.

### A2. Emit a separate CSIR beside optimization IR
After expansion and semantic resolution, emit immutable CSIR plus a source/provenance map; compile optimized IR separately.
CSIR contains span, macro stack, stable site ID, operation/resource ID, schemas, lane, and declared assumptions.
Associate executable observations with CSIR IDs, never optimization-node identity.
Production libraries consume only core descriptors/schemas; `jolt-sim` optionally consumes CSIR.
- **Costs:** new serializer, validator, and compiler conformance tests.
- **Risks:** CSIR/compiler semantic drift without differential controls.
- **Evidence enabled:** stable model/proof inputs, replay attribution, backend-neutral obligations.
- **Explicit nonclaims:** CSIR does not prove compiler lowering or host behavior.

### A3. Compiler-owned semantic provenance graph with CSIR projection
Create an immutable expanded-form provenance graph; CSIR is its normalized, versioned projection.
Each semantic node has an origin anchor, expansion-parent chain, resolved binding, and semantic-role path.
Permit an explicit declared semantic anchor for public operations that must survive semantic-preserving refactors.
This is strictly better technically: identity survives optimizer rewrites without making optimizer IR archival.
- **Costs:** largest compiler artifact and tooling investment.
- **Risks:** graph/version churn; explicit anchors can be misused as false equivalence claims.
- **Evidence enabled:** durable source/macro/debugger/proof/replay correlation and refactor-aware trace migration.
- **Explicit nonclaims:** an anchor does not assert two changed operations are behaviorally equivalent.

**Site-ID rule for A1–A3:** derive the default ID from `{CSIR-schema, namespace/logical definition, resolved binding path, normalized expanded semantic-role path, macro-definition digest chain, operation tag}`. Do **not** hash line/column. Formatting, comments, and movement that preserves this structure retain the ID; changing binding resolution, macro expansion/digest, semantic role/path, operation schema, namespace/definition identity, or CSIR schema breaks it. A declared anchor may preserve identity across an intentional refactor, but must record old/new CSIR digests and reviewer approval.

**Recommendation — A3.** The charter needs one durable semantic identity across macro expansion, optimization, runtime observation, and external obligations; a provenance graph plus projected CSIR provides that without treating optimization IR as a semantic archive. Under remint policy, CSIR schema and compiler consumers should advance together on one baseline—no compatibility reader or dual-ID bridge for superseded prerelease schemas.

## B. Boundary taxonomy

### B1. Opt-in annotations at public APIs
Libraries label functions `ordinary-core`, `Dynamic-opaque`, host-capability, or simulation-handler.
Unannotated code defaults to ordinary-core until a runtime escape is observed.
- **Costs:** minimal compiler work.
- **Risks:** unsound omission; annotations become aspirational documentation.
- **Evidence enabled:** manually scoped boundary tests and monitors.
- **Explicit nonclaims:** no closed-world effect or controlledness claim.

### B2. Conservative CSIR lane inference with explicit widening
`ordinary-core`: resolved expanded semantics over canonical values and declared core operations.
`Dynamic-opaque`: `eval`, dynamic resolution, unknown macro expansion, or unresolved call path.
`host-capability`: declared capability crossing, raw host object, FFI, process, callback, clock, entropy, or I/O.
`simulation-handler`: optional scenario interpretation of a closed core descriptor; never a production dependency.
- **Costs:** resolver/expander facts, lane diagnostics, explicit boundary declarations.
- **Risks:** initially broad `Dynamic` results; users may resist required declarations.
- **Evidence enabled:** honest closed-world summaries, fail-closed simulation, refinement coverage checks.
- **Explicit nonclaims:** inference does not make host execution deterministic or pure.

### B3. Capability-only application profile
Require all non-pure behavior to use capability descriptors; reject or sandbox all other dynamic/host behavior.
Treat simulation as one capability implementation.
- **Costs:** substantial language/profile migration and capability API design.
- **Risks:** over-constrains ordinary Jolt; incentivizes generic escape hatches.
- **Evidence enabled:** strongest static boundary and sandbox story.
- **Explicit nonclaims:** no claim over raw host callbacks or code outside the profile.

**Widening and controlledness rule for B2:** `eval`, dynamic resolution, unknown macros, raw host objects, and unregistered callbacks widen the enclosing claim to `Dynamic-opaque`; no static coverage/proof claim may cross it. A registered callback is host-capability unless its thread/lifetime/ownership/serialization contract is declared. An unhandled descriptor in a hermetic simulation is an escape and fails closed, rather than silently becoming host I/O—matching current FFI behavior (`runtime.clj:942-996`).

**Controller composition:** the existing adapter is an optional host-capability/simulation-handler seam, not a language-wide effect runtime. It validates exact FFI descriptors (`runtime.clj:484-522`), records live descriptor/route evidence (`runtime.clj:904-926`), and does not own raw threads or executor tasks (`runtime.clj:44-46`). Scheduler choice, modeled fault choice, and host nondeterminism are choices only when a named model/controller owns them; ordinary canonical data is state, not a choice.

**Recommendation — B2.** It gives the charter a useful ordinary-core while making every widening mechanically visible and preserving current optional-controller architecture. The prerelease remint rule permits one precise taxonomy and descriptor schema to replace prior classifications in place, rather than retaining permissive legacy lanes that weaken every new claim.

## C. Evidence lattice

### C1. One total ordered badge
Rank every result `opaque < assumed < monitored < sampled < bounded-complete < proved`, with `failed` last.
- **Costs:** simple UI and filtering.
- **Risks:** falsely implies a monitor outranks sampling, or either implies a finite exhaustive search.
- **Evidence enabled:** superficial reporting only.
- **Explicit nonclaims:** not a sound evidence semantics; reject.

### C2. Claim-relative partial order plus compatible evidence bundles
For the *same proposition, transition relation, abstraction, and scope*:  
`opaque ⊑ assumed`; `assumed ⊑ sampled` and `assumed ⊑ monitored`; sampled and monitored are incomparable.  
`bounded-complete` is above either only when its finished exploration covers that same finite relation.  
`proved` is above bounded-complete only when a checked proof establishes the same or stronger proposition under listed assumptions.  
`failed` is evidence for the negation and is incomparable with positive levels; it blocks promotion.
- **Costs:** claim IDs, scope matching, and a compatibility checker.
- **Risks:** less convenient than one score; users must state the target relation.
- **Evidence enabled:** honest aggregation across testing, monitoring, search, and proof.
- **Explicit nonclaims:** a proof of a model is not automatically a proof of its implementation.

### C3. Unordered evidence ledger only
Store records but never derive a level; every consumer interprets evidence independently.
- **Costs:** lowest semantic commitment.
- **Risks:** inconsistent dashboards and accidental overclaiming by downstream tools.
- **Evidence enabled:** archival and manual review.
- **Explicit nonclaims:** no automatic claim upgrade.

**Mandatory record metadata:** claim ID and proposition; level; source/model/CSIR digest; schema/IR version; tool and checker version; transition-system/abstraction digest; bounds and state-cap status; fairness; host/FFI and controlledness assumptions; result; canonical replay coordinates (seed, choices/actions, trace digest, witness); timestamp and target tuple.

**Upgrade rules for C2:**
- `opaque → assumed` requires an explicit, named boundary assumption; it is not validation.
- `→ sampled` requires reproducible generated/example cases and a declared sampling domain.
- `→ monitored` requires a validated canonical trace and declared required-observation coverage; loss, malformed mapping, or an escape yields `inconclusive`/`failed`, not pass.
- `→ bounded-complete` requires a finite declared transition relation, canonical state identity, all enabled actions explored, termination, and a nonbinding state cap. A cutoff is **not** bounded-complete.
- `→ proved` requires a checked theorem/certificate, stated TCB, and an explicit model-to-CSIR/runtime refinement argument where the claim names implementation behavior.
- Never promote: Hegel/sample pass to proved; finite monitor pass to unbounded liveness; timeout to deadlock; or a model result to production conformance without the abstraction/coverage relation.

For cooperative models, the current kernel supplies a useful transition-system shape and terminal distinctions (`kernel.clj:310-341`, `545-560`); its branch contract explicitly excludes closed-over mutation, host entropy, clocks, and I/O from completeness (`kernel.clj:481-492`). Finite traces can establish monitored safety or bounded response only; LTL-style infinite liveness additionally needs explicit fairness and an infinite-trace semantics.

**Recommendation — C2.** The seven labels are not honestly a total order, so the charter should make evidence bundles and scope compatibility first-class. Reminting one current record schema lets every producer adopt the same strict metadata now; compatibility branches would preserve ambiguous old badges and defeat the evidence discipline.

## D. Effect-descriptor v1 scope

### D1. Leave effects as the current FFI controller only
Treat validated FFI descriptors and routing as the sole handler facility.
Use `proceed` for native fallback and handler return values for substitution.
- **Costs:** nearly zero new core mechanism.
- **Risks:** conflates FFI routing with application semantics; no vocabulary for time/entropy/I/O above FFI.
- **Evidence enabled:** existing FFI route evidence and hermetic handler packs.
- **Explicit nonclaims:** not algebraic effects; no general application descriptors.

### D2. Core closed descriptors; optional adapter to the FFI controller
Add a core/stdlib descriptor schema: `{family operation canonical-args operation-id resource-id site-id assumptions}`.
`with-effect-handlers` is dynamically scoped, innermost-first, strict-LIFO; a handler substitutes a validated result or aborts.
A default real capability handler remains production behavior; `jolt-sim` optionally installs recording/model/fault handlers.
At FFI boundaries, an adapter may map a closed descriptor to the current validated FFI descriptor; `proceed` remains native fallback only.
- **Costs:** core schema validation, dynamic scope implementation, and handler contracts.
- **Risks:** descriptor vocabulary/version growth; mistaken equivalence between an application operation and an FFI call.
- **Evidence enabled:** stable effect routes for time, entropy, I/O, faults, and resource protocols without simulator imports.
- **Explicit nonclaims:** no continuation capture, cloning, or scheduler search through handlers.

### D3. General delimited-control effect runtime
Lower `perform`/handlers in the compiler and expose resumptions as first-class values.
Attempt to generalize the controller's `proceed` into user-visible continuation handling.
- **Costs:** compiler/runtime/stack/exception/cancellation/FFI redesign.
- **Risks:** continuation lifetime, multi-shot cloning, cross-thread resume, masking, locks, native loans, and callback affinity.
- **Evidence enabled:** direct-style resumable effects, if independently specified and implemented.
- **Explicit nonclaims:** none safely available in v1; defer.

**D2 v1 semantic limits:** operation vocabulary is closed and schema-validated, not a universal untyped `perform`. Handlers are deep only for explicitly nested descriptor execution within their dynamic extent; they do not capture a continuation. Therefore resumption is neither one-shot nor multi-shot: it does not exist at this layer. Exceptions abort through handler scope and `finally`-style cleanup restores strict LIFO state. Cancellation, masking, cleanup, resource linearity, thread affinity, callbacks, and FFI loans must be operation-family protocols; unknown or cross-thread callbacks widen to host-capability/opaque.

The existing controller's `proceed` is narrower: it is declared one-shot, owner-thread, and dynamic-extent (`runtime.clj:50-56`), routes native exceptions as ordinary application exceptions (`runtime.clj:1109-1117`), and restores FFI before future control in reverse installation order (`runtime.clj:1268-1292`, `1452-1460`). It is not a general effect-handler continuation. Current runtime sessions also reject overlap/nesting (`runtime.clj:1438-1447`), so no existing general handler-composition semantics should be inferred.

**Recommendation — D2.** It is the smallest justified mechanism: descriptors standardize execution boundaries while preserving direct-style production APIs and making `jolt-sim` an optional interpretation. The one-current-baseline policy supports replacing descriptor/handler schemas atomically as executable consumers appear; do not fossilize provisional handler or controller ABI variants.

# Questions for the decision session

1. **CSIR identity:** choose A1, A2, or the provenance-graph/CSIR projection in **A3**.
2. **Claim boundary:** choose annotation-led **B1**, conservative inferred lanes **B2**, or capability-only **B3**.
3. **Evidence semantics:** reject total ranking (**C1**) in favor of the partial-order bundle model (**C2**), or accept ledger-only **C3**.
4. **Effects v1:** retain FFI-only routing (**D1**), adopt closed core descriptors with optional simulator adapters (**D2**), or fund delimited control (**D3**).
