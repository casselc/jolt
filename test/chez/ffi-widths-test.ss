;; ffi-widths-test.ss — exact scalar-width and variadic FFI types gate.
;;
;; Exercises the exact scalar widths (:int8/:i8, :int16/:short, :uint16/:ushort,
;; :int32, :uint32) across BOTH halves of jolt.ffi so a typed foreign call and a
;; raw memory access agree on layout:
;;   * the runtime memory path  — jolt.ffi/sizeof|read|write, host/chez/java/ffi.ss
;;   * the compile-time sig path — jolt.ffi/__cfn,  ffi-types in backend_scheme.clj
;; Plus the signed/unsigned bit equivalence and fail-closed on an unknown type.
;;
;; Run via the wrapper, which compiles and preloads the C helper:
;;   sh test/chez/ffi-widths-test.sh "$(CHEZ)"
;; (from the repo root, like every other gate).
;;
;; SEED DEPENDENCY: the signature/callback sections compile jolt.ffi/__cfn and
;; __ccallable forms with the exact widths, so this gate requires a seed
;; re-minted (`make remint`) from a backend_scheme.clj whose ffi-types declares
;; them. Against an older checked-in seed those sections fail at compile time
;; with "unknown foreign type" — that failure is the seed lagging the source,
;; not a runtime regression.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/ffi.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))
;; eval one form (string) in `user`, like the loader does form-by-form, so a def
;; is visible to a later form.
(define (ev s) (jolt-compile-eval s "user"))

