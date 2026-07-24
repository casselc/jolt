; Expected result: UNSAT.
; Corrected environment policy: project generation invalidation and dirty
; consumed baked observations set a permanent compile taint unless the change is
; one precisely scoped loader operation. Publication also rechecks live
; in-memory identities after capture. Ordinary late-bound nonmacro roots are
; intentionally excluded. Classifier and mutation-hook completeness are assumed.
;
; Observed named UNSAT core:
;   corrected_permanent_taint_tracking_enabled
;   corrected_final_publication_recheck_enabled
;   permanent_taint_window_definition
;   final_publication_window_definition
;   global_permanent_taint_definition
;   strategy_base_gate_definition
;   final_decision_recheck_definition
;   candidate_acceptance_definition
;   violation_definition
;   violation_query
;
; Chiasmus supplies check-sat/UNSAT-core extraction.

(declare-datatypes ()
  ((RootRevision root_rev0 root_rev1)
   (DefinedState undefined_state defined_state)
   (MacroState nonmacro_state macro_state)
   (MetaRevision meta_rev0 meta_rev1)
   (RegistryRevision registry_rev0 registry_rev1)
   (NamespaceTarget target_none target_p1 target_p2)
   (CellOrigin baked_cell project_cell)
   (MappingOrigin baked_mapping project_mapping)
   (ConsumptionState unconsumed consumed)
   (RootBindingMode
     ordinary_late_bound_root
     macro_reader_callback_root
     inline_or_direct_link_root)
   (CacheDecision cache_hit_decision publication_decision)
   (MutationWindow
     change_observed_by_taint
     change_after_capture_before_publish)
   (MutationActor untrusted_actor unknown_actor loader_controlled_actor)
   (OperationScope outside_loader_scope exact_loader_scope)
   (SafetyStrategy scoped_invalidation_strategy fresh_namespace_strategy)
   (NamespaceStart preexisting_namespace fresh_empty_namespace)))

(declare-const cell_origin CellOrigin)
(declare-const mapping_origin MappingOrigin)
(declare-const cell_consumption ConsumptionState)
(declare-const mapping_consumption ConsumptionState)
(declare-const registry_consumption ConsumptionState)
(declare-const root_binding_mode RootBindingMode)
(declare-const cache_decision CacheDecision)
(declare-const mutation_window MutationWindow)
(declare-const mutation_actor MutationActor)
(declare-const operation_scope OperationScope)
(declare-const safety_strategy SafetyStrategy)
(declare-const namespace_start NamespaceStart)
(declare-const taint_before_operation Bool)

(declare-const root_before RootRevision)
(declare-const defined_before DefinedState)
(declare-const macro_before MacroState)
(declare-const meta_before MetaRevision)
(declare-const alias_before NamespaceTarget)
(declare-const refer_before NamespaceTarget)
(declare-const registry_before RegistryRevision)
(assert (! (= root_before root_rev0) :named root_before_definition))
(assert (! (= defined_before defined_state) :named defined_before_definition))
(assert (! (= macro_before nonmacro_state) :named macro_before_definition))
(assert (! (= meta_before meta_rev0) :named meta_before_definition))
(assert (! (= alias_before target_p1) :named alias_before_definition))
(assert (! (= refer_before target_p1) :named refer_before_definition))
(assert (! (= registry_before registry_rev0)
           :named registry_before_definition))

(declare-const root_at_final_guard RootRevision)
(declare-const defined_at_final_guard DefinedState)
(declare-const macro_at_final_guard MacroState)
(declare-const meta_at_final_guard MetaRevision)
(declare-const alias_at_final_guard NamespaceTarget)
(declare-const refer_at_final_guard NamespaceTarget)
(declare-const registry_at_final_guard RegistryRevision)

(declare-const root_changed Bool)
(assert (! (= root_changed
              (not (= root_at_final_guard root_before)))
           :named root_change_definition))
(declare-const ordinary_nonmacro_root_change Bool)
(assert (! (= ordinary_nonmacro_root_change
              (and root_changed
                   (= root_binding_mode ordinary_late_bound_root)
                   (= macro_before nonmacro_state)
                   (= macro_at_final_guard nonmacro_state)))
           :named ordinary_nonmacro_root_change_definition))
(declare-const compile_relevant_root_change Bool)
(assert (! (= compile_relevant_root_change
              (and root_changed
                   (or (= root_binding_mode inline_or_direct_link_root)
                       (= root_binding_mode macro_reader_callback_root)
                       (= macro_before macro_state)
                       (= macro_at_final_guard macro_state))))
           :named compile_relevant_root_change_definition))
(declare-const defined_changed Bool)
(assert (! (= defined_changed
              (not (= defined_at_final_guard defined_before)))
           :named defined_change_definition))
(declare-const macro_changed Bool)
(assert (! (= macro_changed
              (not (= macro_at_final_guard macro_before)))
           :named macro_change_definition))
(declare-const meta_changed Bool)
(assert (! (= meta_changed
              (not (= meta_at_final_guard meta_before)))
           :named meta_change_definition))
(declare-const alias_changed Bool)
(assert (! (= alias_changed
              (not (= alias_at_final_guard alias_before)))
           :named alias_change_definition))
(declare-const refer_changed Bool)
(assert (! (= refer_changed
              (not (= refer_at_final_guard refer_before)))
           :named refer_change_definition))
