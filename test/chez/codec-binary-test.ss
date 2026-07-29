;; jolt.codec.binary regression: the checked binary scalar substrate. Run:
;;   chez --script test/chez/codec-binary-test.ss
;;
;; Covers, deterministically and with no host randomness:
;;
;;   * subtraction-form admission over the same bounded domain the substrate's
;;     bounds model is stated over (limits 0..32, sizes 0..33), so the model's
;;     UNSAT claim has an executable counterpart;
;;   * every u16 value, exhaustively, in both endiannesses and both signednesses;
;;   * boundary bands plus a deterministic LCG corpus for the wider widths;
;;   * explicit byte layouts, so an endianness swap cannot hide behind a
;;     round trip that would agree with itself either way;
;;   * exact-tail acceptance and one-past-the-tail rejection at every width;
;;   * a no-partial-write sentinel for every rejected write and copy;
;;   * memmove overlap controls that a memcpy implementation fails;
;;   * IEEE-754 f64 raw-bit fidelity compared as BITS, never as numbers,
;;     including signed zero, infinities, subnormals and NaN payloads;
;;   * the absence of an f32 raw-bit pair, the verbatim u32 path that replaces
;;     it, and the documented widening/narrowing of the numeric f32 accessors;
;;   * the fail-closed unsupported-host-representation arm.
;;
;; Thread isolation for the reusable IEEE scratch lives in
;; test/chez/thread-slot-test.ss, which needs forked threads.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

;; A rejected operation must raise; `caught` reports the JVM class name the
;; taxonomy promises, so a test can distinguish an invalid range from an invalid
;; value rather than settling for "something threw".
(define (thrown-class e)
  (let ((v (jolt-unwrap-throw e)))
    (if (jolt-ex-info-record? v)
        (jolt-ex-info-record-class-name v)
        (format "~a" v))))
