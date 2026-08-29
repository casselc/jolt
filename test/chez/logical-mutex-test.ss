;; logical-mutex-test.ss -- execution-context-owned reentrant mutex core.
;;
;; This is the minimal #27 slice: one unbounded, uninterruptible contention
;; boundary; no deadlines, interrupts, conditions, or public Java surface.  The
;; tests drive the internal primitive directly so later consumers inherit a
;; pinned ownership/unwind/publication contract rather than a convenient shape.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n" name)))

(define (string-has? s needle)
  (and (string? s)
       (let ((n (string-length s)) (m (string-length needle)))
         (let loop ((i 0))
           (and (<= (+ i m) n)
                (or (string=? (substring s i (+ i m)) needle)
                    (loop (+ i 1))))))))

;; A bounded thread result cell.  The timeout is a gate watchdog, never the
;; synchronization mechanism: completion is published and consumed under mu.
(define (thread-result thunk)
  (let ((mu (make-mutex)) (cv (make-condition)) (done? #f) (value #f) (raised #f))
    (fork-thread
      (lambda ()
        (guard (e (#t (jolt-with-mutex mu
                         (set! raised e) (set! done? #t) (condition-broadcast cv))))
          (let ((v (thunk)))
            (jolt-with-mutex mu
              (set! value v) (set! done? #t) (condition-broadcast cv))))))
    (vector mu cv (lambda () done?) (lambda () value) (lambda () raised))))

(define (thread-result-await tr)
  (let ((deadline (+ (now-millis) 10000)))
    (jolt-with-mutex (vector-ref tr 0)
      (let loop ()
        (unless ((vector-ref tr 2))
          (when (>= (now-millis) deadline)
            (error 'logical-mutex-test "thread watchdog expired"))
          (jolt-condition-wait (vector-ref tr 1) (vector-ref tr 0)
                               (jolt-millis->time deadline))
          (loop))))
    (let ((e ((vector-ref tr 4))))
      (if e (raise e) ((vector-ref tr 3))))))

(printf "== logical mutex: thread identity, reentrancy, and inspection ==\n")
(define lm1 (jolt-logical-mutex-new))
(ok "fresh mutex is unlocked" (not (jolt-logical-mutex-locked? lm1)))
(ok "fresh mutex is not held by self" (not (jolt-logical-mutex-held-by-self? lm1)))
(ok "fresh mutex has zero self hold count" (= 0 (jolt-logical-mutex-hold-count lm1)))
(jolt-logical-mutex-enter! lm1)
(ok "enter establishes self ownership" (jolt-logical-mutex-held-by-self? lm1))
(ok "logical body holds no counted Chez mutex" (= 0 (jolt-locks-held)))
(ok "first enter has depth one" (= 1 (jolt-logical-mutex-hold-count lm1)))
(ok "same thread try-enter is reentrant" (jolt-logical-mutex-try-enter! lm1))
(ok "reentry increments depth" (= 2 (jolt-logical-mutex-hold-count lm1)))
(define other-view
  (thread-result
    (lambda ()
      (vector (jolt-logical-mutex-try-enter! lm1)
              (jolt-logical-mutex-held-by-self? lm1)
              (jolt-logical-mutex-hold-count lm1)
              (jolt-logical-mutex-locked? lm1)))))
(define ov (thread-result-await other-view))
(ok "a forked thread has a distinct stable owner identity"
    (and (not (vector-ref ov 0))
         (not (vector-ref ov 1))
         (= 0 (vector-ref ov 2))
         (vector-ref ov 3)))
(jolt-logical-mutex-exit! lm1)
(ok "nested exit preserves outer ownership" (= 1 (jolt-logical-mutex-hold-count lm1)))
(jolt-logical-mutex-exit! lm1)
(ok "outer exit clears ownership" (not (jolt-logical-mutex-locked? lm1)))
(ok "non-owner exit raises"
    (guard (e (#t (eq? (condition-who e) 'jolt-logical-mutex-exit!)))
      (jolt-logical-mutex-exit! lm1)
      #f))

;; Uncontended entry cannot switch and is therefore legal under an unrelated
;; counted lock.  Only the contended boundary refuses that shape.
(define lm1b (jolt-logical-mutex-new))
(define lm1b-outer (make-mutex))
(ok "uncontended claim is legal under a counted transition lock"
    (jolt-with-mutex lm1b-outer
      (let ((got (jolt-logical-mutex-try-enter! lm1b)))
        (when got (jolt-logical-mutex-exit! lm1b))
        got)))
;; Mutation teeth for the body-spanning API.  The body does not park: deleting
;; the scoped helper's up-front assertion therefore makes this return normally
;; and fail the row, instead of merely moving the error to a later switch point.
(define lm1b-scoped-error #f)
(guard (e (#t (set! lm1b-scoped-error e)))
  (jolt-with-mutex lm1b-outer
    (jolt-with-logical-mutex lm1b (lambda () 'must-not-run))))
(ok "scoped arbitrary body rejects even an uncontended counted outer lock"
    (and (condition? lm1b-scoped-error)
         (eq? (condition-who lm1b-scoped-error) 'jolt-with-logical-mutex)
         (string-has? (condition-message lm1b-scoped-error) "counted lock")))

(printf "\n== scoped return, throw, and continuation unwind ==\n")
(define lm2 (jolt-logical-mutex-new))
(ok "scoped return preserves body value"
    (= 42 (jolt-with-logical-mutex lm2 (lambda () 42))))
(ok "scoped return releases" (not (jolt-logical-mutex-locked? lm2)))
(define threw? #f)
(guard (e (#t (set! threw? #t)))
  (jolt-with-logical-mutex lm2 (lambda () (error 'lm2 "boom"))))
(ok "throw escapes the body" threw?)
(ok "throw releases" (not (jolt-logical-mutex-locked? lm2)))
(define escaped
  (sa-call-with-escape-continuation
    (lambda (escape)
      (jolt-with-logical-mutex lm2
        (lambda () (escape 'escaped) 'not-reached)))))
(ok "escape continuation returns through the scope" (eq? escaped 'escaped))
(ok "escape continuation releases" (not (jolt-logical-mutex-locked? lm2)))

;; A raw host continuation can be re-enterable even though jolt.continuations
;; deliberately exposes only one-shot inward escapes. Capture inside the body,
;; let the scope return and release, then try to rewind it. The dynamic-wind
;; before-thunk must reject before body code runs a second time or an after-thunk
;; attempts a second exit. This is the same retirement oracle as scoped FFI loans.
(define lm2-reentry (jolt-logical-mutex-new))
(define lm2-saved #f)
(define lm2-visits 0)
(define lm2-phase 0)
(define lm2-reentry-outcome
  (guard (e (#t (list 'raised (condition-message e) lm2-visits)))
    (let ((value
           (jolt-with-logical-mutex lm2-reentry
             (lambda ()
               (call/cc (lambda (k)
                          (unless lm2-saved (set! lm2-saved k))
                          'first))
               (set! lm2-visits (+ lm2-visits 1))
               'body-returned))))
      (if (= lm2-phase 0)
          (begin
            (set! lm2-phase 1)
            (lm2-saved 'again))
          (list 'returned value lm2-visits)))))
(ok "retired logical scope rejects host-continuation re-entry before body resumes"
    (and (eq? 'raised (car lm2-reentry-outcome))
         (string-has? (cadr lm2-reentry-outcome) "cannot be re-entered")
         (= 1 (caddr lm2-reentry-outcome))
         (not (jolt-logical-mutex-locked? lm2-reentry))))
(ok "retirement belongs to the dead scope, not the mutex"
    (let ((got (jolt-logical-mutex-try-enter! lm2-reentry)))
      (when got (jolt-logical-mutex-exit! lm2-reentry))
      got))

(printf "\n== release-before-registration and publication ==\n")
;; Deterministically widen enter!'s failed-try -> guarded-wait gap.  The owner
;; releases before the contender calls wait, so there is no wake to remember;
;; the contender must retake the decision and acquire immediately.  The payload
;; read is the acquire side of the same bookkeeping mutex publication edge.
(define lm3 (jolt-logical-mutex-new))
(define lm3-sync (make-mutex))
(define lm3-cv (make-condition))
(define lm3-tried? #f)
(define lm3-go? #f)
(define lm3-payload 0)
(jolt-logical-mutex-enter! lm3)
(define lm3-waiter
  (thread-result
    (lambda ()
      (let ((me (jolt-logical-mutex-self)))
        (unless (not (jolt-logical-mutex-try-enter/owner! lm3 me))
          (error 'lm3 "contender unexpectedly acquired"))
        (jolt-with-mutex lm3-sync
          (set! lm3-tried? #t)
          (condition-broadcast lm3-cv)
          (let loop ()
            (unless lm3-go?
              (jolt-condition-wait lm3-cv lm3-sync)
              (loop))))
        (jolt-logical-mutex-wait! lm3 me)
        (let ((seen lm3-payload))
          (jolt-logical-mutex-exit! lm3)
          seen)))))
(jolt-with-mutex lm3-sync
  (let loop ()
    (unless lm3-tried?
      (jolt-condition-wait lm3-cv lm3-sync)
      (loop))))
(set! lm3-payload 73)
(jolt-logical-mutex-exit! lm3)
(jolt-with-mutex lm3-sync
  (set! lm3-go? #t)
  (condition-broadcast lm3-cv))
(ok "release before waiter registration is not a lost wake"
    (= 73 (thread-result-await lm3-waiter)))
(ok "thread contender released after observing published payload"
    (not (jolt-logical-mutex-locked? lm3)))

(printf "\n== fiber park, contention, wake, and happens-before ==\n")
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)
(define lm4 (jolt-logical-mutex-new))
(define lm4-inside 0)
(define lm4-max 0)
(define lm4-payload 0)
(define lm4-seen #f)
(define lm4-owner
  (sa-fiber-spawn
    (lambda ()
      (jolt-with-logical-mutex lm4
        (lambda ()
          (set! lm4-inside (+ lm4-inside 1))
          (set! lm4-max (max lm4-max lm4-inside))
          (jolt-fiber-park!)
          (set! lm4-payload 99)
          (set! lm4-inside (- lm4-inside 1)))))))
(sa-fiber-run-all)
(ok "owner parked while retaining logical ownership"
    (and (eq? 'parked (jolt-fiber-state lm4-owner))
         (jolt-logical-mutex-locked? lm4)))
(define lm4-contender
  (sa-fiber-spawn
    (lambda ()
      (jolt-with-logical-mutex lm4
        (lambda ()
          (set! lm4-inside (+ lm4-inside 1))
          (set! lm4-max (max lm4-max lm4-inside))
          (set! lm4-seen lm4-payload)
          (set! lm4-inside (- lm4-inside 1)))))))
(sa-fiber-run-all)
(ok "contending fiber commits to a parked wait"
    (eq? 'parked (jolt-fiber-state lm4-contender)))
(ok "parked owner and contender never overlap" (= 1 lm4-max))
(sa-fiber-resume lm4-owner)
(let loop ((n 0))
  (when (and (< n 10)
             (or (not (memq (jolt-fiber-state lm4-owner) '(done dead)))
                 (not (memq (jolt-fiber-state lm4-contender) '(done dead)))))
    (sa-fiber-run-all)
    (loop (+ n 1))))
(ok "owner and woken contender both finish"
    (and (eq? 'done (jolt-fiber-state lm4-owner))
         (eq? 'done (jolt-fiber-state lm4-contender))))
(ok "woken contender observes owner's published write" (= 99 lm4-seen))
(ok "outermost fiber exit clears the mutex" (not (jolt-logical-mutex-locked? lm4)))

(printf "\n== contended boundary rejects a counted outer lock ==\n")
(define lm5 (jolt-logical-mutex-new))
(jolt-logical-mutex-enter! lm5)
(define lm5-outer (make-mutex))
(define lm5-error #f)
(define lm5-contender
  (sa-fiber-spawn
    (lambda ()
      (guard (e (#t (set! lm5-error e) 'rejected))
        (jolt-with-mutex lm5-outer (jolt-logical-mutex-enter! lm5))
        'unexpected))))
(sa-fiber-run-all)
(ok "contended entry under counted lock rejects without parking"
    (and (eq? 'done (jolt-fiber-state lm5-contender))
         (eq? 'rejected (jolt-fiber-result lm5-contender))))
(ok "rejection names the sole guarded boundary"
    (and (condition? lm5-error)
         (eq? (condition-who lm5-error) 'jolt-logical-mutex-wait!)
         (string-has? (condition-message lm5-error) "counted lock")))
(jolt-logical-mutex-exit! lm5)

(printf "\n== preemption preserves exclusion ==\n")
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)
(jolt-fiber-preempt-ticks-set! jolt-fiber-preempt-ticks-min)
(define lm6 (jolt-logical-mutex-new))
(define lm6-value 0)
(define lm6-inside 0)
(define lm6-max 0)
(define (lm6-spin n)
  (let loop ((i 0) (x 0))
    (if (fx=? i n) x (loop (fx+ i 1) (fx+ x i)))))
(define (lm6-worker)
  (let loop ((i 0))
    (when (< i 8)
      (jolt-with-logical-mutex lm6
        (lambda ()
          (set! lm6-inside (+ lm6-inside 1))
          (set! lm6-max (max lm6-max lm6-inside))
          (let ((v lm6-value))
            (lm6-spin 80000)
            (set! lm6-value (+ v 1)))
          (set! lm6-inside (- lm6-inside 1))))
      (loop (+ i 1)))))
(define lm6-before (jolt-fiber-preempts))
(define lm6-fibers
  (list (sa-fiber-spawn lm6-worker)
        (sa-fiber-spawn lm6-worker)
        (sa-fiber-spawn lm6-worker)))
(sa-fiber-run-all)
(ok "control: timer preemption occurred inside the workload"
    (> (jolt-fiber-preempts) lm6-before))
(ok "preempted logical critical sections never overlap" (= 1 lm6-max))
(ok "preempted increments are linearized" (= 24 lm6-value))
(ok "every preempted worker finishes"
    (let loop ((fs lm6-fibers))
      (or (null? fs)
          (and (eq? 'done (jolt-fiber-state (car fs))) (loop (cdr fs))))))

(printf "\n== terminal fiber unwind releases ==\n")
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)
(define lm7-ordinary (jolt-logical-mutex-new))
(define lm7-ordinary-a
  (sa-fiber-spawn
    (lambda ()
      (jolt-with-logical-mutex lm7-ordinary
        (lambda () (error 'lm7-ordinary "ordinary boom"))))))
(guard (e (#t #f)) (sa-fiber-run-all))
(ok "ordinary unguarded fiber death releases through normal unwind"
    (and (eq? 'dead (jolt-fiber-state lm7-ordinary-a))
         (not (jolt-logical-mutex-locked? lm7-ordinary))))

;; Drive the *production* CPS/cheap-park death path, not a test-local imitation.
;; jolt-sm-drive uses with-exception-handler so jolt-fiber-dead! clears the
;; current-fiber register before its escape unwinds this scope.  This is the
;; narrow terminal-owner arm; the ordinary spawn above goes through resume*'s
;; guard and releases while the fiber is still mounted.
(define lm7 (jolt-logical-mutex-new))
(define lm7-w (ac-make 1 'fixed #f))
(go-chan-register! lm7-w)
(define lm7-a
  (sa-fiber-spawn
    (lambda ()
      (jolt-sm-drive lm7-w
        (lambda (k)
          (jolt-with-logical-mutex lm7
            (lambda () (error 'lm7 "terminal boom"))))))))
(guard (e (#t #f)) (sa-fiber-run-all))
(ok "CPS-driver throwing fiber became terminal" (eq? 'dead (jolt-fiber-state lm7-a)))
(ok "terminal unwind cleared ownership after current-fiber was reset"
    (not (jolt-logical-mutex-locked? lm7)))
(define lm7-later #f)
(define lm7-b
  (sa-fiber-spawn
    (lambda ()
      (jolt-with-logical-mutex lm7 (lambda () (set! lm7-later #t))))))
(sa-fiber-run-all)
(ok "later fiber acquires after terminal unwind"
    (and lm7-later (eq? 'done (jolt-fiber-state lm7-b))))

(jolt-fiber-pool-reset!)
(printf "\nlogical-mutex-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "logical-mutex-test: PASS\n") (exit 0))
    (exit 1))
