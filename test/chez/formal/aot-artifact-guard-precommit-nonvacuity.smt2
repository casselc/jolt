; Expected result: SAT.
; Non-vacuity control: all in-memory route tokens match at the guard/selection
; commit; a provider mutation afterward is post-selection and does not reread
; source or invalidate execution through the immutable sealed route.
;
; Observed witness:
;   mutation_timing=mutation_after_guard, mutation_target=both_targets
;   provider_token_after_hook=gen0, provider_token_after_commit=gen1
;   selection_committed=true, first_user_form_exec=true
;   pre_guard_route_mismatch=false, violation=false
;
; Chiasmus supplies check-sat/model extraction.

(declare-datatypes ()
  ((Generation gen0 gen1)
   (MutationTiming no_mutation mutation_before_guard mutation_after_guard)
   (MutationTarget provider_target helper_target both_targets)))

(declare-const mutation_timing MutationTiming)
(declare-const mutation_target MutationTarget)

(declare-const sealed_provider_token Generation)
(declare-const sealed_helper_token Generation)
(assert (! (= sealed_provider_token gen0)
           :named sealed_provider_token_definition))
(assert (! (= sealed_helper_token gen0)
           :named sealed_helper_token_definition))

(declare-const provider_token_at_root_lookup Generation)
(declare-const helper_token_at_root_lookup Generation)
(assert (! (= provider_token_at_root_lookup gen0)
           :named provider_root_lookup_definition))
(assert (! (= helper_token_at_root_lookup gen0)
           :named helper_root_lookup_definition))

(declare-const root_route_candidate_selected Bool)
(assert (! (= root_route_candidate_selected
              (and (= provider_token_at_root_lookup sealed_provider_token)
                   (= helper_token_at_root_lookup sealed_helper_token)))
           :named root_route_candidate_definition))

(declare-const provider_targeted Bool)
(assert (! (= provider_targeted
              (or (= mutation_target provider_target)
                  (= mutation_target both_targets)))
           :named provider_target_definition))
(declare-const helper_targeted Bool)
(assert (! (= helper_targeted
              (or (= mutation_target helper_target)
                  (= mutation_target both_targets)))
           :named helper_target_definition))

(declare-const provider_token_after_hook Generation)
(assert (! (= provider_token_after_hook
              (ite (and (= mutation_timing mutation_before_guard)
                        provider_targeted)
                   gen1
                   provider_token_at_root_lookup))
           :named provider_after_hook_definition))
(declare-const helper_token_after_hook Generation)
(assert (! (= helper_token_after_hook
              (ite (and (= mutation_timing mutation_before_guard)
                        helper_targeted)
                   gen1
                   helper_token_at_root_lookup))
           :named helper_after_hook_definition))

(declare-const all_route_tokens_match_at_guard Bool)
(assert (! (= all_route_tokens_match_at_guard
              (and (= provider_token_after_hook sealed_provider_token)
                   (= helper_token_after_hook sealed_helper_token)))
           :named all_route_token_guard_definition))
(declare-const artifact_guard_rechecks_all_tokens Bool)
(assert (! (= artifact_guard_rechecks_all_tokens true)
           :named corrected_artifact_guard_enabled))
(declare-const artifact_guard_passes Bool)
(assert (! (= artifact_guard_passes
              (and root_route_candidate_selected
                   (or (not artifact_guard_rechecks_all_tokens)
                       all_route_tokens_match_at_guard)))
           :named artifact_guard_pass_definition))
(declare-const selection_committed Bool)
(assert (! (= selection_committed artifact_guard_passes)
           :named selection_commit_definition))

(declare-const provider_token_after_commit Generation)
(assert (! (= provider_token_after_commit
              (ite (and (= mutation_timing mutation_after_guard)
                        provider_targeted)
                   gen1
                   provider_token_after_hook))
           :named provider_after_commit_definition))
(declare-const helper_token_after_commit Generation)
(assert (! (= helper_token_after_commit
              (ite (and (= mutation_timing mutation_after_guard)
                        helper_targeted)
                   gen1
                   helper_token_after_hook))
           :named helper_after_commit_definition))

(declare-const selected_route_provider_token Generation)
(declare-const selected_route_helper_token Generation)
(assert (! (= selected_route_provider_token sealed_provider_token)
           :named immutable_selected_provider_definition))
(assert (! (= selected_route_helper_token sealed_helper_token)
           :named immutable_selected_helper_definition))
(declare-const first_user_form_exec Bool)
(assert (! (= first_user_form_exec selection_committed)
           :named first_user_form_execution_definition))

(declare-const pre_guard_route_mismatch Bool)
(assert (! (= pre_guard_route_mismatch
              (not all_route_tokens_match_at_guard))
           :named pre_guard_mismatch_definition))
(declare-const violation Bool)
(assert (! (= violation
              (and first_user_form_exec pre_guard_route_mismatch))
           :named violation_definition))

(assert (! (= mutation_timing mutation_after_guard)
           :named boundary_mutation_after_guard))
(assert (! (= mutation_target both_targets)
           :named boundary_both_ambient_tokens_mutate))
(assert (! selection_committed :named selection_commit_reachable))
(assert (! first_user_form_exec :named first_user_form_reachable))
(assert (! (= provider_token_after_commit gen1)
           :named ambient_provider_changes_after_commit))
(assert (! (= helper_token_after_commit gen1)
           :named ambient_helper_changes_after_commit))
(assert (! (= selected_route_provider_token gen0)
           :named immutable_provider_route_retained))
(assert (! (= selected_route_helper_token gen0)
           :named immutable_helper_route_retained))
(assert (! (not violation)
           :named nonvacuous_trace_is_not_violation))
