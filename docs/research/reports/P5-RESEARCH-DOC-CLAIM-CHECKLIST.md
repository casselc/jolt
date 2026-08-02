# P5 — Research-doc claim-discipline checklist (Deepseek V4 Flash trial)

**Provenance:** `jolt-research-auditor` via `opencode-dispatch`, session
`ses_03ffb0eb6ffe7VL4SDqvMkyErG`, model
`fireworks-ai/accounts/fireworks/models/deepseek-v4-flash-0731` (profile default),
600s budget, 2026-08-01 (post-restart; first run at 300s timed out pre-restart).
**Status:** UNREVIEWED working report; citations not yet independently
spot-verified by the primary orchestrator.
**Trial verdict:** model followed the bounded prompt, citation discipline, and
output cap; suitable for this audit class. (Dispatcher emitted a cosmetic
server-shutdown traceback AFTER delivering the result; deliverable unaffected —
dispatcher `stop_server` robustness noted as a separate chore.)

---

# Audit checklist — four Jolt documents (2026-08-01)

File keys: **F1** = `JOLT-FORMALIZABLE-APPLICATION-CORE-RESEARCH-PLAN-2026-08-01.md`; **F2** = `jolt-gradual-formalism-vision-2026-08-01.md`; **F3** = `jolt-sim-architecture-review-2026-08-01.md`; **F4** = `JOLT-SIM-MAELSTROM-FLOW-IMPLEMENTATION-PLAN.md` (lines 1–300 only).

## A. Explicit non-goals

1. F1 §Executive decision (l.23): not an attempt to preserve every historical JVM Clojure behavior or implementation accident.
2. F1 §Baseline policy (l.31): no prerelease controller or trace ABI retained merely for compatibility.
3. F1 §Application-profile surface (l.83): non-goals include arbitrary JVM class interop, unrestricted reflection, implicit host mutation, and pretending all platform-specific behavior has one portable semantics.
4. F1 §Data and coordination kernels (l.113): Refs/STM, if supported, are a separate transaction subsystem — "not atoms with new syntax."
5. F1 §Effects, capabilities, and FFI (l.174): do not begin with unrestricted algebraic effects, multi-shot continuations, or a universal untyped `perform` map.
6. F2 §Status (l.3–4): not an effects-system proposal and not a claim about current implementation support.
7. F2 §Goal (l.17–19): developer should not need to learn temporal logic, rewrite production code, or adopt an effect system.
8. F2 §Effects (l.144–148): effects are not needed for L0–L3; making effects a prerequisite would be counterproductive.
9. F2 §Minimal credible MVP (l.272): defer bespoke LSP work.
10. F3 §Executive assessment / Finding 6 (l.32–36, 177–207): Maelstrom node is "premature scope expansion" unless extracted to an extension or made example-only; do not add workloads before a concrete transport contract and real/sim parity seam exist.
11. F3 §Finding 1 (l.96–97): do not try to turn Hegel sampling into a model checker.
12. F3 §Guardrails (l.264–265): no compatibility branches for prerelease controller/trace contracts; remint the one current pin.
13. F3 §Guardrails (l.269): keep external OS process containment outside the simulated transition system.
14. F3 §Guardrails (l.270–271): do not claim Windows process-explorer support (CI lane excludes that gate).
15. F3 §Addendum (l.296): the FFI controller is not a general effect system and "should not be relabeled as one."
16. F3 §Addendum non-goals (l.362–363): do not begin with multi-shot continuations, handler-driven scheduler search, implicit global handler composition, or a universal untyped `perform` map.
17. F4 §Architecture-review reconciliation (l.42–45): the standalone capacity-one mailbox BFS is not the immediate proof target.
18. F4 §Reconciliation (l.141–145): no compatibility code or CI lanes for 0.5.12 or earlier will be retained; "historical fork parity is not a goal."
19. F4 §Reconciliation (l.210): do not land a Maelstrom-only partial JSON parser.
20. F4 §Objective (l.227–228): Flow must not become a prerequisite for simulation or require application code rewritten for the simulator.
21. F4 §Planning baseline (l.264–277): current nonclaims — no high-utility scheduler search or partial-order reduction; no fine-grained control of nested futures/promises/atoms/timers/`core.async`; runtime time/entropy not controlled end to end; no virtual network fault world; no real-socket/hermetic parity lane for the current HTTP example; no Maelstrom-compatible Jolt node library; no Jepsen/Elle history bridge; no production OpenTelemetry bridge.

