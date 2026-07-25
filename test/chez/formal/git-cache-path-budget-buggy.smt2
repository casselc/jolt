; Known-SAT control for the Git for Windows recursive-submodule path failure.
;
; Live 2026-07-24 witness:
;   cache root                         66
;   git-v2 URL/SHA stage layout        95
;   nested submodule GIT_DIR suffix    65
;   total                             226
;
; Git rejects an explicit GIT_DIR whose length is >= PATH_MAX-40. The observed
; Git for Windows build uses PATH_MAX=260, so the rejection boundary is 220.

(declare-const cache_root_length Int)
(declare-const layout_stage_length Int)
(declare-const recursive_suffix_length Int)
(declare-const git_dir_guard Int)

(assert (! (= cache_root_length 66)
           :named observed_cache_root_length))
(assert (! (= layout_stage_length 95)
           :named old_v2_layout_stage_length))
(assert (! (= recursive_suffix_length 65)
           :named observed_recursive_suffix_length))
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
