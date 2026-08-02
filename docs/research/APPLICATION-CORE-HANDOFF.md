# Jolt Application Core Charter — Lane Handoff

**Status:** active research lane, read-only grounding phase.
**Durable source of truth:** this file. Chat/session summaries are secondary.

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
| everything else in worktree | untouched at base SHA | — |

External lanes (do not touch):
- Codex/OpenCode owns `/home/chuck/ai-src/worktrees/jolt-v0513-sim-controller-atomic`
- Codex/Claude owns `/home/chuck/ai-src/worktrees/jolt-sim-http-sqlite-evidence-v1`
- Canonical v0.5.13 candidate branch: read-only for this lane
- selected-Chez, provider-registry, AOT-cache work: out of scope

## Delegated agents and tasks

| Task | Agent | Model/effort | Scope | State |
| --- | --- | --- | --- | --- |
| P1 runtime semantic grounding | `jolt-runtime-engineer` | `openai/gpt-5.6-sol`, high | v0.5.13 candidate source, read-only | pending |
| P2 semantic boundary alternatives | `simulation-formalism-architect` | `openai/gpt-5.6-terra`, high | 4 research docs + jolt-sim, read-only | pending |
| P4 Hegel/differential obligations | `property-testing` | `zai-coding-plan/glm-5.2`, high | jolt-hegel + 4 research docs, read-only | pending |
| P3 first proof target design | `formal-methods` | `openai/gpt-5.6-terra`, high | docs + P1 register | pending (after P1) |
| Phase 1.5 model trial | `jolt-structure-auditor` (dispatcher) | `fireworks-ai/accounts/fireworks/models/deepseek-v4-flash-0731` | 4 research docs, read-only | pending |
| Phase 3 design challenge | external Claude CLI | `sonnet`, high, plan mode, read-only | decision memo + live source | pending |
| Phase 5 final review | `jolt-reviewer` | `zai-coding-plan/glm-5.2`, high | charter vs sources, read-only | pending |

Selectable model IDs verified via `opencode models` (2026-08-01):
- Kimi K3: `fireworks-ai/accounts/fireworks/models/kimi-k3`,
  `openrouter/moonshotai/kimi-k3`
- Deepseek V4 Flash 0731:
  `fireworks-ai/accounts/fireworks/models/deepseek-v4-flash-0731`,
  `openrouter/deepseek/deepseek-v4-flash-0731`

## Source files inspected (by primary, so far)

Research documents (all read in full unless noted):
- `/home/chuck/ai-src/JOLT-FORMALIZABLE-APPLICATION-CORE-RESEARCH-PLAN-2026-08-01.md`
- `/home/chuck/ai-src/jolt-gradual-formalism-vision-2026-08-01.md`
- `/home/chuck/ai-src/jolt-sim-architecture-review-2026-08-01.md`
- `/home/chuck/ai-src/JOLT-SIM-MAELSTROM-FLOW-IMPLEMENTATION-PLAN.md` (lines 1–300 of 1018 so far)

Repository state verified:
- `jolt-upstream` clean; base SHA resolves; branch/path absent before creation
- `jolt-sim` at `eb7bce4` (`feat(sim): explore cooperative timer races`), clean
- v0.5.13 candidate tree layout: `jolt-core/jolt/{analyzer,ir,backend_scheme,passes}.clj`,
  `host/chez/{atoms,collections,hasheq,dyn-binding,java/concurrency,...}.ss`,
  `stdlib/`, `test/conformance/`, `vendor/clojure-test-suite`

Configuration verified:
- Agent defaults: simulation-formalism-architect + formal-methods =
  `openai/gpt-5.6-terra` high; jolt-runtime-engineer + jolt-sim-engineer =
  `openai/gpt-5.6-sol` high; property-testing + jolt-reviewer =
  `zai-coding-plan/glm-5.2` high

## Decisions accepted

None yet. Charter-phase semantic decisions are explicitly deferred to the user
after the Phase 2 decision memo.

## Rejected alternatives

None yet.

## Open questions

All substantive semantic choices open pending Phase 1 reports and user
decision session. Known decision points (from approved plan):
1. CSIR shape: annotate existing IR vs separate semantic IR vs dual emission.
2. Boundary taxonomy rules: ordinary / Dynamic-opaque / host capability /
   simulation handler classification and widening rules.
3. Evidence lattice upgrade rules between the 7 evidence levels.
4. Effect-descriptor v1 scope (closed schema-validated descriptors;
   substitution/abortive handlers only — per research plan).
5. First proof target selection (candidates: transient-region scoping,
   capacity-one mailbox, canonical equality/hash consistency).
6. Initial pure fragment boundary (exact form list for the first profile).

## Commands and tests actually run

- `git worktree add` for this lane at base SHA; `git status` clean — verified
- `opencode models` — model registry enumerated (376 entries; providers:
  openrouter 335, fireworks-ai 17, openai 13, opencode 7, zai-coding-plan 4)
- OpenCode session DB queried read-only to record session ID
- No builds, no test suites, no Jolt/Chez compilation executed in this lane

## Unexecuted claims / nonclaims

- No claim that v0.5.13 candidate passes any suite from this lane.
- No claim that any semantic fact in the research docs matches live source
  until P1's source-cited register confirms it.
- No proof, bounded-completeness, or conformance claim of any kind yet.
- No Windows/macOS lane executed or claimed.
- Research docs are treated as design intent, not source facts.

## REPL state

No shared REPL in this lane for the charter phase (per plan).

## Handoff protocol

- Checkpoint commits only after user review, author:
  `Chuck Cassel <619504+casselc@users.noreply.github.com>`
- Never push, never open a PR.
- To resume: read this file, then `git status`/`git log` in the worktree.

## Checkpoint log

| # | Commit | Contents | Reviewed by user |
| --- | --- | --- | --- |
| 1 | (pending) | handoff skeleton | pending |
