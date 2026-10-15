;; Only fresh exclusively produced storage is adopted; no retained caller-owned
;; buffer is passed to the internal ownership-transfer helper.
(import (chezscheme))
(load "host/chez/run-gate-harness.ss")

(define (fresh-result size value)
  (let* ((bytes (make-bytevector size value))
         (address (#%$fxaddress bytes)))
    ;; Return the sole array owner and an integer address witness, not a mutable
    ;; alias to producer storage. The producer relinquishes BYTES here.
    (values (na-owned-bv->bytearray bytes) address)))

(let-values (((a address) (fresh-result 4 255)))
  (gate-check "small fresh storage adopted without copy"
              (#%$fxaddress (jolt-array-vec a)) address)
  (gate-check "high-bit byte representation preserved" (ja-ref a 0) -1)
  (gate-check "small owner has no unnecessary pin"
              (hashtable-ref sa-pin-boxes a #f) #f)
  (ja-set! a 0 42)
  (gate-check "sole mutable owner can change its result" (ja-ref a 0) 42))
(let-values (((a address) (fresh-result 65536 128)))
  (gate-check "large fresh storage adopted without copy"
              (#%$fxaddress (jolt-array-vec a)) address)
  (gate-check "large adopted result has owner-lifetime pin"
              (box? (hashtable-ref sa-pin-boxes a #f)) #t)
  (do ((i 0 (+ i 1))) ((= i 3)) (sa-gc-collect))
  (gate-check "live owner retains identical backing across full GC"
              (#%$fxaddress (jolt-array-vec a)) address)
  (gate-check "live owner retains high-bit contents" (ja-ref a 65535) -128)
  (ja-set! a 65535 17)
  (gate-check "owner remains mutable after GC" (ja-ref a 65535) 17))
(define (discard-owner-get-pin)
  (let-values (((a _) (fresh-result 65536 7)))
    ;; Retain only the guardian's box, never its owner. The drain must clear it
    ;; after collection rather than retaining pinned backing forever.
    (hashtable-ref sa-pin-boxes a #f)))
(let ((pin (discard-owner-get-pin)))
  (gate-check "release control starts with a pinned backing" (bytevector? (unbox pin)) #t)
  (do ((i 0 (+ i 1))) ((= i 3)) (sa-gc-collect))
  (gate-check "dead owner releases pinned backing" (unbox pin) #f))
(let-values (((a _) (fresh-result 0 0)) ((b __) (fresh-result 0 0)))
  (gate-check "empty result has zero length" (ja-len a) 0)
  (gate-check "independent empty results have distinct array owners" (eq? a b) #f))
(let-values (((a _) (fresh-result 4 3)) ((b __) (fresh-result 4 3)))
  (ja-set! a 0 99)
  (gate-check "independent adopted results do not alias" (ja-ref b 0) 3))
(for-each
  (lambda (copy)
    (let* ((borrowed (bytevector 1 255)) (a (copy borrowed)))
      (gate-check "public seam does not adopt borrowed backing"
                  (eq? borrowed (jolt-array-vec a)) #f)
      (bytevector-u8-set! borrowed 0 42)
      (gate-check "borrowed caller mutation cannot alter public result" (ja-ref a 0) 1)
      (ja-set! a 1 7)
      (gate-check "public result mutation cannot alter caller buffer"
                  (bytevector-u8-ref borrowed 1) 255)))
  (list na-bv->bytearray na-byte-array))
(gate-summary "Owned byte adoption")
