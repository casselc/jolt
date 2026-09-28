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

(define (emit-source source)
  (let-values (((f j) (rdr-read-form source 0 (string-length source))))
    (ei-compile-form (make-analyze-ctx "user") f #f)))

(ok "compiler lowers a proven String receiver directly"
    (contains? (emit-source "(.toDurableWalBytes \"x\")")
               "(jolt-str-durable-wal-bytes \"x\")"))
(ok "unproven receiver retains ordinary dispatch"
    (let ((emitted (emit-source "((fn [x] (.toDurableWalBytes x)) \"x\")")))
      (and (contains? emitted "record-method-dispatch")
           (not (contains? emitted "jolt-str-durable-wal-bytes")))))
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

(for-each
  (lambda (n)
    (let* ((prefix (make-string n #\a))
           (input (string-append prefix "😀\"/\\\nβ"))
           (expected (string-append "{\"sql\":\"" prefix
                      "\\ud83d\\ude00\\\"\\/\\\\\\n\\u03b2\"}\n")))
      (ok (format "chunk-boundary exact spelling after ~a ASCII scalars" n)
          (equal? (durable-bytes input) (ascii expected)))))
  ;; Appended suffix has six scalars: prefixes334/335/336 test n340/341/342.
  '(0 1 334 335 336 340 341 342 4083 4084 4085 4095 4096 4097 8168 8192))
(let* ((input (make-string 5000 #\a))
       (first (jolt-str-durable-wal-bytes input))
       (second (jolt-str-durable-wal-bytes input)))
  (ja-set! first 0 0)
  (ok "multi-chunk results retain independent owned storage"
      (and (= 123 (ja-ref second 0)) (= (+ 5000 11) (ja-len second)))))

;; Instrument the actual source form, not a hand-copied encoder. Do not alter
;; runtime primitives or the production binding; only this test's private twin.
(define port-write-count 0)
(define (counted-put-bytevector . args)
  (set! port-write-count (+ port-write-count 1))
  (apply put-bytevector args))
(define (counted-put-u8 port byte)
  (set! port-write-count (+ port-write-count 1))
  (put-u8 port byte))
(define (instrument-form form)
  (cond ((eq? form 'jolt-str-durable-wal-bytes) 'counted-wal-encoder)
        ((eq? form 'put-bytevector) 'counted-put-bytevector)
        ((eq? form 'put-u8) 'counted-put-u8)
        ((pair? form) (cons (instrument-form (car form)) (instrument-form (cdr form))))
        (else form)))
(call-with-input-file "host/chez/java/natives-str.ss"
  (lambda (port)
    (let loop ((form (read port)))
      (when (eof-object? form) (error 'wal-gate "encoder definition not found"))
      (if (and (pair? form) (eq? (car form) 'define)
               (eq? (if (pair? (cadr form)) (caadr form) (cadr form))
                    'jolt-str-durable-wal-bytes))
          (eval (instrument-form form) (interaction-environment))
          (loop (read port))))))
(let* ((input (make-string 10000 #\a)) (output (counted-wal-encoder input)))
  (ok "instrumented twin retains byte-exact output"
      (equal? (jvec->list output) (durable-bytes input)))
  (ok "large ASCII WAL uses bounded block port writes, not one per scalar"
      (<= port-write-count 10)))

(printf "durable-wal-native-test: ~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
