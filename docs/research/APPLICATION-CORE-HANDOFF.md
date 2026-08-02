# Jolt Application Core Charter — Lane Handoff

**Status:** active research lane; Phase 1 grounding complete except P3; preparing
for an OpenCode restart to load new bounded agent profiles.
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
| `docs/research/reports/P1-SEMANTIC-FACTS-REGISTER.md` | primary orchestrator (this lane) | unreviewed working artifact |
| `docs/research/reports/P2-DECISION-ALTERNATIVES-MEMO.md` | primary orchestrator (this lane) | unreviewed working artifact |
| `docs/research/reports/P4-EXECUTABLE-OBLIGATIONS-MATRIX.md` | primary orchestrator (this lane) | unreviewed working artifact |
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
| P3 first proof target design | `formal-methods` | `openai/gpt-5.6-terra`, high | docs + P1 register | **pending — dispatch after restart** (prompt essence below) |
| Phase 1.5 model trial | `jolt-structure-auditor` via dispatcher `-m fireworks-ai/accounts/fireworks/models/deepseek-v4-flash-0731` | default | 4 research docs, read-only | **timed out at 300s, session aborted** (`ses_0400e39acffek30lUV0PJ2w4EZ`); superseded by the new `jolt-research-auditor` profile — retry after restart with 600s budget |
| Phase 3 design challenge | external Claude CLI | `sonnet`, high, plan mode, read-only | decision memo + live source | pending (after Phase 2) |
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

None yet. Charter-phase semantic decisions are explicitly deferred to the user
after the Phase 2 decision memo.

## Rejected alternatives

None yet.

## Open questions

From P1 (source-grounded):
1. Which source is authoritative for numeric `=`: README category-aware claim or
   conformance register's category-blind behavior?
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
- Never push, never open a PR.
- To resume: read this file, then `git status`/`git log` in the worktree.

## Checkpoint log

| # | Commit | Contents | Reviewed by user |
| --- | --- | --- | --- |
| 1 | `62352c15` | handoff skeleton | yes (plan approved) |
| 2 | (pending) | P1/P2/P4 reports + handoff state + infra record | pending |
