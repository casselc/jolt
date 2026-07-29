# Byte-window and I/O-completion invariants

This note supplements [RFD 0001](rfd/0001/README.md). The RFD owns the selected
layering and public semantics; this note records the bounded models, witnesses,
assumptions, and implementation gates behind those decisions.

The models have different implementation status. Core protocol dispatch and
the deftype/defrecord representation boundary have runtime controls in this
fork. `Window`, strict `Cursor`, and bounded whole-Window copy are implemented
on the separate `jolt-bytes` branch `codex/window-cursor-runtime` at
`b63603b`. The external `jolt-bencode` and nREPL incubation branches are the
first codec and transport consumers. The jolt-tcp completion lifecycle remains
a design contract. In every case, a solver result establishes only the
property encoded by its bounded or abstract model; it is not a proof of the
runtime.

## Byte-window containment

A `Window` is an immutable descriptor `(backing, offset, length)` over mutable,
aliased storage. A relative half-open slice `[start,end)` is valid when:

```text
0 <= offset
0 <= length
offset + length <= backing capacity
0 <= start <= end <= length
```

The selected construction is:

```text
child offset = offset + start
child length = end - start
```

Within backing capacities `0..16`, the corrected counterexample query is
UNSAT: no valid relative slice has a negative length, escapes its parent, or
escapes the backing capacity. The deliberately buggy `child length = end`
control is SAT for parent `[0,1)` and empty tail slice `[1,1)`, producing an
escaping child `[1,2)`. The full capacity-16 window and its full slice remain
reachable.

The bounded argument covers descriptor arithmetic only. It assumes an
API-respecting caller and cannot prevent mutation through a retained raw-array
alias. Traversal while another owner mutates or holds an operation lease is
outside the contract.

Runtime conformance must additionally check:

- `seq`, `nth`, two- and three-argument `reduce` yield the same signed byte
  sequence;
- empty, full, nested, and boundary slices preserve their parent bounds;
- invalid ranges fail without constructing a descriptor; and
- whole-Window copies validate the destination before mutation and preserve
  overlap as `memmove` would; and
- `drop`/`take` produce ordinary sequence projections while `slice` preserves
  backing identity in O(1).

## Ansatz oracle and Hegel runtime properties

The solver model answers a bounded counterexample query, but it need not be the
only source of runtime properties. The selected follow-on uses Ansatz as a
proof oracle and jolt-hegel as the shrinking runtime explorer:

```text
Ansatz theorem
   | hypotheses                         | conclusions
   v                                    v
constructive dependent generators   runtime assertions
   |                                    |
   +---------- hand-written Hegel property ---------+
                              |
                       actual Jolt Window

pinned theorem/environment --> exhaustive bounded EDN oracle
```

The initial pure target was the following statement over unbounded naturals:

```text
offset + length <= capacity
and start <= end
and end <= length
implies
  child-offset = offset + start
  child-length = end - start
  child-offset + child-length <= capacity
```

The direct inequality proof was not admitted because its transitive closure
reaches the `propext` axiom. The accepted constructive closure instead takes
the parent tail and backing room as witnesses and proves the same endpoint and
containment conclusions without axioms, foreign declarations, opaque
declarations, Quot, partial, or unsafe definitions.

The theorem does not prove Jolt's integer coercions, allocation bounds, byte
sign, mutation behavior, or backing identity. Those remain runtime
obligations. The checked oracle lane enumerates capacities `0..16`: 969 valid
parent descriptors and all 20,349 valid relative slices. It retains the known
buggy empty-tail witness for parent `[0,1)` and slice `[1,1)`.

The Hegel positive-domain property draws inputs dependently:

| Theorem hypothesis | Constructive draw | Runtime observation |
| --- | --- | --- |
| `capacity : Nat` | capacity `0..256`, then an exact-size backing | backing has the requested capacity |
| `0 <= offset <= capacity` | offset `0..capacity` | parent construction succeeds |
| `offset + length <= capacity` | length `0..capacity-offset` | traversal stays inside backing |
| `0 <= start <= end <= length` | start `0..length`, then end `start..length` | slice construction succeeds |
| `child-length = end-start` | no independent draw | child count is `end-start` |
| `child-offset = offset+start` | no independent draw | child contents equal the corresponding backing subsequence |
| shared backing | outside the theorem | a nonempty child observes a backing mutation |

