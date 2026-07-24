;; Verify jolt.ffi aggregate descriptors through the full reader -> analyzer ->
;; Scheme backend -> Chez foreign-procedure path. The companion shell script
;; compiles ffi-aggregate-helper.c and sets JOLT_FFI_AGGREGATE_TEST_LIBRARY.

(import (chezscheme))
(load "host/chez/rt.ss")
(set-chez-ns! "clojure.core")
(load "host/chez/seed/prelude.ss")
(load "host/chez/post-prelude.ss")
(set-chez-ns! "user")
(load "host/chez/host-contract.ss")
(load "host/chez/seed/image.ss")
(load "host/chez/compile-eval.ss")
(load "host/chez/java/ffi.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a\n" name)))
(define (ev source) (jolt-compile-eval source "user"))

(ev (string-append "(jolt.ffi/load-library "
                   (format "~s" (getenv "JOLT_FFI_AGGREGATE_TEST_LIBRARY"))
                   ")"))

(ev "(def c-date-value
       (jolt.ffi/__cfn
        \"jolt_test_date_value\"
        [[:by-value
          [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]]
        :int))")

(ev "(def c-datetime-value
       (jolt.ffi/__cfn
        \"jolt_test_datetime_value\"
        [[:by-value
          [:struct
           [[:date [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]
            [:time [:struct [[:hour :uint8] [:minute :uint8] [:second :uint8]
                             [:microsecond :uint]]]]]]]]
        :int))")

(ev "(def c-date-size
       (jolt.ffi/__cfn \"jolt_test_date_size\" [] :int))")
(ev "(def c-datetime-size
       (jolt.ffi/__cfn \"jolt_test_datetime_size\" [] :int))")

(ok "C oracle reports expected date layout"
    (= 8 (jnum->exact (ev "(c-date-size)"))))
(ok "C oracle reports expected nested datetime layout"
    (= 16 (jnum->exact (ev "(c-datetime-size)"))))

(ok "flat struct is passed by value"
    (= 2749
       (jnum->exact
        (ev "(let [p (jolt.ffi/alloc 8)]
               (jolt.ffi/write p :int32 0 2026)
               (jolt.ffi/write p :uint8 4 7)
               (jolt.ffi/write p :uint8 5 23)
               (let [result (c-date-value p)]
                 (jolt.ffi/free p)
                 result))"))))

(ok "nested structs are passed by value"
    (= 302012753
       (jnum->exact
        (ev "(let [p (jolt.ffi/alloc 16)]
               (jolt.ffi/write p :int32 0 2026)
               (jolt.ffi/write p :uint8 4 7)
               (jolt.ffi/write p :uint8 5 23)
               (jolt.ffi/write p :uint8 8 1)
               (jolt.ffi/write p :uint8 9 2)
               (jolt.ffi/write p :uint8 10 3)
               (jolt.ffi/write p :uint 12 4)
               (let [result (c-datetime-value p)]
                 (jolt.ffi/free p)
                 result))"))))

(ok "null by-value aggregate pointers fail before native entry"
    (jolt-truthy?
     (ev "(try (c-date-value 0) false
               (catch NullPointerException _ true))")))

(ok "aggregate return descriptors fail closed"
    (guard (e (#t #t))
      (ev "(jolt.ffi/__cfn
            \"jolt_test_date_value\"
            [:pointer]
            [:struct [[:year :int32]]])")
      #f))

(printf "~a/~a aggregate FFI checks passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
