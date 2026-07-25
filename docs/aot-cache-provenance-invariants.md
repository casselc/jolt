# AOT generation and provenance invariants

This note records bounded Chiasmus/Z3 analyses of the namespace AOT cache. The
production recommendation is now a fresh-process, closed-world whole-project
image selected atomically under one immutable build token. Independently
reusable namespace artifacts are not a production boundary: they admit a mixed
build snapshot unless the runtime also implements provenance-sealed generation
routing, recursive candidate eligibility, an atomic in-memory artifact
guard/selection commit, complete consumed-input/effect and compiler-environment
gating, route-complete nested loading, reconstruct-or-taint reload handling,
atomic shared load bookkeeping, and a phase-safe retry boundary.

Those selective-runtime generation models remain useful research contracts and
counterexample records, but the stronger and simpler whole-image contract is the
recommended implementation. The older source/provider and live-revalidation
models remain evidence about rejected designs.

## Production disposition

The per-namespace runtime cache has been removed from the production loader.
`JOLT_AOT_CACHE` and `JOLT_CACHE_DIR` are accepted only as inert legacy process
environment; neither changes namespace loading nor creates artifacts.
[`namespace-load-effects-smoke.sh`](../test/chez/namespace-load-effects-smoke.sh)
sets both adversarially and checks with two fresh processes that `deftest`
registration runs both times and no cache files are created.

The checked models below therefore have two durable jobs: record why selective
namespace reuse was rejected, and bound any future whole-image implementation.
They do not justify another incremental namespace-cache prototype on the
production branch. The `research/aot-v5-prototype` branch remains the explicit
home for that investigation.

Every `UNSAT` result below means only that no counterexample exists within its
stated finite model. Runtime tests remain the semantic oracle. In particular,
the whole-image proof assumes that project-graph resolution and compiler-input
observation are complete; it does not establish their completeness.

## Downstream witness: cached tests disappear

A 2026-07-24 validation of the `jolt-lang/http-client` test runner supplied a
concrete ecosystem witness for the already modeled top-level-effect problem.
With released `joltc v0.4.15`, a cold `joltc -M:test` discovered and ran 60
tests. The immediately following warm invocation loaded the cached test
namespaces but reported:

```text
Ran 0 tests. 0 assertions passed, 0 failures, 0 errors.
```

Running with `JOLT_AOT_CACHE=0` discovered all 60 tests again. `deftest` both
defines a Var and performs a top-level registration effect; restoring namespace
definitions without reconstructing that effect leaves `clojure.test`'s runtime
registry empty. The TLS assertions in that downstream suite have independent
failures and do not affect the discovery witness.

This observation does not require a new invariant: it is a live instance of the
existing incomplete-effect/replay counterexamples. It strengthens the decision
to remove namespace-level runtime reuse rather than adding
`clojure.test`-specific replay logic. A closed-world image must contain one
coherent post-initialization state or execute its initialization exactly once;
it may not restore only the namespace definitions.

## Production invariant: fresh-process closed-world whole image

The production unit of reuse is one immutable whole-project image, not a set of
independently reusable namespace artifacts. A build:

- starts from a fresh compiler process and project namespace state;
- resolves one declared, complete project source graph and one complete
  compiler-input witness;
- binds that graph, input witness, emitted image bytes, and every namespace
  revision to one collision-resistant build token;
- publishes the image immutably in a private cache; and
- selects that image atomically by token, with no per-namespace selection or
  fallback to an artifact from another build.

Before user forms execute, the loaded image token, aggregate graph witness,
aggregate compiler-input witness, bytes, and namespace revisions must all match
the selected token. A dynamic compile input outside the declared graph fails
closed. Thus one execution cannot combine namespaces from different build
tokens, substitute different image bytes, run an undeclared dynamic compile
input, or inherit state from a non-fresh compiler process.

This is a deliberately closed-world contract. Complete graph and input
classification, collision-free tokens, and immutable token-to-image publication
are explicit implementation assumptions. The formal model proves the
post-classification selection gate, not a filesystem snapshot algorithm, a
dependency resolver, or exhaustive instrumentation.

## Whole-image production models and results

The checked-in inputs omit `(check-sat)` and model-extraction commands because
`chiasmus_verify` supplies them.

| Model | Expected and observed result | Meaning |
| --- | --- | --- |
| [`aot-whole-image-independent-artifacts-buggy.smt2`](../test/chez/formal/aot-whole-image-independent-artifacts-buggy.smt2) | `SAT` (72 returned model entries) | Independently selecting namespace A from `build0` and namespace B from `build1` executes a mixed snapshot even though each build's whole-image metadata is internally coherent. |
| [`aot-whole-image-closed-world-corrected.smt2`](../test/chez/formal/aot-whole-image-closed-world-corrected.smt2) | `UNSAT` (18-label core) | Fresh-process compilation, exact image-witness validation, atomic whole-image selection, and rejection of undeclared dynamic input admit no modeled mixed, substituted, undeclared-input, or non-fresh execution. |
| [`aot-whole-image-closed-world-nonvacuity.smt2`](../test/chez/formal/aot-whole-image-closed-world-nonvacuity.smt2) | `SAT` (72 returned model entries) | A coherent `build1` image executes with `violation=false`; irrelevant independently chosen namespace tokens are ignored. |

The rejected independent-artifact witness is:

```text
selected whole-image build token   = build0
independently selected namespace A = build0 / rev0
independently selected namespace B = build1 / rev1
loaded whole-image witness         = build0 / graph0 / inputs0 / bytes0
dynamic compile input              = declared
fresh compiler process             = true
user forms execute                 = true
mixed snapshot violation           = true
```

The corrected violation query has this exact 18-label `UNSAT` core:

```text
image_witness_integrity_definition
corrected_fresh_process_required
corrected_atomic_whole_image_selection
corrected_image_witness_guard
corrected_closed_world_dynamic_input_gate
effective_a_token_definition
effective_b_token_definition
effective_a_revision_definition
effective_b_revision_definition
closed_world_input_definition
execution_preflight_definition
user_form_execution_definition
mixed_snapshot_violation_definition
image_provenance_violation_definition
undeclared_dynamic_input_violation_definition
nonfresh_process_violation_definition
violation_definition
violation_query
```

The non-vacuity control selects and loads
`build1 / graph1 / inputs1 / bytes1`, obtains `effective_a_token=build1`,
`effective_b_token=build1`, `user_forms_exec=true`, and `violation=false`.
Both `SAT` model sizes count every binding returned by Chiasmus, including
named-assertion symbols, rather than only the projected witness fields.

## Selective-runtime research invariant: provenance-sealed generations

An executable namespace generation is an immutable record containing:

- the publication token that selects its artifact bytes;
- the recorded compile-input witness from which those bytes were emitted;
- exact dependency-generation tokens, recursively through the provider graph.

The selective-runtime research contract is:

