; Non-vacuity control for the corrected scoped-pointer guard.
;
; Before the first exit, the same before guard must admit the initial entry and
; the callback must observe a valid pointer. Expected result: SAT with
; useful_live_scope=true.

(declare-const exit_completed Bool)
(declare-const entry_attempted Bool)
(declare-const retired Bool)
(declare-const before_allows_entry Bool)
(declare-const callback_resumed Bool)
(declare-const pointer_valid Bool)
(declare-const useful_live_scope Bool)

(assert (! (not exit_completed) :named initial_extent_is_live))
(assert (! entry_attempted :named initial_entry_attempted))
(assert (! (= retired exit_completed)
           :named retirement_follows_first_exit))
(assert (! (= before_allows_entry (not retired))
           :named before_guard_allows_live_scope))
(assert (! (= callback_resumed
              (and entry_attempted before_allows_entry))
           :named callback_runs_after_before_guard))
(assert (! (= pointer_valid (not retired))
           :named live_pointer_validity))
(assert (! (= useful_live_scope
              (and callback_resumed pointer_valid))
           :named useful_scope_definition))
(assert (! useful_live_scope :named nonvacuity_query))
