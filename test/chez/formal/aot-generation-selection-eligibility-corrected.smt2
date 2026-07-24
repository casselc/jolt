; Expected result: UNSAT.
; Accepted root-selection gate: every sealed direct and transitive provider
; generation must match its current aggregate source/context/observation witness
; at selection. Mismatch misses or recompiles before user forms. No
; post-selection live state is modeled.
;
; Observed named UNSAT core:
;   provider_selection_eligibility_definition
;   helper_selection_eligibility_definition
;   recursive_selection_eligibility_definition
;   corrected_recursive_eligibility_gate_enabled
;   root_selection_gate_definition
;   user_form_execution_definition
;   selection_currentness_violation_definition
;   violation_definition
;   violation_query
;
; Chiasmus supplies check-sat/UNSAT-core extraction.

(declare-datatypes ()
  ((EligibilityWitness witness_absent witness_rev0 witness_rev1)))

(declare-const sealed_provider_witness EligibilityWitness)
(declare-const current_provider_witness_at_selection EligibilityWitness)
(declare-const sealed_helper_witness EligibilityWitness)
(declare-const current_helper_witness_at_selection EligibilityWitness)

(declare-const provider_selection_eligible Bool)
(assert (! (= provider_selection_eligible
              (= sealed_provider_witness
                 current_provider_witness_at_selection))
           :named provider_selection_eligibility_definition))
(declare-const helper_selection_eligible Bool)
(assert (! (= helper_selection_eligible
              (= sealed_helper_witness
                 current_helper_witness_at_selection))
           :named helper_selection_eligibility_definition))
(declare-const recursive_selection_eligible Bool)
(assert (! (= recursive_selection_eligible
              (and provider_selection_eligible helper_selection_eligible))
           :named recursive_selection_eligibility_definition))

(declare-const require_recursive_selection_eligibility Bool)
(assert (! (= require_recursive_selection_eligibility true)
           :named corrected_recursive_eligibility_gate_enabled))

(declare-const root_selection_succeeds Bool)
(assert (! (= root_selection_succeeds
              (or (not require_recursive_selection_eligibility)
                  recursive_selection_eligible))
           :named root_selection_gate_definition))
(declare-const miss_or_recompile Bool)
(assert (! (= miss_or_recompile (not root_selection_succeeds))
           :named miss_or_recompile_definition))
(declare-const user_forms_exec Bool)
(assert (! (= user_forms_exec root_selection_succeeds)
           :named user_form_execution_definition))

(declare-const selection_currentness_violation Bool)
(assert (! (= selection_currentness_violation
              (and user_forms_exec
                   (or (not (= sealed_provider_witness
                               current_provider_witness_at_selection))
                       (not (= sealed_helper_witness
                               current_helper_witness_at_selection)))))
           :named selection_currentness_violation_definition))
(declare-const violation Bool)
(assert (! (= violation selection_currentness_violation)
           :named violation_definition))
(assert (! violation :named violation_query))
