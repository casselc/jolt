; One-fault control for a scoped interior pointer. The retirement guard is
; omitted, so re-entry resumes the receiver with the address computed during
; the first extent. A collection while retired may have moved the backing.

(declare-const exit_completed Bool)
(declare-const reentry_attempted Bool)
(declare-const backing_moved_after_exit Bool)
(declare-const retired Bool)
(declare-const receiver_resumed Bool)
(declare-const old_pointer_valid Bool)

(assert (! exit_completed :named first_extent_exited))
(assert (! reentry_attempted :named continuation_reentry_attempted))
(assert (! backing_moved_after_exit :named backing_move_witness))
(assert (! (= retired exit_completed)
           :named retirement_follows_every_exit))
(assert (! (= receiver_resumed reentry_attempted)
           :named retirement_guard_omitted_bug))
(assert (! (= old_pointer_valid
              (not (and exit_completed backing_moved_after_exit)))
           :named old_address_invalid_if_backing_moves))

(declare-const violation Bool)
(assert (! (= violation
              (and receiver_resumed (not old_pointer_valid)))
           :named stale_pointer_resume_violation))
(assert (! violation :named expected_bug_witness))