Independent integers followed by `h/assume!` or `g/filter` are rejected for
this positive-domain property. They waste cases and may shrink out of the
theorem's domain. `g/let` inside `hegel.clojure-test/with`, or nested `g/bind`
for a reusable generator, makes each later bound depend on earlier draws.
Before that claim becomes a gate, a deliberately failing construction must
shrink to a reproducible minimal case that still satisfies every hypothesis and
reports `:flaky? false`.

The incubating `jolt.bytes` package exercises the first property in this shape;
the Window calls are the selected RFD surface, while the Hegel forms are
current:

```clojure
(deftest valid-window-slices-follow-proved-geometry
  (with {:test-cases 500
         :seed 20260724
         :name "jolt.bytes/window-slice-containment/v1"
         :database ""
         :verbosity :quiet}
    [capacity (g/integer 0 256)
     octets   (g/vector {:size capacity} (g/octet))
     offset   (g/integer 0 capacity)
     length   (g/integer 0 (- capacity offset))
     start    (g/integer 0 length)
     end      (g/integer start length)]
    (let [backing  (byte-array (mapv unchecked-byte octets))
          parent   (bytes/window backing offset (+ offset length))
          child    (bytes/slice parent start end)
          expected (mapv #(if (> % 127) (- % 256) %)
                         (subvec octets
                                 (+ offset start)
                                 (+ offset end)))]
      (when-not (= (- end start) (count child))
        (throw (ex-info "slice length disagrees with proved geometry"
                        {:hegel/origin
                         "jolt.bytes/window-slice:length"})))
      (when-not (= expected (vec child))
        (throw (ex-info "slice contents disagree with proved geometry"
                        {:hegel/origin
                         "jolt.bytes/window-slice:contents"})))
      ;; A nonempty mutation/alias check is a separate runtime obligation.
      )))
```

Invalid windows and slices use separate generators by violation class:
negative bounds, reversed ranges, parent escape, and child escape. Machine
overflow is also a separate property because the natural-number theorem does
not decide signed fixed-width arithmetic or feasible allocation size.

At `jolt-bytes` commit `b63603b`, the JVM and proposal-Jolt gates each execute
132,671 assertions. That includes 2,601 Cursor reads, 4,845 accepted two-read
compositions, and 825 bounded overlapping whole-Window copies in addition to
the Window rows above. Six Hegel properties run 500 cases each. The Cursor
failure-consumption control shrinks non-flakily to
`{:limit 0 :position 0 :size 1}`; the Window control retains the empty-tail
witness above. Chiasmus verifies corrected, buggy, and non-vacuity models for
Cursor commit and copy bounds. These counts and source pins live with the
package rather than being inferred from this summary.

The same division generalizes without making networking the organizing
example:

- for codecs, Ansatz proves round-trip, canonicalization, encoded-length, and
  cursor-consumption laws; Hegel generates semantic values first and derives
  encoded bytes, then uses `g/chunkings` for incremental-versus-whole decoding;
- for pure state machines, an Ansatz invariant and transition theorem supply
  the model precondition, step, and post-state invariant; Hegel stateful rules
  execute real operations and shrink traces; and
- mutation, callbacks, native completion, cleanup, scheduling, fairness, and
  durability remain runtime or environmental evidence rather than consequences
  of the pure theorem.

The codec pattern now has an implemented first consumer. `jolt-bencode` commit
`1ef16d1` supplies a strict UTF-8 nREPL profile over `jolt.bytes/Cursor` with
explicit `:ok`, `:need-more`, and `:invalid` results. Failure returns the
identical Cursor. Its Ansatz slice kernel-checks framing size, containment, and
commit geometry; its bounded differential oracle checks 9,537 rows; its
runtime oracle exhausts 162 modeled values, every proper prefix, and all
26,244 ordered pairs; JVM and Jolt each execute 109,209 assertions; and three
Hegel properties run 500 cases each. The external nREPL branch
`codex/byte-native-bencode` at `12e7170` then retains a Cursor across socket
reads, copies only an unread partial suffix, bounds an accumulated frame, and
distinguishes clean EOF from truncation. This is composition evidence, not a
claim that Ansatz proves UTF-8, recursive parsing, sockets, or middleware.

