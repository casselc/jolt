; Expected result: UNSAT.
; Historical control for a rejected live-validation design. "Corrected" is
; relative to that design; this is not the accepted generation invariant.
; Interpretation: no counterexample exists within this bounded corrected model.
; This does not constitute an unrestricted proof of the loader.
;
; Observed named UNSAT core:
;   manifest_own_source
;   manifest_macro_source
;   manifest_transitive_source
;   latent_producer_context
;   manifest_consumer_context
;   corrected_context_carrying_closure
;   exact_source_validation
;   compiler_context_validation
;   manifest_validation_definition
;   cache_execution_definition
;   artifact_semantics_definition
;   current_semantics_definition
;   semantic_value_bounds
;   provenance_mismatch_definition
;   violation_definition
;   violation_query
;
; This is the exact declaration/assertion/query model linted and verified with
; Chiasmus. Chiasmus supplies check-sat/UNSAT-core extraction.

; Corrected control: the same bounded AOT provenance violation query and schema
; as the v3 witness. The corrected model retains both the loaded-source closure
; actually used by the producer and its producer compiler context, then validates
; both rather than substituting current disk/source or consumer context.

(declare-datatypes () ((Snapshot s0 s1)))
(declare-datatypes () ((Context checked unchecked)))
(declare-datatypes () ((Publication pub_a pub_b)))
(declare-const capture_m_step Int)
(declare-const capture_c_step Int)
(declare-const publish_c_step Int)
(declare-const edit_step Int)
(declare-const fresh_load_m_step Int)
(declare-const validate_and_load_c_step Int)
(assert (! (= capture_m_step 0) :named trace_capture_m))
(assert (! (= capture_c_step 1) :named trace_capture_c))
(assert (! (= publish_c_step 2) :named trace_publish_c))
(assert (! (= edit_step 3) :named trace_optional_edit))
(assert (! (= fresh_load_m_step 4) :named trace_fresh_load_m))
(assert (! (= validate_and_load_c_step 5) :named trace_validate_load_c))
(declare-const c_capture_src Snapshot)
(declare-const m_loaded_src_capture Snapshot)
(declare-const h_loaded_src_capture Snapshot)
(declare-const producer_ctx_capture Context)
(declare-const consumer_ctx_capture Context)
(declare-const c_disk_fresh Snapshot)
(declare-const m_disk_after_edit Snapshot)
(declare-const h_disk_after_edit Snapshot)
(declare-const producer_ctx_fresh Context)
(declare-const consumer_ctx_fresh Context)
(declare-const producer_already_loaded_capture Bool)
(declare-const disk_edit_without_reload Bool)
(declare-const fresh_process Bool)
(declare-const published Bool)
(assert (! producer_already_loaded_capture :named producer_was_preloaded))
(assert (! fresh_process :named second_process_is_fresh))
(assert (! published :named consumer_was_published))
(assert (! (= disk_edit_without_reload
              (and producer_already_loaded_capture
                   (or (not (= m_disk_after_edit m_loaded_src_capture))
                       (not (= h_disk_after_edit h_loaded_src_capture)))))
           :named edit_without_reload_definition))
(declare-const manifest_c_src Snapshot)
(declare-const manifest_m_src Snapshot)
(declare-const manifest_h_src Snapshot)
(declare-const manifest_producer_ctx Context)
(declare-const manifest_consumer_ctx Context)
(declare-const tracks_producer_context Bool)
(assert (! (= manifest_c_src c_capture_src) :named manifest_own_source))
(assert (! (= manifest_m_src m_loaded_src_capture) :named manifest_macro_source))
(assert (! (= manifest_h_src h_loaded_src_capture)
           :named manifest_transitive_source))
(assert (! (= manifest_producer_ctx producer_ctx_capture)
           :named latent_producer_context))
(assert (! (= manifest_consumer_ctx consumer_ctx_capture)
           :named manifest_consumer_context))
(assert (! (= tracks_producer_context true)
           :named corrected_context_carrying_closure))
(declare-const selected_publication Publication)
(declare-const loaded_publication Publication)
(assert (! (= selected_publication pub_a) :named caller_selected_publication_a))
(declare-const source_validation Bool)
(assert (! (= source_validation
              (and (= manifest_c_src c_disk_fresh)
                   (= manifest_m_src m_disk_after_edit)
                   (= manifest_h_src h_disk_after_edit)))
           :named exact_source_validation))
(declare-const context_validation Bool)
(assert (! (= context_validation
              (and (= manifest_consumer_ctx consumer_ctx_fresh)
                   (or (not tracks_producer_context)
                       (= manifest_producer_ctx producer_ctx_fresh))))
           :named compiler_context_validation))
(declare-const manifest_valid Bool)
(assert (! (= manifest_valid
              (and published fresh_process source_validation context_validation))
           :named manifest_validation_definition))
(declare-const caller_guard_pass Bool)
(assert (! (= caller_guard_pass (= selected_publication loaded_publication))
           :named caller_bound_guard_definition))
(declare-const cache_exec Bool)
(assert (! (= cache_exec (and manifest_valid caller_guard_pass))
           :named cache_execution_definition))
(declare-const artifact_semantics Int)
(assert (! (= artifact_semantics
              (+ (ite (= c_capture_src s1) 16 0)
                 (ite (= m_loaded_src_capture s1) 8 0)
                 (ite (= h_loaded_src_capture s1) 4 0)
                 (ite (= producer_ctx_capture unchecked) 2 0)
                 (ite (= consumer_ctx_capture unchecked) 1 0)))
           :named artifact_semantics_definition))
(declare-const current_semantics Int)
(assert (! (= current_semantics
              (+ (ite (= c_disk_fresh s1) 16 0)
                 (ite (= m_disk_after_edit s1) 8 0)
                 (ite (= h_disk_after_edit s1) 4 0)
                 (ite (= producer_ctx_fresh unchecked) 2 0)
                 (ite (= consumer_ctx_fresh unchecked) 1 0)))
           :named current_semantics_definition))
(assert (! (and (<= 0 artifact_semantics) (<= artifact_semantics 31)
                (<= 0 current_semantics) (<= current_semantics 31))
           :named semantic_value_bounds))
(declare-const provenance_mismatch Bool)
(assert (! (= provenance_mismatch (not (= artifact_semantics current_semantics)))
           :named provenance_mismatch_definition))
(declare-const violation Bool)
(assert (! (= violation (and cache_exec provenance_mismatch))
           :named violation_definition))
(assert (! violation :named violation_query))
