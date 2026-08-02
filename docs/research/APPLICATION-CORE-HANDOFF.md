# Jolt Application Core Charter — Lane Handoff

**Status:** active research lane; Phase 4 charter drafting in progress;
**target baseline pivoted to upstream v0.5.17 (2026-08-01)** — see pivot section.
**Durable source of truth:** this file. Chat/session summaries are secondary.

## Coordination pivot to v0.5.17 (2026-08-01, Codex handoff via user)

- **New target baseline:** upstream Jolt v0.5.17, tag commit
  `da59e49dbe8c810e05aa2ce900a95c5a1ef0c9fe` ("Merge PR #516
  fix/string-surface-gaps"). Verified locally: tag `v0.5.17` contains it.
  Read-only reference worktree: `/home/chuck/ai-src/worktrees/jolt-v0517-reference`
  (DETACHED at the tag).
- **Codex-reported baseline evidence:** clean upstream v0.5.17 unit suite
  1195/1195 — reported, NOT independently re-run by this lane.
- **Upstream now owns:** monotonic clock as `jolt.host/mono-nanos`; telemetry;
  TimeUnit; timed-wait and Thread.join fixes; nREPL/editor improvements;
  CLI/dependency tooling; String APIs. Codex preserves upstream decisions and
  remints only still-needed fork functionality (their items 1–10: arraycopy,
  executor admission, exact-width FFI, atomic native-error, ranged transfers,
  scoped loans, sim image, future lifecycle hooks, unified sim controller on
  v0.5.17 + mono-nanos, Linux CI + x64 Windows validation).
- **This lane's git base REMAINS `021b0b72`** (historical; per coordination
  boundaries: continue in this worktree, no rebase/rename of the
  `v0513`-named branch). Charter *target* becomes v0.5.17 semantic contracts.
  Do not design for compatibility with v0.5.12/v0.5.13 or earlier fork
  behavior; "v0513" names are historical.
- **Codex design guidance adopted (affects charter):** portable source-level
  model, not coupled to v0.5.13 compiler internals, not waiting on the runtime
  remint; clocks as abstract effect with distinct monotonic vs wall-clock
  semantics (monotonic maps to `jolt.host/mono-nanos` on v0.5.17); **effects
  extensible by applications/libraries, NOT a compiler-closed enumeration**;
  native/FFI effects support pass-through / modeled / record-replay / hybrid
  policies and simulation must not prohibit deliberately calling the real OS;
  simulator handlers control existing application/library boundaries, never
  reimplement libraries.
- **Fable: slices 3 and 4 CANCELLED.** The handoff explicitly does not
  authorize additional Fable usage; existing P8/P9 artifacts remain inputs.
  Remaining review load shifts to `jolt-reviewer` (Phase 5) and
  `jolt-deep-reviewer` (unaffected — not Fable).
- **P10 dispatched:** targeted refresh of P1's load-bearing facts against
  v0.5.17 (`jolt-runtime-engineer`, read-only, using the v0517 reference
  worktree). The charter's semantic contracts are source-level and expected to
  survive; line-level citations and the mono-nanos/telemetry/timed-wait deltas
  are what P10 refreshes.
- **Amendment queue:** H1 (D4/D2 effect vocabulary OPEN and extensible):
  **user-confirmed 2026-08-01**; applied to memo. H2 (charter baseline =
  v0.5.17): applied; coordination-mandated. **H3 (extensibility governance):
  user-decided 2026-08-01 — E2+E3 (core-reserved `:jolt.effect/*` set +
  policy tiers) with multimethod-style derivation as the mechanism (user's
  proposal); derivation optional-but-rewarded, standalone families default to
  tier (b) pass-through-only.** Sub-decisions S1–S3 (single-parent tree v1,
  no schema inheritance v1, tier-(a) registration validation) **user-confirmed
  2026-08-01**.
- **PR flag:** Codex says "keep the public draft PR current"; Chuck's standing
  rule for this lane is never push/open a PR. Holding Chuck's rule pending
  explicit reversal.
- **Codex deliverables mapping:** identities (entity/operation/request/
  transaction/attempt), lifecycle state machines, linearization/commit/
  publish/durability points, cancellation/retry/timeout/cleanup/ambiguous
  outcomes, extensible effect/handler contract, minimal adapter points →
  charter §3/§4/§5/§8 content + a new companion artifact (whole-system
  HTTP→command→SQLite→outbox flow model + requested-runtime-seams register)
  scheduled after §8; bounded proof models + witness→schedule/Hegel/shrink/
  replay path → §7/§8 (already designed via D5/G); deterministic scenario
  inputs + canonical trace/evidence schemas → §5/§8.

