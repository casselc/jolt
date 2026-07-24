; Expected result: UNSAT.
; Accepted retry boundary: integrity and selection failures before user forms may
; retry, but once any user top-level form has begun the transaction never starts
; another compile/load attempt. The duplicate-after-user-failure query is UNSAT
; within the two-attempt model.
;
; Observed named UNSAT core:
;   corrected_user_failure_retry_disabled
;   first_integrity_phase_definition
;   first_selection_reachability_definition
;   first_selection_phase_definition
;   first_user_form_reachability_definition
;   pre_user_failure_definition
;   user_failure_definition
;   retry_policy_definition
;   second_user_form_reachability_definition
;   compile_attempt_count_definition
;   user_form_entry_count_definition
;   duplicate_after_user_failure_definition
;   violation_definition
;   violation_query
;
; Chiasmus supplies check-sat/UNSAT-core extraction.

(declare-datatypes ()
  ((AttemptOutcome
     integrity_failure
     selection_failure
     user_top_level_failure
     success)))

(declare-const first_attempt_outcome AttemptOutcome)
(declare-const retry_pre_user_failure Bool)
(declare-const retry_after_user_failure Bool)
(assert (! (= retry_pre_user_failure true)
           :named corrected_pre_user_retry_enabled))
(assert (! (= retry_after_user_failure false)
           :named corrected_user_failure_retry_disabled))

(declare-const first_integrity_pass Bool)
(assert (! (= first_integrity_pass
              (not (= first_attempt_outcome integrity_failure)))
           :named first_integrity_phase_definition))

(declare-const first_selection_reached Bool)
(assert (! (= first_selection_reached first_integrity_pass)
           :named first_selection_reachability_definition))

(declare-const first_selection_pass Bool)
(assert (! (= first_selection_pass
              (or (= first_attempt_outcome user_top_level_failure)
                  (= first_attempt_outcome success)))
           :named first_selection_phase_definition))

(declare-const first_user_forms_reached Bool)
(assert (! (= first_user_forms_reached
              (and first_selection_reached first_selection_pass))
           :named first_user_form_reachability_definition))

(declare-const pre_user_failure Bool)
(assert (! (= pre_user_failure
              (or (= first_attempt_outcome integrity_failure)
                  (= first_attempt_outcome selection_failure)))
           :named pre_user_failure_definition))

(declare-const user_top_level_failed Bool)
(assert (! (= user_top_level_failed
              (= first_attempt_outcome user_top_level_failure))
           :named user_failure_definition))

(declare-const retry_started Bool)
(assert (! (= retry_started
              (or (and pre_user_failure retry_pre_user_failure)
                  (and user_top_level_failed retry_after_user_failure)))
           :named retry_policy_definition))

(declare-const second_integrity_reached Bool)
(declare-const second_selection_reached Bool)
(declare-const second_user_forms_reached Bool)
(assert (! (= second_integrity_reached retry_started)
           :named second_integrity_reachability_definition))
(assert (! (= second_selection_reached retry_started)
           :named second_selection_reachability_definition))
(assert (! (= second_user_forms_reached retry_started)
           :named second_user_form_reachability_definition))

(declare-const compile_attempt_count Int)
(assert (! (= compile_attempt_count (+ 1 (ite retry_started 1 0)))
           :named compile_attempt_count_definition))
(declare-const user_form_phase_entry_count Int)
(assert (! (= user_form_phase_entry_count
              (+ (ite first_user_forms_reached 1 0)
                 (ite second_user_forms_reached 1 0)))
           :named user_form_entry_count_definition))
(assert (! (and (<= 1 compile_attempt_count)
                (<= compile_attempt_count 2)
                (<= 0 user_form_phase_entry_count)
                (<= user_form_phase_entry_count 2))
           :named two_attempt_bounds))

(declare-const duplicate_after_user_failure Bool)
(assert (! (= duplicate_after_user_failure
              (and user_top_level_failed
                   (or (> compile_attempt_count 1)
                       (> user_form_phase_entry_count 1))))
           :named duplicate_after_user_failure_definition))
(declare-const violation Bool)
(assert (! (= violation duplicate_after_user_failure)
           :named violation_definition))
(assert (! violation :named violation_query))
