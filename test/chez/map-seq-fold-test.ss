;; Raw callback effects must match the actual seq view, not only a final result.
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (evv src) (jolt-compile-eval src "user"))

;; Independent oracle: use the public sequence view before any instrumentation.
(define (seq-pairs m)
  (map (lambda (entry) (cons (pvec-nth! entry 0) (pvec-nth! entry 1)))
       (seq->list (jolt-seq m))))
(define (effect-trace fold m)
  (let ((seen (make-vector (pmap-cnt m))) (i 0))
    (fold m (lambda (k v acc)
              (vector-set! seen i (cons k v))
              (set! i (+ i 1))
              (+ acc 1)) 0)
    (vector->list seen)))
(define (check-map name m)
  (let* ((expected (seq-pairs m)) (pending expected) (prefix-ok? #t) (calls 0)
         (answer
           (pmap-fold-seq-order
             m (lambda (k v acc)
                 ;; Check the next pair WHILE its side effect runs. Reversing a
                 ;; returned collection cannot repair out-of-order callbacks.
                 (unless (and (pair? pending) (equal? (car pending) (cons k v)))
                   (set! prefix-ok? #f))
                 (when (pair? pending) (set! pending (cdr pending)))
                 (set! calls (+ calls 1))
                 (+ (* acc 3) v)) 7)))
    (ok (string-append name ": callback effects")
        (and prefix-ok? (null? pending) (= calls (pmap-cnt m))))
    (ok (string-append name ": accumulator order")
        (= answer (fold-left (lambda (a pair) (+ (* a 3) (cdr pair))) 7 expected)))
    (ok (string-append name ": map unchanged") (equal? expected (seq-pairs m)))))

(for-each
  (lambda (m)
    (let ((seed (vector 'unique)) (calls 0))
      (ok "empty returns identical seed without callback"
          (and (eq? seed (pmap-fold-seq-order
                          m (lambda (k v acc) (set! calls (+ calls 1)) acc) seed))
               (= calls 0)))))
  (list empty-pmap empty-pmap-hash))

(define array-small (evv "(array-map :z 3 :a 1 :b 2)"))
(define array-large (evv "(apply array-map (range 40))"))
(define array-edited (evv "(persistent! (dissoc! (assoc! (transient (array-map :a 1 :b 2 :c 3)) :d 4) :b))"))
(define trie (evv "(into (hash-map) (map (fn [i] [(str \"pad-\" i) i]) (range 100)))"))
(define collision-keys '("Aa" "BB" "AaAa" "BBBB" "AaBB" "BBAa"))
(define (add-collisions m)
  (let loop ((ks collision-keys) (m m) (n 100))
    (if (null? ks) m
        (loop (cdr ks) (pmap-assoc m (car ks) n) (+ n 1)))))
(define collisions (add-collisions trie))
(define collision-only
  (pmap-assoc (pmap-assoc empty-pmap-hash "Aa" 1) "BB" 2))
;; Six equal-length Aa/BB choices produce 64 distinct strings with one complete
;; hash, not merely one root slot. Exercise the documented bucket-stack tradeoff.
(define collision64-keys
  (let loop ((n 6) (keys '("")))
    (if (= n 0) keys
        (loop (- n 1)
              (apply append
                     (map (lambda (prefix)
                            (list (string-append prefix "Aa")
                                  (string-append prefix "BB"))) keys))))))
(define collision64
  (let loop ((keys collision64-keys) (m empty-pmap-hash) (n 0))
    (if (null? keys) m
        (loop (cdr keys) (pmap-assoc m (car keys) n) (+ n 1)))))

(ok "explicit large array map does not promote" (pmap-array? array-large))
(ok "padding uses a HAMT" (hnode? (pmap-root trie)))
(ok "Aa/BB truly collide" (= (key-hash "Aa") (key-hash "BB")))
(ok "four-string group truly collides"
    (apply = (map key-hash '("AaAa" "BBBB" "AaBB" "BBAa"))))
(ok "two collision hashes are distinct" (not (= (key-hash "Aa") (key-hash "AaAa"))))
(ok "64 distinct collision keys"
    (and (= 64 (length collision64-keys)) (= 64 (pmap-cnt collision64))))
(ok "all 64 complete hashes are equal" (apply = (map key-hash collision64-keys)))

;; Verify fixture shape, rather than relying on names that merely look colliding.
(define (buckets node)
  (fold-left
    (lambda (out child)
      (cond ((hnode? child) (append (buckets child) out))
            ((hcoll? child) (cons (map car (hcoll-alist child)) out))
            (else out)))
    '() (vector->list (hnode-arr node))))
(define actual-buckets (buckets (pmap-root collisions)))
(ok "two-key full-hash bucket exists"
    (exists (lambda (ks) (and (= (length ks) 2) (member "Aa" ks) (member "BB" ks)))
            actual-buckets))
(ok "four-key full-hash bucket exists"
    (exists (lambda (ks) (and (= (length ks) 4)
                             (for-all (lambda (k) (member k ks))
                                      '("AaAa" "BBBB" "AaBB" "BBAa"))))
            actual-buckets))
(ok "nested HAMT node exists"
    (exists hnode? (vector->list (hnode-arr (pmap-root collisions)))))
(ok "actual 64-entry full-hash bucket exists"
    (exists (lambda (keys)
              (and (= 64 (length keys))
                   (for-all (lambda (k) (member k keys)) collision64-keys)))
            (buckets (pmap-root collision64))))

(for-each (lambda (item) (check-map (car item) (cdr item)))
          (list (cons "small array" array-small) (cons "large array" array-large)
                (cons "edited array" array-edited) (cons "HAMT" trie)
                (cons "padded collision groups" collisions)
                (cons "one collision bucket" collision-only)
                (cons "64-entry collision bucket" collision64)
                (cons "updated/deleted bucket"
                      (pmap-dissoc (pmap-assoc collisions "AaAa" 999) "BBBB"))))

;; Negative controls kill the old descending-child AND forward-bucket orders.
;; The second fixture has only one child: its mismatch can only be bucket order.
(ok "descending-child mutant is detected"
    (not (equal? (effect-trace pmap-fold-fwd trie) (seq-pairs trie))))
(ok "forward-collision-bucket mutant is detected"
    (not (equal? (effect-trace pmap-fold-fwd collision-only) (seq-pairs collision-only))))
(ok "64-entry forward-bucket mutant is detected"
    (not (equal? (effect-trace pmap-fold-fwd collision64) (seq-pairs collision64))))

(define (check-exception-prefix name m stop-after)
  (let ((seen '()) (sentinel (vector 'stop)) (expected (seq-pairs m)))
    (ok (string-append name ": callback exception propagates unchanged")
        (guard (ex (else (eq? ex sentinel)))
          (pmap-fold-seq-order m
            (lambda (k v n)
              (set! seen (cons (cons k v) seen))
              (if (= (+ n 1) stop-after) (raise sentinel) (+ n 1))) 0)
          #f))
    (ok (string-append name ": exception stops after exact seq prefix")
        (equal? (reverse seen) (list-head expected stop-after)))))
(check-exception-prefix "padded collisions" collisions 3)
(check-exception-prefix "64-entry collision bucket" collision64 33)

;; No production test seam. Trap the existing entry/seq constructors, verify the
;; trap with seq itself, and restore both bindings even if the fold raises.
(let ((saved-entry make-map-entry) (saved-view pmap-view-seq)
      (sentinel (vector 'materialized)) (count 0))
  (dynamic-wind
    (lambda ()
      (set! make-map-entry (lambda args (raise sentinel)))
      (set! pmap-view-seq (lambda args (raise sentinel))))
    (lambda ()
      (ok "entry-view trap is live"
          (guard (ex (else (eq? ex sentinel))) (jolt-seq collisions) #f))
      (ok "fold does not materialize entry view"
          (guard (ex (else #f))
            (pmap-fold-seq-order collisions
              (lambda (k v acc) (set! count (+ count 1)) acc) #f)
            (= count (pmap-cnt collisions)))))
    (lambda () (set! make-map-entry saved-entry) (set! pmap-view-seq saved-view))))

(printf "map-seq-fold-test: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