(define helper-so (getenv "JOLT_FFI_WIDTHS_HELPER"))
(unless helper-so
  (error #f "JOLT_FFI_WIDTHS_HELPER must name the compiled helper library"))
(load-shared-object helper-so)

;; --- runtime memory path: sizeof discriminates the declared width -------------
;; sizeof is the sharpest discriminator: a :uint16 mapped to the wrong Chez type
;; (e.g. unsigned-int) would report 4, not 2. Each exact width must size to its
;; bit width, and aliases must agree with their canonical name.
(ok "sizeof :int8 = 1"   (= 1 (jnum->exact (ev "(jolt.ffi/sizeof :int8)"))))
(ok "sizeof :i8 = 1"     (= 1 (jnum->exact (ev "(jolt.ffi/sizeof :i8)"))))
(ok "sizeof :uint8 = 1"  (= 1 (jnum->exact (ev "(jolt.ffi/sizeof :uint8)"))))
(ok "sizeof :int16 = 2"  (= 2 (jnum->exact (ev "(jolt.ffi/sizeof :int16)"))))
(ok "sizeof :short = 2"  (= 2 (jnum->exact (ev "(jolt.ffi/sizeof :short)"))))
(ok "sizeof :uint16 = 2" (= 2 (jnum->exact (ev "(jolt.ffi/sizeof :uint16)"))))
(ok "sizeof :ushort = 2" (= 2 (jnum->exact (ev "(jolt.ffi/sizeof :ushort)"))))
(ok "sizeof :int32 = 4"  (= 4 (jnum->exact (ev "(jolt.ffi/sizeof :int32)"))))
(ok "sizeof :uint32 = 4" (= 4 (jnum->exact (ev "(jolt.ffi/sizeof :uint32)"))))

;; --- runtime memory path: write/read roundtrips at the width boundaries -------
;; rw : write a value at the declared type, read it back, free. Boundary values
;; hit the sign bit and the min/max of each width.
(ev "(def rw (fn [ty v] (let [p (jolt.ffi/alloc (jolt.ffi/sizeof ty))] (jolt.ffi/write p ty 0 v) (let [r (jolt.ffi/read p ty)] (jolt.ffi/free p) r))))")
(ok "int8 roundtrip -128"   (= -128 (jnum->exact (ev "(rw :int8 -128)"))))
(ok "int8 roundtrip -1"     (= -1 (jnum->exact (ev "(rw :int8 -1)"))))
(ok "int8 roundtrip 127"    (= 127 (jnum->exact (ev "(rw :int8 127)"))))
(ok "uint8 roundtrip 0"     (= 0 (jnum->exact (ev "(rw :uint8 0)"))))
(ok "uint8 roundtrip 255"   (= 255 (jnum->exact (ev "(rw :uint8 255)"))))
(ok "int16 roundtrip -32768" (= -32768 (jnum->exact (ev "(rw :int16 -32768)"))))
(ok "int16 roundtrip -1"    (= -1 (jnum->exact (ev "(rw :int16 -1)"))))
(ok "int16 roundtrip 32767" (= 32767 (jnum->exact (ev "(rw :int16 32767)"))))
(ok "uint16 roundtrip 0"    (= 0 (jnum->exact (ev "(rw :uint16 0)"))))
(ok "uint16 roundtrip 40000" (= 40000 (jnum->exact (ev "(rw :uint16 40000)"))))
(ok "uint16 roundtrip 65535" (= 65535 (jnum->exact (ev "(rw :uint16 65535)"))))
(ok "int32 roundtrip -2147483648" (= -2147483648 (jnum->exact (ev "(rw :int32 -2147483648)"))))
(ok "int32 roundtrip -1"    (= -1 (jnum->exact (ev "(rw :int32 -1)"))))
(ok "int32 roundtrip 2147483647" (= 2147483647 (jnum->exact (ev "(rw :int32 2147483647)"))))
(ok "uint32 roundtrip 0"    (= 0 (jnum->exact (ev "(rw :uint32 0)"))))
(ok "uint32 roundtrip 3000000000" (= 3000000000 (jnum->exact (ev "(rw :uint32 3000000000)"))))
(ok "uint32 roundtrip 4294967295" (= 4294967295 (jnum->exact (ev "(rw :uint32 4294967295)"))))

;; --- signed/unsigned bit equivalence: same stored bits, two views -------------
;; The defining property of the exact widths: a :uint16 read of a :int16 -1
;; write is 65535 (and :int8 -1 read as :uint8 is 255). A width mapped to the
;; wrong signedness would lose this equivalence.
(ok "int8 -1 read as uint8 = 255"
    (= 255 (jnum->exact (ev "(let [p (jolt.ffi/alloc 1)] (jolt.ffi/write p :int8 0 -1) (let [r (jolt.ffi/read p :uint8)] (jolt.ffi/free p) r))"))))
(ok "int16 -1 read as uint16 = 65535"
    (= 65535 (jnum->exact (ev "(let [p (jolt.ffi/alloc 2)] (jolt.ffi/write p :int16 0 -1) (let [r (jolt.ffi/read p :uint16)] (jolt.ffi/free p) r))"))))
(ok "int32 -1 read as uint32 = 4294967295"
    (= 4294967295 (jnum->exact (ev "(let [p (jolt.ffi/alloc 4)] (jolt.ffi/write p :int32 0 -1) (let [r (jolt.ffi/read p :uint32)] (jolt.ffi/free p) r))"))))
(ok "uint16 65535 read as int16 = -1"
    (= -1 (jnum->exact (ev "(let [p (jolt.ffi/alloc 2)] (jolt.ffi/write p :uint16 0 65535) (let [r (jolt.ffi/read p :int16)] (jolt.ffi/free p) r))"))))
(ok "uint8 255 read as int8 = -1"
    (= -1 (jnum->exact (ev "(let [p (jolt.ffi/alloc 1)] (jolt.ffi/write p :uint8 0 255) (let [r (jolt.ffi/read p :int8)] (jolt.ffi/free p) r))"))))
(ok "uint32 4294967295 read as int32 = -1"
    (= -1 (jnum->exact (ev "(let [p (jolt.ffi/alloc 4)] (jolt.ffi/write p :uint32 0 4294967295) (let [r (jolt.ffi/read p :int32)] (jolt.ffi/free p) r))"))))

;; --- fail-closed: an unrecognized type is rejected at the runtime accessor -----
(ok "unknown type rejected by sizeof"
    (raises? (lambda () (jnum->exact (ev "(jolt.ffi/sizeof :nope)")))))
(ok "unknown type rejected by read"
    (raises? (lambda () (jnum->exact (ev "(jolt.ffi/read 0 :nope)")))))

;; --- compile-time signature path: arguments and results ----------------------
;; Widening C functions make the argument's signedness observable independently
;; of the result type. Constant-return functions exercise exact-width result
;; lowering independently of argument conversion. Requires a seed re-minted
;; from the edited backend_scheme.clj (see the header).
(ev "(jolt.ffi/load-library)")
(for-each
  ev
  '("(def w-i8  (jolt.ffi/__cfn \"jolt_w_widen_i8\"  [:i8]    :int64))"
    "(def w-int8 (jolt.ffi/__cfn \"jolt_w_widen_i8\" [:int8] :int64))"
    "(def w-i16 (jolt.ffi/__cfn \"jolt_w_widen_i16\" [:short] :int64))"
    "(def w-int16 (jolt.ffi/__cfn \"jolt_w_widen_i16\" [:int16] :int64))"
    "(def w-u16 (jolt.ffi/__cfn \"jolt_w_widen_u16\" [:ushort] :uint64))"
    "(def w-uint16 (jolt.ffi/__cfn \"jolt_w_widen_u16\" [:uint16] :uint64))"
    "(def w-i32 (jolt.ffi/__cfn \"jolt_w_widen_i32\" [:int32] :int64))"
    "(def w-u32 (jolt.ffi/__cfn \"jolt_w_widen_u32\" [:uint32] :uint64))"
    "(def r-i8  (jolt.ffi/__cfn \"jolt_w_return_i8\"  [] :int8))"
    "(def r-i16 (jolt.ffi/__cfn \"jolt_w_return_i16\" [] :int16))"
    "(def r-u16 (jolt.ffi/__cfn \"jolt_w_return_u16\" [] :uint16))"
    "(def r-i32 (jolt.ffi/__cfn \"jolt_w_return_i32\" [] :int32))"
    "(def r-u32 (jolt.ffi/__cfn \"jolt_w_return_u32\" [] :uint32))"))
(ok "exact-width native arguments preserve boundary values"
    (equal? '(-128 -32768 65535 -2147483648 4294967295)
            (map (lambda (form) (jnum->exact (ev form)))
                 '("(w-i8 -128)" "(w-i16 -32768)" "(w-u16 65535)"
                   "(w-i32 -2147483648)" "(w-u32 4294967295)"))))
