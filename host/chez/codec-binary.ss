;; codec-binary.ss — jolt.codec.binary: a checked binary scalar substrate over
;; byte arrays.
;;
;; The namespace is jolt.codec.binary, NOT jolt.bytes. jolt.bytes is owned by the
;; external casselc/jolt-bytes package (Window, Cursor, slicing, copying), and
;; the loader seeds its loaded-ns table from every namespace that already has
;; host vars — so publishing these vars into jolt.bytes would mark that namespace
;; loaded at startup and stop (require '[jolt.bytes …]) from ever reading the
;; library's Clojure source at all. This substrate is the codec layer's scalar
;; floor; jolt.bytes is a separate, higher-level view abstraction that may sit on
;; top of it.
;;
;; Every binary protocol implementation (a length-prefixed RPC envelope, bencode,
;; a compression header, an image or audio container) needs the same three
;; things: read a fixed-width integer or float out of a byte array at an explicit
;; offset, write one back, and move a range of bytes. Written in Clojure over
;; aget/aset that costs a boxed index dispatch and a hand-rolled shift/or chain
;; per byte; written here it is one Chez bytevector primitive.
;;
;; The contract this namespace fixes is BOUNDS, not convenience:
;;
;;   * admission is subtraction-form. After proving 0 <= offset <= limit, a
;;     span of `size` is admitted only when size <= limit - offset. The additive
;;     form (offset + size > limit) is the same test only when the sum cannot
;;     overflow; the subtraction form is correct without that side condition and
;;     stays correct for the machine-integer ports of this code.
;;   * argument validation precedes range admission, and range admission
;;     precedes mutation. A rejected write or copy leaves the destination
;;     byte-for-byte unchanged — there is exactly one mutating primitive call per
;;     operation and every check is upstream of it.
;;   * a value is never silently narrowed or reinterpreted. Writing 70000 as a
;;     u16, -1 as a u32, or the exact integer 1 where a float is required is an
;;     error, not a truncation. (Chez's own bytevector-ieee-double-set! accepts
;;     exact 1 and stores 1.0; that reinterpretation is rejected here.)
;;
;; The exception taxonomy is part of the API and is documented in
;; stdlib/jolt/codec/binary.clj:
;;
;;   IndexOutOfBoundsException     invalid range
;;   IllegalArgumentException      invalid value (type or domain)
;;   UnsupportedOperationException unsupported host representation
;;
;; Loaded after natives-array.ss — a jolt byte-array is a jolt-array of kind
;; 'byte whose backing IS a Chez bytevector, so every accessor below hands that
;; bytevector straight to the R6RS primitive with no staging copy.

;; --- argument validation -----------------------------------------------------

(define (jb-who who) (string-append "jolt.codec.binary/" who))

;; The backing bytevector of a jolt byte-array. Any other value — an object
;; array, a bytevector that never went through byte-array, nil — is an invalid
;; value rather than an out-of-range access, and is rejected before any offset
;; is even examined.
(define (jb-backing who arr)
  (if (and (jolt-array? arr) (eq? (jolt-array-kind arr) 'byte))
      (jolt-array-vec arr)
      (throw-jvm (quote IllegalArgumentException)
                 (string-append (jb-who who) ": expected a byte-array"))))

;; An offset/size argument must be an exact integer. A flonum index (2.0, 1.5)
;; is rejected instead of truncated: jnum->exact would silently accept 1.9 as 1,
;; which is precisely the kind of quiet reinterpretation a codec cannot afford.
(define (jb-index who n)
  (if (and (integer? n) (exact? n))
      n
      (throw-jvm (quote IllegalArgumentException)
                 (string-append (jb-who who) ": expected an exact integer offset"))))

;; Subtraction-form admission. `limit` is the array length; the two guards are
;; ordered so that 0 <= off <= limit is established before limit - off is used,
;; and so that an overflow-shaped request (a huge offset paired with a huge size)
;; is rejected by the offset guard rather than by an arithmetic accident.
(define (jb-check-range who bv off size)
  (let ((limit (bytevector-length bv)))
    (when (or (< off 0) (> off limit))
      (throw-jvm (quote IndexOutOfBoundsException)
                 (string-append (jb-who who) ": offset out of range")))
    (when (or (< size 0) (> size (- limit off)))
      (throw-jvm (quote IndexOutOfBoundsException)
                 (string-append (jb-who who) ": range out of bounds")))))

(define (jb-domain-error who lo hi)
  (throw-jvm (quote IllegalArgumentException)
             (string-append (jb-who who) ": value outside ["
                            (number->string lo) ", " (number->string hi) "]")))

(define (jb-int who v lo hi)
  (if (and (integer? v) (exact? v) (>= v lo) (<= v hi))
      v
      (jb-domain-error who lo hi)))

;; A float argument must already BE a float. Accepting an exact integer here
;; would make (put-f64-le! a 0 1) and (put-f64-le! a 0 1.0) look interchangeable
;; while only one of them is a documented conversion, and would let a bignum far
;; outside binary64's exact range be rounded without the caller ever asking.
(define (jb-flonum who v)
  (if (flonum? v)
      v
      (throw-jvm (quote IllegalArgumentException)
                 (string-append (jb-who who) ": expected a float"))))

;; --- host representation gate ------------------------------------------------
;; The raw-bit and float operations claim IEEE-754 binary64 flonums and binary32
;; single conversion. R6RS fixes the meaning of the ieee accessors, but not that
;; the host's own float type is the same binary64 those accessors read back. This
;; is checked once at load and re-asserted per call as a single boolean test, so
;; a host that cannot honour the claim fails closed with the documented
;; unsupported-representation error instead of returning plausible wrong bits.
;;
;; --- the staging scratch ---
;; The raw-bit conversions stage through one reusable eight-byte bytevector so a
;; steady-state conversion allocates nothing beyond its result. That buffer is
;; MUTABLE and must never be shared, so it lives in a non-inheriting thread slot
;; (rt.ss) rather than a plain thread parameter: fork-thread copies the parent's
;; current parameter value, so a parent that had converted a single float before
;; spawning futures would hand every worker the SAME eight bytes, and concurrent
;; conversions would read each other's patterns. The slot's owner check replaces
;; an inherited entry before it can be read; same-thread reuse is unchanged.
(define jb-ieee-scratch (jolt-make-thread-slot (lambda () (make-bytevector 8 0))))
(define (jb-scratch) (jolt-thread-slot-ref jb-ieee-scratch))

(define (jb-probe-ieee)
  (let ((b (make-bytevector 8 0)))
    (bytevector-ieee-double-set! b 0 1.0 (endianness big))
    (and (= (bytevector-u64-ref b 0 (endianness big)) #x3FF0000000000000)
         (begin
           (bytevector-u64-set! b 0 #xC05EDD2F1A9FBE77 (endianness big))
           (= (begin (bytevector-ieee-double-set!
                      b 0 (bytevector-ieee-double-ref b 0 (endianness big))
                      (endianness big))
                     (bytevector-u64-ref b 0 (endianness big)))
              #xC05EDD2F1A9FBE77))
         (begin
           (bytevector-ieee-single-set! b 0 1.0 (endianness big))
           (= (bytevector-u32-ref b 0 (endianness big)) #x3F800000)))))

(define jb-ieee-ok (jb-probe-ieee))

(define (jb-require-ieee who)
  (unless jb-ieee-ok
    (throw-jvm (quote UnsupportedOperationException)
               (string-append (jb-who who)
                              ": host float representation is not IEEE-754 binary64"))))

;; --- accessor generators -----------------------------------------------------
;; Hygienic templates rather than higher-order factories: each generated
;; accessor calls its bytevector primitive directly, with no closure hop in the
;; scalar path and no per-call allocation.

(define-syntax define-jb-get
  (syntax-rules ()
    ((_ name who size (bv i) body)
     (define (name arr off)
       (let* ((bv (jb-backing who arr))
              (i (jb-index who off)))
         (jb-check-range who bv i size)
         body)))))

;; The value check runs before the range check purely so that the error a caller
;; sees names the argument they got wrong most specifically; both precede the
;; single mutating call, which is what failure atomicity actually depends on.
;; `val` is a pattern variable, not a template binding, so the use site's check
;; expression names the same identifier the generated argument binds.
(define-syntax define-jb-put
  (syntax-rules ()
    ((_ name who size (bv i v val) check body)
     (define (name arr off val)
       (let* ((bv (jb-backing who arr))
              (i (jb-index who off))
              (v check))
         (jb-check-range who bv i size)
         body
         arr)))))

(define jb-u8-max 255)
(define jb-i8-min -128)
(define jb-i8-max 127)
(define jb-u16-max 65535)
(define jb-i16-min -32768)
(define jb-i16-max 32767)
(define jb-u32-max 4294967295)
(define jb-i32-min -2147483648)
(define jb-i32-max 2147483647)
(define jb-u64-max 18446744073709551615)
(define jb-i64-min -9223372036854775808)
(define jb-i64-max 9223372036854775807)

;; --- 8-bit -------------------------------------------------------------------

(define-jb-get jb-get-u8 "get-u8" 1 (bv i) (bytevector-u8-ref bv i))
(define-jb-get jb-get-i8 "get-i8" 1 (bv i) (bytevector-s8-ref bv i))

(define-jb-put jb-put-u8! "put-u8!" 1 (bv i v val)
  (jb-int "put-u8!" val 0 jb-u8-max) (bytevector-u8-set! bv i v))
(define-jb-put jb-put-i8! "put-i8!" 1 (bv i v val)
  (jb-int "put-i8!" val jb-i8-min jb-i8-max) (bytevector-s8-set! bv i v))

;; --- 16-bit ------------------------------------------------------------------

(define-jb-get jb-get-u16-le "get-u16-le" 2 (bv i) (bytevector-u16-ref bv i (endianness little)))
(define-jb-get jb-get-u16-be "get-u16-be" 2 (bv i) (bytevector-u16-ref bv i (endianness big)))
(define-jb-get jb-get-i16-le "get-i16-le" 2 (bv i) (bytevector-s16-ref bv i (endianness little)))
(define-jb-get jb-get-i16-be "get-i16-be" 2 (bv i) (bytevector-s16-ref bv i (endianness big)))

(define-jb-put jb-put-u16-le! "put-u16-le!" 2 (bv i v val)
  (jb-int "put-u16-le!" val 0 jb-u16-max) (bytevector-u16-set! bv i v (endianness little)))
(define-jb-put jb-put-u16-be! "put-u16-be!" 2 (bv i v val)
  (jb-int "put-u16-be!" val 0 jb-u16-max) (bytevector-u16-set! bv i v (endianness big)))
(define-jb-put jb-put-i16-le! "put-i16-le!" 2 (bv i v val)
  (jb-int "put-i16-le!" val jb-i16-min jb-i16-max) (bytevector-s16-set! bv i v (endianness little)))
(define-jb-put jb-put-i16-be! "put-i16-be!" 2 (bv i v val)
  (jb-int "put-i16-be!" val jb-i16-min jb-i16-max) (bytevector-s16-set! bv i v (endianness big)))

;; --- 32-bit ------------------------------------------------------------------

(define-jb-get jb-get-u32-le "get-u32-le" 4 (bv i) (bytevector-u32-ref bv i (endianness little)))
(define-jb-get jb-get-u32-be "get-u32-be" 4 (bv i) (bytevector-u32-ref bv i (endianness big)))
(define-jb-get jb-get-i32-le "get-i32-le" 4 (bv i) (bytevector-s32-ref bv i (endianness little)))
(define-jb-get jb-get-i32-be "get-i32-be" 4 (bv i) (bytevector-s32-ref bv i (endianness big)))

(define-jb-put jb-put-u32-le! "put-u32-le!" 4 (bv i v val)
  (jb-int "put-u32-le!" val 0 jb-u32-max) (bytevector-u32-set! bv i v (endianness little)))
(define-jb-put jb-put-u32-be! "put-u32-be!" 4 (bv i v val)
  (jb-int "put-u32-be!" val 0 jb-u32-max) (bytevector-u32-set! bv i v (endianness big)))
(define-jb-put jb-put-i32-le! "put-i32-le!" 4 (bv i v val)
  (jb-int "put-i32-le!" val jb-i32-min jb-i32-max) (bytevector-s32-set! bv i v (endianness little)))
(define-jb-put jb-put-i32-be! "put-i32-be!" 4 (bv i v val)
  (jb-int "put-i32-be!" val jb-i32-min jb-i32-max) (bytevector-s32-set! bv i v (endianness big)))

;; --- 64-bit ------------------------------------------------------------------
;; Chez fixnums are 61-bit, so a u64/i64 result outside that range is a bignum.
;; That allocation is the RESULT, not a staging buffer: no temporary array or
;; sequence is built either way. A codec that wants to stay in fixnum territory
;; reads the halves as u32.

(define-jb-get jb-get-u64-le "get-u64-le" 8 (bv i) (bytevector-u64-ref bv i (endianness little)))
(define-jb-get jb-get-u64-be "get-u64-be" 8 (bv i) (bytevector-u64-ref bv i (endianness big)))
(define-jb-get jb-get-i64-le "get-i64-le" 8 (bv i) (bytevector-s64-ref bv i (endianness little)))
(define-jb-get jb-get-i64-be "get-i64-be" 8 (bv i) (bytevector-s64-ref bv i (endianness big)))

(define-jb-put jb-put-u64-le! "put-u64-le!" 8 (bv i v val)
  (jb-int "put-u64-le!" val 0 jb-u64-max) (bytevector-u64-set! bv i v (endianness little)))
(define-jb-put jb-put-u64-be! "put-u64-be!" 8 (bv i v val)
  (jb-int "put-u64-be!" val 0 jb-u64-max) (bytevector-u64-set! bv i v (endianness big)))
(define-jb-put jb-put-i64-le! "put-i64-le!" 8 (bv i v val)
  (jb-int "put-i64-le!" val jb-i64-min jb-i64-max) (bytevector-s64-set! bv i v (endianness little)))
(define-jb-put jb-put-i64-be! "put-i64-be!" 8 (bv i v val)
  (jb-int "put-i64-be!" val jb-i64-min jb-i64-max) (bytevector-s64-set! bv i v (endianness big)))

;; --- IEEE-754 floats ---------------------------------------------------------
;; These exist alongside the raw-bit conversions because composing
;; (put-u64-be! a i (f64-bits x)) through a Jolt value materializes a bignum for
;; every negative or large-exponent double; the direct accessor writes the same
;; eight bytes with no intermediate number at all.
;;
;; The f64 accessors are exact: a Jolt float IS binary64, so the eight bytes on
;; the wire and the value in hand are the same thing.
;;
;; The f32 accessors are NUMERIC, and they convert. Jolt has no binary32 value
;; type, so get-f32-le/be reads four wire bytes as binary32 and WIDENS the result
;; to binary64 — exactly, since every binary32 is a binary64 — while put-f32-le/be!
;; takes a binary64 and NARROWS it to the four bytes it writes, rounding to
;; nearest-even and overflowing to an infinity. A value that is not exactly
;; representable in binary32 therefore does not survive a put/get round trip, and
;; a signalling NaN read through get-f32 arrives already quieted. That is the
;; documented contract of these four functions, not a defect in them: a caller
;; that needs the wire's four bytes preserved verbatim reads and writes them with
;; the u32 accessors, which never involve a float at all.

(define-jb-get jb-get-f32-le "get-f32-le" 4 (bv i)
  (begin (jb-require-ieee "get-f32-le") (bytevector-ieee-single-ref bv i (endianness little))))
(define-jb-get jb-get-f32-be "get-f32-be" 4 (bv i)
  (begin (jb-require-ieee "get-f32-be") (bytevector-ieee-single-ref bv i (endianness big))))
(define-jb-get jb-get-f64-le "get-f64-le" 8 (bv i)
  (begin (jb-require-ieee "get-f64-le") (bytevector-ieee-double-ref bv i (endianness little))))
(define-jb-get jb-get-f64-be "get-f64-be" 8 (bv i)
  (begin (jb-require-ieee "get-f64-be") (bytevector-ieee-double-ref bv i (endianness big))))

(define-jb-put jb-put-f32-le! "put-f32-le!" 4 (bv i v val)
  (begin (jb-require-ieee "put-f32-le!") (jb-flonum "put-f32-le!" val))
  (bytevector-ieee-single-set! bv i v (endianness little)))
(define-jb-put jb-put-f32-be! "put-f32-be!" 4 (bv i v val)
  (begin (jb-require-ieee "put-f32-be!") (jb-flonum "put-f32-be!" val))
  (bytevector-ieee-single-set! bv i v (endianness big)))
(define-jb-put jb-put-f64-le! "put-f64-le!" 8 (bv i v val)
  (begin (jb-require-ieee "put-f64-le!") (jb-flonum "put-f64-le!" val))
  (bytevector-ieee-double-set! bv i v (endianness little)))
(define-jb-put jb-put-f64-be! "put-f64-be!" 8 (bv i v val)
  (begin (jb-require-ieee "put-f64-be!") (jb-flonum "put-f64-be!" val))
  (bytevector-ieee-double-set! bv i v (endianness big)))

;; --- raw bit conversion ------------------------------------------------------
;; Bit-exact in both directions, and deliberately not routed through numeric
;; equality: -0.0 and 0.0 are numerically equal but have different bit patterns,
;; and a NaN is equal to nothing at all, including itself.
;;
;; f64 is a total bijection with the u64 domain — every one of the 2^64 patterns
;; survives a round trip in either direction, NaN payloads and signalling bit
;; included, because a Chez flonum IS the binary64 pattern.
;;
;; There is deliberately NO f32 counterpart. Jolt's only float type is binary64,
;; so a bits->f32 would have to widen to produce a value at all, and re-narrowing
;; quiets a signalling NaN (0x7F800001 comes back as 0x7FC00001). Such a pair
;; would be a partial function wearing a bijection's name, which is worse for a
;; codec than not having it: the failure is silent and pattern-dependent. Code
;; that must carry an arbitrary f32 wire pattern verbatim moves it through the
;; u32 accessors and never widens it; code that wants the NUMBER reads it with
;; get-f32-le/be, whose widening is documented and intended.

(define (jb-f64-bits x)
  (jb-require-ieee "f64-bits")
  (let ((b (jb-scratch)))
    (bytevector-ieee-double-set! b 0 (jb-flonum "f64-bits" x) (endianness big))
    (bytevector-u64-ref b 0 (endianness big))))

(define (jb-bits->f64 n)
  (jb-require-ieee "bits->f64")
  (let ((b (jb-scratch)))
    (bytevector-u64-set! b 0 (jb-int "bits->f64" n 0 jb-u64-max) (endianness big))
    (bytevector-ieee-double-ref b 0 (endianness big))))

;; --- ranged copy -------------------------------------------------------------
;; memmove semantics, including src and dst being the SAME array with overlapping
;; ranges in either direction. R6RS requires bytevector-copy! to behave as if the
;; source range were copied to a temporary first; a memcpy-shaped implementation
;; would corrupt a forward-overlapping self-copy, which the overlap controls in
;; test/chez/bytes-substrate-test.ss exist to catch.
;;
;; Both ranges are admitted in full before the copy runs, so a request that is
;; valid for the source and invalid for the destination moves nothing.

(define (jb-copy! src src-off dst dst-off size)
  (let* ((sbv (jb-backing "copy!" src))
         (dbv (jb-backing "copy!" dst))
         (s (jb-index "copy!" src-off))
         (d (jb-index "copy!" dst-off))
         (n (jb-index "copy!" size)))
    (jb-check-range "copy!" sbv s n)
    (jb-check-range "copy!" dbv d n)
    (bytevector-copy! sbv s dbv d n)
    dst))

;; --- public range predicates -------------------------------------------------
;; A reader admits its next field with the same subtraction-form test the
;; accessors use, so it is exposed rather than reimplemented per codec.

(define (jb-in-range? arr off size)
  (let ((bv (jb-backing "in-range?" arr))
        (i (jb-index "in-range?" off))
        (n (jb-index "in-range?" size)))
    (let ((limit (bytevector-length bv)))
      (and (>= i 0) (<= i limit) (>= n 0) (<= n (- limit i))))))

(define (jb-check-range! arr off size)
  (let ((bv (jb-backing "check-range!" arr))
        (i (jb-index "check-range!" off))
        (n (jb-index "check-range!" size)))
    (jb-check-range "check-range!" bv i n)
    jolt-nil))

;; --- publication -------------------------------------------------------------

(def-var! "jolt.codec.binary" "in-range?" jb-in-range?)
(def-var! "jolt.codec.binary" "check-range!" jb-check-range!)

(def-var! "jolt.codec.binary" "get-u8" jb-get-u8)
(def-var! "jolt.codec.binary" "get-i8" jb-get-i8)
(def-var! "jolt.codec.binary" "put-u8!" jb-put-u8!)
(def-var! "jolt.codec.binary" "put-i8!" jb-put-i8!)

(def-var! "jolt.codec.binary" "get-u16-le" jb-get-u16-le)
(def-var! "jolt.codec.binary" "get-u16-be" jb-get-u16-be)
(def-var! "jolt.codec.binary" "get-i16-le" jb-get-i16-le)
(def-var! "jolt.codec.binary" "get-i16-be" jb-get-i16-be)
(def-var! "jolt.codec.binary" "put-u16-le!" jb-put-u16-le!)
(def-var! "jolt.codec.binary" "put-u16-be!" jb-put-u16-be!)
(def-var! "jolt.codec.binary" "put-i16-le!" jb-put-i16-le!)
(def-var! "jolt.codec.binary" "put-i16-be!" jb-put-i16-be!)

(def-var! "jolt.codec.binary" "get-u32-le" jb-get-u32-le)
(def-var! "jolt.codec.binary" "get-u32-be" jb-get-u32-be)
(def-var! "jolt.codec.binary" "get-i32-le" jb-get-i32-le)
(def-var! "jolt.codec.binary" "get-i32-be" jb-get-i32-be)
(def-var! "jolt.codec.binary" "put-u32-le!" jb-put-u32-le!)
(def-var! "jolt.codec.binary" "put-u32-be!" jb-put-u32-be!)
(def-var! "jolt.codec.binary" "put-i32-le!" jb-put-i32-le!)
(def-var! "jolt.codec.binary" "put-i32-be!" jb-put-i32-be!)

(def-var! "jolt.codec.binary" "get-u64-le" jb-get-u64-le)
(def-var! "jolt.codec.binary" "get-u64-be" jb-get-u64-be)
(def-var! "jolt.codec.binary" "get-i64-le" jb-get-i64-le)
(def-var! "jolt.codec.binary" "get-i64-be" jb-get-i64-be)
(def-var! "jolt.codec.binary" "put-u64-le!" jb-put-u64-le!)
(def-var! "jolt.codec.binary" "put-u64-be!" jb-put-u64-be!)
(def-var! "jolt.codec.binary" "put-i64-le!" jb-put-i64-le!)
(def-var! "jolt.codec.binary" "put-i64-be!" jb-put-i64-be!)

(def-var! "jolt.codec.binary" "get-f32-le" jb-get-f32-le)
(def-var! "jolt.codec.binary" "get-f32-be" jb-get-f32-be)
(def-var! "jolt.codec.binary" "get-f64-le" jb-get-f64-le)
(def-var! "jolt.codec.binary" "get-f64-be" jb-get-f64-be)
(def-var! "jolt.codec.binary" "put-f32-le!" jb-put-f32-le!)
(def-var! "jolt.codec.binary" "put-f32-be!" jb-put-f32-be!)
(def-var! "jolt.codec.binary" "put-f64-le!" jb-put-f64-le!)
(def-var! "jolt.codec.binary" "put-f64-be!" jb-put-f64-be!)

(def-var! "jolt.codec.binary" "f64-bits" jb-f64-bits)
(def-var! "jolt.codec.binary" "bits->f64" jb-bits->f64)

(def-var! "jolt.codec.binary" "copy!" jb-copy!)
