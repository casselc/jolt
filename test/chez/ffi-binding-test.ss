;; jolt.ffi regression: a compile-time-typed foreign binding lowers to a real
;; Chez foreign-procedure and calls native code. Run `make ffi`; its wrapper
;; builds the portable scalar helper first. The gate binds both helper and libc
;; symbols through jolt.ffi/__cfn plus the host memory primitives — the same path
;; a library uses to bind its native dependencies.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/ffi.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
;; eval one form (string) in `user`, like the loader does form-by-form, so a def
;; is visible to a later form.
(define (ev s) (jolt-compile-eval s "user"))

(define scalar-helper (getenv "JOLT_FFI_SCALAR_HELPER"))
(unless scalar-helper
  (error #f "JOLT_FFI_SCALAR_HELPER must name the compiled scalar test library"))
(load-shared-object scalar-helper)

;; load libc (process symbols) and bind typed foreign functions
(ev "(jolt.ffi/load-library)")
(ev "(def c-strlen (jolt.ffi/__cfn \"strlen\" [:string] :size_t))")
(ev "(def c-abs (jolt.ffi/__cfn \"abs\" [:int] :int))")

(ok "foreign-procedure built for strlen" (procedure? (var-deref "user" "c-strlen")))
(ok "typed call: strlen(\"hello\") = 5" (= 5 (jnum->exact (ev "(c-strlen \"hello\")"))))
(ok "typed call: abs(-7) = 7"          (= 7 (jnum->exact (ev "(c-abs -7)"))))

;; memory: alloc / write / read roundtrip through the host primitives
(ok "mem int roundtrip"
    (= 4242 (jnum->exact
              (ev "(let [p (jolt.ffi/alloc (jolt.ffi/sizeof :int))]
                     (jolt.ffi/write p :int 0 4242)
                     (let [v (jolt.ffi/read p :int)] (jolt.ffi/free p) v))"))))
(ok "sizeof :pointer is a word" (let ((n (jnum->exact (ev "(jolt.ffi/sizeof :pointer)")))) (or (= n 8) (= n 4))))

;; Exact scalar widths used by native structures and protocols. In particular,
;; pollfd and sockaddr fields cannot be modeled faithfully as :int: that gives
;; them the wrong width, while byte-position workarounds depend on host order.
(ok "signed 8-bit aliases have exact width 1"
    (equal? '(1 1)
            (map (lambda (t)
                   (jnum->exact
                     (ev (string-append "(jolt.ffi/sizeof " t ")"))))
                 '(":int8" ":i8"))))
(ok "16-bit aliases have exact width 2"
    (equal? '(2 2 2 2)
            (map (lambda (t)
                   (jnum->exact
                     (ev (string-append "(jolt.ffi/sizeof " t ")"))))
                 '(":int16" ":short" ":uint16" ":ushort"))))
(ok "32-bit types have exact width 4"
    (equal? '(4 4)
            (map (lambda (t)
                   (jnum->exact
                     (ev (string-append "(jolt.ffi/sizeof " t ")"))))
                 '(":int32" ":uint32"))))

(ev "(def p8 (jolt.ffi/alloc 1))")
(ev "(jolt.ffi/write p8 :i8 0 -1)")
(ok "signed 8-bit aliases preserve sign"
    (= -1 (jnum->exact (ev "(jolt.ffi/read p8 :int8 0)"))))
(ev "(jolt.ffi/free p8)")

(ok "uint16 roundtrips its maximum value"
    (= 65535
       (jnum->exact
         (ev "(let [p (jolt.ffi/alloc 2)]
                (jolt.ffi/write p :uint16 0 65535)
                (let [v (jolt.ffi/read p :uint16 0)]
                  (jolt.ffi/free p)
                  v))"))))
(ev "(def p16 (jolt.ffi/alloc 2))")
(ev "(jolt.ffi/write p16 :int16 0 -1)")
(ok "the same 16 bits retain signed and unsigned interpretations"
    (and (= -1 (jnum->exact (ev "(jolt.ffi/read p16 :int16 0)")))
         (= 65535 (jnum->exact (ev "(jolt.ffi/read p16 :uint16 0)")))))
(ev "(jolt.ffi/free p16)")
(ok "int16 roundtrips its minimum value"
    (= -32768
       (jnum->exact
         (ev "(let [p (jolt.ffi/alloc 2)]
                (jolt.ffi/write p :short 0 -32768)
                (let [v (jolt.ffi/read p :int16 0)]
                  (jolt.ffi/free p)
                  v))"))))

(ok "uint32 roundtrips its maximum value"
    (= 4294967295
       (jnum->exact
         (ev "(let [p (jolt.ffi/alloc 4)]
                (jolt.ffi/write p :uint32 0 4294967295)
                (let [v (jolt.ffi/read p :uint32 0)]
                  (jolt.ffi/free p)
                  v))"))))
(ev "(def p32 (jolt.ffi/alloc 4))")
(ev "(jolt.ffi/write p32 :int32 0 -1)")
(ok "the same 32 bits retain signed and unsigned interpretations"
    (and (= -1 (jnum->exact (ev "(jolt.ffi/read p32 :int32 0)")))
         (= 4294967295 (jnum->exact (ev "(jolt.ffi/read p32 :uint32 0)")))))
(ev "(jolt.ffi/free p32)")
(ok "int32 roundtrips its minimum value"
    (= -2147483648
       (jnum->exact
         (ev "(let [p (jolt.ffi/alloc 4)]
                (jolt.ffi/write p :int32 0 -2147483648)
                (let [v (jolt.ffi/read p :int32 0)]
                  (jolt.ffi/free p)
                  v))"))))

;; Store-width check is byte-order-independent: the two bytes may be in either
;; order, but the sentinel immediately after them must remain untouched.
(ev "(def p-width (jolt.ffi/alloc 3))")
(ev "(jolt.ffi/write p-width :uint8 2 171)")
(ev "(jolt.ffi/write p-width :uint16 0 4660)")
(ok "a uint16 store occupies exactly two bytes"
    (let ((b0 (jnum->exact (ev "(jolt.ffi/read p-width :uint8 0)")))
          (b1 (jnum->exact (ev "(jolt.ffi/read p-width :uint8 1)")))
          (b2 (jnum->exact (ev "(jolt.ffi/read p-width :uint8 2)")))
          (v (jnum->exact (ev "(jolt.ffi/read p-width :uint16 0)"))))
      (and (equal? '(18 52) (sort < (list b0 b1)))
           (= 171 b2)
           (= 4660 v))))
(ev "(jolt.ffi/free p-width)")

;; Exercise compiler-side argument, result, and callback lowering against a
;; portable C helper. High-bit boundary values discriminate signedness, while
;; the memory checks above discriminate width independently of register ABI.
(for-each
  (lambda (form) (ev form))
  '("(def c-widen-i8 (jolt.ffi/__cfn \"jolt_test_widen_i8\" [:i8] :int64))"
    "(def c-widen-i16 (jolt.ffi/__cfn \"jolt_test_widen_i16\" [:short] :int64))"
    "(def c-widen-u16 (jolt.ffi/__cfn \"jolt_test_widen_u16\" [:ushort] :uint64))"
    "(def c-widen-i32 (jolt.ffi/__cfn \"jolt_test_widen_i32\" [:int32] :int64))"
    "(def c-widen-u32 (jolt.ffi/__cfn \"jolt_test_widen_u32\" [:uint32] :uint64))"
    "(def c-return-i8 (jolt.ffi/__cfn \"jolt_test_return_i8\" [] :int8))"
    "(def c-return-i16 (jolt.ffi/__cfn \"jolt_test_return_i16\" [] :int16))"
    "(def c-return-u16 (jolt.ffi/__cfn \"jolt_test_return_u16\" [] :uint16))"
    "(def c-return-i32 (jolt.ffi/__cfn \"jolt_test_return_i32\" [] :int32))"
    "(def c-return-u32 (jolt.ffi/__cfn \"jolt_test_return_u32\" [] :uint32))"))

(ok "exact-width native arguments preserve boundary values"
    (equal? '(-128 -32768 65535 -2147483648 4294967295)
            (map (lambda (form) (jnum->exact (ev form)))
                 '("(c-widen-i8 -128)"
                   "(c-widen-i16 -32768)"
                   "(c-widen-u16 65535)"
                   "(c-widen-i32 -2147483648)"
                   "(c-widen-u32 4294967295)"))))
(ok "exact-width native results preserve boundary values"
    (equal? '(-128 -32768 65535 -2147483648 4294967295)
            (map (lambda (form) (jnum->exact (ev form)))
                 '("(c-return-i8)"
                   "(c-return-i16)"
                   "(c-return-u16)"
                   "(c-return-i32)"
                   "(c-return-u32)"))))

(for-each
  (lambda (form) (ev form))
  '("(def i8-id (jolt.ffi/__ccallable (fn [x] x) [:int8] :int8))"
    "(def i16-id (jolt.ffi/__ccallable (fn [x] x) [:int16] :int16))"
    "(def u16-id (jolt.ffi/__ccallable (fn [x] x) [:uint16] :uint16))"
    "(def i32-id (jolt.ffi/__ccallable (fn [x] x) [:int32] :int32))"
    "(def u32-id (jolt.ffi/__ccallable (fn [x] x) [:uint32] :uint32))"
    "(def c-call-i8 (jolt.ffi/__cfn \"jolt_test_call_i8\" [:pointer] :int64))"
    "(def c-call-i16 (jolt.ffi/__cfn \"jolt_test_call_i16\" [:pointer] :int64))"
    "(def c-call-u16 (jolt.ffi/__cfn \"jolt_test_call_u16\" [:pointer] :uint64))"
    "(def c-call-i32 (jolt.ffi/__cfn \"jolt_test_call_i32\" [:pointer] :int64))"
    "(def c-call-u32 (jolt.ffi/__cfn \"jolt_test_call_u32\" [:pointer] :uint64))"))
(ok "C-invoked exact-width callbacks preserve boundary values"
    (equal? '(-128 -32768 65535 -2147483648 4294967295)
            (map (lambda (form) (jnum->exact (ev form)))
                 '("(c-call-i8 i8-id)"
                   "(c-call-i16 i16-id)"
                   "(c-call-u16 u16-id)"
                   "(c-call-i32 i32-id)"
                   "(c-call-u32 u32-id)"))))
(for-each
  (lambda (name) (ev (string-append "(jolt.ffi/free-callable " name ")")))
  '("i8-id" "i16-id" "u16-id" "i32-id" "u32-id"))

(ok "unknown runtime memory types fail closed"
    (guard (e (#t #t))
      (ev "(jolt.ffi/sizeof :int128)")
      #f))
(ok "unknown compile-time signature types fail closed"
    (guard (e (#t #t))
      (ev "(jolt.ffi/__cfn \"strlen\" [:int128] :int)")
      #f))

;; byte-array buffer I/O: write a byte-array into foreign memory and read it back
;; byte-exact (high bytes preserved, no UTF-8 mangling). Elements are SIGNED bytes
;; like the JVM's byte[], so a high byte reads negative and 0xff-masks back.
(ok "byte-array roundtrip (binary-faithful, signed elements)"
    (jolt-truthy?
      (ev "(let [src (byte-array [0 65 200 255 10])
                  p (jolt.ffi/alloc 5)]
              (jolt.ffi/write-array p src)
              (let [back (jolt.ffi/read-array p 5)]
                (jolt.ffi/free p)
                (and (= 5 (alength back))
                     (= [0 65 -56 -1 10] (vec back))
                     (= [0 65 200 255 10] (mapv #(bit-and % 0xff) back)))))")))

;; A :blocking foreign call is collect-safe: a thread parked in it must not pin
;; the stop-the-world collector. Resolve the helper once before spawning so a
;; missing symbol cannot make the worker fail open.
(ev "(def c-test-sleep
       (jolt.ffi/__cfn \"jolt_test_sleep_millis\" [:uint32] :void :blocking))")
(let ((sleep-fn (var-deref "user" "c-test-sleep")))
  (sleep-fn 0) ; force lazy native-symbol resolution on the asserting thread
  (fork-thread (lambda () (sleep-fn 2000))) ; ~2s
  (let loop ((i 0)) (when (fx<? i 30000000) (loop (fx+ i 1)))) ; let the worker enter native sleep
  (ok "blocking ffi call is collect-safe" (guard (e (#t #f)) (collect) #t)))

;; callbacks: receive a call FROM C. A foreign-callable wraps a jolt fn as a
;; C-callable function pointer (what GTK signal handlers / qsort comparators need).
;; Build a comparator and sort an int array through libc qsort.
(ev "(def cmp (jolt.ffi/__ccallable
                (fn [pa pb]
                  (let [a (jolt.ffi/read pa :int) b (jolt.ffi/read pb :int)]
                    (cond (< a b) -1 (> a b) 1 :else 0)))
                [:pointer :pointer] :int))")
(ok "foreign-callable returns a pointer"
    (let ((p (jnum->exact (var-deref "user" "cmp")))) (and (integer? p) (> p 0))))
(ev "(def c-qsort (jolt.ffi/__cfn \"qsort\" [:pointer :size_t :size_t :pointer] :void))")
(ok "C calls back into jolt: qsort with a jolt comparator"
    (jolt-truthy?
      (ev "(let [n 5 w (jolt.ffi/sizeof :int) p (jolt.ffi/alloc (* n w))]
             (doseq [[i v] (map vector (range n) [3 1 4 1 5])]
               (jolt.ffi/write p :int (* i w) v))
             (c-qsort p n w cmp)
             (let [out (mapv (fn [i] (jolt.ffi/read p :int (* i w))) (range n))]
               (jolt.ffi/free p)
               (= out [1 1 3 4 5])))")))
;; free-callable unlocks + drops the code object, returning nil.
(ok "free-callable releases the callback"
    (jolt-nil? (ev "(jolt.ffi/free-callable cmp)")))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
