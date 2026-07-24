; Expected result: UNSAT.
; Corrected same-namespace reload: reconstructed cells exactly match new source;
; otherwise retention taints the generation and prevents cached execution.
;
; Observed named UNSAT core:
;   actual_cell_after_reload_definition
;   unreconstructed_reload_definition
;   corrected_reload_taint_enabled
;   generation_taint_definition
;   cache_execution_gate_definition
;   stale_cell_residue_definition
;   violation_definition
;   violation_query
;
; Chiasmus supplies check-sat/UNSAT-core extraction.

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
(assert (! violation :named violation_query))