(define (caught thunk)
  (call/cc
    (lambda (k)
      (with-exception-handler
        (lambda (e) (k (thrown-class e)))
        (lambda () (thunk) 'no-throw)))))

(define (bytes-of arr) (bytevector->u8-list (jolt-array-vec arr)))
(define (fresh n) (na-byte-array n))
(define (filled n b)
  (let ((a (na-byte-array n)))
    (do ((i 0 (+ i 1))) ((= i n) a) (bytevector-u8-set! (jolt-array-vec a) i b))))
(define (snapshot arr) (bytevector-copy (jolt-array-vec arr)))
(define (unchanged? arr snap) (equal? (jolt-array-vec arr) snap))

;; ---------------------------------------------------------------------------
;; 1. subtraction-form admission
;;
;; The bounds model proves that admission `size <= limit - offset`, taken after
;; `0 <= offset <= limit`, never admits a span that leaves the array. Replay it
;; over the model's own bounded domain against the real predicate, using an
;; independently computed oracle (arbitrary-precision addition, which is exactly
;; the arithmetic the subtraction form exists to avoid needing).
;; ---------------------------------------------------------------------------

(let ((checked 0)
      ;; offsets -2..limit+1 (limit+4 of them) x sizes -1..33 (35 of them),
      ;; summed over limits 0..32.
      (expected-rows (let loop ((limit 0) (n 0))
                       (if (> limit 32) n (loop (+ limit 1) (+ n (* (+ limit 4) 35)))))))
  (do ((limit 0 (+ limit 1))) ((> limit 32))
    (let ((a (fresh limit)))
      (do ((off -2 (+ off 1))) ((> off (+ limit 1)))
        (do ((size -1 (+ size 1))) ((> size 33))
          (let ((expected (and (>= off 0) (<= off limit)
                               (>= size 0) (<= (+ off size) limit))))
            (set! checked (+ checked 1))
            (unless (eq? (and (jb-in-range? a off size) #t) (and expected #t))
              (ok (format "in-range? limit=~a off=~a size=~a" limit off size) #f)))))))
  (ok (format "subtraction-form admission agrees with the additive oracle (~a rows)" checked)
      (= checked expected-rows)))

;; Overflow-shaped input: an offset and a size whose SUM would overflow a 64-bit
;; machine integer are rejected by the offset guard, before any arithmetic on
;; the size can matter.
(let ((a (fresh 8)))
  (ok "overflow-shaped offset rejected"
      (not (jb-in-range? a 9223372036854775807 9223372036854775807)))
  (ok "overflow-shaped offset is a range error"
      (string=? "java.lang.IndexOutOfBoundsException"
                (caught (lambda () (jb-get-u8 a 9223372036854775807)))))
  (ok "negative size rejected" (not (jb-in-range? a 0 -1)))
  (ok "negative offset rejected" (not (jb-in-range? a -1 0)))
  (ok "empty span at the limit is admitted" (jb-in-range? a 8 0))
  (ok "empty span past the limit is rejected" (not (jb-in-range? a 9 0)))
  (ok "check-range! returns nil on success" (eq? jolt-nil (jb-check-range! a 0 8)))
  (ok "check-range! throws a range error past the tail"
      (string=? "java.lang.IndexOutOfBoundsException"
                (caught (lambda () (jb-check-range! a 0 9))))))

;; ---------------------------------------------------------------------------
;; 2. exhaustive u16 / i16
;;
;; All 65536 values, both endiannesses, checked against an explicitly computed
;; byte layout and an explicitly computed two's-complement reading — not against
;; the accessor's own inverse.
;; ---------------------------------------------------------------------------

(let ((a (fresh 2))
      (bad 0))
  (do ((v 0 (+ v 1))) ((> v 65535))
    (let ((hi (quotient v 256)) (lo (remainder v 256))
          (signed (if (>= v 32768) (- v 65536) v)))
      (jb-put-u16-le! a 0 v)
      (unless (and (equal? (bytes-of a) (list lo hi))
                   (= (jb-get-u16-le a 0) v)
                   (= (jb-get-i16-le a 0) signed))
        (set! bad (+ bad 1)))
      (jb-put-u16-be! a 0 v)
      (unless (and (equal? (bytes-of a) (list hi lo))
                   (= (jb-get-u16-be a 0) v)
                   (= (jb-get-i16-be a 0) signed))
        (set! bad (+ bad 1)))
      (jb-put-i16-le! a 0 signed)
      (unless (and (equal? (bytes-of a) (list lo hi))
                   (= (jb-get-i16-le a 0) signed)
                   (= (jb-get-u16-le a 0) v))
        (set! bad (+ bad 1)))
      (jb-put-i16-be! a 0 signed)
      (unless (and (equal? (bytes-of a) (list hi lo))
                   (= (jb-get-i16-be a 0) signed)
                   (= (jb-get-u16-be a 0) v))
        (set! bad (+ bad 1)))))
  (ok "exhaustive u16/i16 layout and reading over all 65536 values" (= bad 0)))

;; ---------------------------------------------------------------------------
;; 3. wider widths: boundary bands + deterministic corpus
;; ---------------------------------------------------------------------------

;; Explicit byte layout at each width, so endianness is pinned by construction.
(define (le-bytes v n)
  (let loop ((i 0) (v v) (acc '()))
    (if (= i n) (reverse acc) (loop (+ i 1) (quotient v 256) (cons (remainder v 256) acc)))))
(define (be-bytes v n) (reverse (le-bytes v n)))

(define (signed-of v bits)
  (let ((half (expt 2 (- bits 1))))
    (if (>= v half) (- v (expt 2 bits)) v)))

;; Boundary bands: every power-of-two edge in the width, +/- 2, plus the domain
;; ends. These are the values an off-by-one in a shift or a sign extension
;; actually breaks on.
(define (bands bits)
  (let ((maxv (- (expt 2 bits) 1)))
    (let loop ((k 0) (acc (list 0 1 2 maxv (- maxv 1) (- maxv 2))))
      (if (> k bits) (filter (lambda (v) (and (>= v 0) (<= v maxv))) acc)
          (let ((e (expt 2 k)))
            (loop (+ k 1) (append (list (- e 2) (- e 1) e (+ e 1) (+ e 2)) acc)))))))

;; A deterministic 64-bit LCG (Knuth's MMIX constants). Same corpus on every run
;; and every host; no host randomness enters the gate.
(define lcg-state 1)
(define (lcg-next!)
  (set! lcg-state (bitwise-and (+ (* lcg-state 6364136223846793005) 1442695040888963407)
                               #xFFFFFFFFFFFFFFFF))
  lcg-state)
(define (corpus bits n)
  (set! lcg-state 1)
  (let ((mask (- (expt 2 bits) 1)))
    (let loop ((i 0) (acc '()))
      (if (= i n) acc (loop (+ i 1) (cons (bitwise-and (lcg-next!) mask) acc))))))

(define (check-width! label bits ugetle ugetbe igetle igetbe uputle uputbe iputle iputbe)
  (let* ((n (quotient bits 8))
         (a (fresh n))
         (vals (append (bands bits) (corpus bits 512)))
         (bad 0))
    (for-each
      (lambda (v)
        (let ((s (signed-of v bits)))
          (uputle a 0 v)
          (unless (and (equal? (bytes-of a) (le-bytes v n))
                       (= (ugetle a 0) v)
                       (= (igetle a 0) s))
            (set! bad (+ bad 1)))
          (uputbe a 0 v)
          (unless (and (equal? (bytes-of a) (be-bytes v n))
                       (= (ugetbe a 0) v)
                       (= (igetbe a 0) s))
            (set! bad (+ bad 1)))
          (iputle a 0 s)
          (unless (and (equal? (bytes-of a) (le-bytes v n))
                       (= (igetle a 0) s)
                       (= (ugetle a 0) v))
            (set! bad (+ bad 1)))
          (iputbe a 0 s)
          (unless (and (equal? (bytes-of a) (be-bytes v n))
                       (= (igetbe a 0) s)
                       (= (ugetbe a 0) v))
            (set! bad (+ bad 1)))))
      vals)
    (ok (format "~a: ~a boundary+corpus values, layout and signedness" label (length vals))
        (= bad 0))))

(check-width! "u32/i32" 32
              jb-get-u32-le jb-get-u32-be jb-get-i32-le jb-get-i32-be
              jb-put-u32-le! jb-put-u32-be! jb-put-i32-le! jb-put-i32-be!)
(check-width! "u64/i64" 64
              jb-get-u64-le jb-get-u64-be jb-get-i64-le jb-get-i64-be
              jb-put-u64-le! jb-put-u64-be! jb-put-i64-le! jb-put-i64-be!)

;; u8 / i8 exhaustively.
(let ((a (fresh 1)) (bad 0))
  (do ((v 0 (+ v 1))) ((> v 255))
    (jb-put-u8! a 0 v)
    (unless (and (= (jb-get-u8 a 0) v)
                 (= (jb-get-i8 a 0) (signed-of v 8)))
      (set! bad (+ bad 1)))
    (jb-put-i8! a 0 (signed-of v 8))
    (unless (= (jb-get-u8 a 0) v) (set! bad (+ bad 1))))
  (ok "exhaustive u8/i8 over all 256 values" (= bad 0)))

;; ---------------------------------------------------------------------------
;; 4. exact tail and one past it, at every width
;; ---------------------------------------------------------------------------

(define widths
  (list (list "u8" 1 (lambda (a i) (jb-get-u8 a i)) (lambda (a i) (jb-put-u8! a i 1)))
        (list "u16-le" 2 (lambda (a i) (jb-get-u16-le a i)) (lambda (a i) (jb-put-u16-le! a i 1)))
        (list "u16-be" 2 (lambda (a i) (jb-get-u16-be a i)) (lambda (a i) (jb-put-u16-be! a i 1)))
        (list "u32-le" 4 (lambda (a i) (jb-get-u32-le a i)) (lambda (a i) (jb-put-u32-le! a i 1)))
        (list "u32-be" 4 (lambda (a i) (jb-get-u32-be a i)) (lambda (a i) (jb-put-u32-be! a i 1)))
        (list "u64-le" 8 (lambda (a i) (jb-get-u64-le a i)) (lambda (a i) (jb-put-u64-le! a i 1)))
        (list "u64-be" 8 (lambda (a i) (jb-get-u64-be a i)) (lambda (a i) (jb-put-u64-be! a i 1)))
        (list "i64-le" 8 (lambda (a i) (jb-get-i64-le a i)) (lambda (a i) (jb-put-i64-le! a i 1)))
        (list "f32-le" 4 (lambda (a i) (jb-get-f32-le a i)) (lambda (a i) (jb-put-f32-le! a i 1.0)))
        (list "f64-be" 8 (lambda (a i) (jb-get-f64-be a i)) (lambda (a i) (jb-put-f64-be! a i 1.0)))))

(for-each
  (lambda (w)
    (let* ((label (car w)) (size (cadr w)) (get (caddr w)) (put (cadddr w))
           (cap (+ size 3))
           (a (filled cap #xA5))
           (tail (- cap size)))
      ;; the exact tail is inside the array
      (ok (format "~a: exact-tail read admitted" label)
          (not (eq? 'threw (caught (lambda () (get a tail))))))
      (ok (format "~a: exact-tail write admitted" label)
          (not (string? (caught (lambda () (put a tail))))))
      ;; one byte past it is not
      (ok (format "~a: one past the tail is a range error (read)" label)
          (string=? "java.lang.IndexOutOfBoundsException"
                    (caught (lambda () (get a (+ tail 1))))))
      (ok (format "~a: one past the tail is a range error (write)" label)
          (string=? "java.lang.IndexOutOfBoundsException"
                    (caught (lambda () (put a (+ tail 1))))))
      ;; and the rejected write moved nothing
      (let* ((b (filled cap #xA5)) (snap (snapshot b)))
        (caught (lambda () (put b (+ tail 1))))
        (ok (format "~a: rejected past-tail write leaves the array untouched" label)
            (unchanged? b snap)))))
  widths)

;; ---------------------------------------------------------------------------
;; 5. invalid values, and the no-partial-write sentinel for each
;; ---------------------------------------------------------------------------

(define (rejects-value! label put v)
  (let* ((a (filled 16 #x5A)) (snap (snapshot a)))
    (ok (format "~a: ~s rejected as an invalid value" label v)
        (string=? "java.lang.IllegalArgumentException" (caught (lambda () (put a 0 v)))))
    (ok (format "~a: ~s left the destination untouched" label v)
        (unchanged? a snap))))

(rejects-value! "put-u8!" jb-put-u8! 256)
(rejects-value! "put-u8!" jb-put-u8! -1)
(rejects-value! "put-i8!" jb-put-i8! 128)
(rejects-value! "put-i8!" jb-put-i8! -129)
(rejects-value! "put-u16-le!" jb-put-u16-le! 65536)
(rejects-value! "put-u16-be!" jb-put-u16-be! -1)
(rejects-value! "put-i16-le!" jb-put-i16-le! 32768)
(rejects-value! "put-i16-be!" jb-put-i16-be! -32769)
(rejects-value! "put-u32-le!" jb-put-u32-le! 4294967296)
(rejects-value! "put-u32-be!" jb-put-u32-be! -1)
(rejects-value! "put-i32-le!" jb-put-i32-le! 2147483648)
(rejects-value! "put-i32-be!" jb-put-i32-be! -2147483649)
(rejects-value! "put-u64-le!" jb-put-u64-le! 18446744073709551616)
(rejects-value! "put-u64-be!" jb-put-u64-be! -1)
(rejects-value! "put-i64-le!" jb-put-i64-le! 9223372036854775808)
(rejects-value! "put-i64-be!" jb-put-i64-be! -9223372036854775809)
;; a float is not an integer of any width
(rejects-value! "put-u16-le!" jb-put-u16-le! 1.0)
(rejects-value! "put-u32-le!" jb-put-u32-le! 1.5)
;; and an exact integer is not a float: Chez's own ieee setter would accept this
;; and silently store 1.0
(rejects-value! "put-f64-le!" jb-put-f64-le! 1)
(rejects-value! "put-f32-be!" jb-put-f32-be! 0)
;; a rational is neither
(rejects-value! "put-u32-le!" jb-put-u32-le! 3/2)

;; Non-integer offsets are invalid values, not range errors — a truncating
;; accessor would have written at index 1.
(let* ((a (filled 16 #x5A)) (snap (snapshot a)))
  (ok "float offset rejected as an invalid value"
      (string=? "java.lang.IllegalArgumentException"
                (caught (lambda () (jb-put-u16-le! a 1.9 7)))))
  (ok "float offset wrote nothing" (unchanged? a snap))
  (ok "float offset rejected on read"
      (string=? "java.lang.IllegalArgumentException"
                (caught (lambda () (jb-get-u16-le a 1.9))))))

;; A non-byte-array destination is an invalid value and never a range error.
(ok "object array rejected"
    (string=? "java.lang.IllegalArgumentException"
              (caught (lambda () (jb-get-u8 (na-make-array 4) 0)))))
(ok "nil rejected"
    (string=? "java.lang.IllegalArgumentException"
              (caught (lambda () (jb-get-u8 jolt-nil 0)))))
(ok "bare bytevector rejected"
    (string=? "java.lang.IllegalArgumentException"
              (caught (lambda () (jb-get-u8 (make-bytevector 4 0) 0)))))

;; ---------------------------------------------------------------------------
;; 6. IEEE-754 raw bits, compared as bits
;; ---------------------------------------------------------------------------

(define f64-patterns
  (append
    (list 0                                  ; +0.0
          #x8000000000000000                 ; -0.0
          #x3FF0000000000000                 ; 1.0
          #xBFF0000000000000                 ; -1.0
          #x7FF0000000000000                 ; +inf
          #xFFF0000000000000                 ; -inf
          #x7FF8000000000000                 ; canonical quiet NaN
          #x7FF8000ABCDEF123                 ; quiet NaN with a payload
          #xFFF8000ABCDEF123                 ; negative quiet NaN with a payload
          #x7FF0000000000001                 ; signalling NaN
          #x0000000000000001                 ; smallest subnormal
          #x000FFFFFFFFFFFFF                 ; largest subnormal
          #x0010000000000000                 ; smallest normal
          #x7FEFFFFFFFFFFFFF)                ; largest finite
    (corpus 64 256)))

(let ((bad 0))
  (for-each
    (lambda (bits)
      ;; bits -> float -> bits is the identity on every one of these patterns
      (unless (= (jb-f64-bits (jb-bits->f64 bits)) bits) (set! bad (+ bad 1))))
    f64-patterns)
  (ok (format "f64 raw bits round-trip exactly over ~a patterns" (length f64-patterns))
      (= bad 0)))

;; The same patterns through the array accessors, in both endiannesses, compared
;; byte-for-byte against the raw-bit path.
(let ((a (fresh 8)) (b (fresh 8)) (bad 0))
  (for-each
    (lambda (bits)
      (let ((x (jb-bits->f64 bits)))
        (jb-put-f64-be! a 0 x)
        (jb-put-u64-be! b 0 bits)
        (unless (equal? (bytes-of a) (bytes-of b)) (set! bad (+ bad 1)))
        (unless (= (jb-f64-bits (jb-get-f64-be a 0)) bits) (set! bad (+ bad 1)))
        (jb-put-f64-le! a 0 x)
        (jb-put-u64-le! b 0 bits)
        (unless (equal? (bytes-of a) (bytes-of b)) (set! bad (+ bad 1)))
        (unless (= (jb-f64-bits (jb-get-f64-le a 0)) bits) (set! bad (+ bad 1)))))
    f64-patterns)
  (ok "f64 array accessors agree with the raw-bit path, both endiannesses" (= bad 0)))

;; Signed zero survives, and is not conflated with +0.0 — a check by numeric
;; equality would pass here no matter what the implementation did.
(ok "-0.0 keeps its sign bit" (= (jb-f64-bits (jb-bits->f64 #x8000000000000000))
                                 #x8000000000000000))
(ok "-0.0 and 0.0 are numerically equal but bit-distinct"
    (and (= (jb-bits->f64 0) (jb-bits->f64 #x8000000000000000))
         (not (= (jb-f64-bits (jb-bits->f64 0))
                 (jb-f64-bits (jb-bits->f64 #x8000000000000000))))))
;; A NaN is equal to nothing, so only the bits can carry the evidence.
(ok "NaN payload survives and is not comparable numerically"
    (let ((x (jb-bits->f64 #x7FF8000ABCDEF123)))
      (and (not (= x x)) (= (jb-f64-bits x) #x7FF8000ABCDEF123))))

(define f32-patterns
  (append
    (list 0 #x80000000 #x3F800000 #xBF800000 #x7F800000 #xFF800000
          #x7FC00000 #x7FC00ABC #xFFC00ABC
          #x00000001 #x007FFFFF #x00800000 #x7F7FFFFF)
    (corpus 32 256)))

(define (f32-signalling? bits)
  (and (= (bitwise-and bits #x7F800000) #x7F800000)
       (not (= (bitwise-and bits #x007FFFFF) 0))      ; is a NaN
       (= (bitwise-and bits #x00400000) 0)))          ; quiet bit clear

;; There is no f32 raw-bit pair, and its absence is the contract. A widening
;; bits->f32 could not be a bijection — re-narrowing quiets a signalling NaN —
;; so the substrate declines to offer one under a total function's name. The
;; check below is that the names are genuinely gone, not merely undocumented;
;; the published-surface check in section 9 backs it from the other direction.
(ok "no f32 raw-bit pair is defined at all"
    (and (not (top-level-bound? 'jb-f32-bits))
         (not (top-level-bound? 'jb-bits->f32))))

;; The verbatim path for an arbitrary f32 wire pattern is u32, which never
;; involves a float. Every pattern the removed pair could not preserve — every
;; signalling NaN included — travels through untouched, in both endiannesses.
(let ((a (fresh 4)) (bad 0) (sig 0))
  (for-each
    (lambda (bits)
      (when (f32-signalling? bits) (set! sig (+ sig 1)))
      (jb-put-u32-be! a 0 bits)
      (unless (= (jb-get-u32-be a 0) bits) (set! bad (+ bad 1)))
      (jb-put-u32-le! a 0 bits)
      (unless (= (jb-get-u32-le a 0) bits) (set! bad (+ bad 1))))
    f32-patterns)
  (ok (format "all ~a f32 wire patterns survive u32 verbatim (~a signalling)"
              (length f32-patterns) sig)
      (= bad 0))
  (ok "the corpus actually exercised the signalling case" (> sig 0)))

;; A signalling NaN specifically: verbatim through u32, and quieted through the
;; numeric accessor. Both halves stated together, because the pair of them IS
;; the reason the raw f32 conversion was removed.
(let ((a (fresh 4)))
  (jb-put-u32-be! a 0 #x7F800001)
  (ok "a signalling f32 NaN is preserved exactly by u32"
      (= (jb-get-u32-be a 0) #x7F800001))
  (let ((x (jb-get-f32-be a 0)))                ; widens, quieting it
    (jb-put-f32-be! a 0 x)                      ; narrows again
    (ok "the same pattern read as a NUMBER comes back quieted"
        (= (jb-get-u32-be a 0) #x7FC00001))))

;; The numeric accessors convert, and the conversion is exactly binary32<->
;; binary64: a value that IS representable in binary32 survives, one that is not
;; comes back as its nearest binary32, and the round trip is idempotent from
;; there. This is the documented contract, so it is asserted rather than avoided.
(let ((a (fresh 4)))
  (jb-put-f32-le! a 0 1.5)                      ; exactly representable
  (ok "an exactly-representable value survives the f32 round trip"
      (= (jb-get-f32-le a 0) 1.5))
  (jb-put-f32-le! a 0 0.1)                      ; not representable in binary32
  (let ((narrowed (jb-get-f32-le a 0)))
    (ok "0.1 narrows to the binary32 neighbour, not to 0.1"
        (and (not (= narrowed 0.1))
             (= narrowed 0.10000000149011612)))
    (jb-put-f32-le! a 0 narrowed)
    (ok "narrowing is idempotent once the value is a binary32"
        (= (jb-get-f32-le a 0) narrowed))))

;; Widening is exact in the other direction: every binary32 IS a binary64, so a
;; wire pattern read as f32 and written straight back reproduces its own bytes
;; whenever the pattern was not a signalling NaN.
(let ((a (fresh 4)) (b (fresh 4)) (bad 0))
  (for-each
    (lambda (bits)
      (unless (f32-signalling? bits)
        (jb-put-u32-be! a 0 bits)
        (jb-put-f32-be! b 0 (jb-get-f32-be a 0))
        (unless (equal? (bytes-of a) (bytes-of b)) (set! bad (+ bad 1)))
        (jb-put-u32-le! a 0 bits)
        (jb-put-f32-le! b 0 (jb-get-f32-le a 0))
        (unless (equal? (bytes-of a) (bytes-of b)) (set! bad (+ bad 1)))))
    f32-patterns)
  (ok "non-signalling f32 patterns survive a get/put through the numeric path"
      (= bad 0)))

;; Raw-bit inputs are domain-checked like every other value.
(ok "bits->f64 rejects a value above the u64 domain"
    (string=? "java.lang.IllegalArgumentException"
              (caught (lambda () (jb-bits->f64 18446744073709551616)))))
(ok "bits->f64 rejects a negative pattern"
    (string=? "java.lang.IllegalArgumentException"
              (caught (lambda () (jb-bits->f64 -1)))))
(ok "f64-bits rejects an exact integer"
    (string=? "java.lang.IllegalArgumentException"
              (caught (lambda () (jb-f64-bits 1)))))

;; ---------------------------------------------------------------------------
;; 7. unsupported host representation, fail-closed
;;
;; The raw-bit and float operations gate on a load-time probe of the host float
;; representation. Force the gate shut and confirm the third arm of the taxonomy
;; fires and that nothing is written on the way out.
;; ---------------------------------------------------------------------------

(let ((saved jb-ieee-ok)
      (a (filled 8 #x33)))
  (let ((snap (snapshot a)))
    (set! jb-ieee-ok #f)
    (ok "f64-bits fails closed on a non-IEEE host"
        (string=? "java.lang.UnsupportedOperationException"
                  (caught (lambda () (jb-f64-bits 1.0)))))
    (ok "bits->f64 fails closed on a non-IEEE host"
        (string=? "java.lang.UnsupportedOperationException"
                  (caught (lambda () (jb-bits->f64 0)))))
    (ok "get-f64-le fails closed on a non-IEEE host"
        (string=? "java.lang.UnsupportedOperationException"
                  (caught (lambda () (jb-get-f64-le a 0)))))
    (ok "put-f64-le! fails closed on a non-IEEE host"
        (string=? "java.lang.UnsupportedOperationException"
                  (caught (lambda () (jb-put-f64-le! a 0 1.0)))))
    (ok "a fail-closed float write mutates nothing" (unchanged? a snap))
    (set! jb-ieee-ok saved))
  (ok "the gate is open on this host" jb-ieee-ok)
  ;; and the integer path never depended on it
  (ok "integer accessors are unaffected by the float gate"
      (begin (jb-put-u32-be! a 0 7) (= (jb-get-u32-be a 0) 7))))

;; ---------------------------------------------------------------------------
;; 8. overlap-safe ranged copy
;;
;; The forward-overlap case is the control: a memcpy-shaped implementation that
;; copies ascending would read bytes it had already overwritten and produce a
;; repeating pattern instead of a shift.
;; ---------------------------------------------------------------------------

(define (arr-of lst)
  (let ((a (fresh (length lst))))
    (let loop ((i 0) (l lst))
      (if (null? l) a
          (begin (bytevector-u8-set! (jolt-array-vec a) i (car l)) (loop (+ i 1) (cdr l)))))))

(let ((a (arr-of '(1 2 3 4 5 6 7 8))))
  (jb-copy! a 0 a 2 4)
  (ok "self-copy forward-overlapping is memmove, not memcpy"
      (equal? (bytes-of a) '(1 2 1 2 3 4 7 8))))

(let ((a (arr-of '(1 2 3 4 5 6 7 8))))
  (jb-copy! a 2 a 0 4)
  (ok "self-copy backward-overlapping is memmove"
      (equal? (bytes-of a) '(3 4 5 6 5 6 7 8))))

;; One-byte shifts in each direction are the tightest overlap a memcpy would
;; still get wrong.
(let ((a (arr-of '(1 2 3 4 5 6 7 8))))
  (jb-copy! a 0 a 1 7)
  (ok "self-copy shifted forward by one byte"
      (equal? (bytes-of a) '(1 1 2 3 4 5 6 7))))
(let ((a (arr-of '(1 2 3 4 5 6 7 8))))
  (jb-copy! a 1 a 0 7)
  (ok "self-copy shifted backward by one byte"
      (equal? (bytes-of a) '(2 3 4 5 6 7 8 8))))

(let ((a (arr-of '(1 2 3 4 5 6 7 8))))
  (jb-copy! a 3 a 3 5)
  (ok "self-copy onto itself is the identity"
      (equal? (bytes-of a) '(1 2 3 4 5 6 7 8))))

;; Exhaustive small self-copy: every (src, dst, size) triple in an 8-byte array,
;; against an independently computed expectation built from a snapshot.
(let ((bad 0) (checked 0))
  (do ((s 0 (+ s 1))) ((> s 8))
    (do ((d 0 (+ d 1))) ((> d 8))
      (do ((n 0 (+ n 1))) ((> n (min (- 8 s) (- 8 d))))
        (let* ((a (arr-of '(10 20 30 40 50 60 70 80)))
               (before (bytes-of a))
               (expected (let loop ((i 0) (acc '()))
                           (if (= i 8) (reverse acc)
                               (loop (+ i 1)
                                     (cons (if (and (>= i d) (< i (+ d n)))
                                               (list-ref before (+ s (- i d)))
                                               (list-ref before i))
                                           acc))))))
          (jb-copy! a s a d n)
          (set! checked (+ checked 1))
          (unless (equal? (bytes-of a) expected) (set! bad (+ bad 1)))))))
  (ok (format "exhaustive 8-byte self-copy geometry (~a triples)" checked) (= bad 0)))

;; Distinct arrays, exact-tail copy.
(let ((src (arr-of '(9 8 7 6))) (dst (filled 6 #x00)))
  (jb-copy! src 1 dst 2 3)
  (ok "ranged copy between arrays lands exactly at the tail"
      (equal? (bytes-of dst) '(0 0 8 7 6 0))))

(let ((src (arr-of '(9 8 7 6))) (dst (fresh 4)))
  (ok "copy! returns the destination" (eq? dst (jb-copy! src 0 dst 0 4))))

(let ((src (arr-of '(1 2 3 4))) (dst (fresh 4)))
  (jb-copy! src 0 dst 0 0)
  (ok "zero-length copy is admitted and writes nothing"
      (equal? (bytes-of dst) '(0 0 0 0))))

;; Rejected copies: each leaves the destination untouched, including the case
;; where the SOURCE range is perfectly valid.
(define (rejects-copy! label src s dst d n expect)
  (let ((snap (snapshot dst)))
    (ok (format "copy!: ~a rejected" label) (string=? expect (caught (lambda () (jb-copy! src s dst d n)))))
    (ok (format "copy!: ~a left the destination untouched" label) (unchanged? dst snap))))

(let ((src (arr-of '(1 2 3 4 5 6 7 8))) (dst (filled 4 #xEE)))
  (rejects-copy! "valid source, oversized destination range" src 0 dst 0 8
                 "java.lang.IndexOutOfBoundsException")
  (rejects-copy! "negative size" src 0 dst 0 -1
                 "java.lang.IndexOutOfBoundsException")
  (rejects-copy! "negative destination offset" src 0 dst -1 2
                 "java.lang.IndexOutOfBoundsException")
  (rejects-copy! "source range past the source tail" src 5 dst 0 4
                 "java.lang.IndexOutOfBoundsException")
  (rejects-copy! "overflow-shaped offsets" src 9223372036854775807 dst 0 1
                 "java.lang.IndexOutOfBoundsException")
  (rejects-copy! "float size" src 0 dst 0 2.0
                 "java.lang.IllegalArgumentException"))

(let ((dst (filled 4 #xEE)))
  (rejects-copy! "non-byte-array source" (na-make-array 4) 0 dst 0 2
                 "java.lang.IllegalArgumentException"))

;; A rejected self-copy is the sharpest sentinel: source and destination are the
;; same storage, so any partial move would be visible immediately.
(let* ((a (arr-of '(1 2 3 4 5 6 7 8))) (snap (snapshot a)))
  (caught (lambda () (jb-copy! a 0 a 4 8)))
  (ok "rejected self-copy leaves the array untouched" (unchanged? a snap)))

;; ---------------------------------------------------------------------------
;; 9. every accessor is reachable through the published jolt.codec.binary vars
;; ---------------------------------------------------------------------------

(define published
  '("in-range?" "check-range!"
    "get-u8" "get-i8" "put-u8!" "put-i8!"
    "get-u16-le" "get-u16-be" "get-i16-le" "get-i16-be"
    "put-u16-le!" "put-u16-be!" "put-i16-le!" "put-i16-be!"
    "get-u32-le" "get-u32-be" "get-i32-le" "get-i32-be"
    "put-u32-le!" "put-u32-be!" "put-i32-le!" "put-i32-be!"
    "get-u64-le" "get-u64-be" "get-i64-le" "get-i64-be"
    "put-u64-le!" "put-u64-be!" "put-i64-le!" "put-i64-be!"
    "get-f32-le" "get-f32-be" "get-f64-le" "get-f64-be"
    "put-f32-le!" "put-f32-be!" "put-f64-le!" "put-f64-be!"
    "f64-bits" "bits->f64"
    "copy!"))

(let ((missing (filter (lambda (n) (not (procedure? (var-deref "jolt.codec.binary" n)))) published)))
  (ok (format "all ~a jolt.codec.binary vars are bound" (length published))
      (null? missing))
  (unless (null? missing) (printf "  missing: ~a\n" missing)))

;; A non-interning, non-creating probe. var-deref would MATERIALIZE an empty
;; cell and hand back a jolt-var-unbound record, which is truthy — so a
;; presence check written with it would pass no matter what is defined.
(define (var-published? ns name)
  (let ((c (var-cell-lookup ns name)))
    (and c (var-cell-defined? c) #t)))

(ok "the probe itself distinguishes defined from absent"
    (and (var-published? "jolt.codec.binary" "get-u8")
         (not (var-published? "jolt.codec.binary" "no-such-var-xyzzy"))))

;; The removed names are asserted ABSENT, so a later change that quietly
;; reintroduces a widening f32 pair has to delete this check to pass.
(let ((present (filter (lambda (n) (var-published? "jolt.codec.binary" n))
                       '("f32-bits" "bits->f32"))))
  (ok "the f32 raw-bit pair is not published" (null? present))
  (unless (null? present) (printf "  unexpectedly present: ~a\n" present)))

;; jolt.bytes belongs to the external Window/Cursor package. The substrate must
;; publish NOTHING there: a single host var in that namespace is enough for the
;; loader to mark it loaded at startup and stop the library's source ever being
;; read. Probing the names this file publishes is the direct form of that check.
(let ((leaked (filter (lambda (n) (var-published? "jolt.bytes" n))
                      (append published '("f32-bits" "bits->f32" "window" "cursor")))))
  (ok "nothing is published into the external jolt.bytes namespace" (null? leaked))
  (unless (null? leaked) (printf "  leaked into jolt.bytes: ~a\n" leaked)))

;; ---------------------------------------------------------------------------

(printf "codec.binary substrate: ~a checks, ~a failures\n" total fails)
(exit (if (> fails 0) 1 0))
