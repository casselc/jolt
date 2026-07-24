; Expected result: SAT.
; Non-vacuity control: the direct provider's revision1 witness and the helper's
; absence witness both remain current at root selection. The root selects and
; executes without a miss. No post-selection live state is modeled.
;
; Observed witness:
;   sealed_provider_witness=witness_rev1
;   current_provider_witness_at_selection=witness_rev1
;   sealed_helper_witness=witness_absent
;   current_helper_witness_at_selection=witness_absent
;   root_selection_succeeds=true, miss_or_recompile=false
;   user_forms_exec=true, violation=false
;
; Chiasmus supplies check-sat/model extraction.

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

(assert (! (= sealed_provider_witness witness_rev1)
           :named boundary_provider_sealed_revision_1))
(assert (! (= current_provider_witness_at_selection witness_rev1)
           :named boundary_provider_current_revision_1))
(assert (! (= sealed_helper_witness witness_absent)
           :named boundary_helper_sealed_absence))
(assert (! (= current_helper_witness_at_selection witness_absent)
           :named boundary_helper_current_absence))
(assert (! user_forms_exec
           :named nonvacuous_root_execution))
(assert (! (= miss_or_recompile false)
           :named coherent_selection_does_not_miss))
(assert (! (not violation)
           :named coherent_selection_is_not_violation))
