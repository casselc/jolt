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
  claims, overclaims, charter blockers. Result: completed, `reports/P6-CLAUDE-DESIGN-CHALLENGE.md`.
- `jolt-deep-reviewer` (Kimi K3, read-only, in-session) — fresh-context internal
  challenge on the same material. Result: completed, `reports/P7-DEEP-REVIEW-CHALLENGE.md`.
- All four load-bearing citations verified with exact line numbers by both
  reviewers. No evidence-lattice violations. No decision overturned.

## Amendments 2026-08-01 (post-challenge, user-approved C1–C5)

These amendments supersede or extend the referenced decisions above.

### C1 (amends D1): A3 is architect judgment; CSIR v1 staging fixed

The choice of A3 over A2 is recorded as **architect judgment**, asserted in P2
without comparative evidence; no accepted consumer yet requires A3's declared
anchors / expansion-parent chain. The **A2-minimal milestone is the only
committed build**; promotion to A3 requires a named consumer and a fresh review.
CSIR v1 staging: field set = `{site-id (D1 structural rule), source span,
expansion parent (single-step in v1), resolved binding, operation tag, lane
(D2), declared assumptions}`; schema version pinned to base SHA `021b0b72`;
validator owned by the future Jolt core lane; exit test = one fixed corpus case
evaluated through the reference evaluator AND the compiled path with matching
terminal observable, labeled `sampled`.

### C2 (amends D5): F4 quoted verbatim; resolution by lane priority; claim scope declared

F4's objection, verbatim: "The suggested standalone capacity-one mailbox BFS is
not the immediate proof target… it does not displace the higher-priority
unchanged-code HTTP/TCP/DB/Maelstrom integration."
Resolution by lane priority: F4 governs the **jolt-sim runtime lane's** landing
order; this charter lane specifies a pure-model proof target for the
cooperative-model track, which F3 roadmap item 3 explicitly recommends. F4's
sentence is about what jolt-sim executes next, not about what the charter
specifies as its first target design. The milestone's claim is declared
**"TCB-validation-only, empty refinement relation"**: the mailbox model has no
abstraction/coverage relation to any Jolt implementation artifact (native
channel semantics UNKNOWN per P1), so its evidence validates the
explorer/kernel/monitor TCB — it is not evidence about Jolt channels.
Dependency recorded: execution substrate = jolt-sim kernel on a
0.5.13-compatible pin; jolt-sim's 0.5.13 pivot is unconfirmed (D10); the design
targets kernel semantics verified at `eb7bce4`.

### C3 (replaces D7): numeric-`=` authority rescoped to conformance-lane tests only

Where conformance tests conflict with README prose on numeric `=`
(category-blind `1` vs `1N`), the conformance register (`SPEC.md` +
`known-divergences.edn`) governs **test expectations** only. The formal v1
fragment makes **no numeric-`=` claim** (D6 already excludes equality corners).
Category-blind equality is NOT canonized as formal semantics. The README
correction remains upstream hygiene. (Original D7's "(executable-derived)"
provenance tag is dropped as unevidenced.)

### C4 (new): one site-ID space

D4's effect-descriptor `site-id` field **is** the D1 CSIR site ID — one ID
space. An operation descriptor references the CSIR node at which the operation
is performed. Code that widens to `Dynamic-opaque` (eval, dynamic resolution)
carries the site-ID of the **widening site** (the eval/resolve call site) when
one exists, and no finer-grained IDs; evidence records must note the widening
site.

### C5 (new): ownership assignments

CSIR schema/versioning work is owned by the **future Jolt core implementation
lane** (not this charter lane). Acceptance of jolt-sim-produced evidence into
charter D3 evidence records is owned by **this charter lane** until Codex
handoff, then by Codex.

### Accepted wording corrections (recorded; applied at charter drafting, not by rewriting subagent reports)

- P3 §4 evidence table: all levels are "after execution" (nothing executed).
- D1 fact wording: only `:pos` carries source metadata; none of the 13 optional
  IR annotation keys carries provenance/site/resource/assumptions.
- D5 wording: the corrected control must terminate `:completed`, never
  `:state-limit` (the explorer requires a positive `:max-states`).
- D9 scoped: sequential-model variants of concurrency laws remain
  Hegel-`sampled`; only concurrent/timed variants route to jolt-sim.
