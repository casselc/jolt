# Jolt Application Core Semantic Charter

**Status:** DRAFT — section-by-section review in progress. Sections marked
"DRAFT PENDING" are not yet accepted.
**Target baseline:** upstream Jolt **v0.5.17**, tag commit
`da59e49dbe8c810e05aa2ce900a95c5a1ef0c9fe` (coordination pivot 2026-08-01;
read-only reference worktree `jolt-v0517-reference`). This lane's git base and
branch/worktree names containing "v0513" are **historical** — no rebase, no
rename, no compatibility obligation for v0.5.12/v0.5.13 or earlier fork
behavior. The charter targets stable, source-level semantic contracts, not any
temporary ABI or compiler-hook revision.
**Citation authority:** `reports/P10-V0517-REFRESH-REGISTER.md` (v0.5.17)
supersedes `reports/P1-SEMANTIC-FACTS-REGISTER.md` (v0.5.13) wherever they
differ; P1 remains the historical v0.5.13 record. Citations prefixed `V17/`
point into the v0.5.17 reference tree.
**Authority:** decision memo `DECISION-MEMO-2026-08-01.md` — decisions D1–D10
with amendments C1–C5, F1–F7, G1–G6, all user-approved 2026-08-01, plus the
v0.5.17 coordination pivot. Where this charter and the memo differ, the
amendments govern.
**Grounding:** reports `reports/P1`–`P10` (same directory). Every semantic fact
about live Jolt carries a source citation or is explicitly labeled
`UNSPECIFIED`.
**Evidence-label key:** `proved | bounded-complete | sampled | monitored |
assumed | opaque | failed` — used per §5's lattice; nothing in this charter is
`proved`.

## Nonclaims (apply to the whole document)

- No claim that arbitrary Jolt code is proved, at any stage.
- No claim that v0.5.17 (or any Jolt build) passes any suite, from this lane.
  Codex-reported v0.5.17 suite state (1195/1195) is recorded as reported, not
  independently re-run here.
- Nothing here is an implementation commitment beyond the staged exit criteria
  in §9; compiler/runtime work begins only after this charter and the first
  proof target are accepted.
- Finite monitoring, bounded search, sampled Hegel evidence, native probes,
  and theorem/certificate evidence are distinct classes and are never merged
  (§5).
- No compatibility obligation is invented for prerelease ABIs or earlier fork
  behavior; one current baseline, remint policy (D10/H2, F4).

---

## 1. Application Core profile and explicit non-goals

### 1.1 Purpose and product boundary

The Jolt Application Core is the **smallest useful formalizable profile** of
Jolt. It is not a separate user language and not a rewrite target: developers
write ordinary Jolt, and this charter defines which subset carries which
semantic and evidence guarantees. The compatibility target is functional,
SCI/Babashka-like utility — the surface expected by code that could run in a
sandboxed interpreter — plus Jolt-native capabilities introduced in later
stages. It is **not** an attempt to preserve every historical JVM Clojure
behavior or implementation accident.

Every language and core-library feature carries exactly one classification,
recorded in the versioned profile matrix (§1.4):

| Classification | Meaning |
| --- | --- |
| `formal-core` | Observable semantics specified in §2; differential validation per §6 applies |
| `specified-profile` | Documented semantics (this charter or a referenced record); not yet in the formal fragment |
| `library-contract` | Contract documented by the owning library; validated at boundaries, not formalized here |
| `target-dependent` | Behavior legitimately differs by target; each target's semantics is named separately |
| `opaque` | No portable semantics; claims may not cross this boundary (§3) |

### 1.2 The v1 formal-core profile

Values (representations per P1 register; semantics in §2):

- `nil`, booleans; exact integers (61-bit fixnum path with bignum promotion on
  the generic path; checked casts truncate toward zero with JVM-sized ranges,
  per the conformance register); exact ratios; doubles (flonum, no
  single-float representation); strings (Chez strings, Unicode codepoint
  indexing — an astral character counts one and cannot be split by `subs`);
  symbols (not interned, may carry metadata); keywords (interned).
- Persistent lists, vectors (32-way trie with tail), maps (array-map insertion
  order promoting to HAMT order past thresholds), sets (hash-ordered).
  Equality and hashing are order-independent for maps/sets.
- Equality, hashing, and comparison: as **test authority**, the conformance
  register (`test/conformance/SPEC.md` + `known-divergences.edn`) governs test
  expectations where it conflicts with README prose (C3). The formal v1
  fragment makes **no numeric-`=` claim** (D6/C3); hash-consistency and
  compare laws are §6/§8 `sampled` obligations, not formal claims.
- Metadata: supported on symbols and collection values and Vars (P1); the
  exhaustive eligibility matrix is `specified-profile`, not formal-core v1.

Forms (evaluation order and observable semantics in §2):

