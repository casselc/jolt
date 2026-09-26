;; Recovered OutputStreamWriter overload regression; no compiler fast path.
(import (chezscheme))
(load "host/chez/gate-boot.ss")
(define total 0) (define fails 0)
(define (is name expr expected)
  (set! total (+ total 1))
  (guard (e (#t (set! fails (+ fails 1)) (printf "FAIL: ~a raised ~a~n" name e)))
    (let ((actual (jolt-pr-readable (jolt-compile-eval expr "user"))))
      (unless (string=? actual expected)
        (set! fails (+ fails 1))
        (printf "FAIL: ~a expected ~s got ~s~n" name expected actual)))))
(is "nonzero start and end-not-count"
    "(let [b (java.io.ByteArrayOutputStream.) w (java.io.OutputStreamWriter. b \"UTF-8\")] (.append w \"abcdef\" 2 5) (.flush w) (.toString b \"UTF-8\"))"
    "\"cde\"")
(is "empty range and exact end"
    "(let [b (java.io.ByteArrayOutputStream.) w (java.io.OutputStreamWriter. b)] (.append w \"abcdef\" 2 2) (.append w \"abcdef\" 4 6) (.flush w) (.toString b))"
    "\"ef\"")
(is "null character StringBuilder and fluent identity"
    "(let [b (java.io.ByteArrayOutputStream.) w (java.io.OutputStreamWriter. b)] [(identical? w (.append w nil)) (identical? w (.append w nil 1 3)) (identical? w (.append w \\B)) (identical? w (.append w (StringBuilder. \"abcdef\") 1 4)) (do (.flush w) (.toString b))])"
    "[true true true true \"nullulBbcd\"]")
(is "Unicode selected codepoint range"
    "(let [b (java.io.ByteArrayOutputStream.) w (java.io.OutputStreamWriter. b \"UTF-8\")] (.append w \"aβ😀z\" 1 3) (.flush w) (.toString b \"UTF-8\"))"
    "\"β😀\"")
(is "invalid ranges reject before output"
    "(mapv (fn [[a z]] (let [b (java.io.ByteArrayOutputStream.) w (java.io.OutputStreamWriter. b)] (let [rejected (try (.append w \"abc\" a z) false (catch IndexOutOfBoundsException e true))] (.flush w) [rejected (.toString b)]))) [[-1 1] [0 4] [2 1]])"
    "[[true \"\"] [true \"\"] [true \"\"]]")
(is "range used around escaped JSON runs preserves exact bytes"
    "(let [b (java.io.ByteArrayOutputStream.) w (java.io.OutputStreamWriter. b \"UTF-8\") s (str \"x\" (char 10) \"y\")] (.append w \"\\\"\") (.append w s 0 1) (.append w \"\\\\n\") (.append w s 2 3) (.append w \"\\\"\") (.flush w) (vec (.toByteArray b)))"
    "[34 120 92 110 121 34]")
(is "close flushes appended selected text"
    "(let [b (java.io.ByteArrayOutputStream.) w (java.io.OutputStreamWriter. b)] (.append w \"closed!\" 0 6) (.close w) (.toString b))"
    "\"closed\"")
(printf "osw-append-recovery-test: ~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
