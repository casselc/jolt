; One-fault SAT control for the corrected scoped-pointer query.
;
; The dynamic-wind before guard is omitted, so the attempted continuation
; reentry resumes the callback after the unlocked backing has moved. This uses
; the same violation definition as the corrected model. Expected result: SAT
; with callback_resumed=true and old_pointer_valid=false.

(declare-const exit_completed Bool)
(declare-const reentry_attempted Bool)
(declare-const backing_moved_after_exit Bool)
(declare-const retired Bool)
(declare-const before_allows_entry Bool)
(declare-const callback_resumed Bool)
(declare-const old_pointer_valid Bool)
(declare-const violation Bool)

(assert (! exit_completed :named first_extent_exited))
(assert (! reentry_attempted :named continuation_reentry_attempted))
(assert (! backing_moved_after_exit :named backing_move_witness))
(assert (! (= retired exit_completed)
           :named retirement_follows_first_exit))
(assert (! before_allows_entry :named omitted_guard_allows_reentry))
(assert (! (= callback_resumed
              (and reentry_attempted before_allows_entry))
           :named callback_runs_after_unguarded_before))
(assert (! (= old_pointer_valid
              (not (and exit_completed backing_moved_after_exit)))
           :named old_address_invalid_if_backing_moves))
(assert (! (= violation
              (and callback_resumed (not old_pointer_valid)))
           :named stale_pointer_resume_violation))
(assert (! violation :named expected_bug_query))