## Identity

- **Worktree:** `/home/chuck/ai-src/worktrees/jolt-v0513-application-core-charter`
- **Branch:** `opencode/v0513-application-core-charter`
- **Base SHA:** `021b0b729bdc11264864bc0033cb1b64b3cde5e3`
  (`feat(ffi): expose scoped byte-array pointer loans`, v0.5.13 rebase candidate)
- **OpenCode session ID:** `ses_04018877dffefBhqS1gSe0NDwK`
  ("Jolt Application Core Semantic Charter orchestration")
- **Primary orchestrator model:** `fireworks-ai/accounts/fireworks/models/kimi-k3`
- **Lane owner (primary agent):** jolt-ecosystem orchestrator (OpenCode)
- **Created:** 2026-08-01

## Objective

Produce a decision-ready **Jolt Application Core Semantic Charter** grounded in
live v0.5.13 source. Nine required sections: (1) initial Application Core
profile + non-goals; (2) deterministic evaluation order + observable semantics
for the first pure data/function/error fragment; (3) boundary between ordinary
Jolt, Dynamic/opaque, host capabilities, and simulation handlers;
(4) provenance, stable semantic site IDs, schemas/effects, assumptions;
(5) evidence taxonomy: proved | bounded-complete | sampled | monitored |
assumed | opaque | failed; (6) first executable differential-validation loop
(ordinary Jolt source → semantic IR/reference behavior → compiled Jolt);
(7) one small first proof target with buggy SAT control, corrected claim,
non-vacuity control, executable regression, assumptions, bounds, TCB;
(8) how schemas/contracts, Hegel, jolt-sim traces/monitors, and later external
solvers consume one semantic/evidence model without separate user-facing
languages; (9) exact staged exit criteria (charter, reference evaluator,
schema prototype, first verified kernel).

No compiler/runtime implementation until charter + first proof target accepted.

## Current ownership

| Path (relative to worktree) | Owner | State |
| --- | --- | --- |
| `docs/research/APPLICATION-CORE-HANDOFF.md` | primary orchestrator (this lane) | editing |
| `docs/research/reports/P1-SEMANTIC-FACTS-REGISTER.md` | primary orchestrator (this lane) | unreviewed working artifact |
| `docs/research/reports/P2-DECISION-ALTERNATIVES-MEMO.md` | primary orchestrator (this lane) | unreviewed working artifact |
| `docs/research/reports/P4-EXECUTABLE-OBLIGATIONS-MATRIX.md` | primary orchestrator (this lane) | unreviewed working artifact |
| `docs/research/reports/P3-FIRST-PROOF-TARGET-DESIGN.md` | primary orchestrator (this lane) | unreviewed working artifact |
| `docs/research/reports/P5-RESEARCH-DOC-CLAIM-CHECKLIST.md` | primary orchestrator (this lane) | unreviewed working artifact |
| `docs/research/reports/P6-CLAUDE-DESIGN-CHALLENGE.md` | primary orchestrator (this lane) | advisory review, reconciled |
| `docs/research/reports/P7-DEEP-REVIEW-CHALLENGE.md` | primary orchestrator (this lane) | advisory review, reconciled |
| `docs/research/reports/P8-FABLE-SLICE1-IDENTITY-SPINE.md` | primary orchestrator (this lane) | advisory review; F1–F7 approved and applied |
| `docs/research/reports/P9-FABLE-SLICE2-PROOF-TARGET.md` | primary orchestrator (this lane) | advisory review; G1–G6 approved and applied |
| `docs/research/reports/P10-V0517-REFRESH-REGISTER.md` | primary orchestrator (this lane) | unreviewed working artifact; **citation authority for charter** |
| `docs/research/reports/P11-EXTERNAL-REFERENCE-AUDITS.md` | primary orchestrator (this lane) | incorporations approved and applied |
| `docs/research/reports/P12-EVIDENCE-LATTICE-REVIEW.md` | primary orchestrator (this lane) | advisory review; all 8 findings accepted and applied |
| `docs/research/reports/P13-SITE-ID-UNIFICATION-REVIEW.md` | primary orchestrator (this lane) | advisory review; all findings accepted and applied |
| `docs/research/reports/P14-FINAL-CHARTER-REVIEW.md` | primary orchestrator (this lane) | advisory review; accept-with-amendments, all applied |
| `docs/research/APPLICATION-CORE-SEMANTIC-CHARTER.md` | primary orchestrator (this lane) | **drafting — section-by-section user review before each commit** |
| everything else in worktree | untouched at base SHA | — |

