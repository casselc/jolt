; Expected result: SAT.
; Buggy direct/nested-load policy: a capture may publish after recording both an
; outer direct load and its nested forms, and selected execution may independently
; follow a project-owned nested edge that is absent from the sealed route.
;
; Observed witness:
;   capture_shape=capture_with_direct_load
;   nested_operation=direct_load_or_file
;   route_membership=route_edge_absent
;   provider_ownership=project_owned
;   candidate_publishable=true, selected_generation_exec=true
;   nested_side_effect_count=2
;   duplicate_nested_side_effect=true, unsealed_route_escape=true
;   violation=true
;
; Chiasmus supplies check-sat/model extraction.

(declare-datatypes ()
  ((CaptureShape
     capture_without_direct_load
     capture_with_direct_load)
   (NestedOperation
     no_nested_operation
     project_require
     direct_load_or_file)
   (RouteMembership
     route_edge_absent
     route_edge_present)
   (ProviderOwnership
     project_owned
     install_baked_owned)))

(declare-const capture_shape CaptureShape)
(declare-const nested_operation NestedOperation)
(declare-const route_membership RouteMembership)
(declare-const provider_ownership ProviderOwnership)

(declare-const capture_contains_direct_load Bool)
(assert (! (= capture_contains_direct_load
              (= capture_shape capture_with_direct_load))
           :named capture_direct_load_definition))
(declare-const outer_load_recorded Bool)
(assert (! (= outer_load_recorded capture_contains_direct_load)
           :named outer_load_recording_definition))
(declare-const nested_forms_recorded Bool)
(assert (! (= nested_forms_recorded capture_contains_direct_load)
           :named nested_form_recording_definition))

(declare-const selected_operation_is_project_edge Bool)
(assert (! (= selected_operation_is_project_edge
              (and (not (= nested_operation no_nested_operation))
                   (= provider_ownership project_owned)))
           :named project_edge_definition))
(declare-const sealed_route_complete Bool)
(assert (! (= sealed_route_complete
              (or (not selected_operation_is_project_edge)
                  (= route_membership route_edge_present)))
           :named sealed_route_completeness_definition))

(declare-const reject_direct_load_capture Bool)
(assert (! (= reject_direct_load_capture false)
           :named buggy_capture_publication_gate_disabled))
(declare-const reject_unsealed_selected_edge Bool)
(assert (! (= reject_unsealed_selected_edge false)
           :named buggy_route_completeness_gate_disabled))

(declare-const candidate_publishable Bool)
(assert (! (= candidate_publishable
              (not (and reject_direct_load_capture
                        capture_contains_direct_load)))
           :named candidate_publication_definition))
(declare-const route_preflight_passes Bool)
(assert (! (= route_preflight_passes
              (or (not reject_unsealed_selected_edge)
                  sealed_route_complete))
           :named route_preflight_definition))
(declare-const selected_generation_exec Bool)
(assert (! (= selected_generation_exec
              (and candidate_publishable route_preflight_passes))
           :named selected_generation_execution_definition))

(declare-const project_forms_or_mutation_reached Bool)
(assert (! (= project_forms_or_mutation_reached
              (and selected_generation_exec
                   selected_operation_is_project_edge))
           :named project_execution_definition))
(declare-const outer_replay_nested_effect Bool)
(assert (! (= outer_replay_nested_effect
              (and selected_generation_exec
                   (= nested_operation direct_load_or_file)
                   outer_load_recorded))
           :named outer_replay_effect_definition))
(declare-const separate_nested_replay_effect Bool)
(assert (! (= separate_nested_replay_effect
              (and selected_generation_exec
                   (= nested_operation direct_load_or_file)
                   nested_forms_recorded))
           :named nested_replay_effect_definition))
(declare-const nested_side_effect_count Int)
(assert (! (= nested_side_effect_count
              (+ (ite outer_replay_nested_effect 1 0)
                 (ite separate_nested_replay_effect 1 0)))
           :named nested_side_effect_count_definition))
(assert (! (and (<= 0 nested_side_effect_count)
                (<= nested_side_effect_count 2))
           :named nested_side_effect_count_bounds))

(declare-const duplicate_nested_side_effect Bool)
(assert (! (= duplicate_nested_side_effect
              (> nested_side_effect_count 1))
           :named duplicate_effect_definition))
(declare-const unsealed_route_escape Bool)
(assert (! (= unsealed_route_escape
              (and selected_operation_is_project_edge
                   (not sealed_route_complete)
                   project_forms_or_mutation_reached))
           :named unsealed_route_escape_definition))
(declare-const violation Bool)
(assert (! (= violation
              (or duplicate_nested_side_effect
                  unsealed_route_escape))
           :named violation_definition))

(assert (! (= capture_shape capture_with_direct_load)
           :named witness_outer_and_nested_capture))
(assert (! (= nested_operation direct_load_or_file)
           :named witness_direct_load_replay))
(assert (! (= route_membership route_edge_absent)
           :named witness_edge_absent_from_route))
(assert (! (= provider_ownership project_owned)
           :named witness_project_owned_edge))
(assert (! violation :named violation_query))
