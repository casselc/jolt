# P12 — Evidence lattice soundness review (slice-4 replacement)

**Provenance:** `jolt-deep-reviewer` in-session subagent, session
`ses_03f20f3fbffeAvYaaszgzb3rCE`, model
`fireworks-ai/accounts/fireworks/models/kimi-k3` (profile default), read-only,
2026-08-01. Bounded review of charter §5 (evidence taxonomy) against memo
D3/C2/F4/F5/D9/D5+G, P4, jolt-sim `explore_states.clj`/`kernel.clj`,
`hegel/core.clj`/`stateful.clj` (citations verified by the reviewer where named).
**Status:** ADVISORY. Dispositions: **all 8 findings accepted** and applied to
§5 on 2026-08-01 (before §5 commit). This was the replacement for the cancelled
Fable slice 4; same-model-family caveat applies (internal challenge, not
vendor-independent).

---

# Review: §5 Evidence Taxonomy — slice-4 (advisory)

**Verdicts:** Q1 lattice: **sound-with-amendment**. Q2 record schema: **unsound-as-written**. Q3 never-promote: **sound-with-amendment**. Q4 terminology: **sound-with-amendment**.

**Sources verified directly:** charter §1–§9; memo D3 :42–57, F4 :271–276, F5 :278–287, D9 :109–115, C2 :160–176; P4 :15–17, :74–88; `stateful.clj:303–304` (trace = `(:name item)`, rule names only — confirmed); `explore_states.clj:18–19,141–144,170–174` (action-path replay; `:completed` returns no witness/path — confirmed); `kernel.clj:667–694` (replay validates schema, choice-events, unused-choices, per-event projection diff — confirmed); `hegel/core.clj:313,367,392` (seed-only public replay; `replay-failure!` in-process — confirmed).

## Findings (ranked)

**F1 — BLOCKER [OBS]: §5.4's replay-coordinate quadruple is unfulfillable by the charter's own first producers.** Charter mandates "canonical replay coordinates (seed, choices/actions, trace digest, witness)" for *every* record. (a) Hegel: public cross-process replay coordinate is `:seed` **only** (P4:17, `core.clj:392`); stateful traces carry rule names, args re-derived not persisted (P4:76, `stateful.clj:304`); no trace document exists to digest; D9 explicitly *defers* arg-persisting traces. "choices/actions" and "trace digest" cannot be produced. (b) jolt-sim clean pass: a `:completed` exploration returns `{status, visited, terminals}` — no witness, no path, no choices (`explore_states.clj:141–144`); its reproduction coordinate is the sim-config + relation + bound digests. (c) §6 already plans Hegel persistence as "concrete source + Hegel seed + versions" — a §5.4-nonconformant record, so the section contradicts the charter's own differential loop. *Smallest amendment:* make coordinates producer-typed: "replay coordinates are per-producer: Hegel = {seed, tool versions, minimized-source?}; jolt-sim exploration = {sim-config digest, transition-relation digest, bounds, witness-path? on violation}; monitor = {trace digest, coverage declaration}."

**F2 — MAJOR [INF]: `sampled` + `monitored` bundle → `bounded-complete` is not textually excluded.** §5.2 says bundles "combine" when claim ID/scope match but never defines the combination's level; in the depicted order the join of `sampled`∨`monitored` is `bounded-complete`. §5.1 blocks it only under strict reading. This is exactly the misreading the lattice exists to prevent. *Smallest amendment:* "A bundle's level is the strongest single member's; combination never promotes. No set of `sampled` and/or `monitored` records is `bounded-complete`."

**F3 — MAJOR [OBS]: pre-remint (v1, live) and pre-anchor (A3-conditional) `failed` records are laundered.** §5.1: `failed` "blocks any promotion of the claim until the failure is resolved and re-evidenced." But remint orphans *all* records and anchors restart claims at `assumed`; §5.3 rules 7–8 forbid only *positive* evidence transfer. Nothing carries the *blocker* forward: post-remint/post-anchor, a claim with an unresolved counterexample has no `failed` attached. *Smallest amendment:* "Anchor and remint records must enumerate unresolved `failed` records on the old digest with per-record disposition (resolved / re-evidenced / waived with reviewer identity); an undispositioned failure blocks the new claim at `failed`."

**F4 — MAJOR [OBS]: §5.5 uses four level values absent from §5.1's closed enumeration and unpositioned in §5.2.** §5 opens "exactly one evidence level" over "the seven levels", yet §5.5 assigns ceilings `probed`/`runtime`, `inconclusive`, and §5.3 rule 10/§3.1 use `simulated` as a level; `inconclusive` recurs as an outcome class with no lattice position. Internal contradiction inside the reviewed section. *Smallest amendment:* either add lattice positions for `probed`/`runtime` or reclassify them plus `simulated` as lane tags and `inconclusive` as a result status, and restate the enumeration accordingly.

