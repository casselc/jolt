# P6 — Vendor-independent design challenge (Claude CLI)

**Provenance:** external Claude CLI (`claude -p`), Claude Code 2.1.220,
`--model sonnet` (latest-Sonnet alias), `--effort high`, plan mode,
Read/Glob/Grep only, no session persistence, budget cap $10 (user-authorized),
2026-08-01. Run from the charter worktree with read roots: v0.5.13 candidate
worktree + jolt-sim.
**Status:** ADVISORY. Acceptance/rejection per finding is recorded in
`../REVIEW-RECONCILIATION-2026-08-01.md` (when written) and the decision memo.
No files were edited by Claude.

---

## Verdict Summary

D1–D10 are directionally sound and citation discipline is unusually strong. The four spot-checked load-bearing citations (D1/D5/D6 evaluation-order + IR-schema claims, jolt-sim kernel/explorer shape) all verify against live source at the cited lines. The strongest weaknesses are: D1 commits to the costliest CSIR target (A3) on an unsupported "strictly better" assertion rather than a derived need; D5 adopts a proof target that jolt-sim's own roadmap (F4) explicitly says is *not* the immediate priority, and the memo's "scope resolves it" argument is asserted, not demonstrated. One real overclaim risk sits in P3 §4's "Evidence summary" table, which drops the "after execution" qualifier used everywhere else in the same document. No charter-blocking contradiction is fatal, but staged exit criteria and CSIR↔effect-descriptor ID unification are both undecided and both required by the handoff's nine-section charter scope.

## Citation Verification Table

| # | Claim | Path:line cited | Status |
|---|---|---|---|
| a | Ordinary `:invoke` is observably left-to-right (ordered-call/`emit-invoke`) | `jolt-core/jolt/backend_scheme.clj:429-473`, `:909-930` | **Verified** — `ordered-call`/`needs-order?` (429-473) forces `let*` temps for order-sensitive operands; `emit-invoke` (909-930) orders `[callee & args]` together via the same mechanism. |
| b | IR carries only optional `:pos`, no provenance/site/resource/assumption fields | `jolt-core/jolt/ir.clj:100-168` | **Verified** — schema comment block lists only `:pos` (source position) among annotation keys; no site-ID/resource-ID/assumption/provenance field appears through line 168. |
| c | Host interop operand order is unfixed bare Scheme application | `jolt-core/jolt/backend_scheme.clj:1302-1353` | **Verified** — `:host-new` (1302-1304) and `:host-call` (1344-1353) splice `(map emit args)` directly with no `ordered-call`/`let*` wrapping, unlike `:invoke`/collection literals. |
| d | jolt-sim kernel + `explore-states` supply BFS/projection/replay shape | `src/jolt/sim/kernel.clj:445-621`, `src/jolt/sim/explore_states.clj:1-26` | **Verified** — `machine`/`machine-projection`/`machine-actions`/`machine-apply` (445-621) give exactly the finite-transition-system API P3 assumes; `explore-states` docstring (1-26) confirms full-branching canonical-dedup BFS with `:completed`/`:state-limit`/`:violation` terminals, matching D5's "no state cap ⇒ inconclusive" language. |

## Ranked Findings

**[MAJOR] D1 commits to the costliest CSIR target on an asserted, not derived, justification.**
`P2-DECISION-ALTERNATIVES-MEMO.md:49` states "This is strictly better technically" for A3 with no comparative evidence — P2's own cost/risk rows (A3: "largest compiler artifact and tooling investment"; risk: "graph/version churn; explicit anchors can be misused as false equivalence claims") are not weighed against A2, which gets the *same* structural site-ID rule (P2:55, applies "for A1–A3"). No decision in D1–D10 names a consumer that requires A3's specific extra feature (declared anchors across refactors / expansion-parent chain) beyond A2. This reads as premature architecture lock-in ahead of the charter's own no-implementation gate.
*If the decision survives:* staging via "A2-minimal first milestone" does defer the actual cost, so the practical near-term risk is small — but the charter should not present A3 as *decided* target architecture without recording that the case for A3-over-A2 is currently an assertion, not a grounded comparison.

