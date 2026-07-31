# FFI native-error capture boundary

## Bounded claim

For one `jolt.ffi` foreign call, over:

```text
target    in {known POSIX, known Windows, unknown}
execution in {native, simulated}
capture   in {false, true}
```

the corrected boundary has no modeled case where its public result shape or
native-error convention differs from this contract:

| Capture | Target | Execution | Public result | Native convention |
| --- | --- | --- | --- | --- |
| false | any | either | scalar | none |
| true | known POSIX | native | pair | `__errno` |
| true | known Windows | native | pair | `__get_last_error` |
| true | known target | simulated | pair | none |
| true | unknown | either | compile rejection | none |

The simulated row assumes a conforming handler supplies the complete public
pair. The executable `jolt-sim` adapter separately checks that shape.

This is not a proof of C API behavior, Chez's implementation, handler
termination, thread-local storage, memory safety, arbitrary targets, or a
caller interpreting a failure sentinel correctly.

## Live source facts

The model is derived from these implementation boundaries:

1. `jolt.analyzer/analyze-ffi-fn` admits only literal Boolean
   `:capture-native-error`, rejects captured `:void`, and records the mode in
   the FFI IR node.
2. `jolt.backend-scheme/emit-ffi-fn` selects the installed simulation hook
   before forcing the lazy foreign procedure. A hook returns one complete Jolt
   value. Only the native capture branch uses `call-with-values`.
3. `jolt-ffi-native-error-procedure` selects an exact error convention from
   `#%$target-machine`; its convention selector rejects unknown targets.
4. `jolt-ffi-make-sim-descriptor` records capture mode, and
   `jolt-sim-ffi-project-descriptor` projects it as
   `:capture-native-error?`.
5. `jolt-sim` includes capture mode in canonical handler identity and requires
   a captured handler result to be a two-element vector.

## Negated query

The result and convention flags are defined bidirectionally. The query asks for
one concrete input where either observed value differs from the contract.

```smt2
(declare-datatypes () ((Target posix windows unknown)))
(declare-datatypes () ((Execution native simulated)))
(declare-datatypes () ((ResultShape scalar pair rejected)))
(declare-datatypes ()
  ((ErrorConvention errno get_last_error no_convention)))
(declare-const target Target)
(declare-const execution Execution)
(declare-const capture Bool)
(declare-const capture_in_handler_key Bool)
(declare-const expected_shape ResultShape)
(declare-const observed_shape ResultShape)
(declare-const expected_convention ErrorConvention)
(declare-const observed_convention ErrorConvention)
(declare-const violation Bool)

(assert (! (= expected_shape
              (ite capture
                   (ite (= target unknown) rejected pair)
                   scalar))
           :named expected_public_shape))
(assert (! (= observed_shape
              (ite (and capture
                        (= execution simulated)
                        (not capture_in_handler_key))
                   scalar
                   expected_shape))
           :named corrected_observed_shape))
(assert (! (= expected_convention
              (ite (and capture (= execution native))
                   (ite (= target windows)
                        get_last_error
                        (ite (= target posix)
                             errno
                             no_convention))
                   no_convention))
           :named expected_error_convention))
(assert (! (= observed_convention
              (ite (and capture (= execution native))
                   (ite (= target windows)
                        get_last_error
                        (ite (= target posix)
                             errno
                             no_convention))
                   no_convention))
           :named observed_target_selector))
(assert (! (= violation
              (or (not (= observed_shape expected_shape))
                  (not (= observed_convention expected_convention))))
           :named violation_definition))
(assert (! violation :named query_contract_violation))
```

`chiasmus_lint` reported no structural errors for either control.

## Known-SAT collision control

The buggy control fixes `capture_in_handler_key` to false and constrains the
target to a known family:

```smt2
(assert (! (= capture_in_handler_key false)
           :named buggy_key_omits_capture))
(assert (! (not (= target unknown))
           :named buggy_witness_uses_known_target))
```

`chiasmus_verify` returned SAT:

```clojure
{:target :windows
 :execution :simulated
 :capture true
 :capture-in-handler-key false
 :expected-shape :pair
 :observed-shape :scalar
 :expected-convention :none
 :observed-convention :none
 :violation true}
```

This is the modeled collision that would result from adding capture mode while
retaining the prior five-field handler identity: a scalar and captured binding
could select the same scalar handler.

## Corrected model

The corrected control changes only the handler identity fact:

```smt2
(assert (! (= capture_in_handler_key true)
           :named corrected_key_includes_capture))
```

`chiasmus_verify` returned UNSAT. Its core contained:

```text
corrected_key_includes_capture
corrected_observed_shape
expected_error_convention
observed_target_selector
violation_definition
query_contract_violation
```

The bounded interpretation is only that no input in the finite table can
violate the modeled result-shape or convention contract after capture mode
becomes part of handler identity.

## Non-vacuity

A separate satisfiable boundary control required all of these cases
simultaneously:

```clojure
{:ordinary-result :scalar
 :posix-native-result :pair
 :posix-native-convention :errno
 :windows-native-result :pair
 :windows-native-convention :get-last-error
 :simulated-captured-result :pair
 :simulated-native-convention :none
 :unknown-captured-result :rejected
 :ordinary-key-capture false
 :captured-key-capture true}
```

`chiasmus_verify` returned SAT and retained distinct ordinary/captured handler
keys. The corrected model is therefore not a reject-all or scalar-only model.

## Executable oracle

The Scheme and Jolt gates must establish the facts abstracted by the model:

- legacy omitted, explicit false, and `:blocking` bindings stay scalar;
- malformed, duplicate, non-Boolean, unknown, and captured-void options fail;
- POSIX and Windows target parameterizations choose their exact conventions,
  while an unknown target fails expansion;
- a failing native call returns its result and error atomically, and later
  cleanup cannot mutate the saved pair;
- collect-safe capture returns the same public shape;
- a simulated captured ghost symbol never resolves natively and receives the
  controller's pair as one Jolt value;
- scalar and captured descriptors with otherwise identical metadata select
  distinct canonical handlers; and
- a malformed captured handler result is latched and fails the controlled run.

The focused acceptance commands are recorded with the landing commit and rebase
report after the generated seed and downstream adapter are synchronized.

## Remaining gaps

The model does not cover variadic ABI boundaries, aggregate ownership, scoped
byte-array loans, callback error channels, Windows runtime execution, or
per-API rules such as Winsock functions that return an error code directly.
Those remain separate gates. In particular, `getaddrinfo` normally returns its
own status, but POSIX `EAI_SYSTEM` delegates additional detail to `errno`; a
binding must follow the documented contract of the specific API.
