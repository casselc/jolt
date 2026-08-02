# P13 — Site-ID ↔ descriptor unification cross-check (slice-3 replacement)

**Provenance:** `jolt-deep-reviewer` in-session subagent, session
`ses_03f0299eeffezA6kA7HMb3KkbS`, model
`fireworks-ai/accounts/fireworks/models/kimi-k3` (profile default), read-only,
2026-08-01. Bounded review of charter §4/§6/Appendix A unification (C4/F2/F6/F7).
**Status:** ADVISORY. Dispositions: **all findings accepted** and applied to the
charter on 2026-08-01 (before §6 commit). Replacement for the cancelled Fable
slice 3; same-model-family caveat applies (internal challenge).

---

# Review — slice-3 replacement: site-ID ↔ effect-descriptor unification (§4 ↔ §6)

**Verdicts:** Q1 coherent-with-amendment · Q2 coherent-with-amendment (one §6.6 sentence inoperable as written — blocker below) · Q3 coherent-with-amendment (minor) · Q4 coherent-with-amendment (one masking hole — major) · Q5 coherent-with-amendment (one identity-component inconsistency — major).

## Findings (ranked)

**A — BLOCKER [OBS]: §6.6's mandated divergence citation is unproducible as written.** §6.6 requires "the site-ID of the **first evaluation step whose observable differs**." But (i) the only observable the pure fragment defines is the §2.6 *terminal* state; intermediate steps have no observable — §3.4 emits events only at descriptor boundaries/lifecycle seams, which §6.8 excludes; (ii) §6.3 compares terminals only; (iii) the compiled side is "the v0.5.17 compiler/backend" with no stepwise canonical projection — so per-step "differs" has no referent on either side. This is P12-F1's shape (a mandate the charter's own components cannot fulfill). *Smallest amendment:* "the site-ID of the smallest reference-side subcomputation whose §2.6 terminal outcomes differ between sides (localized by re-evaluation over CSIR v1 nodes, which carry `site-id` per §4.1)." The evaluator-side annotation needs no new artifact — evaluator is "over CSIR v1", field set includes `site-id`; only the "observable differs per step" concept is undefined.

**B — MAJOR [OBS]: the provenance map §6.6 depends on is undefined in location, direction, and versioning.** §6.6 names "the CSIR→optimization-IR provenance map"; §4 never defines that artifact. The only candidate is §4.1's "plus a source/provenance map" — direction unstated (source-span vs optimization-IR), schema/digest unpinned, and absent from §5.4 record metadata (so mapped positions in divergence reports are not versioned/replayable). F1 does **not** break it *if* it stays outside the closed CSIR v1 document — but that placement must be stated. One-ID-space itself is coherent: C4 unifies descriptor↔CSIR IDs; the compiled side is reached by map, not by ID. *Smallest amendment:* §4.1 gains: "the compiler also emits a versioned CSIR provenance map, `site-id → {source span, optimization-IR node path}`, a side artifact outside the closed CSIR v1 schema (F1), its digest recorded in §5.4 metadata"; §6.6 cites that sentence.

**C — MAJOR [OBS]: §4.2 and Appendix A disagree about the site-ID's components; duplicate sibling subforms can collide.** §4.2 lists components `{CSIR-schema version, namespace/logical definition, resolved binding path, operation tag}` — **no role path** (F2 likewise dropped D1's "normalized expanded semantic-role path"). Yet A.5 states "The site-ID's 'semantic-role path' (§4.2)…", citing a component §4.2 doesn't list, and A.7 says "The NF is serialized … role paths embedded" — singular "The NF," admitting a whole-definition reading under which two identical `(+ 1 2)` invocations in one body share digest, binding path, and operation tag → **one ID, two sites**, silently breaking §6.6 attribution. No A.8 vector covers duplicate subforms. *Smallest amendment:* add "semantic-role path (A.5)" to §4.2's component list; A.7: "each node's digest is over the canonical serialization of that node's NF subtree with its role path embedded"; add a duplicate-subform vector to A.8.

