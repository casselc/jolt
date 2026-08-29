;; async-alts-order-test.ss — observe the actual __do-alts registration order.
;;
;; The ordinary fairness test is necessarily satisfied by the fast pass. This
;; gate instruments pvec-nth-d in an isolated process, sends __do-alts through
;; its empty-channel registration path, and records both traversals of the exact
;; ports vector. It therefore rejects a sequential or random-cyclic registration
;; pass even when the fast pass remains a full Fisher-Yates shuffle.
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n" name)))

(define (mono-nanos)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000000000 (time-second t)) (time-nanosecond t))))
(define (now-secs) (/ (exact->inexact (mono-nanos)) 1000000000.0))
(define (wait-until pred secs)
  (let ((deadline (+ (now-secs) secs)))
    (let loop ()
      (cond
        ((pred) #t)
        ((> (now-secs) deadline) #f)
        (else (sleep (make-time 'time-duration 1000000 0)) (loop))))))

(define observation-mu (make-mutex))
(define target-ports #f)
(define observations '())
(define original-pvec-nth-d pvec-nth-d)

(define (observations-snapshot)
  (jolt-with-mutex observation-mu (reverse observations)))

;; This wrapper is deliberately process-local and restored before exit. Equality
;; by identity ensures unrelated persistent-vector activity cannot contaminate a
;; trial.
(set! pvec-nth-d
  (lambda (v i d)
    (when (eq? v target-ports)
      (jolt-with-mutex observation-mu
        (set! observations (cons i observations))))
    (original-pvec-nth-d v i d)))

(define expected-indices '(0 1 2 3))
(define cyclic-orders
  '((0 1 2 3) (1 2 3 0) (2 3 0 1) (3 0 1 2)))
(define (permutation? xs)
  (equal? (list-sort < xs) expected-indices))
(define (contains-list? xss xs)
  (ormap (lambda (candidate) (equal? xs candidate)) xss))
(define (cyclic? xs) (contains-list? cyclic-orders xs))
(define (distinct-count xss)
  (length
    (fold-left (lambda (seen xs)
                 (if (contains-list? seen xs) seen (cons xs seen)))
               '() xss)))

(define registration-orders '())
(define traversals-valid? #t)
(define trials-completed? #t)

(do ((trial 0 (+ trial 1))) ((= trial 48))
  (let* ((channels (vector (jolt-async-chan) (jolt-async-chan)
                           (jolt-async-chan) (jolt-async-chan)))
         (ports (apply jolt-vector (vector->list channels)))
         (result 'pending))
    (jolt-with-mutex observation-mu
      (set! observations '())
      (set! target-ports ports))
    (fork-thread
      (lambda ()
        (*txn* #f)
        (set! result (jolt-async-do-alts ports #f))))
    ;; Four fast-pass reads followed by four registration-pass reads occur before
    ;; the worker parks. A timeout is a failure, never an unbounded gate hang.
    (unless (wait-until (lambda () (>= (length (observations-snapshot)) 8)) 3.0)
      (set! trials-completed? #f))
    (let ((seen (observations-snapshot)))
      (when (>= (length seen) 8)
        (let ((fast-order (list-head seen 4))
              (registration-order (list-head (list-tail seen 4) 4)))
          (unless (and (permutation? fast-order)
                       (permutation? registration-order))
            (set! traversals-valid? #f))
          (set! registration-orders
                (cons registration-order registration-orders)))))
    ;; Closing a registered port releases the worker and makes trials independent.
    (jolt-async-close! (vector-ref channels 0))
    (unless (wait-until (lambda () (not (eq? result 'pending))) 3.0)
      (set! trials-completed? #f))))

(set! pvec-nth-d original-pvec-nth-d)
(set! target-ports #f)

(printf "\n== core.async alts registration order ==\n")
(ok "all registration trials completed" trials-completed?)
(ok "fast and registration traversals are complete permutations"
    (and traversals-valid? (= (length registration-orders) 48)))
(ok "registration uses non-cyclic permutations"
    (ormap (lambda (xs) (not (cyclic? xs))) registration-orders))
(ok "registration explores more than cyclic rotations"
    (> (distinct-count registration-orders) 4))

(printf "\nasync alts order: ~a assertions, ~a failures\n" total fails)
(exit (if (= fails 0) 0 1))
