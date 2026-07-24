; Expected result: SAT.
; Rejected publication gate: a consumed revision is omitted from the sealed
; observation trace and an untrusted compile-time effect has neither a sealed
; trust assertion nor a sealed nonblank salt, yet the generation publishes and
; executes.
;
; Observed witness:
;   event_a_consumed=true, event_a_identity=identity_rev1
;   event_a_observation=observation_omitted
;   event_b_consumed=true, event_b_identity=identity_absent
;   event_b_observation=observed_absent
;   compile_effect_class=untrusted_effect
;   consumed_trace_complete=false, effect_contract_satisfied=false
;   selected_generation_exec=true
;   consumed_input_violation=true, untrusted_effect_violation=true
;   violation=true
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

; Exactly two possible compile-time consumption events.
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
(assert (! (= require_complete_consumed_trace false)
           :named buggy_consumed_trace_gate_disabled))
(assert (! (= fail_closed_untrusted_effect false)
           :named buggy_effect_gate_disabled))

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

(assert (! (= event_a_consumed true)
           :named witness_event_a_consumed))
(assert (! (= event_a_identity identity_rev1)
           :named witness_event_a_revision))
(assert (! (= event_a_observation observation_omitted)
           :named witness_event_a_omitted))
(assert (! (= event_b_consumed true)
           :named witness_event_b_consumed))
(assert (! (= event_b_identity identity_absent)
           :named witness_event_b_absence))
(assert (! (= event_b_observation observed_absent)
           :named witness_event_b_absence_observed))
(assert (! (= compile_effect_class untrusted_effect)
           :named witness_untrusted_effect))
(assert (! (= sealed_trust_assertion false)
           :named witness_no_trust_assertion))
(assert (! (= effect_salt_is_sealed false)
           :named witness_salt_not_sealed))
(assert (! (= sealed_effect_salt blank_salt)
           :named witness_blank_salt))
(assert (! selected_generation_exec :named witness_generation_executes))
(assert (! violation :named violation_query))
