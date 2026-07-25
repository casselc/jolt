; Deliberately buggy shape-first selector.
;
; Both runtime and compiler treat every jrec physical field as a public map
; entry, and every jrec receives record collection fallbacks. SAT demonstrates
; the concrete failure: a bare deftype implementing ILookup has a same-named
; physical slot, so the slot wins and its handler is bypassed.

(declare-const is_record Bool)
(declare-const explicit_field_access Bool)
(declare-const public_lookup Bool)
(declare-const key_matches_physical_field Bool)
(declare-const declares_lookup_handler Bool)

(declare-const runtime_raw_slot Bool)
(declare-const compiler_raw_slot Bool)
(declare-const lookup_handler_selected Bool)
(declare-const record_collection_fallback Bool)

(assert (! (not is_record) :named opaque_deftype))
(assert (! (not explicit_field_access) :named public_not_explicit_access))
(assert (! public_lookup :named public_lookup_attempted))
(assert (! key_matches_physical_field :named lookup_key_collides_with_slot))
(assert (! declares_lookup_handler :named declared_lookup_handler))

(assert (! (= runtime_raw_slot key_matches_physical_field)
           :named buggy_runtime_shape_first))
(assert (! (= compiler_raw_slot key_matches_physical_field)
           :named buggy_compiler_shape_first))
(assert (! (= lookup_handler_selected
              (and declares_lookup_handler (not runtime_raw_slot)))
           :named buggy_handler_only_after_slot_miss))
(assert (! record_collection_fallback
           :named buggy_every_jrec_is_record_collection))

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
(assert (! property_violated :named boundary_violation_witness))
