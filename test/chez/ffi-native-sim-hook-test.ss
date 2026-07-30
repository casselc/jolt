;; jolt.ffi native-OP interception (simulation) seam gate.
;;
;; The same disabled-by-default internal hook that intercepts every
;; jolt.ffi/defcfn CALL (see ffi-sim-hook-test.ss) also intercepts the runtime
;; primitives a jolt library uses to load shared objects and manage raw foreign
;; memory: load-library, loaded?, alloc, free, read, write, read-bytes,
;; write-bytes, read-array, write-array, ptr->string, string->ptr, sizeof.
;;
;; Each primitive reads the same hot-path variable and, when a hook is installed,
;; routes the call through it with a stable plain descriptor carrying
;; `kind=native-op`, `op`, and the live call `args` — distinguishable from a
;; defcfn call descriptor, which is keyed by `csym`. The hook's return stands in for the primitive's result,
;; and the live args let a hook emulate writes through byte arrays / pointers.
;; With no hook the original body runs unchanged and no descriptor is allocated,
;; so a disabled seam has exactly its prior behavior — and under a hook,
;; nonexistent libraries and the fake pointers a hook hands back never reach the
;; OS loader or Chez's foreign-memory primitives.
;;
;; This is a runtime slice (host/chez/java/ffi.ss, loaded from source) — not a
;; compiler-source slice — so it normally runs against the checked-in seed.
;; After the shared seed learns the special sim compiler flavor, this gate opts
;; into it so the defcfn discrimination below retains its interception branch.
;; The guarded lookup keeps the gate compatible with the pre-remint seed, whose
;; emitter still includes that branch unconditionally. A caller may instead hand
;; a converged seed pair:
;;   chez --script test/chez/ffi-native-sim-hook-test.ss
;;   chez --script test/chez/ffi-native-sim-hook-test.ss PRELUDE IMAGE

(import (chezscheme))

(define seed-args (cdr (command-line)))
(cond
  ((null? seed-args)
   (load "host/chez/gate-boot.ss"))
  ((= (length seed-args) 2)
   (load "host/chez/rt.ss")
   (set-chez-ns! "clojure.core")
   (load (car seed-args))
   (load "host/chez/post-prelude.ss")
   (set-chez-ns! "user")
   (load "host/chez/host-contract.ss")
   (load (cadr seed-args))
   (load "host/chez/compile-eval.ss"))
  (else
    (display "usage: ffi-native-sim-hook-test.ss [PRELUDE IMAGE]\n"
             (current-error-port))
    (exit 2)))

