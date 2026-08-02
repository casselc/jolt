;; jolt.ffi ranged byte-array transfers: read-array! and the 4-arg write-array.
;; Run:
;;   chez --script test/chez/ffi-ranged-transfer-test.ss
;; Pins the ranged forms independently of the whole-array binding gate: both copy
;; a sub-range, validate exact byte-array kind + complete range + null-for-zero
;; length BEFORE any native access or mutation, fold native u8 -> signed
;; (na-u8->byte) on read and mask signed -> #xff on write, and return the length.
;; The existing 2-arg whole-array forms stay exercised for compatibility.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/ffi.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
;; eval one form (string) in `user`, like the loader does form-by-form, so a def
;; is visible to a later form.
(define (ev s) (jolt-compile-eval s "user"))

(ev "(jolt.ffi/load-library)")

;; --- partial read/write with untouched sentinels and high bytes -------------
(ok "read-array! copies a destination sub-range and conserves prefix/suffix"
    (jolt-truthy?
      (ev "(let [p (jolt.ffi/alloc 5)]
              (jolt.ffi/write p :uint8 0 10)
              (jolt.ffi/write p :uint8 1 200)
              (jolt.ffi/write p :uint8 2 255)
              (jolt.ffi/write p :uint8 3 0)
              (jolt.ffi/write p :uint8 4 127)
              (let [dest (byte-array [-1 -1 -1 -1 -1 -1 -1 -1])
                    n (jolt.ffi/read-array! p 3 dest 2)]
                (jolt.ffi/free p)
                (and (= n 3)
                     (= -1 (nth dest 0)) (= -1 (nth dest 1))
                     (= -1 (nth dest 5)) (= -1 (nth dest 6)) (= -1 (nth dest 7))
                     (= 10 (bit-and (nth dest 2) 0xff))
                     (= 200 (bit-and (nth dest 3) 0xff))
                     (= 255 (bit-and (nth dest 4) 0xff))
                     (= -56 (nth dest 3))
                     (= -1 (nth dest 4)))))")))
(ok "write-array ranged form copies a source sub-range and conserves native sentinels"
    (jolt-truthy?
      (ev "(let [src (byte-array [0 200 255 7 -1 0])
                  p (jolt.ffi/alloc 8)]
              (doseq [i (range 8)] (jolt.ffi/write p :uint8 i 170))
              (let [n (jolt.ffi/write-array (+ p 2) src 1 4)
                    out (mapv #(bit-and (jolt.ffi/read p :uint8 %) 0xff) (range 8))]
                (jolt.ffi/free p)
                (and (= n 4)
                     (= out [170 170 200 255 7 255 170 170]))))")))
(ok "read-array! reads from the supplied interior native pointer"
    (jolt-truthy?
      (ev "(let [p (jolt.ffi/alloc 6)]
              (doseq [[i b] (map vector (range 6) [10 20 30 40 50 60])]
                (jolt.ffi/write p :uint8 i b))
              (let [dest (byte-array [-1 -1 -1 -1 -1 -1])
                    n (jolt.ffi/read-array! (+ p 2) 3 dest 1)]
                (jolt.ffi/free p)
                (and (= n 3)
                     (= [-1 30 40 50 -1 -1] (vec dest)))))")))

;; --- whole-array compatibility across both directions -----------------------
(ok "ranged read-array! equals whole-array read-array over the same bytes"
    (jolt-truthy?
      (ev "(let [p (jolt.ffi/alloc 4)]
              (jolt.ffi/write p :uint8 0 1)
              (jolt.ffi/write p :uint8 1 2)
              (jolt.ffi/write p :uint8 2 3)
              (jolt.ffi/write p :uint8 3 4)
              (let [whole (jolt.ffi/read-array p 4)
                    into (byte-array 4)
                    n (jolt.ffi/read-array! p 4 into 0)]
                (jolt.ffi/free p)
                (and (= n 4) (= (vec whole) (vec into)))))")))
(ok "whole-array write-array still roundtrips (backward-compatible form)"
    (jolt-truthy?
      (ev "(let [src (byte-array [7 200 255 0 -1])
                  p (jolt.ffi/alloc 5)
                  w (jolt.ffi/write-array p src)
                  back (jolt.ffi/read-array p 5)]
              (jolt.ffi/free p)
              (and (= w 5) (= (vec src) (vec back))))")))

;; --- exact-tail zero-length transfer with null is a no-op -------------------
(ok "zero-length exact-tail transfer with a null pointer is a no-op"
    (jolt-truthy?
      (ev "(let [dest (byte-array [5 6 7])
                  src (byte-array [5 6 7])]
              (and (= 0 (jolt.ffi/read-array! jolt.ffi/null 0 dest 3))
                   (= 0 (jolt.ffi/write-array jolt.ffi/null src 3 0))
                   (= [5 6 7] (vec dest))))")))

;; --- validation BEFORE effects: invalid calls throw AND leave state untouched
;; try/catch returns true only when dest/native is the original sentinel.
(ok "read-array! rejects negative length before mutating dest"
    (jolt-truthy?
      (ev "(let [dest (byte-array [9 9 9 9])
                  p (jolt.ffi/alloc 3)]
              (try
                (try (jolt.ffi/read-array! p -1 dest 0) false
                     (catch IndexOutOfBoundsException _ (= [9 9 9 9] (vec dest))))
                (finally (jolt.ffi/free p))))")))
(ok "read-array! rejects negative offset before mutating dest"
    (jolt-truthy?
      (ev "(let [dest (byte-array [9 9 9 9])
                  p (jolt.ffi/alloc 3)]
              (try
                (try (jolt.ffi/read-array! p 1 dest -1) false
                     (catch IndexOutOfBoundsException _ (= [9 9 9 9] (vec dest))))
                (finally (jolt.ffi/free p))))")))
(ok "read-array! rejects a non-empty transfer at the exact tail before mutating dest"
    (jolt-truthy?
      (ev "(let [dest (byte-array [9 9 9 9])
                  p (jolt.ffi/alloc 3)]
              (try
                (try (jolt.ffi/read-array! p 1 dest 4) false
                     (catch IndexOutOfBoundsException _ (= [9 9 9 9] (vec dest))))
                (finally (jolt.ffi/free p))))")))
(ok "read-array! rejects a zero-length offset beyond the tail"
    (jolt-truthy?
      (ev "(let [dest (byte-array [9 9 9 9])]
              (try
                (jolt.ffi/read-array! jolt.ffi/null 0 dest 5)
                false
                (catch IndexOutOfBoundsException _ (= [9 9 9 9] (vec dest)))))")))
(ok "read-array! rejects an overflow-shaped length before mutating dest"
    (jolt-truthy?
      (ev "(let [dest (byte-array [9 9 9 9])]
              (try
                (jolt.ffi/read-array! jolt.ffi/null 9223372036854775807 dest 1)
                false
                (catch IndexOutOfBoundsException _ (= [9 9 9 9] (vec dest)))))")))
(ok "read-array! rejects a wrong-kind destination"
    (jolt-truthy?
      (ev "(try (jolt.ffi/read-array! jolt.ffi/null 1 [0 1 2] 0) false
                (catch IllegalArgumentException _ true))")))
(ok "read-array! rejects a non-byte-array (char-array) destination"
    (jolt-truthy?
      (ev "(try (jolt.ffi/read-array! jolt.ffi/null 1 (char-array [\\a \\b]) 0) false
                (catch IllegalArgumentException _ true))")))
(ok "read-array! rejects a null pointer with non-zero length"
    (jolt-truthy?
      (ev "(try (jolt.ffi/read-array! jolt.ffi/null 1 (byte-array 2) 0) false
                (catch NullPointerException _ true))")))

(ok "write-array ranged rejects negative offset before touching native memory"
    (jolt-truthy?
      (ev "(let [src (byte-array [1 2 3 4 5])
                  p (jolt.ffi/alloc 5)]
              (doseq [i (range 5)] (jolt.ffi/write p :uint8 i 204))
              (try
                (try (jolt.ffi/write-array p src -1 2) false
                     (catch IndexOutOfBoundsException _
                       (= [204 204 204 204 204]
                          (mapv #(bit-and (jolt.ffi/read p :uint8 %) 0xff) (range 5)))))
                (finally (jolt.ffi/free p))))")))
(ok "write-array ranged rejects negative length before touching native memory"
    (jolt-truthy?
      (ev "(let [src (byte-array [1 2 3 4 5])
                  p (jolt.ffi/alloc 5)]
              (doseq [i (range 5)] (jolt.ffi/write p :uint8 i 204))
              (try
                (try (jolt.ffi/write-array p src 0 -1) false
                     (catch IndexOutOfBoundsException _
                       (= [204 204 204 204 204]
                          (mapv #(bit-and (jolt.ffi/read p :uint8 %) 0xff) (range 5)))))
                (finally (jolt.ffi/free p))))")))
(ok "write-array ranged rejects a non-empty transfer at the exact tail"
    (jolt-truthy?
      (ev "(let [src (byte-array [1 2 3 4 5])]
              (try
                (jolt.ffi/write-array jolt.ffi/null src 5 1)
                false
                (catch IndexOutOfBoundsException _ (= [1 2 3 4 5] (vec src)))))")))
(ok "write-array ranged rejects a zero-length offset beyond the tail"
    (jolt-truthy?
      (ev "(let [src (byte-array [1 2 3 4 5])]
              (try
                (jolt.ffi/write-array jolt.ffi/null src 6 0)
                false
                (catch IndexOutOfBoundsException _ (= [1 2 3 4 5] (vec src)))))")))
(ok "write-array ranged rejects length-exceeds-src before touching native memory"
    (jolt-truthy?
      (ev "(let [src (byte-array [1 2 3 4 5])
                  p (jolt.ffi/alloc 5)]
              (doseq [i (range 5)] (jolt.ffi/write p :uint8 i 204))
              (try
                (try (jolt.ffi/write-array p src 0 99) false
                     (catch IndexOutOfBoundsException _
                       (= [204 204 204 204 204]
                          (mapv #(bit-and (jolt.ffi/read p :uint8 %) 0xff) (range 5)))))
                (finally (jolt.ffi/free p))))")))
(ok "write-array ranged rejects an overflow-shaped length before native access"
    (jolt-truthy?
      (ev "(let [src (byte-array [1 2 3 4 5])]
              (try
                (jolt.ffi/write-array jolt.ffi/null src 1 9223372036854775807)
                false
                (catch IndexOutOfBoundsException _ (= [1 2 3 4 5] (vec src)))))")))
(ok "write-array ranged rejects a wrong-kind source"
    (jolt-truthy?
      (ev "(try (jolt.ffi/write-array jolt.ffi/null [0 1 2] 0 1) false
                (catch IllegalArgumentException _ true))")))
(ok "write-array ranged rejects a char-array source"
    (jolt-truthy?
      (ev "(try (jolt.ffi/write-array jolt.ffi/null (char-array [\\a \\b]) 0 1) false
                (catch IllegalArgumentException _ true))")))
(ok "write-array ranged rejects a null pointer with non-zero length"
    (jolt-truthy?
      (ev "(try (jolt.ffi/write-array jolt.ffi/null (byte-array [1 2]) 0 1) false
                (catch NullPointerException _ true))")))

;; --- a 4096-byte transfer exercising the fold/mask seam over many bytes -----
(ok "read-array! / write-array handle a 4096-byte payload"
    (jolt-truthy?
      (ev "(let [n 4096
                  src (byte-array (mapv #(bit-and % 0xff) (range n)))
                  p (jolt.ffi/alloc n)
                  w (jolt.ffi/write-array p src 0 n)
                  dest (byte-array n)
                  r (jolt.ffi/read-array! p n dest 0)]
              (jolt.ffi/free p)
              (and (= w n) (= r n) (= (vec src) (vec dest))))")))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
