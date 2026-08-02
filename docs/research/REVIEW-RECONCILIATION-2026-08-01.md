# Phase 3 Review Reconciliation — 2026-08-01

**Scope:** dispositions for every finding in `reports/P6-CLAUDE-DESIGN-CHALLENGE.md`
(Claude Sonnet, vendor-independent) and `reports/P7-DEEP-REVIEW-CHALLENGE.md`
(`jolt-deep-reviewer`, Kimi K3, fresh-context internal).
**Authority:** primary orchestrator reconciles; user approved decision-level
clarifications C1–C5 on 2026-08-01.
**Amendment location:** `DECISION-MEMO-2026-08-01.md` §Amendments 2026-08-01.
Subagent reports (P1–P5) are NOT rewritten; corrections live in the memo
amendments and this file.

## Citation verification outcomes

| Citation | P6 | P7 | Disposition |
| --- | --- | --- | --- |
| Ordinary `:invoke` observably L-to-R (`backend_scheme.clj:429-473,909-930`) | verified | verified, lines exact | accepted as charter fact |
| IR annotation surface (`ir.clj:100-168`) | verified | verified in substance; wording imprecise (13 optional keys, none provenance-bearing) | accepted with corrected wording (memo §Amendments) |
| Host interop operand order unfixed (`backend_scheme.clj:1302-1353`) | verified | verified, lines exact | accepted as charter fact |
| jolt-sim kernel + explore-states BFS/projection/replay (`kernel.clj:445-621`, `explore_states.clj:1-26`) | verified | verified, lines exact | accepted as charter fact |
| Extra (P7 only): explore fixture counts, hermetic fail-closed (`runtime.clj:942-996`), replay validation (`kernel.clj:667-698`), monitor fold (`monitor.clj:100-146`) | — | verified | accepted as charter facts |
| Baseline SHA `021b0b72` | — | unverifiable in subagent environment | verified by primary at worktree creation (`git log`) |

## Finding dispositions

### P6 (Claude) findings

| Finding | Severity | Disposition |
| --- | --- | --- |
| D1 A3 "strictly better" is asserted, not derived | MAJOR | **accepted** → C1 amendment: A3 recorded as architect judgment; A2-minimal is the only committed build; promotion needs a named consumer + fresh review |
| D5/F4 resolution asserted, not demonstrated | MAJOR | **accepted** → C2 amendment: F4 quoted verbatim; resolution by lane priority; claim scope "TCB-validation-only, empty refinement relation"; substrate dependency recorded |
| P3 §4 evidence table drops "after execution" qualifier | MINOR | **accepted** → wording correction recorded; charter uses corrected text (P3 report itself not rewritten) |
| D9 "never Hegel" too absolute | MINOR | **accepted** → scoped: sequential-model variants remain Hegel-`sampled`; only concurrent/timed variants route to jolt-sim |
| Site-ID (D1) vs descriptor `site-id` (D4) same space? | QUESTION | **accepted** → C4: one ID space; widening-site rule for Dynamic-opaque code |

### P7 (jolt-deep-reviewer) findings

| Finding | Severity | Disposition |
| --- | --- | --- |
| B1: CSIR v1 not decision-writable (fields/version/owner/exit) | BLOCKER | **accepted** → C1 amendment fixes field set, version pin, validator owner, exit test |
| M1: D7 rules on an excluded object; "(executable-derived)" unevidenced; accident-canonization risk | MAJOR | **accepted** → C3 replaces D7: conformance-test authority only; no formal numeric-`=` claim in v1; tag dropped |
| M2: D5 mischaracterizes F4's priority objection; milestone has empty refinement relation | MAJOR | **accepted** → C2 amendment (as above) |
| m3: "no state cap" wording (explorer requires positive `:max-states`) | MINOR | **accepted** → "`:completed`, never `:state-limit`" |
| m4: "only optional :pos" imprecise | MINOR | **accepted** → corrected wording |
| m5: registered-callback sentence truncated | MINOR | **accepted** → completed: "…may be narrowed to a named capability lane" |
| m6: "selected throw/try/catch/finally" never enumerated | MINOR | **deferred to charter §2** — the fragment definition enumerates the exact form set |
| m7: explorer edge-count does not exist yet; dependency unstaged | MINOR | **accepted** → recorded in C2/D5 staging: edge count lands before the non-vacuity metric is claimed |
| m8: P3 `:steps :steps` typo | MINOR | **accepted** → noted in amendments |
| q1: max-steps-7 asserted, not derived | QUESTION | **accepted** → derivation recorded (≤6 task transitions + one slack) |
| q2: P4 Row-1 sampled equality vs D6/D7 exclusion | QUESTION | **resolved** — charter will state: sampled runtime equality testing is in scope; formal equality is out of v1 scope |
| q3: cross-lane evidence-acceptance owner unassigned | QUESTION | **accepted** → C5: this lane owns acceptance until Codex handoff, then Codex |

### P6 charter blockers (dispositions)

1. No staged exit criteria → **deferred to charter §9** (hard requirement recorded).
2. CSIR↔descriptor ID unification → C4.
3. D9/differential-loop circular dependency → **resolved by ordering**: CSIR v1 +
   reference evaluator first (milestone M1), generated Hegel cases second;
   jolt-hegel API additions remain deferred past that. Charter §6/§9 states the order.
4. D5 vs jolt-sim roadmap → C2.
5. No owner for CSIR schema/versioning → C5.
6. Cross-lane baseline mismatch deferred, not resolved → C2 records the
   0.5.13-substrate dependency explicitly; D10 unchanged (jolt-sim lane owns its pivot).

### P7 charter blockers (dispositions)

1. B1 → C1. 2. m6 → charter §2. 3. M1 → C3. 4. M2 → C2.
5. m7 → C2/D5 staging. 6. q3 → C5.

### P7 open questions (dispositions)

- q1–q3: resolved as above.
- "Does the jolt-sim remint affect D3's `schema/IR version` metadata for
  pre-remint evidence?" → **answered by D3 itself**: every evidence record
  carries its schema/IR version and source digests; pre-remint records remain
  valid evidence *under their recorded versions* and are never silently
  promoted across a remint. Charter §5 states this rule.

## Overclaim scan results

- P6: no lattice violations beyond the P3 §4 qualifier (fixed).
- P7: no lattice violations; closest approaches fixed by C3 and m3.
- P2:49 "strictly better technically" → reclassified as architect judgment (C1);
  charter must not present it as a grounded comparison.

## Fable candidates (user-directed: all four approved 2026-08-01)

Sequential execution, one Claude task at a time, per-slice budget cap $10,
read-only, bounded to its slice:

| Slice | Scope | Timing | Status |
| --- | --- | --- | --- |
| 1 | D1 identity spine: A3-vs-A2 judgment honesty, site-ID / macro-digest-chain / declared-anchor rule, C4 unification consequences (incl. site-IDs for eval'd/dynamically resolved code) | now | dispatched |
| 2 | D5/F4 reconciliation + P3 mailbox transition relation, invariant, controls adequacy (incl. max-steps derivation) | after slice 1 | pending |
| 3 | site-ID ↔ descriptor unification cross-section check | after charter §4/§6 drafted | pending |
| 4 | D3/C2 lattice soundness + one record-schema sufficiency (Hegel seed-only replay vs jolt-sim action-path replay) | before charter §5 finalized | pending |

Each slice gets a cost/quality report; the user may halt remaining slices at any
checkpoint. Fable output is advisory; primary owns acceptance.