> User forms may execute only from the artifact bytes selected by one immutable
> generation token. Those bytes must map to that generation's sealed
> compile-input witness, every provider must be routed through the generation's
> sealed dependency token, and every already-loaded provider must match the
> required token before any user form begins.

The compile-input witness is an aggregate of every input the compiler claims can
affect emitted bytes, including own source, retained provider inputs, compiler
context, reader identity, and target facts. The formal model assumes that
observation is complete; it does not prove completeness.

Publication additionally requires:

- an exact sealed observation for every input actually consumed by compilation,
  including lookup absence and present-value revision;
- fail-closed disablement for an untrusted compile-time effect unless the
  generation seals an explicit trust assertion or an explicit nonblank salt;
- either a matching requested namespace as the first meaningful form, or an
  exact sealed caller-namespace context for every meaningful pre-`ns` form.

At root candidate lookup, every sealed provider generation in the dependency
closure must still be eligible against its current aggregate
source/context/consumed-observation witness. After any intervening loader hook
and immediately before the first user form, one artifact guard rechecks every
in-memory generation token in that sealed route and atomically commits
selection. This guard/commit, not the earlier candidate lookup, is the semantic
selection boundary. A provider change before it misses or fails; a change after
it is post-selection.

The final artifact guard does not reread source, compiler inputs, reader state,
or the filesystem. Post-commit live changes do not retroactively change the
selected immutable route; they affect a later top-level load/reload transaction
or another process. The transaction does not attempt to make arbitrary live
process state equal the old compile state immediately before each form.

Two nested-loading boundaries are fail-closed in the selective-runtime policy:

- Arbitrary nested `:reload` or `:reload-all` cannot both honor moving-source
  semantics and preserve the selected generation's in-flight sealed route. A
  reload requested from inside a selected cached generation must fail before
  mutating namespace or provider state. Encountering a reload during capture
  makes that candidate unpublishable.
- A direct `load` or `load-file` during capture also makes the candidate
  unpublishable. Current outer-plus-nested capture can otherwise record the
  nested forms and then replay them through both paths, duplicating execution.
  This restriction may be relaxed only when the nested load is represented as
  an immutable sealed provider, or when capture suppression is proven to prevent
  duplicate recording and replay.
- A project-owned `require`, `load`, or `load-file` encountered by a selected
  cached generation must already be an edge in its sealed route. A warm-only
  conditional edge absent from that route fails before project forms or
  namespace/provider mutation; it must not fall back to independent loading.
  Immutable initial-install and baked namespaces are version-sealed exceptions.

This last rule intentionally makes dynamic loading cache-dependent: a program
whose branch reaches an unsealed project edge may run through the ordinary
loader but not through that cached generation. Code that requires moving-source
or arbitrary dynamic-load semantics must opt out of AOT publication/selection
for the affected namespace or transaction.

The retry boundary is separate:

> Integrity or generation-selection failures detected before user forms may
> retry. Once any user top-level form has begun, failure propagates and the same
> load transaction must not recompile or enter user forms a second time.

## Selective-runtime generation models and results

The checked-in inputs omit `(check-sat)` and model-extraction commands because
`chiasmus_verify` supplies them.

