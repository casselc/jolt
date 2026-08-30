;; AtomicInteger/AtomicLong arithmetic-method lock boundary regression.
;; Run: chez --script test/chez/atomic-numeric-test.ss
;;
;; The caller-provided delta is not trusted leaf data: converting it can raise
;; and constructs a modeled JVM throwable.  Both activities must finish before
;; the counted per-atomic mutex is entered.  Wrap the two conversion seams so
;; this test observes the actual lock count rather than inferring it from a
;; successful call or hoping that an error happens to re-enter.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a\n" name)))
(define (ev s) (jolt-compile-eval s "user"))

(define conversion-lock-counts '())
(define error-lock-counts '())
(define base-jolt-need-num jolt-need-num)
(define base-jolt-num-cast-throw jolt-num-cast-throw)
(define success #f)
(define failure-results #f)
(define expected-failure
  (jolt-vector "java.lang.ClassCastException"
               "class java.lang.String cannot be cast to class java.lang.Number"))
(define concurrent #f)

(dynamic-wind
  (lambda ()
    (set! jolt-need-num
      (lambda (x)
        (set! conversion-lock-counts
          (cons (jolt-locks-held) conversion-lock-counts))
        (base-jolt-need-num x)))
    (set! jolt-num-cast-throw
      (lambda (x)
        (set! error-lock-counts (cons (jolt-locks-held) error-lock-counts))
        (base-jolt-num-cast-throw x))))
  (lambda ()

    (set! success
      (ev "(let [i (java.util.concurrent.atomic.AtomicInteger. 0)
             l (java.util.concurrent.atomic.AtomicLong. 0)
             ia (.addAndGet i 2.9)
             ig (.getAndAdd i 3.9)
             la (.addAndGet l 4.9)
             lg (.getAndAdd l 5.9)]
         [ia ig (.get i) la lg (.get l)])"))
    (ok "addAndGet/getAndAdd preserve converted Integer and Long values"
        (jolt=2 success (jolt-vector 2 2 5 4 4 9)))

    (set! failure-results
      (ev "(mapv (fn [f]
               (try (f)
                    (catch Throwable e
                      [(.getName (class e)) (.getMessage e)])))
             [(fn [] (.addAndGet
                       (java.util.concurrent.atomic.AtomicInteger. 0) \"bad\"))
              (fn [] (.getAndAdd
                       (java.util.concurrent.atomic.AtomicLong. 0) \"bad\"))])"))
    (ok "wrong deltas retain the exact modeled JVM exception class and message"
        (jolt=2 failure-results (jolt-vector expected-failure expected-failure)))

    (ok "every delta conversion observes zero counted locks"
        (and (pair? conversion-lock-counts)
             (for-all zero? conversion-lock-counts)))
    (ok "typed error construction observes zero counted locks"
        (and (= 2 (length error-lock-counts))
             (for-all zero? error-lock-counts)))

;; The lock region still has to serialize the leaf transition.  Exercise both
;; methods and both kinds from real worker threads; this would lose increments
;; if moving conversion changed the transition's mutex coverage.
    (set! concurrent
      (ev "(let [i (java.util.concurrent.atomic.AtomicInteger. 0)
             l (java.util.concurrent.atomic.AtomicLong. 0)
             workers (mapv
                       (fn [_]
                         (future
                           (dotimes [_ 2000]
                             (.getAndAdd i 1)
                             (.addAndGet l 1))))
                       (range 4))]
         (doseq [w workers] (deref w))
         [(.get i) (.get l)])"))
    (ok "concurrent Integer and Long additions lose no updates"
        (jolt=2 concurrent (jolt-vector 8000 8000)))
    (ok "test exits with no counted lock retained" (= 0 (jolt-locks-held))))
  (lambda ()
    (set! jolt-need-num base-jolt-need-num)
    (set! jolt-num-cast-throw base-jolt-num-cast-throw)))

;; Arithmetic overflow parity is deliberately not pinned here.  The exact-#23
;; baseline is unbounded where the JVM wraps at 32/64 bits; that distinct defect
;; is tracked by chucklehead-dev/jolt-aspect-packs#36.

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
