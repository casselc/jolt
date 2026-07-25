; Boundary/non-vacuity control for git-cache-path-budget-corrected.smt2.
; The largest modeled cache root and recursive suffix remain reachable at
; length 219, exactly one character below Git's rejection boundary.

(declare-const cache_root_length Int)
(declare-const layout_stage_length Int)
(declare-const recursive_suffix_length Int)
(declare-const git_dir_guard Int)

(assert (! (= cache_root_length 80)
           :named boundary_cache_root_length))
(assert (! (= layout_stage_length 54)
           :named compact_v3_layout_stage_length))
(assert (! (= recursive_suffix_length 85)
           :named boundary_recursive_suffix_length))
(assert (! (= git_dir_guard 220)
           :named git_path_max_minus_40_guard))

(declare-const git_dir_length Int)
(assert (! (= git_dir_length
              (+ cache_root_length
                 layout_stage_length
                 recursive_suffix_length))
           :named git_dir_length_definition))

(declare-const valid Bool)
(assert (! (= valid (< git_dir_length git_dir_guard))
           :named valid_definition))
(assert (! valid :named nonvacuity_query))
(assert (! (= git_dir_length 219)
           :named inclusive_boundary_reachable))
