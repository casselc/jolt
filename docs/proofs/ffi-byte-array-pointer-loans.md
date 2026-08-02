# Scoped byte-array pointer loan: bounded note

## Claim and boundary

For one valid scope and one attempted continuation re-entry after its first
exit, the callback cannot resume with the retired temporary pointer or execute a
second copy-back. This is a bounded source-order claim, not a proof of Chez's
collector or of arbitrary C code honoring the non-retention contract.

The implementation validates before allocating/locking, sets `retired?` in the
first exit cleanup, and rejects from the `dynamic-wind` before thunk. The same
cleanup copies the fixed-length temporary bytevector back to the selected signed
vector range and unlocks the temporary. On supported paths those fixed-range
operations are total; an internal cleanup invariant failure surfaces rather
than being silently converted into callback success.

## Executable witnesses

`test/chez/ffi-binding-test.ss`, run with `make -j1 ffi`, exercises:

- signed-byte in-out copyback after an actual portable C helper call;
- whole and ranged arities, whole/exact-tail empty ranges, invalid kind/range before
  callback, and stable temporary address through collection;
- normal result, Jolt exception, host exception, and nonlocal exit copyback;
- rejected same-owner-thread array nesting, successful cross-array nesting, and
  owner-tag rejection of an inherited active-loan cell; and
- continuation re-entry rejected before callback resumption or second copyback.

The tests establish these concrete paths only. C retention and concurrent
unsynchronized access remain outside this bounded note.
