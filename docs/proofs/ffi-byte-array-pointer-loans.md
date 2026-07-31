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

The simulation-only overlay in `host/chez/sim/runtime.ss` does not expose a
real address while a controller is installed. It stages two native-operation
descriptors around the unchanged callback:

```text
borrow-byte-array [same-live-array offset length] -> positive fake pointer
callback [fake-pointer length]
release-byte-array [fake-pointer]
```

The callback runs after the borrow handler returns. Nested `defcfn` and raw FFI
operations therefore reach the controller normally instead of re-entering the
same handler invocation. Cleanup uses the hook that issued the loan and is
attempted from the `dynamic-wind` after thunk on return, throw, or nonlocal
exit. The nested FFI descriptor is version 3 and advertises the exact ordered
15-operation set.

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
- nested FFI calls occur outside handler re-entry;
- nested loans release in LIFO order and callback throws still release once;
- descriptor-version 3 validation and advertised operation registries agree;
  and
- the ordinary release image contains no simulation pointer wrapper.

At this slice's focused checkpoint:

```text
make ffi                    63/63
make ffinativehook          52/52
make simcontrollerabi       60/60
make simfficontrollerabi    81/81
make ffisimhook             46/46
make ffisimflavor           19/19
make ordinaryffinosim       54/54
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
- A conforming borrow handler must return one positive fake pointer. A handler
  that allocates a loan and then returns malformed data has already violated
  the controller contract.
- Cleanup is attempted exactly once. A throwing release handler is reported as
  a controller failure; this claim does not prove the handler completed its
  own state transition.
- Concurrent unsynchronized ordinary mutation of the loaned array remains an
  application data race. The simulator memory model makes each modeled native
  operation atomic; broader schedule control is a separate layer.
