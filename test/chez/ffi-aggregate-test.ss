;; Full reader -> analyzer -> Scheme backend -> native ABI evidence for exact
;; scalar widths and pointer-backed C structs passed by value. The companion
;; shell script builds ffi-aggregate-helper.c and supplies its shared library.
;; This is a compiler-source gate and therefore receives a converged transient
;; prelude/image pair rather than relying on the checked bootstrap seed.

(import (chezscheme))

(define seed-args (cdr (command-line)))
(unless (= (length seed-args) 2)
  (display "usage: ffi-aggregate-test.ss PRELUDE IMAGE\n" (current-error-port))
  (exit 2))

(load "host/chez/rt.ss")
(set-chez-ns! "clojure.core")
(load (car seed-args))
(load "host/chez/post-prelude.ss")
(set-chez-ns! "user")
(load "host/chez/host-contract.ss")
(load (cadr seed-args))
(load "host/chez/compile-eval.ss")
(load "host/chez/loader.ss")
(set-source-roots! ldr-install-roots)
(load "host/chez/java/ffi.ss")

(define total 0)
(define fails 0)
(define expected-total 25)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a\n" name)))
(define (ev source) (jolt-compile-eval source "user"))
(define (compile-rejected? source)
  (guard (e (#t #t))
    (ev source)
    #f))

(ev "(require '[jolt.ffi :as ffi])")
;; Process symbols provide libc's abs on every supported target; loading the
;; helper DLL alone is insufficient on Windows because GetProcAddress does not
;; search that DLL's dependency closure.
(ev "(ffi/load-library)")
(ev (string-append "(ffi/load-library "
                   (format "~s" (getenv "JOLT_FFI_AGGREGATE_TEST_LIBRARY"))
                   ")"))

(define date-type
  "[:by-value
     [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]")
(define datetime-type
  "[:by-value
     [:struct
      [[:date [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]
       [:time [:struct [[:hour :uint8] [:minute :uint8] [:second :uint8]
                        [:microsecond :uint32]]]]]]]")

(ev "(def c-abs32 (ffi/foreign-fn \"abs\" [:int32] :int32))")
(ev (string-append
     "(def c-date-value (ffi/foreign-fn \"jolt_test_date_value\" ["
     date-type "] :int))"))
(ev (string-append
     "(def c-date-blocking (ffi/foreign-fn \"jolt_test_date_value\" ["
     date-type "] :int {:blocking true}))"))
(ev (string-append
     "(def c-date-captured
        (ffi/foreign-fn \"jolt_test_date_value_with_error\" ["
     date-type " :int] :int {:capture-native-error true}))"))
(ev (string-append
     "(def c-date-blocking-captured
        (ffi/foreign-fn \"jolt_test_date_value_with_error\" ["
     date-type " :int] :int
         {:blocking true :capture-native-error true}))"))
(ev (string-append
     "(def c-date-vararg
        (ffi/foreign-fn \"jolt_test_date_plus_vararg\" ["
     date-type " :int :int] :int {:varargs-after 2}))"))
(ev (string-append
     "(def c-datetime-value
        (ffi/foreign-fn \"jolt_test_datetime_value\" ["
     datetime-type "] :int))"))
(ev (string-append
     "(def c-datetime-blocking-captured
        (ffi/foreign-fn \"jolt_test_datetime_value_with_error\" ["
     datetime-type " :int] :int
         {:blocking true :capture-native-error true}))"))
(ev (string-append
     "(def c-datetime-probe
        (ffi/foreign-fn \"jolt_test_datetime_probe\" ["
     datetime-type " :int32 :int32] :int32
         {:blocking true
          :capture-native-error true
          :varargs-after 2}))"))
(ev (string-append
     "(def c-date-year
        (ffi/foreign-fn \"jolt_test_date_year\" ["
     date-type "] :int32))"))
(ev (string-append
     "(def c-datetime-microsecond
        (ffi/foreign-fn \"jolt_test_datetime_microsecond\" ["
     datetime-type "] :uint32))"))
(ev "(def c-date-size (ffi/foreign-fn \"jolt_test_date_size\" [] :int))")
(ev "(def c-time-size (ffi/foreign-fn \"jolt_test_time_size\" [] :int))")
(ev "(def c-datetime-size
       (ffi/foreign-fn \"jolt_test_datetime_size\" [] :int))")
(ev "(def c-datetime-time-offset
       (ffi/foreign-fn \"jolt_test_datetime_time_offset\" [] :int))")
(ev "(def c-time-microsecond-offset
       (ffi/foreign-fn \"jolt_test_time_microsecond_offset\" [] :int))")

(ok "exact int32 alias crosses the native ABI"
    (= 8 (jnum->exact (ev "(c-abs32 -8)"))))
(ok "exact int32 aliases report four-byte width"
    (jolt-truthy? (ev "(= [4 4] [(ffi/sizeof :int32)
                                  (ffi/sizeof :uint32)])")))
(ok "C oracle reports expected date layout"
    (= 8 (jnum->exact (ev "(c-date-size)"))))
(ok "C oracle reports expected time layout"
    (= 8 (jnum->exact (ev "(c-time-size)"))))
(ok "C oracle reports expected nested datetime layout"
    (= 16 (jnum->exact (ev "(c-datetime-size)"))))
(ok "C oracle reports the nested time offset"
    (= 8 (jnum->exact (ev "(c-datetime-time-offset)"))))
(ok "C oracle reports the aligned uint32 field offset"
    (= 4 (jnum->exact (ev "(c-time-microsecond-offset)"))))

(ev "(defn with-test-date [f]
       (let [p (ffi/alloc 8)]
         (try
           (ffi/write p :int32 0 2026)
           (ffi/write p :uint8 4 7)
           (ffi/write p :uint8 5 23)
           (f p)
           (finally (ffi/free p)))))")
(ok "flat struct is passed by value from caller-owned storage"
    (= 2749 (jnum->exact (ev "(with-test-date c-date-value)"))))
(ok "by-value aggregate composes with collect-safe blocking lowering"
    (= 2749 (jnum->exact (ev "(with-test-date c-date-blocking)"))))
(ok "by-value aggregate composes with atomic native-error capture"
    (jolt-truthy?
     (ev "(= [-2749 73]
              (with-test-date #(c-date-captured % 73)))")))
(ok "blocking and capture flags remain orthogonal with aggregates"
    (jolt-truthy?
     (ev "(= [-2749 74]
              (with-test-date #(c-date-blocking-captured % 74)))")))
(ok "by-value fixed aggregate composes with a variadic tail"
    (= 2754
       (jnum->exact (ev "(with-test-date #(c-date-vararg % 1 5))"))))

(ok "nested structs are passed by value"
    (= 302012753
       (jnum->exact
        (ev "(let [p (ffi/alloc 16)]
               (try
                 (ffi/write p :int32 0 2026)
                 (ffi/write p :uint8 4 7)
                 (ffi/write p :uint8 5 23)
                 (ffi/write p :uint8 8 1)
                 (ffi/write p :uint8 9 2)
                 (ffi/write p :uint8 10 3)
                 (ffi/write p :uint32 12 4)
                 (c-datetime-value p)
                 (finally (ffi/free p))))"))))
(ok "nested aggregate composes with blocking and native-error capture"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 16)]
            (try
              (ffi/write p :int32 0 2026)
              (ffi/write p :uint8 4 7)
              (ffi/write p :uint8 5 23)
              (ffi/write p :uint8 8 1)
              (ffi/write p :uint8 9 2)
              (ffi/write p :uint8 10 3)
              (ffi/write p :uint32 12 4)
              (= [-302012753 75]
                 (c-datetime-blocking-captured p 75))
              (finally (ffi/free p))))")))
(ok "aggregate fields preserve negative int32 and high uint32 values"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 16)]
            (try
              (ffi/write p :int32 0 -123456789)
              (ffi/write p :uint32 12 4045620583)
              (= [-123456789 4045620583]
                 [(c-date-year p) (c-datetime-microsecond p)])
              (finally (ffi/free p))))")))
(ok "nested aggregate composes with blocking, capture, and varargs"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 16)]
            (try
              (ffi/write p :int32 0 -123456789)
              (ffi/write p :uint8 4 250)
              (ffi/write p :uint8 5 251)
              (ffi/write p :uint8 8 252)
              (ffi/write p :uint8 9 253)
              (ffi/write p :uint8 10 254)
              (ffi/write p :uint32 12 4045620583)
              (= [-1 19003] (c-datetime-probe p 1 37))
              (finally (ffi/free p))))")))

(ok "null by-value aggregate pointers fail before native entry"
    (jolt-truthy?
     (ev "(try (c-date-value 0) false
               (catch NullPointerException _ true))")))
(ok "aggregate return descriptors fail closed"
    (compile-rejected?
     "(ffi/foreign-fn \"jolt_test_date_value\" [:pointer]
        [:struct [[:year :int32]]])"))
(ok "bare struct arguments fail closed"
    (compile-rejected?
     "(ffi/foreign-fn \"jolt_test_date_value\"
        [[:struct [[:year :int32]]]] :int)"))
(ok "empty struct arguments fail closed"
    (compile-rejected?
     "(ffi/foreign-fn \"jolt_test_date_value\"
        [[:by-value [:struct []]]] :int)"))
(ok "nested by-value fields fail closed"
    (compile-rejected?
     "(ffi/foreign-fn \"jolt_test_date_value\"
        [[:by-value [:struct [[:x [:by-value [:struct [[:y :int]]]]]]]]]
        :int)"))
(ok "namespaced by-value tags fail closed"
    (compile-rejected?
     "(ffi/foreign-fn \"jolt_test_date_value\"
        [[:not-ffi/by-value [:struct [[:year :int32]]]]] :int)"))
(ok "namespaced struct tags fail closed"
    (compile-rejected?
     "(ffi/foreign-fn \"jolt_test_date_value\"
        [[:by-value [:not-ffi/struct [[:year :int32]]]]] :int)"))
(ok "namespaced aggregate field names fail closed"
    (compile-rejected?
     "(ffi/foreign-fn \"jolt_test_date_value\"
        [[:by-value [:struct [[:calendar/year :int32]]]]] :int)"))
(ok "aggregate callback arguments fail closed"
    (compile-rejected?
     "(ffi/foreign-callable identity
        [[:by-value [:struct [[:year :int32]]]]] :int)"))

(unless (= total expected-total)
  (set! fails (+ fails 1))
  (printf "FAIL: expected ~a assertions, executed ~a~n" expected-total total))
(printf "~a/~a aggregate FFI checks passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
