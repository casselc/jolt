; Bounded counterexample query for a scoped interior pointer after a
; continuation exits and later attempts to re-enter the scope.
;
; The address was computed during the first entry. Once that dynamic extent
; exits, the bytevector is unlocked and may move. The corrected retirement
; guard refuses re-entry before the receiver can resume with the stale address.

(declare-const exit_completed Bool)
(declare-const reentry_attempted Bool)
(declare-const backing_moved_after_exit Bool)
(declare-const retired Bool)
(declare-const receiver_resumed Bool)
(declare-const old_pointer_valid Bool)

(assert (! exit_completed :named first_extent_exited))
(assert (! reentry_attempted :named continuation_reentry_attempted))
(assert (! (= retired exit_completed)
           :named retirement_follows_every_exit))
(assert (! (= receiver_resumed
              (and reentry_attempted (not retired)))
           :named retirement_guard_precedes_receiver_resume))
(assert (! (= old_pointer_valid
              (not (and exit_completed backing_moved_after_exit)))
           :named old_address_invalid_if_backing_moves))

(declare-const violation Bool)
(assert (! (= violation
              (and receiver_resumed (not old_pointer_valid)))
           :named stale_pointer_resume_violation))
(assert (! violation :named counterexample_query))
