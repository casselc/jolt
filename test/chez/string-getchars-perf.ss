;; Non-default scaling characterization for String.getChars.
;; It reports absolute and per-character costs at two sizes, while correctness
;; and the no-ja-set causal assertion live in string-getchars-test.ss. Timing is
;; deliberately manual: loaded machines must not turn a constant-factor probe
;; into a flaky correctness gate.
;;
;;   chez --script test/chez/string-getchars-perf.ss

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define (now-ms)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000.0 (time-second t)) (/ (time-nanosecond t) 1000000.0))))

(jolt-compile-eval
  "(defn copy-ranges [^String source dst repetitions size] (dotimes [_ repetitions] (.getChars source 0 size dst 0)) (count dst))"
  "user")
(define copy-ranges (var-deref "user" "copy-ranges"))

(define (best-ms size repetitions)
  (let ((source (make-string size #\x))
        (dst (na-char-array size)))
  (let loop ((run 0) (best +inf.0))
    (if (fx=? run 4)
        best
        (let* ((started (now-ms))
               (actual (jolt-invoke4 copy-ranges source dst repetitions size))
               (elapsed (- (now-ms) started)))
          (unless (= actual size)
            (error 'string-getchars-perf "copy result drifted" actual size))
          (loop (fx+ run 1) (min best elapsed)))))))

;; Equal total copied characters, different range sizes. The report exposes
;; both fixed call overhead and the per-character slope without asserting a
;; machine-specific wall-clock threshold.
(jolt-invoke4 copy-ranges (make-string 1024 #\x) (na-char-array 1024) 8 1024)
(let* ((small-size 1024) (small-repetitions 4096)
       (large-size 65536) (large-repetitions 64)
       (small (best-ms small-size small-repetitions))
       (large (best-ms large-size large-repetitions))
       (total-chars (* small-size small-repetitions)))
  (printf "~a chars as ~a x ~a: ~a ms (~a ns/char)\n"
          total-chars small-repetitions small-size small
          (/ (* small 1000000.0) total-chars))
  (printf "~a chars as ~a x ~a: ~a ms (~a ns/char)\n"
          total-chars large-repetitions large-size large
          (/ (* large 1000000.0) total-chars))
  (exit 0))