(ok "exact-width native results preserve boundary values"
    (equal? '(-128 -32768 65535 -2147483648 4294967295)
            (map (lambda (form) (jnum->exact (ev form)))
                 '("(r-i8)" "(r-i16)" "(r-u16)" "(r-i32)" "(r-u32)"))))

;; One fixed integer precedes three already-promoted doubles. This is an
;; executable witness on every supported platform, including ABIs where fixed
;; and variadic floating-point arguments use different locations.
(ev "(def sum-variadic
       (jolt.ffi/__cfn \"jolt_w_sum_variadic\"
         [:int :double :double :double] :double {:varargs-after 1}))")
(ok "variadic boundary preserves promoted doubles"
    (= 6.875 (ev "(sum-variadic 3 1.5 2.25 3.125)")))

;; C calls alone cannot prove the declaration width: a mistakenly widened
;; foreign signature can still appear correct when the C callee's fixed-width
;; parameter performs the narrowing. Pin the exact compiler declarations that
;; both emit-ffi-fn and emit-ffi-callable consume from the re-minted seed.
(define compiler-ffi-type->chez
  (var-deref "jolt.backend-scheme" "ffi-type->chez"))
(ok "compiler maps every exact-width canonical name and alias exactly"
    (for-all
     (lambda (entry)
       (equal? (cdr entry)
               (jolt-invoke1 compiler-ffi-type->chez (car entry))))
     '(("int8" . "integer-8")
       ("i8" . "integer-8")
       ("int16" . "integer-16")
       ("short" . "integer-16")
       ("uint16" . "unsigned-16")
       ("ushort" . "unsigned-16")
       ("int32" . "integer-32")
       ("uint32" . "unsigned-32"))))

;; Chez's exact integer foreign types narrow opposite-signed values that still
;; fit the same bit-pattern width (rather than rejecting both sides of each
;; source domain). Assert the observable two's-complement reinterpretation for
;; every canonical name and alias.
(ok "i8 narrows 128 to -128"
    (= -128 (jnum->exact (ev "(w-i8 128)"))))
(ok "int8 narrows 128 to -128"
    (= -128 (jnum->exact (ev "(w-int8 128)"))))
(ok "short narrows 32768 to -32768"
    (= -32768 (jnum->exact (ev "(w-i16 32768)"))))
(ok "int16 narrows 32768 to -32768"
    (= -32768 (jnum->exact (ev "(w-int16 32768)"))))
(ok "ushort narrows -1 to 65535"
    (= 65535 (jnum->exact (ev "(w-u16 -1)"))))
(ok "uint16 narrows -1 to 65535"
    (= 65535 (jnum->exact (ev "(w-uint16 -1)"))))
(ok "int32 narrows 2147483648 to -2147483648"
    (= -2147483648 (jnum->exact (ev "(w-i32 2147483648)"))))
(ok "uint32 narrows -1 to 4294967295"
    (= 4294967295 (jnum->exact (ev "(w-u32 -1)"))))

;; Values beyond the accepted bit-pattern envelope still fail closed. Exercise
;; both spellings at every aliased width so none can silently widen.
(for-each
 (lambda (named-form)
   (ok (car named-form)
       (raises? (lambda () (ev (cdr named-form))))))
 '(("i8 rejects -129" . "(w-i8 -129)")
   ("int8 rejects -129" . "(w-int8 -129)")
   ("short rejects -32769" . "(w-i16 -32769)")
   ("int16 rejects -32769" . "(w-int16 -32769)")
   ("ushort rejects 65536" . "(w-u16 65536)")
   ("uint16 rejects 65536" . "(w-uint16 65536)")
   ("int32 rejects -2147483649" . "(w-i32 -2147483649)")
   ("uint32 rejects 4294967296" . "(w-u32 4294967296)")))

;; --- callback path: C invokes exact-width jolt foreign-callables -------------
(for-each
  ev
  '("(def cb-i8  (jolt.ffi/__ccallable (fn [x] x) [:int8] :int8))"
    "(def cb-i16 (jolt.ffi/__ccallable (fn [x] x) [:int16] :int16))"
    "(def cb-u16 (jolt.ffi/__ccallable (fn [x] x) [:uint16] :uint16))"
    "(def cb-i32 (jolt.ffi/__ccallable (fn [x] x) [:int32] :int32))"
    "(def cb-u32 (jolt.ffi/__ccallable (fn [x] x) [:uint32] :uint32))"
    "(def call-i8  (jolt.ffi/__cfn \"jolt_w_call_i8\"  [:pointer] :int64))"
    "(def call-i16 (jolt.ffi/__cfn \"jolt_w_call_i16\" [:pointer] :int64))"
    "(def call-u16 (jolt.ffi/__cfn \"jolt_w_call_u16\" [:pointer] :uint64))"
    "(def call-i32 (jolt.ffi/__cfn \"jolt_w_call_i32\" [:pointer] :int64))"
    "(def call-u32 (jolt.ffi/__cfn \"jolt_w_call_u32\" [:pointer] :uint64))"))
