; Expected result: SAT.
; Historical non-vacuity control for a rejected live-revalidation design. It is
; not the accepted generation invariant.
; Boundary/non-vacuity control for the corrected temporal model. It selects the
; second value of every finite identity, keeps both forms, validation, and
; execution coherent, and requires both publication and a real warm execution.
; This is not a violating SAT control.
;
; Observed witness:
;   capture_publish=true, manifest_selected=true, warm_exec=true
;   capture_violation=false, warm_violation=false, violation=false
;
; Chiasmus supplies check-sat/model extraction.

(declare-datatypes () ((CompilerContext ctx0 ctx1)))
(declare-datatypes () ((ReaderIdentity readers0 readers1)))
(declare-datatypes () ((Publication pub0 pub1)))

(declare-const capture_start_step Int)
(declare-const compile_form_1_step Int)
(declare-const compile_form_2_step Int)
(declare-const publish_step Int)
(declare-const validate_step Int)
(declare-const execute_first_form_step Int)
(assert (! (= capture_start_step 0) :named trace_capture_start))
(assert (! (= compile_form_1_step 1) :named trace_compile_form_1))
(assert (! (= compile_form_2_step 2) :named trace_compile_form_2))
(assert (! (= publish_step 3) :named trace_publish))
(assert (! (= validate_step 4) :named trace_validate))
(assert (! (= execute_first_form_step 5) :named trace_execute_first_form))

(declare-const capture_context CompilerContext)
(declare-const capture_readers ReaderIdentity)
(declare-const form_1_context CompilerContext)
(declare-const form_1_readers ReaderIdentity)
(declare-const form_2_context CompilerContext)
(declare-const form_2_readers ReaderIdentity)
(declare-const validation_context CompilerContext)
(declare-const validation_readers ReaderIdentity)
(declare-const first_form_context CompilerContext)
(declare-const first_form_readers ReaderIdentity)
(declare-const selected_publication Publication)
(declare-const loaded_publication Publication)

(declare-const per_form_revalidation Bool)
(declare-const embedded_execution_state_guard Bool)
(assert (! (= per_form_revalidation true)
           :named corrected_per_form_revalidation_enabled))
(assert (! (= embedded_execution_state_guard true)
           :named corrected_first_form_state_guard_enabled))

(declare-const capture_state_coherent Bool)
(assert (! (= capture_state_coherent
              (and (= form_1_context capture_context)
                   (= form_1_readers capture_readers)
                   (= form_2_context capture_context)
                   (= form_2_readers capture_readers)))
           :named capture_state_coherence_definition))

(declare-const capture_publish Bool)
(assert (! (= capture_publish
              (or (not per_form_revalidation) capture_state_coherent))
           :named capture_publication_gate_definition))

(declare-const manifest_selected Bool)
(assert (! (= manifest_selected
              (and capture_publish
                   (= validation_context capture_context)
                   (= validation_readers capture_readers)))
           :named manifest_selection_definition))

(declare-const publication_matches Bool)
(assert (! (= publication_matches
              (= selected_publication loaded_publication))
           :named publication_match_definition))

(declare-const execution_state_coherent Bool)
(assert (! (= execution_state_coherent
              (and (= first_form_context capture_context)
                   (= first_form_readers capture_readers)))
           :named execution_state_coherence_definition))

(declare-const first_form_guard_pass Bool)
(assert (! (= first_form_guard_pass
              (and publication_matches
                   (or (not embedded_execution_state_guard)
                       execution_state_coherent)))
           :named first_form_guard_definition))

(declare-const warm_exec Bool)
(assert (! (= warm_exec (and manifest_selected first_form_guard_pass))
           :named warm_execution_definition))

(declare-const capture_violation Bool)
(assert (! (= capture_violation
              (and capture_publish
                   (or (not (= form_1_context capture_context))
                       (not (= form_1_readers capture_readers))
                       (not (= form_2_context capture_context))
                       (not (= form_2_readers capture_readers)))))
           :named capture_violation_definition))

(declare-const warm_violation Bool)
(assert (! (= warm_violation
              (and warm_exec
                   (or (not (= first_form_context capture_context))
                       (not (= first_form_readers capture_readers)))))
           :named warm_violation_definition))

(declare-const violation Bool)
(assert (! (= violation (or capture_violation warm_violation))
           :named violation_definition))

; Coherent second-identity boundary and reachability assertions.
(assert (! (= capture_context ctx1) :named boundary_capture_context))
(assert (! (= capture_readers readers1) :named boundary_capture_readers))
(assert (! (= form_1_context ctx1) :named boundary_form_1_context))
(assert (! (= form_1_readers readers1) :named boundary_form_1_readers))
(assert (! (= form_2_context ctx1) :named boundary_form_2_context))
(assert (! (= form_2_readers readers1) :named boundary_form_2_readers))
(assert (! (= validation_context ctx1) :named boundary_validation_context))
(assert (! (= validation_readers readers1) :named boundary_validation_readers))
(assert (! (= first_form_context ctx1) :named boundary_first_form_context))
(assert (! (= first_form_readers readers1) :named boundary_first_form_readers))
(assert (! (= selected_publication pub1) :named boundary_selected_publication))
(assert (! (= loaded_publication pub1) :named boundary_loaded_publication))
(assert (! capture_publish :named nonvacuous_coherent_publication))
(assert (! manifest_selected :named nonvacuous_manifest_selection))
(assert (! warm_exec :named nonvacuous_warm_execution))
(assert (! (not violation) :named coherent_trace_is_not_violation))
