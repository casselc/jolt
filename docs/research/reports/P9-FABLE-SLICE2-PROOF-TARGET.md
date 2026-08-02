# P9 — Fable slice 2: D5/C2/P3 first proof target review

**Provenance:** external Claude CLI (`claude -p`), Claude Code 2.1.220,
`--model fable` (user-directed), `--effort high`, plan mode, Read/Glob/Grep
only, no session persistence, budget cap $10, 2026-08-01. Bounded to slice 2
(D5/F4 reconciliation + P3 mailbox faithfulness, controls, TCB).
**Cost:** $3.47 actual (cap $10), 17 turns, ~30k output tokens, `end_turn`,
no error (JSON output captured; slice 1's text mode had no cost data).
**Status:** ADVISORY. Dispositions recorded in
`../REVIEW-RECONCILIATION-2026-08-01.md` and applied as G-amendments to
`../DECISION-MEMO-2026-08-01.md` (user approval requested in chat).

---

All material verified against live source. Findings below; the review is complete.

# Fable Slice 2 — D5/C2/P3 First Proof Target Review

**Verdict summary (10 lines)**
1. Q1 (F4 reconciliation): **sound-with-amendment** — C2's lane split holds; F4's fuller context endorses, not contradicts, a bounded pure-model target; residual gap is unscheduled execution.
2. Q2 (model faithfulness): **unsound-as-written** — P3's guard-style "enabled iff" relation does not exist in the kernel; blocking is a budget-consuming transition and unconditional wakes throw.
3. Q3a (buggy witness): **sound** — hand-simulated step-by-step under machine-apply semantics; 5 actions is the shortest witness and fires only at its final state (inference; not executed).
4. Q3b (non-vacuity): **sound-with-amendment** — classes are right but the explorer cannot report them; mechanism (scripted-path fixtures / probe invariants) is unnamed.
5. Q3c (max-steps 7): **unsound-as-written** — BLOCKER: the ≤6 derivation counts only productive ops; block transitions consume steps; worst quiescence path is ~9–10, so the corrected control violates via its own `:step-limit` clause.
6. Q3d (edge count): **sound** — explorer verifiably lacks an edge count; P3 stages it correctly.
7. Q4 (TCB): **sound-with-amendment** — missing rows: the invariant itself (per-clause SAT probes) and the persisted-trace EDN reader.
8. `:step-limit`-as-violation is good design once the bound is fixed — it turns the derivation into a checked claim; keep it.
9. `:failed` is a real kernel terminal (kernel.clj:530-535) absent from the invariant disjunction — a step-fn bug would pass silently.
10. Nothing here overturns D5/C2; the mailbox remains the right first target after the encoding and bound amendments.

## 1. F4 reconciliation (sound-with-amendment)
- **Observation:** F4's full paragraph (JOLT-SIM-…-PLAN.md:42-45) calls the mailbox "a useful later control for state identity and reduction soundness" — it assigns it a role, it does not reject it; the objection is strictly about jolt-sim's landing order. Lines 14-15 explicitly permit the pure cooperative-model track "bounded claims about its declared transition system," which is exactly P3's claim shape. P5 §C item 1 (P5:82) shows F3:233-238 and F2 both *recommend* this shape; F4 is the lone dissent and only on scheduling. C2's resolution is genuine.
- **Major:** F4's immediate landing order (plan:189-205) never schedules mailbox execution, and D5 assigns execution to "a separate bounded jolt-sim task (not this lane)". C2 neutralizes the priority conflict but leaves the proof target with no scheduled executor — all D5 evidence stays `[assumed/expected]` indefinitely. F4 is silent on `explore-states` itself in lines 1-210.
- **Minor:** C2 pins "kernel semantics verified at `eb7bce4`", but the plan's named checkpoints are `56d0694`/`588677b` with the 0.5.13 pivot unconfirmed. Which is newer is **unverifiable** from the read fence (no git access).
- **Minor:** name collision — "F4" is both P5's file key (the plan) and a memo F-amendment; C2 means the file. Confusing in one document.

## 2. Model faithfulness (unsound-as-written)
- **Blocker (encoding):** P3's "send m: enabled iff open? and slot=nil" (P3:70) has no kernel counterpart. `machine-actions` enumerates *runnable tasks only* (kernel.clj:545-560); the kernel has no world-state guards. A task refuses an operation only by executing `step-block` (kernel.clj:34-35, fixture explore_states_test.clj:281,299) — a full transition that increments `:steps` (kernel.clj:364). The model-level relation is therefore an abstraction of a larger kernel graph containing block transitions; P3 nowhere states this.
- **Blocker (wakes):** "send/take/close explicitly wake the counterpart where applicable" (P3:66) — but waking a non-blocked task is a transition error (kernel.clj:187-190), and that throw is raised in `apply-transition`, *outside* the step-fn catch (kernel.clj:357-363), so it escapes `machine-apply` and crashes BFS. The step context is only `{:task :now :world}`, so "where applicable" requires waiting/blocked flags **in the world** — absent from P3's state variables (P3:53-62). The world schema and projection must grow.
- **Major:** invariant omits `status = :failed` (P3:85-95). `classify` puts `:failed` first (kernel.clj:322-327); a step-fn defect becomes a silently-counted terminal and the corrected control still returns `:completed`. Add `:failed` to the disjunction.
- **Major (vacuity):** clause 3, "closed and a send transition is enabled," can never fire: the producer's program closes only after both sends, so no reachable state has a pending send after close. The clause is untestable as configured, and "send enabled" additionally needs a model-level definition over the projection (kernel enabledness ≠ model enabledness).
- **Minor:** spurious wakeups cannot occur (wakes are exact and explicit; `wake-due` touches only sleeping tasks, kernel.clj:142-146) — P3 correctly needn't handle them, but should say so. Close-while-sender-blocked is unreachable in this configuration and should be named in the omissions list (P3:156) alongside timeout/cancel.

## 3. Controls adequacy
- **(a) Buggy witness — sound.** Hand-simulation (inference, not executed): forced prefix send-a → receive-a → send-b (each earlier interleaving leaves exactly one enabled productive action besides block-attempts); at the branch, buggy close drops `:b`, then receive-on-closed-empty completes the consumer with `delivered=[:a]`, `status=:completed` → clause 4 fires. The 4-action prefix does not violate (`[:a]` is still a prefix of `[:a :b]`; status non-terminal). No ≤4-action state violates; block-attempt detours only lengthen paths; deadlock is unreachable; `:step-limit` states sit at depth ≥7, and BFS depth order reports the depth-5 witness first. Wakes on this path are all no-ops if conditional (counterpart never blocked), so it is enabled step-by-step under `machine-apply`.
- **(c) max-steps 7 — BLOCKER.** The derivation "2 tasks × 3 operations ⇒ ≤6" counts only productive transitions. With blocking-as-step, worst case is producer ≤4 runs (1 block at send-b) + consumer ≤6 runs (blocks before receive-a, receive-b, and the close-observation) = **10** task transitions (9 if the consumer starts `blocked`); a concrete valid 10-path exists. At steps=7 that path is mid-run with runnable tasks → `classify` returns `:step-limit` (kernel.clj:332-335) → P3's own invariant clause fires → the **corrected control returns `:violation`, not the required `:completed`** (P3:117-123). Making `:step-limit` a violation is coherent with the explorer's classifications and worth keeping — it checks the bound — but the bound is wrong. Note `apply-time-advance` never increments steps (kernel.clj:378-390), irrelevant here (no timers). The max-steps/max-states distinction is otherwise not conflated: `:max-steps` lives in the sim config, and the explorer separately requires a positive `:max-states` (explore_states.clj:54-59), as the memo correction already records — though P3's body never names `:max-states` (minor).
- **(b) Non-vacuity — sound-with-amendment.** The five classes plus the separate deadlock fixture are the right set (blocked-producer + blocked-consumer simultaneously is impossible, so no class is missing), but `explore-states` returns only `:status/:visited/:terminals` — it cannot certify class reachability. Name the mechanism: literal scripted-path fixtures with `restore-projection` asserts (the existing idiom at explore_states_test.clj:379-385) or per-class probe invariants expecting `:violation`.
- **(d) Edge count — sound.** Verified: no edge/action counter anywhere in the explorer (explore_states.clj:100-102,141-151). P3:137 correctly stages "add that count before claiming the non-vacuity metric."

## 4. TCB completeness (sound-with-amendment)
- **Major:** the **invariant function is a trusted component with no row** (P3:161-170). The buggy control exercises only clause 4 (completed-run equality); clauses 1 (slot arity), 2 (prefix — note the buggy drop *preserves* prefix-ness, so it never tests clause 2), 3 (no-send-after-close), and the `:deadlock` clause never fire in any named control. An inverted or dead clause passes silently. Add per-clause known-SAT probe fixtures.
- **Major:** the **persisted-trace EDN reader** is trusted and uncontrolled. P3 steps 2-3 persist and re-read canonical traces (P3:139-149); the versioned trace document reader has a documented forgeable end-of-input-sentinel defect history (plan:56-59). Add a row: malformed/truncated/forged-document rejection fixtures.
- **Minor:** `trace/canonical-value`/`restore-value` round-trip underpins both state identity (`visited` keying, explore_states.clj:96-97) and evidence canonicalization (explore_states.clj:69) — arguably covered by the "Canonical projection" row, but the evidence path should be named. Fixture-to-test wiring (expected-value assertions) remains trusted with no control; acceptable if acknowledged.

## Proposed amendments
1. **(Blocker, amends D5 + memo line 213-214)** Re-derive the step bound counting block transitions: state the encoding (guard failure ⇒ `step-block`, one step; conditional wakes via world-tracked waiting flags), longest quiescence path = 10 (consumer initially runnable; 9 if initially blocked), set `max-steps` 11 (one slack). Keep `:step-limit` in the violation disjunction as the bound's checked control.
2. **(Blocker, amends P3 §2)** Extend the world schema with producer/consumer waiting flags (or equivalent) and make every wake conditional on them, since waking a non-blocked task throws out of `machine-apply` (kernel.clj:187-190, 357-363); restate the transition relation as model-level abstraction over kernel block transitions, and define "send enabled" over the projection.
3. **(Major)** Add `status = :failed` to the invariant disjunction.
4. **(Major)** Make clause 3 non-vacuous: add a second fault-injected control (producer program `send-a, close, send-b`, expecting the send-after-close probe to fire) or explicitly downgrade clause 3 to a documented vacuous guard in this configuration.
5. **(Major)** Add two TCB rows: invariant function (per-clause known-SAT probes) and persisted-trace reader (malformed/forged-document rejection, incl. the sentinel regression).
6. **(Minor)** Name the non-vacuity verification mechanism (scripted-path fixtures / probe invariants); name `:max-states` in P3's body; record in C2 that execution needs a jolt-sim landing-order amendment or stays `[assumed]`; reconcile `eb7bce4` vs `588677b`/0.5.13; note the F4 file-key/amendment-ID collision.

*Caveat: all path/bound analysis is hand-simulation against read source; nothing was executed (execution is outside this slice's read-only fence).*
