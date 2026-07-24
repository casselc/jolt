; Expected result: SAT.
; Rejected production boundary: namespace artifacts are selected independently
; even though each artifact belongs to one coherent whole-build token. The
; shaped witness selects namespace A from build0 and namespace B from build1,
; then executes them as one project snapshot.
;
; This model assumes that graph/input classification is complete for the two
; represented namespaces and one represented dynamic compile input. It does not
; prove that a real graph resolver or compiler-input observer is complete.
;
; Expected witness:
;   selected_build_token=build0
;   independently_selected_a_token=build0
;   independently_selected_b_token=build1
;   effective_a_revision=rev0
;   effective_b_revision=rev1
;   dynamic_compile_input=dynamic_declared
;   user_forms_exec=true
;   mixed_snapshot_violation=true
;   violation=true
;
; Chiasmus supplies check-sat/model extraction.

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

; The two aggregate graph witnesses stand for complete bounded project snapshots:
; graph0 contains namespace A@rev0 and B@rev0; graph1 contains A@rev1 and B@rev1.
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

; These policy switches are source-design choices, not free result flags.
(declare-const require_fresh_process Bool)
(declare-const atomic_whole_image_selection Bool)
(declare-const require_image_witness_integrity Bool)
(declare-const reject_undeclared_dynamic_input Bool)
(assert (! (= require_fresh_process true)
           :named buggy_still_uses_fresh_process))
(assert (! (= atomic_whole_image_selection false)
           :named buggy_independent_namespace_artifact_selection))
(assert (! (= require_image_witness_integrity true)
           :named buggy_image_integrity_gate_enabled))
(assert (! (= reject_undeclared_dynamic_input true)
           :named buggy_dynamic_input_gate_enabled))

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

; Concrete known-SAT counterexample. The selected whole-image metadata is
; coherent; only independent namespace-artifact selection is faulty.
(assert (! (= selected_build_token build0)
           :named witness_selected_build0))
(assert (! (= loaded_image_token build0)
           :named witness_loaded_image_build0))
(assert (! (= loaded_image_graph_witness graph0)
           :named witness_loaded_graph0))
(assert (! (= loaded_image_input_witness inputs0)
           :named witness_loaded_inputs0))
(assert (! (= loaded_image_bytes bytes0)
           :named witness_loaded_bytes0))
(assert (! (= loaded_image_a_revision rev0)
           :named witness_loaded_a_rev0))
(assert (! (= loaded_image_b_revision rev0)
           :named witness_loaded_b_rev0))
(assert (! (= independently_selected_a_token build0)
           :named witness_independent_a_build0))
(assert (! (= independently_selected_b_token build1)
           :named witness_independent_b_build1))
(assert (! (= dynamic_compile_input dynamic_declared)
           :named witness_dynamic_input_declared))
(assert (! (= fresh_compiler_process true)
           :named witness_fresh_process))
(assert (! (= project_graph_complete true)
           :named assumption_complete_project_graph))
(assert (! (= compiler_input_observation_complete true)
           :named assumption_complete_compiler_inputs))
(assert (! user_forms_exec :named witness_user_forms_execute))
(assert (! violation :named violation_query))
