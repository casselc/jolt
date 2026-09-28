;; Narrow compiler/runtime contract for the private Durable V1 WAL primitive.
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
(define (ascii s) (map char->integer (string->list s)))
(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1)))))))
(define (emit-source source)
  (let-values (((f j) (rdr-read-form source 0 (string-length source))))
    (ei-compile-form (make-analyze-ctx "user") f #f)))

(ok "compiler lowers proven String receiver"
    (contains? (emit-source "(.toDurableWalBytes \"x\")")
               "(jolt-str-durable-wal-bytes \"x\")"))
(ok "unproven receiver retains dispatch"
    (let ((emitted (emit-source "((fn [x] (.toDurableWalBytes x)) \"x\")")))
      (and (contains? emitted "record-method-dispatch")
           (not (contains? emitted "jolt-str-durable-wal-bytes")))))
(ok "empty SQL has exact framing"
    (equal? (jvec->list (jolt-str-durable-wal-bytes ""))
            (ascii "{\"sql\":\"\"}\n")))
(ok "quote slash and backslash use canonical short escapes"
    (equal? (jvec->list (jolt-str-durable-wal-bytes "\"/\\"))
            (ascii "{\"sql\":\"\\\"\\/\\\\\"}\n")))
(ok "named controls use canonical short escapes"
    (equal? (jvec->list (jolt-str-durable-wal-bytes "\b\f\n\r\t"))
            (ascii "{\"sql\":\"\\b\\f\\n\\r\\t\"}\n")))
(ok "other controls use lowercase hex escapes"
    (equal? (jvec->list (jolt-str-durable-wal-bytes (string (integer->char 1))))
            (ascii "{\"sql\":\"\\u0001\"}\n")))
(ok "NUL uses lowercase JSON hex escape"
    (equal? (jvec->list (jolt-str-durable-wal-bytes (string (integer->char 0))))
            (ascii "{\"sql\":\"\\u0000\"}\n")))
(ok "BMP Unicode uses lowercase JSON hex"
    (equal? (jvec->list (jolt-str-durable-wal-bytes "β€"))
            (ascii "{\"sql\":\"\\u03b2\\u20ac\"}\n")))
(ok "astral Unicode becomes a UTF-16 surrogate pair"
    (equal? (jvec->list (jolt-str-durable-wal-bytes "😀"))
            (ascii "{\"sql\":\"\\ud83d\\ude00\"}\n")))
(for-each
  (lambda (n)
    (let* ((prefix (make-string n #\a))
           (input (string-append prefix "😀\"/\\\nβ"))
           (expected (string-append "{\"sql\":\"" prefix
                      "\\ud83d\\ude00\\\"\\/\\\\\\n\\u03b2\"}\n")))
      (ok (format "chunk-boundary exact spelling after ~a ASCII scalars" n)
          (equal? (jvec->list (jolt-str-durable-wal-bytes input)) (ascii expected)))))
  '(0 1 340 341 342 4083 4084 4085 4095 4096 4097 8168 8192))
(let* ((input (make-string 5000 #\a))
       (first (jolt-str-durable-wal-bytes input))
       (second (jolt-str-durable-wal-bytes input)))
  (ja-set! first 0 0)
  (ok "multi-chunk results retain independent owned storage"
      (and (= 123 (ja-ref second 0))
           (= (+ 5000 11) (ja-len second)))))
(let* ((sql "\"\\/\b\f\n\r\t")
       (expected (jvec->list (jolt-str-durable-wal-bytes sql)))
       (first (jolt-str-durable-wal-bytes sql))
       (second (jolt-str-durable-wal-bytes sql)))
  (na-aset-byte first 8 0)
  (ok "mutating one output leaves another output unchanged"
      (equal? (jvec->list second) expected))
  (ok "mutating output cannot corrupt cached escape templates"
      (equal? (jvec->list (jolt-str-durable-wal-bytes sql)) expected)))
;; Source-shape guard for the measured cause; runtime ownership is checked above.
;; This is not a timing or general allocation oracle. The old encoder fails it.
(let ((source (call-with-input-file "host/chez/java/natives-str.ss" get-string-all)))
  (ok "short escape writes do not allocate a bytevector per character"
      (not (contains? source "(put-bytevector port (bytevector 92"))))
(printf "durable-wal-native-test: ~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
