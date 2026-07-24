; Expected result: SAT.
; Negative control: an ordinary runtime Var is not consumed during compilation.
; Its root revision changes after generation selection, but no live reread is
; required and the sealed generation still executes without a publication miss.
;
; Observed witness:
;   event_b_consumed=false
;   event_b_observation=observation_omitted
;   runtime_var_revision_at_selection=runtime_rev0
;   runtime_var_revision_later=runtime_rev1
;   runtime_var_redefined=true
;   selected_generation_exec=true, publication_miss=false, violation=false
;
; Chiasmus supplies check-sat/model extraction.

(declare-datatypes ()
  ((InputIdentity identity_absent identity_rev0 identity_rev1)))
(declare-datatypes ()
  ((SealedObservation
     observation_omitted
     observed_absent
     observed_rev0
     observed_rev1)))
(declare-datatypes ()
  ((EffectClass no_effect trusted_effect untrusted_effect)))
(declare-datatypes ()
  ((SaltValue blank_salt salt0 salt1)))
(declare-datatypes ()
  ((RuntimeRevision runtime_rev0 runtime_rev1)))

(declare-const event_a_consumed Bool)
(declare-const event_a_identity InputIdentity)
(declare-const event_a_observation SealedObservation)
(declare-const event_b_consumed Bool)
(declare-const event_b_identity InputIdentity)
(declare-const event_b_observation SealedObservation)
(declare-const event_a_exactly_observed Bool)
(assert (! (= event_a_exactly_observed
              (or (not event_a_consumed)
                  (and event_a_consumed
                       (or (and (= event_a_identity identity_absent)
                                (= event_a_observation observed_absent))
                           (and (= event_a_identity identity_rev0)
                                (= event_a_observation observed_rev0))
                           (and (= event_a_identity identity_rev1)
                                (= event_a_observation observed_rev1))))))
           :named event_a_exact_observation_definition))
(declare-const event_b_exactly_observed Bool)
(assert (! (= event_b_exactly_observed
              (or (not event_b_consumed)
                  (and event_b_consumed
                       (or (and (= event_b_identity identity_absent)
                                (= event_b_observation observed_absent))
                           (and (= event_b_identity identity_rev0)
                                (= event_b_observation observed_rev0))
                           (and (= event_b_identity identity_rev1)
                                (= event_b_observation observed_rev1))))))
           :named event_b_exact_observation_definition))
(declare-const consumed_trace_complete Bool)
(assert (! (= consumed_trace_complete
              (and event_a_exactly_observed event_b_exactly_observed))
           :named consumed_trace_completeness_definition))

(declare-const compile_effect_class EffectClass)
(declare-const sealed_trust_assertion Bool)
(declare-const sealed_effect_salt SaltValue)
(declare-const effect_salt_is_sealed Bool)
(declare-const explicit_effect_authorization Bool)
(assert (! (= explicit_effect_authorization
              (or sealed_trust_assertion
                  (and effect_salt_is_sealed
                       (not (= sealed_effect_salt blank_salt)))))
           :named explicit_effect_authorization_definition))
(declare-const effect_contract_satisfied Bool)
(assert (! (= effect_contract_satisfied
              (or (not (= compile_effect_class untrusted_effect))
                  explicit_effect_authorization))
           :named effect_contract_definition))
(declare-const require_complete_consumed_trace Bool)
(declare-const fail_closed_untrusted_effect Bool)
(assert (! (= require_complete_consumed_trace true)
           :named corrected_consumed_trace_gate_enabled))
(assert (! (= fail_closed_untrusted_effect true)
           :named corrected_effect_gate_enabled))
(declare-const publication_allowed Bool)
(assert (! (= publication_allowed
              (and (or (not require_complete_consumed_trace)
                       consumed_trace_complete)
                   (or (not fail_closed_untrusted_effect)
                       effect_contract_satisfied)))
           :named publication_gate_definition))
(declare-const selected_generation_exec Bool)
(assert (! (= selected_generation_exec publication_allowed)
           :named selected_generation_execution_definition))

(declare-const consumed_input_violation Bool)
(assert (! (= consumed_input_violation
              (and selected_generation_exec
                   (or
                     (and event_a_consumed
                          (not
                            (or
                              (and (= event_a_identity identity_absent)
                                   (= event_a_observation observed_absent))
                              (and (= event_a_identity identity_rev0)
                                   (= event_a_observation observed_rev0))
                              (and (= event_a_identity identity_rev1)
                                   (= event_a_observation observed_rev1)))))
                     (and event_b_consumed
                          (not
                            (or
                              (and (= event_b_identity identity_absent)
                                   (= event_b_observation observed_absent))
                              (and (= event_b_identity identity_rev0)
                                   (= event_b_observation observed_rev0))
                              (and (= event_b_identity identity_rev1)
                                   (= event_b_observation observed_rev1))))))))
           :named consumed_input_violation_definition))
(declare-const untrusted_effect_violation Bool)
(assert (! (= untrusted_effect_violation
              (and selected_generation_exec
                   (= compile_effect_class untrusted_effect)
                   (not sealed_trust_assertion)
                   (not (and effect_salt_is_sealed
                             (not (= sealed_effect_salt blank_salt))))))
           :named untrusted_effect_violation_definition))
(declare-const violation Bool)
(assert (! (= violation
              (or consumed_input_violation untrusted_effect_violation))
           :named violation_definition))

(declare-const runtime_var_revision_at_selection RuntimeRevision)
(declare-const runtime_var_revision_later RuntimeRevision)
(declare-const runtime_var_redefined Bool)
(assert (! (= runtime_var_redefined
              (not (= runtime_var_revision_at_selection
                      runtime_var_revision_later)))
           :named runtime_var_redefinition_definition))
(declare-const publication_miss Bool)
(assert (! (= publication_miss (not selected_generation_exec))
           :named publication_miss_definition))

(assert (! (= event_a_consumed true) :named control_event_a_consumed))
(assert (! (= event_a_identity identity_rev0)
           :named control_event_a_revision))
(assert (! (= event_a_observation observed_rev0)
           :named control_event_a_observed))
; Event B represents the ordinary runtime Var: because its root is late-bound by
; emitted code, it is not a compile-time consumption event and needs no seal.
(assert (! (= event_b_consumed false)
           :named runtime_var_not_compile_time_consumed))
(assert (! (= event_b_identity identity_rev0)
           :named runtime_var_selection_identity))
(assert (! (= event_b_observation observation_omitted)
           :named runtime_var_not_in_compile_witness))
(assert (! (= compile_effect_class no_effect)
           :named control_no_compile_time_effect))
(assert (! (= sealed_trust_assertion false)
           :named control_no_unneeded_trust_assertion))
(assert (! (= effect_salt_is_sealed false)
           :named control_no_unneeded_salt))
(assert (! (= sealed_effect_salt blank_salt)
           :named control_blank_unused_salt))
(assert (! (= runtime_var_revision_at_selection runtime_rev0)
           :named runtime_var_initial_revision))
(assert (! (= runtime_var_revision_later runtime_rev1)
           :named runtime_var_later_revision))
(assert (! runtime_var_redefined
           :named runtime_var_redefinition_reachable))
(assert (! selected_generation_exec
           :named generation_executes_after_runtime_redefinition))
(assert (! (not publication_miss)
           :named runtime_redefinition_does_not_miss))
(assert (! (not violation)
           :named late_bound_control_is_not_violation))
