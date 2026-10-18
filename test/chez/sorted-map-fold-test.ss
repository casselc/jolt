;; Native stock-map fold: callback order without entry/seq construction.
(import (chezscheme))
(load "host/chez/gate-boot.ss")
(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (ev source) (jolt-compile-eval source "user"))
(define (pairs m)
  (let loop ((xs (jolt-seq m)) (acc '()))
    (if (jolt-nil? xs) (reverse acc)
        (let ((entry (jolt-first xs)))
          (loop (jolt-next xs)
                (cons (cons (jolt-nth entry 0) (jolt-nth entry 1)) acc))))))
(define (fold-pairs m)
  (reverse (sorted-map-fold-seq-order m (lambda (k v acc) (cons (cons k v) acc)) '())))

(for-each
  (lambda (n)
    (for-each
      (lambda (constructor)
        (let ((m (ev (format "(into (~a) (map (fn [i] [i (* 7 i)]) (range ~a)))" constructor n))))
          (ok "real bootstrap stock ops are admitted" (stock-sorted-map? m))
          (ok "fold order equals the same map's seq" (equal? (pairs m) (fold-pairs m)))
          (ok "one callback per entry"
              (= n (sorted-map-fold-seq-order m (lambda (k v acc) (+ acc 1)) 0)))))
      '("sorted-map" "sorted-map-by >")))
  '(0 1 8 31 32 33 128 129 1000))

(let ((m (ev "(sorted-map)")) (seed (vector 'seed)))
  (ok "empty fold returns exact accumulator and never calls visit"
      (eq? seed (sorted-map-fold-seq-order m (lambda args (error 'test "unexpected visit")) seed))))
(for-each
  (lambda (m)
    (let ((calls 0))
      (ok "non-stock collections decline without callbacks" (not (stock-sorted-map? m)))
      (ok "fold rejects unsupported input"
          (guard (e (else #t))
            (sorted-map-fold-seq-order m (lambda args (set! calls (+ calls 1))) #f) #f))
      (ok "no visit on rejection" (= calls 0))))
  (list jolt-nil #f (ev "{}") (ev "[]") (ev "(sorted-set 1 2)")))

(let* ((m (ev "(sorted-map :a 1 :b 2)")) (ops (jolt-ref-get m (keyword #f "ops"))) (calls 0))
  (jolt-ref-put! m (keyword #f "ops")
    (pmap-assoc ops (keyword #f "seq") (lambda (x) (set! calls (+ calls 1)) jolt-nil)))
  (ok "per-object operation replacement declines" (not (stock-sorted-map? m)))
  (ok "guard does not trial-call custom seq" (= calls 0))
  (ok "ordinary seq still calls the object's operation" (and (jolt-nil? (jolt-seq m)) (= calls 1))))

(let ((m (ev "(let [armed (atom false) m (sorted-map-by (fn [a b] (when @armed (throw (ex-info \"comparison\" {}))) (compare b a)) \"a\" 1 \"b\" 2)] (reset! armed true) m)")))
  (ok "armed custom comparator is not called" (equal? (pairs m) (fold-pairs m))))
(let* ((m (ev "(sorted-map :a 1 :b 2 :c 3)")) (expected (pairs m))
       (seen '()) (sentinel (vector 'stop)))
  (ok "exception identity propagates"
      (guard (e (else (eq? e sentinel)))
        (sorted-map-fold-seq-order m
          (lambda (k v acc) (set! seen (cons (cons k v) seen))
            (if (= acc 1) (raise sentinel) (+ acc 1))) 0) #f))
  (ok "exception stops after exact seq prefix" (equal? (reverse seen) (list-head expected 2)))
  (ok "nested fold has an independent cursor"
      (= 9 (sorted-map-fold-seq-order m
             (lambda (k v acc)
               (+ acc (sorted-map-fold-seq-order m (lambda (ik iv n) (+ n 1)) 0))) 0))))

;; This trap is itself checked against seq, so an accidentally ineffective
;; instrumentation seam cannot certify the allocation-light fold.
(let ((m (ev "(into (sorted-map) (map (fn [i] [i i]) (range 65)))"))
      (original make-map-entry) (calls 0))
  (dynamic-wind
    (lambda () (set! make-map-entry
                 (lambda (k v) (set! calls (+ calls 1)) (original k v))))
    (lambda ()
      (fold-pairs m)
      (ok "fold constructs no map entries" (= calls 0))
      (pairs m)
      (ok "entry-construction trap is live on seq" (= calls 65)))
    (lambda () (set! make-map-entry original))))

(printf "sorted map fold: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
