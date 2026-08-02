;; hasheq-concurrency-test.ss — process-level regression for the concurrent
;; weak hash-cache corruption present in the v0.5.17 base.
;;
;; One process exercises exactly one production cache, selected with
;; JOLT_HASHEQ_CONCURRENCY_MODE=string|symbol. Four coordinated Chez threads
;; race shared hot objects and fresh weak keys while collections reclaim dead
;; entries. Keeping the modes in separate processes makes a failure
;; attributable. Symbols are made with make-symbol-t, bypassing the separate
;; unsynchronized symbol-string-pool.
;;
;; Every production jolt-hasheq result is compared with its pure compute-*
;; function. Exit 0 means all comparisons passed, exit 1 records a mismatch or
;; caught condition, and exit 2 means the harness or invocation is invalid.
;; Hard faults and hangs are classified by hasheq-concurrency-test.sh.
;;
;; Knobs:
;;   JOLT_HASHEQ_CONCURRENCY_DIR   progress-log directory (optional)
;;   JOLT_HASHEQ_CONCURRENCY_MODE  required: string or symbol
;;   JOLT_HASHEQ_CONCURRENCY_ITERS iterations per worker (default 8000)

(import (chezscheme))
(load "host/chez/rt.ss")

(define n-workers 4)
(define n-hot 16)
(define retained-ring-size 32)
(define max-samples 50)

;; Explicit (collect) is illegal while ordinary Chez threads are active. Lower
;; the normal allocation trip threshold instead, so the runtime requests GC at
;; safe points through the same path that exposed the production crash.
(collect-trip-bytes (* 256 1024))

(define artifact-dir (getenv "JOLT_HASHEQ_CONCURRENCY_DIR"))
(define mode (getenv "JOLT_HASHEQ_CONCURRENCY_MODE"))
(unless (and mode (or (string=? mode "string") (string=? mode "symbol")))
  (fprintf (current-error-port)
           "JOLT_HASHEQ_CONCURRENCY_MODE must be string or symbol\n")
  (exit 2))
(define string-mode? (string=? mode "string"))

(define iters
  (let* ((raw (getenv "JOLT_HASHEQ_CONCURRENCY_ITERS"))
         (n (and raw (string->number raw))))
    (if (and n (integer? n) (exact? n) (> n 0))
        (min n 10000000)
        8000)))

