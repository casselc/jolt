; Bounded counterexample query for one scoped byte-array pointer loan.
;
; Domain/abstraction: Boolean facts for the first dynamic extent's exit, one
; later continuation reentry attempt, a possible backing move while unlocked,
; the retired flag, before-thunk admission, callback resumption, and old-pointer
; validity. This models the source ordering in host/chez/java/ffi.ss, not Chez's
; collector or dynamic-wind implementation. Expected result: UNSAT.

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
(assert (! (= retired exit_completed)
           :named retirement_follows_first_exit))
(assert (! (= before_allows_entry (not retired))
           :named before_guard_rejects_retired_scope))
(assert (! (= callback_resumed
              (and reentry_attempted before_allows_entry))
           :named callback_runs_only_after_before_guard))
(assert (! (= old_pointer_valid
              (not (and exit_completed backing_moved_after_exit)))
           :named old_address_invalid_if_backing_moves))
(assert (! (= violation
              (and callback_resumed (not old_pointer_valid)))
           :named stale_pointer_resume_violation))
(assert (! violation :named counterexample_query))