Out-of-worktree session infrastructure (not lane artifacts, not in a git repo):
- `/home/chuck/ai-src/.opencode/agent/jolt-research-auditor.md` (new profile)
- `/home/chuck/ai-src/.opencode/agent/jolt-deep-reviewer.md` (new profile)
- `/home/chuck/ai-src/tools/opencode-config/agents/jolt-research-auditor.md` (new)
- `/home/chuck/ai-src/tools/opencode-config/agents/jolt-deep-reviewer.md` (new)
- `/home/chuck/ai-src/tools/opencode-dispatch` (AGENT_POLICIES extended per-model)

External lanes (do not touch):
- Codex/OpenCode owns `/home/chuck/ai-src/worktrees/jolt-v0513-sim-controller-atomic`
- Codex/Claude owns `/home/chuck/ai-src/worktrees/jolt-sim-http-sqlite-evidence-v1`
- Canonical v0.5.13 candidate branch: read-only for this lane
- selected-Chez, provider-registry, AOT-cache work: out of scope

## Delegated agents and tasks

| Task | Agent | Model/effort | Scope | State |
| --- | --- | --- | --- | --- |
| P1 runtime semantic grounding | `jolt-runtime-engineer` | `openai/gpt-5.6-sol`, high | v0.5.13 candidate source, read-only | **completed** — session `ses_0400ee974ffeD2n1HmvHthHXhz`; report in `reports/P1-SEMANTIC-FACTS-REGISTER.md` |
| P2 semantic boundary alternatives | `simulation-formalism-architect` | `openai/gpt-5.6-terra`, high | 4 research docs + jolt-sim, read-only | **completed** — session `ses_0400ea2c9ffeIuhezqZdOrofZX`; report in `reports/P2-DECISION-ALTERNATIVES-MEMO.md` |
| P4 Hegel/differential obligations | `property-testing` | `zai-coding-plan/glm-5.2`, high | jolt-hegel + 2 research docs, read-only | **completed** — session `ses_0400e9f45ffe91J6BPnLROGN95`; report in `reports/P4-EXECUTABLE-OBLIGATIONS-MATRIX.md` |
| P3 first proof target design | `formal-methods` | `openai/gpt-5.6-terra`, high | docs + P1 register + jolt-sim kernel | **completed** — session `ses_03ffb4ccbffeEMPcSVPkOGLMRK`; report in `reports/P3-FIRST-PROOF-TARGET-DESIGN.md` |
| P10 v0.5.17 facts refresh | `jolt-runtime-engineer` | `openai/gpt-5.6-sol`, high | v0517 reference tree + P1 register, read-only | **completed** — session `ses_03fabf181ffey963aAQ9f2A0wU`; report in `reports/P10-V0517-REFRESH-REGISTER.md`. Verdicts: 7 CONFIRMED (invoke order, interop opacity, macro phase, atoms, settlement, core.async, conveyance, compile spine), 3 CHANGED (IR `:def :meta` duplication; `jolt.host/mono-nanos`+`wall-nanos` new; telemetry primitives), 1 REMOVED (sim/controller overlay — no lifecycle seam at v0.5.17) |
| P11 external reference audits (user-supplied refs) | 4× `jolt-research-auditor` (Deepseek profile, in-session) | profile default | local captures in `/home/chuck/ai-src/refs-cache/` | **completed** — Hydro `ses_03f56c807ffeopMEfiWfffZ6dn`, Cedar `ses_03f5696b8ffe77gNhKbPqjgFtd`, trio `ses_03f51390dffeTdB0JSM7AyK4RE`, provenance `ses_03f5106fdffe2VxJGkwltbBD7H`; report `reports/P11-EXTERNAL-REFERENCE-AUDITS.md`. Note: Deepseek cannot read PDFs natively (refused to fabricate — correct); PDFs extracted via uv+pymupdf to markdown. Auditor corrections: Rubydust is dynamic *type inference* (not origin tracking); ICSE'13 is EXPOSITOR time-travel debugging (not provenance); Dafny paper is the Cutler/Torlak/Hicks stability extended abstract |
| Phase 1.5 model trial | `jolt-structure-auditor` via dispatcher `-m fireworks-ai/accounts/fireworks/models/deepseek-v4-flash-0731` | default | 4 research docs, read-only | **superseded** — first run timed out at 300s pre-restart (`ses_0400e39acffek30lUV0PJ2w4EZ`); retried via new profile below |
| Phase 1.5 retry: claim-discipline checklist | `jolt-research-auditor` via dispatcher (new profile, no `-m`) | Deepseek V4 Flash 0731, profile default, 600s | 4 research docs, read-only | **completed** — session `ses_03ffb0eb6ffe7VL4SDqvMkyErG`; report in `reports/P5-RESEARCH-DOC-CLAIM-CHECKLIST.md`; trial verdict: model suitable for bounded extraction audits |
| Phase 3a design challenge (vendor-independent) | external Claude CLI | `sonnet` (latest alias, Claude Code 2.1.220), high effort, plan mode, Read/Glob/Grep only, $10 budget (user-authorized), no Fable | decision memo + reports + live v0.5.13 + jolt-sim | **completed** — report in `reports/P6-CLAUDE-DESIGN-CHALLENGE.md`; nonpersistent, no session ID |
| Phase 3b design challenge (fresh-context internal) | `jolt-deep-reviewer` | Kimi K3 (Fireworks), profile default, read-only | same material | **completed** — session `ses_03fedc27dffe5yQx7iH7RXij1y`; report in `reports/P7-DEEP-REVIEW-CHALLENGE.md` |
| Phase 3 scope rule | both reviewers flagged ≤3 sections each for later bounded Fable review; no Fable run without explicit user direction | — | — | satisfied; candidates recorded below |
| Phase 5 final review | `jolt-reviewer` | `zai-coding-plan/glm-5.2`, high | charter vs sources, read-only | pending |