;; A separate append-only file per worker remains useful if the process faults
;; or is killed while stdout is still buffered. Progress I/O is outside cache
;; calls and happens only every 512 iterations.
(define (progress! wid str)
  (when artifact-dir
    (guard (e (else #f))
      (let ((p (open-file-output-port
                (string-append artifact-dir "/progress-"
                               (number->string wid) ".log")
                (file-options append) (buffer-mode none) (native-transcoder))))
        (put-string p str)
        (put-char p #\newline)
        (close-port p)))))

;; Failure recording is the only test-owned shared mutation. Cache operations
;; are never performed under this mutex.
(define fail-mu (make-mutex))
(define fail-count 0)
(define fail-samples '())

(define (record! kind wid i expected got key)
  (with-mutex fail-mu
    (set! fail-count (+ fail-count 1))
    (when (< (length fail-samples) max-samples)
      (set! fail-samples
            (cons (list kind wid i expected got key) fail-samples)))))

(define (condition->string e)
  (guard (x (else "<unprintable condition>"))
    (call-with-string-output-port (lambda (p) (display-condition e p)))))

(define (record-exception! wid e)
  (with-mutex fail-mu
    (set! fail-count (+ fail-count 1))
    (when (< (length fail-samples) max-samples)
      (set! fail-samples
            (cons (list 'exception mode wid (condition->string e))
                  fail-samples)))))

(define (pure-hasheq key)
  (if string-mode?
      (compute-string-hasheq key)
      (compute-symbol-hasheq (symbol-t-ns key) (symbol-t-name key))))

(define (make-hot-key k)
  (if string-mode?
      (string-append "hot-str-" (number->string k))
      (make-symbol-t (if (even? k) #f "hotns")
                     (string-append "hot-sym-" (number->string k))
                     jolt-nil)))

(define (make-fresh-key wid i)
  (if string-mode?
      (string-append "wk-str-" (number->string wid) "-" (number->string i))
      (make-symbol-t (if (fxeven? i) #f "wkns")
                     (string-append "wk-sym-" (number->string wid) "-"
                                    (number->string i))
                     jolt-nil)))

;; Hot objects are constructed serially, but their expected values are computed
;; without the cache. Workers therefore race their first production insert.
(define hot-keys (make-vector n-hot))
(define hot-expected (make-vector n-hot))
(do ((k 0 (+ k 1))) ((= k n-hot))
  (let ((key (make-hot-key k)))
    (vector-set! hot-keys k key)
    (vector-set! hot-expected k (pure-hasheq key))))

;; Sanity is intentionally collision-safe: equal content must hash equally,
;; but unequal content is not required to produce a distinct hash. The
;; production check uses an object outside the hot set.
(define (harness-ok?)
  (let* ((a (if string-mode?
                (string-copy "sanity-key")
                (make-symbol-t "sanity" "key" jolt-nil)))
         (b (if string-mode?
                (string-copy "sanity-key")
                (make-symbol-t "sanity" "key" jolt-nil)))
         (expected (pure-hasheq a)))
    (and (not (eq? a b))
         (fixnum? expected)
         (fx=? expected (pure-hasheq b))
         (fx=? expected (jolt-hasheq a)))))

(unless (harness-ok?)
  (printf "hasheq-concurrency-test: harness sanity check failed (~a)\n" mode)
  (flush-output-port)
  (exit 2))

(define (check-key wid i key expected)
  (let ((got (jolt-hasheq key)))
    (unless (and (fixnum? got) (fx=? got expected))
      (record! (if string-mode? 'string 'symbol)
               wid i expected got
               (if string-mode? key (symbol-t-name key))))))

(define (worker wid)
  (guard (e (else (record-exception! wid e)))
    (let ((retained (make-vector retained-ring-size #f)))
      (let loop ((i 0))
        (if (fx<? i iters)
            (begin
              (let* ((k (fxmod (fx+ i wid) n-hot))
                     (key (vector-ref hot-keys k)))
                (check-key wid i key (vector-ref hot-expected k)))
              (let ((key (make-fresh-key wid i)))
                (check-key wid i key (pure-hasheq key))
                ;; The retained allocation keeps recent weak keys live and
                ;; supplies bounded pressure for frequent automatic GC.
                (vector-set! retained (fxmod i retained-ring-size)
                             (make-vector 64 key)))
              (when (fxzero? (fxmod i 512))
                (progress! wid (string-append "iter " (number->string i))))
              (loop (fx+ i 1)))
            (progress! wid (string-append "done " (number->string iters))))))))

;; One start barrier releases all workers together. The done counter is the
;; portable Chez join used by nearby runtime tests.
(define start-mu (make-mutex))
(define start-cv (make-condition))
(define started? #f)
(define done-mu (make-mutex))
(define done-cv (make-condition))
(define done-count 0)

(do ((wid 0 (+ wid 1))) ((= wid n-workers))
  (fork-thread
   (lambda ()
     (dynamic-wind
       (lambda () #f)
       (lambda ()
         (with-mutex start-mu
           (let wait ()
             (unless started?
               (condition-wait start-cv start-mu)
               (wait))))
         (progress! wid "started")
         (worker wid))
       (lambda ()
         (with-mutex done-mu
           (set! done-count (+ done-count 1))
           (condition-broadcast done-cv)))))))

(with-mutex start-mu
  (set! started? #t)
  (condition-broadcast start-cv))

(with-mutex done-mu
  (let wait ()
    (unless (= done-count n-workers)
      (condition-wait done-cv done-mu)
      (wait))))

(printf "hasheq-concurrency-test: mode=~a workers=~a iterations=~a/worker hot-keys=~a\n"
        mode n-workers iters n-hot)
(if (zero? fail-count)
    (printf "PASS: every jolt-hasheq result matched the pure oracle\n")
    (begin
      (printf "FAIL: ~a corruption event(s) detected\n" fail-count)
      (for-each (lambda (sample) (printf "  ~s\n" sample))
                (reverse fail-samples))))
(flush-output-port)
(exit (if (zero? fail-count) 0 1))
