; Expected result: SAT.
; Buggy selected-generation policy: a nested reload mutates a sealed provider
; and the same selected transaction continues executing user forms.
;
; Observed witness:
;   reload_intent=nested_reload_requested
;   reload_rejected_before_mutation=false
;   provider_mutated=true
;   selected_execution_continues=true
;   retry_started=false, violation=true
;
; Chiasmus supplies check-sat/model extraction.

(declare-datatypes ()
  ((ReloadIntent no_nested_reload nested_reload_requested)
   (ProviderRevision provider_rev0 provider_rev1)))

(declare-const reload_intent ReloadIntent)
(declare-const sealed_provider_revision ProviderRevision)
(assert (! (= sealed_provider_revision provider_rev0)
           :named sealed_provider_revision_definition))

(declare-const selected_cached_generation Bool)
(assert (! (= selected_cached_generation true)
           :named selected_generation_definition))
(declare-const nested_reload_requested_flag Bool)
(assert (! (= nested_reload_requested_flag
              (= reload_intent nested_reload_requested))
           :named nested_reload_request_definition))

(declare-const fail_before_provider_mutation Bool)
(assert (! (= fail_before_provider_mutation false)
           :named buggy_fail_before_mutation_disabled))
(declare-const retry_after_selected_reload_failure Bool)
(assert (! (= retry_after_selected_reload_failure false)
           :named post_user_retry_disabled))

(declare-const reload_rejected_before_mutation Bool)
(assert (! (= reload_rejected_before_mutation
              (and nested_reload_requested_flag
                   fail_before_provider_mutation))
           :named reload_rejection_definition))
(declare-const provider_revision_after_request ProviderRevision)
(assert (! (= provider_revision_after_request
              (ite (and nested_reload_requested_flag
                        (not reload_rejected_before_mutation))
                   provider_rev1
                   sealed_provider_revision))
           :named provider_revision_after_request_definition))
(declare-const provider_mutated Bool)
(assert (! (= provider_mutated
              (not (= provider_revision_after_request
                      sealed_provider_revision)))
           :named provider_mutation_definition))

(declare-const selected_execution_continues Bool)
(assert (! (= selected_execution_continues
              (and selected_cached_generation
                   (or (not nested_reload_requested_flag)
                       (not reload_rejected_before_mutation))))
           :named selected_execution_definition))
(declare-const retry_started Bool)
(assert (! (= retry_started
              (and reload_rejected_before_mutation
                   retry_after_selected_reload_failure))
           :named retry_definition))

(declare-const selected_reload_violation Bool)
(assert (! (= selected_reload_violation
              (and selected_cached_generation
                   nested_reload_requested_flag
                   (or provider_mutated
                       selected_execution_continues
                       retry_started)))
           :named selected_reload_violation_definition))
(declare-const violation Bool)
(assert (! (= violation selected_reload_violation)
           :named violation_definition))

(assert (! (= reload_intent nested_reload_requested)
           :named witness_nested_reload_requested))
(assert (! violation :named violation_query))
