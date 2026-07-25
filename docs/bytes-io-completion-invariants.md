# Byte-window and I/O-completion invariants

This note supplements [RFD 0001](rfd/0001/README.md). The RFD owns the selected
layering and public semantics; this note records the bounded models, witnesses,
assumptions, and implementation gates behind those decisions.

These are design proofs. Until `jolt.bytes/Window` and the jolt-tcp completion
type exist and pass their runtime conformance suites, the models establish
consistency of the proposed contracts rather than correctness of code.

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

The proposed initial pure theorem is over unbounded naturals:

```text
offset + length <= capacity
and start <= end
and end <= length
implies
  child-offset = offset + start
  child-length = end - start
  child-offset + child-length <= capacity
```

The theorem does not prove Jolt's integer coercions, allocation bounds, byte
sign, mutation behavior, or backing identity. Those remain runtime
obligations. The first oracle lane will enumerate capacities `0..16`: 969 valid
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

Once `jolt.bytes/Window` lands, the first property has this shape; the Window
calls are the selected RFD surface, while the Hegel forms are current:

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

Automation may validate the manifest schema, pins, named tests, case count, and
digests. It must not yet synthesize executable generators or assertions:
theorem types do not determine Nat-to-Long representation, allocation policy,
effects, invalid-input behavior, or sound shrinking. The theorem, oracle, and
manifest are proposed follow-on artifacts; the checked-in evidence today is the
solver trio and its runtime controls.

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
| [`io-completion-lease-lifecycle-buggy.pl`](../test/chez/formal/io-completion-lease-lifecycle-buggy.pl) | `premature_reuse/2` and `double_publication/2` each have a witness | Both rejected transition classes are observable. |
| [`io-completion-lease-lifecycle-corrected.pl`](../test/chez/formal/io-completion-lease-lifecycle-corrected.pl) | `bad/2` has no solution; `valid_cancel_path/1` has one | Safety holds without eliminating valid cancellation. |
| [`io-completion-lease-lifecycle-nonvacuity.pl`](../test/chez/formal/io-completion-lease-lifecycle-nonvacuity.pl) | `valid_cancel_path/1` has the four-transition solution | The lifecycle constraints are non-vacuous. |
| [`protocol-interface-dispatch-buggy.smt2`](../test/chez/formal/protocol-interface-dispatch-buggy.smt2) | SAT, local same-short-name protocol selected | Lossy simple-name identity plus a same-shaped method admits false core-interface dispatch. |
| [`protocol-interface-dispatch-corrected.smt2`](../test/chez/formal/protocol-interface-dispatch-corrected.smt2) | UNSAT | Canonical stored ids preserve logical interface identity and exclude the modeled false dispatch. |
| [`protocol-interface-dispatch-nonvacuity.smt2`](../test/chez/formal/protocol-interface-dispatch-nonvacuity.smt2) | SAT, genuine implementation selected | The exact selector still admits useful dispatch. |
| [`protocol-reify-dispatch-buggy.smt2`](../test/chez/formal/protocol-reify-dispatch-buggy.smt2) | SAT, undeclared protocol selects a same-named local method | A method-name-only reify table admits cross-protocol dispatch. |
| [`protocol-reify-dispatch-corrected.smt2`](../test/chez/formal/protocol-reify-dispatch-corrected.smt2) | UNSAT | Local selection requires membership of the requested canonical protocol in the reify declaration set. |
| [`protocol-reify-dispatch-nonvacuity.smt2`](../test/chez/formal/protocol-reify-dispatch-nonvacuity.smt2) | SAT, declared protocol selects its method | The membership guard preserves useful local dispatch. |

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

## Source and implementation anchors

The generic core dispatch implementation and its runtime controls live in:

- `jolt-core/clojure/core/20-coll.clj` for collection predicates and reduce;
- `jolt-core/clojure/core/30-macros.clj` for canonical protocol ids carried
  through `defprotocol`, `deftype`, `defrecord`, `reify`, extension, and
  `instance?`;
- `host/chez/records.ss` (`iface-method`) for interface-identity and exact-arity
  method selection, and `protocol-resolve` for requested-protocol membership
  before a reify-local method is selected;
- `host/chez/seq.ss` (`jolt-reduce`) for `IReduce` and `IReduceInit`;
- `host/chez/java/concurrency.ss` (`jolt-deref` and its instance-check arm) for
  `IDeref`/`IBlockingDeref` behavior;
- `host/chez/post-prelude.ss` for `IPending`; and
- the `reify`, `protocol-predicates`, `protocol-reduce`, and `protocol-deref`
  suites in `test/chez/unit.edn`.

The accepted implementation is commit `3ac5be82`. Its final gates passed
1106/1106 unit assertions, self-host fixpoint, host-class 22/22, PIC 22/22,
protocol-return 4/4, devirtualization 12/12, inline-body 3/3, contagion 20/20,
and corpus 3803/3822 with zero new divergence (9 known mismatches and 10
expected crashes). The model claims remain bounded to the selector and do not
replace those runtime/JVM parity controls.
