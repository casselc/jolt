; Expected result: SAT.
; Boundary/non-vacuity control for sealed generation routing. Both immutable
; candidates are published, generation 1 is selected, its matching provider is
; already loaded, and the selected bytes execute exactly once without violation.
; This is not a violating SAT control.
;
; Observed witness:
;   selected_consumer_generation=cgen1
;   selected_dependency_generation=pgen1
;   selected_transitive_dependency_generation=hgen1
;   loaded_publication_token=token1
;   provider_preloaded=true, preloaded_provider_generation=pgen1
;   helper_preloaded=true, preloaded_helper_generation=hgen1
;   effective_provider_generation=pgen1, effective_helper_generation=hgen1
;   user_forms_exec=true, violation=false
;
; Chiasmus supplies check-sat/model extraction.

(declare-datatypes () ((ConsumerGeneration cgen0 cgen1)))
(declare-datatypes () ((ProviderGeneration pgen0 pgen1)))
(declare-datatypes () ((HelperGeneration hgen0 hgen1)))
(declare-datatypes () ((CompileWitness witness0 witness1)))
(declare-datatypes () ((PublicationToken token0 token1)))

(declare-const publish_generation_0_step Int)
(declare-const publish_generation_1_step Int)
(declare-const select_generation_step Int)
(assert (! (= publish_generation_0_step 0)
           :named concurrent_publish_generation_0))
(assert (! (= publish_generation_1_step 0)
           :named concurrent_publish_generation_1))
(assert (! (= select_generation_step 1)
           :named token_selection_after_publication))

(declare-const selected_consumer_generation ConsumerGeneration)
(declare-const selected_publication_token PublicationToken)
(declare-const selected_compile_witness CompileWitness)
(declare-const selected_dependency_generation ProviderGeneration)
(declare-const selected_transitive_dependency_generation HelperGeneration)
(assert (! (= selected_publication_token
              (ite (= selected_consumer_generation cgen0) token0 token1))
           :named selected_token_from_generation))
(assert (! (= selected_compile_witness
              (ite (= selected_consumer_generation cgen0)
                   witness0 witness1))
           :named selected_witness_from_generation))
(assert (! (= selected_dependency_generation
              (ite (= selected_consumer_generation cgen0) pgen0 pgen1))
           :named selected_dependency_from_generation))
(assert (! (= selected_transitive_dependency_generation
              (ite (= selected_dependency_generation pgen0) hgen0 hgen1))
           :named selected_transitive_dependency_from_provider))

(declare-const loaded_publication_token PublicationToken)
(declare-const loaded_consumer_generation ConsumerGeneration)
(declare-const loaded_bytes_witness CompileWitness)
(assert (! (= loaded_consumer_generation
              (ite (= loaded_publication_token token0) cgen0 cgen1))
           :named loaded_generation_from_token))
(assert (! (= loaded_bytes_witness
              (ite (= loaded_publication_token token0) witness0 witness1))
           :named loaded_witness_from_token))

(declare-const independently_selected_provider ProviderGeneration)
(declare-const independently_selected_helper HelperGeneration)
(declare-const provider_preloaded Bool)
(declare-const preloaded_provider_generation ProviderGeneration)
(declare-const helper_preloaded Bool)
(declare-const preloaded_helper_generation HelperGeneration)
(declare-const sealed_dependency_routing Bool)
(declare-const loaded_provider_conflict_preflight Bool)
(declare-const publication_token_guard Bool)
(declare-const sealed_byte_integrity_guard Bool)
(assert (! (= sealed_dependency_routing true)
           :named corrected_sealed_dependency_routing))
(assert (! (= loaded_provider_conflict_preflight true)
           :named corrected_loaded_provider_preflight))
(assert (! (= publication_token_guard true)
           :named corrected_publication_token_guard))
(assert (! (= sealed_byte_integrity_guard true)
           :named corrected_sealed_byte_guard))

(declare-const routed_provider_generation ProviderGeneration)
(assert (! (= routed_provider_generation
              (ite sealed_dependency_routing
                   selected_dependency_generation
                   independently_selected_provider))
           :named provider_routing_definition))

