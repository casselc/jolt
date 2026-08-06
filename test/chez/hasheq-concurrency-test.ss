;; hasheq-concurrency-test.ss — concurrent weak-cache safety regression.
;;
;; Chez mutable hashtables are shared destructive objects: concurrent reads and
;; writes without synchronization can corrupt their bucket chains and later
;; abort inside the collector's post-GC eq-hashtable rehash. Exercise both
;; hasheq cache paths from several application threads with distinct, short-lived
;; keys and enough ordinary allocation to provoke collection.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

;; Make the automatic threaded collection witness independent of the host's
;; nursery tuning. Unlike collect, this does not request collection from an
;; application thread while its peers are active.
(define original-collect-trip-bytes (collect-trip-bytes))
(collect-trip-bytes (* 1024 1024))

(define worker-count 8)
(define iterations 25000)
(define done-mutex (make-mutex))
(define done-condition (make-condition))
(define remaining worker-count)
(define failure #f)
(define worker-threads '())
(define shared-string (string-copy "shared-hasheq-key"))
(define shared-symbol (make-symbol-t #f shared-string jolt-nil))
(string-hasheq shared-string)
(symbol-hasheq shared-symbol)
(define parent-id (get-thread-id))
(define parent-string-cell (string-hasheq-cache-cell))
(define parent-symbol-cell (symbol-hasheq-cache-cell))
(define gc-before (sstats-gc-count (statistics)))

(do ((worker 0 (+ worker 1))) ((= worker worker-count))
  (let ((worker-id worker))
    (set! worker-threads
      (cons
       (fork-thread
        (lambda ()
          (guard (e (#t (with-mutex done-mutex
                           (unless failure (set! failure e)))))
         ;; A child inherits the parent's parameter value, but must replace it
         ;; before touching either mutable table, even for the same key.
         (string-hasheq shared-string)
         (symbol-hasheq shared-symbol)
         (let ((string-cell (string-hasheq-cache-cell))
               (symbol-cell (symbol-hasheq-cache-cell))
               (child-id (get-thread-id)))
           (unless (and (eqv? (car string-cell) child-id)
                        (eqv? (car symbol-cell) child-id)
                        (not (eq? (cdr string-cell)
                                  (cdr parent-string-cell)))
                        (not (eq? (cdr symbol-cell)
                                  (cdr parent-symbol-cell))))
             (error 'hasheq-concurrency-test
                    "child retained an inherited cache" child-id)))
         (let loop ((i 0) (checksum 0))
           (unless (= i iterations)
             (let* ((s (string-append
                        "worker-" (number->string worker-id)
                        "-value-" (number->string i)
                        (make-string 24
                                     (integer->char
                                      (+ 65 (modulo (+ worker-id i) 26))))))
                    ;; Split workers evenly so each cache is mutated by four
                    ;; threads without coupling the symbol case to interning.
                    (string-worker? (even? worker-id))
                    (h (if string-worker?
                           (string-hasheq s)
                           (symbol-hasheq (make-symbol-t #f s jolt-nil))))
                    (expected (if string-worker?
                                  (compute-string-hasheq s)
                                  (compute-symbol-hasheq #f s))))
               (unless (= h expected)
                 (error 'hasheq-concurrency-test
                        "cached hash differs from direct computation"
                        h expected))
               (loop (+ i 1) (bitwise-xor checksum h))))))
          (with-mutex done-mutex
            (set! remaining (- remaining 1))
            (condition-signal done-condition))))
       worker-threads))))

(with-mutex done-mutex
  (let ((deadline (ms->deadline 120000)))
    (let wait ()
      (cond
        ((zero? remaining) #t)
        ((condition-wait done-condition done-mutex deadline) (wait))
        (else
         (printf "hasheq concurrency timeout: remaining=~s~n" remaining))))))

(when failure
  (display-condition failure (current-error-port)))

;; The completion condition is signaled immediately before a worker returns;
;; join successful workers before the explicit collections below.
(when (zero? remaining)
  (for-each thread-join worker-threads))

(define gc-after (sstats-gc-count (statistics)))
(define parent-ownership-preserved?
  (and (eqv? (car (string-hasheq-cache-cell)) parent-id)
       (eqv? (car (symbol-hasheq-cache-cell)) parent-id)
       (eq? (string-hasheq-cache-cell) parent-string-cell)
       (eq? (symbol-hasheq-cache-cell) parent-symbol-cell)))

(define string-size-before-collect #f)
(define symbol-size-before-collect #f)
(define string-size-after-collect #f)
(define symbol-size-after-collect #f)
(define weak-cleanup-observed? #f)
(when (zero? remaining)
  ;; Long-lived worker caches must not retain ephemeral keys. Never call
  ;; collect after a timeout: Chez rejects it while worker threads remain.
  ;; The size drop proves weak keys were released; Chez may retain the table's
  ;; peak backing capacity, which is a separate workload-level memory concern.
  (collect)
  (collect-trip-bytes (* 64 1024 1024))
  (do ((i 0 (+ i 1))) ((= i 10000))
    (let ((s (string-append "ephemeral-" (number->string i))))
      (string-hasheq s)
      (symbol-hasheq (make-symbol-t #f s jolt-nil))))
  (set! string-size-before-collect
        (hashtable-size (cdr (string-hasheq-cache-cell))))
  (set! symbol-size-before-collect
        (hashtable-size (cdr (symbol-hasheq-cache-cell))))
  (collect)
  (set! string-size-after-collect
        (hashtable-size (cdr (string-hasheq-cache-cell))))
  (set! symbol-size-after-collect
        (hashtable-size (cdr (symbol-hasheq-cache-cell))))
  (set! weak-cleanup-observed?
        (and (< string-size-after-collect string-size-before-collect)
             (< symbol-size-after-collect symbol-size-before-collect)))
  (collect-trip-bytes original-collect-trip-bytes))

(printf "hasheq concurrency: workers=~a iterations=~a remaining=~a failure=~s gc-delta=~a weak-sizes=~s/~s->~s/~s~n"
        worker-count iterations remaining failure (- gc-after gc-before)
        string-size-before-collect symbol-size-before-collect
        string-size-after-collect symbol-size-after-collect)
(exit (if (and (zero? remaining)
               (not failure)
               parent-ownership-preserved?
               weak-cleanup-observed?
               (> gc-after gc-before))
          0
          1))
