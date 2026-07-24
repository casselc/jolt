; Expected result: UNSAT.
; Corrected production boundary: one fresh compiler process resolves one complete
; project source graph and complete compiler-input witness, publishes one
; immutable whole-project image under one build token, and atomically selects
; that image. Execution fails closed for a mismatched image witness or a dynamic
; compile input outside the declared graph.
;
; The completeness of the real source-graph resolver and compiler-input observer
; is assumed. This finite model proves only the gate after complete and exact
; classification; it does not prove that production instrumentation finds every
; input.
;
; Chiasmus supplies check-sat/UNSAT-core extraction.

(declare-datatypes ()
  ((BuildToken build0 build1)
   (SourceRevision rev0 rev1)
   (SourceGraphWitness graph0 graph1)
   (CompilerInputWitness inputs0 inputs1)
   (ImageBytes bytes0 bytes1)
   (DynamicCompileInput dynamic_none dynamic_declared dynamic_undeclared)))

(declare-const selected_build_token BuildToken)
(declare-const loaded_image_token BuildToken)
(declare-const loaded_image_graph_witness SourceGraphWitness)
(declare-const loaded_image_input_witness CompilerInputWitness)
(declare-const loaded_image_bytes ImageBytes)
(declare-const loaded_image_a_revision SourceRevision)
(declare-const loaded_image_b_revision SourceRevision)
(declare-const independently_selected_a_token BuildToken)
(declare-const independently_selected_b_token BuildToken)
(declare-const dynamic_compile_input DynamicCompileInput)
(declare-const fresh_compiler_process Bool)
(declare-const project_graph_complete Bool)
(declare-const compiler_input_observation_complete Bool)

(assert (! (= project_graph_complete true)
           :named assumption_complete_project_graph))
(assert (! (= compiler_input_observation_complete true)
           :named assumption_complete_compiler_inputs))

(declare-const selected_graph_witness SourceGraphWitness)
(declare-const selected_input_witness CompilerInputWitness)
(declare-const selected_image_bytes ImageBytes)
(declare-const selected_a_revision SourceRevision)
(declare-const selected_b_revision SourceRevision)
(assert (! (= selected_graph_witness
              (ite (= selected_build_token build0) graph0 graph1))
           :named selected_graph_from_build_token))
(assert (! (= selected_input_witness
              (ite (= selected_build_token build0) inputs0 inputs1))
           :named selected_inputs_from_build_token))
(assert (! (= selected_image_bytes
              (ite (= selected_build_token build0) bytes0 bytes1))
           :named selected_bytes_from_build_token))
(assert (! (= selected_a_revision
              (ite (= selected_build_token build0) rev0 rev1))
           :named selected_a_revision_from_build_token))
(assert (! (= selected_b_revision
              (ite (= selected_build_token build0) rev0 rev1))
           :named selected_b_revision_from_build_token))

(declare-const image_matches_selected_witness Bool)
(assert (! (= image_matches_selected_witness
              (and (= loaded_image_token selected_build_token)
                   (= loaded_image_graph_witness selected_graph_witness)
                   (= loaded_image_input_witness selected_input_witness)
                   (= loaded_image_bytes selected_image_bytes)
                   (= loaded_image_a_revision selected_a_revision)
                   (= loaded_image_b_revision selected_b_revision)))
           :named image_witness_integrity_definition))

(declare-const require_fresh_process Bool)
(declare-const atomic_whole_image_selection Bool)
(declare-const require_image_witness_integrity Bool)
(declare-const reject_undeclared_dynamic_input Bool)
(assert (! (= require_fresh_process true)
           :named corrected_fresh_process_required))
(assert (! (= atomic_whole_image_selection true)
           :named corrected_atomic_whole_image_selection))
(assert (! (= require_image_witness_integrity true)
           :named corrected_image_witness_guard))
(assert (! (= reject_undeclared_dynamic_input true)
           :named corrected_closed_world_dynamic_input_gate))

(declare-const effective_a_token BuildToken)
(declare-const effective_b_token BuildToken)
(declare-const effective_a_revision SourceRevision)
(declare-const effective_b_revision SourceRevision)
(assert (! (= effective_a_token
              (ite atomic_whole_image_selection
                   loaded_image_token
                   independently_selected_a_token))
           :named effective_a_token_definition))
(assert (! (= effective_b_token
              (ite atomic_whole_image_selection
                   loaded_image_token
                   independently_selected_b_token))
           :named effective_b_token_definition))
(assert (! (= effective_a_revision
              (ite atomic_whole_image_selection
                   loaded_image_a_revision
                   (ite (= independently_selected_a_token build0) rev0 rev1)))
           :named effective_a_revision_definition))
(assert (! (= effective_b_revision
              (ite atomic_whole_image_selection
                   loaded_image_b_revision
                   (ite (= independently_selected_b_token build0) rev0 rev1)))
           :named effective_b_revision_definition))

(declare-const closed_world_input_valid Bool)
(assert (! (= closed_world_input_valid
              (and project_graph_complete
                   compiler_input_observation_complete
                   (not (= dynamic_compile_input dynamic_undeclared))))
           :named closed_world_input_definition))

(declare-const execution_preflight_passes Bool)
(assert (! (= execution_preflight_passes
              (and (or (not require_fresh_process)
                       fresh_compiler_process)
                   (or (not require_image_witness_integrity)
                       image_matches_selected_witness)
                   (or (not reject_undeclared_dynamic_input)
                       closed_world_input_valid)))
           :named execution_preflight_definition))
(declare-const user_forms_exec Bool)
(assert (! (= user_forms_exec execution_preflight_passes)
           :named user_form_execution_definition))

(declare-const mixed_snapshot_violation Bool)
(assert (! (= mixed_snapshot_violation
              (and user_forms_exec
                   (or (not (= effective_a_token effective_b_token))
                       (not (= effective_a_revision selected_a_revision))
                       (not (= effective_b_revision selected_b_revision)))))
           :named mixed_snapshot_violation_definition))
(declare-const image_provenance_violation Bool)
(assert (! (= image_provenance_violation
              (and user_forms_exec
                   (not image_matches_selected_witness)))
           :named image_provenance_violation_definition))
(declare-const undeclared_dynamic_input_violation Bool)
(assert (! (= undeclared_dynamic_input_violation
              (and user_forms_exec
                   (= dynamic_compile_input dynamic_undeclared)))
           :named undeclared_dynamic_input_violation_definition))
(declare-const nonfresh_process_violation Bool)
(assert (! (= nonfresh_process_violation
              (and user_forms_exec
                   (not fresh_compiler_process)))
           :named nonfresh_process_violation_definition))
(declare-const violation Bool)
(assert (! (= violation
              (or mixed_snapshot_violation
                  image_provenance_violation
                  undeclared_dynamic_input_violation
                  nonfresh_process_violation))
           :named violation_definition))
(assert (! violation :named violation_query))