Selectable model IDs verified via `opencode models` (2026-08-01):
- Kimi K3: `fireworks-ai/accounts/fireworks/models/kimi-k3`,
  `openrouter/moonshotai/kimi-k3`
- Deepseek V4 Flash 0731:
  `fireworks-ai/accounts/fireworks/models/deepseek-v4-flash-0731`,
  `openrouter/deepseek/deepseek-v4-flash-0731`

## P3 pending prompt essence (restart-safe)

Dispatch `formal-methods` (default `openai/gpt-5.6-terra`, high), read-only:
- Inputs: `docs/research/reports/P1-SEMANTIC-FACTS-REGISTER.md` (this worktree),
  the research plan (§Proof/search/evidence routing + staged plan),
  the gradual-formalism vision (guardrails), the jolt-sim architecture review
  (proof-target guidance, two tracks), `jolt-sim` `src/jolt/sim/{kernel,trace,monitor}.clj`,
  and the `prove-code-invariants` skill discipline
  (`/home/chuck/.claude/skills/prove-code-invariants/SKILL.md`).
- Deliverable: ONE recommended first proof target + ONE alternative from
  (a) transient-region scoping over bounded op model, (b) capacity-one mailbox
  send/receive/close, (c) canonical equality/hash consistency over bounded
  values. For the recommended: exact claim statement, buggy SAT control
  (known-SAT, expected witness shape), corrected claim, non-vacuity control,
  executable regression path, assumptions/bounds (cutoff ≠ pass), TCB statement.
  Plus differential-loop architecture (source → CSIR → reference evaluator →
  compiled Jolt) and evidence labels per element. Output cap 250 lines.

## Decisions accepted

All ten charter-phase decisions accepted by the user on 2026-08-01; full text,
alternatives, and rejected options in `DECISION-MEMO-2026-08-01.md`:

- **D1:** CSIR identity = A3 target (compiler-owned provenance graph, CSIR as
  versioned projection), staged via A2-minimal CSIR v1 for the first pure
  fragment; structural site IDs, never line/column hashes.
- **D2:** boundary taxonomy = B2 (conservative lane inference: ordinary-core /
  Dynamic-opaque / host-capability / simulation-handler; mechanical widening).
- **D3:** evidence lattice = C2 (claim-relative partial order + compatible
  evidence bundles + mandatory record metadata + never-promote list).
- **D4:** effects v1 = D2 (closed schema-validated core descriptors; dynamic
  innermost-first strict-LIFO substitution/abortive handlers; NO continuations
  at this layer; explicit non-goals recorded).
- **D5:** first proof target = capacity-one mailbox (send/receive/close, no
  timeout) on the existing jolt-sim cooperative kernel; buggy
  close-drops-slot known-SAT control; corrected/no-cap BFS; non-vacuity
  classes; execution is a separate jolt-sim task, not this lane.
