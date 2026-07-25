; Counterexample query for method-name/arity-only core interface dispatch.
;
; This deliberately buggy registry stores only a simple interface name. SAT
; demonstrates that an unrelated local protocol with the same short name and
; method shape can compare equal to the required core interface and be selected.

(declare-const implements_required_interface Bool)
(declare-const stored_interface_id_matches_required Bool)
(declare-const has_same_method_name Bool)
(declare-const accepts_required_arity Bool)
(declare-const selected Bool)

(assert (! (= selected
              (and stored_interface_id_matches_required
                   has_same_method_name
                   accepts_required_arity))
           :named buggy_stored_id_name_arity_selector))

; Pin the adversarial control: logical identities differ, but lossy short-name
; storage says they match.
(assert (! (not implements_required_interface)
           :named unrelated_protocol))
(assert (! stored_interface_id_matches_required
           :named collapsed_short_name_ids))
(assert (! has_same_method_name
           :named colliding_method_name))
(assert (! accepts_required_arity
           :named colliding_method_arity))

(declare-const false_dispatch Bool)
(assert (! (= false_dispatch
              (and selected (not implements_required_interface)))
           :named false_dispatch_definition))
(assert (! false_dispatch :named false_dispatch_query))
