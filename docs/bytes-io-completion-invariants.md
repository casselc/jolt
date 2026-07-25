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

## Completion and lease lifecycle

The model separates four facts that must not be collapsed:

1. cancellation was requested;
2. native code may still access the submitted window;
3. one terminal outcome has been published; and
4. the caller may reuse the window.

The selected lifecycle keeps caller reuse false throughout submitted,
cancel-requested, and internal release-before-publication states. Native access
ends before terminal publication. Exactly one of succeeded, failed, or
cancelled becomes visible, and only that terminal observation makes the window
reusable by the caller.

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

Run each SMT file through Chiasmus `chiasmus_lint` and `chiasmus_verify` with
`solver=z3`; Chiasmus supplies the final solver commands omitted from the
checked-in files. Run the Prolog files with `solver=prolog` and these queries:

```text
premature_reuse(State, Path).
double_publication(State, Path).
bad(State, Path).
valid_cancel_path(Path).
```

The expected SMT sequence is SAT, UNSAT, SAT. The buggy Prolog queries must
produce paths, the corrected `bad/2` query must not, and both valid-cancel
queries must produce the path shown above.

## Source and implementation anchors

The generic core dispatch gaps that must be corrected before the idiomatic
surface is claimed currently live in:

- `jolt-core/clojure/core/20-coll.clj` for collection predicates and reduce;
- `host/chez/seq.ss` for sequence/reduction dispatch;
- `host/chez/java/concurrency.ss` for Future behavior; and
- `host/chez/post-prelude.ss` for deref and pending dispatch.

Implementation commits must replace these broad anchors with exact functions
and line references, add JVM controls where parity is intended, and link the
runtime tests back to this note.
