; Non-vacuity control for the corrected deftype/defrecord boundary.
;
; One model contains three independent useful paths: a record public field
; lookup, a bare deftype's declared ILookup whose key collides with a physical
; slot, and an explicit field read on that deftype. SAT shows the correction
; preserves all three rather than disabling slot access or custom lookup.

(declare-const record_public_slot Bool)
(declare-const deftype_public_slot Bool)
(declare-const deftype_lookup_handler Bool)
(declare-const deftype_explicit_slot Bool)
(declare-const record_collection_fallback Bool)
(declare-const deftype_collection_fallback Bool)

(assert (! (= record_public_slot (and true true true))
           :named record_public_selector))
(assert (! (= deftype_public_slot (and false true true))
           :named deftype_public_selector))
(assert (! (= deftype_lookup_handler (and true (not false)))
           :named deftype_lookup_selector))
(assert (! (= deftype_explicit_slot (and true true))
           :named explicit_field_selector))
(assert (! (= record_collection_fallback true)
           :named record_collection_selector))
(assert (! (= deftype_collection_fallback false)
           :named deftype_collection_selector))

(assert (! record_public_slot :named record_field_remains_useful))
(assert (! (not deftype_public_slot) :named deftype_slot_remains_private))
(assert (! deftype_lookup_handler :named declared_lookup_remains_useful))
(assert (! deftype_explicit_slot :named explicit_field_remains_useful))
(assert (! record_collection_fallback :named record_collection_remains_useful))
(assert (! (not deftype_collection_fallback)
           :named opaque_deftype_has_no_record_fallback))
