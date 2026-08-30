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

;; The exact-#23 baseline was unbounded where the JVM wraps at 32/64 bits. Pin
;; every RMW method at both signed boundaries, plus signature conversion for
;; the other value-taking methods and callback results (jolt-aspect-packs#36).
(define typed-boundaries
  (ev "(let [imax 2147483647
             imin -2147483648
             lmax 9223372036854775807
             lmin -9223372036854775808]
         [(.incrementAndGet (java.util.concurrent.atomic.AtomicInteger. imax))
          (.decrementAndGet (java.util.concurrent.atomic.AtomicInteger. imin))
          (let [a (java.util.concurrent.atomic.AtomicInteger. imax)]
            [(.getAndIncrement a) (.get a)])
          (let [a (java.util.concurrent.atomic.AtomicInteger. imin)]
            [(.getAndDecrement a) (.get a)])
          (.addAndGet (java.util.concurrent.atomic.AtomicInteger. 2147483640) 10)
          (let [a (java.util.concurrent.atomic.AtomicInteger. -2147483640)]
            [(.getAndAdd a -10) (.get a)])
          (.incrementAndGet (java.util.concurrent.atomic.AtomicLong. lmax))
          (.decrementAndGet (java.util.concurrent.atomic.AtomicLong. lmin))
          (let [a (java.util.concurrent.atomic.AtomicLong. lmax)]
            [(.getAndIncrement a) (.get a)])
          (let [a (java.util.concurrent.atomic.AtomicLong. lmin)]
            [(.getAndDecrement a) (.get a)])
          (.addAndGet (java.util.concurrent.atomic.AtomicLong. 9223372036854775800) 10)
          (let [a (java.util.concurrent.atomic.AtomicLong. -9223372036854775800)]
            [(.getAndAdd a -10) (.get a)])])"))
(ok "all integer and long RMW methods return JVM-width wrapped values"
    (jolt=2 typed-boundaries
      (jolt-vector -2147483648 2147483647
                   (jolt-vector 2147483647 -2147483648)
                   (jolt-vector -2147483648 2147483647)
                   -2147483646
                   (jolt-vector -2147483640 2147483646)
                   -9223372036854775808 9223372036854775807
                   (jolt-vector 9223372036854775807 -9223372036854775808)
                   (jolt-vector -9223372036854775808 9223372036854775807)
                   -9223372036854775806
                   (jolt-vector -9223372036854775800 9223372036854775806))))

(define typed-conversions
  (ev "(let [i (java.util.concurrent.atomic.AtomicInteger. 2.9)
             l (java.util.concurrent.atomic.AtomicLong. 2.9)
             is (java.util.concurrent.atomic.AtomicInteger. -9)
             ls (java.util.concurrent.atomic.AtomicLong. -9)
             iu (java.util.concurrent.atomic.AtomicInteger. 1)
             lu (java.util.concurrent.atomic.AtomicLong. 1)]
         [(.get i) (.get l)
          [(.getAndSet is 3.9) (.get is)]
          [(.getAndSet ls 3.9) (.get ls)]
          [(.updateAndGet iu (fn [_] 4.9)) (.get iu)]
          [(.getAndUpdate lu (fn [_] 4.9)) (.get lu)]
          (.intValue (java.util.concurrent.atomic.AtomicLong. 4294967295))
          (.longValue (java.util.concurrent.atomic.AtomicInteger. -2147483648))])"))
(ok "constructor, getAndSet, callback, and Number views retain primitive widths"
    (jolt=2 typed-conversions
      (jolt-vector 2 2
                   (jolt-vector -9 3) (jolt-vector -9 3)
                   (jolt-vector 4 4) (jolt-vector 1 4)
                   -1 -2147483648)))

(define typed-failures
  (ev "(let [i (java.util.concurrent.atomic.AtomicInteger. 7)
             l (java.util.concurrent.atomic.AtomicLong. 7)
             result (fn [f]
                      (try (f)
                           (catch Throwable e
                             [(.getName (class e)) (.getMessage e)])))]
         [(result (fn [] (java.util.concurrent.atomic.AtomicInteger. 2147483648)))
          [(result (fn [] (.set i 2147483648))) (.get i)]
          [(result (fn [] (.getAndSet l 9223372036854775808N))) (.get l)]
          [(result (fn [] (.updateAndGet i (fn [_] 2147483648)))) (.get i)]])"))
(ok "out-of-width inputs retain JVM exception types and do not mutate cells"
    (jolt=2 typed-failures
      (jolt-vector
       (jolt-vector "java.lang.ArithmeticException" "integer overflow")
       (jolt-vector
        (jolt-vector "java.lang.ArithmeticException" "integer overflow") 7)
       (jolt-vector
        (jolt-vector "java.lang.IllegalArgumentException"
                     "Value out of range for long: 9223372036854775808") 7)
       (jolt-vector
        (jolt-vector "java.lang.ArithmeticException" "integer overflow") 7))))

;; Crossing the wrap boundary concurrently must still form one linearizable
;; getAndIncrement history: every old value is unique and the final state is the
;; modeled wrapped sum.  This checks return values, not only the final count.
(define concurrent-wrap
  (ev "(let [i (java.util.concurrent.atomic.AtomicInteger. 2147483547)
             l (java.util.concurrent.atomic.AtomicLong. 9223372036854775707)
             workers (mapv
                       (fn [_]
                         (future
                           (loop [n 0 iv [] lv []]
                             (if (= n 2000)
                               [iv lv]
                               (recur (inc n)
                                      (conj iv (.getAndIncrement i))
                                      (conj lv (.getAndIncrement l)))))))
                       (range 4))
             histories (mapv deref workers)
             ivals (vec (mapcat first histories))
             lvals (vec (mapcat second histories))]
         [(.get i) (count ivals) (count (set ivals))
          (.get l) (count lvals) (count (set lvals))])"))
(ok "concurrent wrapped RMW histories have unique return values and modeled finals"
    (jolt=2 concurrent-wrap
      (jolt-vector -2147475749 8000 8000 -9223372036854767909 8000 8000)))
(ok "typed boundary tests exit with no counted lock retained" (= 0 (jolt-locks-held)))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