| Model | Expected and observed result | Meaning |
| --- | --- | --- |
| [`aot-generation-routing-independent-buggy.smt2`](../test/chez/formal/aot-generation-routing-independent-buggy.smt2) | `SAT` | Independent namespace selection mixes a correctly selected consumer/provider with the wrong transitive helper generation and still executes user forms. |
| [`aot-generation-routing-sealed-corrected.smt2`](../test/chez/formal/aot-generation-routing-sealed-corrected.smt2) | `UNSAT` | Sealed direct and transitive dependency routing, caller-bound immutable publication tokens, byte-witness integrity, and loaded-provider conflict preflight admit no modeled mixed-generation execution. |
| [`aot-generation-routing-nonvacuity.smt2`](../test/chez/formal/aot-generation-routing-nonvacuity.smt2) | `SAT` | A coherent second consumer generation with matching preloaded provider and helper executes normally. |
| [`aot-generation-selection-eligibility-buggy.smt2`](../test/chez/formal/aot-generation-selection-eligibility-buggy.smt2) | `SAT` | A provider sealed at revision 0 is current at revision 1, but a missing recursive eligibility gate selects and executes it. |
| [`aot-generation-selection-eligibility-corrected.smt2`](../test/chez/formal/aot-generation-selection-eligibility-corrected.smt2) | `UNSAT` | Recursive direct/transitive provider eligibility at root selection prevents stale sealed witnesses from executing. |
| [`aot-generation-selection-eligibility-nonvacuity.smt2`](../test/chez/formal/aot-generation-selection-eligibility-nonvacuity.smt2) | `SAT` | A matching provider revision and matching helper absence witness select and execute without a miss. |
| [`aot-artifact-guard-precommit-buggy.smt2`](../test/chez/formal/aot-artifact-guard-precommit-buggy.smt2) | `SAT` | A provider token mutates after root candidate lookup, but an omitted final in-memory guard commits and starts user forms. |
| [`aot-artifact-guard-precommit-corrected.smt2`](../test/chez/formal/aot-artifact-guard-precommit-corrected.smt2) | `UNSAT` | Rechecking all route tokens and atomically committing at the artifact guard prevents a pre-guard mismatch from executing. |
| [`aot-artifact-guard-precommit-nonvacuity.smt2`](../test/chez/formal/aot-artifact-guard-precommit-nonvacuity.smt2) | `SAT` | Both ambient tokens may mutate after guard/commit while execution retains the immutable selected route. |
| [`aot-consumed-input-effect-buggy.smt2`](../test/chez/formal/aot-consumed-input-effect-buggy.smt2) | `SAT` | An omitted consumed revision and unauthorized untrusted effect still publish and execute when both gates are disabled. |
| [`aot-consumed-input-effect-corrected.smt2`](../test/chez/formal/aot-consumed-input-effect-corrected.smt2) | `UNSAT` | Complete exact consumed-input observations plus the fail-closed effect contract prevent both modeled violations. |
| [`aot-consumed-input-effect-nonvacuity.smt2`](../test/chez/formal/aot-consumed-input-effect-nonvacuity.smt2) | `SAT` | Exact present and absent observations with sealed trust and a nonblank salt still publish and execute. |
| [`aot-consumed-input-late-bound-runtime-control.smt2`](../test/chez/formal/aot-consumed-input-late-bound-runtime-control.smt2) | `SAT` | A non-consumed ordinary runtime Var can be redefined after selection without forcing a publication miss. |
| [`aot-compiler-environment-taint-buggy.smt2`](../test/chez/formal/aot-compiler-environment-taint-buggy.smt2) | `SAT` | Baked nonmacro promotion, project alias retarget, and consumed registry change remain untainted and an old hit is accepted. |
| [`aot-compiler-environment-taint-corrected.smt2`](../test/chez/formal/aot-compiler-environment-taint-corrected.smt2) | `UNSAT` | Refined compile-identity taint plus final publication recheck prevents an unsafe environment change from being accepted. |
| [`aot-compiler-environment-taint-nonvacuity.smt2`](../test/chez/formal/aot-compiler-environment-taint-nonvacuity.smt2) | `SAT` | A fresh namespace, precisely scoped loader update, and ordinary late-bound nonmacro root change still permit publication. |
| [`aot-direct-load-capture-buggy.smt2`](../test/chez/formal/aot-direct-load-capture-buggy.smt2) | `SAT` | Outer-plus-nested direct-load capture publishes, replays one nested side effect twice, and independently follows an absent project route edge. |
| [`aot-direct-load-capture-corrected.smt2`](../test/chez/formal/aot-direct-load-capture-corrected.smt2) | `UNSAT` | Capture-time direct load disables publication and selected project operations absent from the sealed route fail before project execution. |
| [`aot-direct-load-capture-nonvacuity.smt2`](../test/chez/formal/aot-direct-load-capture-nonvacuity.smt2) | `SAT` | A capture with no direct load publishes and its selected generation executes without duplicate replay or route escape. |
| [`aot-loaded-libs-rmw-buggy.smt2`](../test/chez/formal/aot-loaded-libs-rmw-buggy.smt2) | `SAT` | Two unrelated marks read the same loaded-libs set and a later stale write loses the first mark. |
| [`aot-loaded-libs-rmw-corrected.smt2`](../test/chez/formal/aot-loaded-libs-rmw-corrected.smt2) | `UNSAT` | One shared mutex or atomic update preserves both marks under either bounded write order. |
| [`aot-loaded-libs-rmw-nonvacuity.smt2`](../test/chez/formal/aot-loaded-libs-rmw-nonvacuity.smt2) | `SAT` | Two initially absent namespace marks both remain present after the corrected update. |
| [`aot-selected-nested-reload-buggy.smt2`](../test/chez/formal/aot-selected-nested-reload-buggy.smt2) | `SAT` | A selected transaction mutates its sealed provider for a nested reload and continues executing. |
| [`aot-selected-nested-reload-corrected.smt2`](../test/chez/formal/aot-selected-nested-reload-corrected.smt2) | `UNSAT` | Nested reload fails before provider mutation, stops selected execution, and cannot retry after user forms have begun. |
| [`aot-selected-nested-reload-nonvacuity.smt2`](../test/chez/formal/aot-selected-nested-reload-nonvacuity.smt2) | `SAT` | With no nested reload, selected execution remains reachable without mutation or retry. |
| [`aot-same-namespace-reload-residue-buggy.smt2`](../test/chez/formal/aot-same-namespace-reload-residue-buggy.smt2) | `SAT` | A macro removed from new same-namespace source survives in retained old cells and cached execution observes the residue. |
| [`aot-same-namespace-reload-residue-corrected.smt2`](../test/chez/formal/aot-same-namespace-reload-residue-corrected.smt2) | `UNSAT` | Reconstructing cells or tainting retained-cell reloads prevents stale residue from executing. |
| [`aot-same-namespace-reload-residue-nonvacuity.smt2`](../test/chez/formal/aot-same-namespace-reload-residue-nonvacuity.smt2) | `SAT` | A reconstructed same-namespace reload exactly matches new nonmacro source and may execute untainted. |
| [`aot-generation-transaction-user-retry-buggy.smt2`](../test/chez/formal/aot-generation-transaction-user-retry-buggy.smt2) | `SAT` | Retrying a user top-level failure creates two compile/load attempts and enters the user-form phase twice. |
| [`aot-generation-transaction-corrected.smt2`](../test/chez/formal/aot-generation-transaction-corrected.smt2) | `UNSAT` | Disabling retry after user forms begin prevents the modeled duplicate compile/execution. |
| [`aot-generation-transaction-integrity-retry-nonvacuity.smt2`](../test/chez/formal/aot-generation-transaction-integrity-retry-nonvacuity.smt2) | `SAT` | An integrity failure stops before selection and user forms, retries, and reaches user forms exactly once. |
| [`aot-generation-transaction-selection-retry-nonvacuity.smt2`](../test/chez/formal/aot-generation-transaction-selection-retry-nonvacuity.smt2) | `SAT` | A selection failure after integrity but before user forms retries and reaches user forms exactly once. |

### Mixed-generation witness

The routing model has two immutable consumer generations, two provider
generations, and two helper generations. The shaped buggy witness is:

```text
selected consumer generation       = cgen0
selected direct dependency         = pgen0
selected transitive dependency     = hgen0
loaded consumer publication token  = token0
effective provider generation      = pgen0
effective helper generation        = hgen1
user forms execute                 = true
transitive routing violation       = true
```

Thus the direct provider happens to match, but independent selection of its
helper is enough to produce a mixed generation. The violation is not
manufactured by a free flag: each routing and execution predicate is defined
bidirectionally from the finite generation values.

The corrected model routes both edges:

```text
consumer generation --sealed token--> provider generation
provider generation --sealed token--> helper generation
```

If an already-loaded provider or helper conflicts with either token, preflight
fails before `user_forms_exec`. If no conflict exists, the selected publication
token maps to immutable bytes and their recorded compile witness.

The corrected query's named `UNSAT` core is:

```text
corrected_sealed_dependency_routing
corrected_loaded_provider_preflight
corrected_publication_token_guard
corrected_sealed_byte_guard
provider_routing_definition
effective_provider_definition
transitive_dependency_routing_definition
effective_helper_definition
loaded_provider_conflict_definition
publication_token_match_definition
sealed_bytes_match_definition
generation_preflight_definition
user_form_execution_definition
routing_violation_definition
transitive_routing_violation_definition
publication_violation_definition
byte_provenance_violation_definition
loaded_conflict_violation_definition
violation_definition
violation_query
```

The non-vacuity control selects `cgen1 -> pgen1 -> hgen1`, preloads matching
`pgen1` and `hgen1`, loads `token1`, and obtains
`user_forms_exec=true, violation=false`.

### Concurrent publication and immutable selection

The routing family includes two publications at the same abstract step followed
by token selection at the next step. Both generation records remain available;
selection binds one token rather than reading a replaceable shared artifact
name. The byte-witness and publication-token violations in the corrected query
therefore cover a caller selecting one generation while loading the other's
bytes.

This is a bounded abstraction of concurrent publication, not a filesystem
atomicity proof. It assumes publication tokens are collision-free and that the
private cache preserves the immutable token-to-bytes mapping.

## Selection-time provider eligibility

Sealed routing answers which generation a root requires. It does not by itself
answer whether that old generation is still eligible when a new root load
begins. The selection family adds one direct provider and one transitive helper,
each with:

- a sealed aggregate source/context/consumed-observation witness;
- the corresponding current witness observed during root selection.

The buggy SAT witness is:

```text
sealed provider witness              = witness_rev0
current provider witness at selection = witness_rev1
sealed helper witness                = witness_rev0
current helper witness at selection  = witness_rev0
root selection succeeds              = true
miss or recompile                    = false
user forms execute                   = true
violation                            = true
```

