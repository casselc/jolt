;; Cross-platform regression tests for build subprocess output normalization.

(import (chezscheme))
(load "host/chez/build-output.ss")

(define total 0)
(define fails 0)

(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a\n" name)))

(ok "empty capture stays empty"
    (string=? (bld-captured-lines->string '()) ""))

(ok "Windows CRLF version output loses its carriage return"
    (string=? (bld-captured-lines->string
                (list "Chez Scheme Version 10.4.1\r"))
              "Chez Scheme Version 10.4.1"))

(ok "multiple CRLF lines normalize to LF without concatenation"
    (string=? (bld-captured-lines->string (list "alpha\r" "beta\r"))
              "alpha\nbeta"))

(ok "outer whitespace is trimmed"
    (string=? (bld-captured-lines->string (list "\t alpha " " beta \r"))
              "alpha \n beta"))

(ok "internal whitespace remains significant"
    (string=? (bld-captured-lines->string (list "a  b\r" "c\td\r"))
              "a  b\nc\td"))

(printf "build-output-test: ~a/~a passed\n" (- total fails) total)
(exit (if (> fails 0) 1 0))