### Provenance manifest and trust boundary

The spike audited Ansatz tag `0.2.75`, commit
`d58b619b18f66c5cc05f684043e3d8978c568d81`. Adoption requires a verified
environment replay and a dependency-closure audit that rejects unreviewed
hooks, `partial`, `foreign`, opaque or assumed constants, and Quot declarations
from the initial proof slice. The current elaborator and Clojure generator are
not assumed semantics-preserving. A hook-free generated JVM evaluation may be
used as another differential lane, but the portable artifact remains data:
versioned EDN rows with a digest.

A reviewed manifest may record:

```clojure
{:id :jolt.bytes/window-slice/v1
 :theorem {:engine :ansatz
           :commit "d58b619b18f66c5cc05f684043e3d8978c568d81"
           :environment-sha256 "<required>"
           :names [:slice-end-preserved :slice-contained]}
 :oracle {:resource "byte-window-slices-v1.edn"
          :sha256 "<required>"
          :case-count 20349}
 :mapping {:hypotheses
           {:capacity :generated-backing-size
            :parent-contained :dependent-offset-length
            :slice-valid :dependent-start-end}
           :conclusions
           {:child-length :runtime-count
            :child-offset :runtime-contents}}
 :runtime {:property
           jolt.bytes-property-test/valid-window-slices-follow-proved-geometry}
 :runtime-only [:signed-traversal :backing-alias :invalid-rejection]
 :omissions [:negative-nat :machine-overflow :concurrency :leases]}
```

Automation validates the checked Window and Cursor artifact digests, pins,
named tests, and case counts. It must not synthesize executable generators or
assertions: theorem types do not determine Nat-to-Long representation,
allocation policy, effects, invalid-input behavior, or sound shrinking. The
exact proof closures, provenance manifests, bounded EDN, and runtime mapping
live in `jolt-bytes`; the solver trios and runtime controls remain independent
semantic companions.

## Protocol and core-interface dispatch

The idiomatic `Window` and completion surfaces rely on ordinary Clojure core
operations. Dispatch is sound only when all three facts hold:

1. the value declares the required interface;
2. the implementation has the required method name; and
3. the implementation accepts the exact interface arity, including `this`.

Method name and arity alone are insufficient, and a registry that stores only a
simple interface name has not preserved identity. The buggy model pins a local
protocol with the same short name and method shape as a core interface: its
logical identity differs while its lossy stored id compares equal, producing a
false dispatch. The corrected model requires canonical stored-id equality to
agree with logical interface identity, so the false-dispatch query is UNSAT
over the complete Boolean domain. Its non-vacuity control still selects a
genuine implementation.

The runtime controls use both unrelated protocol names and local protocols
literally named `IReduce`, `IDeref`, `IBlockingDeref`, `IPending`, `Seqable`,
`Counted`, and `Indexed`. Their canonical namespace-qualified ids must remain
distinct from `clojure.lang.*`, and their same-shaped methods must never drive
the core operations. JVM controls establish the intended fallback or
`ClassCastException`. The same suite verifies that:

- custom `IReduce` and `IReduceInit` return values are not unwrapped by core;
- future and promise, but not delay, report `IBlockingDeref`;
- timed deref rejects native and custom IDeref-only values;
- invalid public deref arities throw `clojure.lang.ArityException`; and
- declaring a core interface while omitting its selected method throws
  `AbstractMethodError`, rather than being confused with an absent interface.

The same identity rule applies below the core adapters. A `reify` stores its
local implementations in a compact method-name table, but that representation
does not authorize selection by name alone:

```text
select-local(reify, requested-protocol, method)
  implies requested-protocol is in reify.declared-protocols
```

