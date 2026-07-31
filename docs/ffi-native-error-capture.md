# Atomic native-error capture

## Problem

Native error slots are per-thread mutable state. POSIX functions conventionally
write `errno`; Windows functions, including Winsock, write the thread's
last-error slot. A later native call can replace that value.

Calling a separately bound native error accessor after an ordinary foreign call
is safe only when nothing runs between the native return and the accessor. It is
not a sound boundary for a `:blocking` foreign call: Chez must reactivate a
collect-safe Scheme thread before Jolt code can invoke the accessor, and that
return path can disturb the Windows last-error slot.

## Public contract

`jolt.ffi/foreign-fn` and `jolt.ffi/defcfn` accept a literal options map:

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

- The only options in this slice are `:blocking` and
  `:capture-native-error`; both values must be literal Booleans.
- `false`, omission, and the legacy `:blocking` option preserve the existing
  scalar return value.
- `true` returns a two-element Jolt vector `[native-result error-code]`.
- The error code is meaningful only when the native API's result indicates
  failure. A native API need not clear its error slot on success.
- On known POSIX targets, the second element is `errno`, captured through
  Chez's `__errno` foreign-procedure convention.
- On known Windows targets, the second element is `GetLastError`, captured
  through Chez's `__get_last_error` convention. Winsock exposes this same slot
  through `WSAGetLastError`.
- Capture occurs in Chez's foreign-call return path, before control returns to
  Scheme. Constructing the Jolt result vector therefore cannot race with or
  overwrite the captured value.
- The option composes with `:blocking true`.
- A `:void` captured binding is rejected because Chez's unspecified void
  result is not a stable first vector element.

This option changes only the opted-in binding. It does not change the C ABI or
the behavior of another binding for the same native symbol and signature.

Variadic boundaries, aggregate arguments, and scoped byte-array loans are
separate FFI slices. This contract does not claim those features until their
v0.5.11 remints land.

## Target selection

The capture convention describes the generated program's target, not the
machine running the compiler. Chez's `(machine-type)` continues to describe the
build host during `xpatch` cross compilation, while `#%$target-machine` is
rebound to the requested target.

The selector therefore reads `#%$target-machine` at macro-expansion time:

- every target in Jolt's exact Windows allowlist selects
  `__get_last_error`;
- every target in its exact Linux/macOS allowlist selects `__errno`; and
- an unrecognized or portable-bytecode target fails expansion instead of
  defaulting to a nearby platform.

The deterministic gate parameterizes both known target families and an unknown
target in one Chez process. It proves compiler selection, not execution on
every target. Native Windows execution remains a separate platform gate.

## Simulation contract

An instrumented binding still chooses its installed controller before forcing
the lazy native procedure. The established one-argument controller returns the
complete public binding value:

- a scalar for an ordinary binding; or
- `[native-result error-code]` for a captured binding.

ABI v4 additionally exposes a two-argument routing controller. Its second
argument is a scoped `proceed` thunk for the exact lazy native branch; for a
captured binding that branch still collects `[native-result error-code]`
atomically before returning to the controller. The thunk is single-use,
dynamic-extent-only, and bound to the controller thread.

Nested FFI descriptor version 2 introduced the exact Boolean
`:capture-native-error?` field, and descriptor version 3 retains it unchanged.
Handler identity includes that field, so scalar and captured bindings with
otherwise identical symbol, type, and blocking metadata cannot collide. ABI v4
changes the controller calling convention without changing descriptor-v3 maps.

The separate external `jolt-sim` adapter accepts the prior descriptor version
as capture disabled, preserves the original descriptor in effect traces, and
validates that a captured handler returns a two-element vector. The core
projector itself emits and validates only its current descriptor version.
Simulation does not read the host OS error slot.

## Ordering invariant

Assume a native function returns result `r` after setting its documented
thread-local error slot to `e`. A captured binding returns `[r e]` even if later
runtime or cleanup work changes that slot:

1. Chez's `__errno` or `__get_last_error` convention reads the slot before the
   foreign call returns to Scheme.
2. Both values enter the generated two-argument continuation.
3. The continuation constructs the persistent Jolt vector.
4. Later native calls may mutate the thread-local slot, but cannot mutate
   either value already stored in the vector.

The executable Linux control obtains `[-1 2]` from a failing `open`, executes a
later failing `close` that changes current `errno`, and requires the saved
vector to remain `[-1 2]`. A collect-safe control exercises the same capture
path on a blocking binding. These controls establish the boundary ordering
under Chez's conventions; they cannot prove that every C API sets its
documented error channel correctly.

This slice does not add a public accessor for the current ambient error slot.
Code that deliberately binds such a platform-specific accessor remains
responsible for ensuring no native or runtime work intervenes.

## Chez requirement

The implementation relies on `__errno` and `__get_last_error`, added to Chez's
foreign-procedure conventions in Chez Scheme 10.4.0. Jolt's selected toolchain
uses Chez 10.4.1.