;; Match cli.ss's loader boundary: the loader (source roots -> real file loading
;; for `require`) must exist before jolt.ffi's host primitives install, so an
;; ordinary (require '[jolt.ffi :as ffi]) resolves stdlib/jolt/ffi.clj's macros
;; exactly like a real library.
(load "host/chez/loader.ss")
(set-source-roots! ldr-install-roots)
(load "host/chez/java/ffi.ss")
;; The native-op interception this gate drives (jolt-ffi-sim-hook,
;; jolt-ffi-install-sim-hook!/-clear-sim-hook!, the ffi-sim-* wrappers) lives
;; in the simulation-only overlay, not in java/ffi.ss itself — an ordinary
;; release/debug binary never loads it and its raw ops stay branch-free.
(load "host/chez/sim/runtime.ss")

;; Current pre-remint seeds have no setter and emit the hook branch
;; unconditionally. Reminted seeds default to ordinary direct FFI emission, so
;; explicitly select the special compiler flavor when the setter exists.
(let ((ssi (guard (e (#t #f))
             (var-deref "jolt.backend-scheme" "set-sim-instrument!"))))
  (when (procedure? ssi) (ssi #t)))

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
;; eval one form (string) in `user`, like the loader does form-by-form.
(define (ev s) (jolt-compile-eval s "user"))
(define (dget d k) (cdr (assq k d)))

;; --- a fully simulated native-memory controller ------------------------------
;; A real simulation controller: it tracks loaded libraries, hands out fake
;; pointers backed by Scheme bytevectors, and emulates every primitive over
;; them. The fake pointers it produces are small integers that are NOT valid
;; mmap'd addresses — so the only reason read/write/free on them do not crash
;; Chez is that the hook intercepts them. A defcfn call descriptor (csym) is
;; distinguished from a native-op descriptor (op) and answered with a sentinel.
(define native-ops '())          ; op-name strings, in capture order
(define native-mem (make-eqv-hashtable))   ; fake ptr (exact int) -> bytevector
(define native-libs (make-hashtable string-hash equal?))  ; name -> #t
(define native-next-ptr 1000000)
(define cfn-sentinel 8888)

(define (sim-reset!)
  (set! native-ops '())
  (set! native-mem (make-eqv-hashtable))
  (set! native-libs (make-hashtable string-hash equal?))
  (set! native-next-ptr 1000000))

(define (sim-bv p) (hashtable-ref native-mem p #f))
(define (sim-alloc-bytes! n)
  (let ((p native-next-ptr) (bv (make-bytevector n 0)))
    (set! native-next-ptr (+ native-next-ptr 1))
    (hashtable-set! native-mem p bv) p))

(define (kw-name k) (if (keyword-t? k) (keyword-t-name k) (jolt-str-render-one k)))

(define (bv-get-u8 bv off) (bytevector-u8-ref bv off))
(define (bv-set-u8! bv off b) (bytevector-u8-set! bv off (bitwise-and b 255)))
(define (bv-get-int bv off)          ; little-endian signed 32
  (let ((u (+ (bv-get-u8 bv off)
              (* (bv-get-u8 bv (+ off 1)) 256)
              (* (bv-get-u8 bv (+ off 2)) 65536)
              (* (bv-get-u8 bv (+ off 3)) 16777216))))
    (if (>= u 2147483648) (- u 4294967296) u)))
(define (bv-set-int! bv off val)
  (let ((u (modulo val 4294967296)))
    (bv-set-u8! bv off u)
    (bv-set-u8! bv (+ off 1) (quotient u 256))
    (bv-set-u8! bv (+ off 2) (quotient u 65536))
    (bv-set-u8! bv (+ off 3) (quotient u 16777216))))

(define (sim-type-size name)
  (cond
    ((or (string=? name "int") (string=? name "uint")
         (string=? name "int32") (string=? name "uint32")) 4)
    ((or (string=? name "int16") (string=? name "uint16")
         (string=? name "short") (string=? name "ushort")) 2)
    ((or (string=? name "int8") (string=? name "uint8")
         (string=? name "i8") (string=? name "u8")
         (string=? name "byte") (string=? name "char")) 1)
    (else 8)))

(define (native-hook desc)
  ;; A defcfn call descriptor is keyed by csym; a native-op descriptor by op.
  ;; Route on exactly that and answer a call with a fixed sentinel.
  (cond
    ((assq 'csym desc) cfn-sentinel)
    (else
     (let ((op (cdr (assq 'op desc))) (args (cdr (assq 'args desc))))
       (set! native-ops (append native-ops (list op)))
       (cond
         ((string=? op "load-library")
          (when (and (pair? args)
                     (not (jolt-nil? (car args)))
                     (not (string=?
                           (jolt-str-render-one (car args))
                           "definitely_not_a_real_lib_zzz9.so")))
            (hashtable-set! native-libs
                            (jolt-str-render-one (car args))
                            #t))
          jolt-nil)
         ((string=? op "loaded?")
          (if (hashtable-ref native-libs (jolt-str-render-one (car args)) #f) #t #f))
         ((string=? op "alloc") (sim-alloc-bytes! (jnum->exact (car args))))
         ((string=? op "free")
          (hashtable-delete! native-mem (jnum->exact (car args))) jolt-nil)
         ((string=? op "sizeof") (sim-type-size (kw-name (car args))))
         ((string=? op "read")
          (let* ((p (jnum->exact (car args))) (ty (kw-name (cadr args)))
                 (off (if (>= (length args) 3) (jnum->exact (caddr args)) 0))
                 (bv (sim-bv p)))
            (cond ((or (string=? ty "int") (string=? ty "uint")) (bv-get-int bv off))
                  (else (bv-get-u8 bv off)))))
         ((string=? op "write")
          (let* ((p (jnum->exact (car args))) (ty (kw-name (cadr args)))
                 (off (jnum->exact (caddr args))) (val (jnum->exact (cadddr args)))
                 (bv (sim-bv p)))
            (cond ((or (string=? ty "int") (string=? ty "uint")) (bv-set-int! bv off val))
                  (else (bv-set-u8! bv off val)))
            jolt-nil))
         ((string=? op "read-bytes")
          (let* ((p (jnum->exact (car args))) (n (jnum->exact (cadr args)))
                 (bv (sim-bv p)) (out (make-bytevector n 0)))
            (do ((i 0 (+ i 1))) ((= i n)) (bytevector-u8-set! out i (bytevector-u8-ref bv i)))
            (utf8->string out)))
         ((string=? op "write-bytes")
          (let* ((p (jnum->exact (car args))) (sbv (string->utf8 (jolt-str-render-one (cadr args))))
                 (n (bytevector-length sbv)) (bv (sim-bv p)))
            (do ((i 0 (+ i 1))) ((= i n)) (bytevector-u8-set! bv i (bytevector-u8-ref sbv i)))
            n))
         ((string=? op "read-array")
          (let* ((p (jnum->exact (car args))) (n (jnum->exact (cadr args)))
                 (bv (sim-bv p)) (v (make-vector n 0)))
            (do ((i 0 (+ i 1))) ((= i n)) (vector-set! v i (bytevector-u8-ref bv i)))
            (make-jolt-array v 'byte)))
         ((string=? op "write-array")
          (let* ((p (jnum->exact (car args))) (jv (jolt-array-vec (cadr args)))
                 (n (vector-length jv)) (bv (sim-bv p)))
            (do ((i 0 (+ i 1))) ((= i n)) (bytevector-u8-set! bv i (bitwise-and (exact (vector-ref jv i)) 255)))
            n))
         ((string=? op "ptr->string")
          (let* ((p (jnum->exact (car args))) (bv (sim-bv p)))
            (if (not bv) jolt-nil
                (let loop ((i 0) (acc '()))
                  (let ((b (bytevector-u8-ref bv i)))
                    (if (= b 0) (utf8->string (u8-list->bytevector (reverse acc)))
                        (loop (+ i 1) (cons b acc))))))))
         ((string=? op "string->ptr")
          (let* ((sbv (string->utf8 (jolt-str-render-one (car args)))) (n (bytevector-length sbv))
                 (buf (make-bytevector (+ n 1) 0)))
            (do ((i 0 (+ i 1))) ((= i n)) (bytevector-u8-set! buf i (bytevector-u8-ref sbv i)))
            (sim-alloc-bytes! (+ n 1))            ; consumes a fake ptr id...
            (let ((p (- native-next-ptr 1)))      ; ...and returns that same one
              (hashtable-set! native-mem p buf) p)))
         (else (error 'native-hook "unknown native op" op)))))))

(define (captured-op? op) (exists (lambda (o) (string=? o op)) native-ops))
;; --- ordinary jolt code: require jolt.ffi, load libc, bind a real symbol -----
(ev "(require '[jolt.ffi :as ffi])")
(ev "(ffi/load-library)")
(ev "(ffi/defcfn c-abs \"abs\" [:int] :int)")

(ok "no hook installed by default" (not jolt-ffi-sim-hook))

;; With no hook the original bodies run unchanged: real foreign memory, no
;; descriptor allocated. A real int roundtrip + sizeof prove the disabled seam.
(ok "disabled seam: real alloc/write/read roundtrip"
    (= 4242 (jnum->exact
              (ev "(let [p (ffi/alloc (ffi/sizeof :int))]
                     (ffi/write p :int 0 4242)
                     (let [v (ffi/read p :int 0)] (ffi/free p) v))"))))
(ok "disabled seam: no native-op descriptor captured yet"
    (null? native-ops))

;; --- hook installed: every native op is intercepted + simulated --------------
(define native-installation (jolt-ffi-install-sim-hook! native-hook))

;; sizeof routes to the hook and returns the simulated width (4 for :int), not
;; the host's foreign-sizeof.
(ok "sizeof intercepted: simulated :int width is 4"
    (= 4 (jnum->exact (ev "(ffi/sizeof :int)"))))
(ok "sizeof captured as a native-op descriptor"
    (captured-op? "sizeof"))

;; alloc returns a FAKE pointer (a small integer, not a real address); write/
;; read over it roundtrip through the simulated store. The live args reach the
;; hook: write's value comes back from read unchanged (out-param emulation).
(ev "(def sim-p (ffi/alloc 8))")
(ok "alloc intercepted and returned a fake pointer"
    (and (integer? (jnum->exact (ev "sim-p")))
         (>= (jnum->exact (ev "sim-p")) 1000000)))
(ev "(ffi/write sim-p :int 0 4242)")
(ok "read intercepts the fake pointer and emulates the prior write"
    (= 4242 (jnum->exact (ev "(ffi/read sim-p :int 0)"))))
(ok "read without explicit offset defaults to byte 0"
    (= 4242 (jnum->exact (ev "(ffi/read sim-p :int)"))))
(ev "(ffi/write sim-p :uint8 1 255)")
(ok "uint8 read/write over a fake pointer roundtrips"
    (= 255 (jnum->exact (ev "(ffi/read sim-p :uint8 1)"))))
(ok "alloc/read/write descriptors all captured"
    (and (captured-op? "alloc") (captured-op? "read")
         (captured-op? "write")))

;; Fake-pointer safety: every primitive that would reach Chez's foreign-memory
;; ops on a bogus address instead routes to the hook and returns cleanly.
(ok "free over a fake pointer does not reach Chez"
    (jolt-nil? (ev "(ffi/free sim-p)")))
(ev "(def sim-q (ffi/alloc 4))")
(ok "read-bytes over a fresh fake pointer returns without crashing"
    (equal? "\x00;\x00;\x00;\x00;" (ev "(ffi/read-bytes sim-q 4)")))
(ok "write-bytes over a fake pointer returns the byte count"
    (= 2 (jnum->exact (ev "(ffi/write-bytes sim-q \"Hi\")"))))
(ok "read-bytes returns what write-bytes stored"
    (equal? "Hi" (ev "(ffi/read-bytes sim-q 2)")))
(ok "read-bytes/write-bytes descriptors captured"
    (and (captured-op? "read-bytes") (captured-op? "write-bytes") (captured-op? "free")))

;; byte-array buffer I/O over fake pointers: write-array stores, read-array
;; returns a fresh byte-array with the same bytes (binary-faithful roundtrip).
(ok "write-array over a fake pointer returns the byte count"
    (= 3 (jnum->exact (ev "(ffi/write-array sim-q (byte-array [10 20 30]))"))))
(ev "(def sim-bar (ffi/read-array sim-q 3))")
(ok "read-array over a fake pointer returns a 3-byte array"
    (= 3 (jnum->exact (ev "(alength sim-bar)"))))
(ok "read-array bytes match what write-array stored"
    (and (= 10 (jnum->exact (ev "(aget sim-bar 0)")))
         (= 20 (jnum->exact (ev "(aget sim-bar 1)")))
         (= 30 (jnum->exact (ev "(aget sim-bar 2)")))))
(ok "read-array/write-array descriptors captured"
    (and (captured-op? "read-array") (captured-op? "write-array")))

;; string marshaling over fake pointers: string->ptr allocates a NUL-terminated
;; buffer; ptr->string reads it back. ptr->string of a null/unknown ptr -> nil.
(ok "string->ptr over the hook returns a fake pointer"
    (>= (jnum->exact
          (ev "(do (def sim-sp (ffi/string->ptr \"hello\")) sim-sp)"))
        1000000))
(ok "ptr->string recovers the string a prior string->ptr stored"
    (equal? "hello" (ev "(ffi/ptr->string sim-sp)")))
(ok "ptr->string of the null pointer yields nil"
    (jolt-nil? (ev "(ffi/ptr->string ffi/null)")))
(ok "ptr->string/string->ptr descriptors captured"
    (and (captured-op? "ptr->string") (captured-op? "string->ptr")))

;; Nonexistent-library safety: the OS loader is never consulted under the hook.
;; The real load-library has no guard around load-shared-object, so a missing
;; .so would throw; returning nil here proves the hook intercepted it.
(ok "zero-argument process load routes through the hook"
    (guard (e (#t #f))
      (ev "(ffi/load-library)")
      #t))
(ok "load-library under the hook does not throw for a nonexistent lib"
    (guard (e (#t #f))
      (ev "(ffi/load-library \"definitely_not_a_real_lib_zzz9.so\")")
      #t))
(ok "loaded? under the hook reports an unloaded nonexistent lib as false"
    (not (jolt-truthy? (ev "(ffi/loaded? \"definitely_not_a_real_lib_zzz9.so\")"))))
;; A library the simulation "loaded" is reported loaded — proving loaded? is
;; answered by the hook (Chez could not have loaded a nonexistent file).
(ev "(ffi/load-library \"libsim-zzz9.so\")")
(ok "loaded? reports a simulation-loaded library as true"
    (jolt-truthy? (ev "(ffi/loaded? \"libsim-zzz9.so\")")))
(ok "load-library/loaded? descriptors captured"
    (and (captured-op? "load-library") (captured-op? "loaded?")))

;; --- descriptor shape: stable, plain, distinguishable from a defcfn call -----
;; A defcfn call (csym descriptor) and a native op (op descriptor) both route to
;; the same hook; the controller tells them apart and answers each correctly.
(ok "a defcfn call under the hook is answered with the call sentinel"
    (= cfn-sentinel (jnum->exact (ev "(c-abs -5)"))))
(ok "a native op under the SAME hook is still simulated (not treated as a call)"
    (= 4 (jnum->exact (ev "(ffi/sizeof :int)"))))
;; Reinstall a controller to inspect exact descriptor shape and snapshot
;; isolation across calls.
(jolt-ffi-clear-sim-hook! native-installation)
(define shape-captured '())
(define shape-installation
  (jolt-ffi-install-sim-hook!
   (lambda (desc)
     (when (assq 'op desc)
       (set! shape-captured (append shape-captured (list desc))))
     4)))
(ev "(ffi/sizeof :int)")
(define shape-first (car shape-captured))
(ok "native-op descriptor has an explicit kind and no csym"
    (and (eq? 'native-op (dget shape-first 'kind))
         (assq 'op shape-first)
         (not (assq 'csym shape-first))))
(ok "native-op descriptor op name is a snapshot string"
    (string=? (dget shape-first 'op) "sizeof"))
(ok "native-op descriptor args preserve the live call argument"
    (and (pair? (dget shape-first 'args))
         (string=? (kw-name (car (dget shape-first 'args))) "int")))
;; Mutating the snapshot must not corrupt a later descriptor's op name.
(string-set! (dget shape-first 'op) 0 #\X)
(ev "(ffi/sizeof :int)")
(ok "mutating one operation descriptor cannot corrupt the next"
    (and (= 2 (length shape-captured))
         (string=? (dget (cadr shape-captured) 'op) "sizeof")))
(jolt-ffi-clear-sim-hook! shape-installation)

;; A native operation must keep using the shared fail-closed invocation helper:
;; if the hook itself performs another intercepted native operation on the same
;; thread, reject it instead of recursing or reaching real foreign memory.
;; ffi-sim-sizeof (not the base, branch-free ffi-sizeof) is the entry point
;; jolt.ffi/sizeof is rebound to, so it is what re-enters the seam here.
(define reentrant-installation
  (jolt-ffi-install-sim-hook!
   (lambda (desc)
     (ffi-sim-sizeof (car (dget desc 'args))))))
(ok "native operation reentrancy fails closed"
    (guard (e (#t #t))
      (ev "(ffi/sizeof :int)")
      #f))
(jolt-ffi-clear-sim-hook! reentrant-installation)

;; --- clearing restores the exact native behavior -----------------------------
;; The hook is gone: the original bodies run, real foreign memory works, and the
;; controller is not consulted again.
(define ops-at-clear (length native-ops))
(ok "clear restores no-hook state" (not jolt-ffi-sim-hook))
(ok "cleared seam: real alloc/write/read roundtrip works again"
    (= -7777 (jnum->exact
               (ev "(let [p (ffi/alloc (ffi/sizeof :int))]
                      (ffi/write p :int 0 -7777)
                      (let [v (ffi/read p :int 0)] (ffi/free p) v))"))))
(ok "cleared seam: real sizeof is the host width (4 for :int)"
    (= 4 (jnum->exact (ev "(ffi/sizeof :int)"))))
(ok "cleared seam: a real byte-array roundtrip is binary-faithful"
    (jolt-truthy?
      (ev "(let [src (byte-array [0 65 200 255 10]) p (ffi/alloc 5)]
             (ffi/write-array p src)
             (let [back (ffi/read-array p 5)] (ffi/free p)
               (and (= 5 (alength back)) (= 255 (aget back 3)))))")))
(ok "cleared seam: real ptr->string/string->ptr roundtrip"
    (equal? "native!"
            (ev "(let [s (ffi/string->ptr \"native!\")] (let [v (ffi/ptr->string s)] (ffi/free s) v))")))
(ok "cleared seam: native defcfn call still works"
    (= 9 (jnum->exact (ev "(c-abs -9)"))))
(ok "a cleared hook is not consulted again"
    (= ops-at-clear (length native-ops)))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
