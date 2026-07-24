; Expected result: SAT.
; Non-vacuity control: a same-namespace reload reconstructs its cells from the
; new source, removes old macro residue, remains untainted, and may execute.
;
; Observed witness:
;   reload_event=same_namespace_reload
;   intended_new_cell_state=cell_nonmacro
;   cell_handling=reconstruct_namespace_cells
;   actual_cell_after_reload=cell_nonmacro
;   generation_tainted=false, cache_execution_allowed=true
;   stale_macro_residue=false, violation=false
;
; Chiasmus supplies check-sat/model extraction.

(declare-datatypes ()
  ((ReloadEvent no_reload same_namespace_reload)
   (CellState cell_absent cell_nonmacro cell_macro)
   (CellHandling retain_old_cells reconstruct_namespace_cells)))

(declare-const reload_event ReloadEvent)
(declare-const old_cell_state CellState)
(declare-const intended_new_cell_state CellState)
(declare-const cell_handling CellHandling)
(assert (! (= old_cell_state cell_macro)
           :named old_cell_state_definition))

(declare-const actual_cell_after_reload CellState)
(assert (! (= actual_cell_after_reload
              (ite (= reload_event same_namespace_reload)
                   (ite (= cell_handling reconstruct_namespace_cells)
                        intended_new_cell_state
                        old_cell_state)
                   old_cell_state))
           :named actual_cell_after_reload_definition))
(declare-const unreconstructed_same_namespace_reload Bool)
(assert (! (= unreconstructed_same_namespace_reload
              (and (= reload_event same_namespace_reload)
                   (= cell_handling retain_old_cells)))
           :named unreconstructed_reload_definition))

(declare-const taint_unreconstructed_reload Bool)
(assert (! (= taint_unreconstructed_reload true)
           :named corrected_reload_taint_enabled))
(declare-const generation_tainted Bool)
(assert (! (= generation_tainted
              (and taint_unreconstructed_reload
                   unreconstructed_same_namespace_reload))
           :named generation_taint_definition))
(declare-const cache_execution_allowed Bool)
(assert (! (= cache_execution_allowed
              (not generation_tainted))
           :named cache_execution_gate_definition))

(declare-const stale_cell_residue Bool)
(assert (! (= stale_cell_residue
              (and (= reload_event same_namespace_reload)
                   (not (= actual_cell_after_reload
                           intended_new_cell_state))))
           :named stale_cell_residue_definition))
(declare-const stale_macro_residue Bool)
(assert (! (= stale_macro_residue
              (and stale_cell_residue
                   (= actual_cell_after_reload cell_macro)
                   (not (= intended_new_cell_state cell_macro))))
           :named stale_macro_residue_definition))
(declare-const violation Bool)
(assert (! (= violation
              (and cache_execution_allowed stale_cell_residue))
           :named violation_definition))

(assert (! (= reload_event same_namespace_reload)
           :named boundary_same_namespace_reload))
(assert (! (= intended_new_cell_state cell_nonmacro)
           :named boundary_new_source_nonmacro))
(assert (! (= cell_handling reconstruct_namespace_cells)
           :named boundary_cells_reconstructed))
(assert (! (= actual_cell_after_reload cell_nonmacro)
           :named reconstructed_cell_matches_source))
(assert (! (not generation_tainted)
           :named reconstructed_generation_untainted))
(assert (! cache_execution_allowed
           :named reconstructed_reload_executes))
(assert (! (not stale_cell_residue)
           :named no_stale_cell_residue))
(assert (! (not violation)
           :named nonvacuous_trace_is_not_violation))