(declare-const registry_changed Bool)
(assert (! (= registry_changed
              (not (= registry_at_final_guard registry_before)))
           :named registry_change_definition))

(declare-const compile_relevant_cell_change Bool)
(assert (! (= compile_relevant_cell_change
              (or compile_relevant_root_change
                  defined_changed
                  macro_changed
                  meta_changed))
           :named compile_relevant_cell_change_definition))
(declare-const compile_relevant_mapping_change Bool)
(assert (! (= compile_relevant_mapping_change
              (or alias_changed refer_changed))
           :named compile_relevant_mapping_change_definition))

(declare-const project_generation_invalidated Bool)
(assert (! (= project_generation_invalidated
              (or (and (= cell_origin project_cell)
                       compile_relevant_cell_change)
                  (and (= mapping_origin project_mapping)
                       compile_relevant_mapping_change)))
           :named project_generation_invalidation_definition))
(declare-const baked_consumed_cell_dirty Bool)
(assert (! (= baked_consumed_cell_dirty
              (and (= cell_origin baked_cell)
                   (= cell_consumption consumed)
                   compile_relevant_cell_change))
           :named baked_consumed_cell_dirty_definition))
(declare-const baked_consumed_mapping_dirty Bool)
(assert (! (= baked_consumed_mapping_dirty
              (and (= mapping_origin baked_mapping)
                   (= mapping_consumption consumed)
                   compile_relevant_mapping_change))
           :named baked_consumed_mapping_dirty_definition))
(declare-const consumed_global_registry_dirty Bool)
(assert (! (= consumed_global_registry_dirty
              (and (= registry_consumption consumed)
                   registry_changed))
           :named consumed_global_registry_dirty_definition))
(declare-const compile_environment_identity_changed Bool)
(assert (! (= compile_environment_identity_changed
              (or project_generation_invalidated
                  baked_consumed_cell_dirty
                  baked_consumed_mapping_dirty
                  consumed_global_registry_dirty))
           :named compile_environment_identity_definition))

(declare-const precisely_scoped_loader_operation Bool)
(assert (! (= precisely_scoped_loader_operation
              (and (= mutation_actor loader_controlled_actor)
                   (= operation_scope exact_loader_scope)))
           :named loader_operation_classification_definition))
(declare-const unsafe_compile_environment_change Bool)
(assert (! (= unsafe_compile_environment_change
              (and compile_environment_identity_changed
                   (not precisely_scoped_loader_operation)))
           :named unsafe_environment_change_definition))

(declare-const baked_nonmacro_promoted Bool)
(assert (! (= baked_nonmacro_promoted
              (and (= cell_origin baked_cell)
                   (= macro_before nonmacro_state)
                   (= macro_at_final_guard macro_state)))
           :named baked_nonmacro_promotion_definition))
(declare-const alias_retargeted_p1_to_p2 Bool)
(assert (! (= alias_retargeted_p1_to_p2
              (and (= alias_before target_p1)
                   (= alias_at_final_guard target_p2)))
           :named alias_retarget_definition))

(declare-const permanent_taint_tracks_unsafe_change Bool)
(assert (! (= permanent_taint_tracks_unsafe_change true)
           :named corrected_permanent_taint_tracking_enabled))
(declare-const final_publication_live_recheck Bool)
(assert (! (= final_publication_live_recheck true)
           :named corrected_final_publication_recheck_enabled))
(declare-const unsafe_change_requires_permanent_taint Bool)
(assert (! (= unsafe_change_requires_permanent_taint
              (and unsafe_compile_environment_change
                   (or (= cache_decision cache_hit_decision)
                       (= mutation_window change_observed_by_taint))))
           :named permanent_taint_window_definition))
(declare-const unsafe_change_requires_final_publication_recheck Bool)
(assert (! (= unsafe_change_requires_final_publication_recheck
              (and unsafe_compile_environment_change
                   (= cache_decision publication_decision)
                   (= mutation_window change_after_capture_before_publish)))
           :named final_publication_window_definition))
(declare-const global_permanent_compile_taint Bool)
(assert (! (= global_permanent_compile_taint
              (or taint_before_operation
                  (and permanent_taint_tracks_unsafe_change
                       unsafe_change_requires_permanent_taint)))
           :named global_permanent_taint_definition))

(declare-const namespace_freshness_requirement_met Bool)
(assert (! (= namespace_freshness_requirement_met
              (= namespace_start fresh_empty_namespace))
           :named namespace_freshness_definition))
(declare-const strategy_base_gate_passes Bool)
(assert (! (= strategy_base_gate_passes
              (and (not global_permanent_compile_taint)
                   (or (= safety_strategy scoped_invalidation_strategy)
                       (and (= safety_strategy fresh_namespace_strategy)
                            namespace_freshness_requirement_met))))
           :named strategy_base_gate_definition))
(declare-const final_decision_recheck_passes Bool)
(assert (! (= final_decision_recheck_passes
              (or (not (= cache_decision publication_decision))
                  (not final_publication_live_recheck)
                  (not unsafe_change_requires_final_publication_recheck)))
           :named final_decision_recheck_definition))
(declare-const candidate_accepted Bool)
(assert (! (= candidate_accepted
              (and strategy_base_gate_passes
                   final_decision_recheck_passes))
           :named candidate_acceptance_definition))

(declare-const violation Bool)
(assert (! (= violation
              (and unsafe_compile_environment_change candidate_accepted))
           :named violation_definition))
(assert (! violation :named violation_query))