The corrected gate requires equality recursively before selection succeeds.
Its named `UNSAT` core is:

```text
provider_selection_eligibility_definition
helper_selection_eligibility_definition
recursive_selection_eligibility_definition
corrected_recursive_eligibility_gate_enabled
root_selection_gate_definition
user_form_execution_definition
selection_currentness_violation_definition
violation_definition
violation_query
```

The non-vacuity control matches provider revision 1 and a first-class helper
absence witness. It executes with `miss_or_recompile=false` and
`violation=false`.

This model establishes eligibility while choosing the root's sealed graph, but
its `root_selection_succeeds` is now understood as candidate lookup rather than
the final semantic commit. The artifact-guard family below covers the bounded
hook interval after that lookup. Neither family requires a second filesystem or
source chase: the final guard compares only in-memory route tokens.

## Artifact guard and selection commit

The artifact-guard family makes the candidate/commit distinction explicit with
one direct provider token, one transitive helper token, one intervening hook, and
three mutation times. The buggy witness is:

```text
mutation timing                  = mutation_before_guard
mutation target                  = provider_target
provider token after hook        = gen1
sealed provider token            = gen0
selection committed              = true
first user form executes         = true
pre-guard route mismatch         = true
violation                        = true
```

The corrected guard compares both in-memory tokens against the sealed route
after the hook and makes that check indivisible from selection commit. Its
violation query is `UNSAT` with this named core:

```text
corrected_artifact_guard_enabled
artifact_guard_pass_definition
selection_commit_definition
first_user_form_execution_definition
pre_guard_mismatch_definition
violation_definition
violation_query
```

The non-vacuity control mutates both ambient provider tokens after the
guard/commit. The selected route retains `gen0`, the first user form executes,
and `violation=false`. No filesystem, source, reader, or arbitrary compiler-state
observation appears in the model. This single token guard is the final selection
commit, not a return to the rejected per-form live-revalidation design.

## Consumed-input and compile-time effect contract

The finite consumption model has two possible compiler-consumption events. Each
event records:

- whether the compiler consumed it;
- an actual identity of `absent`, `revision0`, or `revision1`;
- a sealed observation of `omitted`, `absent`, `revision0`, or `revision1`.

Absence is a real identity. A consumed miss represented as `omitted` is
incomplete; it must be represented as observed absence.

The publication rule is:

```text
consumed_trace_complete =
  every consumed event has its exact sealed identity

effect_authorized =
  sealed_trust_assertion
  or (salt_is_sealed and salt is nonblank)

publication_allowed =
  consumed_trace_complete
  and (effect is not untrusted or effect_authorized)
```

The buggy SAT control omits a consumed `revision1` event and performs an
untrusted effect with no trust assertion and an unsealed blank salt. With both
publication gates disabled it obtains:

```text
consumed_trace_complete       = false
effect_contract_satisfied     = false
selected_generation_exec      = true
consumed_input_violation      = true
untrusted_effect_violation    = true
violation                     = true
```

With both gates enabled, the same violation query is `UNSAT`. Its named core is:

```text
event_a_exact_observation_definition
event_b_exact_observation_definition
consumed_trace_completeness_definition
explicit_effect_authorization_definition
effect_contract_definition
corrected_consumed_trace_gate_enabled
corrected_effect_gate_enabled
publication_gate_definition
selected_generation_execution_definition
consumed_input_violation_definition
untrusted_effect_violation_definition
violation_definition
violation_query
```

The non-vacuity control seals one present `revision1`, one absence, an explicit
trust assertion, and `salt1` as a sealed nonblank salt. Publication and execution
remain reachable with `violation=false`. Trust or salt authorizes only the
modeled opaque effect. It never waives an omitted consumed input, an unknown or
moved provider, or incomplete registry/caller-context provenance.

The late-bound negative control excludes an ordinary runtime Var from the
compile-consumption trace. Its root changes from `runtime_rev0` to
`runtime_rev1` after selection, but the selected generation still executes with
`publication_miss=false`. This exclusion applies only when the root is not read
under macro expansion, data-reader execution, another compiler callback, or an
inline/direct-link path. A Var read during one of those phases is a compiler
input even when the Var itself is an ordinary nonmacro helper and was used
without `require`; it must seal provider generation plus pristine revision or
disable publication.

The resulting implementation obligation is a capture-local observation seam:
actual macro expansion, reader invocation, compile-relevant resolution/metadata,
global record/type-registry lookup, and capture-time top-level effects must
either emit an exact serializable observation or disable publication.
Uninstrumented time, random, network, subprocess, foreign, opaque mutable, and
similar effects are untrusted. A sealed salt or trust assertion is a deliberate
user claim, not a formal proof that the effect is deterministic.

Macro consumption must record retained provider/generation provenance even when
the macro is fully qualified and used without `require`. A missing current source
path does not make a source-backed macro install-owned: only immutable
initial-install or baked namespaces may use version-sealed trust on a path miss.
Unknown, removed, or moved user-macro provenance disables publication.

Global compiler registries are independent consumed inputs. A cold bare
`Widget` lookup that records absence cannot hit after an unrelated provider adds
`provider.Widget` to the record/type registry: the registry observation or
revision changed even if the consumer namespace and its cells are fresh.
Namespace freshness alone therefore cannot replace complete compiler-registry
observation.

Caller namespace is also a compiler input before the requested namespace has
been established. If any meaningful form precedes a matching
`(ns requested.name)`, the artifact must seal exact caller-namespace context.
The conservative eligibility rule instead requires the first meaningful form to
be that matching `ns`; otherwise publication is disabled. Without either rule, a
cold artifact captured from caller `A` can hit from caller `B` and replay its
pre-`ns` definition into `A`.

This obligation is a target contract, not a claim about current instrumentation.
`aot-observe!` is an extension seam proposed for consumption-side probes; no
production probes currently establish complete coverage. The models assume that
every compiler-consumed input and compile-time effect reaches that seam, so they
prove the publication and execution contract under complete instrumentation,
not that the present runtime has implemented or completed that instrumentation.

## Mutable compiler-environment taint

The compiler-environment family separates compile identity from ordinary runtime
state. Its finite identity includes:

- project cell root, defined, macro, and metadata state;
- project alias/refer state;
- roots consumed by macro/reader/compiler callbacks or inline/direct-link
  lowering;
- per-consumed-cell and per-consumed-mapping pristine/dirty state for baked
  namespaces, including an initially nonmacro classification;
- a consumed global record/type-registry revision.

An ordinary nonmacro root change remains late-bound only when no compile-phase or
inline/direct-link path read that root. Project compile-identity changes
invalidate the project generation. Baked namespaces are not globally trusted:
each consumed baked cell or mapping must remain pristine.

The shaped buggy witness combines three live failures:

