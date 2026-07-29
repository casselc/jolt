;; jolt.ffi regression: a compile-time-typed foreign binding lowers to a real
;; Chez foreign-procedure and calls native code. Run:
;;   chez --script test/chez/ffi-binding-test.ss
;; Binds a few libc functions (process symbols, always present) through the
;; jolt.ffi/__cfn special form + the host memory primitives — the same path a
;; library uses to bind its native deps.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/ffi.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
;; eval one form (string) in `user`, like the loader does form-by-form, so a def
;; is visible to a later form.
(define (ev s) (jolt-compile-eval s "user"))
(define (has? s sub)
  (let ((ns (string-length s)) (nsub (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i nsub) ns) #f)
            ((string=? (substring s i (+ i nsub)) sub) #t)
            (else (loop (+ i 1)))))))
(define (emitf ns str)
  (let-values (((f j) (rdr-read-form str 0 (string-length str))))
    (let ((ctx (make-analyze-ctx ns)))
      (jolt-ce-emit (jolt-ce-run-passes (jolt-ce-analyze ctx f) ctx)))))

;; load libc (process symbols) and bind typed foreign functions
(ev "(jolt.ffi/load-library)")
(ev "(def c-strlen (jolt.ffi/__cfn \"strlen\" [:string] :size_t))")
(ev "(def c-abs (jolt.ffi/__cfn \"abs\" [:int] :int))")

(ok "foreign-procedure built for strlen" (procedure? (var-deref "user" "c-strlen")))
(ok "typed call: strlen(\"hello\") = 5" (= 5 (jnum->exact (ev "(c-strlen \"hello\")"))))
(ok "typed call: abs(-7) = 7"          (= 7 (jnum->exact (ev "(c-abs -7)"))))

;; --- variadic ABI boundary --------------------------------------------------
;; A typed FFI still has to distinguish fixed from variadic C parameters. Apple
;; arm64 passes the latter on the stack even while fixed parameters still fit in
;; registers. fcntl's third argument is after `...`; treating this as a fixed
;; three-argument function can return success without applying F_SETFL.
(ok "lowering preserves collect-safe and variadic conventions together"
    (has? (emitf "user"
             "(jolt.ffi/__cfn \"fcntl\" [:int :int :int] :int
                                    {:blocking true :varargs-after 2})")
          "(foreign-procedure __collect_safe (__varargs_after 2) \"fcntl\""))
(ok "native-error capture composes with collect-safe and variadic conventions"
    (has? (emitf "user"
             "(jolt.ffi/__cfn \"fcntl\" [:int :int :int] :int
                {:blocking true :varargs-after 2 :capture-native-error true})")
          "(jolt-ffi-native-error-procedure (__collect_safe (__varargs_after 2)) \"fcntl\""))
(ev "(def c-fcntl
       (jolt.ffi/__cfn \"fcntl\" [:int :int :int] :int
                         {:varargs-after 2}))")
(ev "(def c-fcntl-collect-safe
       (jolt.ffi/__cfn \"fcntl\" [:int :int :int] :int
                         {:blocking true :varargs-after 2}))")
(ev "(def c-fcntl-all-options
       (jolt.ffi/__cfn \"fcntl\" [:int :int :int] :int
         {:blocking true :varargs-after 2 :capture-native-error true}))")
(ev "(def c-open-va
       (jolt.ffi/__cfn \"open\" [:string :int] :int
                         {:varargs-after 2}))")
