; Counterexample query for method-name-only reify dispatch.
;
; The deliberately buggy selector consults the instance-local method table
; without first establishing that the reify declared the requested protocol.
; SAT demonstrates that a same-named method from another protocol can be
; selected.

(declare-const declares_requested_protocol Bool)
(declare-const has_same_named_local_method Bool)
(declare-const local_method_selected Bool)

(assert (! (= local_method_selected
              has_same_named_local_method)
           :named buggy_method_name_only_selector))

(assert (! (not declares_requested_protocol)
           :named requested_protocol_not_declared))
(assert (! has_same_named_local_method
           :named other_protocol_method_present))

(declare-const false_dispatch Bool)
(assert (! (= false_dispatch
              (and local_method_selected
                   (not declares_requested_protocol)))
           :named false_dispatch_definition))
(assert (! false_dispatch :named false_dispatch_query))
