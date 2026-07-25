; Non-vacuity control for exact core interface dispatch.
;
; SAT demonstrates that the corrected selector still dispatches when the value
; implements the required interface and the method has the required shape.

(declare-const implements_required_interface Bool)
(declare-const stored_interface_id_matches_required Bool)
(declare-const has_same_method_name Bool)
(declare-const accepts_required_arity Bool)
(declare-const selected Bool)

(assert (! implements_required_interface
           :named required_interface_present))
(assert (! (= stored_interface_id_matches_required
              implements_required_interface)
           :named canonical_id_preserves_interface_identity))
(assert (! has_same_method_name
           :named required_method_name_present))
(assert (! accepts_required_arity
           :named required_method_arity_present))
(assert (! (= selected
              (and stored_interface_id_matches_required
                   has_same_method_name
                   accepts_required_arity))
           :named canonical_id_name_arity_selector))
(assert (! selected :named useful_dispatch_query))
