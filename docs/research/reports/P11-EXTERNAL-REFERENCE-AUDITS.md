# P11 — External reference audits (Hydro, Cedar, FuzzChick, Dafny-stability, Checked C, Rubydust, EXPOSITOR)

**Provenance:** four parallel `jolt-research-auditor` in-session subagents
(Deepseek V4 Flash 0731 profile), 2026-08-01:
- Hydro audit — session `ses_03f56c807ffeopMEfiWfffZ6dn`
- Cedar audit — session `ses_03f5696b8ffe77gNhKbPqjgFtd`
- Trio audit (FuzzChick/Dafny/CheckedC) — session `ses_03f51390dffeTdB0JSM7AyK4RE`
- Provenance audit (Rubydust/ICSE'13) — session `ses_03f5106fdffe2VxJGkwltbBD7H`
**Sources:** local captures in `/home/chuck/ai-src/refs-cache/` (web markdown
captures; PDF→text extractions via uv+pymupdf). dafny-sound paper obtained from
the user-supplied alternate URL (cutler.pl) after the UPenn link 404'd.
**Status:** UNREVIEWED working reports. Auditor-corrected framings noted inline.
Incorporation dispositions are the primary's, presented in chat.

---

## Part A — Hydro docs audit

### 1. Core mechanism
"Hydro comes with a built-in deterministic simulation environment" and "The simulator uses the exact same Hydro code you will run in production, and requires no changes" (simulation.md:5,16). Tests "are run against various distributed schedules to test possible concurrent executions" (simulation.md:5). Safety bugs are caught "at compile time rather than in production" via the type system (correctness.md:18). Inference: production code and simulated execution share one code path; the simulator varies schedule/interleaving, not the program.

### 2. The "exhaustive" claim
"the Hydro simulator can perform **exhaustive** checks, which ensure that your application will behave correctly in *all* possible distributed executions. For particularly complex tests where there are too many scenarios to check, the Hydro simulator can use **coverage-guided fuzzing** to *intelligently* explore the space of executions and find bugs" (simulation.md:7). The space claimed is "all possible distributed executions" — schedules over message delays, interleavings, retries (correctness.md:7). Fallback: coverage-guided fuzzing, framed as bug-finding, not guarantee. Mapping: our `bounded-complete` requires "a finished, uncapped exploration of that same finite relation" (memo D3); Hydro's "all possible distributed executions" is asserted over a space the captured text never declares finite or bounded — either our bounded-complete over an implicit finite schedule space, or a stronger-sounding claim lacking a declared finite relation. Fuzzing maps to our `sampled`; our lattice does not grade coverage-guided vs random sampling. Inference: Hydro's "exhaustive" is not provably our bounded-complete from these pages; the declared-finite-relation requirement is absent.

### 3. `nondet!` guard mechanism
"when it is necessary to bypass these checks for advanced distributed logic, Hydro requires you to attach **non-determinism guards** (`nondet!`) that explain the effects of the non-determinism, clearly marking the code that should be carefully reviewed" (correctness.md:18). Same idea as our mechanical widening: both quarantine bypass points from claims. Differences: ours is compiler-mechanical and automatic; Hydro's is user-attached at each bypass. Ours is sounder-by-default (cf. rejected B1 "opt-in annotations: unsound by omission"); Hydro's forces human attention per site. Borrow: the mandatory "explain the effects" requirement — a human-authored explanation at each widening site, stronger than our current "declared assumptions" field, plus review-flagging of widening sites. Inference: combination (mechanical detection + mandatory explanation) would be strictly stronger than either alone.

### 4. Bounded vs Unbounded types — analogous §3 hazard
"Observing a collection that is still asynchronously changing as if it were a final result" (correctness.md:9-10). §3 should name a hazard class, e.g. "live-collection-as-final": a sampled/monitored observation of a collection is interpreted as a terminal value while another lane still mutates it. Our D3 never-promote list guards promotion but not this observation-scoping error; the taxonomy should require a declared quiescence point before any collection observation may be treated as final, mirroring Hydro's bounded/unbounded typing.

### 5. Feature-support matrix as honesty pattern
Table with Support Level Full/Partial/Limited and Notes, e.g. "Non-Deterministic Observations | Limited | `assume_ordering::<TotalOrder>` is supported, `assume_retries::<ExactlyOnce>` is not supported" (simulation.md:18-24). Gains: per-feature pre-committed coverage granularity; the Notes column names exact supported/unsupported variants, precluding overclaim; it qualifies the "exact same Hydro code… requires no changes" claim with "some limitations around non-deterministic observations and timing" (simulation.md:16); turns a capability boundary into a reviewable contract. Matches our D6 named-exclusions pattern and should be the shape of the §1 profile matrix: per-feature rows with named exclusions, not a blanket profile.

### 6. SURPRISES (both sides, unresolved)
- **Exhaustiveness scope vs D3:** Hydro claims "all possible distributed executions" with no declared finite relation, vs our bounded-complete requiring a finished, uncapped exploration of a declared finite relation. Side A: Hydro's claim is stronger than our bounded-complete (no declared finiteness). Side B: the simulator's schedule enumeration is implicitly finite, making it our bounded-complete. Not resolvable from captured text.
- **`nondet!` vs rejected B1:** Hydro mandates user-attached guards at bypass points; our charter rejected "opt-in annotations: unsound by omission". Side A: Hydro's pattern is the rejected opt-in annotation. Side B: Hydro's guard is mandatory-at-bypass and carries no claims (review-marking only), so it is not the rejected B1. Not resolved here.
- Minor: Hydro's "requires no changes" same-code claim sits alongside our rule "Production libraries never depend on jolt-sim" — different objects (app code vs library dependency), no direct conflict.

### 7. UNKNOWNS
(a) how exhaustive vs fuzzing modes are distinguished in test reporting/output; (b) the exact finite space/bounds over which exhaustiveness is claimed; (c) `nondet!` syntax/semantics/enforcement; (d) how Partial/Limited rows are enforced; (e) whether "all possible distributed executions" includes retry/duplicate schedules. Pages needed next: "Non-Determinism and nondet!", "Eventual Determinism", "Bounded and Unbounded Types", "Writing Simulation Tests", "Coverage-Guided Fuzzing", and the Flo POPL 2025 paper.

---

## Part B — Cedar (OOPSLA'24) audit

### Q1. Correctness architecture
1. Lean formalization; five properties proved (§3.5): "Forbid trumps permit", "Default deny", "Explicit allow", "Sound slicing", "Validation soundness".
2. Rust implementation, not proved: "used extensive differential random testing to ensure that the implementation matches the model" (§1).
3. Differential random testing Lean-vs-Rust: "test that equal inputs map to equal outputs" (§3.6).
4. Symbolic compiler to decidable SMT: "a decidable, sound, and complete encoding of their semantics" (§1).
5. Validator: "ensures that policy evaluation will never error on a type mismatch, or a bogus attribute or role name" (§1).
6. TCB framing: "Since the authorizer is part of an application's security trusted computing base (TCB)…" (§3.5).
7. Trusted: Lean kernel, the Lean model as spec, the SMT solver (CVC5 1.0.5, §5.4). Checked: Rust impl vs Lean model (differential, sampled); design properties (Lean-checked certificates); encoding soundness/completeness — paper-proved only, "proofs of soundness and completeness using the Lean encoder are underway, as of this writing" (§4.4).
8. Inference: no component is both proved and the production artifact; the production artifact (Rust) is only tested, never proved.

### Q2. Differential testing vs our §6 loop
- Setup: "The Lean model is executable by compilation to native code, so we use extensive differential random testing… generators (for policies, entity stores, and requests) in the style of Pałka et al., and the cargo fuzz framework to test that equal inputs map to equal outputs" (§3.6). Agreement = same inputs → same outputs.
- Bugs: "uncovering nearly two dozen bugs since the project's inception, and forcing us (via CI) to keep the Lean spec and proofs up to date" (§3.6); proofs also found bugs: "the proof of validation soundness, revealed several bugs" (§3.5).
- Also direct property tests on the implementation: "the 'round trip' property that a pretty-printed Cedar abstract syntax tree parses back to itself" (§3.6).
- They have that our §6 lacks: (a) generators for all input classes; (b) CI-enforced spec/implementation sync; (c) the reference is the same artifact as the proof model (single source); (d) direct property tests on the implementation, not only cross-implementation comparison.
- We have that they lack: CSIR site-IDs/provenance, mandatory evidence metadata incl. canonical replay coordinates, the 7-level lattice, lane taxonomy + widening. Cedar's loop is a bare agree/disagree with no replay coordinates or evidence levels.

### Q3. Decidable SMT encoding — lessons for our §9 fragment
- Design-for-decidability: "a novel type-based translation that employs only decidable theories, and finite sets of ground well-formedness constraints (e.g., to ensure entity graphs are acyclic) rather than quantified constraints" (§2.6); "made possible by Cedar's controls on expressiveness, and by leveraging invariants ensured by Cedar's policy validator" (§4).
- Quantifiers break it: "the quantifiers make the encoding undecidable, causing timeouts or unknown results" (§4.3).
- Grounding trick: "a Cedar expression e accesses only a finite set of entities from the store… the footprint of e" (§4.3); per-footprint-pair transitivity + per-footprint acyclicity constraints "force the relation defined by the ancestor functions to be the transitive closure of an underlying DAG" (§4.3).
- Types map directly to SMT: "Cedar's types are designed to enable a direct translation to SMT types" (§4.1); errors via Option (§4.2); subtyping restricted: "support depth subtyping but not width subtyping, and there is no subtyping among entity types" (§3.4).
- Concrete lessons: (1) choose a fragment whose types map 1:1 to decidable theories; (2) replace every quantified well-formedness obligation with ground constraints over the finite footprint of the checked program — for our D5 bounded BFS the state space is already finite, so ground all invariants to the reachable-state set; (3) make the typechecker/validator a precondition so the encoding is "a total function from well-typed expressions to well-typed terms" (§4.2); (4) encode errors explicitly; (5) restrict subtyping/width so obligations stay mechanical.

### Q4. Validator → our §8 schema/contract layer
- Singleton types: "Singleton types True and False are ascribed to expressions sure to evaluate to true and false" — dead-branch pruning and always-true/always-false warnings (§2.5).
- Capabilities: "Capabilities ensure that a policy always checks the presence of an optional attribute before accessing it" (§2.5); mechanism: `e has f` produces capability ε={e.f}; optional access must be in capability α (§3.4); conditionals thread guard capabilities into branches.
- One-model consumption: the schema (M,S) drives the validator (§2.5), the symbolic compiler ("the symbolic store for M", §4.1), and generators (§3.6) — matches our §8 one-schema-IR principle.
- Capability mechanism worth adopting: yes — model required map entries as plain fields, optional entries as Option; optional-entry access in contracts requires a prior presence check (Cedar's `has`), enforced by the schema validator so validators, generators, and traces agree on which optional fields are guaranteed present. Mechanical check, fitting §9.

### Q5. Entity DAG vs S1 single-parent
- Cedar: "The parent relation on entities forms a directed acyclic graph (DAG)" (§2.2). `in` is boolean reachability (§3.2). Slicing enumerates all ancestors with no preference: "K=(hp∪{P,Any})×(hR∪{R,Any})" (§3.3). Policy combination is fixed, not specificity-ordered: "forbid policies always override permit" (§2.4).
- Judgment: Cedar's DAG does not weaken S1. Cedar never selects a most-specific ancestor — `in` is reachability and combination is a fixed rule. H3's handler applicability must choose among handlers ("the most-specific family wins…"), which needs a total order a DAG cannot guarantee. The query-vs-dispatch distinction justifies keeping S1.

### Q6. Evidence discipline vs our 7-level lattice
- Proved (Lean certificates): the five §3.5 properties.
- Paper-proved only: encoding soundness/completeness — "proofs… are underway, as of this writing" (§4.4). By our lattice this is not `proved`; it is `assumed`-level until the Lean certificate exists. The §1 contribution "A verified symbolic compiler" is stronger than §4.4's status — a mislabel by our standards.
- Tested (sampled): differential random testing (§3.6); cross-engine agreement in perf eval (§5.2).
- Nothing claimed: the Rust implementation's correctness (only tested); CVC5 and the Lean kernel trusted without stated assumptions; no bounded-complete or coverage claims — their testing is unbounded random sampling = our `sampled`, and they never claim more.
- Match: their `proved` ≈ our `proved`; their differential ≈ our `sampled`. Mismatch: the "verified symbolic compiler" headline vs in-progress Lean proofs.

### Q7. Surprises
1. Cedar's validator is optional (§3.4) and unvalidated policies can error at runtime (§3.2) — vs our B2 mandatory lane inference. Different domains, but opt-in-vs-mandatory philosophy differs.
2. The reference model itself was buggy: proofs and differential testing "revealed several bugs" / "other subtle bugs in our semantics" (§3.5) — the oracle is not infallible; our §6 reference evaluator is likewise TCB and needs its own controls.
3. Forgiving semantics: "Cedar's semantics is generally forgiving for operations on entity references that do not exist in μ" (§3.2) — vs our fail-closed posture. Opposite design directions.
4. "A verified symbolic compiler" (§1) vs "proofs… underway" (§4.4) — internal tension within the paper.

### Q8. Unknowns
Post-publication status of the Lean encoding proofs; generator distributions; whether any Rust component is formally verified; identity of the ~two dozen bugs; whether §3.5 properties cover templates/extension types/action groups; "CVC5's theory of sets which is not standardized" (§4.1) — the decidable-fragment claim rests on a non-standard theory.

---

## Part C — FuzzChick / Dafny-stability / Checked C audit

### 1. Sources
- **FuzzChick** = "Coverage Guided, Property Based Testing"; Lampropoulos, Hicks, Pierce; PACMPL OOPSLA 2019, Article 181 (p.1). CGPT = PBT + coverage-guided fuzzing: instrument the property + SUT (not the framework) for control-flow coverage; retain inputs covering new paths; type-aware mutators at the algebraic-datatype level; random-generation fallback for local minima (p.3; Alg. 3, p.11). Implemented as a QuickChick (Coq) extension. Claim: finds bugs under sparse preconditions orders of magnitude faster than QuickChick/Crowbar (p.1, p.4).
- **Dafny-stability** = "Improving the Stability of Type Soundness Proofs in Dafny"; Cutler, Torlak, Hicks; extended abstract, venue placeholder (p.1). Recipe: make safety predicate and typechecker opaque; prove per-typing-rule compatibility lemmas and inversion lemmas; soundness proof calls them around IH calls (pp.3-4). Eliminates SMT verification instability; scales to Cedar (p.1, p.5).
- **Checked C** = "Achieving Safety Incrementally with Checked C"; Ruef, Lampropoulos, Sweet, Tarditi, Hicks (venue not in extraction). Every C program is a Checked C program; checked pointers intermix with legacy; checked regions restrict to checked pointers; compiler inserts null/bounds checks at checked dereferences; Coq-mechanized blame theorem: checked code cannot be blamed for spatial-safety failures (pp.1-3, 12-14). Plus `checked-c-convert` porting tool (§5).

### 2. FuzzChick
- Integration: properties, generators, printers, shrinkers are all Coq definitions; extract to OCaml with a runtime library for IO/randomness (p.7); `Derive` synthesizes generator/show/shrink from the type (p.6).
- Failed test vs proof: failed test returns a shrunk counterexample (p.6); testing is explicitly pre-proof: "iron out most of the bugs… before spending the energy required to prove correctness formally"; no counterexample ⇒ "proceed with greater confidence" — never completeness (p.5).
- §5 mapping: matches our sampled-vs-proved split exactly; their evaluation uses systematic fault injection with known ground truth (rule-table mutants, p.17) — same control discipline as our D5 buggy known-SAT control. Their `NoBug` after maxTests ≈ our sampled pass; counterexample ≈ D3's `failed`.
- Borrow for §8: the same property definition serves both testing and proof (`mirror_twice` is QuickChicked before being proved, p.6) — one artifact, two evidence levels. Coverage instrumentation targets property+SUT only, never the framework (p.3, p.10) — coverage should be about the claim, not the harness. Rule-table factorization isolates the checked logic for systematic mutation — a model for isolating our kernel transition relation for fault injection.

### 3. Dafny soundness
- What is proved: type soundness of a small expression language (and Cedar): `⊢e:t ⇒ ∃v. e↓v ∧ v:t`, as a Dafny lemma over the definitional interpreter `eval` and typechecker `check`, both implemented in Dafny (p.1). Not the Dafny verifier, not Boogie compilation — the semantics *is* the interpreter (`e↓v` iff `eval(e)=Ok(v)`, p.1).
- TCB vs machine-checked: machine-checked = Dafny+SMT (Z3) accepted the VCs. Assumed/TCB: the evaluator ("all proofs are relative to this evaluator," p.4), the `Term`/`Ty` encoding, and the verifier itself — which is unstable: verification can flip verified→unverified on minor, even unrelated, changes (p.1).
- §9/§7 mapping: a credible soundness statement must name (a) the exact theorem and the artifacts it is relative to, (b) the checking mechanism and its instability, (c) what is opaque/specified vs implemented. Their opacity + specification-lemma discipline is a TCB-table pattern — each component specified and made opaque so the proof depends only on the specification — like our D5 "each TCB row with its own control." Their stability proxy (resource-usage variance, p.4) supports our D3 requirement to pin tool/checker versions in evidence records.

### 4. Checked C incremental
- Coexistence: checked regions may not use unchecked pointers/arrays nor call unprototyped/vararg functions (p.4); `Unchecked` blocks give full C freedom (p.4); interface types (`itype`) let one function serve both regions (p.5); callers that cannot make an argument safe insert a local cast (p.2). Runtime checks exist only at checked-pointer dereferences — erasure semantics, no boundary checks (p.3, p.20); failure = runtime error + process termination (p.3).
- Blame: Theorem 3 — a stuck well-typed program's redex is in unchecked code (p.13). Reviewer guidance: focus on unchecked regions, trust checked ones (p.14).
- §3/§8 mapping: checked/unchecked ≈ our ordinary-core vs Dynamic-opaque lanes, with explicit boundary artifacts (`Unchecked` blocks, casts, `itype`) ≈ our mechanical-widening markers. Blame lesson: the precise side is blameless even when failure occurs inside it — blame attributed to the opaque side; achievable with erasure semantics, but the failure signal is process termination, not a contract-violation report — our Dynamic→precise contract rule should decide which failure mode it wants. Their "cast signals something to investigate" (p.17) is a blame-visibility mechanism worth borrowing.
- Migration ergonomics: best-effort partial conversion that never blocks compilation (p.2); per-function constraint solving prevents one unsafe use from poisoning the whole program (p.15); converted pointers "need never be considered again" by later assurance (p.18) — monotonic progress; the program stays compilable/testable at every stage (p.3). Lesson for staged verification: keep the artifact buildable and testable at every stage; make conversion best-effort and non-blocking; record what is done so later stages don't revisit it — supports our §9 "first verified kernel last" with verified parts staying verified.

### 5. Surprises
- Checked C proves blame with erasure semantics — no runtime checks at boundaries (p.3, p.20) — while our §8 places contracts at Dynamic→precise boundaries. Both sides: (a) the charter's contract-at-boundary implies boundary checks; (b) Checked C shows a blame theorem without them, at the cost of process-termination failure mode. No resolution.
- Dafny front matter internally inconsistent: ACM Reference Format says 2023; footers say "Conference'17, July 2017" with placeholder DOI (p.1).
- FuzzChick: hand-written generators beat FuzzChick by orders of magnitude (<1s vs minutes) (p.4, p.21) — supports D9's hand-built generators, but shows the gap is large.
- No charter decision directly contradicted; the erasure-semantics blame above is the closest tension.

### 6. Unknowns
- FuzzChick: no mechanism for promoting a passed test into proof status, or attaching test-evidence records to proofs; no evidence-metadata discipline.
- Dafny: exact venue; Cedar proof's TCB not enumerated; verifier soundness unaddressed.
- Checked C: venue; the Coq mechanization covers CoreChkC, not the Clang implementation (check insertion, subsumption, flow-sensitive typing future work, p.21); the 8.6% overhead figure is cited, not measured here (p.5).

---

## Part D — Rubydust / EXPOSITOR audit

*(Auditor corrected the assignment's framing: Rubydust is dynamic type inference, not origin tracking; ICSE'13 is a time-travel debugging paper, not a provenance paper. Both corrections verified against front matter.)*

### 1. Identification & core mechanism
- **Rubydust** = "Dynamic Inference of Static Types for Ruby"; An, Chaudhuri, Foster, Hicks; POPL'11 (p1). Constraint-based dynamic type inference: each runtime value wrapped with a type variable for its position (field/argument/return), subtyping constraints generated on use, solved after the run; sound if training covers all paths through each method body (p1; Thm 3.1, p8).
- **ICSE'13** = "EXPOSITOR: Scriptable Time-Travel Debugging with First-Class Traces"; Khoo, Foster, Hicks; ICSE 2013 (p1). Execution trace as a time-indexed list of state snapshots manipulated with list combinators (map/filter/merge/scan); lazy sparse interval trees materialized on demand over the UndoDB backend; EditHAMT lazy sets/maps; validated on a stack-smash and a Firefox data race (p1, p8).

### 2. Rubydust: attachment, overhead, debugging value, charter mapping
- Attachment: values wrapped at method entry/exit and field boundaries with a `Proxy` {wrapped object, type, owner}; `method_missing` intercepts calls (p2, p10). Per-position wrapping, not per-value lineage (p2).
- Overhead: "quite high" (p1): a-star 114.81s vs 0.04s, ministat 11.19s vs 0.00s (p11); wrappers impede interpreter fast paths.
- Debugging value: found a real type error from a *passing* test run (Ascii85, p1, p11-12); coverage-blame: instrument to flag uncovered paths and blame lack of coverage (p2); answers "what contract must this value satisfy and is usage consistent across call sites" — a stack trace shows *where*, not *which contract was violated*.
- Charter mapping: §4 CSIR provenance is static/compile-time; Rubydust is the missing *dynamic* half: runtime attachment of position identity. For §8, a dynamic origin tag ("which CSIR site produced this runtime value") is worth adding to the runtime-observation model. **Cost:** wrapping is semantically invasive — `false`/`nil` unwrapped for truthiness (p10), `instance_eval` escape hatch unsoundness (p10), single-threaded assumption (p4). **Canonicalization:** Rubydust's answer: forward `eql?`/`hash` to the wrapped object so the tag is invisible to equality (p10). Inference: origins must be out-of-band metadata in the trace event schema (like EXPOSITOR's item.time/item.value), never part of the canonical value, or H5 hash-consistency breaks.

### 3. ICSE'13 lesson (honest mapping)
Not provenance/blame/contracts — a debugging environment. Transferable to §8: trace-as-first-class-object — time-indexed, lazily materialized, composable, backward search from a symptom (1s backward vs 4s forward, p4); Firefox case correlates cross-thread events via EditHAMT (p8). For §4: EXPOSITOR carries no provenance — items are snapshots/values, not origins. Closest blame-adjacent mechanism is Whyline (slicing), noted as prohibitively expensive for fine-grained data-flow (p9) — a cost warning for any dynamic provenance spine. **No contract/blame lesson exists in this paper.**

### 4. Static vs dynamic — one paragraph
Both, at different stages. Static CSIR provenance (compile time) is the identity spine — site-IDs, expansion parent, resolved binding, lane — needed for evidence anchoring and remint policy. Dynamic origin tracking (runtime) serves §8: which site produced this value, and attribution inside Dynamic-opaque regions — F7's descriptor-level attribution is a static approximation, while Rubydust shows runtime instrumentation can distinguish per-method even for eval-created methods (p5). Stage: static first (CSIR v1, C1); dynamic later as an opt-in runtime-observation extension — Rubydust's cost and semantic invasiveness argue for lazy, on-demand tagging (EXPOSITOR's laziness) rather than eager wrapping, with origins carried as trace-schema metadata so they survive canonicalization.

### 5. Surprises
- **Framing mismatch:** Rubydust is dynamic *type inference*, not origin tracking — contradicts the assignment's description, not the charter.
- **F7 vs Rubydust granularity:** charter says eval'd code's operations share the widening site's ID, discrimination from the descriptor (F7); Rubydust instruments eval-created methods individually after creation (p5). Charter side: static, cheap, fail-closed. Rubydust side: finer attribution, but requires runtime introspection Jolt's compiled Chez code may not offer.
- **H5 canonical hash vs value-attached tags:** Rubydust forwards `eql?`/`hash` (p10); the memo does not specify where origins live relative to canonical values — consistent but unspecified (resolved by the out-of-band-metadata rule above).
- **EXPOSITOR's lazy traces vs D3's mandatory trace digest:** eager full-trace digests are expensive (Firefox: 383MB, 2m6s, p8); the memo does not address lazy materialization of evidence traces.

### 6. Unknowns
- Rubydust: no Proxy memory-overhead figures; no multi-threaded story; no field-write/globals/literal/code-block interception; nothing on canonical values or trace digests.
- EXPOSITOR: no provenance/origin concept; fine-grained data-flow tracking explicitly future work; no digest/canonicalization answer; no contract/blame mechanism.