- Literals per §2.1 (no `#=` — D8); `quote`; `if`; `do`; `let*`; `loop*` /
  `recur`; `fn*` (named/anonymous, fixed/variadic, multi-arity); `def` and Var
  reference (root + dynamic binding read order); `set!` (innermost thread
  binding only, never establishes a root); `throw` / `try` / `catch` /
  `finally` (the exact selected subset is enumerated in §2.4); ordinary
  ordered function invocation; lexical closures.

Excluded from v1 formal-core (each with its lane; details in §3):

- Concurrency primitives (atoms, futures, promises, delays, agents, locks,
  `core.async`): `host-capability` / simulation lanes; the P10 register
  (V17) stands as their v0.5.17 documentation until their own stages.
- Clocks: `jolt.host/mono-nanos` (monotonic, never steps, arbitrary origin,
  ns representation; durations only via differences) and
  `jolt.host/wall-nanos` (UTC, may step under NTP) are `host-capability`
  primitives (`V17/host/chez/rt.ss:441-458`). The §3/§4 clock **effect**
  abstracts over them with distinct monotonic vs wall-clock semantics; which
  primitive supplied each value is recorded in the operation descriptor.
- FFI and host interop: `host-capability`; **operand evaluation order for
  host-new/host-call is unspecified and classified `opaque`** (V17: bare
  Scheme application, Chez order unspecified). Qualified static-method
  invocation is different — an ordinary `:invoke` specialization with ordered
  arguments (`V17/jolt-core/jolt/backend_scheme.clj:1064-1068`) — and may be
  classified by its target.
- `eval`, `load-string`, dynamic resolution, unknown macros:
  `Dynamic-opaque`.
- Raw host objects, unregistered callbacks: `opaque` / `host-capability` per
  §3's rules.
- Transients, refs/STM: `specified-profile` candidates for later stages;
  refs/STM, if ever supported, is a separate transaction subsystem — not
  atoms with new syntax.
- Queues: representation unspecified in P1's fence → `specified-profile`
  deferred, not formal-core v1.
- Reader customization beyond §2.1's fixed literal set: `opaque` in v1.
- Telemetry primitives (`V17/host/chez/rt.ss:434-488`: clocks, CPU/GC/memory
  counters, host thread-id, machine type) are `host-capability` observation
  inputs — **never evidence identities** (§4/§5).

### 1.3 Explicit non-goals

1. **No JVM accident preservation.** Category-blind `1`=`1N` is conformance
   test authority only (C3); it is not canonized as formal semantics.
2. **No arbitrary JVM class interop, unrestricted reflection, or implicit
   host mutation** in any classified lane.
3. **No single portable semantics pretense.** Platform-specific behavior is
   `target-dependent` with per-target records; unexecuted platform lanes are
   named, not claimed.
4. **No arbitrary-proof claims.** Evidence is per-claim, per-scope, per
   §5's lattice. Nothing is proved without a checked certificate and stated
   TCB — and no such certificate exists at charter time.
5. **No unrestricted effects.** No multi-shot continuations, no universal
   untyped `perform` map, no handler-driven scheduler search, no implicit
   global handler composition (D4).
6. **No effect-system prerequisite.** Schemas, contracts, Hegel tests, models,
   and monitors work without effect handlers (effects improve L4+ refinement;
   they are not a gate).
7. **No prerelease-ABI compatibility retention.** One current baseline; a
   prerelease CSIR/schema remint orphans all prior evidence records (F4,
   declared — detectable via §5 record metadata, never silently
   reinterpreted). Post-v1 remints must emit old→new ID migration records.
8. **No compatibility obligations for v0.5.12/v0.5.13 or earlier fork
   behavior** (coordination pivot 2026-08-01). This charter targets v0.5.17
   semantic contracts; branch/worktree names containing "v0513" are
   historical. The jolt-sim lane owns its own pivot and remint.
9. **No `#=` semantics** (D8: outside formal-core, classified opaque); no
   reader-eval in any formal lane.
10. **No unexecuted-lane support claims.** Every evidence record names its
    target tuple; Windows process-explorer support is not claimed (jolt-sim
    CI explicitly excludes that gate).
11. **No OS-process containment inside the simulated transition system.**
12. **No separate user-facing specification languages.** Schemas, models,
    monitors, and solver inputs are Jolt-shaped declarations over one
    semantic/evidence model (§8).
13. **No reliance on a runtime lifecycle/controller seam.** None exists at
    the v0.5.17 baseline (P10: `sim/` overlay REMOVED upstream; the
    v0.5.13-era private future-lifecycle overlay cannot be cited). Runtime
    seams are *requested* from the v0.5.17 runtime lane (companion artifact,
    §8/§9) — never assumed.
