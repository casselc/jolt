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
(define kw-generation (keyword #f "generation"))
(define kw-seq (keyword #f "seq"))
(define kw-actor (keyword #f "actor"))
(define kw-id (keyword #f "id"))
(define kw-hit (keyword #f "hit"))
(define kw-action (keyword #f "action"))
(define kw-barrier (keyword #f "barrier"))
(define kw-continue (keyword #f "continue"))
(define kw-cancel (keyword #f "cancel"))
(define kw-fault (keyword #f "fault"))
(define kw-reset (keyword #f "reset"))
(define kw-barrier-broken (keyword #f "barrier-broken"))
(define kw-error-type (keyword "jolt.checkpoint" "type"))
(define kw-error-generation (keyword "jolt.checkpoint" "generation"))
(define kw-error-seq (keyword "jolt.checkpoint" "seq"))
(define kw-error-actor (keyword "jolt.checkpoint" "actor"))
(define kw-error-id (keyword "jolt.checkpoint" "id"))
(define kw-error-hit (keyword "jolt.checkpoint" "hit"))
(define kw-error-barrier-id (keyword "jolt.checkpoint" "barrier-id"))
(define kw-error-reason (keyword "jolt.checkpoint" "reason"))

(define (snapshot) (jolt-checkpoint-snapshot))
(define (trace-of s) (jolt-get s kw-trace))
(define (trace-count) (pvec-count (trace-of (snapshot))))
(define (event-at trace i) (pvec-nth! trace i))

(define (selector actor site hit)
  (jolt-vector actor site hit))

;; V1 keeps the occurrence plan flat and inert.  The separate barrier table
;; maps one explicit barrier ID to its exact selector vector.  Installation
;; must validate the complete table and preallocate every immutable,
;; generation-owned round object while checkpoint-controller-mu is held.  A
;; round is [generation barrier-id], selectors may name distinct sites, every
;; :barrier selector has exactly one group, and membership cannot be inferred
;; from timing or a site's local hit count.  Arrival and wait must use only the
;; preallocated round mutex plus the actor recorder/clock; reset gathers the
;; generation's preallocated round table while it owns the controller mutex.
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

(define (event-matches? event action actor site hit)
  (and (eq? action (jolt-get event kw-action))
       (string=? actor (jolt-get event kw-actor))
       (string=? site (jolt-get event kw-id))
       (= hit (jolt-get event kw-hit))))

(define (trace-contains? trace action actor site hit)
  (let loop ((i 0))
    (and (< i (pvec-count trace))
         (or (event-matches? (event-at trace i) action actor site hit)
             (loop (+ i 1))))))

(define (error-data result)
  (and (error-result? result)
       (jolt-ex-info-record? (cdr result))
       (jolt-ex-info-record-data (cdr result))))

;; A broken wait reports the identity of the already-published arrival plus the
;; generation-local round and terminal reason.  This is deliberately a data
;; contract rather than a message assertion, and reset/cancel create no event.
(define (barrier-broken-error? result generation barrier-id reason event)
  (let ((data (error-data result)))
    (and data
         (eq? kw-barrier-broken (jolt-get data kw-error-type))
         (= generation (jolt-get data kw-error-generation))
         (string=? barrier-id (jolt-get data kw-error-barrier-id))
         (eq? reason (jolt-get data kw-error-reason))
         (= (jolt-get event kw-seq) (jolt-get data kw-error-seq))
         (string=? (jolt-get event kw-actor) (jolt-get data kw-error-actor))
         (string=? (jolt-get event kw-id) (jolt-get data kw-error-id))
         (= (jolt-get event kw-hit) (jolt-get data kw-error-hit)))))

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

;; A condition-backed signal is only a test-owned progress witness.  Histories
;; use it to establish that setup completed or that a lock is held; no sleep is
;; used as synchronization.
(define (signal-cell)
  (let ((mu (make-mutex))
        (cv (make-condition))
        (value #f))
    (vector
      (lambda () (jolt-with-mutex mu value))
      (lambda (next)
        (jolt-with-mutex mu
          (set! value next)
          (condition-broadcast cv)))
      (lambda ()
        (let ((deadline (+ (now-ms) 3000)))
          (jolt-with-mutex mu
            (let loop ()
              (cond (value #t)
                    ((>= (now-ms) deadline) #f)
                    (else
                     (jolt-condition-wait
                       cv mu (jolt-millis->time deadline))
                     (loop))))))))))
(define (signal-cell-value c) ((vector-ref c 0)))
(define (signal-cell-set! c value) ((vector-ref c 1) value))
(define (signal-cell-await c) ((vector-ref c 2)))
(define (thread-result-done? result)
  (jolt-with-mutex (vector-ref result 0)
    ((vector-ref result 2))))

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

(define (history-controller-held-progress)
  ;; Install and bind first.  The holder then owns the controller mutex while
  ;; both established actors arrive.  Correct barrier arrival/release must
  ;; complete during that interval; waiting for the holder to release before
  ;; checking the results would make this history unable to distinguish a
  ;; controller-locking implementation from a round-local one.
  (jolt-checkpoint-reset!)
  (let* ((site-a "test.barrier/controller-held-a")
         (site-b "test.barrier/controller-held-b")
         (actor-a "controller-held/a")
         (actor-b "controller-held/b")
         (bound-a (signal-cell))
         (bound-b (signal-cell))
         (go (signal-cell))
         (held (signal-cell))
         (release (signal-cell))
         (released (counter)))
    (register-barrier-site! site-a)
    (register-barrier-site! site-b)
    (let* ((setup
             (install!
               (list (entry actor-a site-a 1 kw-barrier)
                     (entry actor-b site-b 1 kw-barrier))
               (list
                 (group "controller-held/shared"
                        (list (selector actor-a site-a 1)
                              (selector actor-b site-b 1))))))
           (a
             (thread-result
               (lambda ()
                 (jolt-checkpoint-bind-actor! actor-a)
                 (signal-cell-set! bound-a #t)
                 (signal-cell-await go)
                 (barrier-hit site-a)
                 (counter-inc! released))))
           (b
             (thread-result
               (lambda ()
                 (jolt-checkpoint-bind-actor! actor-b)
                 (signal-cell-set! bound-b #t)
                 (signal-cell-await go)
                 (barrier-hit site-b)
                 (counter-inc! released)))))
      (ok "controller-held manifest installs" (ok-result? setup))
      (ok "controller-held actors finish binding before the lock test"
          (and (signal-cell-await bound-a) (signal-cell-await bound-b)))
      ;; Create the holder only after both bind completions are observed.  If it
      ;; were forked alongside the actors, it could legitimately win the
      ;; controller mutex before their binds and create a scheduler-dependent
      ;; false failure unrelated to established-arrival progress.
      (let ((holder
              (thread-result
                (lambda ()
                  (jolt-with-mutex checkpoint-controller-mu
                    (signal-cell-set! held #t)
                    (signal-cell-await release))))))
        (ok "a separate thread holds checkpoint-controller-mu"
            (signal-cell-await held))
        (signal-cell-set! go #t)
        (let ((ar (thread-result-await a))
              (br (thread-result-await b)))
          (ok "established arrivals and release progress while controller is held"
              (and (ok-result? ar) (ok-result? br)
                   (= 2 (counter-value released))))
          (signal-cell-set! release #t)
          (ok "controller lock holder exits after the bounded progress check"
              (ok-result? (thread-result-await holder))))))))

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
      (ok "duplicate selector membership is rejected without publication"
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

(define (history-unique-actor-control)
  (jolt-checkpoint-reset!)
  (let ((site-a1 "test.barrier/duplicate-a1")
        (site-a2 "test.barrier/duplicate-a2")
        (site-b "test.barrier/duplicate-b"))
    (register-barrier-site! site-a1)
    (register-barrier-site! site-a2)
    (register-barrier-site! site-b)
    (let ((before (snapshot)))
      (ok "distinct selectors for one actor are rejected by the unique-actor control"
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

(define (history-fault-does-not-break)
  ;; The expected peer's fault is an earlier, separate occurrence.  Catching
  ;; it must leave that actor able to reach its later barrier occurrence, and
  ;; the other participant must remain pending until it does.
  (jolt-checkpoint-reset!)
  (let* ((site-a "test.barrier/fault-wait")
         (site-fault "test.barrier/fault-earlier")
         (site-b "test.barrier/fault-barrier")
         (actor-a "fault/a")
         (actor-b "fault/b")
         (barrier-id "fault/shared"))
    (register-barrier-site! site-a)
    (jolt-checkpoint-register-site! site-fault '(continue fault))
    (register-barrier-site! site-b)
    (let* ((setup
             (install!
               (list
                 (entry actor-a site-a 1 kw-barrier)
                 (entry actor-b site-fault 1 kw-fault)
                 (entry actor-b site-b 1 kw-barrier))
               (list
                 (group barrier-id
                        (list (selector actor-a site-a 1)
                              (selector actor-b site-b 1))))))
           (waiter
             (thread-result
               (lambda ()
                 (jolt-checkpoint-bind-actor! actor-a)
                 (barrier-hit site-a)))))
      (ok "fault-does-not-break manifest installs" (ok-result? setup))
      (ok "fault history publishes the first participant arrival"
          (await-trace-count 1))
      (let* ((fault-seen (signal-cell))
             (proceed (signal-cell))
             (peer
               (thread-result
                 (lambda ()
                   (jolt-checkpoint-bind-actor! actor-b)
                   (let ((fault-result
                           (attempt-unwrapped
                             (lambda ()
                               (jolt-checkpoint!
                                 site-fault '(continue fault))))))
                     (signal-cell-set! fault-seen fault-result)
                     (signal-cell-await proceed)
                     (barrier-hit site-b))))))
        (ok "expected peer fault is catchable at its earlier occurrence"
            (and (signal-cell-await fault-seen)
                 (error-result? (signal-cell-value fault-seen))))
        (let ((trace (trace-of (snapshot))))
          (ok "caught fault leaves the barrier waiter pending"
              (and (= 2 (pvec-count trace))
                   (barrier-event? (event-at trace 0) actor-a site-a 1 1)
                   (event-matches? (event-at trace 1) kw-fault
                                   actor-b site-fault 1)
                   (not (thread-result-done? waiter)))))
        (signal-cell-set! proceed #t)
        (let ((wr (thread-result-await waiter))
              (pr (thread-result-await peer))
              (trace (trace-of (snapshot))))
          (ok "same actor reaches the later barrier and releases the waiter"
              (and (ok-result? wr) (ok-result? pr)
                   (= 3 (pvec-count trace))
                   (barrier-event? (event-at trace 2) actor-b site-b 1 3))))))))

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
          (ok "reset wakes a stale waiter with canonical barrier-broken data"
              (and (= 1 (pvec-count (trace-of old)))
                   (barrier-broken-error?
                     wr (jolt-get old kw-generation) "reset/pending" kw-reset
                     (event-at (trace-of old) 0))))
          (ok "reset wake consumes no extra old-generation event"
              (and (= 1 (pvec-count (trace-of old)))
                   (= 2 (jolt-get old kw-next-seq))))
          (ok "fresh generation starts with no inherited hit, seq, or event"
              (and (= 0 (pvec-count (trace-of fresh)))
                   (= 1 (jolt-get fresh kw-next-seq)))))))))

;; Cancellation breaks every pending barrier group containing the cancelled
;; actor rather than silently shrinking any quorum.  The cancel occurrence is
;; separate from both expected barrier occurrences, so one sticky decision can
;; be checked against two simultaneously parked groups without synthetic
;; arrivals or releases.
(define (history-cancel-break)
  (jolt-checkpoint-reset!)
  (let* ((site-a "test.barrier/cancel-wait")
         (site-b1 "test.barrier/cancel-peer-one")
         (site-c "test.barrier/cancel-wait-two")
         (site-b2 "test.barrier/cancel-peer-two")
         (site-d "test.barrier/cancel-late-wait")
         (site-b3 "test.barrier/cancel-peer-three")
         (site-cancel "test.barrier/cancel-earlier")
         (actor-a "cancel/waiter-one")
         (actor-b "cancel/peer")
         (actor-c "cancel/waiter-two")
         (actor-d "cancel/waiter-late")
         (barrier-id-one "cancel/broken-one")
         (barrier-id-two "cancel/broken-two")
         (barrier-id-three "cancel/broken-three"))
    (register-barrier-site! site-a)
    (register-barrier-site! site-b1)
    (register-barrier-site! site-c)
    (register-barrier-site! site-b2)
    (register-barrier-site! site-d)
    (register-barrier-site! site-b3)
    (jolt-checkpoint-register-site! site-cancel '(continue cancel))
    (let* ((setup
             (install!
               (list
                 (entry actor-a site-a 1 kw-barrier)
                 (entry actor-b site-b1 1 kw-barrier)
                 (entry actor-c site-c 1 kw-barrier)
                 (entry actor-b site-b2 1 kw-barrier)
                 (entry actor-d site-d 1 kw-barrier)
                 (entry actor-b site-b3 1 kw-barrier)
                 ;; The expected peer cancels at an earlier, separate
                 ;; occurrence instead of reaching either barrier selector.
                 (entry actor-b site-cancel 1 kw-cancel))
               (list
                 (group barrier-id-one
                        (list (selector actor-a site-a 1)
                              (selector actor-b site-b1 1)))
                 (group barrier-id-two
                        (list (selector actor-c site-c 1)
                              (selector actor-b site-b2 1)))
                 (group barrier-id-three
                        (list (selector actor-d site-d 1)
                              (selector actor-b site-b3 1))))))
           (waiter-one
             (thread-result
               (lambda ()
                 (jolt-checkpoint-bind-actor! actor-a)
                 (barrier-hit site-a))))
           (waiter-two
             (thread-result
               (lambda ()
                 (jolt-checkpoint-bind-actor! actor-c)
                 (barrier-hit site-c)))))
      (ok "cancel-break manifest installs" (ok-result? setup))
      (ok "cancel-break observes both pending exact quorums"
          (await-trace-count 2))
      (jolt-checkpoint-bind-actor! actor-b)
      (let ((cancel-result
              (attempt-unwrapped
                (lambda ()
                  (jolt-checkpoint! site-cancel '(continue cancel)))))
            (waiter-one-result (thread-result-await waiter-one))
            (waiter-two-result (thread-result-await waiter-two)))
        (ok "cancel remains a terminal action"
            (error-result? cancel-result))
        (let* ((before-late (snapshot))
               (before-trace (trace-of before-late))
               (generation (jolt-get before-late kw-generation))
               (late
                 (thread-result
                   (lambda ()
                     (jolt-checkpoint-bind-actor! actor-d)
                     (barrier-hit site-d))))
               (late-result (thread-result-await late))
               (trace (trace-of (snapshot))))
          (ok "one sticky cancel breaks and wakes both arrived groups"
              (and (= 3 (pvec-count before-trace))
                   (barrier-broken-error?
                     waiter-one-result generation barrier-id-one kw-cancel
                     (event-at before-trace 0))
                   (barrier-broken-error?
                     waiter-two-result generation barrier-id-two kw-cancel
                     (event-at before-trace 1))))
          (ok "an expected actor arriving after cancel observes the broken round"
              (and (= 4 (pvec-count trace))
                   (barrier-broken-error?
                     late-result generation barrier-id-three kw-cancel
                     (event-at trace 3))))
          (ok "cancel-break publishes only two early arrivals, cancel, and late arrival"
              (and (= 4 (pvec-count trace))
                   (trace-contains? trace kw-barrier actor-a site-a 1)
                   (trace-contains? trace kw-barrier actor-c site-c 1)
                   (trace-contains? trace kw-cancel actor-b site-cancel 1)
                   (trace-contains? trace kw-barrier actor-d site-d 1))))))))

(define history
  (let ((args (command-line)))
    (if (> (length args) 1) (cadr args) "")))

(cond
  ((string=? history "fiber") (history-one-carrier-fibers))
  ((string=? history "threads") (history-os-threads))
  ((string=? history "membership") (history-exact-membership))
  ((string=? history "unique-actor") (history-unique-actor-control))
  ((string=? history "rounds") (history-round-isolation))
  ((string=? history "controller-held") (history-controller-held-progress))
  ((string=? history "fault") (history-fault-does-not-break))
  ((string=? history "reset") (history-reset-wakes))
  ((string=? history "cancel-break") (history-cancel-break))
  (else (error 'checkpoint-barrier-red-test "unknown history" history)))

(if (= fails 0)
    (printf "checkpoint barrier ~a: ~a checks passed\n" history total)
    (begin
      (printf "checkpoint barrier ~a: ~a/~a checks FAILED\n"
              history fails total)
      (exit 1)))
