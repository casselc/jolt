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

;; Match cli.ss's loader boundary so the public jolt.ffi macros are exercised
;; from source under both the checked seed and caller-supplied transient seeds.
(load "host/chez/loader.ss")
(set-source-roots! ldr-install-roots)
(load "host/chez/java/ffi.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
;; eval one form (string) in `user`, like the loader does form-by-form, so a def
;; is visible to a later form.
(define (ev s) (jolt-compile-eval s "user"))
(define (ev-fails? s) (guard (e (#t #t)) (ev s) #f))
(define (has? s sub)
  (let ((ns (string-length s)) (nsub (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i nsub) ns) #f)
            ((string=? (substring s i (+ i nsub)) sub) #t)
            (else (loop (+ i 1)))))))

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
(ok "byte-array uses an unboxed Chez bytevector backing"
    (bytevector? (jolt-array-vec (ev "(byte-array [0 128 255])"))))
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
(ok "write-array rejects non-byte primitive arrays"
    (jolt-truthy?
      (ev "(let [p (jolt.ffi/alloc 1)]
             (try
               (jolt.ffi/write-array p (int-array [1]))
               false
               (catch IllegalArgumentException _ true)
               (finally (jolt.ffi/free p))))")))

;; Scoped zero-copy loans: the callback receives a stable pointer into the
;; bytevector-backed array. It may call native code, allocate, collect, throw,
;; nest another loan, or leave nonlocally; the pointer dies at the first exit.
(ev "(def c-memset-pointer
       (jolt.ffi/__cfn \"memset\" [:pointer :int :size_t] :pointer))")
(ok "ranged pointer loan mutates only the selected live array window"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2 3 4])
                  result
                  (jolt.ffi/with-byte-array-pointer
                    a 1 2
                    (fn [p n]
                      (c-memset-pointer p 171 n)
                      :callback-result))]
              (and (= :callback-result result)
                   (= [1 171 171 4] (vec a))))")))
(ok "whole-array pointer-loan arity supplies the complete validated length"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2 3])]
              (and (= 3
                      (jolt.ffi/with-byte-array-pointer
                        a
                        (fn [p n]
                          (c-memset-pointer p 205 n)
                          n)))
                   (= [205 205 205] (vec a))))")))
(ok "scoped pointer stays stable across allocation and collection"
    (let* ((a (ev "(byte-array [1 2 3 4])"))
           (bv (jolt-array-vec a)))
      (and
       (ffi-with-byte-array-pointer
        a 1 2
        (lambda (p n)
          (let ((before (object->reference-address bv)))
            (make-bytevector 1048576 0)
            (collect)
            (foreign-set! 'unsigned-8 p 0 99)
            (and (= n 2)
                 (= p (+ before 1))
                 (= before (object->reference-address bv))
                 (locked-object? bv)))))
       (= 99 (bytevector-u8-ref bv 1))
       (not (locked-object? bv)))))
(ok "empty exact-tail and whole-empty loans are valid"
    (jolt-truthy?
      (ev "(and
             (let [a (byte-array [1 2])]
               (jolt.ffi/with-byte-array-pointer
                 a 2 0
                 (fn [p n] (and (integer? p) (pos? p) (zero? n)))))
             (let [a (byte-array 0)]
               (jolt.ffi/with-byte-array-pointer
                 a
                 (fn [p n] (and (integer? p) (pos? p) (zero? n))))))")))
(ok "invalid pointer-loan ranges fail before the callback"
    (jolt-truthy?
      (ev "(let [a (byte-array 2) calls (atom 0)
                  f (fn [_ _] (swap! calls inc))]
              (and
                (try
                  (jolt.ffi/with-byte-array-pointer a -1 1 f)
                  false
                  (catch IndexOutOfBoundsException _ true))
                (try
                  (jolt.ffi/with-byte-array-pointer a 1 2 f)
                  false
                  (catch IndexOutOfBoundsException _ true))
                (try
                  (jolt.ffi/with-byte-array-pointer
                    a 1 4611686018427387904 f)
                  false
                  (catch IndexOutOfBoundsException _ true))
                (zero? @calls)))")))
(ok "pointer loans reject non-byte arrays"
    (jolt-truthy?
      (ev "(try
             (jolt.ffi/with-byte-array-pointer
               (int-array [1 2]) (fn [_ _] false))
             false
             (catch IllegalArgumentException _ true))")))
(let* ((a (ev "(byte-array [1 2 3 4 5 6 7 8])"))
       (bv (jolt-array-vec a)))
  (ok "nested same-array loans balance reference-counted locks"
      (and
       (not (locked-object? bv))
       (ffi-with-byte-array-pointer
        a 1 4
        (lambda (p n)
          (and
           (locked-object? bv)
           (ffi-with-byte-array-pointer
            a 2 2
            (lambda (q m)
              (and (locked-object? bv) (= q (+ p 1)) (= m 2))))
           (locked-object? bv)
           (= n 4))))
       (not (locked-object? bv))))
  (ok "callback error and nonlocal exit both retire and unlock the loan"
      (and
       (guard (e (#t #t))
         (ffi-with-byte-array-pointer
          a 0 4 (lambda (p n) (error 'pointer-loan "boom")))
         #f)
       (not (locked-object? bv))
       (call/cc
        (lambda (escape)
          (ffi-with-byte-array-pointer
           a 0 4 (lambda (p n) (escape #t)))))
       (not (locked-object? bv))
       (= 4
          (ffi-with-byte-array-pointer
           a 0 4 (lambda (p n) n)))
       (not (locked-object? bv)))))
(let* ((bv (make-bytevector 8 0))
       (saved #f)
       (phase 0)
       (visits '())
       (outcome
        (guard (e (#t
                   (list 'raised (condition-message e)
                         (reverse visits) (locked-object? bv))))
          (let ((value
                 (ffi-with-locked-byte-range
                  "reentry" bv 0 8
                  (lambda (pointer count argument)
                    (call/cc
                     (lambda (continuation)
                       (unless saved (set! saved continuation))
                       'first-entry))
                    (set! visits (cons (locked-object? bv) visits))
                    (locked-object? bv))
                  0)))
            (if (= phase 0)
                (begin (set! phase 1) (saved 'second-entry))
                (list 'returned value (reverse visits)
                      (locked-object? bv)))))))
  (ok "retired pointer scope rejects continuation re-entry before callback resumes"
      (and
       (eq? 'raised (car outcome))
       (has? (cadr outcome) "cannot be re-entered")
       (equal? '(#t) (caddr outcome))
       (not (cadddr outcome))
       (not (locked-object? bv))
       (= 8
          (ffi-with-locked-byte-range
           "later-scope" bv 0 8 (lambda (p n arg) n) 0))
       (not (locked-object? bv)))))
(ev "(def pointer-throw-array (byte-array [1 2 3 4]))")
(ok "Jolt exception out of a loan unlocks before a later scope"
    (and
     (jolt-truthy?
      (ev "(try
             (jolt.ffi/with-byte-array-pointer
               pointer-throw-array 0 2
               (fn [_ _] (throw (Exception. \"loan boom\"))))
             false
             (catch Exception _ true))"))
     (not
      (locked-object?
       (jolt-array-vec (var-deref "user" "pointer-throw-array"))))
     (jolt-truthy?
      (ev "(jolt.ffi/with-byte-array-pointer
             pointer-throw-array 0 2 (fn [_ n] (= n 2)))"))))

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

;; --- public option boundary + atomic native-error capture --------------------
;; Exercise the public macros from stdlib source as well as direct __cfn forms.
;; The analyzer must fail closed on every nonliteral/unknown option, while
;; omission and explicit false retain the original scalar contract.
(ev "(require '[jolt.ffi :as ffi])")
(ev "(def opt-abs (ffi/foreign-fn \"abs\" [:int] :int))")
(ev "(def opt-abs-legacy (ffi/foreign-fn \"abs\" [:int] :int :blocking))")
(ev "(def opt-abs-blocking
       (ffi/foreign-fn \"abs\" [:int] :int {:blocking true}))")
(ev "(def opt-abs-captured
       (ffi/foreign-fn \"abs\" [:int] :int {:capture-native-error true}))")
(ev "(def opt-abs-both
       (ffi/foreign-fn \"abs\" [:int] :int
         {:blocking true :capture-native-error true}))")
(ev "(def opt-abs-false
       (ffi/foreign-fn \"abs\" [:int] :int
         {:blocking false :capture-native-error false}))")
(ev "(def opt-abs-empty (ffi/foreign-fn \"abs\" [:int] :int {}))")

(ok "foreign-fn omitted options retain scalar semantics"
    (= 9 (jnum->exact (ev "(opt-abs -9)"))))
(ok "foreign-fn legacy :blocking retains scalar semantics"
    (= 8 (jnum->exact (ev "(opt-abs-legacy -8)"))))
(ok "foreign-fn {:blocking true} retains scalar semantics"
    (= 7 (jnum->exact (ev "(opt-abs-blocking -7)"))))
(ok "foreign-fn explicit false flags retain scalar semantics"
    (= 6 (jnum->exact (ev "(opt-abs-false -6)"))))
(ok "foreign-fn empty options map defaults both flags to false"
    (= 5 (jnum->exact (ev "(opt-abs-empty -5)"))))
(ok "foreign-fn capture returns a two-element result-first vector"
    (jolt-truthy?
      (ev "(let [v (opt-abs-captured -4)]
             (and (vector? v) (= 2 (count v))
                  (= 4 (nth v 0)) (integer? (nth v 1))))")))
(ok "foreign-fn capture composes with collect-safe lowering"
    (jolt-truthy?
      (ev "(let [v (opt-abs-both -3)]
             (and (vector? v) (= 2 (count v))
                  (= 3 (nth v 0)) (integer? (nth v 1))))")))

(ev "(ffi/defcfn opt-defcfn-abs \"abs\" [:int] :int
       {:capture-native-error true})")
(ok "defcfn forwards capture options to the same result contract"
    (jolt-truthy?
      (ev "(let [v (opt-defcfn-abs -2)]
             (and (vector? v) (= 2 (count v))
                  (= 2 (nth v 0)) (integer? (nth v 1))))")))

(ev "(def opt-cfn-map
       (jolt.ffi/__cfn \"abs\" [:int] :int
         {:blocking true :capture-native-error false}))")
(ok "direct __cfn accepts the literal options map"
    (= 1 (jnum->exact (ev "(opt-cfn-map -1)"))))
(ev "(def opt-cfn-void-false
       (jolt.ffi/__cfn \"unused_void_symbol_zzz9\" [] :void
         {:capture-native-error false}))")
(ok "capture false leaves a void binding valid"
    (procedure? (var-deref "user" "opt-cfn-void-false")))

(ok "reject numeric macro options"
    (ev-fails? "(ffi/foreign-fn \"abs\" [:int] :int 5)"))
(ok "reject explicit nil macro options"
    (ev-fails? "(ffi/foreign-fn \"abs\" [:int] :int nil)"))
(ok "reject multiple macro option arguments"
    (ev-fails? "(ffi/foreign-fn \"abs\" [:int] :int :blocking {})"))
(ok "reject numeric direct __cfn options"
    (ev-fails? "(jolt.ffi/__cfn \"abs\" [:int] :int 5)"))
(ok "reject non-:blocking keyword options"
    (ev-fails? "(jolt.ffi/__cfn \"abs\" [:int] :int :collect-safe)"))
(ok "reject symbolic options"
    (ev-fails? "(jolt.ffi/__cfn \"abs\" [:int] :int not-an-option)"))
(ok "reject non-keyword option-map keys"
    (ev-fails? "(jolt.ffi/__cfn \"abs\" [:int] :int {\"blocking\" true})"))
(ok "reject namespaced option-map keys"
    (ev-fails? "(jolt.ffi/__cfn \"abs\" [:int] :int {:other/blocking true})"))
(ok "reject unknown option-map keys"
    (ev-fails? "(jolt.ffi/__cfn \"abs\" [:int] :int {:bogus true})"))
(ok "reject non-boolean option values"
    (ev-fails? "(jolt.ffi/__cfn \"abs\" [:int] :int {:blocking 1})"))
(ok "reject nonliteral option values"
    (ev-fails? "(jolt.ffi/__cfn \"abs\" [:int] :int
                 {:capture-native-error flag})"))
(ok "reject duplicate literal option keys at the reader boundary"
    (ev-fails? "(jolt.ffi/__cfn \"abs\" [:int] :int
                 {:blocking true :blocking false})"))
(ok "reject captured void bindings"
    (ev-fails? "(jolt.ffi/__cfn \"free\" [:pointer] :void
                 {:capture-native-error true})"))

;; POSIX control: open a definitely absent path (ENOENT=2), then call close(-1)
;; (EBADF=9). The first pair must survive the later error-slot mutation.
(ev "(def c-open-with-error
       (jolt.ffi/__cfn \"open\" [:string :int] :int
         {:capture-native-error true}))")
(ev "(def c-close (jolt.ffi/__cfn \"close\" [:int] :int))")
(ev "(def c-close-with-error-blocking
       (jolt.ffi/__cfn \"close\" [:int] :int
         {:blocking true :capture-native-error true}))")
(ev "(def saved-posix-error
       (when (not= :windows (:os (jolt.host/target)))
         (c-open-with-error \"/definitely-absent-jolt-ffi-capture/nope\" 0)))")
(ok "POSIX capture obtains the native result and ENOENT atomically"
    (jolt-truthy?
      (ev "(or (= :windows (:os (jolt.host/target)))
               (= [-1 2] saved-posix-error))")))
(ev "(when (not= :windows (:os (jolt.host/target))) (c-close -1))")
(ok "POSIX captured pair survives a later native cleanup failure"
    (jolt-truthy?
      (ev "(or (= :windows (:os (jolt.host/target)))
               (= [-1 2] saved-posix-error))")))
(ok "POSIX native-error capture composes with collect-safe calls"
    (jolt-truthy?
      (ev "(or (= :windows (:os (jolt.host/target)))
               (= [-1 9] (c-close-with-error-blocking -1)))")))

;; Windows control: CloseHandle(NULL) fails with ERROR_INVALID_HANDLE=6.
;; SetLastError mutates the ambient slot afterward; the saved pair is immutable.
(ev "(when (= :windows (:os (jolt.host/target)))
       (jolt.ffi/load-library \"kernel32.dll\"))")
(ev "(def c-close-handle-with-error
       (jolt.ffi/__cfn \"CloseHandle\" [:uptr] :int
         {:capture-native-error true}))")
(ev "(def c-close-handle-with-error-blocking
       (jolt.ffi/__cfn \"CloseHandle\" [:uptr] :int
         {:blocking true :capture-native-error true}))")
(ev "(def c-set-last-error
       (jolt.ffi/__cfn \"SetLastError\" [:uint] :void))")
(ev "(def saved-windows-error
       (when (= :windows (:os (jolt.host/target)))
         (c-close-handle-with-error 0)))")
(ok "Windows capture obtains the native result and last-error atomically"
    (jolt-truthy?
      (ev "(or (not= :windows (:os (jolt.host/target)))
               (= [0 6] saved-windows-error))")))
(ev "(when (= :windows (:os (jolt.host/target))) (c-set-last-error 1234))")
(ok "Windows captured pair survives a later last-error mutation"
    (jolt-truthy?
      (ev "(or (not= :windows (:os (jolt.host/target)))
               (= [0 6] saved-windows-error))")))
(ok "Windows native-error capture composes with collect-safe calls"
    (jolt-truthy?
      (ev "(or (not= :windows (:os (jolt.host/target)))
               (= [0 6] (c-close-handle-with-error-blocking 0)))")))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
