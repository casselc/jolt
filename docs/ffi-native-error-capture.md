# Atomic native-error capture

## Problem

Native error slots are per-thread, mutable state. POSIX functions conventionally
write `errno`; Windows functions, including Winsock, write the thread's last-error
slot. Any later native call can replace that value.

Calling `jolt.ffi/errno` immediately after a foreign call is sufficient only
when the complete return boundary guarantees that nothing runs between the
native return and the accessor. A `:blocking` foreign call demonstrably lacks
that guarantee because Chez must reactivate a collect-safe Scheme thread before
Jolt code can invoke the accessor. Native Windows jolt-net validation found the
broader rule: after blocking `connect` was paired, the first ordinary duplicate
`bind` still exposed a zero last-error while a later attempt happened to retain
`10048`. Call kind and source-level adjacency are therefore not a sound
classification boundary.

## Public contract

`jolt.ffi/foreign-fn` and `jolt.ffi/defcfn` accept the literal option
`:capture-native-error`:

```clojure
(ffi/defcfn connect-with-error
  "connect" [:uptr :pointer :int] :int
  {:blocking true :capture-native-error true})

(let [[result error-code] (connect-with-error socket address address-len)]
  (if (neg? result)
    (throw (ex-info "connect failed" {:code error-code}))
    result))
```

The option has these exact semantics:

- Its value must be the literal Boolean `true` or `false`.
- `false`, omission, and the legacy `:blocking` option preserve the existing
  scalar return value.
- `true` returns a two-element Jolt vector `[native-result error-code]`.
- The error code is meaningful only when the native API's result indicates
  failure. Callers must ignore it on success; native APIs need not clear their
  error slot after a successful call.
- On POSIX, the second element is the `errno` captured by Chez's `__errno`
  foreign-procedure convention.
- On Windows, the second element is the value captured by Chez's
  `__get_last_error` convention. This is the value observed as a Winsock
  `WSAGetLastError` code by the native Windows socket probe.
- Capture occurs in Chez's foreign-call return path, before control returns to
  Scheme. Constructing the result vector therefore cannot race with or clobber
  the captured value.
- The option composes with `:blocking true` and `:varargs-after`.
- A `:void` binding is rejected. Exposing Chez's unspecified void result as the
  first vector element would not be a stable Jolt contract.

This option changes only the opted-in binding. It does not alter the C ABI or the
behavior of other bindings for the same symbol.

## Ordering invariant

Assume the native function returns result `r` after setting its documented
thread-local error slot to `e`. An opted-in binding returns `[r e]` even if later
runtime or cleanup work changes the slot.

The argument is bounded to the call boundary:

1. Chez's `__errno`/`__get_last_error` convention reads the slot before the
   foreign call returns to Scheme.
2. Both values are passed to the generated two-argument continuation.
3. The continuation constructs the persistent Jolt vector.
4. Later native calls can mutate the thread-local slot, but not either value
   already stored in that vector.

The Linux regression control first obtains `[-1 2]` from a failing `open`, then
executes `close(-1)`, which changes current `errno` to `9`; the saved vector
remains `[-1 2]`. The collect-safe control obtains `[-1 9]` directly from an
opted-in `:blocking` call. This proves ordering under Chez's documented capture
semantics; it cannot prove that a particular C API sets its documented error
channel correctly. The jolt-net Windows W1 gate supplies the complementary
native evidence: one process preserves exact `WSAECONNREFUSED` `10061` and
first-attempt `WSAEADDRINUSE` `10048` only after both calls consume captured
pairs.

## Cross-target selection invariant

The capture convention must describe the generated program's target, not the
machine running the compiler:

- a Windows target must expand the opted-in binding with
  `__get_last_error`; and
- a POSIX target must expand it with `__errno`.

This distinction matters when Jolt cross-compiles through Chez's `xpatch`.
Chez's `(machine-type)` continues to describe the build host, while the
compiler parameter `$target-machine` is rebound to the requested target around
source expansion and compilation. The selector therefore reads
`#%$target-machine` at macro-expansion time.

The deterministic controls parameterize the compiler target to `ta6nt` and
`ta6le` in the same test process. They assert selection of
`__get_last_error` and `__errno`, respectively. Because neither control derives
its expected value from `(machine-type)`, together they cover the two failure
shapes: Linux-host to Windows-target accidentally retaining `__errno`, and
Windows-host to Linux-target accidentally emitting the Windows-only
convention.

## Choosing between the two APIs

Use `{:capture-native-error true}` whenever a caller interprets a native failure
sentinel and needs its associated error code. This is mandatory independently
of `:blocking`; a separate source-level accessor is not part of the same result.

`jolt.ffi/errno` remains available for code that must inspect the current slot
independently of a particular call. Its caller is responsible for ensuring that
no native or runtime work has intervened.

A function should keep an ordinary scalar binding only when its return value
fully identifies the outcome. `WSAStartup` is the representative case: its
nonzero return is itself the Winsock error and no last-error read is required.

`getaddrinfo` is subtler. Its normal failures are returned directly as
`EAI_*`, but POSIX `EAI_SYSTEM` delegates the underlying cause to `errno`.
Therefore a blocking `getaddrinfo` caller that preserves `EAI_SYSTEM` detail
must use the captured pair and consult its second element only for that return
code. Windows has no `EAI_SYSTEM`, so the captured slot is ignored there.

Downstream dispatch should keep scalar and captured calls structurally
distinct. One wrapper must not return a scalar for some operation names and a
pair for others; use, for example, separate `invoke` and `invoke-captured`
surfaces whose result shapes are invariant.

## Chez requirement

The implementation relies on the `__errno` and `__get_last_error`
foreign-procedure conventions added in Chez Scheme 10.4.0. The supported Jolt
toolchain uses Chez 10.4.1.