```text
baked cell macro state at seal      = nonmacro_state
baked cell macro state at guard     = macro_state
project alias at seal               = target_p1
project alias at guard              = target_p2
consumed registry at seal           = registry_rev0
consumed registry at guard          = registry_rev1
project generation invalidated      = true
baked consumed cell dirty           = true
consumed global registry dirty      = true
global permanent compile taint      = false
candidate accepted                  = true
violation                           = true
```

The corrected model divides unsafe changes into two windows. Changes observed
by mutation hooks set a permanent compile taint that blocks later hits and
publication. A change after capture but before publication is caught by one
final live in-memory identity recheck. The violation query is `UNSAT` with this
named core:

```text
corrected_permanent_taint_tracking_enabled
corrected_final_publication_recheck_enabled
permanent_taint_window_definition
final_publication_window_definition
global_permanent_taint_definition
strategy_base_gate_definition
final_decision_recheck_definition
candidate_acceptance_definition
violation_definition
violation_query
```

A global permanent bit is therefore sufficient by itself only if complete,
synchronous instrumentation is assumed to catch every unsafe change before the
decision. The selective-runtime bounded contract does not silently assume that stronger
property: it also requires the final publication recheck. A global bit set for
*every* Var-root mutation would be sound but wrong for the late-bound negative
control and unnecessarily disable the process; it must track only the refined
compile-relevant set above.

The conservative alternative is to construct each root/route namespace with no
preexisting registry entries, cells, aliases, or refers, then permit only
precisely scoped loader-controlled construction. This removes same-namespace
residue but does not replace global registry observation. The non-vacuity model
uses that fresh-namespace strategy, an ordinary late-bound root change, and one
precisely scoped loader metadata update; final publication remains reachable.

Classification is an explicit assumption. “Loader-controlled” must be
non-user-spoofable, dynamically scoped to the exact internal operation, and
guaranteed to install state consistent with the selected/captured generation.
If runtime hooks cannot distinguish that from arbitrary user mutation, selective
taint is unsound. The only safe fallback is to classify every such operation as
unsafe, permanently disable AOT in that process, or isolate compilation in a
fresh process.

## Direct/nested loading and sealed-route completeness

The direct-load family combines two related exactly-once and route-completeness
failures. Its finite inputs are:

- capture with or without an observed direct `load`/`load-file`;
- no selected nested operation, project `require`, or direct `load`/`load-file`;
- nested edge absent from or present in the sealed route;
- project ownership or immutable install/baked ownership.

The shaped buggy witness records both an outer direct load and its nested forms,
publishes anyway, and then independently follows the missing project edge:

```text
capture shape                    = capture_with_direct_load
selected nested operation        = direct_load_or_file
sealed route membership          = route_edge_absent
provider ownership               = project_owned
candidate publishes              = true
selected generation executes     = true
nested side-effect count         = 2
duplicate side effect            = true
unsealed route escape            = true
violation                        = true
```

The corrected policy disables publication whenever capture observed a direct
load. Independently, a project-owned `require`, `load`, or `load-file` encountered
by selected code passes only if its edge is in the sealed route. This second gate
covers a warm-only conditional operation not reached during capture. It compares
against immutable route membership, not current source, so it adds no
immediate-before-execution reread.

The corrected violation query is `UNSAT` with this named core:

```text
outer_load_recording_definition
nested_form_recording_definition
corrected_capture_publication_gate_enabled
corrected_route_completeness_gate_enabled
candidate_publication_definition
route_preflight_definition
selected_generation_execution_definition
project_execution_definition
outer_replay_effect_definition
nested_replay_effect_definition
nested_side_effect_count_definition
duplicate_effect_definition
unsealed_route_escape_definition
violation_definition
violation_query
```

The non-vacuity control captures no direct load, selects no nested operation,
publishes, and executes with side-effect count `0` and `violation=false`.
Install/baked ownership is a version-sealed exception to route membership, not a
generic fallback for missing project source. If a program needs a conditional
project edge to resolve independently, it must use the ordinary loader through
an explicit AOT opt-out.

## Shared loaded-libs update

The loaded-libs family represents two unrelated namespaces, `A` and `B`, both
initially absent. Under the rejected read/modify/write behavior, both markers
read that initial set. With `A` writing before `B`, `B`'s stale write becomes the
final set:

```text
write order             = mark_a_then_b
final contains A        = false
final contains B        = true
lost loaded-libs mark   = true
violation               = true
```

The corrected abstraction makes the final set the union of the initial set and
both requests. Runtime may implement that as a true atomic update or one shared
mutex covering the complete read/union/write operation. A per-namespace mutex is
not sufficient because both updates mutate the same global set.

The lost-update query is `UNSAT` with this named core:

```text
mark_a_request_definition
mark_b_request_definition
corrected_shared_update_enabled
final_a_definition
final_b_definition
lost_mark_definition
violation_definition
violation_query
```

The non-vacuity control starts with both entries absent and reaches
`final_has_a=true`, `final_has_b=true`, and `violation=false`.

## Selected nested reload

The selected-reload family starts with one selected cached generation and one
provider sealed at `provider_rev0`. Under the buggy policy a nested reload is
permitted inside that selective transaction:

```text
reload intent                            = nested_reload_requested
reload rejected before mutation          = false
provider mutated                         = true
selected execution continues             = true
retry started                            = false
violation                                = true
```

The selective-runtime policy rejects the request before the first provider or namespace
mutation, stops the selected transaction, and keeps post-user retry disabled.
It does not reread source or attempt to choose a newer generation inside the
in-flight route. The violation query is `UNSAT` with this named core:

```text
corrected_fail_before_mutation_enabled
corrected_post_user_retry_disabled
reload_rejection_definition
provider_revision_after_request_definition
provider_mutation_definition
selected_execution_definition
retry_definition
selected_reload_violation_definition
violation_definition
violation_query
```

The non-vacuity control requests no nested reload and still reaches selected
execution with no provider mutation, retry, or violation.

## Same-namespace reload residue

The residue family distinguishes new source intent from the actual cell retained
in one mutable namespace. The buggy witness begins with an old macro, reloads
source that omits it, and keeps the old cells:

```text
reload event                = same_namespace_reload
old cell                    = cell_macro
intended new cell           = cell_absent
cell handling               = retain_old_cells
actual cell after reload    = cell_macro
generation tainted          = false
cache execution allowed     = true
stale macro residue         = true
violation                   = true
```

The corrected policy has two safe branches: reconstruct the namespace cells so
actual state exactly matches new source, or taint any retained-cell
same-namespace reload and prevent cached execution. The stale-residue query is
`UNSAT` with this named core:

```text
actual_cell_after_reload_definition
unreconstructed_reload_definition
corrected_reload_taint_enabled
generation_taint_definition
cache_execution_gate_definition
stale_cell_residue_definition
violation_definition
violation_query
```

The non-vacuity control reconstructs an old macro cell as a new nonmacro cell,
remains untainted, and executes with no stale residue. Fresh namespace
construction is the conservative implementation of this branch; incremental
cell cleanup is safe only if it can prove equivalence to reconstruction.

## Transaction and retry evidence

