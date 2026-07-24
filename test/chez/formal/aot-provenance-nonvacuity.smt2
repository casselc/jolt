; Expected result: SAT.
; Historical non-vacuity control for a rejected live-validation design. It is
; not the accepted generation invariant.
; This is not the violating SAT control. It requires a valid corrected warm hit
; at the maximum five-bit semantic value and proves the corrected model does not
; obtain UNSAT merely by making all cache execution unreachable.
;
; Observed model:
;   cache_exec=true
;   artifact_semantics=31
;   current_semantics=31
;   provenance_mismatch=false
;   violation=false
;
; This is the exact declaration/assertion/query model linted and verified with
; Chiasmus. Chiasmus supplies check-sat/model extraction.

; Non-vacuity/boundary control for the corrected AOT provenance model.
; Same schema and definitions as the violation query; instead of asserting a
; violation, require a valid cache execution at the maximum 5-bit semantic value.

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
(declare-const provenance_mismatch Bool)
(assert (! (= provenance_mismatch (not (= artifact_semantics current_semantics)))
           :named provenance_mismatch_definition))
(declare-const violation Bool)
(assert (! (= violation (and cache_exec provenance_mismatch))
           :named violation_definition))

; Boundary and reachability assertions: all source/context bits are at their high
; constructor, the matching publication is loaded, and a correct warm hit occurs.
(assert (! (= c_capture_src s1) :named boundary_c_source))
(assert (! (= m_loaded_src_capture s1) :named boundary_m_source))
(assert (! (= h_loaded_src_capture s1) :named boundary_h_source))
(assert (! (= producer_ctx_capture unchecked) :named boundary_producer_context))
(assert (! (= consumer_ctx_capture unchecked) :named boundary_consumer_context))
(assert (! (= c_disk_fresh s1) :named boundary_current_c_source))
(assert (! (= m_disk_after_edit s1) :named boundary_current_m_source))
(assert (! (= h_disk_after_edit s1) :named boundary_current_h_source))
(assert (! (= producer_ctx_fresh unchecked)
           :named boundary_current_producer_context))
(assert (! (= consumer_ctx_fresh unchecked)
           :named boundary_current_consumer_context))
(assert (! (= loaded_publication pub_a) :named boundary_same_publication))
(assert (! cache_exec :named nonvacuous_valid_warm_hit))
(assert (! (= artifact_semantics 31) :named artifact_semantic_upper_boundary))
(assert (! (= current_semantics 31) :named current_semantic_upper_boundary))
(assert (! (not violation) :named valid_hit_is_not_violation))
