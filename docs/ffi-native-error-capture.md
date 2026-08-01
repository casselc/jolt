# Atomic native-error capture

`jolt.ffi/foreign-fn` and `jolt.ffi/defcfn` can capture a native call's failure
code atomically, alongside its result, as a two-element Jolt vector.

## Problem

Native error slots are per-thread mutable state. POSIX functions conventionally
write `errno`; Windows functions — including Winsock — write the thread's
last-error slot (which `WSAGetLastError` reads). A *later* native call can
replace that value, so reading the slot from a separately bound accessor after
the call is only sound when nothing runs between the native return and the
accessor. That boundary is not safe for a `:blocking` foreign call: the
collect-safe thread must be reactivated before Jolt code can run the accessor,
and that return path can disturb the slot.

## Public contract

`foreign-fn` and `defcfn` accept a trailing literal options map. Its only keys
are `:blocking` and `:capture-native-error`, both literal Booleans.

```clojure
(require '[jolt.ffi :as ffi])

;; legacy scalar results are unchanged:
(ffi/defcfn c-open "open" [:string :int] :int)
(ffi/defcfn c-accept "accept" [:uptr :pointer :pointer] :int :blocking)

;; capture the native error code atomically:
(ffi/defcfn c-open-err "open" [:string :int] :int {:capture-native-error true})
(let [[result error-code] (c-open-err path flags)]
  (if (neg? result)
    (throw (ex-info "open failed" {:code error-code}))
    result))

;; composes with :blocking:
(ffi/defcfn c-accept-err "accept" [:uptr :pointer :pointer] :int
  {:blocking true :capture-native-error true})
```

Exact semantics:

- Omitting the option, the legacy `:blocking` keyword, or
  `{:capture-native-error false}` all preserve the existing **scalar** result.
- `{:capture-native-error true}` returns exactly
  `[native-result native-error-code]`, **result first**.
- The error code is meaningful only when the native API's result indicates
  failure; a native API need not clear its slot on success.
- On known POSIX targets the second element is `errno`; on known Windows targets
  it is `GetLastError` (the slot `WSAGetLastError` reads). The convention is
  selected from the compiler's target machine, not the build host, and an
  unrecognized target fails expansion rather than guessing.
- Capture occurs in Chez's foreign-call return path, before control returns to
  Scheme, so constructing the result vector cannot race with or overwrite the
  captured value.
- Capture composes with `:blocking` and preserves the binding's lazy native
  symbol resolution (the shared library may load after the binding is defined).
- `:capture-native-error true` is rejected for `:void`: there is no stable native
  result to pair with the error code.
- This option changes only the opted-in binding. It does not change the C ABI or
  the behavior of another binding for the same symbol and signature.

## What fails closed

The options map is validated at compile time, in
`jolt.analyzer/analyze-ffi-fn` — the single choke point the public macros and a
direct `jolt.ffi/__cfn` form both pass through. Each of these is a compile-time
error:

- an unknown key (`{:bogus true}`)
- a namespaced key (`{::capture-native-error true}`)
- a non-keyword key (`{"blocking" true}`)
- a non-literal-Boolean value (`{:capture-native-error "yes"}`,
  `{:blocking 1}`)
- a non-map / non-`:blocking` trailing option, or any extra trailing argument
- capture on a `:void` return

Duplicate literal keys are rejected by the reader before they can reach the
analyzer.

## Notes

This slice does not add a public accessor for the ambient error slot, a variadic
ABI boundary, aggregate ownership, scoped byte-array loans, or any simulator
ABI. Code that deliberately binds a platform-specific error accessor remains
responsible for ensuring no native or runtime work intervenes between the call
and the read. This is a usage document, not a formal proof.
