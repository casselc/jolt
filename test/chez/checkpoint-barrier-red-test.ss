;; RED-only executable histories for the exact-actor checkpoint barrier ABI.
;;
;; Run each named history in its own bounded subprocess through
;; checkpoint-barrier-red-test.sh.  The current runtime deliberately rejects
;; the versioned manifest below, so this suite stays outside the default/CI
;; gate until the barrier slice is implemented.  Do not weaken these histories
;; into sleeps-as-synchronization: event publication and test-owned conditions
;; are the only progress signals; the subprocess deadline is only a watchdog.
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a\n" name)))

(define (attempt thunk)
  (guard (e (#t (cons 'error e))) (cons 'ok (thunk))))
(define (attempt-unwrapped thunk)
  (guard (e (#t (cons 'error (jolt-unwrap-throw e))))
    (cons 'ok (thunk))))
(define (ok-result? x) (and (pair? x) (eq? 'ok (car x))))
(define (error-result? x) (and (pair? x) (eq? 'error (car x))))

(define kw-version (keyword "jolt.checkpoint" "version"))
(define kw-plan (keyword "jolt.checkpoint" "plan"))
(define kw-barriers (keyword "jolt.checkpoint" "barriers"))
(define kw-trace (keyword #f "trace"))
(define kw-next-seq (keyword #f "next-seq"))
(define kw-seq (keyword #f "seq"))
(define kw-actor (keyword #f "actor"))
(define kw-id (keyword #f "id"))
(define kw-hit (keyword #f "hit"))
(define kw-action (keyword #f "action"))
(define kw-barrier (keyword #f "barrier"))
(define kw-continue (keyword #f "continue"))
(define kw-cancel (keyword #f "cancel"))

(define (snapshot) (jolt-checkpoint-snapshot))
(define (trace-of s) (jolt-get s kw-trace))
(define (trace-count) (pvec-count (trace-of (snapshot))))
(define (event-at trace i) (pvec-nth! trace i))

(define (selector actor site hit)
  (jolt-vector actor site hit))

;; V1 keeps the occurrence plan flat and inert.  The separate barrier table
;; maps one explicit barrier ID to its exact selector vector.  Consequently a
;; round is [generation barrier-id], selectors may name distinct sites, every
;; :barrier selector has exactly one group, and membership cannot be inferred
;; from timing or a site's local hit count.
(define (manifest entries groups)
  (jolt-hash-map
    kw-version 1
    kw-plan (apply jolt-hash-map (apply append entries))
    kw-barriers (apply jolt-hash-map (apply append groups))))

(define (entry actor site hit action)
  ;; The v1 plan has no barrier metadata or round integer: all round identity
  ;; lives in the separate barriers table.
  (list (selector actor site hit) action))

(define (group barrier-id selectors)
  (list barrier-id (apply jolt-vector selectors)))

(define (register-barrier-site! site . extra)
  (jolt-checkpoint-register-site!
    site
    (append '(continue barrier) extra)))

(define (barrier-hit site)
  (jolt-checkpoint! site '(continue barrier)))

(define (barrier-event? event actor site hit seq)
  (and (eq? kw-barrier (jolt-get event kw-action))
       (string=? actor (jolt-get event kw-actor))
       (string=? site (jolt-get event kw-id))
       (= hit (jolt-get event kw-hit))
       (= seq (jolt-get event kw-seq))))

(define (now-ms)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000 (time-second t))
       (quotient (time-nanosecond t) 1000000))))

(define (await-trace-count n)
  (let ((deadline (+ (now-ms) 3000)))
    (let loop ()
      (cond ((>= (trace-count) n) #t)
            ((>= (now-ms) deadline) #f)
            (else
             (sleep (make-time 'time-duration 1000000 0))
             (loop))))))

;; Result cells make OS-thread histories self-bounded.  The outer subprocess
;; timeout remains a second line of defense for a carrier-blocking barrier.
(define (thread-result thunk)
  (let ((mu (make-mutex))
        (cv (make-condition))
        (done? #f)
        (value #f))
    (fork-thread
      (lambda ()
        (let ((v (attempt-unwrapped thunk)))
          (jolt-with-mutex mu
            (set! value v)
            (set! done? #t)
            (condition-broadcast cv)))))
    (vector mu cv (lambda () done?) (lambda () value))))

(define (thread-result-await result)
  (let ((deadline (+ (now-ms) 3000)))
    (jolt-with-mutex (vector-ref result 0)
      (let loop ()
        (unless ((vector-ref result 2))
          (if (>= (now-ms) deadline)
              (set! deadline #f)
              (begin
                (jolt-condition-wait
                  (vector-ref result 1)
                  (vector-ref result 0)
                  (jolt-millis->time deadline))
                (loop))))))
    (if deadline ((vector-ref result 3)) '(timeout))))

(define (counter)
  (let ((mu (make-mutex)) (n 0))
    (vector
      (lambda () (jolt-with-mutex mu (set! n (+ n 1))))
      (lambda () (jolt-with-mutex mu n)))))
(define (counter-inc! c) ((vector-ref c 0)))
(define (counter-value c) ((vector-ref c 1)))

(define (install! entries groups)
  (attempt (lambda () (jolt-checkpoint-install-plan! (manifest entries groups)))))

(define (history-one-carrier-fibers)
  (jolt-checkpoint-reset!)
  (jolt-fiber-carrier-count-set! 1)
  (let* ((site-a "test.barrier/fiber-a")
         (site-b "test.barrier/fiber-b")
         (released (counter)))
    (register-barrier-site! site-a)
    (register-barrier-site! site-b)
    (let ((setup
            (install!
              (list (entry "fiber/a" site-a 1 kw-barrier)
                    (entry "fiber/b" site-b 1 kw-barrier))
              (list
                (group "shared/fiber"
                       (list (selector "fiber/a" site-a 1)
                             (selector "fiber/b" site-b 1))))))
          (a #f)
          (b #f))
      (sa-fiber-spawn
        (lambda ()
          (jolt-checkpoint-bind-actor! "fiber/a")
          (set! a (attempt-unwrapped (lambda () (barrier-hit site-a))))
          (when (ok-result? a) (counter-inc! released))))
      (sa-fiber-spawn
        (lambda ()
          (jolt-checkpoint-bind-actor! "fiber/b")
          (set! b (attempt-unwrapped (lambda () (barrier-hit site-b))))
          (when (ok-result? b) (counter-inc! released))))
      (sa-fiber-run-all)
      (let ((trace (trace-of (snapshot))))
        (ok "versioned barrier manifest installs" (ok-result? setup))
        (ok "one-carrier peer arrival releases both fibers exactly once"
            (and (ok-result? a) (ok-result? b) (= 2 (counter-value released))))
        (ok "distinct sites share one exact-actor barrier"
            (and (= 2 (pvec-count trace))
                 (barrier-event? (event-at trace 0) "fiber/a" site-a 1 1)
                 (barrier-event? (event-at trace 1) "fiber/b" site-b 1 2)))))))

(define (history-os-threads)
  (jolt-checkpoint-reset!)
  (let* ((site-a "test.barrier/thread-a")
         (site-b "test.barrier/thread-b")
         (released (counter)))
    (register-barrier-site! site-a)
    (register-barrier-site! site-b)
    (let* ((setup
             (install!
               (list (entry "thread/a" site-a 1 kw-barrier)
                     (entry "thread/b" site-b 1 kw-barrier))
               (list
                 (group "shared/thread"
                        (list (selector "thread/a" site-a 1)
                              (selector "thread/b" site-b 1))))))
           (a (thread-result
                (lambda ()
                  (jolt-checkpoint-bind-actor! "thread/a")
                  (barrier-hit site-a)
                  (counter-inc! released))))
           (b (thread-result
                (lambda ()
                  (jolt-checkpoint-bind-actor! "thread/b")
                  (barrier-hit site-b)
                  (counter-inc! released))))
           (ar (thread-result-await a))
           (br (thread-result-await b))
           (trace (trace-of (snapshot))))
      (ok "OS-thread barrier manifest installs" (ok-result? setup))
      (ok "OS-thread peer arrival releases both waiters exactly once"
          (and (ok-result? ar) (ok-result? br) (= 2 (counter-value released))))
      (ok "OS-thread barrier records only the two exact arrivals"
          (and (= 2 (pvec-count trace))
               (equal? '(1 2)
                       (map (lambda (e) (jolt-get e kw-seq))
                            (vector->list (pvec-v trace)))))))))

(define (history-exact-membership)
  (jolt-checkpoint-reset!)
  (let ((site-a "test.barrier/member-a")
        (site-b "test.barrier/member-b")
        (site-c "test.barrier/outsider"))
    (register-barrier-site! site-a)
    (register-barrier-site! site-b)
    (register-barrier-site! site-c)
    (let ((valid
            (install!
              (list
                (entry "member/a" site-a 1 kw-barrier)
                (entry "member/b" site-b 1 kw-barrier))
              (list
                (group "members/exact"
                       (list (selector "member/a" site-a 1)
                             (selector "member/b" site-b 1)))))))
      (ok "one canonical exact-membership contract installs" (ok-result? valid)))
    (jolt-checkpoint-reset!)
    (register-barrier-site! site-a)
    (register-barrier-site! site-b)
    (register-barrier-site! site-c)
    (let ((before (snapshot)))
      (ok "an action selector outside the declared membership is rejected"
          (and
            (error-result?
              (install!
                (list
                  (entry "member/a" site-a 1 kw-barrier)
                  (entry "member/b" site-b 1 kw-barrier)
                  (entry "member/c" site-c 1 kw-barrier))
                (list
                  ;; member/c's :barrier selector has no group.
                  (group "members/outsider"
                         (list (selector "member/a" site-a 1)
                               (selector "member/b" site-b 1))))))
            (jolt= before (snapshot)))))
    (let ((before (snapshot)))
      (ok "a grouped selector absent from the plan is rejected"
          (and
            (error-result?
              (install!
                (list (entry "member/a" site-a 1 kw-barrier))
                (list
                  (group "members/missing-plan"
                         (list (selector "member/a" site-a 1)
                               (selector "member/b" site-b 1))))))
            (jolt= before (snapshot)))))
    (let ((before (snapshot)))
      (ok "a grouped non-barrier plan selector is rejected"
          (and
            (error-result?
              (install!
                (list
                  (entry "member/a" site-a 1 kw-continue)
                  (entry "member/b" site-b 1 kw-barrier))
                (list
                  (group "members/non-barrier"
                         (list (selector "member/a" site-a 1)
                               (selector "member/b" site-b 1))))))
            (jolt= before (snapshot)))))
    (let ((before (snapshot)))
      (ok "a barrier selector in two groups is rejected"
          (and
            (error-result?
              (install!
                (list
                  (entry "member/a" site-a 1 kw-barrier)
                  (entry "member/b" site-b 1 kw-barrier)
                  (entry "member/c" site-c 1 kw-barrier))
                (list
                  (group "members/one"
                         (list (selector "member/a" site-a 1)
                               (selector "member/b" site-b 1)))
                  (group "members/two"
                         (list (selector "member/a" site-a 1)
                               (selector "member/c" site-c 1))))))
            (jolt= before (snapshot)))))
    (let ((before (snapshot)))
      (ok "duplicate actor membership is rejected without publication"
          (and
            (error-result?
              (install!
                (list (entry "member/a" site-a 1 kw-barrier))
                (list
                  (group "members/duplicate"
                         (list (selector "member/a" site-a 1)
                               (selector "member/a" site-a 1))))))
            (jolt= before (snapshot)))))

    (let ((before (snapshot)))
      (ok "barrier selectors require canonical actor/id/hit order"
          (and
            (error-result?
              (install!
                (list
                  (entry "member/a" site-a 1 kw-barrier)
                  (entry "member/b" site-b 1 kw-barrier))
                (list
                  (group "members/out-of-order"
                         (list (selector "member/b" site-b 1)
                               (selector "member/a" site-a 1))))))
            (jolt= before (snapshot)))))))

(define (history-duplicate-arrival)
  (jolt-checkpoint-reset!)
  (let ((site-a1 "test.barrier/duplicate-a1")
        (site-a2 "test.barrier/duplicate-a2")
        (site-b "test.barrier/duplicate-b"))
    (register-barrier-site! site-a1)
    (register-barrier-site! site-a2)
    (register-barrier-site! site-b)
    (let ((before (snapshot)))
      (ok "one actor cannot own two arrivals in the same barrier round"
          (and
            (error-result?
              (install!
                (list
                  (entry "duplicate/a" site-a1 1 kw-barrier)
                  (entry "duplicate/a" site-a2 1 kw-barrier)
                  (entry "duplicate/b" site-b 1 kw-barrier))
                (list
                  (group "duplicate/round"
                         (list (selector "duplicate/a" site-a1 1)
                               (selector "duplicate/a" site-a2 1)
                               (selector "duplicate/b" site-b 1))))))
            (jolt= before (snapshot)))))))

(define (history-round-isolation)
  (jolt-checkpoint-reset!)
  (let* ((a1 "test.barrier/round-a1")
         (b1 "test.barrier/round-b1")
         (a2 "test.barrier/round-a2")
         (b2 "test.barrier/round-b2")
         (b-round2-returned (counter)))
    (for-each register-barrier-site! (list a1 b1 a2 b2))
    (let* ((setup
             (install!
               (list
                 (entry "round/a" a1 1 kw-barrier)
                 (entry "round/b" b1 1 kw-barrier)
                 (entry "round/a" a2 1 kw-barrier)
                 (entry "round/b" b2 1 kw-barrier))
               (list
                 (group "round/shared-1"
                        (list (selector "round/a" a1 1)
                              (selector "round/b" b1 1)))
                 (group "round/shared-2"
                        (list (selector "round/a" a2 1)
                              (selector "round/b" b2 1))))))
           (a (thread-result
                (lambda ()
                  (jolt-checkpoint-bind-actor! "round/a")
                  (barrier-hit a1)
                  ;; Hold A out of the second explicit barrier ID until main
                  ;; has observed B parked.
                  (let loop ()
                    (when (< (trace-count) 3)
                      (sleep (make-time 'time-duration 1000000 0))
                      (loop)))
                  (barrier-hit a2))))
           (b (thread-result
                (lambda ()
                  (jolt-checkpoint-bind-actor! "round/b")
                  (barrier-hit b1)
                  (barrier-hit b2)
                  (counter-inc! b-round2-returned)))))
      (ok "two explicit barrier IDs provide isolated generation-local rounds"
          (ok-result? setup))
      (ok "second-round first arrival becomes observable" (await-trace-count 3))
      (ok "the first barrier ID cannot release the second one"
          (= 0 (counter-value b-round2-returned)))
      (let ((ar (thread-result-await a))
            (br (thread-result-await b))
            (trace (trace-of (snapshot))))
        (ok "matching round-2 arrival releases both actors"
            (and (ok-result? ar) (ok-result? br)
                 (= 1 (counter-value b-round2-returned))))
        (ok "two rounds publish four arrivals with no cross-round duplicate"
            (and (= 4 (pvec-count trace))
                 (equal? '(1 2 3 4)
                         (map (lambda (e) (jolt-get e kw-seq))
                              (vector->list (pvec-v trace))))))))))

(define (history-reset-wakes)
  (jolt-checkpoint-reset!)
  (let* ((site-a "test.barrier/reset-a")
         (site-b "test.barrier/reset-b"))
    (register-barrier-site! site-a)
    (register-barrier-site! site-b)
    (let* ((setup
             (install!
               (list
                 (entry "reset/a" site-a 1 kw-barrier)
                 (entry "reset/b" site-b 1 kw-barrier))
               (list
                 (group "reset/pending"
                        (list (selector "reset/a" site-a 1)
                              (selector "reset/b" site-b 1))))))
           (waiter
             (thread-result
               (lambda ()
                 (jolt-checkpoint-bind-actor! "reset/a")
                 (barrier-hit site-a)))))
      (ok "reset history manifest installs" (ok-result? setup))
      (ok "pending barrier arrival publishes before it parks" (await-trace-count 1))
      (let ((old (snapshot)))
        (jolt-checkpoint-reset!)
        (let ((wr (thread-result-await waiter))
              (fresh (snapshot)))
          (ok "reset wakes a stale barrier waiter with failure"
              (error-result? wr))
          (ok "reset wake consumes no extra old-generation event"
              (and (= 1 (pvec-count (trace-of old)))
                   (= 2 (jolt-get old kw-next-seq))))
          (ok "fresh generation starts with no inherited hit, seq, or event"
              (and (= 0 (pvec-count (trace-of fresh)))
                   (= 1 (jolt-get fresh kw-next-seq)))))))))

;; Cancellation breaks a pending barrier rather than silently shrinking its
;; quorum. Fault remains a catchable, nonterminal action and is intentionally
;; not treated as a barrier-break history here.
(define (history-cancel-break)
  (jolt-checkpoint-reset!)
  (let* ((site-a "test.barrier/cancel-wait")
         (site-b "test.barrier/cancel-terminal")
         (site-c "test.barrier/cancel-breaker")
         (actor-a "cancel/waiter")
         (actor-b "cancel/peer")
         (barrier-id "cancel/broken"))
    (register-barrier-site! site-a)
    (register-barrier-site! site-b)
    (jolt-checkpoint-register-site! site-c '(continue cancel))
    (let* ((setup
             (install!
               (list
                 (entry actor-a site-a 1 kw-barrier)
                 (entry actor-b site-b 1 kw-barrier)
                 ;; The expected peer cancels at an earlier, separate
                 ;; occurrence instead of reaching its barrier selector. The
                 ;; cancel selector is not itself a barrier member.
                 (entry actor-b site-c 1 kw-cancel))
               (list
                 (group barrier-id
                        (list (selector actor-a site-a 1)
                              (selector actor-b site-b 1))))))
           (waiter
             (thread-result
               (lambda ()
                 (jolt-checkpoint-bind-actor! actor-a)
                 (barrier-hit site-a)))))
      (ok "cancel-break manifest installs" (ok-result? setup))
      (ok "cancel-break observes the pending exact quorum"
          (await-trace-count 1))
      (jolt-checkpoint-bind-actor! actor-b)
      (let ((cancel-result
              (attempt-unwrapped
                (lambda ()
                  (jolt-checkpoint! site-c '(continue cancel)))))
            (waiter-result (thread-result-await waiter))
            (trace (trace-of (snapshot))))
        (ok "cancel remains a terminal action"
            (error-result? cancel-result))
        (ok "cancel breaks rather than shrinks the quorum"
            (error-result? waiter-result))
        (ok "cancel-break publishes no synthetic arrival/release event"
            (and (= 2 (pvec-count trace))
                 (eq? kw-barrier (jolt-get (event-at trace 0) kw-action))
                 (eq? kw-cancel (jolt-get (event-at trace 1) kw-action))))))))

(define history
  (let ((args (command-line)))
    (if (> (length args) 1) (cadr args) "")))

(cond
  ((string=? history "fiber") (history-one-carrier-fibers))
  ((string=? history "threads") (history-os-threads))
  ((string=? history "membership") (history-exact-membership))
  ((string=? history "duplicate") (history-duplicate-arrival))
  ((string=? history "rounds") (history-round-isolation))
  ((string=? history "reset") (history-reset-wakes))
  ((string=? history "cancel-break") (history-cancel-break))
  (else (error 'checkpoint-barrier-red-test "unknown history" history)))

(if (= fails 0)
    (printf "checkpoint barrier ~a: ~a checks passed\n" history total)
    (begin
      (printf "checkpoint barrier ~a: ~a/~a checks FAILED\n"
              history fails total)
      (exit 1)))