- **D6:** initial pure fragment = P1 §§1–5 core (literals, let*/loop*/fn*/recur,
  ordered ordinary invoke, if/do, quote, selected throw/try); excludes
  concurrency, FFI, host interop (operand order UNSPECIFIED), eval,
  dynamic resolution, raw host values, unresolved reader/equality corners.
- **D7:** numeric-`=` authority = conformance register (SPEC.md +
  known-divergences.edn), not README prose.
- **D8:** `#=` = outside formal-core (opaque/excluded).
- **D9:** Hegel gaps = hand-build generators in-project; concurrency/time
  obligations route to jolt-sim, never Hegel; defer hegel API additions.
- **D10:** charter pins 0.5.13 candidate `021b0b72`; jolt-sim lane owns its own
  pivot; no cross-gap compatibility claims.

## Rejected alternatives

See `DECISION-MEMO-2026-08-01.md` §Rejected alternatives (A1, B1, B3, C1, C3,
D1, D3, D5-alternative). Phase 3 (P6/P7) did not overturn any rejection.

## Phase 3 design-challenge reconciliation (2026-08-01)

Two independent challenges (P6 Claude Sonnet, vendor-independent; P7 Kimi K3,
fresh-context internal) reviewed the decision memo + P1–P5. **All four
load-bearing citations verified with exact line numbers by both reviewers**;
P7 additionally verified the explore-states fixture counts, hermetic
fail-closed routing, replay validation, and monitor fold. No evidence-lattice
violation found. Convergent findings and primary dispositions:

Accepted wording/precision amendments (non-substantive):
- A1: P3 §4 evidence table gains the "after execution" qualifier (P6 MINOR).
- A2: "carries only optional :pos" → "only :pos carries source metadata; none
  of the 13 optional annotation keys carries provenance/site/resource/
  assumptions" (P7 m4).
- A3: "finish BFS with no state cap" → "must terminate `:completed`, never
  `:state-limit`" (P7 m3; explorer requires positive `:max-states`).
- A4: D9 "never Hegel" scoped: concurrent/timed variants route to jolt-sim;
  sequential-model variants remain Hegel-`sampled` (P6 MINOR).
- A5: registered-callback sentence completed: "…contract is declared, it may
  be narrowed to a named capability lane" (P7 m5).
- A6: P3 `:steps :steps` typo (P7 m8). A7: max-steps-7 derivation line added
  (≤6 task transitions; 7 gives one slack) (P7 q1).

Decision clarifications C1–C5: **APPROVED by user 2026-08-01** and applied to
`DECISION-MEMO-2026-08-01.md` §Amendments 2026-08-01:
- C1 (D1): A3-over-A2 recorded as architect judgment; CSIR v1 staging fixed
  (field set, version pin to `021b0b72`, future-core-lane validator owner,
  exit test = one fixed corpus case through both paths, labeled `sampled`).
- C2 (D5): F4 quoted verbatim; resolution by lane priority; milestone claim
  "TCB-validation-only, empty refinement relation"; 0.5.13-substrate
  dependency recorded.
- C3 (D7): rescoped to conformance-lane test authority only; formal v1
  fragment makes no numeric-`=` claim; "(executable-derived)" dropped.
- C4 (new): one site-ID space; descriptor `site-id` = CSIR site ID;
  Dynamic-opaque code carries the widening site's ID only.
- C5 (new): CSIR schema/versioning = future Jolt core lane; charter
  evidence-record acceptance = this lane until Codex handoff, then Codex.

Full dispositions: `REVIEW-RECONCILIATION-2026-08-01.md`.

Deferred to charter content: staged exit criteria detail (charter §9),
enumeration of "selected throw/try/catch/finally" (charter §2),
Hegel/differential ordering (CSIR v1 + reference evaluator first, generated
cases second; hegel API additions remain deferred).

