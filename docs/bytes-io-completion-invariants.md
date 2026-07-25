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
