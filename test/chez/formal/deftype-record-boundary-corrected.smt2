; Counterexample query for the public deftype/defrecord boundary.
;
; A jrec is a physical representation shared by deftype and defrecord. Public
; lookup may select a physical slot only for a defrecord; an explicit .-field
; form is the separate internal path available to both. Record-style collection
; fallbacks (count/contains/assoc/dissoc/conj) are likewise record-only. The
; compiler selector must agree with the runtime selector.

(declare-const is_record Bool)
(declare-const explicit_field_access Bool)
(declare-const public_lookup Bool)
(declare-const key_matches_physical_field Bool)
(declare-const declares_lookup_handler Bool)

(declare-const runtime_raw_slot Bool)
(declare-const compiler_raw_slot Bool)
(declare-const lookup_handler_selected Bool)
(declare-const record_collection_fallback Bool)

(assert (! (not (and explicit_field_access public_lookup))
           :named explicit_and_public_forms_are_disjoint))
(assert (! (= runtime_raw_slot
              (and is_record
                   public_lookup
                   key_matches_physical_field))
           :named runtime_raw_slot_is_record_only))
(assert (! (= compiler_raw_slot
              (or (and explicit_field_access
                       key_matches_physical_field)
                  (and is_record
                       public_lookup
                       key_matches_physical_field)))
           :named compiler_raw_slot_matches_public_boundary))
(assert (! (= lookup_handler_selected
              (and public_lookup
                   (not is_record)
                   declares_lookup_handler))
           :named opaque_deftype_uses_declared_lookup))
(assert (! (= record_collection_fallback is_record)
           :named collection_fallback_is_record_only))

(declare-const private_slot_leak Bool)
(declare-const lookup_handler_bypassed Bool)
(declare-const collection_shape_fabricated Bool)
(declare-const property_violated Bool)

(assert (! (= private_slot_leak
              (and public_lookup
                   (not is_record)
                   (or runtime_raw_slot compiler_raw_slot)))
           :named private_slot_leak_definition))
(assert (! (= lookup_handler_bypassed
              (and public_lookup
                   (not is_record)
                   declares_lookup_handler
                   key_matches_physical_field
                   (not lookup_handler_selected)))
           :named lookup_handler_bypass_definition))
(assert (! (= collection_shape_fabricated
              (and (not is_record) record_collection_fallback))
           :named collection_shape_fabrication_definition))
(assert (! (= property_violated
              (or private_slot_leak
                  lookup_handler_bypassed
                  collection_shape_fabricated))
           :named boundary_violation_definition))
(assert (! property_violated :named boundary_counterexample_query))