## B. Evidence-level rules

1. F1 §Semantic formalisms (l.75): a passed finite monitor, sampled Hegel property, bounded explorer run, native probe, and external theorem are distinct evidence classes and must be displayed as such.
2. F1 §Semantic formalisms (l.71): infinite temporal claims require LTL plus explicit fairness and lasso/independent-model controls.
3. F1 §Gradual schemas (l.149): `Dynamic` is not proof of membership; a Dynamic-to-precise boundary receives a contract unless a compiler-recognized guard or checked proof discharges it.
4. F1 §Guardrails ergonomics (l.157): throttled validation is sampled evidence, never a type or proof claim.
5. F1 §Effects/FFI (l.178): native probes establish layout facts, real calls establish named runtime postconditions, deterministic worlds establish simulated behavior; "None proves arbitrary C library correctness."
6. F1 §Proof, search, and evidence routing (l.195–199): every output carries an evidence level (`proved | bounded-complete | sampled | monitored | assumed | opaque | failed`) plus bounds, fairness, host assumptions, replay coordinates.
7. F1 §Proof, search, and evidence routing (l.201): no finite monitor proves unbounded liveness; no Hegel pass proves completeness; no state-cap result is success; unknown/malformed/lost required observations are never silently ignored.
8. F1 §Current evidence (l.269): no new full simulation-image suite pass is claimed.
9. F2 §Gradual levels (l.80): L2 is "sampled testing, never completeness."
10. F2 §Gradual levels (l.81): L3 bounded reachability claim only if exploration finishes without a state cap.
11. F2 §Gradual levels (l.83): L5 allows "only the exact independently verified bounded claim."
12. F2 §Gradual levels (l.86–87): a green Hegel run must never be displayed as a proof; a finite monitor pass must never be displayed as unbounded liveness.
13. F2 §What cannot be automatic (l.107–116): no tool can soundly infer the abstraction function, linearization points, permitted host effects, ownership/cleanup/cancellation, fairness/symmetry assumptions, or model omission from arbitrary code.
14. F2 §Refinement (l.132–134): only explicit `:hide` classifications accepted; a hidden event must leave abstract state unchanged; unknown/malformed/lost/ambiguous events are failure/inconclusive, never silently ignored.
15. F2 §PObserve (l.192–193): do not globally sort application logs by timestamp — that can invent a causal order the implementation never established.
16. F2 §PObserve (l.195–202): mapper must report unmapped events; `:required` absence/ambiguity/loss/escape makes refinement inconclusive/failed; `:best-effort` is "never a proof premise."
17. F2 §PObserve (l.207–208): a passed finite monitor is a statement about the mapped trace, not proof that all production behavior conformed.
18. F2 §Telemetry (l.231–234): lossy export must emit drop/loss metrics; a `:required` monitor returns `:inconclusive`, not `:pass`, when telemetry was sampled away.
19. F2 §Telemetry (l.239–241): telemetry is never promoted to a replay or full-conformance claim without its stated completeness assumptions.
20. F2 §Tooling (l.257–259): code actions scaffold declarations but must not assert correctness.
21. F2 §Guardrails (l.286–289): generated tests are derived evidence; require a known-SAT buggy control, a corrected control, and a reachable valid path before reporting bounded proof evidence.
22. F2 §Guardrails (l.290–292): distinguish deadlock, timeout, quiescence, failure, bounded-step cutoff; no temporal/liveness claims until fairness and infinite-trace interpretation are explicit.
23. F3 §Finding 1 (l.82–94): exact replay of a selected admission order does not establish coverage/completeness; only the cooperative-model track may make bounded reachability/completeness claims; the runtime track claims only controlledness/replay within declared hook and escape bounds.
24. F3 §Finding 5 (l.167–169): supervisor wall time is valid but "must not become evidence of virtual-time determinism."
25. F3 §Finding 6 (l.206–207): Echo unit tests are neither distributed-safety nor liveness evidence.
26. F3 §Roadmap 8 (l.253–255): neither a timeout nor a finite monitor proves unbounded liveness.
27. F3 §Evidence limits (l.275–281): report establishes source/CI facts only; does not claim HEAD passes its suite, ABI matches either pin, SQLite parity in CI, Maelstrom interop, or exhaustive exploration.
28. F4 §Reconciliation (l.14–18): the pure kernel may make only bounded claims about its declared transition system; the runtime controller "is not model checking of arbitrary Jolt code."
29. F4 §Reconciliation (l.30–32): supervisor wall time stays outside virtual-time evidence; finite capacities, short writes/`EAGAIN`, deterministic timer ties, cancellation, cleanup, and fault plans must land before deterministic network/time claims broaden.
30. F4 §Reconciliation (l.36–37): Echo alone is not distributed-safety, liveness, or Maelstrom interoperability evidence.
31. F4 §Reconciliation (l.65–66): the integrity checker "explicitly makes no canonicality claim for mutable payload leaves."
32. F4 §Reconciliation (l.120–122): no additional Maelstrom workload lands before real and in-process Echo share replayable message/causal evidence and offline checks.
33. F4 §Reconciliation (l.151–155): the HTTP gate's claim is deliberately narrow — one request at one-byte capacity, no generated schedules, no DB locking/durability, no virtual faults beyond one captured poll EINTR, no Maelstrom integration.

