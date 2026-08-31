;; async-alts-order-test.ss — observe the actual __do-alts registration order.
;;
;; The ordinary fairness test is necessarily satisfied by the fast pass. This
;; gate instruments pvec-nth-d in an isolated process, sends __do-alts through
;; its empty-channel registration path, and records all three traversals of the
;; exact ports vector: declared-order validation, then the fast and registration
;; passes in one shared Fisher-Yates order. It rejects a sequential, random-cyclic,
;; or independently reshuffled registration pass.
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
(define (valid-traversals? validation-order fast-order registration-order)
  (and (equal? validation-order expected-indices)
       (permutation? fast-order)
       (permutation? registration-order)
       (equal? fast-order registration-order)))
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
    ;; Four validation reads, four fast-pass reads, then four registration-pass
    ;; reads occur before the worker parks. A timeout is a failure, never an
    ;; unbounded gate hang.
    (unless (wait-until (lambda () (>= (length (observations-snapshot)) 12)) 3.0)
      (set! trials-completed? #f))
    (let ((seen (observations-snapshot)))
      (when (>= (length seen) 12)
        (let ((validation-order (list-head seen 4))
              (fast-order (list-head (list-tail seen 4) 4))
              (registration-order (list-head (list-tail seen 8) 4)))
          (unless (valid-traversals? validation-order fast-order registration-order)
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
(ok "validation is declared-order; fast and registration share one permutation"
    (and traversals-valid? (= (length registration-orders) 48)))
(ok "independent-registration-order mutation is rejected"
    (not (valid-traversals? '(0 1 2 3) '(2 0 3 1) '(0 2 1 3))))
(ok "registration uses non-cyclic permutations"
    (ormap (lambda (xs) (not (cyclic? xs))) registration-orders))
(ok "registration explores more than cyclic rotations"
    (> (distinct-count registration-orders) 4))

;; A shared alts handler can lose on another channel while this transformed
;; channel remains full. Its inactive registration must be pruned independently
;; of capacity so explicit close can complete the xform immediately and once.
(let* ((ch (jolt-async-chan 1))
       (h (alt-handler-alloc))
       (completion-count 0)
       (original-ac-xrf-apply ac-xrf-apply))
  (jolt-async-give ch 'buffered)
  (alt-claim! h)
  (async-chan-alt-putters-set! ch (list (cons h 'stale)))
  (async-chan-xrf-set! ch #t)
  (set! ac-xrf-apply
    (lambda (target . args)
      (when (and (eq? target ch) (null? args))
        (set! completion-count (+ completion-count 1)))
      target))
  (jolt-async-close! ch)
  (set! ac-xrf-apply original-ac-xrf-apply)
  (ok "inactive full-buffer put registration pruned at close"
      (null? (async-chan-alt-putters ch)))
  (ok "pruned registration permits exactly-once xform completion"
      (= completion-count 1)))

;; Observe the atomic-pair invariant at the runtime seam used by ac-notify!.
;; This is the executable boundary case from the bounded SMT model: a shared
;; alts handler is both the FIFO put and take head, while a distinct compatible
;; putter waits behind it.  Progress must skip the self-pair, claim exactly one
;; distinct pair, and leave neither selected handler active.
(let* ((ch (jolt-async-chan))
       (shared (alt-handler-alloc))
       (peer (alt-handler-alloc))
       (claim-events '())
       (original-alt-claim-pair! alt-claim-pair!))
  (set! alt-claim-pair!
    (lambda (put-h take-h)
      (let* ((put-before (alt-active? put-h))
             (take-before (alt-active? take-h))
             (claimed? (original-alt-claim-pair! put-h take-h))
             (event (vector (alt-handler-id put-h)
                            (alt-handler-id take-h)
                            put-before take-before claimed?
                            (alt-active? put-h) (alt-active? take-h))))
        (set! claim-events (cons event claim-events))
        claimed?)))
  (async-chan-alt-putters-set!
   ch (list (cons shared 'self) (cons peer 'external)))
  (async-chan-alt-takers-set! ch (list shared))
  (jolt-with-mutex (async-chan-mu ch) (ac-notify! ch))
  (set! alt-claim-pair! original-alt-claim-pair!)
  (let ((event (and (= (length claim-events) 1) (car claim-events))))
    (ok "mixed alts makes one compatible pair claim" event)
    (ok "pair claim never rendezvous a handler with itself"
        (and event (not (= (vector-ref event 0) (vector-ref event 1)))))
    (ok "both handlers are active at pair linearization"
        (and event (vector-ref event 2) (vector-ref event 3)))
    (ok "compatible pair claim succeeds"
        (and event (vector-ref event 4)))
    (ok "successful pair claim consumes both handler identities"
        (and event (not (vector-ref event 5)) (not (vector-ref event 6))))
    (ok "claimed and stale mixed registrations are removed"
        (and (null? (async-chan-alt-putters ch))
             (null? (async-chan-alt-takers ch))))))

;; The private registered! hooks are the deterministic "the waiter is visible"
;; seam used by race tests.  They are arbitrary caller code, so visibility must
;; be committed under the channel mutex and the hook itself invoked after unlock,
;; before the operation waits.
(let ((ch (jolt-async-chan 1))
      (registered-depth #f)
      (put-result 'pending))
  (jolt-async-give ch 'seed)
  (fork-thread
   (lambda ()
     (set! put-result
       (jolt-async-give/registered
        ch 'tail (lambda () (set! registered-depth (jolt-locks-held)))))))
  (ok "private put registered hook fires before the operation can finish"
      (and (wait-until (lambda () registered-depth) 2.0)
           (eq? put-result 'pending)))
  (ok "private put registered hook runs outside the counted channel lock"
      (eqv? registered-depth 0))
  (ok "registered put remains live after its hook"
      (and (eq? (jolt-async-take ch) 'seed)
           (wait-until (lambda () (not (eq? put-result 'pending))) 2.0)
           (eq? put-result #t)
           (eq? (jolt-async-take ch) 'tail))))

(let ((ch (jolt-async-chan 1))
      (registered-depth #f)
      (take-result 'pending))
  (fork-thread
   (lambda ()
     (set! take-result
       (jolt-async-take/registered
        ch (lambda () (set! registered-depth (jolt-locks-held)))))))
  (ok "private take registered hook fires before the operation can finish"
      (and (wait-until (lambda () registered-depth) 2.0)
           (eq? take-result 'pending)))
  (ok "private take registered hook runs outside the counted channel lock"
      (eqv? registered-depth 0))
  (jolt-async-give ch 'wake)
  (ok "registered take remains live after its hook"
      (and (wait-until (lambda () (not (eq? take-result 'pending))) 2.0)
           (eq? take-result 'wake))))

;; A reservation belongs to the operation that made it.  Force that operation
;; to pause after unlock but before drive, then let another execution context
;; attempt a drive.  Channel-global scanning incorrectly lets the second context
;; run the first operation's user code.
(let ((ch (jolt-async-chan 1))
      (original-drive ac-drive-xrf!)
      (driver-id #f)
      (driver-at-boundary? #f)
      (release-driver? #f)
      (xrf-owner #f)
      (put-result 'pending))
  (async-chan-xrf-set!
   ch (lambda args
        (when (pair? args)
          (set! xrf-owner (jolt-execution-context-identity)))
        ch))
  (set! ac-drive-xrf!
    (lambda (target work)
      (if (and (eq? target ch)
               (eq? driver-id (jolt-execution-context-identity)))
          (begin
            (set! driver-at-boundary? #t)
            (wait-until (lambda () release-driver?) 2.0)
            (original-drive target work))
          (original-drive target work))))
  (fork-thread
   (lambda ()
     (set! driver-id (jolt-execution-context-identity))
     (set! put-result (jolt-async-give ch 'owned))))
  (ok "reserving put reaches the forced post-unlock drive boundary"
      (wait-until (lambda () driver-at-boundary?) 2.0))
  ;; This is deliberately a different execution context.
  (original-drive ch (async-chan-xrf-work ch))
  (set! release-driver? #t)
  (ok "only the reserving execution context invokes the reducer"
      (and (wait-until (lambda () (not (eq? put-result 'pending))) 2.0)
           (eq? xrf-owner driver-id)))
  (set! ac-drive-xrf! original-drive))

(printf "\nasync alts order: ~a assertions, ~a failures\n" total fails)
(exit (if (= fails 0) 0 1))