The transaction model has four mutually exclusive first-attempt outcomes:

```text
integrity_failure
selection_failure
user_top_level_failure
success
```

They encode ordered phase reachability:

- an integrity failure stops before selection;
- a selection failure stops before user forms;
- a user top-level failure occurs only after the user-form phase begins;
- at most one second attempt exists.

The queried violation is defined from observable counts:

```text
duplicate_after_user_failure =
  user_top_level_failed
  and (compile_attempt_count > 1
       or user_form_phase_entry_count > 1)
```

The rejected-policy SAT witness has a first user top-level failure, starts a
retry, reaches user forms again, and reports both counts as `2`.

With pre-user retry enabled and post-user retry disabled, the same violation
query is `UNSAT`. Its named core is:

```text
corrected_user_failure_retry_disabled
first_integrity_phase_definition
first_selection_reachability_definition
first_selection_phase_definition
first_user_form_reachability_definition
pre_user_failure_definition
user_failure_definition
retry_policy_definition
second_user_form_reachability_definition
compile_attempt_count_definition
user_form_entry_count_definition
duplicate_after_user_failure_definition
violation_definition
violation_query
```

Two separate non-vacuity controls avoid turning the result into a no-retry
policy:

- integrity failure: selection and user forms are not reached on attempt one;
  attempt two reaches user forms, with two compile/load attempts and one
  user-form phase entry;
- selection failure: integrity succeeds, user forms are not reached on attempt
  one, and the same `2` attempts / `1` user-form entry boundary is reachable.

## Design boundary and current recommendation

The live counterexamples now cross independent mutable subsystems: provider
tokens, macro/helper Vars, namespace mappings, same-namespace cell residue,
global type registries, direct/nested loading, loaded-libs bookkeeping, and
caller context before `ns`. A fresh namespace alone closes only some of them; a
source hash or namespace generation alone closes fewer.

The counterexamples make independently reusable namespace artifacts the wrong
production default. Closing every hole while preserving selective in-process
reuse requires all of these gates:

- complete consumption-side observation, including negative lookups and global
  registries;
- exact retained provider/generation identity for compile-phase Var reads;
- non-spoofable loader-controlled mutation classification;
- final publication identity recheck and final in-memory route-token
  guard/commit;
- reconstructed or tainted same-namespace reloads;
- first meaningful form is matching `ns`, or exact caller context is sealed.

The production recommendation is instead to build one closed-world
whole-project image in a fresh process and select it atomically under one build
token. There is no namespace-by-namespace cache lookup on that path. A load
either receives the complete immutable image described by the selected graph
and compiler-input witness, or misses/fails before user forms. A newly reached
compile-time input outside the declared graph also fails closed rather than
silently extending the snapshot.

That pivot removes mutable per-namespace generation routing from the production
trusted computing base, but it does not remove the hard discovery problem.
Production enablement still requires runtime tests showing that graph and
compiler-input collection are complete, image publication is immutable,
selection is atomic, and the compiler process is actually fresh. Until those
conditions are demonstrated, whole-image reuse should remain opt-in and the safe
fallback is ordinary non-AOT loading.

The selective generation machinery should remain a separate research path, not
an incremental prerequisite for the whole-image implementation. Its bounded
`UNSAT` results specify what selective reuse would need; they are not evidence
that the current in-process cache is ready for default use.

## Historical analyses of rejected designs

The following models remain checked in because their counterexamples motivated
the redesign. Filenames containing `corrected` mean corrected relative to that
historical design, not the selective-runtime generation contract.

### Source/provider live-validation family

| Model | Result | Historical question |
| --- | --- | --- |
| [`aot-provenance-v3-buggy.smt2`](../test/chez/formal/aot-provenance-v3-buggy.smt2) | `SAT` | Can a current-disk observation replace the exact already-loaded source that influenced compilation? |
| [`aot-provenance-source-witness.smt2`](../test/chez/formal/aot-provenance-source-witness.smt2) | `SAT` | Can an edit without reload produce a source-only witness when producer contexts are equal? |
| [`aot-provenance-source-corrected.smt2`](../test/chez/formal/aot-provenance-source-corrected.smt2) | `UNSAT` | Does retaining loaded source provenance close that bounded source-only query? |
| [`aot-provenance-v4-corrected.smt2`](../test/chez/formal/aot-provenance-v4-corrected.smt2) | `UNSAT` | Does exact source plus producer-context validation close the bounded v3 query? |
| [`aot-provenance-nonvacuity.smt2`](../test/chez/formal/aot-provenance-nonvacuity.smt2) | `SAT` | Does that historical corrected model still admit a coherent warm hit? |

The main v3 witness used an already-loaded macro at `s0` while current disk and
the manifest said `s1`; its artifact semantics were `23` while current semantics
were `31`. The source-isolating witness constrained producer contexts equal and
still obtained the mismatch.

The historical `v4-corrected` `UNSAT` result never proved a
validation-to-execution guarantee. Its six-stage abstraction collapses manifest
validation and warm execution into one final stage. Treating it as proof against
post-selection filesystem/provider changes was misleading. Under the
selective-runtime contract, those later live changes are outside the sealed
transaction anyway.

### Live-state temporal revalidation family

| Model | Result | Historical question |
| --- | --- | --- |
| [`aot-state-toctou-capture-buggy.smt2`](../test/chez/formal/aot-state-toctou-capture-buggy.smt2) | `SAT` | Can compiler/reader identity change between forms and still publish without per-form revalidation? |
| [`aot-state-toctou-warm-buggy.smt2`](../test/chez/formal/aot-state-toctou-warm-buggy.smt2) | `SAT` | Can context/reader identity change after validation and execute without a first-form live-state guard? |
| [`aot-state-toctou-corrected.smt2`](../test/chez/formal/aot-state-toctou-corrected.smt2) | `UNSAT` | Do both live-revalidation gates close those two bounded queries? |
| [`aot-state-toctou-nonvacuity.smt2`](../test/chez/formal/aot-state-toctou-nonvacuity.smt2) | `SAT` | Does the rejected live-revalidation design still admit one coherent capture and warm execution? |

These models explain the complexity cost of making execution depend on mutable
live state. They intentionally omit own-source/provider changes between
selection and execution, and they are not being extended: provenance-sealed
generations remove that live-equality requirement instead.

The existing runtime cases for loaded-source, provider-context, reader-state,
inter-form mutation, and validation/load races remain useful regression evidence
for the failure modes. Generation-specific source mapping should use stable
symbol names after implementation settles; this note intentionally avoids
loader line ranges while that work is active.

## Bounds and assumptions

### Whole-image production family

The whole-image model has two build tokens, two aggregate project-graph
witnesses, two aggregate compiler-input witnesses, two immutable image-byte
identities, two namespaces with two revisions each, and one bounded dynamic
compile input classified as absent, declared, or undeclared. It models one
fresh-process fact, one atomic image-selection decision, one preflight, and one
user-form execution decision.

