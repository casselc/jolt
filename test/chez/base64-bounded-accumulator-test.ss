(import (chezscheme))
(load "host/chez/gate-boot.ss")
(define checks 0)
(define (check label valid?)
  (set! checks (+ checks 1))
  (unless valid? (error 'base64-bounded-accumulator label)))
(for-each
  (lambda (pair)
    (check "RFC4648 basic output"
           (bytevector=? (string->utf8 (cdr pair))
                         (b64-decode (car pair) b64-alphabet #f))))
  '(("" . "") ("Zg==" . "f") ("Zm8=" . "fo") ("Zm9v" . "foo")
    ("Zm9vYg==" . "foob") ("Zm9vYmE=" . "fooba") ("Zm9vYmFy" . "foobar")
    ("Zg" . "f") ("Zm8" . "fo")))
(check "URL alphabet" (bytevector=? #vu8(251 239 255) (b64-decode "--__" b64url-alphabet #f)))
(check "MIME filtering" (bytevector=? (string->utf8 "foobar")
                                      (b64-decode "Zm9v\r\nYmFy" b64-alphabet #t)))
(check "basic rejects MIME whitespace"
       (guard (e (#t #t)) (b64-decode "Zm9v\n" b64-alphabet #f) #f))

(do ((n 0 (+ n 1))) ((> n 257))
  (let ((expected (make-bytevector n)))
    (do ((i 0 (+ i 1))) ((= i n))
      (bytevector-u8-set! expected i (modulo (+ (* i 37) (* n 11)) 256)))
    (for-each
      (lambda (alphabet)
        (for-each
          (lambda (pad?)
            (let ((encoded (b64-encode expected alphabet pad?)))
              (check "mixed bytes, alphabets and partial groups"
                     (bytevector=? expected (b64-decode encoded alphabet #f)))
              (check "MIME mixed bytes"
                     (bytevector=? expected (b64-decode (string-append "!\r\n" encoded "?") alphabet #t)))))
          '(#t #f)))
      (list b64-alphabet b64url-alphabet))))

;; Known-bad recurrence on this valid, unpadded basic input. This negative
;; control preserves bytes but retains consumed bits, independently of time.
(define (unbounded-basic s)
  (let ((acc 0) (bits 0) (out '()))
    (string-for-each
      (lambda (c)
        (set! acc (bitwise-ior (bitwise-arithmetic-shift-left acc 6) (b64-char-val c b64-alphabet)))
        (set! bits (+ bits 6))
        (when (>= bits 8)
          (set! bits (- bits 8))
          (set! out (cons (bitwise-and (bitwise-arithmetic-shift-right acc bits) 255) out)))) s)
    (u8-list->bytevector (reverse out))))
(define (selected s)
  (if (getenv "JOLT_TEST_UNBOUNDED_BASE64") (unbounded-basic s)
      (b64-decode s b64-alphabet #f)))
(do ((n 0 (+ n 4))) ((> n 256))
  (check "nonzero-bit vectors and boundaries"
         (bytevector=? (make-bytevector (quotient (* n 3) 4) 255)
                       (selected (make-string n #\/)))))
(define input (make-string 16384 #\/))
(define before (sstats-bytes (statistics)))
(define result (selected input))
(define allocated (- (sstats-bytes (statistics)) before))
(check "large exact bytes" (bytevector=? result (make-bytevector 12288 255)))
(printf "Base64 allocation: ~a bytes / ~a encoded chars\n" allocated (string-length input))
;; Broad deterministic allocation ceiling, not a speed-sensitive threshold.
;; Old recurrence exceeds it even though its decoded output is identical.
(check "linear bounded allocation" (< allocated (* 256 (string-length input))))
(printf "PASS bounded Base64 accumulator: ~a checks\n" checks)