If the requested protocol was not declared, dispatch must continue to that
protocol's host/default extensions and otherwise report a missing method. A
local method belonging to a different protocol is never a candidate. The
`reify` unit control captures the concrete collision using two protocols that
both declare `m`; the JVM returns the first implementation only through the
first protocol and reports the second call missing.

## Deftype and defrecord representation boundary

Jolt uses one physical `jrec` representation for `deftype` and `defrecord`.
That implementation choice must not manufacture public map behavior. The
semantic selector is the declared kind and operation:

```text
public raw slot read
  iff value is a defrecord
  and operation is get/keyword lookup
  and key names a declared field

explicit raw slot read
  iff operation is .-field
  and the field exists
```

A bare deftype therefore answers public lookup only through its declared
`ILookup` or set-like `get` method. A same-named physical field cannot bypass
that method. Record-style fallbacks for `count`, `contains?`, `find`, `assoc`,
`dissoc`, and `conj` are defrecord-only; a deftype receives them only by
declaring and implementing the corresponding interfaces. Explicit `.-field`
access remains available to generated deftype method bodies and direct callers.

The compiler must preserve the same distinction. Record-shape metadata carries
`:record?` through joins, caps, local annotations, whole-program field types,
and code generation. Public keyword/get inference and scalar replacement use a
physical field only when that flag is true. Explicit field IR may still use the
direct accessor for either kind. Otherwise an optimized build could reintroduce
a private-slot leak that the runtime dispatcher correctly rejects.

The corrected model is a complete Boolean selector model for these choices. Its
counterexample query is UNSAT. This means no assignment satisfying the encoded
selectors simultaneously leaks a bare deftype slot, bypasses its declared
lookup handler, or grants it record collection fallbacks. It does not model
field-index calculation, protocol resolution internals, generated Scheme, or
Chez execution. The buggy control is SAT with all three violations true. The
non-vacuity control is SAT with a record public read, a deftype `ILookup` read,
and an explicit deftype field read all available.

Runtime controls pin the JVM-facing consequences: eleven unit assertions cover
opaque public lookup, rejected record collection operations, same-name
`ILookup`, explicit fields, kind predicates, and retained defrecord map
behavior. The optimizer control requires public lookup to retain `jolt-get` and
return the handler's `:lookup`, while explicit access emits the direct field
accessor and returns the physical value.

## Completion and lease lifecycle

The selected completion is future-shaped without claiming Jolt `Future`
cancellation. It implements `IDeref`, timed `IBlockingDeref`, and `IPending`,
exposes a nonblocking `outcome`, and accepts an explicit two-phase `cancel!`
request. Untimed and timed deref return a success value or throw the stored
failure/cancellation exception. An observation timeout changes no operation or
lease state.

The model separates four facts that must not be collapsed:

1. cancellation was requested;
2. native code may still access the submitted window;
3. one terminal outcome has been published; and
4. the caller may reuse the window.

The selected lifecycle keeps caller reuse false throughout submitted,
cancel-requested, and internal release-before-publication states. Native access
ends before terminal publication. Exactly one of succeeded, failed, or
cancelled becomes visible. Terminal publication makes the storage eligible for
reuse; the caller may actually reuse it only after observing that terminal
state.

The corrected graph has no reachable state, in paths through four transitions,
with:

- a terminal publication while native access remains possible;
- caller reuse before terminal publication;
- more than one terminal publication; or
- native access already ended merely because cancellation was requested.

The buggy control reaches both expected witnesses:

```text
created -> submitted -> cancel_requested
        -> cancel_requested_but_released
```

and:

```text
created -> submitted -> success_released
        -> succeeded -> double_published
```

The non-vacuity control reaches the valid four-transition cancellation path:

```text
created -> submitted -> cancel_requested -> cancel_released -> cancelled
```

The graph proves neither fairness nor that a native backend honors
cancellation. It does not prove peer delivery, external storage visibility, or
durability. Runtime tests must force close/cancel/native-completion races and
verify release-before-notification ordering under the actual synchronization
primitive.

## Solver records

