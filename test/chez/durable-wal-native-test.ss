;; Narrow contract for the private Durable V1 WAL byte primitive.  Generic JSON
;; conformance belongs to data.json; this pins only the stable byte spelling
;; needed by the Durable capability-gated fast path.
(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/emit-image.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a~n" name)))

(define (jvec->list v)
  (let loop ((s (jolt-seq v)) (acc '()))
    (if (jolt-nil? s) (reverse acc)
        (loop (seq-more s) (cons (seq-first s) acc)))))

(define (durable-bytes s)
  (jvec->list (jolt-str-durable-wal-bytes s)))

(define (ascii s) (map char->integer (string->list s)))

(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1)))))))

(ok "compiler lowers a proven String host-call directly"
    ;; The analyzer separately owns the proof that stamps :target-type :str.
    ;; This test deliberately checks only that typed String calls select the
    ;; private primitive; generic record-method dispatch remains unmodified.
    (let ((backend (read-file-string "jolt-core/jolt/backend_scheme.clj")))
      (and (contains? backend "(= m \"toDurableWalBytes\")")
           (contains? backend "(jolt-str-durable-wal-bytes "))))
(ok "empty SQL has exact framing"
    (equal? (durable-bytes "") (ascii "{\"sql\":\"\"}\n")))
(ok "quote slash and backslash use canonical short escapes"
    (equal? (durable-bytes "\"/\\") (ascii "{\"sql\":\"\\\"\\/\\\\\"}\n")))
(ok "named controls use canonical short escapes"
    (equal? (durable-bytes "\b\f\n\r\t")
            (ascii "{\"sql\":\"\\b\\f\\n\\r\\t\"}\n")))
(ok "other controls use lowercase hex escapes"
    (equal? (durable-bytes (string (integer->char 1)))
            (ascii "{\"sql\":\"\\u0001\"}\n")))
(ok "BMP Unicode uses lowercase JSON hex"
    (equal? (durable-bytes "β€")
            (ascii "{\"sql\":\"\\u03b2\\u20ac\"}\n")))
(ok "astral Unicode becomes its UTF-16 surrogate escape pair"
    (equal? (durable-bytes "😀")
            (ascii "{\"sql\":\"\\ud83d\\ude00\"}\n")))

(printf "durable-wal-native-test: ~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
