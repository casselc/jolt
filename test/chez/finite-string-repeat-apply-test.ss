(import (chezscheme))
(load "host/chez/rt.ss")
(define checks 0)
(define failures 0)
(define (ok label condition)
  (set! checks (+ checks 1))
  (unless condition (set! failures (+ failures 1)) (printf "FAIL ~a\n" label)))
(define (generic-str . args) (apply jolt-str args))
(for-each
 (lambda (piece)
   (for-each
    (lambda (n)
      (ok "same output as generic apply"
          (string=? (jolt-apply jolt-str (jolt-repeat n piece))
                    (jolt-apply generic-str (jolt-repeat n piece)))))
    '(-2 0 1 2 15 16 32 255 4096)))
 '("" "0" "ab" "é😀\n"))
(let ((s (jolt-repeat 32 "0")))
  (ok "candidate actually avoids realizing the repeated tail"
      (and (string=? (jolt-apply jolt-str s) (make-string 32 #\0))
           (lazy-src? (cseq-tail s))))
  (ok "retained input is reusable" (string=? (jolt-apply generic-str s) (make-string 32 #\0))))
(let ((s (jolt-repeat 3 "ab")))
  (seq-more s)
  (ok "already realized tail declines" (not (apply-str-finite-repeat s)))
  (ok "already realized output" (string=? (jolt-apply jolt-str s) "ababab")))
(ok "infinite Repeat declines" (not (apply-str-finite-repeat (jolt-repeat "0"))))
(ok "zero-step range declines" (not (apply-str-finite-repeat (jolt-range 1 5 0))))
(ok "nonstring Repeat declines" (not (apply-str-finite-repeat (jolt-repeat 3 12))))
(ok "nonstring uses normal rendering" (string=? (jolt-apply jolt-str (jolt-repeat 3 12)) "121212"))
(ok "fixed leading arguments retain generic behavior"
    (string=? (jolt-apply jolt-str "prefix" (jolt-repeat 3 "0")) "prefix000"))
(ok "custom functions retain invocation" (= (jolt-apply + (jolt-repeat 3 2)) 6))
(let ((old str-tostring-hook) (calls 0) (value (vector 'custom-value)))
  (dynamic-wind
    (lambda ()
      (set! str-tostring-hook
        (lambda (x)
          (if (eq? x value)
              (begin (set! calls (+ calls 1)) (number->string calls))
              (and old (old x))))))
    (lambda ()
      (let* ((actual (jolt-apply jolt-str (jolt-repeat 3 value)))
             (actual-calls calls)
             (_ (set! calls 0))
             (control (jolt-apply generic-str (jolt-repeat 3 value))))
        ;; Slice equivalence only. Parent renders these callbacks right-to-left
        ;; (321), a separately recorded pre-existing conformance defect. Do not
        ;; assert that this baseline behavior is JVM-correct.
        (ok "custom values retain generic rendering behavior and callback count"
            (and (string=? actual control) (= actual-calls 3) (= calls 3)))))
    (lambda () (set! str-tostring-hook old))))
(let* ((calls 0)
       (source (cseq-lazy "a" (lambda ()
                               (set! calls (+ calls 1)) (jolt-repeat 2 "b")))))
  (ok "arbitrary lazy tail keeps its realization effects"
      (and (string=? (jolt-apply jolt-str source) "abb") (= calls 1))))
(let ((piece (string-copy "single")))
  (ok "single argument preserves String identity"
      (eq? piece (jolt-apply jolt-str (jolt-repeat 1 piece)))))
(let ((a (jolt-apply jolt-str (jolt-repeat 3 "ab"))))
  (string-set! a 0 #\x)
  (ok "returned strings independent" (string=? (jolt-apply jolt-str (jolt-repeat 3 "ab")) "ababab")))
(printf "finite-string-repeat: ~a/~a checks passed\n" (- checks failures) checks)
(exit (if (= failures 0) 0 1))
