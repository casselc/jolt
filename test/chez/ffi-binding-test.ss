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