**F5 — MINOR [OBS]: "divergent differential" (`failed` row) collides with §2.6/rule 3.** §2.6 classifies bounded divergence `:timeout` as "inconclusive… never evidence," rule 3 says "a timeout is `inconclusive`, always" — yet the row makes "a… divergent differential" `failed` evidence. *Fix:* replace with "a differential counterexample (mismatched terminal outcomes per §2.6)."

**F6 — MINOR [OBS]: §5.2's scope-match list omits two mandatory §5.4 identity fields.** Bundle comparability lists "transition relation/abstraction digest, bounds, fairness, host assumptions" but not **schema/IR version** or **target tuple**, both mandatory — so cross-remint bundling and cross-target laundering (runtime-pass on tuple A displayed for tuple B) are blocked only by §4.3/non-goal 10, not by the promotion discipline itself. Also [INF] state-identity/projection function is only implicitly inside "abstraction digest". *Fix:* "scope = the full §5.4 record identity: relation, abstraction (incl. canonical state-identity/projection), bounds, fairness, host assumptions, schema/IR version, target tuple."

**F7 — MINOR [OBS]: §5.4 "remain valid under their recorded versions" softens F4's "orphans all prior evidence records".** "Valid" invites display-as-current; §5.6's display rules don't cover orphaned records. *Fix:* "remain readable as historical records under their recorded versions; orphaned for all current-claim display and promotion (F4)."

**F8 — MINOR [OBS]: §5.5 "example evidence (`sampled` with literal cases)".** Legitimate specialization, not a lattice violation — the parenthetical pins it to `sampled` — but the column is "Level ceiling" and the cell's headline token is an unlisted 8th label. *Fix:* cell reads "`sampled` (literal-case examples)."

## Unverified citations
- §5.3 rule 9's "P5 B.18" — P5 not in provided material.
- P11 precedents: Cedar §4.4, Hydro "exhaustive" docs, Dafny-stability, P5 B.16 — outside named roots.
- Memo D3 :42–57 substance matches §5.1–§5.4 (including the same F1-affected quadruple at :55–57); C2 :169–173 verifies rule 5's "empty refinement relation"; D9 :115 verifies "always `sampled`."

## Open questions
1. After a `failed` is "resolved and re-evidenced", from what level does re-evidence start — `assumed`, or the pre-failure level? Unspecified.
2. When is a state-cap result ever `failed` rather than `inconclusive` (absent a violation witness, which would be `failed` on its own)?
3. Should the D5/mailbox record (§7, jolt-sim producer) be the conformance fixture for whatever per-producer coordinate schema F1's amendment adopts?

**Summary for orchestrator:** one blocker (F1), three majors (F2–F4), four minors. F1–F3 each resolve with a single sentence; F4 needs a small classification decision. Lattice core (C2 ordering, incomparability, claim-relativity) is sound as far as the cited material supports.

---

## Orchestrator dispositions (2026-08-01) — ALL ACCEPTED and applied to §5

- F1 → §5.4 replay coordinates are now **producer-typed** (Hegel `{seed, tool
  versions, minimized-source?}`; jolt-sim exploration `{sim-config digest,
  transition-relation digest, bounds, witness-path?}`; monitor `{trace digest,
  coverage declaration}`); D5 mailbox execution named the conformance fixture
  (answers reviewer open question 3).
- F2 → §5.2: "A bundle's level is the strongest single member's; combination
  never promotes. No set of `sampled` and/or `monitored` records is
  `bounded-complete`"; diagram annotated (level order, not bundle semantics).
- F3 → new **failed-disposition rule** (§5.3): anchor/remint records must
  enumerate unresolved `failed` records with per-record disposition;
  undispositioned failure blocks the new claim at `failed`.
- F4 → new **terminology note** (§5.3): seven levels are the only levels;
  `probed`/`runtime`/`simulated` are evidence-kind tags; `inconclusive` is a
  result status; state-cap = `inconclusive` unless a violation witness exists
  (answers reviewer open question 2).
- F5 → `failed` row now reads "differential counterexample (mismatched
  terminal outcomes per §2.6)".
- F6 → scope = full record identity incl. canonical state-identity/projection,
  schema/IR version, target tuple.
- F7 → records "remain readable as historical records; orphaned for all
  current-claim display and promotion (F4)".
- F8 → §5.5 cell now "`sampled` (literal-case examples)".
- Reviewer open question 1 (re-evidence start level): answered in the §5.1
  `failed` row — re-evidencing is a new evidence chain; the historical
  `failed` record remains attached with its disposition.
