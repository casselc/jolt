;; Internal String scan entry points: the public JVM-shaped corpus cannot call
;; clojure.core/str-find on the reference JVM, so pin its raw start-index guard
;; here. This is specifically what keeps future unchecked adapters safe.
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (fx+ total 1))
  (unless pred
    (set! fails (fx+ fails 1))
    (printf "FAIL: ~a\n" name)))

(define huge (expt 2 200))

(ok "character scan starts at its normalized bound"
    (fx=? 3 (str-char-index-from "abca" #\a 1 4)))
(ok "character scan reports a miss"
    (fx=? -1 (str-char-index-from "abca" #\z 0 4)))
(ok "raw extreme positive start misses"
    (jolt-nil? (str-find "a" "abc" huge)))
(ok "raw extreme positive start clamps empty needle to length"
    (fx=? 3 (str-find "" "abc" huge)))
(ok "raw extreme negative start clamps to zero"
    (fx=? 0 (str-find "a" "abc" (- huge))))
(ok "raw non-integral start follows jolt index truncation"
    (fx=? 1 (str-find "b" "abc" 1.9)))
(ok "raw non-number start is still rejected"
    (guard (e (#t #t))
      (str-find "a" "abc" "not-an-index")
      #f))

(printf "string-indexof-internal-test: ~a/~a passed\n" (- total fails) total)
(exit (if (fx=? fails 0) 0 1))
