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
| 1 | D1 identity spine: A3-vs-A2 judgment honesty, site-ID / macro-digest-chain / declared-anchor rule, C4 unification consequences (incl. site-IDs for eval'd/dynamically resolved code) | completed 2026-08-01 | report `reports/P8-FABLE-SLICE1-IDENTITY-SPINE.md`; F1–F7 user-approved and applied to memo |
| 2 | D5/F4 reconciliation + P3 mailbox transition relation, invariant, controls adequacy (incl. max-steps derivation) | completed 2026-08-01 ($3.47 of $10 cap) | report `reports/P9-FABLE-SLICE2-PROOF-TARGET.md`; 2 blockers + 4 majors; amendments G1–G6 **user-approved and applied to memo** |
| 3 | site-ID ↔ descriptor unification cross-section check | after charter §4/§6 drafted | pending |
| 4 | D3/C2 lattice soundness + one record-schema sufficiency (Hegel seed-only replay vs jolt-sim action-path replay) | before charter §5 finalized | pending |

Each slice gets a cost/quality report; the user may halt remaining slices at any
checkpoint. Fable output is advisory; primary owns acceptance.

## Fable slice-1 dispositions (user-approved 2026-08-01)

| Amendment | Content | Disposition |
| --- | --- | --- |
| F1 | CSIR v1 schema closed; anchors undeclarable in v1; anchor rule A3-conditional | **accepted** — makes the A3 promotion gate real (any A3 feature forces a remint → core-lane review) |
| F2 | Site-ID = digest of normalized expanded form at the site; macro-definition chain demoted to provenance metadata outside the ID | **accepted** — blocker fix; also removes the uncomputable-digest problem for prebuilt macros (`host-contract.ss:285-295`) |
| F3 | Normative normalization algorithm as charter appendix; C1 exit test gains cross-run/cross-implementation ID determinism vectors | **accepted** — F2 is unimplementable without it |
| F4 | Prerelease remint orphans all evidence records (declared; detectable via D3 metadata); post-v1 remints emit old→new ID migration records | **accepted** |
| F5 | Evidence never transfers across an anchor; post-anchor claims restart at `assumed`; anchor record carries old/new digests, expansion diff, differential-run evidence ID, reviewer identity, equivalence argument | **accepted** — kills the false-equivalence abuse case; reviewer judgment + mandatory differential corpus is the control |
| F6 | Descriptor carries a CSIR site-ID or a reserved enumerated `host-origin` ID (registration site + entry-kind); absent site-id = validation failure | **accepted** — covers handwritten host-layer Scheme and native-thread callback firings |
| F7 | Dynamic-opaque attribution declared descriptor-level; `operation-id` cardinality defined | **accepted with refinement**: `operation-id` = per-instance unique (aligns with jolt-sim stable operation-ID practice); `operation` remains the per-kind tag |

Fable slice-1 verdict context preserved in P8: 1 blocker (macro-digest churn),
4 majors (gate leak via anchors in D1 text; uncomputable definition digests;
non-deterministic normalization spec; host-origin site-ID dangling case), 3
minors, 2 questions. D1's core direction (structural key, never line/column)
survived adversarial review and was verified against live source.

## Fable slice-2 dispositions (user-approved 2026-08-01; applied as G-amendments)

Report: `reports/P9-FABLE-SLICE2-PROOF-TARGET.md`. Cost $3.47 (cap $10).
All source analysis hand-simulated by Fable against live jolt-sim source;
nothing executed (read-only fence). Two blockers, four majors; D5/C2 direction
survives ("mailbox remains the right first target after the encoding and bound
amendments").

| Amendment | Content | Primary disposition |
| --- | --- | --- |
| G1 (blocker) | Re-derive step bound counting block transitions: guard failure ⇒ `step-block` consumes a step; longest quiescence path = 10 (9 if consumer initially blocked); `max-steps` 11 (one slack); keep `:step-limit` in the violation disjunction as the checked bound control | **recommend accept** — without this, the corrected control returns `:violation` via its own `:step-limit` clause (P3:117-123) |
| G2 (blocker) | World schema gains producer/consumer waiting flags; every wake conditional on them (unconditional wake throws outside the step-fn catch, kernel.clj:187-190,357-363); transition relation restated as model-level abstraction over kernel block transitions; "send enabled" defined over the projection | **recommend accept** — the guard-style "enabled iff" relation does not exist in the kernel (`machine-actions` enumerates runnable tasks only) |
| G3 (major) | Add `status = :failed` to the invariant disjunction (kernel.clj:322-327,530-535) | **recommend accept** — otherwise a step-fn defect passes silently |
| G4 (major) | Clause 3 (no-send-after-close) made non-vacuous by a second fault-injected control: producer program `send-a, close, send-b`, expecting the clause-3 probe to fire | **recommend accept** — preferred over documented-vacuous downgrade; cheap and strengthens the suite |
| G5 (major) | Two TCB rows: invariant function (per-clause known-SAT probes — the buggy drop preserves prefix-ness, so clause 2 needs its own probe) and persisted-trace EDN reader (malformed/truncated/forged rejection incl. the end-of-input-sentinel regression) | **recommend accept** |
| G6 (minors) | Name non-vacuity mechanism (scripted-path fixtures with `restore-projection` asserts / per-class probe invariants); name `:max-states` beside `:max-steps`; execution scheduling recorded as "needs jolt-sim landing-order amendment or stays `[assumed]`"; pin recency resolved by primary (`588677b` is ancestor of `eb7bce4`, git merge-base verified 2026-08-01 — C2's pin is the newer main); "F4" name collision fixed (memo refers to "the Flow plan"; "F4" denotes only the amendment) | **recommend accept** |

Verified-sound elements (no amendment needed): the buggy 5-action witness
(hand-simulated as the shortest witness firing only at its final state); the
edge-count staging (explorer verifiably has no edge counter); C2's lane-priority
resolution (F4 assigns the mailbox a role — "useful later control for state
identity and reduction soundness" — and F4:14-15 explicitly permits bounded
claims on the cooperative-model track; residual gap is only unscheduled
execution); the non-vacuity state-class set (mechanism naming via G6);
`:step-limit`-as-violation design (kept as the bound's checked control).
