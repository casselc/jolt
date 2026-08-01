# Atomic native-error capture

## Bounded claim

For one opted-in, non-void `jolt.ffi` call, the returned two-element vector
contains the native result and the error-slot value captured by Chez in that
same foreign-call return path. Later Scheme or native work cannot change the
saved vector.

This is deliberately narrower than claiming that every native API sets an error
slot, clears it on success, or uses the same convention. On supported POSIX Jolt
targets the binding captures `errno`; on supported Windows Jolt targets it
captures `GetLastError`. A caller must consult the bound API's result contract
before treating the second value as meaningful.

## Live source facts

The implementation establishes these facts:

1. `jolt.analyzer/ffi-option` accepts only omission, the legacy unqualified
   `:blocking` keyword, or a literal map containing unqualified `:blocking` and
   `:capture-native-error` keys with literal Boolean values.
2. `analyze-ffi-fn` rejects capture for `:void` and records both flags in the
   ordinary FFI IR node.
3. `jolt.backend-scheme/emit-ffi-fn` leaves the scalar lowering unchanged when
   capture is false. When capture is true, it selects
   `jolt-ffi-native-error-procedure` and converts the two Scheme values into one
   result-first Jolt vector.
4. `host/chez/rt.ss` expands that procedure with Chez's `__errno` convention on
   supported POSIX targets and `__get_last_error` on supported Windows targets.
   The compiler target, rather than the build host, selects the convention.
5. Chez performs convention capture before returning control to Scheme,
   including before a collect-safe thread is reactivated. Vector construction
   therefore happens after the native result and error value are already
   ordinary Scheme values.

## Negated query and controls

The models ask for a state where the saved error differs from the value present
when the foreign call returned. SAT is a concrete stale-read witness; UNSAT says
that no such state exists in this small timing abstraction.

### Known-SAT post-hoc accessor

This control models the old pattern of calling a native function and reading the
ambient slot later:

```smt2
(declare-const call_error Int)
(declare-const later_error Int)
(declare-const saved_error Int)
(declare-const immediate_capture Bool)
(declare-const violation Bool)

(assert (! (= saved_error
              (ite immediate_capture call_error later_error))
           :named saved_error_definition))
(assert (! (= violation (not (= saved_error call_error)))
           :named violation_definition))
(assert (! (not immediate_capture) :named buggy_posthoc_capture))
(assert (! (= call_error 0) :named call_value))
(assert (! (= later_error 1) :named later_overwrite))
(assert (! violation :named query_stale_capture))
```

`chiasmus_lint` returned no errors. `chiasmus_verify` returned SAT with
`call_error=0`, `later_error=1`, `saved_error=1`, and `violation=true`.

### Corrected foreign-return capture

Replacing `buggy_posthoc_capture` with:

```smt2
(assert (! immediate_capture :named corrected_immediate_capture))
```

returned UNSAT. The core was:

```text
saved_error_definition
violation_definition
corrected_immediate_capture
query_stale_capture
```

### Non-vacuity

Constraining `call_error=2`, `later_error=9`, and `immediate_capture=true`
returned SAT with `saved_error=2` and `violation=false`. The corrected model can
represent a real captured failure while permitting later mutation.

### Fail-closed option boundary

A second Boolean model defines `violation = invalid_options AND accepted`.
The fail-open control (`invalid_options=true`, `accepted=true`) returned SAT.
The corrected constraint `accepted = NOT invalid_options`, with the same
violation query, returned UNSAT. Non-vacuity controls returned SAT for a valid
captured Windows binding (pair result plus last-error convention) and for a
valid non-capturing unknown-target binding (scalar result and no error
convention). This establishes only the dispatch contract, not parser
correctness; the executable gate below is the parser oracle.

## Executable oracle

`test/chez/ffi-scalar-helper.c` writes a known native error and returns a failure
sentinel through the platform's default C ABI. `test/chez/ffi-binding-test.ss`
checks:

- direct `__cfn`, public `foreign-fn`, and public `defcfn` capture;
- exact `[native-result error-code]` ordering;
- composition with `:blocking`;
- persistence after a later helper overwrites the same thread's slot;
- unchanged scalar behavior for omitted, empty, legacy `:blocking`, and false
  capture options;
- rejection of unknown, namespaced, duplicate, non-keyword, nonliteral, and
  non-Boolean options; and
- rejection of captured `:void` bindings.

Run the focused oracle serially with pinned Chez 10.4.1:

```sh
make -j1 ffi
```

The same helper and Scheme gate are also run natively on local x64 Windows.

## Remaining gaps

This is not a proof of a native library's documented failure conditions, the
meaning of an error slot after success, signal-handler behavior, or every Chez
target. Portable-bytecode and unrecognized targets fail expansion when capture
is requested because their operating-system error convention cannot be inferred
from the machine type. No simulator hook or ambient public error accessor is
introduced by this slice.
