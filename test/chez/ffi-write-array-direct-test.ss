;; Whole-array ffi/write-array copies directly from managed backing without
;; exporting a borrowed pointer. Run from the repository root through the
;; workspace's mandatory Chez wrapper; no native helper library is required.
(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/ffi.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a~n" name)))

(define (foreign-octets p n)
  (let loop ((i 0) (out '()))
    (if (= i n) (reverse out)
        (loop (+ i 1) (cons (sa-foreign-ref 'unsigned-8 p i) out)))))

(define (with-sentinel-buffer size thunk)
  (let ((p (sa-foreign-alloc size)))
    (dynamic-wind
      (lambda ()
        (do ((i 0 (+ i 1))) ((= i size))
          (sa-foreign-set! 'unsigned-8 p i #xa5)))
      (lambda () (thunk p))
      (lambda () (sa-foreign-free p)))))

;; Observe mechanism, not timing: real foreign writes still happen. Intercepts
;; are serial/test-local and always restored. The adapter must see the ORIGINAL
;; backing on the direct path, not a different allocation made by another seam.
(define (observe-write thunk collect-before-copy?)
  (let ((stage ja-bytes->bv!) (copy sa-foreign-bytes-set!)
        (stages 0) (copies 0) (seen #f))
    (dynamic-wind
      (lambda ()
        (set! ja-bytes->bv!
          (lambda (arr off bv at n)
            (set! stages (+ stages 1)) (stage arr off bv at n)))
        (set! sa-foreign-bytes-set!
          (lambda (p bv n)
            (set! copies (+ copies 1)) (set! seen bv)
            ;; Collection BEFORE the adapter call tests managed liveness; the
            ;; native memcpy itself must remain non-collect-safe (source rule).
            (when collect-before-copy? (collect))
            (copy p bv n))))
      (lambda ()
        (let ((result (thunk))) (vector result stages copies seen)))
      (lambda ()
        (set! ja-bytes->bv! stage)
        (set! sa-foreign-bytes-set! copy)))))

(define (check-write name arr off n expected direct? short-arity?)
  (with-sentinel-buffer (+ n 9)
    (lambda (p)
      (let ((observed
              (observe-write
                (lambda ()
                  (if short-arity? (ffi-write-array (+ p 3) arr)
                      (ffi-write-array (+ p 3) arr off n))) #t)))
        (ok (string-append name ": returned count") (= n (vector-ref observed 0)))
        (ok (string-append name ": staging count")
            (= (if direct? 0 1) (vector-ref observed 1)))
        (ok (string-append name ": exactly one adapter call")
            (= 1 (vector-ref observed 2)))
        (ok (string-append name ": source identity")
            (eq? direct? (eq? (jolt-array-vec arr) (vector-ref observed 3))))
        (ok (string-append name ": bytes and untouched neighbors")
            (equal? (foreign-octets p (+ n 9))
                    (append '(165 165 165) expected '(165 165 165 165 165 165))))))))

(define octets (na-byte-array (bytevector 0 1 127 128 200 255 10)))
(check-write "whole array, two arguments" octets 0 7 '(0 1 127 128 200 255 10) #t #t)
(check-write "whole array, explicit range" octets 0 7 '(0 1 127 128 200 255 10) #t #f)
(check-write "empty whole array" (na-byte-array (bytevector)) 0 0 '() #t #t)
(check-write "zero-offset prefix retains staging" octets 0 3 '(0 1 127) #f #f)
(check-write "nonzero source offset retains staging" octets 3 3 '(128 200 255) #f #f)
(check-write "zero length at end" octets 7 0 '() #f #f)
(check-write "legacy boxed byte backing"
             (make-jolt-array (vector 0 127 -128 -1) 'byte)
             0 4 '(0 127 128 255) #f #t)
(check-write "legacy boxed slice"
             (make-jolt-array (vector 0 127 -128 -1) 'byte)
             1 2 '(127 128) #f #f)

;; Every rejected range must fail BEFORE staging or touching foreign memory.
;; Nonzero sentinels prevent an accidental zero write from passing unnoticed.
(for-each
  (lambda (range)
    (with-sentinel-buffer 16
      (lambda (p)
        (let* ((off (car range)) (n (cadr range))
               (observed
                 (observe-write
                   (lambda ()
                     (guard (e (#t #t))
                       (ffi-write-array (+ p 3) octets off n) #f)) #f)))
          (ok "invalid range throws" (eq? #t (vector-ref observed 0)))
          (ok "invalid range does not stage or call adapter"
              (and (= 0 (vector-ref observed 1)) (= 0 (vector-ref observed 2))))
          (ok "invalid range leaves destination untouched"
              (equal? (foreign-octets p 16) (make-list 16 #xa5)))))))
  '((-1 1) (0 -1) (0 8) (6 2) (8 0)))

;; Successful copying does not make either side an alias of the other. This is
;; a synchronous copy, not a pin/loan or ownership-transfer API.
(with-sentinel-buffer 12
  (lambda (p)
    (let ((arr (na-byte-array (bytevector 0 128 255 17))))
      (ffi-write-array (+ p 3) arr)
      (ja-set! arr 0 66)
      (ok "source mutation after return cannot alter destination"
          (equal? (foreign-octets (+ p 3) 4) '(0 128 255 17)))
      (sa-foreign-set! 'unsigned-8 p 4 99)
      (ok "destination mutation cannot alter source"
          (equal? (bytevector->u8-list (jolt-array-vec arr)) '(66 128 255 17))))))

;; The positive fallback controls above detect a vacuous counter. These raw
;; registered entries must use the same candidate primitive as direct calls.
(ok "public host entry is candidate" (eq? (var-deref "jolt.ffi" "write-array") ffi-write-array))
(ok "reserved host entry is candidate" (eq? (var-deref "jolt.ffi" "__write-array") ffi-write-array))

(printf "ffi-write-array-direct-test: ~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