**D — MAJOR [OBS gap; INF scenario]: one-sided non-canonical terminals can be laundered as lane exclusions.** §6.3 (via §2.6) makes a function/host-object-valued terminal "not canonical-comparable … classify the program's lane per §3" without stating per-side behavior. If reference yields `5` and compiled yields a function (a plausible compiler defect), the text permits reading the case as "excluded by lane" rather than as a §6.4 differential failure — exclusion then masks exactly the divergences §6.6 exists to attribute. Static widening is genuinely pre-evaluation (all §3.2 triggers syntactic), so "excluded by lane, not attributed" is consistent with F7 for *static* cases — but the value-dependent path is runtime-discovered and needs the symmetry rule. *Smallest amendment:* §6.3: "lane exclusion requires both sides' terminals non-canonical (or static non-fragment classification); an exactly-one-side non-canonical terminal is a differential failure per §6.4, attributed per §6.6."

**E — MINOR [OBS]: §6.6 cites F6/F7 in its header, but the v1 loop can never produce a descriptor.** §6.8 excludes FFI/host interop; §6.6's only descriptor sentence is future-tense. F6's `host-origin` class is unreachable in the pure fragment, and §9's exit test contains no host-origin or absent-`site-id` validation fixture. Nothing *claims* coverage, but the header citation invites that reading. *Smallest amendment:* §6.8 gains: "no descriptors exist in the v1 loop; F6's host-origin class and F7's per-instance `operation-id` are specified (§4.4) but uncovered-by-design until the host-capability extension."

**F — QUESTION [OBS]: "namespace/logical definition" (§4.2) and "reserved enumerated `host-origin` ID" (§4.4) are undefined in ways two artifacts could resolve differently.** "Logical" hints at refactor/REPL-redefinition stability but is nowhere defined; "enumerated" (closed list) sits oddly against "registration site + entry-kind tag" (open, per-registration). *Smallest amendment:* define "logical definition" as the enclosing top-level Var's `{ns, name}`; state host-origin IDs are enumerated per entry-kind with registration site as a field.

## Open questions
1. Finding D's rule presumes the harness can classify "non-canonical" per side independently — does the compiled side's terminal projection (§2.6 canonicalization) exist as a specified artifact, or is it part of the comparison harness (§6.1, currently "does not exist")?
2. If the provenance map (finding B) is versioned independently of the CSIR schema, does a map-only change force F4 remint orphaning (§4.3), or is it evidence-metadata-only?
3. Should A.8's determinism suite gain a vector for finding F's REPL-redefinition case once "logical definition" is defined?

**Summary for orchestrator:** one blocker (§6.6 attribution sentence), three majors (map artifact, role-path component inconsistency, exclusion asymmetry), one minor, one question-finding; each resolves with a single sentence or clause. The one-ID-space design (C4/F2/F6/F7) is coherent; §4↔§6 consistency requires the four named amendments, not redesign.

---

## Orchestrator dispositions (2026-08-01) — ALL ACCEPTED and applied

- A → §6.6 now localizes divergence by **subtree re-evaluation**: "the
  site-ID of the smallest reference-side subcomputation whose §2.6 terminal
  outcomes differ between sides" (no per-step observable needed).
- B → §4.1 defines the **CSIR provenance map** as a versioned side artifact
  `site-id → {source span, optimization-IR node path}`, outside the closed
  CSIR v1 schema; digest in §5.4 metadata; map-only changes are
  evidence-metadata-only, no F4 orphaning (answers reviewer open question 2).
- C → §4.2's component list now includes **semantic-role path (A.5)**; A.7
  digests per-node NF subtree + role path; A.8 gains a duplicate-subform
  vector.
- D → §6.3 gains the **both-sides exclusion rule**: exactly-one-side
  non-canonical terminal = differential failure, attributed per §6.6.
- E → §6.8: F6/F7 specified but **uncovered-by-design** in the v1 loop.
- F → "logical definition" = the enclosing top-level Var's `{ns, name}`;
  `host-origin` IDs enumerated per entry-kind with registration site as a
  field; A.8 gains the REPL-redefinition vector (answers reviewer open
  question 3).
- Reviewer open question 1 (compiled-side terminal projection): answered in
  §6.1's harness row — the comparison harness includes the compiled-side
  terminal canonicalization (§2.6).
