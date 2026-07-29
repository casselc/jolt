; Non-vacuity control for the corrected scoped-pointer guard. The receiver
; remains reachable during the original live extent, before retirement, and
; observes a valid address.

(declare-const exit_completed Bool)
(declare-const entry_attempted Bool)
(declare-const retired Bool)
(declare-const receiver_resumed Bool)
(declare-const pointer_valid Bool)

(assert (! (not exit_completed) :named live_initial_extent))
(assert (! entry_attempted :named initial_entry_attempted))
(assert (! (= retired exit_completed)
           :named retirement_follows_every_exit))
(assert (! (= receiver_resumed
              (and entry_attempted (not retired)))
           :named retirement_guard_allows_live_entry))
(assert (! (= pointer_valid (not retired))
           :named live_extent_address_validity))

(declare-const useful Bool)
(assert (! (= useful (and receiver_resumed pointer_valid))
           :named useful_live_scope))
(assert (! useful :named nonvacuity_query))