**[MAJOR] D5's first-proof-target choice directly conflicts with jolt-sim's own stated roadmap priority, and the memo's resolution is asserted.**
`P5-RESEARCH-DOC-CLAIM-CHECKLIST.md:82` (Internal contradiction #1) quotes F4 verbatim: "The suggested standalone capacity-one mailbox BFS is not the immediate proof target… it does not displace the higher-priority unchanged-code HTTP/TCP/DB/Maelstrom integration." D5 answers this only by declaring scope: "Execution is a separate bounded jolt-sim task (not this lane)." That resolves *whose lane* owns execution but not the substantive tension — if jolt-sim's actual next work is HTTP/Maelstrom, this design may sit unexecuted indefinitely or diverge from real constraints jolt-sim encounters first, at which point the design in P3 goes stale before ever running.
*If the decision survives:* as a design exercise for this lane's own evidence-discipline demonstration it is defensible; it should not be read as evidence jolt-sim will execute it soon.

**[MINOR] P3 §4 "Evidence summary" table drops the execution-pending qualifier used everywhere else in the same document.**
`P3-FIRST-PROOF-TARGET-DESIGN.md:210` reads "Corrected completed BFS with no state cap: **bounded-complete**" — flatly, as achieved. Every other occurrence of this same claim in the document is qualified `[bounded-complete after execution; currently assumed]`. No solver/BFS run occurred. This table is the most likely fragment to be copied verbatim into the charter, which would then overclaim.

**[MINOR] D9's "never Hegel obligations" for real concurrency/time is stated as an absolute rather than a scoped rule.**
`DECISION-MEMO-2026-08-01.md:111-113`. P4's own grounding shows the *sequential model* of the same properties (atom laws, settlement laws) remains legitimately `sampled` via Hegel — only the *concurrent/timed* variant is out of reach. The "never" wording risks being read as excluding Hegel from the sequential-model rows too, which P4 explicitly supports.

**[QUESTION] Is the CSIR site-ID (D1) the same ID space as the effect-descriptor `site-id` field (D4)?**
D1's site-ID rule is derived from `{CSIR-schema, namespace/logical definition, resolved binding path, normalized expanded semantic-role path, macro-definition digest chain, operation tag}`. D4's descriptor schema separately lists `site-id` as a descriptor field. Nothing in D1–D10 states these are the same identifier or a projection of one from the other. If they're independently derived, cross-referencing a CSIR node to an effect-record by site-id is unsound; if they must be identical, that's an unstated constraint on D4's implementation.

## Overclaim Scan

- **P2-DECISION-ALTERNATIVES-MEMO.md:49** — "This is strictly better technically" (A3 vs. A2/A1), unqualified comparative claim without cited evidence. Flag for charter drafting: rephrase as an architect judgment, not a proven fact.
- **P3-FIRST-PROOF-TARGET-DESIGN.md:210** — see MINOR finding above; drops the execution-pending hedge present elsewhere in the same doc.
- Everywhere else scanned correctly distinguishes `sampled`/`monitored`/`bounded-complete`/`assumed`/`opaque`/`failed` and explicitly names the never-promote list. No violations found there.

## Charter Blockers

1. **No staged exit criteria exist.** Handoff §9 requires "exact staged exit criteria (charter, reference evaluator, schema prototype, first verified kernel)" — none of D1–D10 states a criterion for any stage transition.
2. **CSIR↔effect-descriptor ID unification undecided** (see QUESTION finding above).
3. **Circular dependency between D9 (Hegel API additions deferred "until the differential loop exists") and the differential loop's own dependency on CSIR+evaluator (not yet built).** No decision breaks this cycle or orders the two build-outs.
4. **D5's proof target is unresolved against jolt-sim's actual roadmap priority** (MAJOR finding above).
5. **No owner is named for CSIR schema/versioning work.** "Every option is new compiler work" but D1 doesn't assign a lane/owner.
6. **Cross-lane baseline mismatch is deferred, not resolved.** D10 pins 0.5.13 for this lane while noting jolt-sim "owns its own pivot" — meaning D5's proof target (built on jolt-sim kernel source) currently has no confirmed 0.5.13-compatible execution substrate.

## Fable Triage (bounded, ≤3)

1. **D1 + P2:45-57** — deep architecture review of whether A3's specific extra mechanism (provenance graph + declared anchors) is justified over A2 by any concrete near-term consumer, given the "strictly better" claim is currently unsupported.
2. **D5 vs. F4 reconciliation** — fresh read of F4's full reconciliation section to judge whether "execution is a separate jolt-sim task" genuinely neutralizes the roadmap-priority conflict or just relabels it.
3. **CSIR site-ID (D1) vs. effect-descriptor site-id (D4) identity question** — cross-section consistency check to determine whether these must be unified before charter §4/§6 can be written without ambiguity.
