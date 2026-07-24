; Corrected executor admission: shutdown publication and enqueue admission
; linearize under the same queue mutex.  An enqueue is accepted exactly when it
; owns that mutex before shutdown; otherwise it throws synchronously.
;
; Expected: UNSAT for an accepted enqueue after shutdown has returned.

(declare-const shutdown_linearization_step Int)
(declare-const shutdown_return_step Int)
(declare-const enqueue_linearization_step Int)

(assert (! (and (<= 0 shutdown_linearization_step)
                (<= shutdown_linearization_step 2)
                (<= 0 shutdown_return_step)
                (<= shutdown_return_step 2)
                (<= 0 enqueue_linearization_step)
                (<= enqueue_linearization_step 2))
           :named bounded_steps))
(assert (! (distinct shutdown_linearization_step
                     shutdown_return_step
                     enqueue_linearization_step)
           :named serialized_transitions))
(assert (! (< shutdown_linearization_step shutdown_return_step)
           :named shutdown_publishes_before_return))

(declare-const implementation_accepts Bool)
(assert (! (= implementation_accepts
              (< enqueue_linearization_step shutdown_linearization_step))
           :named accept_iff_enqueue_linearizes_first))

(declare-const accepted_after_shutdown_return Bool)
(assert (! (= accepted_after_shutdown_return
              (and implementation_accepts
                   (< shutdown_return_step enqueue_linearization_step)))
           :named violation_definition))
(assert (! accepted_after_shutdown_return :named violation_query))
