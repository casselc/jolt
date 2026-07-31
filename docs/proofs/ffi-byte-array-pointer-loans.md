# FFI scoped byte-array pointer loans

## Public contract

`jolt.ffi/with-byte-array-pointer` has two forms:

```clojure
(with-byte-array-pointer bytes callback)
(with-byte-array-pointer bytes offset length callback)
```

Both invoke `callback` with the scoped pointer and validated length. The first
form covers the complete byte array. The second accepts exactly
`0 <= offset <= array-length` and `0 <= length <= array-length - offset`, so an
empty range at the tail is valid without forming the potentially
overflow-shaped sum `offset + length`.

The pointer is valid only during that callback. Native code must not retain it.

## Live implementation facts

The ordinary runtime path in `host/chez/java/ffi.ss`:

1. accepts only a byte array and obtains its unboxed bytevector backing;
2. converts and validates the complete range before taking a lock;
3. calls Chez `lock-object` before computing the interior reference address;
4. invokes the Jolt callback inside `dynamic-wind`;
5. marks the scope retired and balances its lock in the after thunk; and
6. rejects any continuation that attempts to re-enter the callback after the
   first exit.

Chez documents a bytevector reference address as the address of its first
content byte. It may change unless the object is locked or otherwise immobile.
Chez locks are reference-counted, so nested scopes over the same backing must
each balance their own lock:

- <https://cisco.github.io/ChezScheme/csug10.1.0/csug.pdf>
- <https://cisco.github.io/ChezScheme/csug9.5/smgmt.html>

The simulation-only overlay in `host/chez/sim/runtime.ss` stages two
native-operation descriptors around the unchanged callback:

```text
borrow-byte-array [same-live-array offset length] -> positive pointer
callback [pointer length]
release-byte-array [pointer]
```

The established one-argument controller returns a positive modeled pointer as
before. ABI v5's routing controller may instead call the borrow descriptor's
zero-argument `proceed` thunk. That exact native branch validates and locks the
live bytevector and returns its real interior address. Once a real borrow has
proceeded, the controller must return that same address; substituting a modeled
pointer is rejected before the callback.

The callback runs after the borrow handler returns. Nested `defcfn` and raw FFI
operations therefore reach the controller normally instead of re-entering the
same handler invocation. Cleanup uses the hook that issued the loan and is
attempted from the `dynamic-wind` after thunk on return, throw, or nonlocal
exit. For a proceeded real borrow the runtime owns the paired unlock: the
release observer may proceed with it, but a normal return or throw without
proceeding still forces exactly one unlock. Proceeding the release of a modeled
loan fails before Chez sees an unmatched unlock. Descriptor version 4 retains
the exact ordered 15-operation set and adds recursive foreign-function type
metadata; the separate ABI-v5
`:proceed-routing` capability describes the controller/thunk calling contract.

## Bounded continuation-safety claim

The Boolean model covers one initial pointer scope, its first exit, one later
continuation re-entry attempt, a possible backing move while unlocked, the
retired flag, before-thunk admission, callback resumption, and old-pointer
validity.

The negated corrected query asks whether the callback can resume after the
first exit while its previously computed pointer may be invalid:

```text
exit completed
AND continuation re-entry attempted
AND callback resumed
AND old pointer invalid
```

The durable models are:

- `test/chez/formal/ffi-pointer-scope-reentry-corrected.smt2`
- `test/chez/formal/ffi-pointer-scope-reentry-guard-omitted-buggy.smt2`
- `test/chez/formal/ffi-pointer-scope-reentry-nonvacuity.smt2`

`chiasmus_lint` accepted all three.

`chiasmus_verify` returned UNSAT for the corrected query. Its core included the
first exit, retirement, before guard, callback gating, violation definition,
and negated query.

The one-fault control removes only the before guard. It returned SAT with:

```clojure
{:exit-completed true
 :reentry-attempted true
 :backing-moved-after-exit true
 :callback-resumed true
 :old-pointer-valid false
 :violation true}
```

The non-vacuity control returned SAT for the initial live entry with the
callback resumed and pointer valid. The guard is therefore not a reject-all
model.

This proves only the finite transition claim above, not Chez's collector,
`dynamic-wind`, or foreign-memory implementation.

## Executable oracle

The focused Scheme gates establish the source facts abstracted by the model:

- real ranged and whole-array loans mutate the same live backing;
- the pointer stays stable across allocation and collection;
- exact-tail and whole-empty loans work;
- invalid ranges and non-byte arrays fail before the callback;
- nested same-array scopes balance reference-counted locks;
- return, exception, and nonlocal exit unlock;
- a captured continuation cannot resume a retired real or simulated pointer;
- the staged simulator protocol preserves live array identity and range;
- routing may use the real address without moving the callback inside the hook;
- real borrow plus modeled or throwing release still leaves the array unlocked;
- modeled release cannot proceed into an unmatched real unlock;
- a routing controller cannot replace a proceeded real pointer;
- nested FFI calls occur outside handler re-entry;
- nested loans release in LIFO order and callback throws still release once;
- descriptor-version 4 validation and advertised operation registries agree;
  and
- the ordinary release image contains no simulation pointer wrapper.

At this slice's focused checkpoint:

```text
make ffi                    73/73
make ffinativehook          65/65
make simcontrollerabi       64/64
make simfficontrollerabi    102/102
make ffisimhook             60/60
make ffisimflavor           21/21
make ordinaryffinosim       61/61
make simprofilesmoke        passed
self-host fixpoint          passed
```

The external `jolt-sim` gate additionally runs one ordinary `jolt.ffi` fixture
unchanged against real native memory and the modeled byte-array loan.

## Remaining limits

- A real C function that retains the pointer violates the API contract; the
  runtime cannot make that retained address safe after callback return.
- The simulator detects accesses made through its modeled operations after
  release. It cannot police raw uninstrumented host memory.
- A modeled borrow handler must return one positive fake pointer. After calling
  real `proceed`, it must return the exact proceeded pointer. Arbitrary pointer
  provenance across separate modeled and real effects is a controller-policy
  responsibility; ABI v5 directly guards only this scoped-loan boundary.
- Cleanup is attempted exactly once. A throwing release handler is reported as
  a controller failure; a real array is still unlocked, but this claim does not
  prove the handler completed its own modeled state transition. If both the
  callback and release observer throw, ordinary `dynamic-wind` semantics make
  the cleanup exception the visible one.
- Concurrent unsynchronized ordinary mutation of the loaned array remains an
  application data race. The simulator memory model makes each modeled native
  operation atomic; broader schedule control is a separate layer.