## C. Internal contradictions / tensions

1. **Capacity-one mailbox BFS as immediate proof target** (the known candidate). For: F3 §Roadmap 3 (l.233–238) — "Choose the next proof target: implement a small cooperative explicit-state explorer… A two-task, capacity-one mailbox with send/receive/timeout/cancel… unreduced BFS… is sufficient"; F2 §MVP (l.268–271, 276–280) — the first demo "should be a capacity-one mailbox with send, receive, timeout, close, and cancellation." Against: F4 §Reconciliation (l.42–45) — "The suggested standalone capacity-one mailbox BFS is not the immediate proof target… it does not displace the higher-priority unchanged-code HTTP/TCP/DB/Maelstrom integration."
2. **Maelstrom status/priority.** F3 (l.32–36, 177–207) calls the Maelstrom node "premature scope expansion" needing extraction or example-only status; F4 (l.33–37) keeps `jolt.maelstrom` co-located as an extractable example/extension, and F4 §Objective (l.212–217) makes the Gossip Glomers suite "a primary executable acceptance ladder for Jolt-sim."
3. **Baseline version.** F1 §Baseline policy (l.27) — "The intended baseline is the current upstream Jolt 0.5.13 rebase candidate"; F4 §Live WIP (l.130–131, 139–141) — current candidate is `56d0694…` "based on 0.5.12," with 0.5.13 adoption conditional ("If adopted… remint… against 0.5.13"). Related: F3 §Finding 7 (l.211–217) documents README pin `757389df…` vs CI `56d0694…` mismatch, while F4 (l.49) reports `aa7ff64` made the pin atomic at `56d0694`.
4. **Suite-pass claims.** F1 §Current evidence (l.269) — "no new full simulation-image suite pass is claimed here"; F3 §Method (l.10–12) — "No test was run: the local Jolt checkout has no `target/sim/jolt` image"; versus F4 (l.59–60, 66–67, 80–81, 89–91, 100, 112–113) reporting integrated and "special-image suite" passes (e.g., "the special-image suite passes 400 / 2,505").
5. **Evidence-spine sequencing.** F3 §Finding 2 (l.113–124) recommends extracting a trace-schema/document layer owned by `trace` before adding hooks/search breadth; F4 §Reconciliation (l.20–24) adopts a kernel-independent trace owner but states "further event categorization and causal identity work must be driven by executable consumers rather than a schema-only detour," and F4 (l.47–118) continues landing new slices (fault director, POSIX fault frontend, Echo transport, HTTP/SQLite) that F3 (l.34–36) cautioned against adding before convergence.

## Unknowns

- F4 was read only to line 300 per assignment; its later phases (Jepsen/Elle, OTel, Unique IDs/Broadcast gates) were not audited.
- Whether the 0.5.13 pivot audit (F4 l.139–145) has since resolved — the four docs do not record a decision.
- Whether the README/CI pin mismatch (F3 l.211–217) predates or postdates the `aa7ff64` fix claimed in F4 (l.49); the docs give no commit dates.
