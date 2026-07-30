;; jolt.ffi regression: a compile-time-typed foreign binding lowers to a real
;; Chez foreign-procedure and calls native code. Run:
;;   chez --script test/chez/ffi-binding-test.ss
;; Or validate compiler-source changes against a caller-supplied seed pair:
;;   chez --script test/chez/ffi-binding-test.ss PRELUDE IMAGE
;; Binds a few libc functions (process symbols, always present) through the
;; jolt.ffi/__cfn special form + the host memory primitives — the same path a
;; library uses to bind its native deps.

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
    (display "usage: ffi-binding-test.ss [PRELUDE IMAGE]\n"
             (current-error-port))
    (exit 2)))

(load "host/chez/java/ffi.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
;; eval one form (string) in `user`, like the loader does form-by-form, so a def
;; is visible to a later form.
(define (ev s) (jolt-compile-eval s "user"))

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
;; pollfd and sockaddr fields cannot be modeled portably by packing shorts into
;; an :int: that silently reverses the fields on a big-endian host.
(ok "16-bit aliases have exact width 2"
    (equal? '(2 2 2 2)
            (map (lambda (t)
                   (jnum->exact
                     (ev (string-append "(jolt.ffi/sizeof " t ")"))))
                 '(":int16" ":short" ":uint16" ":ushort"))))
(ok "signed 8-bit aliases have exact width 1"
    (equal? '(1 1)
            (map (lambda (t)
                   (jnum->exact
                     (ev (string-append "(jolt.ffi/sizeof " t ")"))))
                 '(":int8" ":i8"))))

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

(ev "(def p8 (jolt.ffi/alloc 1))")
(ev "(jolt.ffi/write p8 :i8 0 -1)")
(ok "signed 8-bit aliases preserve sign"
    (= -1 (jnum->exact (ev "(jolt.ffi/read p8 :int8 0)"))))
(ev "(jolt.ffi/free p8)")

;; Store-width check is endian-neutral: the two bytes may be in either order,
;; but the sentinel immediately after them must remain untouched.
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

;; Exercise the compiler-side signature table as well as the runtime accessors.
(ev "(def c-htons (jolt.ffi/__cfn \"htons\" [:uint16] :uint16))")
(ev "(def c-ntohs (jolt.ffi/__cfn \"ntohs\" [:ushort] :ushort))")
(ok "typed uint16 native calls roundtrip"
    (= 4660 (jnum->exact (ev "(c-ntohs (c-htons 4660))"))))
(ok "typed uint16 native calls accept the unsigned maximum"
    (= 65535 (jnum->exact (ev "(c-ntohs (c-htons 65535))"))))
(ev "(def signed-byte-id
       (jolt.ffi/__ccallable (fn [x] x) [:int8] :i8))")
(ok "signed 8-bit callback signature compiles"
    (let ((p (jnum->exact (var-deref "user" "signed-byte-id"))))
      (and (integer? p) (> p 0))))
(ev "(jolt.ffi/free-callable signed-byte-id)")

(ok "unknown runtime memory types fail closed"
    (guard (e (#t #t))
      (ev "(jolt.ffi/sizeof :int128)")
      #f))
(ok "unknown compile-time signature types fail closed"
    (guard (e (#t #t))
      (ev "(jolt.ffi/__cfn \"strlen\" [:int128] :int)")
      #f))

;; byte-array buffer I/O: write a byte-array into foreign memory and read it back
;; byte-exact (high bytes preserved, no UTF-8 mangling).
(ok "byte-array roundtrip (binary-faithful)"
    (jolt-truthy?
      (ev "(let [src (byte-array [0 65 200 255 10])
                  p (jolt.ffi/alloc 5)]
              (jolt.ffi/write-array p src)
              (let [back (jolt.ffi/read-array p 5)]
                (jolt.ffi/free p)
                (and (= 5 (alength back))
                     (= 0 (aget back 0)) (= 65 (aget back 1))
                     (= 200 (aget back 2)) (= 255 (aget back 3)) (= 10 (aget back 4)))))")))

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

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
