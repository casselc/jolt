# Application Core Semantic Charter (Clojure.next core; first realization: Jolt)

**Status:** DRAFT — section-by-section review in progress. Sections marked
"DRAFT PENDING" are not yet accepted.
**Scope:** a **Clojure.next Application Core** — implementation-neutral,
portable semantics with named realization targets. The semantics in this
charter are written to be implementable in Jolt-on-Chez, jank, JVM/CLR hosts,
or native Clojure implementations (Go/Zig/Rust/…). **Jolt-on-Chez at upstream
v0.5.17 is the first/reference realization** and the source of all executable
evidence in this lane; it is not the owner of the semantics. Host behavior
appears only as cited *realization notes*, never as the definition of core
semantics, and no host's accidents are canonized.
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

Values (portable semantics; realizations cited as notes; details in §2):

- `nil`, booleans.
- **Exact integers:** unbounded exact semantics — arithmetic is always exact
  (bignum semantics); implementations may use a small-integer fast path
  *(realization: Jolt-on-Chez uses Chez 61-bit fixnums with exact bignum
  promotion, `V17` P10 #2)*. Fixed-width interop casts are explicit checked
  operations whose width set is `target-dependent`; they are not part of core
  arithmetic.
- **Exact ratios** (non-integer rationals); **IEEE-754 binary64 doubles**
  (no single-float in the core).
- **Strings:** immutable sequences of **Unicode scalar values**. `count` and
  indexing are by scalar value; a scalar value cannot be split by `subs`.
  *(Realization: JVM hosts index UTF-16 code units and CAN split surrogate
  pairs — a platform accident, `target-dependent`, not core semantics.
  Jolt-on-Chez indexes scalar values directly, `V17` P10 #2.)*
- **Symbols** (namespace/name, not interned, may carry metadata); **keywords**
  (namespace/name, interned — identity-stable).
- **Collections:** persistent lists, vectors, maps, sets. Equality and
  hashing are order-independent for maps/sets. **Iteration order of
  hash-based maps/sets is unspecified** (realization-dependent; only sorted
  collections guarantee order). *(Realizations: Jolt-on-Chez vectors are
  32-way tries with tails; maps use insertion-ordered small maps promoting to
  HAMT past thresholds; sets are hash-ordered HAMTs — `V17` P10 #2. JVM
  realizations differ in kind, not in this portable contract.)*
- **Equality, hashing, comparison:** as **test authority**, the conformance
  register governs test expectations where it conflicts with README prose
  (C3). The formal v1 fragment makes **no numeric-`=` claim** (D6/C3);
  hash-consistency and compare laws are §6/§8 `sampled` obligations. The
  canonical string/collection hash algorithm is defined by this charter so
  all realizations agree *(JVM-compatible hashing is a `target-dependent`
  interop concern — open question I1)*.
- **Metadata:** supported on symbols and collection values and Vars; the
  exhaustive eligibility matrix is `specified-profile`, not formal-core v1.

**Sequence processing model (H4):** the core is **eager/transducer-first at
the bottom**. Default sequence operations are eager and strict; transducers
are the composable, collection-agnostic transformation primitive; eager
drivers (`into`/`transduce`-style) are the canonical consumers. **Laziness
is opt-in** via explicit lazy stream/generator constructors with defined
realization, exception, cancellation, and resource semantics (§2). *(JVM
pervasive/chunked laziness is a host behavior; chunk size is a realization
detail, not core semantics.)*

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

1. **No host-accident canonization.** The core does not preserve any host's
   implementation accidents — JVM UTF-16 surrogate splitting, JVM primitive
   overflow behavior, Chez-specific integer widths, or category-blind
   `1`=`1N` (conformance test authority only, C3 — not formal semantics).
   Portable semantics first; realizations are cited, never canonized.
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

Each row also carries a **support level** (`Full` / `Partial` / `Limited` /
`Excluded`) with a Notes column naming the exact unsupported variants (the
Hydro feature-support-matrix honesty pattern, P11 A.5): coverage granularity
is pre-committed per feature, and any "same code" claim is immediately
qualified by its named exceptions.

### 1.5 Coverage staging (what comes after this charter's core)

This charter specifies the semantic foundation. The two surfaces asked about
most are staged as follows (exit criteria in §9):

- **The core library (clojure.core-equivalent: seq/reduce/map/filter/concat,
  transducers, predicates):** mostly pure functions over immutable values —
  the cheapest formalization target after the fragment evaluator exists.
  Stage: with the reference evaluator and schema prototype (§9 stages 2–3), a
  selected pure kernel of core functions gets equational semantics and
  becomes the first `verified-kernel` candidate (§9 stage 4). The processing
  model is eager/transducer-first (§1.2); **lazy streams are opt-in** with
  defined realization, exception, cancellation, and resource semantics,
  specified separately from the eager core.
- **Coordination and async (atoms, promises/delays/futures, agents,
  channels/core.async-equivalent, timers, Flow):** stage after the
  coordination-kernels stage (§9), and gated on the v0.5.17 runtime lane
  delivering lifecycle observation/control seams (non-goal 13: requested,
  never assumed). The §7 mailbox proof target is the seed of this work —
  capacity/blocked/close/drain semantics on the cooperative model before any
  runtime channel semantics is claimed.
- **Effect handlers and simulation worlds:** the H3 derivation hierarchy and
  tier model land with the runtime lane's controller; this charter specifies
  the contracts, not the ABI.

---

## 2. Deterministic evaluation order and observable semantics (first pure fragment)

**Scope:** the v1 formal-core profile of §1.2: pure data, functions, lexical
binding, ordinary invocation, and the enumerated error subset. Every rule is
portable (Clojure.next); realization notes cite the Jolt-on-Chez reference
(`V17/…` per P10) or name a JVM contrast explicitly. Anything not fixed by a
rule here is UNSPECIFIED and out of fragment, not implicitly host behavior.

### 2.1 Reader and literals

- **Literal set (fixed):** `nil`, `true`/`false`, integers (decimal and
  documented radix forms), exact ratios (`1/2`), doubles, arbitrary-precision
  decimals (`M` suffix), strings (with escape forms), characters, symbols,
  keywords, lists, vectors, maps, sets; quote (`'`), deref (`@`),
  unquote/splicing inside syntax quote, anonymous function literal `#()`,
  discard `#_`, comments, reader conditionals `#?`. *(Jolt documents the same
  surface at both baselines; no reader-semantics changelog entries in
  0.5.14–0.5.17 — `V17/CHANGELOG.md:10-322`; v0.5.13 list at
  `README.md:310-321`.)*
- **No `#=` / read-eval anywhere in any lane** (D8: opaque, excluded).
- **Tagged literals:** an unknown tag reads as an inert tagged-literal data
  value (tag + form); a strict data reader applies registered readers,
  built-ins, then a default handler, and throws otherwise. *(Realization:
  Jolt core `read-string` inert vs `clojure.edn` strict, per P1;
  `stdlib/clojure/edn.clj:28-46` [v0513].)*
- **Reader conditionals** select by feature set. *(Realization: Jolt chooses
  the matching branch by default rather than requiring `:allow` — P1;
  portable feature-set definition is `specified-profile`.)*
- **Syntax quote** is macro-authoring machinery: `specified-profile`, outside
  the v1 formal fragment's semantics (it is supported by the reader and
  lowered to construction code — P1; not formalized in v1).
- **Map literals with duplicate keys and set literals with duplicate members
  are read errors.** *(Jolt realization: UNSPECIFIED — the reader
  implementation was outside P1/P10's fences; §6 corpus must pin it.)*
- **Literal lowering:** literals lower to abstract constructors; the concrete
  representation (persistent/packed/embedded) is a realization choice that
  must not change source-level value semantics. *(No selectable
  representation-profile mechanism exists in Jolt today — P1 divergence
  register; semantics here are representation-agnostic by construction.)*

### 2.2 Evaluation order

- **Ordinary invocation is observably left-to-right:** the callee is
  evaluated first, then arguments in source order. "Observably" means a
  realization may reorder only when no observable difference exists;
  side-effecting operands and order-sensitive Var reads must preserve source
  order. *(Realization proof: the Jolt analyzer preserves operand order —
  `V17/jolt-core/jolt/analyzer.clj:1030-1037`; the backend forces sequential
  `let*` temporaries exactly when reordering could be observable
  (`needs-order?`/`ordered-call`) — `V17/jolt-core/jolt/backend_scheme.clj:
  429-473, 878-899, 1029-1086`. Chez's own application order is unspecified;
  the compiler enforces observable order regardless —
  `V17/jolt-core/jolt/backend_scheme.clj:429-432`.)*
- **Collection literal evaluation:** elements evaluate in source order; map
  keys and values evaluate in pair order; a computed collection being invoked
  is evaluated before its key/default operands.
  *(Realization: `V17/jolt-core/jolt/backend_scheme.clj:1051-1060`.)*
- **Special forms:** `if` evaluates its test once, then exactly one branch
  (absent else yields `nil`). `do` evaluates forms in order; result is the
  last form (`nil` for empty `do`). `let*` initializers evaluate in order,
  each before its binding is visible. `loop*` initializers evaluate in order
  outside the recursive frame; `recur` evaluates its arguments in order
  (same ordered mechanism as invocation) and re-enters the nearest enclosing
  `loop*`/`fn*` frame. `fn*` bodies share these rules per arity.
- **`fn*` arity selection:** fixed arities dispatch on exact argument count;
  a variadic arity accepts any count at or above its fixed prefix; no
  matching arity is an `:arity` error (§2.4). A named `fn` self-reference and
  mutual recursion use `letrec` semantics. *(Realization:
  `V17/jolt-core/jolt/analyzer.clj` fn/arity handling — P1 §1; mechanism
  unchanged per P10 (a).)*
- **`def`:** interns the Var in the current namespace, then evaluates its
  initializer (and metadata expression, if present), and returns the Var —
  not the root value. A declaration without initializer establishes no root.
  *(Realization: P1 §1, `analyzer.clj` + `backend_scheme.clj` [v0513];
  mechanism unchanged per P10 (a).)*
- **Var reference:** reads consult the innermost dynamic binding first, then
  the root. `(var x)` / `#'x` yields the Var cell itself. Only Vars declared
  `:dynamic` may be dynamically bound; bindings are per-thread stacks.
  *(Realization: `V17/host/chez/dyn-binding.ss:4-22` — P10 #9; read-order
  detail per P1 §5 [v0513].)*
- **`set!`:** updates only the innermost existing thread binding; throws if
  none exists; never establishes or mutates a root binding. *(Realization:
  P1 §1, `dyn-binding.ss` [v0513]; P10 #9 mechanism confirmed.)*
- **Host interop is excluded from the order guarantee:** `host-new` and
  `host-call` operand evaluation order is `opaque` (§1.2). Qualified
  static-method invocation is an ordinary ordered invocation specialization.
  *(Realization: `V17/jolt-core/jolt/backend_scheme.clj:1271-1273,
  1313-1322` unordered bare application; `:1064-1068` ordered static
  specialization.)*
- **Determinism statement:** within the fragment, observable evaluation order
  is fully determined by these rules; no unspecified order remains. This is
  what makes the §6 differential relation well-defined.

### 2.3 Values, equality, hashing, comparison

- **Values:** per §1.2 — `nil`, booleans, unbounded exact integers, exact
  ratios, binary64 doubles, Unicode scalar-value strings, symbols, keywords,
  persistent lists/vectors/maps/sets. Functions are values but are **not
  canonically comparable** (§2.6).
- **`=` is value equality:** recursive for collections (same-kind vectors
  positionally; maps by equal key/value entries; sets by membership).
  Numbers compare by numeric value under the numeric-tower rules of the
  conformance register (test authority, C3 — category-blind `1`=`1N` holds
  for tests; **no formal numeric-`=` claim in v1**). `=` ignores metadata.
  Doubles follow IEEE-754 equality: **NaN is not equal to itself**; `-0.0`
  and `0.0` are equal. *(Realization pinning via §6 corpus: NaN/`-0.0`
  behavior is a stated portable rule awaiting corpus witness, not yet
  evidence.)*
- **Canonical hash (H5):** the charter owns the canonical hash algorithm per
  type family — strings hashed over their scalar-value sequence; collection
  hashes ordered for sequentials, order-independent for maps/sets. Required
  law: **hash-consistency** — `(= a b) ⇒ (= (hash a) (hash b))`, with double
  canonicalization for `-0.0`/`0.0` and NaN. The exact algorithm and a
  published test-vector suite land at the schema/hash stage (§9); until
  then, hash semantics are specified only up to the consistency law.
  *(Candidate realization input: Jolt's signed 32-bit wrapping
  Murmur3-compatible `hasheq` — P1 §2 [v0513]; note 0.5.14 `hash-combine`
  and keyword host-`hashCode` fixes — `V17/CHANGELOG.md:288-297`. Host
  `hashCode`/JVM-compatible hashing is a `target-dependent` interop profile,
  never canonical.)*
- **`compare`:** a total order over `nil` (least), numbers (by value),
  strings (scalar-value lexicographic), keywords, symbols, booleans,
  characters, and equal-length vectors (lexicographic); NaN sorts topmost
  among doubles and compares equal to itself (so total order is preserved).
  Comparing unsupported pairs is a `:class-cast` error (§2.4).
  *(Realization: P1 §2 `converters.ss:180-223` [v0513], returning exact
  -1/0/1; 0.5.17 note: host String `.compareTo` now returns integers —
  `V17/CHANGELOG.md:27-34`.)*
- **Keywords** are interned (identity-stable); **symbols** are not. Equality
  for both is by namespace + name.

### 2.4 Special forms and the error model (enumerated subset)

The complete special-form set of the v1 fragment is exactly: `if`, `do`,
`let*`, `loop*`, `recur`, `fn*`, `def`, `var`, `quote`, `set!`, `throw`,
`try`/`catch`/`finally`. Everything else is macro expansion over these or
library functions.

- **Macro expansion boundary:** expansion precedes special-form/interop/
  invocation dispatch; expansions are re-analyzed recursively. Expanders run
  with `&form` and `&env` available. Call-site position propagates onto
  unpositioned expansions; **no expansion lineage exists** (identity is
  §4's CSIR work, not the reader's job). *(Realization:
  `V17/jolt-core/jolt/analyzer.clj:961-973`;
  `V17/host/chez/host-contract.ss:236-253,267-295`; IR carries `:pos` (and
  `:def :meta` location duplication) but no provenance —
  `V17/jolt-core/jolt/ir.clj:100-108,149-168`;
  `V17/jolt-core/jolt/analyzer.clj:417-432`.)*
- **`quote`:** yields its form as literal data without evaluation; no
  constructor calls, no evaluation of contents.
- **`throw`:** evaluates one expression and throws the resulting value.
  Arbitrary values are throwable; `ex-info` constructs an error value
  carrying a message, a data map, and an optional cause; `ex-data` retrieves
  the map.
- **`try`/`catch`/`finally`:** the body evaluates first; catch clauses are
  tested **in source order** by type match (`instance?`-style) against the
  thrown value's runtime class; unconditional catch selectors exist
  (Throwable/Object-class equivalents and `:default`); if no clause matches,
  the original value is rethrown unchanged. `finally` is last-position only
  and runs with `dynamic-wind` after-thunk semantics — on normal return, on
  catch completion, or while an unmatched throw escapes; its value is
  discarded. *(Realization: P1 §§1,3 [v0513] — ordered `instance?` plus a
  broad-host-condition helper; `backend_scheme.clj:1155-1170`; mechanism
  unchanged per P10 (a).)*
- **Portable error kinds:** the fragment's error taxonomy is a small set of
  named kinds — `:arity`, `:class-cast`, `:index-out-of-bounds`,
  `:illegal-argument`, `:illegal-state`, `:unsupported`, `:ex-info` (with
  data), plus `:host` (any host-originated condition outside these kinds;
  host messages are `target-dependent`). The named kinds map to Jolt's
  observed exception classes (P1 §3) and to reasonable equivalents in other
  hosts.

### 2.5 Sequence processing and opt-in laziness (H4)

- **Eager-first:** default sequence operations are eager and strict, applied
  in §2.2 order. Transducers compose transformations collection-agnostically;
  eager drivers realize them with defined resource use and no implicit
  retention.
- **Opt-in lazy streams:** laziness exists only through explicit lazy
  stream/generator constructors. For the pure fragment, a lazy stream is
  semantically the sequence of its elements: **a pure lazy stream and its
  eager realization are equal as values.** The observable differences are
  *when* element-producing thunks run and whether they run at all:
  - an exception raised by an element thunk surfaces **at the force point**,
    not at stream construction (an eager operation raising does so at the
    call);
  - divergent (non-terminating) streams are definable; any total consumption
    of one diverges (§2.6 outcome (c));
  - abandonment of an unrealized pure stream has no resource obligation;
    resource-holding streams require explicit scope (`specified-profile`,
    later stage);
  - realized-prefix retention is a memory realization detail, not semantics
    *(JVM hosts retain the realized prefix while the head is referenced —
    realization note, not core semantics)*.
- The fragment's default `map`/`filter`/`concat`-class operations are eager;
  lazy counterparts exist only as explicitly named stream forms.

### 2.6 Observable terminal states (the §6 comparison relation)

The observable outcome of a fragment program is exactly one of:

1. **a canonical value** — normalized recursively: numbers by exact value,
   strings by scalar-value sequence, booleans/`nil`, keywords/symbols by
   namespace+name, collections recursively. Metadata is not part of the
   canonical value. A value containing a function (or any host object) is
   not canonical-comparable and classifies the program's lane per §3 (not a
   fragment outcome).
2. **an error outcome** — `{kind, data?}`: the portable kind (§2.4), plus
   `ex-data` equality when the kind is `:ex-info`. Host-originated messages
   are never compared (target-dependent text).
3. **bounded divergence** — the harness's step/time bound expiring,
   classified `:timeout`. A `:timeout` is never evidence of true divergence
   or of convergence; it is an inconclusive outcome (§5).

Two outcomes are equal iff: both canonical values are `=`-equal per §2.3, or
both error outcomes have equal kinds (and equal data for `:ex-info`).
Divergence is equal only to itself and proves nothing.

## 3. Boundary taxonomy

Every behavior in a program is classified into exactly one **lane**. The lane
determines which claims may be made and which evidence levels are reachable
(§5). Classification is computed conservatively over CSIR regions (§4): the
analyzer assigns the narrowest lane the region's operations provably satisfy;
anything it cannot determine widens.

### 3.1 The four lanes

| Lane | Meaning | Claim levels reachable |
| --- | --- | --- |
| `ordinary-core` | Resolved, expanded semantics over canonical values and declared core operations — the §2 fragment and later specified kernels | up to `bounded-complete`; `proved` only with a checked certificate + stated TCB |
| `Dynamic-opaque` | `eval`/`load-string`, dynamic resolution, unknown macro expansion, unresolved call paths, runtime-generated code | `opaque` / `assumed` only; no static coverage or proof claim crosses |
| `host-capability` | Declared capability crossings: raw host objects, FFI, process, callbacks, clocks, entropy, I/O — including telemetry primitives as observation inputs | `monitored` / `probed` / `runtime` evidence with named postconditions; never purity by assertion |
| `simulation-handler` | Optional scenario interpretation of a registered effect descriptor (§3.3); never a production dependency | `simulated` — deterministic model behavior, not host behavior |

### 3.2 Mechanical widening rules

A region widens to `Dynamic-opaque` when it contains any of: `eval` /
`load-string`; dynamic resolution or an unresolved Var; an unknown macro; a
raw host object crossing; an unregistered callback; or any construct the
analyzer cannot determine. Widening is contagious upward to the enclosing
claim. Host interop operand order (`host-new`/`host-call`) is `opaque`
(§1.2); qualified static-method invocation remains an ordered ordinary
invocation (§2.2).

A **registered callback** is `host-capability` unless its
thread/lifetime/ownership/serialization contract is declared, in which case
it may be narrowed to a named capability lane.

**Widening-site record (P11 B.3, `nondet!` precedent):** every widening site
records `{site-id, trigger, human-authored explanation}` and is
review-flagged. Detection stays mechanical (unsound-omission-free); the
explanation forces human attention per site — strictly stronger than either
alone. Widening sites are first-class review artifacts in §5 evidence
records.

### 3.3 Effect families and the derivation hierarchy (H3)

An **effect descriptor** is `{family, operation, canonical-args,
operation-id, resource-id, site-id, assumptions}`: `operation-id` is
per-instance unique (F7); `site-id` is the CSIR site ID or a reserved
`host-origin` ID (F6/C4); origins and provenance ride as trace-schema
metadata fields, never inside canonical values (P11 B.7 — H5 hash-consistency
depends on this).

- **Core reserved set (E2):** the `:jolt.effect/*` prefix is reserved for
  Jolt-core-owned families — clock, entropy, scheduling/task, io/fs, net,
  process, ffi — with fixed semantics, schemas, and target mappings.
  Extension happens by deriving **from** them; they may not be redefined or
  shadowed.
- **Clock effect (worked example, H1):** an abstract family with distinct
  **monotonic** and **wall-clock** operations. On v0.5.17 the real handler
  maps monotonic to `jolt.host/mono-nanos` and wall to
  `jolt.host/wall-nanos`, and the descriptor records which primitive supplied
  each value (`V17/host/chez/rt.ss:441-458`). Simulation supplies
  virtual-time handlers under the same family.
- **Open extension:** library/application families register under their own
  namespaces and MAY `derive` from a parent family (single-parent tree, S1).
  Derivation is optional but rewarded: derived families inherit handler
  coverage and policy tier; standalone families default to tier (b).
- **Policy tiers (E3):** `(a) modeled` — requires a registered model/handler
  as evidence; registration validates the named model exists and rejects
  invalid claims (S3); `(b) pass-through-only` — real OS/host always,
  recorded but never modeled; `(c) opaque`. Tiers inherit from the nearest
  declared ancestor; upgrades require evidence, downgrades must be declared.
  A hermetic world rejects (b)/(c) families at install.
- **Handler applicability:** a handler installed for family F covers F and
  all its descendants. Handlers are dynamically scoped, innermost-first,
  strict-LIFO; a handler substitutes a validated result or aborts. **No
  continuations exist at this layer.** Between applicable handlers, the
  dynamically nearest wins; at the same dynamic level, the most-specific
  family wins; equal specificity is an installation error and fails closed.
- **Fail-closed rule:** a hermetic world fails closed on a performed family
  with no covering handler (directly or via ancestors), or on any family
  registered at a tier the world rejects. Pass-through in hybrid/observed
  worlds is always an explicit per-family policy choice, never ambient.
  Native/FFI families support pass-through, modeled, record/replay, and
  hybrid routing policies; **simulation never prohibits deliberately calling
  the real OS**; simulator handlers control existing application/library
  boundaries and never reimplement libraries (H1).

### 3.4 Observation and hazard classes

- Observable events are emitted only at declared operation boundaries
  (descriptors) or at runtime lifecycle seams — which do not exist at the
  v0.5.17 baseline and are **requested from the runtime lane, never assumed**
  (non-goal 13; P10 (b) REMOVED).
- **Live-collection-as-final hazard (P11 B.2):** an observation of a
  collection may be treated as a terminal value only at a declared
  **quiescence point**. A monitor or differential comparison that observes a
  collection before quiescence must classify the observation `inconclusive`,
  never pass/fail on it (mirrors Hydro's bounded/unbounded typing, P11 A.4).
- Host telemetry scalars (clocks, counters, thread-id) are observation inputs
  only — never evidence identities (non-goal 14).

### 3.5 Boundary evidence rules

- Lane membership caps evidence levels per §3.1's table; §5's lattice governs
  promotion within a lane.
- Unknown, malformed, or lost **required** observations are
  `inconclusive`/`failed` according to the declared coverage policy — never
  silently ignored (P5 B.16).
- The jolt-sim runtime adapter is an **optional** host-capability /
  simulation-handler seam, not a language-wide effect runtime; its controller
  semantics at `eb7bce4` are documented in P2; at v0.5.17 no controller seam
  exists upstream (P10 (b)) — the charter specifies the contracts, not the
  ABI.

## 4. Provenance, site IDs, schemas/effects, assumptions

DRAFT PENDING — A3-target/A2-minimal staging with closed v1 schema (F1);
site-ID from normalized-expanded-form digest (F2) + normative normalization
appendix (F3, Appendix A); remint orphaning + migration records (F4); anchors
A3-conditional with no evidence transfer (F5); effect descriptors D2 with one
ID space + host-origin class + per-instance `operation-id` (C4/F6/F7);
declared assumptions representation; origins/provenance as trace-schema
metadata, never inside canonical values (P11 B.7); dynamic origin tracking
("which CSIR site produced this runtime value") deferred to a later opt-in
stage with lazy materialization (P11 D).

## 5. Evidence taxonomy

DRAFT PENDING — the 7 levels; C2 claim-relative partial order; never-promote
list; mandatory record metadata; pre-remint record rule (records remain valid
under their recorded versions, never silently promoted); Fable slice-4
(lattice soundness + record-schema sufficiency) fires before this section is
finalized.

## 6. First executable differential-validation loop

DRAFT PENDING — source → CSIR → reference evaluator → compiled Jolt; corpus
(conformance selection + generated programs); comparison relation (terminal
observable per §2.6); known-divergence register; minimized-case persistence
(concrete source + Hegel seed + versions); first honest milestone (one fixed
corpus case, labeled `sampled`); Hegel API additions remain deferred (D9);
ordering: CSIR v1 + reference evaluator first, generated cases second.
P11/Cedar incorporations: generators for ALL input classes; CI-enforced
spec/impl sync (reference evaluator and compiled path gated together);
direct property tests on the implementation as well as cross-implementation
comparison; reference evaluator is TCB and gets its own controls (the Cedar
oracle itself was buggy).

## 7. First proof target

DRAFT PENDING — capacity-one mailbox per D5 with G1–G6 corrections: world
with waiting flags; conditional wakes; model-level relation over kernel block
transitions; `max-steps 11` (longest quiescence path 10 + slack) with
`:max-states` named; invariant disjunction incl. `:failed`; second
fault-injected control (send-a, close, send-b) for clause 3; per-clause
known-SAT probes; persisted-trace reader fixtures; TCB table; claim scope
"TCB-validation-only, empty refinement relation"; execution dependency
(jolt-sim landing-order amendment or evidence stays `[assumed]`).
P11 incorporations: FuzzChick rule-table factorization pattern for isolating
the transition relation for systematic fault injection; coverage
instrumentation targets the claim, never the harness.

## 8. One semantic/evidence model consumption

DRAFT PENDING — canonical schema IR driving validators, compiler facts,
Hegel domains, trace codecs, model domains, refinement contracts, solver
inputs; sampled vs bounded-complete vs monitored routing per §5; Hegel gaps
hand-built in-project (D9); concurrency/time obligations to jolt-sim;
sequential-model variants remain Hegel-`sampled`; no separate user-facing
languages; generated artifacts carry provenance headers and never assert
correctness. P11 incorporations: singleton-type-style vacuity warnings
(always-true/always-false contract branches flagged by the validator);
capability rule — optional-entry access in contracts requires a prior
presence check; contract modes (advisory / enforced / discharged-elidable)
with Checked C erasure as the discharged-mode reference; one property
artifact drives testing and proof (FuzzChick).

## 9. Staged exit criteria

DRAFT PENDING — exact exit criteria for: charter acceptance; reference
evaluator; schema prototype; first verified kernel. Includes the CSIR v1 exit
test (one fixed corpus case through both paths, labeled `sampled`, plus
cross-run site-ID determinism vectors per F3) and the proof-target execution
gate (jolt-sim landing-order amendment). P11/Cedar design-for-decidability
constraints for the verified-kernel stage: fragment types map 1:1 to
decidable theories; ground well-formedness over the finite footprint, never
quantifiers; validator as precondition making the encoding total; errors
encoded explicitly; restricted subtyping. Checked C migration ergonomics:
best-effort non-blocking adoption; monotonic progress (verified parts stay
verified); artifact buildable/testable at every stage. Dafny-stability
discipline: TCB components specified + opaque; tool/checker versions pinned;
verification-instability treated as evidence-relevant metadata.

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
