; Counterexample query for exact core interface dispatch.
;
; The corrected registry preserves canonical identity: its stored-id comparison
; agrees with logical interface identity. The selector then requires that id,
; method name, and exact callable arity. UNSAT means it cannot select a
; same-shaped method from an unrelated protocol in this complete Boolean domain.

(declare-const implements_required_interface Bool)
(declare-const stored_interface_id_matches_required Bool)
(declare-const has_same_method_name Bool)
(declare-const accepts_required_arity Bool)
(declare-const selected Bool)

(assert (! (= stored_interface_id_matches_required
              implements_required_interface)
           :named canonical_id_preserves_interface_identity))
(assert (! (= selected
              (and stored_interface_id_matches_required
                   has_same_method_name
                   accepts_required_arity))
           :named canonical_id_name_arity_selector))

(declare-const false_dispatch Bool)
(assert (! (= false_dispatch
              (and selected (not implements_required_interface)))
           :named false_dispatch_definition))
(assert (! false_dispatch :named false_dispatch_counterexample_query))
