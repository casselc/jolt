; Expected result: SAT.
; Non-vacuity control: one consumed present revision and one consumed absence are
; exactly sealed. The untrusted effect has both an explicit trust assertion and
; a sealed nonblank salt. Publication and execution remain reachable.
;
; Observed witness:
;   event_a=identity_rev1/observed_rev1
;   event_b=identity_absent/observed_absent
;   compile_effect_class=untrusted_effect
;   sealed_trust_assertion=true
;   effect_salt_is_sealed=true, sealed_effect_salt=salt1
;   consumed_trace_complete=true, effect_contract_satisfied=true
;   selected_generation_exec=true, violation=false
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

(assert (! (= event_a_consumed true) :named boundary_event_a_consumed))
(assert (! (= event_a_identity identity_rev1)
           :named boundary_event_a_revision_1))
(assert (! (= event_a_observation observed_rev1)
           :named boundary_event_a_revision_1_observed))
(assert (! (= event_b_consumed true) :named boundary_event_b_consumed))
(assert (! (= event_b_identity identity_absent)
           :named boundary_event_b_absent))
(assert (! (= event_b_observation observed_absent)
           :named boundary_event_b_absence_observed))
(assert (! (= compile_effect_class untrusted_effect)
           :named boundary_untrusted_effect))
(assert (! (= sealed_trust_assertion true)
           :named boundary_explicit_trust_assertion))
(assert (! (= effect_salt_is_sealed true)
           :named boundary_salt_sealed))
(assert (! (= sealed_effect_salt salt1)
           :named boundary_nonblank_salt))
(assert (! selected_generation_exec
           :named nonvacuous_generation_execution))
(assert (! (not violation) :named coherent_trace_is_not_violation))