Fable review: **user-directed 2026-08-01 for all four slices.** Sequential,
one Claude task at a time, per-slice budget cap $10, read-only, bounded to its
slice:
1. D1 identity spine (A3-vs-A2 honesty, site-ID/macro-digest/declared-anchor,
   C4 unification incl. eval'd-code site-IDs) — **completed**; report
   `reports/P8-FABLE-SLICE1-IDENTITY-SPINE.md`; 1 BLOCKER (macro-digest chain
   causes global ID churn) + 4 majors; amendments F1–F7 **user-approved and
   applied to memo** (F7 refined: `operation-id` = per-instance unique)
2. D5/F4 reconciliation + P3 mailbox controls adequacy — **completed**
   ($3.47 of $10 cap); report `reports/P9-FABLE-SLICE2-PROOF-TARGET.md`;
   2 blockers (kernel encoding; max-steps bound) + 4 majors; amendments
   G1–G6 **user-approved and applied to memo**
3. Site-ID ↔ descriptor unification cross-check — after charter §4/§6 drafted
4. D3/C2 lattice soundness + record-schema sufficiency — before charter §5
   finalized

## Open questions

- **I1 — RESOLVED (H5, user-approved 2026-08-01, option a):** canonical hash
  is charter-owned per type family (strings over scalar values; collections
  ordered vs order-independent); hash-consistency law including `-0.0`/NaN
  canonicalization; algorithm + test-vector suite at the schema/hash stage;
  JVM-compatible hashing = `target-dependent` interop profile only.

From P1 (source-grounded):
1. Which source is authoritative for numeric `=`: README category-aware claim or
   conformance register's category-blind behavior? (resolved by C3 for tests;
   formal claim deferred)
2. Does the live reader accept `#=` as inert syntax, or reject it?
3. Should charter "function-call evaluation order" include host interop forms?
   (P1 found ordinary `:invoke` is observably left-to-right but host
   constructor/method operands use unordered bare Scheme application.)

From P2 (user-level decision session questions):
4. CSIR identity: A1 (annotate existing IR) vs A2 (separate CSIR) vs A3
   (provenance graph + CSIR projection — architect recommends A3).
5. Claim boundary: B1 (opt-in annotations) vs B2 (conservative CSIR lane
   inference + widening — recommended) vs B3 (capability-only profile).
6. Evidence semantics: C1 (total order — recommended against) vs C2
   (claim-relative partial order + bundles — recommended) vs C3 (ledger only).
7. Effects v1: D1 (FFI-only) vs D2 (closed core descriptors + optional sim
   adapters — recommended) vs D3 (delimited control).

From P4 (Hegel gap decisions):
8. G1: hand-build recursive/AST + keyword/symbol generators vs add to jolt-hegel.
9. G2: route real-concurrency/time obligations (cross-task transient escape,
   multi-thread atom linearizability, deref timeouts) to jolt-sim, never Hegel?
10. G3: model-declared `:max-steps` bound — jolt-hegel API addition or
    jolt-model/jolt-sim concern?
11. G4: self-contained minimized operation-sequence corpus (args included)?
12. G5: named-corpus/regression-replay layer above Hegel for the differential loop?

Baseline note: jolt-sim README pins 0.5.12-derived `56d0694`; this lane's
charter baseline is the 0.5.13 candidate `021b0b72`. The 0.5.13 pivot is owned
by the parallel jolt-sim lanes, not this one.

## Commands and tests actually run

- `git worktree add` for this lane at base SHA; `git status` clean — verified
- `opencode models` — model registry enumerated (376 entries)
- OpenCode session DB queried read-only to record session/subagent IDs
- `opencode-dispatch` Phase 1.5 trial: server started, session created,
  **timed out at 300s and aborted** (no deliverable; no evidence of failure mode)
- No builds, no test suites, no Jolt/Chez compilation executed in this lane

## Unexecuted claims / nonclaims

- No claim that v0.5.13 candidate passes any suite from this lane.
- P1/P2/P4 reports are UNREVIEWED subagent outputs; citations not yet
  independently spot-verified by the primary (planned before charter drafting).
- No proof, bounded-completeness, or conformance claim of any kind yet.
- No Windows/macOS lane executed or claimed.
- Research docs are design intent, not source facts; P1 register is the
  source-grounding artifact.

## REPL state

No shared REPL in this lane for the charter phase (per plan).

## Infrastructure changes for new-model profiles (2026-08-01)

User authorized creating bounded profiles for the new models and extending
`opencode-dispatch`:
- New agent `jolt-research-auditor` — Deepseek V4 Flash 0731 (Fireworks),
  read-only, 40 steps, temperature 0.1, policy marker `jolt-policy-v1`.
  Purpose: bounded read-only research/document audits (replaces `-m` override).
- New agent `jolt-deep-reviewer` — Kimi K3 (Fireworks), read-only, 64 steps,
  temperature 0.2, policy marker `jolt-policy-v1`. Purpose: heavyweight
  fresh-context design/claim review. NOTE: same model family as the primary;
  it is an internal challenge pass, NOT a substitute for Claude's
  vendor-independent review lane.
