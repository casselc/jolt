; Expected result: SAT.
; Historical model of a rejected live-revalidation design, retained as bounded
; counterexample evidence. It is not the accepted generation invariant.
; Known-buggy control for validation-to-execution state: the per-form publication
; gate is enabled, but the artifact has no embedded execution-state guard.
; Validation matches the artifact; context and readers then change before the
; first namespace form, which still executes.
;
; Observed witness:
;   validation_context=ctx0, validation_readers=readers0
;   first_form_context=ctx1, first_form_readers=readers1
;   embedded_execution_state_guard=false
;   capture_publish=true, capture_violation=false
;   warm_exec=true, warm_violation=true, violation=true
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
(assert (! (= embedded_execution_state_guard false)
           :named buggy_missing_first_form_state_guard))

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

; Witness shaping isolates the validation/first-form race.
(assert (! (= capture_context ctx0) :named witness_capture_context))
(assert (! (= capture_readers readers0) :named witness_capture_readers))
(assert (! (= form_1_context ctx0) :named witness_form_1_context))
(assert (! (= form_1_readers readers0) :named witness_form_1_readers))
(assert (! (= form_2_context ctx0) :named witness_form_2_context))
(assert (! (= form_2_readers readers0) :named witness_form_2_readers))
(assert (! (= validation_context ctx0) :named witness_validation_context))
(assert (! (= validation_readers readers0) :named witness_validation_readers))
(assert (! (= first_form_context ctx1) :named witness_execution_context_mutated))
(assert (! (= first_form_readers readers1) :named witness_execution_readers_mutated))
(assert (! (= selected_publication pub0) :named witness_selected_publication))
(assert (! (= loaded_publication pub0) :named witness_loaded_publication))
(assert (! violation :named violation_query))
