;; Whole-array ffi/write-array copies from managed backing without exporting a
;; borrowed pointer. Real native copies, bounds sentinels and mechanism controls.
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

;; Real adapters remain in use; only count the serial test-local seam. Restore
;; every intercepted procedure on both success and exception. A forced GC before
;; each native copy checks source liveness, not collection *during* memcpy.
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
            (when collect-before-copy? (collect))
            (copy p bv n))))
      (lambda () (let ((result (thunk))) (vector result stages copies seen)))
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
;; The primitive's old coercion path is unchanged even for a non-byte kind.
;; A bytevector alone is insufficient authority for the byte-array fast path.
(check-write "different array kind retains staging"
             (make-jolt-array (bytevector 0 127 128 255) 'int)
             0 4 '(0 127 128 255) #f #t)

(for-each
  (lambda (range)
    (with-sentinel-buffer 16
      (lambda (p)
        (let ((observed
                (observe-write
                  (lambda ()
                    (guard (e (#t #t))
                      (ffi-write-array (+ p 3) octets (car range) (cadr range)) #f)) #f)))
          (ok "invalid range throws" (eq? #t (vector-ref observed 0)))
          (ok "invalid range does not stage or call adapter"
              (and (= 0 (vector-ref observed 1)) (= 0 (vector-ref observed 2))))
          (ok "invalid range leaves destination untouched"
              (equal? (foreign-octets p 16) (make-list 16 #xa5)))))))
  '((-1 1) (0 -1) (0 8) (6 2) (8 0)))
(for-each
  (lambda (not-array)
    (with-sentinel-buffer 8
      (lambda (p)
        (let ((observed
                (observe-write
                  (lambda ()
                    (guard (e (#t #t)) (ffi-write-array p not-array) #f)) #f)))
          (ok "non-array input throws" (eq? #t (vector-ref observed 0)))
          (ok "non-array rejection precedes copying"
              (and (= 0 (vector-ref observed 1)) (= 0 (vector-ref observed 2))))
          (ok "non-array leaves destination untouched"
              (equal? (foreign-octets p 8) (make-list 8 #xa5)))))))
  (list jolt-nil "bytes" (vector 1 2)))

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
(ok "public host entry is candidate" (eq? (var-deref "jolt.ffi" "write-array") ffi-write-array))
(ok "reserved host entry is candidate" (eq? (var-deref "jolt.ffi" "__write-array") ffi-write-array))
(printf "ffi-write-array-direct-test: ~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
