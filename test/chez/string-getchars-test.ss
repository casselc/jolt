;; String.getChars must validate every range before touching the destination,
;; then copy without re-running the generic array bounds/type path per character.
;;
;;   chez --script test/chez/string-getchars-test.ss

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok label pred)
  (set! total (fx+ total 1))
  (unless pred
    (set! fails (fx+ fails 1))
    (printf "FAIL: ~a\n" label)))
(define (ev source) (jolt-final-str (jolt-compile-eval source "user")))
(define (is label source expected)
  (let ((actual (ev source)))
    (ok (format "~a: expected ~s, got ~s" label expected actual)
        (string=? expected actual))))

(is "valid offset copy returns nil and preserves untouched cells"
    "(let [dst (char-array [\\x \\x \\x \\x \\x])] [(.getChars \"abcd\" 1 4 dst 1) (vec dst)])"
    "[nil [\\x \\b \\c \\d \\x]]")
(is "empty copy is valid at both ends"
    "(let [dst (char-array [\\x \\y])] [(.getChars \"ab\" 2 2 dst 2) (vec dst)])"
    "[nil [\\x \\y]]")

;; The JVM validates the complete source and destination ranges before copying.
;; Each invalid call must therefore leave every sentinel intact. This kills the
;; old loop, which copied a valid prefix before destination overflow failed.
(is "all invalid ranges are StringIndexOutOfBoundsException and nonmutating"
    "(mapv (fn [[begin end offset size]] (let [dst (char-array (repeat size \\x))] [(try (.getChars \"abcd\" begin end dst offset) :ok (catch Throwable e (.getSimpleName (class e)))) (vec dst)])) [[-1 2 0 4] [0 5 0 5] [3 2 0 4] [0 2 -1 4] [0 3 0 2] [0 0 5 4]])"
    "[[StringIndexOutOfBoundsException [\\x \\x \\x \\x]] [StringIndexOutOfBoundsException [\\x \\x \\x \\x \\x]] [StringIndexOutOfBoundsException [\\x \\x \\x \\x]] [StringIndexOutOfBoundsException [\\x \\x \\x \\x]] [StringIndexOutOfBoundsException [\\x \\x]] [StringIndexOutOfBoundsException [\\x \\x \\x \\x]]]")
(is "source range failure precedes nil destination failure"
    "[(try (.getChars \"abcd\" -1 2 nil 0) (catch Throwable e (.getSimpleName (class e)))) (try (.getChars \"abcd\" 0 0 nil 0) (catch Throwable e (.getSimpleName (class e))))]"
    "[StringIndexOutOfBoundsException NullPointerException]")

;; Receiver and arguments are ordinary Clojure expressions. The direct emitter
;; may splice each exactly once, in source order, but cannot skip later argument
;; evaluation merely because the eventual invocation will fail validation.
(is "receiver and arguments evaluate once in order"
    "(let [seen (atom []) dst (char-array (repeat 4 \\x))] (try (.getChars (do (swap! seen conj :receiver) \"abcd\") (do (swap! seen conj :begin) 3) (do (swap! seen conj :end) 2) (do (swap! seen conj :dst) dst) (do (swap! seen conj :offset) 0)) (catch Throwable _)) [@seen (vec dst)])"
    "[[:receiver :begin :end :dst :offset] [\\x \\x \\x \\x]]")

;; Jolt strings are currently scalar-indexed (#119), unlike JVM UTF-16 Strings.
;; getChars must retain that established representation until that separate
;; contract changes; this optimization cannot silently split astral scalars.
(is "astral source retains current scalar indexing"
    "(let [dst (char-array 3)] (.getChars \"a𝄞b\" 0 3 dst 0) (mapv int dst))"
    "[97 119070 98]")

;; Causal control: the validated copy must not fall back to checked ja-set! in
;; its inner loop. Wrapping that old seam makes an otherwise value-equivalent
;; implementation observable and kills the previous implementation directly.
(let ((original ja-set!) (stores 0))
  (dynamic-wind
    (lambda () (set! ja-set! (lambda args (set! stores (fx+ stores 1)) (apply original args))))
    (lambda ()
      (is "copy bypasses checked per-element ja-set!"
          "(let [dst (char-array 4096)] (.getChars (apply str (repeat 4096 \"x\")) 0 4096 dst 0) (count dst))"
          "4096")
      (ok "checked per-element store count is zero" (fx=? stores 0)))
    (lambda () (set! ja-set! original))))

(printf "string-getchars-test: ~a/~a passed\n" (fx- total fails) total)
(exit (if (fx=? fails 0) 0 1))