14. **Host telemetry is not evidence identity.** Telemetry primitives supply
    observation inputs only; host thread IDs, counters, and timestamps are
    never canonical event/operation/site identities (P10 #10).

### 1.4 Profile matrix requirement

The profile matrix is a versioned companion artifact to this charter. Each
row: feature → classification (§1.1) → semantics location (§2 subsection or
referenced proof/conformance record) → evidence obligations (§5/§8). A feature
may not be referenced as `formal-core` unless its matrix row cites a §2
semantics subsection and its §6 differential coverage state. The matrix is
reminted with the charter, not patched for prerelease compatibility.

---

## 2. Deterministic evaluation order and observable semantics (first pure fragment)

DRAFT PENDING — contents: literal lowering (abstract constructors, no
representation profile selector exists today); ordinary `:invoke` observably
left-to-right (`backend_scheme.clj:429-473,909-930`) with the `needs-order?`
let* rule; `if`/`do`/`let*`/`loop*`/`recur`/`fn*` semantics; `def`/Var read
order (innermost dynamic binding → `*ns*` handling → root); `quote`;
`set!` thread-binding rule; the enumerated throw/try/catch/finally subset
(incl. `finally` as `dynamic-wind` after-thunk, ordered catch-by-`instance?`,
unconditional catch selectors); error values (`ex-info`, `ex-data`, cause);
observable terminal states for the §6 comparison relation.

## 3. Boundary taxonomy

DRAFT PENDING — B2 lanes with mechanical widening rules; registered-callback
narrowing; fail-closed hermetic simulation; controller composition note;
widening-site ID rule (C4/F6/F7).

## 4. Provenance, site IDs, schemas/effects, assumptions

DRAFT PENDING — A3-target/A2-minimal staging with closed v1 schema (F1);
site-ID from normalized-expanded-form digest (F2) + normative normalization
appendix (F3, Appendix A); remint orphaning + migration records (F4); anchors
A3-conditional with no evidence transfer (F5); effect descriptors D2 with one
ID space + host-origin class + per-instance `operation-id` (C4/F6/F7);
declared assumptions representation.

## 5. Evidence taxonomy

DRAFT PENDING — the 7 levels; C2 claim-relative partial order; never-promote
list; mandatory record metadata; pre-remint record rule (records remain valid
under their recorded versions, never silently promoted); Fable slice-4
(lattice soundness + record-schema sufficiency) fires before this section is
finalized.

## 6. First executable differential-validation loop

DRAFT PENDING — source → CSIR → reference evaluator → compiled Jolt; corpus
(conformance selection + generated programs); comparison relation (terminal
observable: canonical value or exception class); known-divergence register;
minimized-case persistence (concrete source + Hegel seed + versions);
first honest milestone (one fixed corpus case, labeled `sampled`); Hegel API
additions remain deferred (D9); ordering: CSIR v1 + reference evaluator first,
generated cases second.

## 7. First proof target

DRAFT PENDING — capacity-one mailbox per D5 with G1–G6 corrections: world
with waiting flags; conditional wakes; model-level relation over kernel block
transitions; `max-steps 11` (longest quiescence path 10 + slack) with
`:max-states` named; invariant disjunction incl. `:failed`; second
fault-injected control (send-a, close, send-b) for clause 3; per-clause
known-SAT probes; persisted-trace reader fixtures; TCB table; claim scope
"TCB-validation-only, empty refinement relation"; execution dependency
(jolt-sim landing-order amendment or evidence stays `[assumed]`).

## 8. One semantic/evidence model consumption

DRAFT PENDING — canonical schema IR driving validators, compiler facts,
Hegel domains, trace codecs, model domains, refinement contracts, solver
inputs; sampled vs bounded-complete vs monitored routing per §5; Hegel gaps
hand-built in-project (D9); concurrency/time obligations to jolt-sim;
sequential-model variants remain Hegel-`sampled`; no separate user-facing
languages; generated artifacts carry provenance headers and never assert
correctness.

## 9. Staged exit criteria

DRAFT PENDING — exact exit criteria for: charter acceptance; reference
evaluator; schema prototype; first verified kernel. Includes the CSIR v1 exit
test (one fixed corpus case through both paths, labeled `sampled`, plus
cross-run site-ID determinism vectors per F3) and the proof-target execution
gate (jolt-sim landing-order amendment).

## Appendix A. Normalization algorithm (normative)

DRAFT PENDING — per F3: gensym canonicalization, sibling/child indexing,
re-expansion chain order, treatment of position-propagated metadata; input to
the site-ID digest (F2). Drafted with §4.

## Appendix B. Grounding references

- Decision memo + amendments: `DECISION-MEMO-2026-08-01.md`
- P1 semantic facts register (v0.5.13 source-grounded)
- P2 decision alternatives; P3 first proof target design; P4 executable
  obligations; P5 claim checklist; P6/P7 design challenges; P8/P9 Fable slices
- Review reconciliation: `REVIEW-RECONCILIATION-2026-08-01.md`
- Lane handoff: `APPLICATION-CORE-HANDOFF.md`