Namespaces A and B stand for the complete project image. The graph and input
witnesses are opaque aggregates: the model assumes that each token maps to one
complete, exact graph/input/image tuple and that publication preserves that
mapping. It does not enumerate a real dependency graph, discover compiler
inputs, prove that dynamic code loading is classified exhaustively, construct
the fresh process, or prove filesystem atomicity. Atomic whole-image selection
is a modeled contract, not a derived implementation fact.

### Generation-routing family

The selective routing model has:

- two consumer generations, two provider generations, and two helper
  generations;
- one explicit two-edge dependency chain, consumer to provider to helper;
- two compile-witness identities and two publication tokens;
- two publishers completing at one abstract step and one later selection step;
- at most one already-loaded provider and one already-loaded helper;
- one user-form execution decision.

The helper token stands for the recursively sealed remainder of a transitive
dependency graph. Larger graphs, fan-out, duplicate edges, and cycles are not
enumerated. Loaded-provider preflight is assumed to inspect every required
generation in that sealed closure.

### Selection-eligibility family

The selection model has one direct provider, one transitive helper, and three
aggregate witness values: absence, revision 0, and revision 1. Each aggregate
stands for exact source, compiler context, and consumed observations. It models
one root-candidate lookup and intentionally stops there; no filesystem or source
observation after that lookup exists.

Longer provider graphs are represented only by the helper boundary. The model
assumes recursive traversal visits every sealed provider and that computing the
current aggregate witness is itself exact.

### Artifact-guard family

The artifact-guard model has two in-memory route tokens, two generation values,
three mutation times, and three mutation targets. Root lookup, one intervening
hook, one atomic guard/commit, and the first user form are the only ordered
stages.

The direct and helper tokens stand for every member of the sealed closure. The
model assumes the runtime can enumerate that closure and make token comparison
indivisible from commit. It omits filesystem/source observations, more than one
hook, mutation during the atomic guard, and machine-level memory ordering.

### Consumed-input/effect family

The consumption model has exactly two possible input-consumption events, three
actual identities, four observation states, one compile-time effect, two
explicit nonblank salts, and one trust assertion.

It proves the publication rule only for those represented events. It does not
prove that runtime instrumentation sees every real compiler input, classifies
every effect correctly, produces collision-free revisions, or serializes opaque
values soundly. Repeated observation, larger traces, form ordinals, registry
fan-out, and multiple effects are omitted.

The late-bound control has one additional two-value runtime revision. That
revision is intentionally absent from publication logic because the modeled Var
was not consumed during compilation. A dynamic deref under a macro, data reader,
compiler callback, inline, or direct-link path is outside that negative control.

### Compiler-environment family

The compiler-environment model has two values for root, defined, macro, metadata,
and global-registry revision; three alias/refer targets; project versus baked
origins; consumed versus unconsumed observations; three root-use modes; two
decision windows; two safety strategies; and one hit or publication decision.

It represents one project generation, one baked cell, one mapping, and one
global registry lookup. Project invalidation, per-consumed baked dirtiness, and
the final live observation are assumed exact. Larger registries, multiple cells,
interleaved controlled/untrusted operations, taint reset, and concurrent final
rechecks are omitted.

The fresh-namespace strategy is an abstract assertion that no namespace
registry, cells, aliases, or refers predate loader construction. It does not
freshen the process-global record/type registry. The precise loader-controlled
classification is not derived from runtime authority in the model.

### Direct/nested-loading family

The direct-load model has two capture shapes, three selected nested operations,
two route-membership values, and two provider-ownership classes. It counts
exactly two possible replay paths for one nested side effect, so the count is
bounded from `0` through `2`.

The project `require` and direct-load constructors stand for any warm-only
conditional project edge. The model does not enumerate nested graphs, repeated
operations, exception handling, or mixed install/project ownership. It assumes
install/baked ownership is immutable and correctly classified by the runtime.

### Loaded-libs read/modify/write family

The loaded-libs model has exactly two unrelated mark requests, two initial
membership bits, and two possible stale-write orders. The shared-mutex/atomic
branch is abstracted as the set union of the initial memberships and both
requests. It does not model three or more concurrent markers, memory-ordering
details, lock failure, or other mutations of the loaded-libs registry.

### Selected nested-reload family

The reload model has one selected generation, one provider, two provider
revisions, and one reload request or no request. It permits no retry in the
corrected post-user phase and does not model a caught rejection, multiple nested
reloads, or a subsequent top-level load transaction. The absence of a
post-selection source observation is intentional.

### Same-namespace residue family

The residue model has one namespace, one cell, three possible old/new/actual cell
states, one reload or no reload, and two handling strategies. Retention taint is
one Boolean policy. It omits multiple Vars, metadata-only residue, aliases,
refers, records/types, incremental cleanup order, and user code observing the
namespace during reconstruction.

### Transaction family

The retry model has one first attempt and at most one retry. The second attempt
is assumed coherent and reaches user forms; this makes duplicate execution
observable but does not model another failure or a third attempt.
`user_form_phase_entry_count` counts entries into the user-code phase, not every
individual form or side effect.

### Contract assumptions and omissions

All production and research families assume, where applicable:

- **complete project-graph resolution**: the whole-image gate receives one
  declared graph containing every project namespace and compile-time edge; the
  finite model does not prove that the real resolver discovers them all;
- **complete compiler-input observation**: the corrected finite model requires
  exact seals for its enumerated events, including negative registry and caller
  context lookups, but real observer-hook coverage remains an implementation
  assumption;
- **sequential sealed observations**: capture observations occur in order and
  are sealed with the bytes they produced; they are not claimed to be an atomic
  filesystem snapshot;
- **immutable private cache**: generation records and token-addressed bytes
  or whole-project images cannot change after publication, and tokens do not
  collide;
- **fresh-process isolation is real**: the whole-image `fresh_compiler_process`
  fact means no project namespace cells or compiler state survive from an
  earlier build; the model accepts this fact rather than constructing the
  process boundary;
- **whole-image selection is atomic**: one selected token commits the complete
  graph/input/image tuple before user forms; partial image visibility and
  namespace-level fallback are excluded by contract;
- **dynamic compile-input classification is exhaustive**: an input absent from
  the declared closed world is classified as undeclared and rejected; the model
  does not prove that production hooks observe every such input;
- **trusted cache participants**: hostile writers, forged records, malicious
  token substitution, and compromised filesystem ownership are excluded;
- **ordinary late-bound Var mutation is outside provenance**: only a nonmacro
  root not consumed by macro/reader/compiler callbacks or inline/direct-link
  lowering remains late-bound; compile-phase consumption seals identity;
- **controlled-operation classification is trusted**: the loader-only marker is
  non-user-spoofable, precisely scoped, and installs generation-consistent
  state; otherwise all such mutation must taint;
- **final guards are atomic at their boundary**: publication rechecks live
  in-memory compiler identity after capture, while artifact execution rechecks
  all route tokens and commits selection before the first user form;
