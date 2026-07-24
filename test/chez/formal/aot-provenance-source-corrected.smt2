; Expected result: UNSAT.
; Historical control for a rejected live-validation design. "Corrected" is
; relative to that design; this is not the accepted generation invariant.
; This is the corrected same-schema counterpart to the source-only SAT witness:
; both provenance switches are true, producer contexts are constrained equal,
; an edit without reload is required, and the same violation is queried.
;
; Observed named UNSAT core:
;   edit_without_reload_definition
;   corrected_loaded_source_provenance
;   manifest_macro_source
;   manifest_transitive_source
;   exact_source_validation
;   manifest_validation_definition
;   cache_execution_definition
;   violation_definition
;   source_only_edit_required
;   violation_query
;
; This is the exact declaration/assertion/query model linted and verified with
; Chiasmus. Chiasmus supplies check-sat/UNSAT-core extraction.

; Corrected same-schema source-mismatch control: both provenance switches true,
; producer contexts equal, edit-without-reload required, same violation query.
(declare-datatypes () ((Snapshot s0 s1)))
(declare-datatypes () ((Context checked unchecked)))
(declare-datatypes () ((Publication pub_a pub_b)))
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
(declare-const retains_loaded_source_provenance Bool)
(declare-const validates_producer_context Bool)
(assert (! (= retains_loaded_source_provenance true)
           :named corrected_loaded_source_provenance))
(assert (! (= validates_producer_context true)
           :named corrected_producer_context_validation))
(declare-const manifest_c_src Snapshot)
(declare-const manifest_m_src Snapshot)
(declare-const manifest_h_src Snapshot)
(declare-const manifest_producer_ctx Context)
(declare-const manifest_consumer_ctx Context)
(assert (! (= manifest_c_src c_capture_src) :named manifest_own_source))
(assert (! (= manifest_m_src
              (ite retains_loaded_source_provenance
                   m_loaded_src_capture m_disk_after_edit))
           :named manifest_macro_source))
(assert (! (= manifest_h_src
              (ite retains_loaded_source_provenance
                   h_loaded_src_capture h_disk_after_edit))
           :named manifest_transitive_source))
(assert (! (= manifest_producer_ctx producer_ctx_capture)
           :named latent_producer_context))
(assert (! (= manifest_consumer_ctx consumer_ctx_capture)
           :named manifest_consumer_context))
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
                   (or (not validates_producer_context)
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
(declare-const provenance_mismatch Bool)
(assert (! (= provenance_mismatch (not (= artifact_semantics current_semantics)))
           :named provenance_mismatch_definition))
(declare-const violation Bool)
(assert (! (= violation (and cache_exec provenance_mismatch))
           :named violation_definition))
(assert (! (= producer_ctx_capture producer_ctx_fresh)
           :named source_only_equal_producer_contexts))
(assert (! disk_edit_without_reload :named source_only_edit_required))
(assert (! violation :named violation_query))
