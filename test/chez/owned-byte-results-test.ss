;; Fresh-output adoption is internal; normal Clojure APIs retain isolation.
(import (chezscheme))
(load "host/chez/gate-boot.ss")
(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a~n" name)))
(define (ev s) (jolt-final-str (jolt-compile-eval s "user")))
(define (is name s expected) (ok name (string=? (ev s) expected)))

;; Representation controls fail if the ownership helper copies, or if public
;; conversion accidentally starts adopting retained mutable source storage.
(let* ((bv (bytevector 1 255)) (a (na-owned-bv->bytearray bv)))
  (ok "owned helper adopts exact storage" (eq? bv (jolt-array-vec a))))
(let* ((bv (bytevector 1 255)) (a (na-bv->bytearray bv)))
  (bytevector-u8-set! bv 0 42)
  (ok "public raw seam still copies"
      (and (not (eq? bv (jolt-array-vec a))) (= 1 (ja-ref a 0)))))
(let* ((bv (bytevector 3 4)) (a (na-byte-array bv)))
  (bytevector-u8-set! bv 0 42)
  (ok "public constructor still copies" (= 3 (ja-ref a 0))))

;; Count calls through the copying seam, not just output equivalence. Restore
;; the binding even if a producer raises. This is a runtime mechanism control.
(define (copy-count thunk)
  (let ((original na-bv->bytearray) (copies 0))
    (dynamic-wind
      (lambda () (set! na-bv->bytearray
                  (lambda (bv) (set! copies (+ copies 1)) (original bv))))
      (lambda () (thunk) copies)
      (lambda () (set! na-bv->bytearray original)))))
(ok "getBytes bypasses copying seam"
    (= 0 (copy-count (lambda () (jolt-str-get-bytes "β😀" "UTF-8")))))
(ok "native WAL bypasses copying seam"
    (= 0 (copy-count (lambda () (jolt-str-durable-wal-bytes "β/\"")))))
(ok "public conversion retains one copying seam"
    (= 1 (copy-count (lambda () (na-byte-array (bytevector 1))))))
;; Observe the input to the public copying constructor: it must be exactly
;; the stream-owned accumulator, not an already-copied intermediate. Combined
;; with the public-seam control above this detects reintroducing two copies.
(let* ((stream (jolt-compile-eval
                 "(let [o (java.io.ByteArrayOutputStream.)] (.write o 7) o)" "user"))
       (owned (baos-bytes stream))
       (original na-byte-array)
       (seen #f))
  (dynamic-wind
    (lambda ()
      (set! na-byte-array
        (lambda (x . rest) (set! seen x) (apply original x rest))))
    (lambda ()
      (record-method-dispatch stream "toByteArray" jolt-nil)
      (ok "toByteArray copies stream storage without intermediate copy"
          (eq? seen owned)))
    (lambda () (set! na-byte-array original))))

(is "UTF8 mutable results independent of source and one another"
    "(let [s \"β😀\" a (.getBytes s \"UTF-8\") b (.getBytes s \"UTF-8\")] (aset-byte a 0 0) (and (= s (String. b \"UTF-8\")) (= s \"β😀\") (not= (aget a 0) (aget b 0))))" "true")
;; Empty storage has no mutable element; this asserts wrapper identity only.
(is "empty UTF8 calls return distinct array wrappers"
    "(not (identical? (.getBytes \"\" \"UTF-8\") (.getBytes \"\" \"UTF-8\")))" "true")
(for-each
  (lambda (charset)
    (let ((a (jolt-str-get-bytes "abc" charset))
          (b (jolt-str-get-bytes "abc" charset)))
      (ok (string-append "fresh charset storage: " charset)
          (not (eq? (jolt-array-vec a) (jolt-array-vec b))))))
  '("UTF-8" "l1" "US-ASCII" "UTF-16" "UTF-16LE" "UTF-16BE"
    "UTF-32" "UTF-32LE" "UTF-32BE" "ISO-2022-JP"))
(is "unsupported charset still throws"
    "(try (.getBytes \"a\" \"not-a-real-charset\") false (catch java.io.UnsupportedEncodingException e true))" "true")
(is "snapshot survives mutation writes reset and close"
    "(let [o (java.io.ByteArrayOutputStream.)] (.write o (byte-array [1 2])) (let [a (.toByteArray o) b (.toByteArray o)] (aset-byte a 0 42) (.write o 3) (let [c (.toByteArray o)] (.reset o) (.write o 9) (.close o) (and (= [1 2] (vec b)) (= [1 2 3] (vec c)) (= [9] (vec (.toByteArray o)))))))" "true")
(is "WAL results independently mutable"
    "(let [a (.toDurableWalBytes \"x\") b (.toDurableWalBytes \"x\")] (aset-byte a 0 0) (= 123 (aget b 0)))" "true")

(printf "owned-byte-results-test: ~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