(ev "(def c-close-va (jolt.ffi/__cfn \"close\" [:int] :int))")
(ok "variadic fcntl applies and reports O_NONBLOCK"
    (jolt-truthy?
      (ev "(let [fd (c-open-va \"/dev/null\" 0)
                  nonblock (case (:os (jolt.host/target))
                             :darwin 4
                             :linux 2048
                             2048)
                  before (c-fcntl fd 3 0)
                  rc (c-fcntl fd 4 (bit-or before nonblock))
                  after (c-fcntl fd 3 0)]
              (c-close-va fd)
              (and (not (neg? before))
                   (zero? rc)
                   (not (zero? (bit-and after nonblock)))))")))
(ok "variadic boundary composes with collect-safe calls"
    (integer?
      (jnum->exact
        (ev "(c-fcntl-collect-safe 0 3 0)"))))
(ok "native-error capture executes with collect-safe and variadic conventions"
    (jolt-truthy?
      (ev "(let [fd (c-open-va \"/dev/null\" 0)
                  result (c-fcntl-all-options fd 3 0)
                  _ (c-close-va fd)]
              (and (= 2 (count result))
                   (integer? (nth result 0))
                   (not (neg? (nth result 0)))
                   (integer? (nth result 1)))))")))
(ok "varargs boundary must be positive and within the declared arguments"
    (and
      (guard (e (#t #t))
        (ev "(jolt.ffi/__cfn \"fcntl\" [:int :int :int] :int
                              {:varargs-after 0})")
        #f)
      (guard (e (#t #t))
        (ev "(jolt.ffi/__cfn \"fcntl\" [:int :int :int] :int
                              {:varargs-after 4})")
        #f)))
(ok "foreign-fn option maps reject unknown and nonliteral policy"
    (and
      (guard (e (#t #t))
        (ev "(jolt.ffi/__cfn \"fcntl\" [:int :int :int] :int
                              {:varargs-after 2 :typo true})")
        #f)
      (guard (e (#t #t))
        (ev "(jolt.ffi/__cfn \"fcntl\" [:int :int :int] :int
                              {:blocking :yes :varargs-after 2})")
        #f)
      (guard (e (#t #t))
        (ev "(jolt.ffi/__cfn \"fcntl\" [:int :int :int] :int
                              {:capture-native-error :yes})")
        #f)
      (guard (e (#t #t))
        (ev "(jolt.ffi/__cfn \"fcntl\" [:int :int :int] :int
                              {:varargs-after 1.5})")
        #f)))
(ok "native-error capture requires a result sentinel"
    (guard (e (#t #t))
      (ev "(jolt.ffi/__cfn \"free\" [:pointer] :void
                            {:capture-native-error true})")
      #f))

;; xpatch changes Chez's compiler target but not (machine-type), which continues
;; to name the build host. Exercise both target choices directly so a
;; Linux-host -> Windows-target build cannot silently select __errno and a
;; Windows-host -> Linux-target build cannot leak the Windows-only convention
;; into the POSIX expander.
(define (native-error-convention-for-target target)
  (parameterize ((#%$target-machine target))
    ;; Build the test form at run time. Chez may pre-expand a literal passed to
    ;; eval while compiling this test procedure, before the parameterization is
    ;; active; expand on a fresh datum observes the intended compiler boundary.
    (cadr
      (syntax->datum
        (expand
          (list 'jolt-ffi-native-error-convention-case
                (list 'quote '__get_last_error)
                (list 'quote '__errno)))))))
(ok "simulated Linux->Windows target selects __get_last_error"
    (eq? '__get_last_error
         (native-error-convention-for-target 'ta6nt)))
(ok "simulated Windows->Linux target selects __errno"
    (eq? '__errno
         (native-error-convention-for-target 'ta6le)))

;; memory: alloc / write / read roundtrip through the host primitives
(ok "mem int roundtrip"
    (= 4242 (jnum->exact
              (ev "(let [p (jolt.ffi/alloc (jolt.ffi/sizeof :int))]
                     (jolt.ffi/write p :int 0 4242)
                     (let [v (jolt.ffi/read p :int)] (jolt.ffi/free p) v))"))))
(ok "sizeof :pointer is a word" (let ((n (jnum->exact (ev "(jolt.ffi/sizeof :pointer)")))) (or (= n 8) (= n 4))))

;; --- 16-bit types -----------------------------------------------------------
;; Before these existed a caller could not express a C `short` at all: struct
;; pollfd's two shorts had to be packed into one :int and masked, which is
;; silently wrong on a big-endian host. sockaddr_in.sin_family needs them too.
(ok "sizeof :int16/:uint16/:short/:ushort is 2"
    (equal? '(2 2 2 2)
            (map (lambda (t) (jnum->exact (ev (string-append "(jolt.ffi/sizeof " t ")"))))
                 '(":int16" ":uint16" ":short" ":ushort"))))
(ok "sizeof :int8 is 1" (= 1 (jnum->exact (ev "(jolt.ffi/sizeof :int8)"))))

(ok "uint16 roundtrip at the top of its range"
    (= 65535 (jnum->exact
               (ev "(let [p (jolt.ffi/alloc 2)]
                      (jolt.ffi/write p :uint16 0 65535)
                      (let [v (jolt.ffi/read p :uint16 0)] (jolt.ffi/free p) v))"))))
;; signedness is the whole point of having both: the same bits must read back as
;; -1 through :int16 and 65535 through :uint16.
(ev "(def p16 (jolt.ffi/alloc 2))")
(ev "(jolt.ffi/write p16 :int16 0 -1)")
(ok "int16 is signed where uint16 is not"
    (and (= -1 (jnum->exact (ev "(jolt.ffi/read p16 :int16 0)")))
         (= 65535 (jnum->exact (ev "(jolt.ffi/read p16 :uint16 0)")))))
(ev "(jolt.ffi/free p16)")
(ok "int16 roundtrips its most negative value"
    (= -32768 (jnum->exact
                (ev "(let [p (jolt.ffi/alloc 2)]
                       (jolt.ffi/write p :int16 0 -32768)
                       (let [v (jolt.ffi/read p :int16 0)] (jolt.ffi/free p) v))"))))

;; A 16-bit store must occupy exactly two bytes and be readable back as the same
;; value. Asserted endian-agnostically (the byte pair as a set), so this test is
;; meaningful on a big-endian host rather than silently host-specific.
(ev "(def pb (jolt.ffi/alloc 4))")
(ev "(jolt.ffi/write pb :uint8 2 171)")   ; sentinel byte after the 16-bit slot
(ev "(jolt.ffi/write pb :uint16 0 4660)") ; 0x1234
(ok "uint16 store occupies exactly its two bytes"
    (let ((b0 (jnum->exact (ev "(jolt.ffi/read pb :uint8 0)")))
          (b1 (jnum->exact (ev "(jolt.ffi/read pb :uint8 1)")))
          (b2 (jnum->exact (ev "(jolt.ffi/read pb :uint8 2)")))
          (v  (jnum->exact (ev "(jolt.ffi/read pb :uint16 0)"))))
      (and (equal? (list 18 52) (sort < (list b0 b1)))  ; {0x12,0x34}, either order
           (= 171 b2)                                    ; sentinel untouched
           (= 4660 v))))                                 ; 0x1234 reads back
(ev "(jolt.ffi/free pb)")

;; The compile-time half: a defcfn signature must accept 16-bit types too. htons
;; is genuinely uint16 -> uint16, so a wrong width shows up as a wrong value
;; rather than a crash. 443 = 0x01BB; byte-swapped = 0xBB01 = 47873.
(ev "(def c-htons (jolt.ffi/__cfn \"htons\" [:uint16] :uint16))")
(ev "(def c-ntohs (jolt.ffi/__cfn \"ntohs\" [:uint16] :uint16))")
(ok "typed 16-bit call: htons/ntohs roundtrip"
    (= 4660 (jnum->exact (ev "(c-ntohs (c-htons 4660))"))))
(ok "typed 16-bit call: htons(443) byte-swaps on a little-endian host"
    (let ((v (jnum->exact (ev "(c-htons 443)"))))
      (or (= v 47873) (= v 443))))   ; 443 unchanged iff the host is big-endian

;; still fails closed on a genuinely unknown type
(ok "unknown foreign type is still rejected"
    (guard (e (#t #t)) (ev "(jolt.ffi/sizeof :int128)") #f))

;; --- native error capture (jolt.ffi/errno) ----------------------------------
(ok "errno-source names a known strategy"
    (let ((k (ev "(jolt.ffi/errno-source)")))
      (and (keyword-t? k)
           (member (keyword-t-name k)
                   '("errno-location" "error" "wsa-get-last-error"))
           #t)))

;; a failing call sets a specific, recognizable code
(ev "(def c-open (jolt.ffi/__cfn \"open\" [:string :int] :int))")
(ev "(def rc-missing (c-open \"/nonexistent-zzz/nope\" 0))")
(ok "failed open returns -1" (= -1 (jnum->exact (var-deref "user" "rc-missing"))))
(ok "errno reports ENOENT (2) for the failed open"
    (= 2 (jnum->exact (ev "(jolt.ffi/errno)"))))

;; THE ordering property, made executable. This is the defect shape that
;; motivated the accessor: a rollback close() runs between the failure and the
;; read, and the caller reports the cleanup's error instead of the real one.
;; close(-1) fails with EBADF (9), overwriting the ENOENT (2) above -- exactly
;; what a constructor's `(c-close fd)` before `(errno)` does. Capture must
;; therefore happen before any cleanup call, which is what the docstring on
;; ffi-errno requires of callers.
(ev "(def c-close (jolt.ffi/__cfn \"close\" [:int] :int))")
(ev "(def captured-before (jolt.ffi/errno))")   ; capture FIRST, as callers must
(ev "(def cleanup-rc (c-close -1))")            ; then the rollback call
(ok "a failing cleanup call does overwrite errno"
    (and (= -1 (jnum->exact (var-deref "user" "cleanup-rc")))
         (= 9 (jnum->exact (ev "(jolt.ffi/errno)")))))
(ok "the value captured before cleanup survives it"
    (= 2 (jnum->exact (var-deref "user" "captured-before"))))

;; Stronger opt-in: Chez captures errno in the foreign-call return path itself.
;; The generated Jolt callable materializes both Scheme values as [result code],
;; so even a collect-safe return transition cannot interpose before capture.
(ev "(def c-open-with-error
       (jolt.ffi/__cfn \"open\" [:string :int] :int
         {:capture-native-error true}))")
(ev "(def open-with-error
       (c-open-with-error \"/nonexistent-zzz/nope\" 0))")
(ok "atomic native-error binding returns [result error-code]"
    (jolt-truthy? (ev "(= [-1 2] open-with-error)")))
(ev "(c-close -1)")
(ok "atomic native-error pair survives later native cleanup"
    (jolt-truthy? (ev "(= [-1 2] open-with-error)")))

;; Composition with __collect_safe is the Windows/Winsock defect shape: the
;; runtime may perform work while reactivating the Scheme thread, after the C
;; call returned but before ordinary Jolt code could call ffi/errno.
(ev "(def c-close-with-error-blocking
       (jolt.ffi/__cfn \"close\" [:int] :int
         {:blocking true :capture-native-error true}))")
(ok "atomic native-error capture composes with collect-safe calls"
    (jolt-truthy? (ev "(= [-1 9] (c-close-with-error-blocking -1))")))

;; byte-array buffer I/O: write a byte-array into foreign memory and read it back
;; byte-exact (high bytes preserved, no UTF-8 mangling).
(ok "byte-array uses an unboxed Chez bytevector backing"
    (bytevector? (jolt-array-vec (ev "(byte-array [0 128 255])"))))
(ev "(def c-memcmp
       (jolt.ffi/__cfn \"memcmp\" [:byte-array :byte-array :size_t] :int))")
(ev "(def c-memset
       (jolt.ffi/__cfn \"memset\" [:byte-array :int :size_t] :pointer))")
(ok "typed byte-array arguments borrow binary storage directly"
    (jolt-truthy?
      (ev "(let [a (byte-array [0 128 255 7])
                  b (byte-array [0 128 255 7])]
              (zero? (c-memcmp a b 4)))")))
(ok "typed byte-array output mutates the original array"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2 3 4])]
              (c-memset a 171 3)
              (= [171 171 171 4] (vec a)))")))
(ev "(def c-memcmp-pointer
       (jolt.ffi/__cfn \"memcmp\" [:pointer :byte-array :size_t] :int))")
(ev "(def c-memset-pointer
       (jolt.ffi/__cfn \"memset\" [:pointer :int :size_t] :pointer))")
(ok "scoped byte-array pointer borrows an interior slice without copying"
    (jolt-truthy?
      (ev "(let [a (byte-array [9 1 2 8])
                  expected (byte-array [1 2])]
              (jolt.ffi/with-byte-array-pointer
                a 1 2
                (fn [p n] (zero? (c-memcmp-pointer p expected n))))))")))
(ok "scoped byte-array pointer mutates the original interior slice"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2 3 4])]
              (jolt.ffi/with-byte-array-pointer
                a 1 2
                (fn [p n] (c-memset-pointer p 171 n)))
              (= [1 171 171 4] (vec a)))")))
(ok "scoped byte-array pointer remains stable across collection"
    (let ((a (ev "(byte-array [1 2 3 4])")))
      (and (ffi-with-byte-array-pointer
             a 1 2
             (lambda (p n)
               (collect)
               (foreign-set! 'unsigned-8 p 0 205)
               (= n 2)))
           (= 205 (bytevector-u8-ref (jolt-array-vec a) 1)))))
(ok "scoped byte-array pointer allows an empty slice at array end"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2])]
              (jolt.ffi/with-byte-array-pointer
                a 2 0
                (fn [p n] (and (pos? p) (zero? n)))))")))
(ok "scoped byte-array pointer rejects invalid ranges before callback"
    (jolt-truthy?
      (ev "(let [a (byte-array 2)]
              (and (try
                     (jolt.ffi/with-byte-array-pointer a -1 1 (fn [_ _] false))
                     false
                     (catch IndexOutOfBoundsException _ true))
                   (try
                     (jolt.ffi/with-byte-array-pointer a 1 2 (fn [_ _] false))
                     false
                     (catch IndexOutOfBoundsException _ true))))")))
(ok "typed byte-array arguments reject other array kinds"
    (jolt-truthy?
      (ev "(try (c-memset (int-array [1 2]) 0 2) false
                (catch IllegalArgumentException _ true))")))
(ok "typed byte-array arguments fail closed on collect-safe calls"
    (guard (e (#t #t))
      (ev "(jolt.ffi/__cfn \"read\" [:int :byte-array :size_t] :ssize_t :blocking)")
      #f))
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

;; Range-aware byte transfers expose caller-controlled source/destination
;; windows for socket and crypto callers. High/signed input bytes remain
;; binary-faithful.
(ok "write-array source range"
    (jolt-truthy?
      (ev "(let [src (byte-array [9 -1 -128 7])
                  p (jolt.ffi/alloc 2)]
              (jolt.ffi/write-array p src 1 2)
              (let [back (jolt.ffi/read-array p 2)]
                (jolt.ffi/free p)
                (= [255 128] (vec back))))")))
(ok "read-array! destination range"
    (jolt-truthy?
      (ev "(let [src (byte-array [0 65 200 255 10])
                  dst (byte-array [7 7 7 7 7])
                  p (jolt.ffi/alloc 5)]
              (jolt.ffi/write-array p src)
              (let [n (jolt.ffi/read-array! (+ p 1) 3 dst 1)]
                (jolt.ffi/free p)
                (and (= 3 n) (= [7 65 200 255 7] (vec dst)))))")))
(ok "range transfers match snapshot copies across small subranges"
    (jolt-truthy?
      (ev "(let [src (byte-array [0 65 128 200 255])
                  p (jolt.ffi/alloc 5)
                  good? (every? true?
                          (for [src-off (range 6)
                                len (range (inc (- 5 src-off)))
                                dst-off (range (inc (- 6 len)))]
                            (let [dst (byte-array (repeat 6 -7))
                                  expected (reduce
                                             (fn [v [i x]] (assoc v (+ dst-off i) x))
                                             [249 249 249 249 249 249]
                                             (map-indexed vector
                                               (subvec (vec src) src-off (+ src-off len))))]
                              (and (= len (jolt.ffi/write-array p src src-off len))
                                   (= len (jolt.ffi/read-array! p len dst dst-off))
                                   (= expected (vec dst))))))]
              (jolt.ffi/free p)
              good?)")))
(ok "range transfers allow zero length at array end"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2])]
              (and (= 0 (jolt.ffi/read-array! 0 0 a 2))
                   (= 0 (jolt.ffi/write-array 0 a 2 0))
                   (= [1 2] (vec a))))")))
(ok "range transfers reject out-of-bounds before native access"
    (jolt-truthy?
      (ev "(let [a (byte-array 2)]
              (and (try (jolt.ffi/read-array! 0 2 a 1) false
                        (catch IndexOutOfBoundsException _ true))
                   (try (jolt.ffi/write-array 0 a -1 1) false
                        (catch IndexOutOfBoundsException _ true))))")))
(ok "non-empty range transfers reject a null pointer"
    (jolt-truthy?
      (ev "(let [a (byte-array 1)]
              (and (try (jolt.ffi/read-array! 0 1 a 0) false
                        (catch NullPointerException _ true))
                   (try (jolt.ffi/write-array 0 a 0 1) false
                        (catch NullPointerException _ true))))")))
(ok "read-array rejects a negative length before allocation"
    (jolt-truthy?
      (ev "(try (jolt.ffi/read-array 0 -1) false
                (catch IndexOutOfBoundsException _ true))")))
(ok "bulk transfer preserves a large binary payload"
    (jolt-truthy?
      (ev "(let [n 65536
                  src (byte-array (map #(bit-and % 255) (range n)))
                  dst (byte-array n)
                  p (jolt.ffi/alloc n)]
              (jolt.ffi/write-array p src)
              (jolt.ffi/read-array! p n dst 0)
              (jolt.ffi/free p)
              (= (vec src) (vec dst)))")))

;; --- HK0B: ranged transfers copy through a scoped interior pointer ----------
;; A ranged read-array!/write-array no longer stages the bytes through a
;; temporary bytevector; it locks the destination/source range and moves the
;; bytes with one memmove between native memory and the interior pointer. The
;; checks below are the semantic boundary that change has to preserve: the
;; complete offset/length table with sentinels on BOTH sides, every rejection
;; leaving the whole geometry untouched, lock/unlock pairing observable through
;; Chez's locked-object?, and same-backing overlap.

(define (mk-bytes lst) (make-jolt-array (u8-list->bytevector lst) 'byte))
(define (arr-bytes a) (bytevector->u8-list (jolt-array-vec a)))
(define (fill-native! p n v) (do ((i 0 (+ i 1))) ((= i n)) (foreign-set! 'unsigned-8 p i v)))
(define (native-bytes p n)
  (let loop ((i (- n 1)) (acc '()))
    (if (< i 0) acc (loop (- i 1) (cons (foreign-ref 'unsigned-8 p i) acc)))))
(define (throws? thunk) (guard (e (#t #t)) (thunk) #f))
(define (slice lst off len) (list-head (list-tail lst off) len))

;; Exhaustive small table. For every array offset, length, and native offset:
;; the transferred window is exact, the untouched prefix and suffix on both the
;; array side and the native side keep their sentinels, and the count is the
;; requested length. Zero-length rows and the exact-tail row (offset = length,
;; length 0) are included by construction.
(let* ((asize 8)
       (nsize 12)
       (nsentinel 238)                        ; native fill
       (dsentinel 249)                        ; destination-array fill
       (pat (lambda (i) (bit-and (+ 16 (* 37 i)) 255)))
       (src-list (map pat (iota asize)))
       (native-list (map (lambda (i) (pat (+ 100 i))) (iota nsize)))
       (p (foreign-alloc nsize))
       (rows 0) (bad 0))
  (do ((off 0 (+ off 1))) ((> off asize))
    (do ((len 0 (+ len 1))) ((> len (- asize off)))
      (do ((noff 0 (+ noff 1))) ((> noff (- nsize len)))
        ;; array range -> native
        (let ((src (mk-bytes src-list)))
          (fill-native! p nsize nsentinel)
          (let ((n (ffi-write-array (+ p noff) src off len)))
            (set! rows (+ rows 1))
            (unless (and (= n len)
                         (equal? (arr-bytes src) src-list)
                         (equal? (native-bytes (+ p noff) len) (slice src-list off len))
                         (equal? (native-bytes p noff) (make-list noff nsentinel))
                         (equal? (native-bytes (+ p noff len) (- nsize noff len))
                                 (make-list (- nsize noff len) nsentinel)))
              (set! bad (+ bad 1)))))
        ;; native -> array range
        (let ((dst (mk-bytes (make-list asize dsentinel))))
          (do ((i 0 (+ i 1))) ((= i nsize))
            (foreign-set! 'unsigned-8 p i (list-ref native-list i)))
          (let ((n (ffi-read-array! (+ p noff) len dst off)))
            (set! rows (+ rows 1))
            (unless (and (= n len)
                         (equal? (native-bytes p nsize) native-list)
                         (equal? (slice (arr-bytes dst) off len) (slice native-list noff len))
                         (equal? (list-head (arr-bytes dst) off) (make-list off dsentinel))
                         (equal? (list-tail (arr-bytes dst) (+ off len))
                                 (make-list (- asize off len) dsentinel)))
              (set! bad (+ bad 1))))))))
  (foreign-free p)
  (printf "ranged transfer table: ~a rows, ~a failures~n" rows bad)
  (ok "exhaustive ranged transfer table preserves prefix/suffix sentinels"
      (and (= rows 930) (= bad 0))))

;; Every rejection is complete before the first native access or destination
;; mutation, so the whole destination AND source geometry survives it.
(let* ((asize 4)
       (nsize 4)
       (dsentinel 249)
       (nsentinel 238)
       (p (foreign-alloc nsize))
       (arr (mk-bytes (make-list asize dsentinel)))
       (bv (jolt-array-vec arr))
       (huge (expt 2 62))
       (intact? (lambda ()
                  (and (equal? (arr-bytes arr) (make-list asize dsentinel))
                       (equal? (native-bytes p nsize) (make-list nsize nsentinel))
                       (not (locked-object? bv)))))
       (rows 0) (bad 0)
       (row (lambda (name thunk)
              (set! rows (+ rows 1))
              (fill-native! p nsize nsentinel)
              (unless (and (throws? thunk) (intact?))
                (set! bad (+ bad 1))
                (printf "FAIL rejection row: ~a~n" name))))
       (bad-array "not-a-byte-array"))
  (row "read negative length"    (lambda () (ffi-read-array! p -1 arr 0)))
  (row "read negative offset"    (lambda () (ffi-read-array! p 1 arr -1)))
  (row "read length past end"    (lambda () (ffi-read-array! p 5 arr 0)))
  (row "read offset past end"    (lambda () (ffi-read-array! p 0 arr 5)))
  (row "read exact tail plus 1"  (lambda () (ffi-read-array! p 1 arr 4)))
  (row "read overflow-shaped"    (lambda () (ffi-read-array! p huge arr 1)))
  (row "read null non-empty"     (lambda () (ffi-read-array! 0 1 arr 0)))
  (row "read wrong array kind"   (lambda () (ffi-read-array! p 1 bad-array 0)))
  (row "write negative length"   (lambda () (ffi-write-array p arr 0 -1)))
  (row "write negative offset"   (lambda () (ffi-write-array p arr -1 1)))
  (row "write length past end"   (lambda () (ffi-write-array p arr 0 5)))
  (row "write offset past end"   (lambda () (ffi-write-array p arr 5 0)))
  (row "write exact tail plus 1" (lambda () (ffi-write-array p arr 4 1)))
  (row "write overflow-shaped"   (lambda () (ffi-write-array p arr 1 huge)))
  (row "write null non-empty"    (lambda () (ffi-write-array 0 arr 0 1)))
  (row "write wrong array kind"  (lambda () (ffi-write-array p bad-array 0 1)))
  (row "write whole wrong kind"  (lambda () (ffi-write-array p bad-array)))
  (row "scope negative offset"   (lambda () (ffi-with-byte-array-pointer arr -1 1 (lambda (q m) m))))
  (row "scope length past end"   (lambda () (ffi-with-byte-array-pointer arr 1 4 (lambda (q m) m))))
  (row "scope overflow-shaped"   (lambda () (ffi-with-byte-array-pointer arr 1 huge (lambda (q m) m))))
  (row "scope wrong array kind"  (lambda () (ffi-with-byte-array-pointer bad-array 0 1 (lambda (q m) m))))
  (foreign-free p)
  (printf "rejection rows: ~a, ~a failures~n" rows bad)
  (ok "rejected transfers and scopes leave the full geometry unchanged"
      (and (= rows 21) (= bad 0))))

;; Zero-length transfers stay valid with a null pointer, at the exact tail, and
;; without taking a lock at all.
(let* ((arr (mk-bytes '(1 2)))
       (bv (jolt-array-vec arr)))
  (ok "zero-length exact-tail transfers accept a null pointer and touch nothing"
      (and (= 0 (ffi-read-array! 0 0 arr 2))
           (= 0 (ffi-write-array 0 arr 2 0))
           (= 0 (ffi-read-array! 0 0 arr 0))
           (equal? (arr-bytes arr) '(1 2))
           (not (locked-object? bv)))))

;; Lock/unlock pairing, observed directly rather than inferred.
(let* ((arr (mk-bytes '(1 2 3 4 5 6 7 8)))
       (bv (jolt-array-vec arr)))
  (ok "nested public scopes each balance one reference-counted lock"
      (and (not (locked-object? bv))
           (ffi-with-byte-array-pointer
             arr 1 4
             (lambda (p n)
               (and (locked-object? bv)
                    (ffi-with-byte-array-pointer
                      arr 2 2
                      (lambda (q m)
                        (and (locked-object? bv) (= q (+ p 1)) (= m 2))))
                    ;; the inner scope released only its own lock
                    (locked-object? bv)
                    (= n 4))))
           (not (locked-object? bv))))
  (ok "a throw out of the callback unlocks, and a later scope still works"
      (and (throws? (lambda ()
                      (ffi-with-byte-array-pointer arr 0 4 (lambda (p n) (error 'hk0b "boom")))))
           (not (locked-object? bv))
           (ffi-with-byte-array-pointer arr 0 4 (lambda (p n) (= n 4)))
           (not (locked-object? bv))))
  (ok "a nonlocal exit out of the callback unlocks"
      (and (call/cc (lambda (k)
                      (ffi-with-byte-array-pointer arr 0 4 (lambda (p n) (k #t)))))
           (not (locked-object? bv)))))
(let ((bv (make-bytevector 8 0)))
  (ok "the private scope unlocks when the receiver throws"
      (and (throws? (lambda ()
                      (ffi-with-locked-byte-range "probe" bv 1 4
                                                  (lambda (p n arg) (error 'hk0b "boom")) 0)))
           (not (locked-object? bv))
           (= 4 (ffi-with-locked-byte-range "probe" bv 1 4 (lambda (p n arg) n) 0))
           (not (locked-object? bv)))))
(ev "(def scoped-throw-arr (byte-array [1 2 3 4]))")
(ok "a Jolt exception out of the callback unlocks the backing"
    (and (jolt-truthy?
           (ev "(try (jolt.ffi/with-byte-array-pointer scoped-throw-arr 0 2
                       (fn [p n] (throw (Exception. \"hk0b\"))))
                     false
                     (catch Exception _ true))"))
         (not (locked-object? (jolt-array-vec (var-deref "user" "scoped-throw-arr"))))
         (jolt-truthy?
           (ev "(jolt.ffi/with-byte-array-pointer scoped-throw-arr 0 2 (fn [p n] (= n 2)))"))))

;; A collection inside the scope cannot move the backing storage, and a ranged
;; transfer nested inside a live scope still lands in the right window.
(let* ((arr (mk-bytes '(1 2 3 4 5 6 7 8)))
       (bv (jolt-array-vec arr))
       (p (foreign-alloc 4)))
  (do ((i 0 (+ i 1))) ((= i 4)) (foreign-set! 'unsigned-8 p i (+ 200 i)))
  (ok "the backing address is stable across a collection inside the scope"
      (ffi-with-byte-array-pointer
        arr 2 4
        (lambda (q n)
          (let ((before (object->reference-address bv)))
            (collect)
            (and (= before (object->reference-address bv))
                 (= q (+ before 2))
                 ;; a ranged transfer nested in the live scope
                 (= 4 (ffi-read-array! p 4 arr 2))
                 (equal? (arr-bytes arr) '(1 2 200 201 202 203 7 8))
                 (locked-object? bv))))))
  (foreign-free p)
  (ok "the nested transfer released its own lock with the scope"
      (not (locked-object? bv))))

;; Same-backing overlap. The native pointer and the array range are the same
;; storage, so a staged copy and a memmove agree while a memcpy need not. Both
;; API directions are exercised at every small distance, forward and backward.
(let* ((n 32)
       (fresh (lambda ()
                (let ((bv (make-bytevector n)))
                  (do ((i 0 (+ i 1))) ((= i n)) (bytevector-u8-set! bv i (bit-and (* 7 i) 255)))
                  bv)))
       (memcpy-raw! (foreign-procedure "memcpy" (uptr uptr uptr) void))
       (forward-copy! (lambda (bv soff doff len)
                        ;; the overlap-unsafe implementation these rows exclude:
                        ;; an in-place forward byte loop, which re-reads bytes it
                        ;; has already overwritten when doff > soff.
                        (do ((i 0 (+ i 1))) ((= i len))
                          (bytevector-u8-set! bv (+ doff i) (bytevector-u8-ref bv (+ soff i))))))
       (expected (lambda (soff doff len)
                   ;; bytevector-copy! is specified for overlap: the reference
                   (let ((bv (fresh)))
                     (bytevector-copy! bv soff bv doff len)
                     (bytevector->u8-list bv))))
       (rows 0) (bad 0) (memcpy-divergent 0) (forward-divergent 0) (controls 0))
  (do ((delta 1 (+ delta 1))) ((> delta 8))
    (do ((len 4 (+ len 4))) ((> len 16))
      (for-each
        (lambda (pair)
          (let* ((soff (car pair)) (doff (cdr pair)) (want (expected soff doff len)))
            ;; read-array!: native source aliases the destination array range
            (let* ((arr (make-jolt-array (fresh) 'byte))
                   (bv (jolt-array-vec arr))
                   (got (ffi-with-byte-array-pointer
                          arr 0 n
                          (lambda (base m)
                            (and (= len (ffi-read-array! (+ base soff) len arr doff))
                                 (bytevector->u8-list bv))))))
              (set! rows (+ rows 1))
              (unless (and (equal? got want) (not (locked-object? bv)))
                (set! bad (+ bad 1))
                (printf "FAIL overlap read soff=~a doff=~a len=~a~n" soff doff len)))
            ;; write-array: native destination aliases the source array range
            (let* ((arr (make-jolt-array (fresh) 'byte))
                   (bv (jolt-array-vec arr))
                   (got (ffi-with-byte-array-pointer
                          arr 0 n
                          (lambda (base m)
                            (and (= len (ffi-write-array (+ base doff) arr soff len))
                                 (bytevector->u8-list bv))))))
              (set! rows (+ rows 1))
              (unless (and (equal? got want) (not (locked-object? bv)))
                (set! bad (+ bad 1))
                (printf "FAIL overlap write soff=~a doff=~a len=~a~n" soff doff len)))
            ;; Controls, so the gated rows above are discriminating rather than
            ;; decorative. The forward byte loop is the overlap-unsafe shape the
            ;; requirement excludes, and it must fail these rows on any host.
            ;; memcpy is reported too, but not gated: its disjointness
            ;; precondition is violated here, so a host is free to return either
            ;; answer -- glibc x86-64 in particular reaches the same code as
            ;; memmove, and diverges on nothing.
            (set! controls (+ controls 1))
            (let ((fbv (fresh)))
              (forward-copy! fbv soff doff len)
              (unless (equal? (bytevector->u8-list fbv) want)
                (set! forward-divergent (+ forward-divergent 1))))
            (let ((cbv (fresh)))
              (lock-object cbv)
              (memcpy-raw! (+ (object->reference-address cbv) doff)
                           (+ (object->reference-address cbv) soff)
                           len)
              (unlock-object cbv)
              (unless (equal? (bytevector->u8-list cbv) want)
                (set! memcpy-divergent (+ memcpy-divergent 1))))))
        (list (cons 4 (+ 4 delta)) (cons (+ 4 delta) 4)))))
  (printf "overlap rows: ~a, ~a failures; controls ~a: forward-loop diverged on ~a, memcpy on ~a~n"
          rows bad controls forward-divergent memcpy-divergent)
  (ok "same-backing overlap matches memmove semantics in both directions"
      (and (= rows 128) (= bad 0)))
  ;; 26 of the 64 control rows have doff > soff with len > the distance, which
  ;; is exactly the set a forward byte loop gets wrong; the rest it happens to
  ;; get right, which is why the count is pinned rather than merely positive.
  (ok "the overlap rows reject an overlap-unsafe forward copy"
      (= forward-divergent 26)))

;; Large-payload conservation: a megabyte moved out through a ranged window and
;; back into a different ranged window is byte-identical, and the sentinels
;; around both windows are untouched. One memmove per direction now carries the
;; whole payload, so a defect in the interior-pointer arithmetic that a 5-byte
;; row cannot see -- a wrong base, a lost offset, a truncated count -- shows up
;; here as a mismatch rather than as a slow test.
(let* ((payload 1048576)
       (pad 64)
       (asize (+ payload (* 2 pad)))
       (sentinel 173)
       (src-bv (make-bytevector asize sentinel))
       (dst-bv (make-bytevector asize sentinel))
       (p (foreign-alloc payload)))
  (do ((i 0 (+ i 1))) ((= i payload))
    (bytevector-u8-set! src-bv (+ pad i) (bitwise-and (+ (* i 31) (quotient i 251)) 255)))
  (let* ((src (make-jolt-array src-bv 'byte))
         (dst (make-jolt-array dst-bv 'byte))
         (wrote (ffi-write-array p src pad payload))
         (read (ffi-read-array! p payload dst pad)))
    (foreign-free p)
    (ok "a megabyte survives a ranged round trip with its sentinels intact"
        (and (= wrote payload)
             (= read payload)
             (equal? (bytevector->u8-list (bytevector-copy src-bv))
                     (bytevector->u8-list src-bv))
             ;; payload conserved exactly
             (let loop ((i 0))
               (cond ((= i payload) #t)
                     ((= (bytevector-u8-ref src-bv (+ pad i))
                         (bytevector-u8-ref dst-bv (+ pad i)))
                      (loop (+ i 1)))
                     (else #f)))
             ;; prefix and suffix sentinels on the destination survived
             (let loop ((i 0))
               (cond ((= i pad) #t)
                     ((and (= sentinel (bytevector-u8-ref dst-bv i))
                           (= sentinel (bytevector-u8-ref dst-bv (- asize 1 i))))
                      (loop (+ i 1)))
                     (else #f)))
             (not (locked-object? src-bv))
             (not (locked-object? dst-bv))))))

;; The public API keeps the same overlap guarantee from Jolt code.
(ok "overlapping ranged transfer through the public API is snapshot-exact"
    (jolt-truthy?
      (ev "(let [a (byte-array [0 1 2 3 4 5 6 7])]
             (jolt.ffi/with-byte-array-pointer
               a 0 8
               (fn [p n] (jolt.ffi/read-array! p 5 a 3)))
             (= [0 1 2 0 1 2 3 4] (vec a)))")))

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
