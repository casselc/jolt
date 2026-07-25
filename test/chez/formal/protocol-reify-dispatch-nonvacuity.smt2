; Non-vacuity control for exact reify protocol dispatch.
;
; SAT demonstrates that a local method remains selectable when the reify
; declares the requested canonical protocol and supplies the method.

(declare-const declares_requested_protocol Bool)
(declare-const has_same_named_local_method Bool)
(declare-const local_method_selected Bool)

(assert (! declares_requested_protocol
           :named requested_protocol_declared))
(assert (! has_same_named_local_method
           :named requested_method_present))
(assert (! (= local_method_selected
              (and declares_requested_protocol
                   has_same_named_local_method))
           :named exact_protocol_membership_selector))
(assert (! local_method_selected :named useful_local_dispatch_query))
