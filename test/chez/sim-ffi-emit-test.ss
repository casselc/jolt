;; Compiler-flavor witness: ordinary emission has no hook reference; sim
;; emission carries one exact scalar descriptor/native thunk branch.
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a~n" name)))
(define (contains? s needle)
  (let ((n (string-length s)) (m (string-length needle)))
    (let loop ((i 0))
      (and (<= (+ i m) n)
           (or (string=? (substring s i (+ i m)) needle) (loop (+ i 1)))))))
(define analyze (var-deref "jolt.analyzer" "analyze"))
(define emit (var-deref "jolt.backend-scheme" "emit"))
(define set-sim! (var-deref "jolt.backend-scheme" "set-sim-instrument!"))
(define form (jolt-ce-read "(jolt.ffi/__cfn \"jolt_missing_sim_symbol\" [:int32] :int64)"))
(define node (analyze (make-analyze-ctx "user") form))
(set-sim! #f)
(define ordinary (emit node))
(set-sim! #t)
(define simulated (emit node))
(set-sim! #f)
(ok "ordinary FFI emission contains no sim hook"
    (and (not (contains? ordinary "jolt-ffi-sim-hook"))
         (not (contains? ordinary "jolt-sim-current-ffi-hook"))))
(ok "sim FFI emission snapshots the effective composite hook"
    (contains? simulated "(let ((h (jolt-sim-current-ffi-hook)))"))
(ok "sim descriptor keeps exact scalar widths"
    (and (contains? simulated "\"int32\"")
         (contains? simulated "\"int64\"")))
(ok "sim branch defers native resolution in a thunk"
    (contains? simulated "(lambda () ((or p"))
(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
