;; jolt.ffi regression: a compile-time-typed foreign binding lowers to a real
;; Chez foreign-procedure and calls native code. Run:
;;   chez --script test/chez/ffi-binding-test.ss
;; Binds a few libc functions (process symbols, always present) through the
;; jolt.ffi/__cfn special form + the host memory primitives — the same path a
;; library uses to bind its native deps.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/loader.ss")
(set-source-roots! ldr-install-roots)
(load "host/chez/java/ffi.ss")

(define total 0) (define fails 0) (define skipped 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (skip name)
  (set! skipped (+ skipped 1))
  (printf "SKIP: ~a\n" name))
(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))
;; eval one form (string) in `user`, like the loader does form-by-form, so a def
;; is visible to a later form.
(define (ev s) (jolt-compile-eval s "user"))
;; Lower one form without evaluating it so convention order can be asserted
;; independently of whether this host ABI happens to expose the bug.
(define (emitf s)
  (let-values (((f j) (rdr-read-form s 0 (string-length s))))
    (let ((ctx (make-analyze-ctx "user")))
      (jolt-ce-emit (jolt-ce-run-passes (jolt-ce-analyze ctx f) ctx)))))
(define (has? s sub)
  (let ((ns (string-length s)) (nsub (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i nsub) ns) #f)
            ((string=? (substring s i (+ i nsub)) sub) #t)
            (else (loop (+ i 1)))))))
