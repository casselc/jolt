;; fibers-publication-test.ss -- lazy realization across a fiber park.
;;
;; A counted runtime mutex may protect only short, runtime-owned transitions.
;; Both force-lazyseq and a cseq tail execute arbitrary user code, so their
;; once/publication boundary must retain logical ownership while letting a
;; fiber park with zero counted locks held.  This gate covers the two minimal
;; regressions plus the cache/reentry policies that the repair must preserve.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n" name)))

(define (ev s) (jolt-compile-eval s "user"))
(define (jv-nth v i) (pvec-nth-d v i jolt-nil))
(define (kw s) (keyword #f s))
(define (string-has? s needle)
  (let ((n (string-length s)) (m (string-length needle)))
    (let loop ((i 0))
      (and (<= (+ i m) n)
           (or (string=? (substring s i (+ i m)) needle)
               (loop (+ i 1)))))))

;; Use the real public fiber carrier through core.async's :fiber backend.  The
;; gate boot has no loader, so load the additive async overlay explicitly.
(define overlay-src
  (call-with-input-file "stdlib/clojure/core/async.clj"
    (lambda (p)
      (let loop ((acc '()))
        (let ((c (read-char p)))
          (if (eof-object? c)
              (list->string (reverse acc))
              (loop (cons c acc))))))))
(jolt-load-string overlay-src)
(ev "(require '[clojure.core.async :refer [go <!! *go-backend*]])")

(printf "== fiber-safe lazy publication ==\n")

;; A contended gate is the only entry path that can park.  If a caller already
;; holds an unrelated counted lock, it must fail at the guarded boundary rather
;; than reaching the scheduler assertion.  Run this before the public carrier is
;; started by the go tests below so the manual drain cannot race it.
(printf "\n== 0. contended entry rejects an outer counted lock ==\n")
(define guarded-gate (jolt-publication-gate-new))
(define guarded-ready-mu (make-mutex))
(define guarded-ready-cv (make-condition))
(define guarded-ready? #f)
(define guarded-release-mu (make-mutex))
(define guarded-release-cv (make-condition))
(define guarded-release? #f)
(jolt-fiber-carrier-count-set! 1)
(fork-thread
  (lambda ()
    (jolt-with-publication-gate guarded-gate
      (lambda ()
        (jolt-with-mutex guarded-ready-mu
          (set! guarded-ready? #t)
          (condition-broadcast guarded-ready-cv))
        (jolt-cv-wait guarded-release-mu guarded-release-cv #f
          (lambda (_) (if guarded-release? #t jolt-cv-again)))))))
(jolt-with-mutex guarded-ready-mu
  (let loop ()
    (unless guarded-ready?
      (jolt-condition-wait guarded-ready-cv guarded-ready-mu)
      (loop))))
(define guarded-outer (make-mutex))
(define guarded-error #f)
(define guarded-fiber
  (sa-fiber-spawn
    (lambda ()
      (guard (e (#t (set! guarded-error e) 'rejected))
        (jolt-with-mutex guarded-outer
          (jolt-publication-gate-enter! guarded-gate))
        'unexpected-entry))))
(sa-fiber-run-all)
(ok "contended gate under outer lock fails without parking"
    (and (eq? (jolt-fiber-state guarded-fiber) 'done)
         (eq? (jolt-fiber-result guarded-fiber) 'rejected)))
(ok "failure names the guarded publication boundary"
    (and (condition? guarded-error)
         (eq? (condition-who guarded-error) 'jolt-publication-gate-wait!)
         (let ((s (condition-message guarded-error)))
           (and (string? s) (string-has? s "counted lock")))))
(define busy-terminal
  (make-jolt-lazyseq (lambda () (error 'busy-terminal "must not run"))
                     42 #t #f guarded-gate))
(define busy-terminal-fiber
  (sa-fiber-spawn (lambda () (force-lazyseq busy-terminal))))
(sa-fiber-run-all)
;; A timer preemption may leave a manually-drained fiber ready between the
;; acquire and its wait; keep draining that runnable state to the boundary.
(let loop ((n 0))
  (when (and (< n 100) (eq? (jolt-fiber-state busy-terminal-fiber) 'ready))
    (sa-fiber-run-all)
    (loop (+ n 1))))
(ok "terminal fast path does not bypass a busy publisher"
    (eq? (jolt-fiber-state busy-terminal-fiber) 'parked))
(jolt-with-mutex guarded-release-mu
  (set! guarded-release? #t)
  (jolt-cv-wake! guarded-release-cv))
;; The owner thread exits the gate promptly after this wake; wait until its
;; release has resumed the contender before manually draining it.
(let loop ((n 0))
  (when (and (< n 500)
             (eq? (jolt-fiber-state busy-terminal-fiber) 'parked))
    (sleep (make-time 'time-duration 1000000 0))
    (loop (+ n 1))))
(let loop ((n 0))
  (when (and (< n 100) (eq? (jolt-fiber-state busy-terminal-fiber) 'ready))
    (sa-fiber-run-all)
    (loop (+ n 1))))
(ok "terminal waiter resumes after publication release"
    (eq? (jolt-fiber-state busy-terminal-fiber) 'done))
(ok "terminal waiter reads the published payload"
    (and (eq? (jolt-fiber-state busy-terminal-fiber) 'done)
         (= (jolt-fiber-result busy-terminal-fiber) 42)))

;; Exact #18 shape. mapv realizes (apply map ...) while building its vector;
;; the mapped deref must be allowed to park.
(printf "\n== 1. mapv may deref a pending promise on a fiber ==\n")
(define mapv-result
  (ev "
(binding [*go-backend* :fiber]
  (let [p (promise)
        g (go (mapv deref [p]))
        d (future (Thread/sleep 20) (deliver p :ok))]
    @d
    (<!! g)))"))
(ok "mapv result has one element" (= (jolt-count mapv-result) 1))
(ok "mapv pending deref resumed with its value"
    (jolt=2 (jv-nth mapv-result 0) (kw "ok")))

;; Metadata copying used to manufacture the old mutex-shaped lock slot.  Once
;; multi-thread mode was active, forcing the copy treated that mutex as a gate
;; vector and crashed.  A copy starts with no gate and allocates one lazily.
(define metadata-copy-result
  (ev "
(do
  @(future :mt-enabled)
  (let [source (lazy-seq (list :copied))
        copied (with-meta source {:origin :test})]
    [(first copied) (:origin (meta copied)) (first source)]))"))
(ok "metadata copy of lazyseq forces after multi-thread activation"
    (jolt=2 (jv-nth metadata-copy-result 0) (kw "copied")))
(ok "metadata remains attached to the copy"
    (jolt=2 (jv-nth metadata-copy-result 1) (kw "test")))
(ok "source remains independently forceable"
    (jolt=2 (jv-nth metadata-copy-result 2) (kw "copied")))

;; A non-chunked map reaches the separate cseq tail publication site before
;; dereferencing the second element.
(printf "\n== 2. a cseq tail may deref a pending promise on a fiber ==\n")
(define cseq-result
  (ev "
(binding [*go-backend* :fiber]
  (let [ready (doto (promise) (deliver :ready))
        pending (promise)
        g (go (second (map deref (list ready pending))))
        d (future (Thread/sleep 20) (deliver pending :tail))]
    @d
    (<!! g)))"))
(ok "cseq tail pending deref resumed with its value"
    (jolt=2 cseq-result (kw "tail")))

;; The owner announces entry immediately before the pending deref.  A sibling
;; must run on the same single carrier before the main thread releases it.
(printf "\n== 3. parked realization releases its carrier ==\n")
(define progress-result
  (ev "
(binding [*go-backend* :fiber]
  (let [started (promise)
        release (promise)
        ran (atom false)
        s (lazy-seq (deliver started true) @release (list :done))
        owner (go (first s))]
    @started
    (let [sibling (go (reset! ran true))]
      (Thread/sleep 50)
      (let [before @ran]
        (deliver release true)
        [before (<!! sibling) (<!! owner)]))))"))
(ok "sibling ran while realization owner was parked" (eq? (jv-nth progress-result 0) #t))
(ok "sibling completed" (eq? (jv-nth progress-result 1) #t))
(ok "parked owner resumed" (jolt=2 (jv-nth progress-result 2) (kw "done")))

;; One fiber owns a parked realization while a second fiber and an OS thread
;; contend.  All observe the same publication and the body executes once.
(printf "\n== 4. concurrent realization executes once ==\n")
(define once-result
  (ev "
(binding [*go-backend* :fiber]
  (let [started (promise)
        release (promise)
        calls (atom 0)
        s (lazy-seq
            (deliver started true)
            @release
            (swap! calls inc)
            (list :value))
        owner (go (first s))]
    @started
    (let [fiber-waiter (go (first s))
          thread-waiter (future (first s))]
      (deliver release true)
      [(<!! owner) (<!! fiber-waiter) @thread-waiter @calls])))"))
(ok "owner received publication" (jolt=2 (jv-nth once-result 0) (kw "value")))
(ok "fiber waiter received publication" (jolt=2 (jv-nth once-result 1) (kw "value")))
(ok "thread waiter received publication" (jolt=2 (jv-nth once-result 2) (kw "value")))
(ok "lazy realization body ran exactly once" (= (jv-nth once-result 3) 1))

;; Lazyseq caches the thrown object.  Contenders must wake and rethrow that
;; same object without re-running the body.
(printf "\n== 5. lazy realization keeps cached-error policy ==\n")
(define error-result
  (ev "
(binding [*go-backend* :fiber]
  (let [started (promise)
        release (promise)
        calls (atom 0)
        boom (ex-info \"boom\" {:kind :expected})
        s (lazy-seq
            (deliver started true)
            @release
            (swap! calls inc)
            (throw boom))
        force #(try (first s) (catch Exception e e))
        owner (go (force))]
    @started
    (let [fiber-waiter (go (force))
          thread-waiter (future (force))]
      (deliver release true)
      (let [a (<!! owner) b (<!! fiber-waiter) c @thread-waiter]
        [(identical? boom a) (identical? a b) (identical? b c) @calls]))))"))
(ok "owner observed the original throwable" (eq? (jv-nth error-result 0) #t))
(ok "fiber waiter observed identical cached throwable" (eq? (jv-nth error-result 1) #t))
(ok "thread waiter observed identical cached throwable" (eq? (jv-nth error-result 2) #t))
(ok "throwing lazy body ran exactly once" (= (jv-nth error-result 3) 1))

;; Current Jolt permits same-owner recursive realization.  The nested call may
;; produce a candidate, but only outermost exit publishes to other owners.
(printf "\n== 6. same-owner recursive realization parity ==\n")
(define recursive-result
  (ev "
(let [calls (atom 0)
      holder (atom nil)
      s (lazy-seq
          (if (= 1 (swap! calls inc))
            (do (seq @holder) (list :outer))
            (list :inner)))]
  (reset! holder s)
  [(first s) @calls])"))
(ok "outermost recursive realization remains the published value"
    (jolt=2 (jv-nth recursive-result 0) (kw "outer")))
(ok "recursive realization remains reentrant" (= (jv-nth recursive-result 1) 2))

;; cseq intentionally differs from lazyseq: a throwing tail is not marked
;; forced, so a later force retries it.  Exercise the host record directly to
;; keep this policy separate from a surrounding lazyseq's cached exception.
(printf "\n== 7. cseq tail keeps retry-on-error policy ==\n")
(jolt-mark-mt!)
(define cseq-calls 0)
(define retry-cell
  (make-cseq 1
             (lambda ()
               (set! cseq-calls (+ cseq-calls 1))
               (if (= cseq-calls 1)
                   (error 'expected "first tail attempt")
                   jolt-empty-list))
             #f 'list #f 0 #f #f))
(define first-threw?
  (guard (c (else #t))
    (seq-more retry-cell)
    #f))
(define retry-value (seq-more retry-cell))
(ok "first cseq tail failure escapes" first-threw?)
(ok "cseq tail retries after failure" (= cseq-calls 2))
(ok "successful retry publishes the tail" (eq? retry-value jolt-empty-list))
(ok "published cseq tail is stable" (eq? (seq-more retry-cell) jolt-empty-list))
(ok "stable cseq tail does not execute again" (= cseq-calls 2))

(printf "\nfibers-publication-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "fibers-publication-test: PASS\n") (exit 0))
    (exit 1))
