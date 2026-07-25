; Counterexample query for exact reify protocol dispatch.
;
; The corrected selector gates the compact method-name table by membership of
; the requested canonical protocol in the reify's declaration set. UNSAT means
; an undeclared protocol cannot select a same-named local method in this
; complete Boolean domain.

(declare-const declares_requested_protocol Bool)
(declare-const has_same_named_local_method Bool)
(declare-const local_method_selected Bool)

(assert (! (= local_method_selected
              (and declares_requested_protocol
                   has_same_named_local_method))
           :named exact_protocol_membership_selector))

(declare-const false_dispatch Bool)
(assert (! (= false_dispatch
              (and local_method_selected
                   (not declares_requested_protocol)))
           :named false_dispatch_definition))
(assert (! false_dispatch :named false_dispatch_counterexample_query))