- `opencode-dispatch` `AGENT_POLICIES` extended: each policy entry now carries
  its expected `provider`/`model`, and `ensure_agent` validates against the
  per-entry expectation instead of the hardcoded GLM check.
- Both profiles exist in `/home/chuck/ai-src/.opencode/agent/` (mode: all,
  for in-session Task use) and `/home/chuck/ai-src/tools/opencode-config/agents/`
  (mode: primary, for dispatcher use), with identical policy-relevant fields.
- **Restart required:** OpenCode loads config once; the user restarts and
  resumes session `ses_04018877dffefBhqS1gSe0NDwK`. After resume, in-session
  Task dispatch should expose the new agents (verify before relying on it);
  the dispatcher path works regardless.
- Neither new profile may receive proof/security-sensitive implementation
  work; both are read-only audit/review lanes pending trial results.

## Handoff protocol

- Checkpoint commits only after user review, author:
  `Chuck Cassel <619504+casselc@users.noreply.github.com>`
- To resume: read this file, then `git status`/`git log` in the worktree.

**Draft PR:** https://github.com/casselc/jolt/pull/12 (base
`codex/upstream-rebase-v0.5.13-candidate`, head
`opencode/v0513-application-core-charter`, created 2026-08-01).

## Pull-request policy (updated 2026-08-01, user-authorized)

- The standing "never push, never open a PR" rule is **lifted for this lane
  only**, per user direction 2026-08-01 adopting Codex coordination guidance:
  keep one public **draft** PR current with bounded, clean research slices.
- PR location: fork `casselc/jolt` only. Base:
  `codex/upstream-rebase-v0.5.13-candidate` (contains this lane's git base
  `021b0b72`, so the PR diff shows only research-lane commits). Head:
  `opencode/v0513-application-core-charter`.
- **Never push or open anything against `jolt-lang/jolt` (origin).**
- Push at each checkpoint commit; no force-push, no history rewrites, no
  branch renames. The PR body points here as the durable source of truth.
- All other ownership boundaries unchanged: no edits to compiler/rebase
  worktrees; no pushes to any other branch.

## Checkpoint log

| # | Commit | Contents | Reviewed by user |
| --- | --- | --- | --- |
| 1 | `62352c15` | handoff skeleton | yes (plan approved) |
| 2 | `9df9ec38` | P1/P2/P4 reports + handoff state + infra record | yes (restart authorized) |
| 3 | `f1825664` | P3 proof-target design + P5 claim checklist + handoff state | yes (all D1–D10 recs approved) |
| 4 | `0328c988` | decision memo (D1–D10 accepted) + handoff state | yes (design challenge authorized) |
| 5 | `6cc3966f` | P6/P7 challenge reports + reconciliation + handoff state | yes (C1–C5 approved) |
| 6 | `28f12307` | memo amendments C1–C5 + reconciliation file + Fable sequencing | yes (Fable 4 slices directed) |
| 7 | `b5f6c819` | Fable slice-1 report (P8) + handoff state | yes (F1–F7 approved) |
| 8 | `489b9a49` | memo F-amendments + reconciliation dispositions + slice-2 dispatch | yes (F1–F7 approved) |
| 9 | `01ecf4c5` | Fable slice-2 report (P9) + reconciliation + handoff state | yes (G1–G6 approved) |
| 10 | `248d4256` | memo G-amendments + Phase 4 charter drafting start | yes (pivot forwarded) |
| 11 | `b48bb60a` | v0.5.17 coordination pivot record; Fable 3–4 cancelled | recorded |
| 12 | `e79ef669` | P10 refresh register + charter baseline revision (front matter + §1) | yes (H1 confirmed) |
| 13 | `cc1059de` | H1/H2 memo amendments + handoff state | yes (E2+E3 + hierarchy directed) |
| 14 | `def4bcd9` | H3 derivation-hierarchy amendment + handoff state | yes (S1–S3 confirmed) |
| 15 | `1b3840c5`+`688aaa45` | PR policy update + draft PR #12 recorded/pushed | yes (user directed PR) |
| 16 | `315f0c0d` | H3 sub-decisions S1–S3 confirmed | yes |
| 17 | `152dd732` | charter §1 revisions: Clojure.next neutrality + §1.5 staging + H4 eager-first | yes (directions given in §1 review) |
| 18 | `a7889565` | H5 canonical-hash decision + charter §2 full draft (evaluation order + observable semantics) | **§2 accepted** |
| 19 | `4ef7053d` | P11 external reference audits + handoff state | yes (incorporation list approved) |
| 20 | `ad0e1d89` | P11 incorporations into §1.4/§3–§9 notes + charter §3 full draft (boundary taxonomy) | **§3 accepted** |
| 21 | `782b361f` | charter §4 full draft (provenance spine, site IDs, schemas/effects, assumptions) | **§4 accepted** |
| 22 | `f08cb55b` | charter §5 draft (evidence taxonomy) + P12 lattice review + amendments | **§5 accepted** |
| 23 | `e956fa45` | charter Appendix A (normative normalization algorithm) | **Appendix A accepted** |
| 24 | `a3217d53` | charter §6 draft (differential loop) + P13 cross-check + amendments | **§6 accepted** |
| 25 | `5991de22`+`9a974b6a` | charter §7 draft (first proof target) + handoff checkpoint | **§7 accepted** |
| 26 | `a3b6f12c` | charter §8 draft (one-model consumption) | **§8 accepted** |
| 27 | `484f8914` | charter §9 draft (staged exit criteria) — completes the charter | **§9 accepted; charter complete** |
| 28 | (pending) | Phase 5: P14 final review + all amendments applied | pending |