- **post-selection live changes are deferred**: filesystem, compiler, reader,
  and target changes after artifact guard/commit affect later
  load/reload/process transactions;
- **nested load/reload is fail-closed**: nested reload fails before mutation
  inside a selected cached generation, while capture-time reload, `load`, and
  `load-file` make the candidate unpublishable until sealed-provider routing or
  proven capture suppression makes them safe;
- **selected project routes are complete**: a warm-only project `require`,
  `load`, or `load-file` absent from the sealed route fails before project forms
  or mutation; only correctly classified immutable install/baked providers are
  exempt;
- **caller context is explicit**: the first meaningful form matches the requested
  namespace, or exact pre-`ns` caller context is sealed and checked;
- **loaded-libs updates are shared and atomic**: every producer uses the same
  atomic update or a single mutex covering the full read/union/write operation;
- **garbage collection is deferred**: reclaiming unreachable generations,
  liveness tracking, crash recovery, and cache-size policy are not modeled.

The models also omit hash collision or cryptographic breakage, partial writes and
durability, namespace graph cycles, process crashes, behavior after a user form
throws, and the internal correctness of compiler emission from a recorded
witness.

## Exact Chiasmus workflow

For the whole-image production boundary:

1. `chiasmus_skills` searched for a bounded closed-world build, atomic
   whole-image selection, mixed namespace snapshots, undeclared dynamic compile
   inputs, fail-closed evaluation, and non-vacuity.
2. `chiasmus_formalize` selected `fail-closed-evaluator`; the skeleton was
   adapted to one aggregate build token/graph/input/image witness, independent
   namespace selection as the rejected control, fresh-process and dynamic-input
   gates, and user execution.
3. All three exact inputs passed `chiasmus_lint` with zero fixes and zero
   errors. `chiasmus_verify` returned buggy `SAT` with 72 model entries,
   corrected `UNSAT` with an 18-label core, and non-vacuity `SAT` with 72 model
   entries.

For generation routing:

1. `chiasmus_skills` searched for a bounded AOT post-selection/full-manifest
   fail-closed query, then the selective direction was reformulated around sealed
   generation and dependency-token routing.
2. `chiasmus_formalize` selected `fail-closed-evaluator`; the skeleton was
   adapted into explicit direct/transitive routing, token/byte, loaded-conflict,
   and user-execution predicates.
3. Each of the three exact routing inputs passed `chiasmus_lint` with no fixes or
   errors and then `chiasmus_verify`: `SAT`, `UNSAT`, `SAT`.

For recursive selection eligibility:

1. `chiasmus_skills` searched for sealed-provider currentness at root selection
   without a post-selection reread.
2. `chiasmus_formalize` supplied the fail-closed skeleton, adapted to direct and
   transitive aggregate eligibility witnesses.
3. The three exact inputs passed `chiasmus_lint` with no fixes/errors and
   `chiasmus_verify`: buggy `SAT`, corrected `UNSAT`, non-vacuity `SAT`.

For artifact guard/selection commit:

1. `chiasmus_skills` searched for post-candidate state transitions and
   fail-closed mutation guards.
2. `chiasmus_formalize` preferred an unsuitable Prolog dependency template even
   when asked for Z3, so the returned Z3 state/fail-closed patterns from
   `chiasmus_skills` were adapted directly to two route tokens and three mutation
   times.
3. The three exact inputs passed `chiasmus_lint` with no fixes/errors and
   `chiasmus_verify`: buggy `SAT`, corrected `UNSAT`, non-vacuity `SAT`.

For consumed inputs and effects:

1. `chiasmus_skills` searched for omitted present/absent revisions and
   untrusted-effect publication.
2. `chiasmus_formalize` supplied the fail-closed skeleton, adapted to a two-event
   consumption trace, exact sealed observations, and explicit trust/salt
   authorization.
3. The four exact inputs passed `chiasmus_lint` with no fixes/errors and
   `chiasmus_verify`: buggy `SAT`, corrected `UNSAT`, trusted/salted
   non-vacuity `SAT`, and late-bound runtime control `SAT`.

For mutable compiler environment:

1. The same Z3 fail-closed pattern was adapted to refined root-use identity,
   project invalidation, per-consumed baked dirtiness, namespace freshness,
   global-registry revision, permanent taint, and final publication recheck.
2. The three exact inputs passed `chiasmus_lint` with no fixes/errors and
   `chiasmus_verify`: buggy `SAT`, corrected `UNSAT`, non-vacuity `SAT`.

For direct/nested loading:

1. `chiasmus_skills` searched for bounded state transitions, fail-closed gates,
   exactly-once replay, and lost-update shapes.
2. `chiasmus_formalize` supplied the fail-closed skeleton, adapted to capture
   shape, selected operation, sealed-route membership, provider ownership, and
   two possible nested-effect replay paths.
3. The three exact inputs passed `chiasmus_lint` with no fixes/errors and
   `chiasmus_verify`: buggy `SAT`, corrected `UNSAT`, non-vacuity `SAT`.

For loaded-libs read/modify/write:

1. The same template search and formalization were adapted to two stale
   snapshots, two write orders, and a shared mutex/atomic-union gate.
2. The three exact inputs passed `chiasmus_lint` with no fixes/errors and
   `chiasmus_verify`: buggy `SAT`, corrected `UNSAT`, non-vacuity `SAT`.

For selected nested reload:

1. The same template search and formalization were adapted to a reload request,
   provider revision transition, fail-before-mutation gate, continued execution,
   and post-user retry.
2. The three exact inputs passed `chiasmus_lint` with no fixes/errors and
   `chiasmus_verify`: buggy `SAT`, corrected `UNSAT`, non-vacuity `SAT`.

For same-namespace reload residue:

1. The Z3 state/fail-closed pattern was adapted to old, intended, and actual
   cell state plus reconstruct-or-taint handling.
2. The three exact inputs passed `chiasmus_lint` with no fixes/errors and
   `chiasmus_verify`: buggy `SAT`, corrected `UNSAT`, non-vacuity `SAT`.

For transaction phases:

1. `chiasmus_skills` searched for bounded pre-user retry and post-user duplicate
   execution.
2. `chiasmus_formalize` again selected `fail-closed-evaluator`; the outcome
   datatype and ordered phase reachability replaced generic evaluator inputs.
3. Each of the four exact transaction inputs passed `chiasmus_lint` with no
   fixes or errors and then `chiasmus_verify`: buggy `SAT`, corrected `UNSAT`,
   integrity-retry `SAT`, and selection-retry `SAT`.

The nine historical inputs were also re-linted and re-verified after being
relabeled as rejected-design evidence. All had zero lint fixes/errors and
retained their recorded results: six `SAT` and three `UNSAT`.

The checked-in suite now contains 44 exact SMT inputs: 30 observed `SAT` and 14
observed `UNSAT`.

All semantic result flags are equality-defined. The `SAT` files expose concrete
witness values, the `UNSAT` files record named cores, and the non-vacuity files
use the same schemas without asserting a violation.