- D5 max-steps-7 derivation: 2 tasks × 3 operations ⇒ longest quiescence path
  ≤6 task transitions; `max-steps 7` provides one slack.
- Registered-callback rule completed: "…unless its
  thread/lifetime/ownership/serialization contract is declared, in which case
  it may be narrowed to a named capability lane."
- P3 `:steps :steps` projection-list typo noted (kernel: `:steps` once).

### Fable review sequencing (user-directed 2026-08-01, all four slices approved)

Sequential, one Claude task at a time, per-slice budget cap $10, read-only,
bounded to its slice (never the whole memo):
1. **Slice 1 (completed):** D1 identity spine. Report
   `reports/P8-FABLE-SLICE1-IDENTITY-SPINE.md`; amendments F1–F7 below,
   user-approved 2026-08-01.
2. **Slice 2 (next):** D5/F4 reconciliation + P3 mailbox transition relation,
   invariant, and controls adequacy (incl. max-steps derivation).
3. **Slice 3 (after charter §4/§6 exist):** site-ID ↔ descriptor unification
   cross-section check.
4. **Slice 4 (before charter §5 final):** D3/C2 lattice soundness + one
   record-schema sufficiency across Hegel seed-only replay vs jolt-sim
   action-path replay.

## F-amendments 2026-08-01 (Fable slice 1, user-approved)

These amendments supersede the referenced rules above.

### F1 (amends D1/C1): CSIR v1 schema is closed; anchors deferred to A3

The CSIR v1 schema is **closed**: unknown fields and anchor records are
validation failures. D1's declared-anchor sentence is removed from the
stage-independent identity rule and applies only conditionally under A3 (after
promotion). In v1 there are **no anchors**. Any A3 feature (anchors, expansion
chain beyond single-step) requires a schema remint, which requires a memo
amendment naming the consumer plus core-lane review (C5). The dangerous drift
direction is A3-creep, not A2-ossification; the closed schema is the mechanism
that makes the promotion gate real.

### F2 (amends D1 site-ID rule): ID from the normalized expanded form, not the macro-definition chain

The site-ID derives from the **digest of the normalized expanded form at the
site** plus the remaining D1 structural components `{CSIR-schema,
namespace/logical definition, resolved binding path, operation tag}` — the
**macro-definition digest chain is removed from the ID**. Rationale: the chain
breaks every downstream ID on macro edits that change nothing at the use site
(including dependency bumps), and a definition digest may be uncomputable for
prebuilt libraries (expanders are opaque compiled closures,
`host-contract.ss:285-295`). The chain may be retained as CSIR **provenance
metadata outside the ID**; keeping it even as metadata requires staging
definition-time source capture explicitly.

### F3 (amends C1): normative normalization appendix + ID determinism vectors

The charter includes a **normative normalization algorithm** as an appendix:
gensym canonicalization, sibling/child indexing, chain order for the
re-expansion recursion, and treatment of position-propagated metadata. C1's
exit test gains **cross-run/cross-implementation site-ID determinism
vectors** — the same source compiled twice must yield identical site-IDs.

### F4 (amends D1/D3): remint evidence policy declared

A prerelease CSIR schema remint **orphans all prior evidence records** —
detectable via D3's schema/IR-version metadata, never silently reinterpreted
or promoted. Post-v1 remints must emit an **old-ID→new-ID migration record**
for surviving sites.

### F5 (amends D1 anchor rule, A3-conditional): evidence never crosses anchors

Evidence levels **never transfer across an anchor**: post-anchor claims restart
at `assumed` until re-evidenced against the new digest. An anchor grants
attribution/history continuity only, never claim continuity. Anchor record
mandatory contents: old/new CSIR digests, normalized-expansion diff,
differential-corpus run evidence ID (the anchored operation's corpus must pass
identically on both digests), reviewer identity, and a stated equivalence
argument. General semantic preservation is undecidable; reviewer judgment is
the control, backed by the mandatory differential-corpus check.

### F6 (amends C4/D4): host-origin ID class; no absent site-IDs

Every effect descriptor carries **either** a CSIR site-ID **or** a member of a
reserved, enumerated `host-origin` ID class (registration site plus entry-kind
tag) for operations issued from handwritten host-layer code that never
traverses the analyzer (including callbacks fired from native threads). An
absent `site-id` is a validation failure. The "when one exists" clause is
deleted.