## §1 review outcome (2026-08-01)

**§1 ACCEPTED** after application of all user directions (neutrality
reframing, §1.5 staging, H4 processing model). **§2 ACCEPTED 2026-08-01**
along with the full P11 incorporation list; incorporations applied to §1.4
(support-level matrix) and the §3–§9 pending notes. **§3 ACCEPTED 2026-08-01.**
**§4 ACCEPTED 2026-08-01.** §5 drafted 2026-08-01; jolt-deep-reviewer
lattice-soundness pass (Fable-slice-4 replacement, session
`ses_03f20f3fbffeAvYaaszgzb3rCE`, report `reports/P12-EVIDENCE-LATTICE-REVIEW.md`)
found 1 blocker + 3 majors + 4 minors — **all 8 accepted and applied to §5
before commit** (producer-typed replay coordinates; bundle-never-promotes
rule; failed-disposition rule; levels-vs-tags-vs-statuses terminology; plus
4 minors). **§5 ACCEPTED 2026-08-01.** **Appendix A ACCEPTED 2026-08-01.** §6 drafted
2026-08-01; slice-3-replacement cross-check (session
`ses_03f0299eeffezA6kA7HMb3KkbS`, report `reports/P13-SITE-ID-UNIFICATION-REVIEW.md`)
found 1 blocker + 3 majors + 1 minor + 1 question-finding — **all accepted
and applied before commit**. **§1–§9 + Appendix A ALL ACCEPTED 2026-08-01 — the charter is complete and
accepted.** Phase 5 complete: `jolt-reviewer` final review (session
`ses_03ce2a213fferS1t1XO94rUVzT`, report `reports/P14-FINAL-CHARTER-REVIEW.md`)
returned **accept-with-amendments** — 2 majors (§1.2 citation cluster; NaN
canonical-comparison tension) + 4 minors + 1 question, **all accepted and
applied**. 25+ load-bearing citations re-verified against v0.5.17 + jolt-sim.
Remaining: Codex-requested companion artifact (whole-system flow model +
requested runtime seams register), then final handoff checkpoint to Codex.

User approved §1 with two directions:
1. **Implementation-neutrality (Clojure.next core):** the charter's semantics
   must be portable — implementable in jank, JVM/CLR, or native Clojure impls
   (Go/Zig/Rust) — not tied to Jolt/Chez. Applied: retitled charter scope;
   values rewritten portable-first with realization notes (e.g., strings =
   immutable sequences of Unicode scalar values; JVM UTF-16 splitting named a
   platform accident, `target-dependent`; Jolt-on-Chez = first realization,
   V17-cited); non-goal 1 generalized to "no host-accident canonization";
   canonical hash strategy opened as question I1.
2. **Coverage staging (core library, async):** answered in new §1.5 —
   clojure.core-equivalent pure kernel = next stage after reference evaluator
   (first verified-kernel candidate, equational semantics); coordination/
   async kernels staged after, gated on v0.5.17 runtime lifecycle seams;
   §7 mailbox is the seed.
3. **Processing model (H4, user-directed):** eager/transducer-first at the
   bottom with opt-in laziness — applied to memo (H4), §1.2 (processing-model
   block), and §1.5 (lazy streams opt-in with defined realization/exception/
   cancellation/resource semantics). JVM pervasive/chunked laziness named a
   host behavior, not core semantics.