(define windows-host?
  (and (memq (machine-type) '(i3nt ti3nt a6nt ta6nt arm64nt tarm64nt)) #t))

;; gate-boot stops before the loader, so explicitly load the public namespace
;; before exercising its foreign-fn/defcfn macros below.
(ev "(require '[jolt.ffi :as ffi])")

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

;; a :blocking foreign call is collect-safe: a thread parked in it must not pin
;; the stop-the-world collector. (collect) here would throw "cannot collect when
;; multiple threads are active" if usleep weren't emitted __collect_safe.
(ev "(def c-usleep (jolt.ffi/__cfn \"usleep\" [:uint] :int :blocking))")
(let ((usleep (var-deref "user" "c-usleep")))
  (fork-thread (lambda () (usleep 2000000)))           ; ~2s in a blocking call
  (let loop ((i 0)) (when (fx<? i 30000000) (loop (fx+ i 1))))  ; spin so the thread enters usleep
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

;; variadic foreign functions: {:varargs-after n} declares the fixed-argument
;; boundary before the C "...", lowering to Chez's __varargs_after convention
;; (required on targets whose variadic and fixed calling conventions differ).
;; snprintf is a clean variadic libc witness: 3 fixed params (buf, size, fmt)
;; then "...". The declared argtypes list the fixed params followed by the
;; already-promoted variadic ones (:double), and the boundary (3) may not exceed
;; the argtype count. A floating variadic value is deliberately discriminating:
;; Apple arm64 moves arguments after `...` to the stack, while other ABIs still
;; need their variadic floating-point metadata/convention emitted correctly.
(ok "blocking precedes the variadic boundary in plain lowering"
    (has? (emitf "(jolt.ffi/__cfn \"snprintf\"
                    [:pointer :size_t :pointer :double] :int
                    {:blocking true :varargs-after 3})")
          "(foreign-procedure __collect_safe (__varargs_after 3) \"snprintf\""))
(ok "capture groups blocking and the variadic boundary in order"
    (has? (emitf "(jolt.ffi/__cfn \"snprintf\"
                    [:pointer :size_t :pointer :double] :int
                    {:blocking true :capture-native-error true
                     :varargs-after 3})")
          "(jolt-ffi-native-error-procedure (__collect_safe (__varargs_after 3)) \"snprintf\""))
(unless windows-host?
  (ev "(ffi/defcfn c-snprintf \"snprintf\"
                      [:pointer :size_t :string :double] :int {:varargs-after 3})"))
(if windows-host?
    (skip "POSIX snprintf variadic byte witness")
    (ok "variadic {:varargs-after 3} lowers snprintf and writes the right bytes"
        (jolt-truthy?
          (ev "(let [buf (jolt.ffi/alloc 16)
                     n (c-snprintf buf 16 \"%.1f\" 1.5)]
                 (let [ok (and (= n 3)
                               (= 49 (bit-and (jolt.ffi/read buf :uint8 0) 0xff))
                               (= 46 (bit-and (jolt.ffi/read buf :uint8 1) 0xff))
                               (= 53 (bit-and (jolt.ffi/read buf :uint8 2) 0xff)))]
                   (jolt.ffi/free buf) ok))"))))
;; the boundary may equal the argtype count (a trailing "..." that matches zero
;; extra args); it just may not exceed it.
(ok "varargs-after equal to arg count is accepted (1 fixed, 0 variadic)"
    (= 9 (jnum->exact
           (ev "(let [f (jolt.ffi/__cfn \"abs\" [:int] :int {:varargs-after 1})] (f -9))"))))

;; --- analyzer fail-closed: malformed {:varargs-after ...} ---------------------
;; Validated at compile time in jolt.analyzer/analyze-ffi-fn, before any native
;; symbol is resolved. Each must raise rather than silently ignore the bad option.
(ok "non-integer :varargs-after rejected"
    (raises? (lambda () (ev "(jolt.ffi/__cfn \"snprintf\" [:pointer :size_t :string :int] :int {:varargs-after 3.0})"))))
(ok "zero :varargs-after rejected"
    (raises? (lambda () (ev "(jolt.ffi/__cfn \"snprintf\" [:pointer :size_t :string :int] :int {:varargs-after 0})"))))
(ok "negative :varargs-after rejected"
    (raises? (lambda () (ev "(jolt.ffi/__cfn \"snprintf\" [:pointer :size_t :string :int] :int {:varargs-after -1})"))))
(ok ":varargs-after exceeding arg count rejected"
    (raises? (lambda () (ev "(jolt.ffi/__cfn \"snprintf\" [:pointer :size_t] :int {:varargs-after 3})"))))
(ok "public foreign-fn forwards {:varargs-after}"
    (has? (emitf "(ffi/foreign-fn \"snprintf\"
                    [:pointer :size_t :string :double] :int
                    {:varargs-after 3})")
          "(foreign-procedure (__varargs_after 3) \"snprintf\""))
(if windows-host?
    (skip "POSIX public foreign-fn snprintf execution")
    (ok "public foreign-fn variadic binding calls snprintf"
        (jolt-truthy?
          (ev "(let [buf (jolt.ffi/alloc 16)
                     f (ffi/foreign-fn \"snprintf\"
                         [:pointer :size_t :string :double] :int
                         {:varargs-after 3})
                     n (f buf 16 \"%.1f\" 2.5)]
                 (jolt.ffi/free buf)
                 (= 3 n))"))))
(unless windows-host?
  (ev "(ffi/defcfn c-snprintf-captured \"snprintf\"
         [:pointer :size_t :pointer :double] :int
         {:blocking true :capture-native-error true :varargs-after 3})"))
(if windows-host?
    (skip "POSIX blocking capture with snprintf varargs")
    (ok "blocking capture and variadic lowering execute together"
        (jolt-truthy?
          (ev "(let [buf (jolt.ffi/alloc 16)
                     fmt (jolt.ffi/string->ptr \"%.1f\")
                     pair (c-snprintf-captured buf 16 fmt 7.5)]
                 (jolt.ffi/free fmt)
                 (jolt.ffi/free buf)
                 (and (vector? pair) (= 2 (count pair))
                      (= 3 (nth pair 0)) (integer? (nth pair 1))))"))))

(printf "~a/~a passed; ~a skipped~n" (- total fails) total skipped)
(exit (if (zero? fails) 0 1))
