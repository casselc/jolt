;; async-alts-ownership-test.ss — native __do-alts owns readiness and default.
;;
;; This is a runtime-seam gate for issue #21 slice 1. It distinguishes the sole
;; native fast pass from handler registration, proves the optional-default arity
;; does not register, preserves the old blocking 2-arg arity, and gives both
;; priority modes non-vacuous ready choices. Nil-put validation is also required
;; to fail before an earlier ready operation can be consumed.
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

(define (result-value r) (pvec-nth-d r 0 jolt-nil))
(define (result-port r) (pvec-nth-d r 1 jolt-nil))
(define default-port (keyword #f "default"))

(printf "\n== native core.async alts ownership ==\n")

;; The public API rejects an empty operation set. Both native compatibility
;; arities fail the same way instead of letting the blocking form wait forever
;; while the default-aware form returns a value.
(let* ((ports (jolt-vector))
       (blocking
        (guard (e (#t 'threw))
          (jolt-async-do-alts ports #t)
          'no-throw))
       (defaulted
        (guard (e (#t 'threw))
          (jolt-async-do-alts ports #t 'fallback)
          'no-throw)))
  (ok "empty operation set rejected by 2-arg native seam"
      (eq? blocking 'threw))
  (ok "empty operation set rejected by 3-arg native seam"
      (eq? defaulted 'threw)))

;; Ready take: native priority traversal checks the empty first port once and
;; consumes the ready second port. A supplied default loses to readiness.
(let* ((empty (jolt-async-chan 1))
       (ready (jolt-async-chan 1))
       (ports (jolt-vector empty ready))
       (poll-count 0)
       (original-ac-poll! ac-poll!))
  (jolt-async-give ready 'ready-value)
  (set! ac-poll!
    (lambda (ch)
      (set! poll-count (+ poll-count 1))
      (original-ac-poll! ch)))
  (let ((r (jolt-async-do-alts ports #t 'fallback)))
    (set! ac-poll! original-ac-poll!)
    (ok "ready result wins over default"
        (and (eq? (result-value r) 'ready-value)
             (eq? (result-port r) ready)))
    (ok "ready path performs one native traversal"
        (= poll-count 2))))

;; Ready put exercises the other operation shape through the same native pass.
(let* ((ch (jolt-async-chan 1))
       (try-count 0)
       (original-ac-try-give! ac-try-give!))
  (set! ac-try-give!
    (lambda (target value)
      (set! try-count (+ try-count 1))
      (original-ac-try-give! target value)))
  (let ((r (jolt-async-do-alts (jolt-vector (jolt-vector ch 'put-value))
                               #t 'fallback)))
    (set! ac-try-give! original-ac-try-give!)
    (ok "ready put commits through native traversal"
        (and (eq? (result-value r) #t)
             (eq? (result-port r) ch)
             (eq? (jolt-async-take ch) 'put-value)))
    (ok "ready put attempted exactly once" (= try-count 1))))

;; Default: every candidate is checked exactly once, then the default returns;
;; no handler was allocated into either channel's registration queue.
(let* ((a (jolt-async-chan))
       (b (jolt-async-chan))
       (put-ch (jolt-async-chan))
       (ports (jolt-vector a b (jolt-vector put-ch 'pending-value)))
       (poll-count 0)
       (try-count 0)
       (original-ac-poll! ac-poll!)
       (original-ac-try-give! ac-try-give!))
  (set! ac-poll!
    (lambda (ch)
      (set! poll-count (+ poll-count 1))
      (original-ac-poll! ch)))
  (set! ac-try-give!
    (lambda (ch value)
      (set! try-count (+ try-count 1))
      (original-ac-try-give! ch value)))
  (let ((r (jolt-async-do-alts ports #t #f)))
    (set! ac-poll! original-ac-poll!)
    (set! ac-try-give! original-ac-try-give!)
    (ok "false is a present default value"
        (and (eq? (result-value r) #f)
             (eq? (result-port r) default-port)))
    (ok "default performs exactly one readiness traversal"
        (and (= poll-count 2) (= try-count 1)))
    (ok "default never registers a handler"
        (and (null? (async-chan-alt-takers a))
             (null? (async-chan-alt-takers b))
             (null? (async-chan-alt-putters put-ch))))))

;; Closed operations are ready operations and therefore beat a supplied
;; default: take returns nil, put returns false, and both identify the channel.
(let ((take-ch (jolt-async-chan))
      (put-ch (jolt-async-chan)))
  (jolt-async-close! take-ch)
  (jolt-async-close! put-ch)
  (let ((take-r (jolt-async-do-alts (jolt-vector take-ch) #t 'fallback))
        (put-r (jolt-async-do-alts
                 (jolt-vector (jolt-vector put-ch 'value)) #t 'fallback)))
    (ok "closed empty take beats default with [nil channel]"
        (and (eq? (result-value take-r) jolt-nil)
             (eq? (result-port take-r) take-ch)))
    (ok "closed put beats default with [false channel]"
        (and (eq? (result-value put-r) #f)
             (eq? (result-port put-r) put-ch)))))

;; The old 2-arg native seam remains blocking: it registers on both channels,
;; wakes from the second, and prunes the losing first registration.
(let* ((a (jolt-async-chan))
       (b (jolt-async-chan))
       (ports (jolt-vector a b))
       (result 'pending))
  (fork-thread
    (lambda ()
      (*txn* #f)
      (set! result (jolt-async-do-alts ports #t))))
  (let ((registered?
         (wait-until
           (lambda ()
             (and (= (length (async-chan-alt-takers a)) 1)
                  (= (length (async-chan-alt-takers b)) 1)))
           3.0)))
    (ok "2-arg compatibility seam registers when none ready" registered?)
    (jolt-async-give b 'wake-value)
    (let ((woke? (wait-until (lambda () (not (eq? result 'pending))) 3.0)))
      (ok "registered native alts wakes with selected port"
          (and woke?
               (eq? (result-value result) 'wake-value)
               (eq? (result-port result) b)))
      (ok "winner prunes the losing registration"
          (null? (async-chan-alt-takers a))))))

;; Priority is a semantic order, not merely a set of ready candidates.
(let ((a (jolt-async-chan 1)) (b (jolt-async-chan 1)))
  (jolt-async-give a 'first)
  (jolt-async-give b 'second)
  (let ((r (jolt-async-do-alts (jolt-vector a b) #t)))
    (ok "priority selects the first ready port"
        (and (eq? (result-value r) 'first)
             (eq? (result-port r) a)))))

;; Non-priority repeatedly chooses between two continually-ready ports. The
;; broad bound rejects declared-order traversal without making timing relevant.
(let ((a (jolt-async-chan 1)) (b (jolt-async-chan 1))
      (a-count 0) (b-count 0))
  (jolt-async-give a 'a)
  (jolt-async-give b 'b)
  (do ((i 0 (+ i 1))) ((= i 1000))
    (let ((r (jolt-async-do-alts (jolt-vector a b) #f)))
      (if (eq? (result-port r) a)
          (begin (set! a-count (+ a-count 1)) (jolt-async-give a 'a))
          (begin (set! b-count (+ b-count 1)) (jolt-async-give b 'b)))))
  (ok "non-priority explores both ready ports"
      (and (< 300 a-count 700) (< 300 b-count 700))))

;; Validate every put before readiness can mutate an earlier operation. This is
;; the native half of the independently runnable public red/green regression in
;; unit.edn.
(let* ((ready (jolt-async-chan 1))
       (other (jolt-async-chan))
       (_ (jolt-async-give ready 'kept))
       (outcome
        (guard (e (#t 'threw))
          (jolt-async-do-alts
            (jolt-vector ready (jolt-vector other jolt-nil)) #t 'fallback)
          'no-throw)))
  (ok "nil put fails before an earlier ready take mutates"
      (and (eq? outcome 'threw)
           (eq? (jolt-async-poll! ready) 'kept))))

(printf "\nasync alts ownership: ~a assertions, ~a failures\n" total fails)
(exit (if (= fails 0) 0 1))