| Model | Expected and verified result | Meaning |
| --- | --- | --- |
| [`byte-window-slice-containment-buggy.smt2`](../test/chez/formal/byte-window-slice-containment-buggy.smt2) | SAT, escaping `[1,2)` child | The wrong child-length formula admits the pinned empty-tail witness. |
| [`byte-window-slice-containment-corrected.smt2`](../test/chez/formal/byte-window-slice-containment-corrected.smt2) | UNSAT | No containment counterexample exists in the recorded `0..16` domain. |
| [`byte-window-slice-containment-nonvacuity.smt2`](../test/chez/formal/byte-window-slice-containment-nonvacuity.smt2) | SAT, full capacity-16 slice | The corrected constraints preserve a useful boundary case. |
| [`ffi-pointer-scope-reentry-guard-omitted-buggy.smt2`](../test/chez/formal/ffi-pointer-scope-reentry-guard-omitted-buggy.smt2) | SAT, retired backing moves and stale receiver resumes | Omitting the one-shot retirement guard lets a captured Scheme continuation resume with an address computed in the old dynamic extent. |
| [`ffi-pointer-scope-reentry-corrected.smt2`](../test/chez/formal/ffi-pointer-scope-reentry-corrected.smt2) | UNSAT | Once the first extent exits, the receiver cannot resume, regardless of whether the unlocked backing moved. |
| [`ffi-pointer-scope-reentry-nonvacuity.smt2`](../test/chez/formal/ffi-pointer-scope-reentry-nonvacuity.smt2) | SAT, initial live receiver runs with a valid pointer | The retirement guard preserves the useful original scoped call. |
| [`io-completion-lease-lifecycle-buggy.pl`](../test/chez/formal/io-completion-lease-lifecycle-buggy.pl) | `premature_reuse/2` and `double_publication/2` each have a witness | Both rejected transition classes are observable. |
| [`io-completion-lease-lifecycle-corrected.pl`](../test/chez/formal/io-completion-lease-lifecycle-corrected.pl) | `bad/2` has no solution; `valid_cancel_path/1` has one | Safety holds without eliminating valid cancellation. |
| [`io-completion-lease-lifecycle-nonvacuity.pl`](../test/chez/formal/io-completion-lease-lifecycle-nonvacuity.pl) | `valid_cancel_path/1` has the four-transition solution | The lifecycle constraints are non-vacuous. |
| [`protocol-interface-dispatch-buggy.smt2`](../test/chez/formal/protocol-interface-dispatch-buggy.smt2) | SAT, local same-short-name protocol selected | Lossy simple-name identity plus a same-shaped method admits false core-interface dispatch. |
| [`protocol-interface-dispatch-corrected.smt2`](../test/chez/formal/protocol-interface-dispatch-corrected.smt2) | UNSAT | Canonical stored ids preserve logical interface identity and exclude the modeled false dispatch. |
| [`protocol-interface-dispatch-nonvacuity.smt2`](../test/chez/formal/protocol-interface-dispatch-nonvacuity.smt2) | SAT, genuine implementation selected | The exact selector still admits useful dispatch. |
| [`protocol-reify-dispatch-buggy.smt2`](../test/chez/formal/protocol-reify-dispatch-buggy.smt2) | SAT, undeclared protocol selects a same-named local method | A method-name-only reify table admits cross-protocol dispatch. |
| [`protocol-reify-dispatch-corrected.smt2`](../test/chez/formal/protocol-reify-dispatch-corrected.smt2) | UNSAT | Local selection requires membership of the requested canonical protocol in the reify declaration set. |
| [`protocol-reify-dispatch-nonvacuity.smt2`](../test/chez/formal/protocol-reify-dispatch-nonvacuity.smt2) | SAT, declared protocol selects its method | The membership guard preserves useful local dispatch. |
| [`deftype-record-boundary-buggy.smt2`](../test/chez/formal/deftype-record-boundary-buggy.smt2) | SAT, bare deftype slot exposed and handler bypassed | Treating every physical `jrec` as a record fabricates three modeled capabilities. |
| [`deftype-record-boundary-corrected.smt2`](../test/chez/formal/deftype-record-boundary-corrected.smt2) | UNSAT | Kind-aware runtime and compiler selectors exclude the modeled public-slot, handler-bypass, and collection-fallback counterexample. |
| [`deftype-record-boundary-nonvacuity.smt2`](../test/chez/formal/deftype-record-boundary-nonvacuity.smt2) | SAT, all intended access paths available | Defrecord lookup, declared deftype lookup, explicit deftype field access, and record collection behavior remain useful. |

