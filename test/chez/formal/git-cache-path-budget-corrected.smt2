; Bounded counterexample query for the compact git-v3 coordinate cache.
;
; Domain:
;   cache root length                 3..80
;   fixed git-v3 stage layout            54
;   recursive submodule suffix        0..85
;   Git for Windows rejection boundary  220
;
; SAT would be a coordinate inside those bounds whose exported GIT_DIR reaches
; the rejection boundary. UNSAT means no such counterexample exists in this
; arithmetic model.

(declare-const cache_root_length Int)
(declare-const layout_stage_length Int)
(declare-const recursive_suffix_length Int)
(declare-const git_dir_guard Int)

(assert (! (and (<= 3 cache_root_length)
                (<= cache_root_length 80))
           :named cache_root_domain))
(assert (! (= layout_stage_length 54)
           :named compact_v3_layout_stage_length))
(assert (! (and (<= 0 recursive_suffix_length)
                (<= recursive_suffix_length 85))
           :named recursive_suffix_domain))
(assert (! (= git_dir_guard 220)
           :named git_path_max_minus_40_guard))

(declare-const git_dir_length Int)
(assert (! (= git_dir_length
              (+ cache_root_length
                 layout_stage_length
                 recursive_suffix_length))
           :named git_dir_length_definition))

(declare-const violation Bool)
(assert (! (= violation (>= git_dir_length git_dir_guard))
           :named violation_definition))
(assert (! violation :named violation_query))
