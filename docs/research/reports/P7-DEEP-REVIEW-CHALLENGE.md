# P7 — Fresh-context internal design challenge (jolt-deep-reviewer)

**Provenance:** `jolt-deep-reviewer` in-session subagent, session
`ses_03fedc27dffe5yQx7iH7RXij1y`, model
`fireworks-ai/accounts/fireworks/models/kimi-k3` (profile default), read-only,
2026-08-01. Same assignment as P6 (independent context, no knowledge of P6).
**Status:** ADVISORY. Acceptance/rejection per finding is recorded in
`../REVIEW-RECONCILIATION-2026-08-01.md` (when written) and the decision memo.
NOTE: same model family as the primary orchestrator — this is an internal
challenge pass, not vendor-independent review (P6 holds that role).

---

# Design-Challenge Review — Application Core Decision Memo (2026-08-01)

**Keys:** `MEMO` = docs/research/DECISION-MEMO-2026-08-01.md (charter worktree); `P1..P5` = docs/research/reports/*; `JOLT` = /home/chuck/ai-src/worktrees/jolt-upstream-rebase-v0.5.13-candidate; `SIM` = /home/chuck/ai-src/jolt-sim. Observation vs inference is marked; advisory only.

## Verdict summary (8 lines)

1. All four tasked load-bearing citations (D1/D5/D6 facts) verify with **exact** line numbers; substance confirmed in live v0.5.13 source and jolt-sim.
2. No evidence-lattice violation found in MEMO or P1–P5; the never-promote rules are restated consistently (MEMO:49-52; P2:122-128; P3:16,97,149; P4:15).
3. One blocker: D1 adopts "A3 target, A2-minimal first milestone" but D1–D10 never stage CSIR v1's field set, versioning, validator owner, or exit criteria — the first milestone is not decision-writable as-is.
4. D7 is the weakest decision: an authority ruling whose object D6 excludes, resting on an unevidenced "(executable-derived)" provenance claim (MEMO:101).
5. D5 survives but mischaracterizes the F4 objection as "resolved by scope" (MEMO:85-87) without citing it, and its milestone yields model-only evidence under the memo's own D3 rule.
6. Wording nits matter in an evidence-discipline charter: "carries only optional :pos" (MEMO:19) and "finish BFS with no state cap" (MEMO:77) are both imprecise against cited source.
7. P3/P5 fixture and controller citations spot-checked beyond the tasked four all verify (table below).
8. Baseline pin `021b0b72…` (MEMO:5) is **unverifiable here**: `.git/HEAD` unreadable in this environment.

## Citation-verification table (task 1)

| # | Claim | Cited | Checked at | Result |
|---|-------|-------|-----------|--------|
| a | ordinary `:invoke` observably L-to-R | `backend_scheme.clj:429-473,909-930` | `JOLT/jolt-core/jolt/backend_scheme.clj:429-473` (`emit-ordered`/`needs-order?`/`ordered-call`), `:909-930` (`emit-invoke` ordering `[fnode & args]` via `ordered-call`) | **VERIFIED**, lines exact. Chez order declared unspecified at 429-432,453-458; order forced only when `needs-order?` fires (459-462) — "observably" is the correct qualifier. P1's secondary support `analyzer.clj:1081-1088`, `ir.clj:42` — `ir.clj:42` verified (constructor preserves `:args` order); analyzer range not checked. |
| b | IR carries only optional `:pos`; no provenance/site/resource/assumption | `jolt-core/jolt/ir.clj:100-168` | `JOLT/jolt-core/jolt/ir.clj:100-168`; annotation list at 149-163 | **VERIFIED in substance**, lines exact. Wording imprecise: 13 optional annotation keys exist (`:hint :shape :nilable :num-kind :num-read :devirt-type :num-ret :phints :nhints :ret-nhint :no-init :meta-expr :letrec`); none carries provenance/site-ID/resource-ID/assumptions. "Only optional :pos" should read "only :pos carries source metadata; no provenance-bearing fields". |
| c | host interop operand order unfixed | `backend_scheme.clj:1302-1353` | `JOLT/.../backend_scheme.clj:1302-1304` (`:host-new`), `:1346-1353` (`:host-call`) | **VERIFIED**, lines exact. Both splice operands into bare Scheme applications with no `ordered-call`; order therefore host-dependent per 429-432. P1:138,153 matches. |
| d | kernel machine + explore-states BFS/projection/replay | `kernel.clj:445-621`; `explore_states.clj:1-26` | `SIM/src/jolt/sim/kernel.clj:445-621`; `SIM/src/jolt/sim/explore_states.clj:1-26` | **VERIFIED**, lines exact. `machine` 494-511, projection `{:tasks :world :now :steps :max-steps}` 513-528, terminals `:failed/:completed/:deadlock/:step-limit` 530-543, deterministic enabled vector 545-560, fail-closed `machine-apply` 562-621. explore_states 1-26: unreduced BFS, canonical dedup, `:completed/:state-limit/:violation`, replay = `reduce machine-apply` (18-19), boundedness caveats (21-26). Supports D5/P3 usage. |

**Extra spot checks (supporting D5/P2/P3):** P3:31 fixture `SIM/test/jolt/sim/explore_states_test.clj:273-414` — VERIFIED (mailbox reply/timeout/cancel, exactly-once claims/cleanups, 273-299,366-385). P3:137 counts `4 < visited < 500`, `{:completed 3}` — VERIFIED at :370-371. P2:87 hermetic fail-closed `SIM/src/jolt/sim/runtime.clj:942-996` — VERIFIED (unhandled descriptor throws `:unhandled-native-effect` before OS access, latched, 947-954,977-990). P2:16/P3:149 `kernel.clj:667-698` replay validation and `monitor.clj:100-146` pure fold with `:pass/:violation/:inconclusive` — VERIFIED.

**Unverified:** MEMO:5 baseline hash (`.git/HEAD` unreadable — BadResource); all F1–F4 doc citations (P5 §§A–C, MEMO:85-87) — outside the read fence; all P4 Hegel citations (`src/hegel/*`) — jolt-hegel not an assigned root; P1's `host/chez/*` citations — not load-bearing for D1/D5/D6 as tasked. D2's "P1 confirmed every widening trigger" (MEMO:38-40) is second-order via P1:91-96,127 — consistent with (c) but not independently re-verified.

## Ranked findings (tasks 2 & 3)

**B1 — BLOCKER: CSIR v1 first milestone is not decision-writable.** D1 (MEMO:15-28) fixes identity policy but D1–D10 nowhere define CSIR v1's node/field set for the D6 fragment, its schema-version/remint rule, validator ownership, or A2→A3 exit criteria. P3:202-204 names exactly this as the first honest milestone. *Smallest strengthening:* add a decision enumerating the minimal CSIR v1 schema (descriptor fields per D4:60-61 + site-ID per MEMO:22-26), its version pin to `021b0b72`, and the exit test ("one fixed corpus case through CSIR evaluator and compiled path, labeled `sampled`", P3:204).

**M1 — MAJOR: D7 is an authority ruling with no in-scope object and an unevidenced provenance tag.** MEMO:100-103. (i) D6 excludes "the unresolved reader/equality corners (D7/D8)", so D7 decides nothing the v1 fragment uses — a decision whose object is excluded. (ii) "(executable-derived)" is asserted nowhere in the cited register; P1:51 cites SPEC.md/known-divergences.edn as documents only (observation: no derivation evidence in fence). (iii) `known-divergences.edn` records *divergences from JVM Clojure*; canonizing category-blind `1`=`1N` risks blessing an implementation accident, in tension with F1's no-accident-preservation non-goal (P5:22). *Strengthening:* scope D7 to "conformance-lane test authority only; the formal fragment makes no numeric-`=` claim in v1"; drop or evidence "executable-derived". Survives only as hygiene ruling.

**M2 — MAJOR: D5's F3-vs-F4 resolution mischaracterizes the objection it cites.** MEMO:85-87 says "resolved by scope", but F4's objection is priority — "not the immediate proof target" (P5:82, F4:42-45) — and the memo never quotes it. Inference: a charter reviewer reading F4 will see an unresolved contradiction, not a scoped one. Also D5's milestone proves a model of no Jolt artifact (P3:28 admits native channel semantics UNKNOWN), so under D3's own model≠implementation rule milestone 1 carries an empty abstraction/coverage relation. *Strengthening:* cite F4's sentence verbatim, state the lane-scope resolution, and declare the milestone's claim "TCB-validation-only, empty refinement relation". Survives because the design is executable on verified machinery (kernel 494-621; explore_states 1-26) with known-SAT + non-vacuity controls and scrupulous labels (P3:159-172).

**m3 — MINOR:** MEMO:77 "finish BFS with no state cap" — explorer *requires* a positive `:max-states` (explore_states.clj:54-59); intended meaning is "`:completed`, never `:state-limit`". Fix wording; this is exactly the state-cap≠bounded-complete rule the charter enforces.

**m4 — MINOR:** MEMO:19-20 "carries only optional :pos" — imprecise vs ir.clj:149-163 (13 optional annotations); substance verified. One-word fix.

**m5 — MINOR:** MEMO:35-36 "A registered callback is host-capability unless its thread/lifetime/ownership/serialization contract is declared" — no consequent (declared → narrows to what?). Same truncation in P2:87.

**m6 — MINOR:** MEMO:90 "selected `throw`/`try`/`catch`/`finally`" — the selection is never enumerated in D1–D10 or P3:200; charter needs the list or a selection rule.

**m7 — MINOR:** D5's "exact visited/terminal/edge counts" depends on an explorer edge-count that does not exist yet (P3:137: "add that count before claiming the non-vacuity metric"); the memo does not stage this dependency.

**m8 — MINOR:** P3:77 typo `:steps :steps` in the projection list vs kernel.clj:516,523-528.

**q1 — QUESTION:** `max-steps 7` is asserted, not derived; P3:93 makes `:step-limit` a *violation*, so the corrected control's `:completed` hinges on 7 ≥ longest quiescence path (≤6 task transitions with 3 ops/task — inference, not shown). One derivation line needed.

**q2 — QUESTION:** P4 Row 1 (sampled equality/hash laws) vs D6/D7 exclusion of equality corners — both can coexist, but the charter should say sampled runtime equality testing is in scope while formal equality is not.

**q3 — QUESTION (unowned boundary):** D9 routes concurrency/time obligations to jolt-sim (MEMO:111-113) while D10 disclaims cross-lane compatibility (MEMO:117-119); no owner is named for accepting jolt-sim-produced evidence into this charter's D3 records.

**Overclaim scan (task 3):** no lattice violations found. Closest approaches are M1(ii) (provenance overclaim) and m3 (state-cap wording). P2:130, P3:149,210-215, P4:15, P5 §B all model correct discipline; `failed`-blocks-promotion (MEMO:48-49) and monitor≠liveness (P3:149) are stated where needed.

## Charter blockers (task 4)

1. **B1** above — CSIR v1 schema/version/owner/exit-criteria staging absent.
2. **m6** — the pure fragment's exact form set ("selected" throw/try/catch/finally) must be enumerable for a decision-ready charter.
3. **M1** — D7 must be rescoped to test authority to remove the D6/D7 circularity.
4. **M2** — F4's priority objection must be quoted and resolved by lane, not "scope" shorthand.
5. **m7** — explorer edge-count dependency must be staged pre-milestone.
6. **q3** — cross-lane evidence-acceptance ownership (D9 G2 ↔ D10) is unassigned.

## Open questions

q1–q3 above, plus: is the F4-conditioned 0.5.13 pivot status (P5:84,91) now resolved by D10's pin, and does the jolt-sim lane's remint affect D3's "schema/IR version" metadata for any evidence produced before remint?

## Fable candidates (≤3; not performed here)

1. **D1 site-ID + declared-anchor rule** (MEMO:22-28; P2:55) — the identity spine every evidence digest depends on; macro-digest-chain stability and anchor-as-false-equivalence need heavyweight adversarial review.
2. **P3 §2 mailbox transition relation, invariant, and non-vacuity adequacy** (P3:39-157) — before minting as the charter's first proof record, verify the model's faithfulness and that the controls actually discriminate (incl. the max-steps-7 derivation).
3. **D3/C2 partial order + mandatory record metadata sufficiency** (MEMO:42-57; P2:102-132) — check lattice soundness and whether one record schema honestly spans Hegel seed-only replay (P4:17) and jolt-sim action-path replay (explore_states.clj:18-19).

— End of review. Advisory; primary orchestrator owns acceptance.
