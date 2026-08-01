# Scoped byte-array pointers

`jolt.ffi/with-byte-array-pointer` provides a bounded, synchronous **in-out**
pointer bridge for the current v0.5.13 signed vector-backed `byte-array`.

```clojure
(ffi/with-byte-array-pointer bytes
  (fn [pointer length] ...))

(ffi/with-byte-array-pointer bytes offset length
  (fn [pointer validated-length] ...))
```

Both forms validate that `bytes` is exactly a Jolt `byte-array`, and the ranged
form validates `0 <= offset <= count` and `0 <= length <= count - offset` before
temporary allocation, locking, or callback execution. The callback receives an
integer address and an exact validated byte count.

## Ownership and lifetime

The caller owns the Jolt array. The scope allocates and owns a temporary Chez
bytevector, copies the selected signed bytes into it as octets (`byte & 0xff`),
locks that temporary for a stable address, and lends that address to native code
only during the callback's dynamic extent. On the first return, Jolt exception,
host exception, or nonlocal exit, it copies every temporary octet back to the
selected array range as a signed byte and retires/unlocks the temporary.

Native code must not retain, free, or use the pointer after the callback exits.
It is not an array-back-pointer and it is never valid for asynchronous work.
Jolt code must not mutate the loaned range during the callback: copy-back owns
that range until exit. Other ranges and other arrays are not aliased by this
temporary.

An attempted continuation re-entry after first exit fails before the callback
resumes. Nested loans of the **same** array on one owner thread are rejected:
independent snapshots would otherwise make their copy-back order lossy. Nested
loans of distinct arrays are allowed. Unsynchronized access from another thread
is outside the contract and can be overwritten by copy-back; callers must
serialize access to the loaned range.

For an empty range, the callback still receives an integer pointer and length
zero. Callers must not dereference that pointer or depend on its numeric value.

## Portable native test call

The focused gate binds the portable helper
`void *jolt_test_fill_bytes(void *, uint8_t, size_t)` and observes its real C
write only after scoped copy-back. It does not claim that the Jolt vector itself
has a C layout.

No errno/`GetLastError`/`WSAGetLastError` claim is made by this API: it performs
no native call. A callback's own FFI binding must opt into native-error capture
at that binding's return boundary when it needs an error code.