(declare-const effective_provider_generation ProviderGeneration)
(assert (! (= effective_provider_generation
              (ite provider_preloaded
                   preloaded_provider_generation
                   routed_provider_generation))
           :named effective_provider_definition))

(declare-const routed_helper_generation HelperGeneration)
(assert (! (= routed_helper_generation
              (ite sealed_dependency_routing
                   selected_transitive_dependency_generation
                   independently_selected_helper))
           :named transitive_dependency_routing_definition))

(declare-const effective_helper_generation HelperGeneration)
(assert (! (= effective_helper_generation
              (ite helper_preloaded
                   preloaded_helper_generation
                   routed_helper_generation))
           :named effective_helper_definition))

(declare-const loaded_provider_conflict Bool)
(assert (! (= loaded_provider_conflict
              (or (and provider_preloaded
                       (not (= preloaded_provider_generation
                               selected_dependency_generation)))
                  (and helper_preloaded
                       (not (= preloaded_helper_generation
                               selected_transitive_dependency_generation)))))
           :named loaded_provider_conflict_definition))

(declare-const publication_token_matches Bool)
(assert (! (= publication_token_matches
              (= loaded_publication_token selected_publication_token))
           :named publication_token_match_definition))

(declare-const sealed_bytes_match Bool)
(assert (! (= sealed_bytes_match
              (and (= loaded_consumer_generation
                      selected_consumer_generation)
                   (= loaded_bytes_witness selected_compile_witness)))
           :named sealed_bytes_match_definition))

(declare-const generation_preflight_pass Bool)
(assert (! (= generation_preflight_pass
              (and (or (not publication_token_guard)
                       publication_token_matches)
                   (or (not sealed_byte_integrity_guard)
                       sealed_bytes_match)
                   (or (not loaded_provider_conflict_preflight)
                       (not loaded_provider_conflict))))
           :named generation_preflight_definition))

(declare-const user_forms_exec Bool)
(assert (! (= user_forms_exec generation_preflight_pass)
           :named user_form_execution_definition))

(declare-const routing_violation Bool)
(assert (! (= routing_violation
              (and user_forms_exec
                   (not (= effective_provider_generation
                           selected_dependency_generation))))
           :named routing_violation_definition))
(declare-const transitive_routing_violation Bool)
(assert (! (= transitive_routing_violation
              (and user_forms_exec
                   (not (= effective_helper_generation
                           selected_transitive_dependency_generation))))
           :named transitive_routing_violation_definition))
(declare-const publication_violation Bool)
(assert (! (= publication_violation
              (and user_forms_exec
                   (not (= loaded_publication_token
                           selected_publication_token))))
           :named publication_violation_definition))
(declare-const byte_provenance_violation Bool)
(assert (! (= byte_provenance_violation
              (and user_forms_exec
                   (or (not (= loaded_consumer_generation
                               selected_consumer_generation))
                       (not (= loaded_bytes_witness
                               selected_compile_witness)))))
           :named byte_provenance_violation_definition))
(declare-const loaded_conflict_violation Bool)
(assert (! (= loaded_conflict_violation
              (and user_forms_exec loaded_provider_conflict))
           :named loaded_conflict_violation_definition))
(declare-const violation Bool)
(assert (! (= violation
              (or routing_violation
                  transitive_routing_violation
                  publication_violation
                  byte_provenance_violation
                  loaded_conflict_violation))
           :named violation_definition))

(assert (! (= selected_consumer_generation cgen1)
           :named boundary_selected_generation_1))
(assert (! (= loaded_publication_token token1)
           :named boundary_loaded_token_1))
(assert (! (= provider_preloaded true)
           :named coherent_provider_preloaded))
(assert (! (= preloaded_provider_generation pgen1)
           :named coherent_preloaded_provider_generation))
(assert (! (= helper_preloaded true)
           :named coherent_helper_preloaded))
(assert (! (= preloaded_helper_generation hgen1)
           :named coherent_preloaded_helper_generation))
(assert (! (= independently_selected_provider pgen0)
           :named ignored_independent_provider_boundary))
(assert (! (= independently_selected_helper hgen0)
           :named ignored_independent_helper_boundary))
(assert (! user_forms_exec :named nonvacuous_user_form_execution))
(assert (! (not violation) :named coherent_execution_is_not_violation))