(ok "C-invoked exact-width callbacks preserve boundary values"
    (equal? '(-128 -32768 65535 -2147483648 4294967295)
            (map (lambda (form) (jnum->exact (ev form)))
                 '("(call-i8 cb-i8)" "(call-i16 cb-i16)"
                   "(call-u16 cb-u16)" "(call-i32 cb-i32)"
                   "(call-u32 cb-u32)"))))
(for-each
  (lambda (name)
    (ev (string-append "(jolt.ffi/free-callable " name ")")))
  '("cb-i8" "cb-i16" "cb-u16" "cb-i32" "cb-u32"))

;; --- fail-closed: unknown runtime and compile-time types ---------------------
;; Eternal: a type neither table names must be rejected, never silently
;; marshaled at a guessed width. Holds before and after any table change.
(ok "unknown argtype rejected by __cfn"
    (raises? (lambda ()
               (ev "(jolt.ffi/__cfn \"jolt_w_widen_i16\" [:bogus] :int)"))))
(ok "unknown result type rejected by __cfn"
    (raises? (lambda ()
               (ev "(jolt.ffi/__cfn \"jolt_w_widen_i16\" [:int16] :bogus)"))))
(ok "unknown argtype rejected by __ccallable"
    (raises? (lambda ()
               (ev "(jolt.ffi/__ccallable (fn [x] x) [:bogus] :int)"))))
(ok "unknown result type rejected by __ccallable"
    (raises? (lambda ()
               (ev "(jolt.ffi/__ccallable (fn [x] x) [:int] :bogus)"))))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