Run each SMT file through Chiasmus `chiasmus_lint` and `chiasmus_verify` with
`solver=z3`; Chiasmus supplies the final solver commands omitted from the
checked-in files. Run the Prolog files with `solver=prolog` and these queries:

```text
premature_reuse(State, Path).
double_publication(State, Path).
bad(State, Path).
valid_cancel_path(Path).
```

Each SMT model trio has the expected SAT, UNSAT, SAT sequence. The buggy Prolog
queries must produce paths, the corrected `bad/2` query must not, and both
valid-cancel queries must produce the path shown above.

The scoped-pointer trio deliberately does not prove Chez GC or continuation
semantics. Its executable companion captures a continuation inside
`ffi-with-locked-byte-range`, exits the scope, and attempts to re-enter it. The
old helper resumed with `locked-object?` false; the corrected helper raises
before the receiver runs again, remains unlocked, and admits a later fresh
scope. Re-locking alone is insufficient because the receiver's pointer
argument was computed before capture and may already be stale.

## Source and implementation anchors

The generic core dispatch implementation and its runtime controls live in:

- `jolt-core/clojure/core/20-coll.clj` for collection predicates and reduce;
- `jolt-core/clojure/core/30-macros.clj` for canonical protocol ids carried
  through `defprotocol`, `deftype`, `defrecord`, `reify`, extension, and
  `instance?`, and for explicit field reads in generated deftype methods;
- `host/chez/records.ss` (`iface-method`) for interface-identity and exact-arity
  method selection, and `protocol-resolve` for requested-protocol membership
  before a reify-local method is selected; the same file owns the runtime
  defrecord-kind and public-lookup/collection selectors;
- `jolt-core/jolt/passes/types.clj`,
  `jolt-core/jolt/passes/types/lattice.clj`,
  `jolt-core/jolt/passes/inline.clj`, and
  `jolt-core/jolt/backend_scheme.clj` for preserving the kind distinction
  through inference, scalar replacement, and code generation;
- `host/chez/java/dot-forms.ss` for the explicit field-access path;
- `host/chez/seq.ss` (`jolt-reduce`) for `IReduce` and `IReduceInit`;
- `host/chez/java/concurrency.ss` (`jolt-deref` and its instance-check arm) for
  `IDeref`/`IBlockingDeref` behavior;
- `host/chez/post-prelude.ss` for `IPending`; and
- the `reify`, `protocol-predicates`, `protocol-reduce`, `protocol-deref`, and
  `deftype-opacity` suites in `test/chez/unit.edn`; and
- `host/chez/run-inline-body.ss` for the optimized public-versus-explicit field
  control.

The accepted implementation is commit `3ac5be82`. Its final gates passed
1106/1106 unit assertions, self-host fixpoint, host-class 22/22, PIC 22/22,
protocol-return 4/4, devirtualization 12/12, inline-body 3/3, contagion 20/20,
and corpus 3803/3822 with zero new divergence (9 known mismatches and 10
expected crashes). The model claims remain bounded to the selector and do not
replace those runtime/JVM parity controls.

The additional deftype/defrecord implementation is commit `ecc22d78`. Its
focused post-remint gates passed 1122/1122 unit assertions, inference 36/36,
whole-program inference 7/7, field reads 11/11, inline-body 7/7, and a
byte-identical Chez 10.4.1 self-host fixpoint with zero skipped forms. The
remaining core/compiler, FFI, tree-shake, dev-boot, namespace-effect, and JVM
certification gates passed. The full CTS command is not green on the branch
base: clean commit `edd4a257` and this implementation both produce the same
pre-existing `bigint` 5-failure and `num` 3-failure results against baselines
of 1 and 2; this slice does not relabel or fix that unrelated numeric/class
regression.