### F7 (amends C4/D4): Dynamic-opaque attribution declared descriptor-level; `operation-id` per-instance

Attribution granularity inside `Dynamic-opaque` regions is **descriptor-level**
— declared explicitly, not left implicit (eval'd code's operations share the
widening site's ID; discrimination comes from the descriptor). D4's
`operation-id` is **per-instance unique** (one per operation invocation),
aligning with jolt-sim's stable operation-ID practice; the `operation` field
remains the per-kind tag.

## G-amendments 2026-08-01 (Fable slice 2, user-approved)

These amendments correct the D5 first proof target design. Report:
`reports/P9-FABLE-SLICE2-PROOF-TARGET.md`. Note: throughout this memo, "the
Flow plan" refers to `JOLT-SIM-MAELSTROM-FLOW-IMPLEMENTATION-PLAN.md`;
"F4" unambiguously denotes amendment F4 above (name-collision fix, G6).

### G1 (amends D5): step bound re-derived counting block transitions

Encoding declared: guard failure ⇒ `step-block`, a budget-consuming transition;
wakes are conditional on world-tracked waiting flags. The longest quiescence
path is **10 task transitions** (9 if the consumer starts blocked);
`max-steps` is set to **11** (one slack). `:step-limit` remains in the
violation disjunction as the bound's checked control. This supersedes the
earlier "≤6 + one slack = 7" derivation, which counted only productive
operations and would have made the corrected control return `:violation` via
its own `:step-limit` clause.

### G2 (amends D5/P3 model): world gains waiting flags; wakes conditional; relation restated

The kernel has no world-state guards: `machine-actions` enumerates runnable
tasks only (`kernel.clj:545-560`), and a task blocks by executing `step-block`
(one transition, increments `:steps`). Waking a non-blocked task throws outside
the step-fn catch (`kernel.clj:187-190,357-363`), crashing the explorer.
Therefore: the world schema gains producer/consumer **waiting flags**; every
wake is conditional on them; the transition relation is restated as a
model-level abstraction over the kernel graph containing block transitions;
and "send enabled" is defined over the projection. Spurious wakeups cannot
occur (wakes are exact and explicit) and close-while-sender-blocked is
unreachable in this configuration; both are named in the omissions list.

### G3 (amends D5 invariant): `:failed` added to the violation disjunction

`classify` puts `:failed` first (`kernel.clj:322-327,530-535`); without this
clause a step-fn defect becomes a silently-counted terminal while the corrected
control returns `:completed`.

### G4 (amends D5 controls): clause 3 made non-vacuous by a second fault-injected control

A second fault-injected control uses the producer program `send-a, close,
send-b`, expecting the no-send-after-close clause (clause 3) to fire. (The
original configuration can never reach a pending send after close, so clause 3
was untestable as configured; a documented-vacuous downgrade was considered
and rejected in favor of the cheap strengthening control.)

### G5 (amends D5 TCB): two rows added

- **Invariant function:** per-clause known-SAT probe fixtures. The buggy
  close-drop preserves prefix-ness, so clause 2 (prefix) is never exercised by
  the named buggy control; clauses 1, 2, 3, and the `:deadlock` clause each
  require their own probe.
- **Persisted-trace EDN reader:** malformed/truncated/forged-document rejection
  fixtures, including the documented end-of-input-sentinel regression.

Also named: the canonical value/restore round-trip underpins both state
identity and evidence canonicalization (covered by the canonical-projection
row, now explicit); fixture-to-test wiring remains trusted and is acknowledged.

### G6 (minors, recorded)

- Non-vacuity verification mechanism named: literal scripted-path fixtures with
  `restore-projection` asserts (the existing idiom at
  `explore_states_test.clj:379-385`) or per-class probe invariants expecting
  `:violation`.
- `:max-states` (explorer state cap, `explore_states.clj:54-59`) is named
  beside `:max-steps` (kernel transition budget); the two are never conflated.
- Execution scheduling: D5 evidence remains `[assumed]` until the jolt-sim
  landing order explicitly schedules it (requires a jolt-sim landing-order
  amendment); recorded as a dependency, not a claim.
- Pin recency resolved by the primary via `git merge-base`: `588677b` is an
  ancestor of `eb7bce4` (verified 2026-08-01); C2's pin is the newer main.
- Name-collision fix: "the Flow plan" = the Maelstrom/Flow implementation plan
  document; "F4" denotes only amendment F4.
