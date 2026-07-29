;; Non-inheriting per-thread slots. Run:
;;   chez --script test/chez/thread-slot-test.ss
;;
;; Chez's make-thread-parameter hands a newly forked thread the parent's CURRENT
;; value, not the parameter's initial value. For dynamic context that is the
;; intended semantics. For a per-thread CACHE it is a correctness defect: a
;; parent that touches the slot before forking hands every child the same
;; mutable object.
;;
;; Every case here initializes on the PARENT before forking. That ordering is the
;; whole point — it is what turns the defect from a scheduling accident into a
;; property of the program — and it is why these gates are deterministic. There
;; is no sleep, no retry, no timeout, and no assumption about how the scheduler
;; interleaves the workers.
;;
;; Each section pairs the corrected mechanism with a CONTROL built on a plain
;; thread parameter, and asserts that the control exhibits the sharing. A gate
;; that cannot fail proves nothing, so the controls are checked as positively as
;; the fixes: if a future change made a bare thread parameter non-inheriting, the
;; control assertions would fail and say so.
;;
;; Covered:
;;   * the slot mechanism itself (identity, values, set/clear, peek);
;;   * the jolt.codec.binary IEEE scratch, by identity and by a forced race;
;;   * java.lang.ThreadLocal initialValue / get / set / remove;
;;   * per-thread interrupt boxes;
;;   * per-thread trace rings and the trace mark.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

;; --- deterministic fan-out ---------------------------------------------------
;; Fork `n` workers, run `body` on each with its index, and JOIN — a mutex and a
;; condition variable, so the parent blocks until every worker has finished
;; rather than waiting a guessed interval. Results come back indexed, so each
;; worker's own observation is compared against what that worker should have
;; seen, never against "some worker's" value.
(define (fan-out n body)
  (let ((results (make-vector n #f))
        (m (make-mutex))
        (c (make-condition))
        (done 0))
    (do ((i 0 (+ i 1))) ((= i n))
      (let ((i i))
        (fork-thread
          (lambda ()
            (let ((r (guard (e (#t (list 'raised e))) (body i))))
              (with-mutex m
                (vector-set! results i r)
                (set! done (+ done 1))
                (condition-broadcast c)))))))
    (with-mutex m
      (let wait () (unless (= done n) (condition-wait c m) (wait))))
    results))

(define (all-distinct? ls)
  (let loop ((xs ls))
    (or (null? xs)
        (and (not (memq (car xs) (cdr xs))) (loop (cdr xs))))))

(define workers 8)

;; ---------------------------------------------------------------------------
;; 1. the slot mechanism
;; ---------------------------------------------------------------------------

;; CONTROL: a plain thread parameter, initialized on the parent first. Every
;; child observes the parent's one object. This is the defect, stated as an
;; assertion rather than as a comment.
(let ((p (make-thread-parameter #f)))
  (p (make-bytevector 8 0))                       ; parent initializes FIRST
  (let* ((parent (p))
         (seen (vector->list (fan-out workers (lambda (i) (p))))))
    (ok "control: a plain thread parameter is inherited by every child"
        (for-all (lambda (v) (eq? v parent)) seen))
    (ok "control: the children therefore share one mutable object"
        (not (all-distinct? seen)))))

;; The slot, under exactly the same ordering.
(let ((s (jolt-make-thread-slot (lambda () (make-bytevector 8 0)))))
  (jolt-thread-slot-ref s)                        ; parent initializes FIRST
  (let* ((parent (jolt-thread-slot-ref s))
         (seen (vector->list (fan-out workers (lambda (i) (jolt-thread-slot-ref s))))))
    (ok "no child inherits the parent's slot value"
        (for-all (lambda (v) (not (eq? v parent))) seen))
    (ok (format "all ~a children get their own object" workers)
        (all-distinct? seen))
    (ok "the parent still holds its own value afterwards"
        (eq? (jolt-thread-slot-ref s) parent))))

;; Same-thread reuse is preserved: repeated refs on one thread return the SAME
;; object, so the steady-state scratch path allocates nothing. This is the
;; property the owner check must not cost.
(let ((s (jolt-make-thread-slot (lambda () (make-bytevector 8 0))))
      (builds 0))
  (let ((s (jolt-make-thread-slot (lambda () (set! builds (+ builds 1))
                                            (make-bytevector 8 0)))))
    (let ((a (jolt-thread-slot-ref s)))
      (do ((i 0 (+ i 1))) ((= i 1000))
        (unless (eq? (jolt-thread-slot-ref s) a) (ok "same-thread reuse" #f)))
      (ok "1000 same-thread refs return one object, built once"
          (and (eq? (jolt-thread-slot-ref s) a) (= builds 1)))))
  ;; and each worker builds exactly once for itself
  (let ((counts (vector->list
                  (fan-out workers
                    (lambda (i)
                      (let ((a (jolt-thread-slot-ref s)))
                        (do ((k 0 (+ k 1))) ((= k 100))
                          (unless (eq? (jolt-thread-slot-ref s) a)
                            (set! a 'CHANGED)))
                        (eq? a (jolt-thread-slot-ref s))))))))
    (ok "each worker's own value is stable across repeated refs"
        (for-all (lambda (v) (eq? v #t)) counts))))

;; set! / peek / clear, and their behaviour across a fork.
(let ((s (jolt-make-thread-slot (lambda () 'fresh))))
  (jolt-thread-slot-set! s 'parent-wrote)         ; parent initializes FIRST
  (ok "peek sees this thread's own value" (eq? (jolt-thread-slot-peek s) 'parent-wrote))
  (let ((seen (vector->list (fan-out workers (lambda (i) (jolt-thread-slot-peek s))))))
    (ok "peek never adopts an inherited entry"
        (for-all (lambda (v) (eq? v #f)) seen)))
  (let ((seen (vector->list (fan-out workers (lambda (i) (jolt-thread-slot-ref s))))))
    (ok "a child's first ref runs init instead of inheriting"
        (for-all (lambda (v) (eq? v 'fresh)) seen)))
  (ok "the parent's own value is untouched by the children"
      (eq? (jolt-thread-slot-ref s) 'parent-wrote))
  (jolt-thread-slot-clear! s)
  (ok "clear drops this thread's value" (eq? (jolt-thread-slot-peek s) #f))
  (ok "the next ref rebuilds from init" (eq? (jolt-thread-slot-ref s) 'fresh)))

;; Each worker writes its OWN distinct value and reads it back, many times. With
;; a shared entry the reads would return another worker's value; with per-thread
;; entries the result cannot depend on the schedule at all.
(let ((s (jolt-make-thread-slot (lambda () 'unset))))
  (jolt-thread-slot-set! s 'parent)               ; parent initializes FIRST
  (let ((seen (vector->list
                (fan-out workers
                  (lambda (i)
                    (let ((mine (string->symbol (format "worker-~a" i))))
                      (let loop ((k 0) (bad 0))
                        (if (= k 20000)
                            bad
                            (begin
                              (jolt-thread-slot-set! s mine)
                              (loop (+ k 1)
                                    (if (eq? (jolt-thread-slot-ref s) mine)
                                        bad
                                        (+ bad 1))))))))))))
    (ok "160000 interleaved set/ref pairs never observe another worker's value"
        (for-all (lambda (v) (eqv? v 0)) seen))
    (ok "the parent's value survived the whole run"
        (eq? (jolt-thread-slot-ref s) 'parent))))

;; ---------------------------------------------------------------------------
;; 2. the jolt.codec.binary IEEE scratch
;; ---------------------------------------------------------------------------

;; The defect the review reproduced: f64-bits stages through one reusable
;; eight-byte bytevector, and under a plain thread parameter every future shared
;; the parent's. Convert once on the parent so the scratch exists BEFORE the
;; fork, exactly as the failing control did.
(jb-f64-bits 1.0)

;; Identity first, because it is deterministic: no two threads may hold the same
;; staging buffer. Reaching the buffer through the slot is the direct check —
;; the race below is corroboration, not the primary evidence.
(let* ((parent (jolt-thread-slot-ref jb-ieee-scratch))
       (seen (vector->list
               (fan-out workers
                 (lambda (i)
                   (jb-f64-bits (+ 1.0 i))        ; go through the public path
                   (jolt-thread-slot-ref jb-ieee-scratch))))))
  (ok "no worker shares the parent's IEEE scratch"
      (for-all (lambda (v) (not (eq? v parent))) seen))
  (ok (format "all ~a workers stage through their own scratch" workers)
      (all-distinct? seen)))

;; The forced race, in the shape the review used: each worker owns a distinct f64
;; bit pattern and converts it repeatedly, failing on the first mismatch. The
;; corrected implementation cannot fail this regardless of interleaving; the
;; inherited-scratch implementation failed it on 15 of 16 workers.
(let* ((iterations 200000)
       (seen (vector->list
               (fan-out workers
                 (lambda (i)
                   ;; a quiet NaN with a per-worker payload: distinct patterns
                   ;; that are not numerically comparable, so only bits can tell
                   ;; them apart — a corrupted read cannot pass by coincidence.
                   (let* ((bits (+ #x7FF8000000000000 (* (+ i 1) #x1111)))
                          (x (jb-bits->f64 bits)))
                     (let loop ((k 0))
                       (cond ((= k iterations) 'clean)
                             ((not (= (jb-f64-bits x) bits)) (list 'corrupt i k))
                             (else (loop (+ k 1)))))))))))
  (ok (format "~a workers x ~a f64 conversions, no cross-thread corruption"
              workers iterations)
      (for-all (lambda (v) (eq? v 'clean)) seen))
  (for-each (lambda (v) (unless (eq? v 'clean) (printf "  ~a\n" v))) seen))

;; CONTROL: the same race over an inherited scratch, proving the harness above
;; is capable of detecting the defect it is gating. Built here rather than
;; described, so the evidence does not depend on re-checking out the old tree.
(let* ((shared (make-thread-parameter #f))
       (scratch (begin (shared (make-bytevector 8 0)) (shared)))
       (buggy-f64-bits
         (lambda (x)
           (let ((b (or (shared) (let ((n (make-bytevector 8 0))) (shared n) n))))
             (bytevector-ieee-double-set! b 0 x (endianness big))
             (bytevector-u64-ref b 0 (endianness big)))))
       (seen (vector->list
               (fan-out workers
                 (lambda (i)
                   (let* ((bits (+ #x7FF8000000000000 (* (+ i 1) #x1111)))
                          (x (jb-bits->f64 bits)))
                     (let loop ((k 0))
                       (cond ((= k 200000) 'clean)
                             ((not (= (buggy-f64-bits x) bits)) 'corrupt)
                             (else (loop (+ k 1))))))))))
       (corrupted (length (filter (lambda (v) (eq? v 'corrupt)) seen))))
  (ok "control: every worker inherited the one buggy scratch"
      (for-all (lambda (v) (eq? v scratch))
               (vector->list (fan-out workers (lambda (i) (shared))))))
  ;; The count is scheduler-dependent; that some worker is corrupted, given all
  ;; of them write different patterns into one buffer 200000 times, is not.
  (printf "  [control] inherited scratch corrupted ~a of ~a workers\n" corrupted workers)
  (ok (format "control: the inherited scratch corrupts conversions (~a/~a workers)"
              corrupted workers)
      (> corrupted 0)))

;; ---------------------------------------------------------------------------
;; 3. java.lang.ThreadLocal
;; ---------------------------------------------------------------------------
;; java.lang.ThreadLocal is defined NOT to inherit — that is what
;; InheritableThreadLocal exists for. So a child's first .get must run
;; initialValue for itself even when the parent has already read or written its
;; own value.

;; Call the registered host methods directly — the same procedures .get / .set /
;; .remove dispatch to, without needing the dot-form compiler in a host gate.
(define (tl-method name)
  (hashtable-ref (hashtable-ref host-methods-tbl "threadlocal" #f) name #f))
(define (tl-get tl) ((tl-method "get") tl))
(define (tl-set! tl v) ((tl-method "set") tl v))
(define (tl-remove! tl) ((tl-method "remove") tl))
(ok "the ThreadLocal host methods are registered"
    (and (procedure? (tl-method "get")) (procedure? (tl-method "set"))
         (procedure? (tl-method "remove"))))

(let* ((inits 0)
       (tl (jolt-make-thread-local (lambda () (set! inits (+ inits 1)) 'initial))))
  (ok "the parent's first get runs initialValue" (eq? (tl-get tl) 'initial))
  (tl-set! tl 'parent-value)                      ; parent initializes FIRST
  (ok "the parent's get returns what it set" (eq? (tl-get tl) 'parent-value))
  (let ((seen (vector->list (fan-out workers (lambda (i) (tl-get tl))))))
    (ok "a child's get runs initialValue rather than inheriting"
        (for-all (lambda (v) (eq? v 'initial)) seen)))
  (ok "the parent's value is unchanged by the children"
      (eq? (tl-get tl) 'parent-value))
  ;; a child's set is invisible to the parent and to its siblings
  (let ((seen (vector->list
                (fan-out workers
                  (lambda (i)
                    (let ((mine (string->symbol (format "child-~a" i))))
                      (tl-set! tl mine)
                      (let loop ((k 0) (bad 0))
                        (if (= k 5000)
                            (and (= bad 0) (eq? (tl-get tl) mine))
                            (loop (+ k 1)
                                  (if (eq? (tl-get tl) mine) bad (+ bad 1)))))))))))
    (ok "each child's set is visible only to itself"
        (for-all (lambda (v) (eq? v #t)) seen)))
  (ok "the parent's value survived every child's set"
      (eq? (tl-get tl) 'parent-value))
  ;; remove restores the initialValue path, per thread
  (let ((seen (vector->list
                (fan-out workers
                  (lambda (i)
                    (tl-set! tl 'scratch)
                    (tl-remove! tl)
                    (tl-get tl))))))
    (ok "remove makes the next get run initialValue again"
        (for-all (lambda (v) (eq? v 'initial)) seen)))
  (tl-remove! tl)
  (ok "the parent's remove restores its own initialValue" (eq? (tl-get tl) 'initial)))

;; CONTROL: a ThreadLocal over a plain thread parameter inherits, so a child's
;; first get would return the parent's object and never run initialValue.
(let ((p (make-thread-parameter 'unset)))
  (p 'parent-value)
  (let ((seen (vector->list (fan-out workers (lambda (i) (p))))))
    (ok "control: a parameter-backed ThreadLocal would leak the parent's value"
        (for-all (lambda (v) (eq? v 'parent-value)) seen))))

;; java.lang.InheritableThreadLocal is the class that DOES propagate, and the
;; correction must not flatten the two into one. Same constructor, inheritable
;; flag set, same parent-initializes-first ordering — and the opposite result.
(let ((itl (jolt-make-thread-local (lambda () 'initial) #t)))
  (tl-set! itl 'parent-value)                     ; parent initializes FIRST
  (let ((seen (vector->list (fan-out workers (lambda (i) (tl-get itl))))))
    (ok "InheritableThreadLocal still hands children the parent's value"
        (for-all (lambda (v) (eq? v 'parent-value)) seen)))
  ;; a child's own set is still local to it — inheritance is of the value at
  ;; fork time, not a shared cell afterwards
  (let ((seen (vector->list
                (fan-out workers
                  (lambda (i) (tl-set! itl 'child-value) (tl-get itl))))))
    (ok "an inheritable child's later set does not reach back to the parent"
        (for-all (lambda (v) (eq? v 'child-value)) seen)))
  (ok "the parent's inheritable value is unchanged" (eq? (tl-get itl) 'parent-value)))

;; ---------------------------------------------------------------------------
;; 4. per-thread interrupt boxes
;; ---------------------------------------------------------------------------
;; The JVM's interrupt flag is per-thread. Under inheritance every future built
;; by an already-running parent would share one box, so interrupting one worker
;; would interrupt all of them, and `interrupted` — which reads AND clears —
;; would let one worker swallow another's pending interrupt.

(current-interrupt-box)                           ; parent initializes FIRST
(let* ((parent-box (current-interrupt-box))
       (boxes (vector->list (fan-out workers (lambda (i) (current-interrupt-box))))))
  (ok "no worker shares the parent's interrupt box"
      (for-all (lambda (b) (not (eq? b parent-box))) boxes))
  (ok (format "all ~a workers get their own interrupt box" workers)
      (all-distinct? boxes)))

;; Setting one worker's flag leaves the parent's and the siblings' alone. The
;; boxes are collected first and set afterwards, on the parent, so the check is
;; a pure function of the collected identities — no scheduling is involved.
(set-box! (current-interrupt-box) #f)
(let* ((boxes (vector->list (fan-out workers (lambda (i) (current-interrupt-box))))))
  (set-box! (car boxes) #t)
  (ok "interrupting one worker does not interrupt the others"
      (for-all (lambda (b) (eq? (unbox b) #f)) (cdr boxes)))
  (ok "interrupting a worker does not interrupt the parent"
      (eq? (unbox (current-interrupt-box)) #f))
  ;; and reading-and-clearing one flag cannot consume another's
  (set-box! (cadr boxes) #t)
  (let ((v (unbox (car boxes))))
    (set-box! (car boxes) #f)
    (ok "clearing one worker's flag leaves another's pending"
        (and (eq? v #t) (eq? (unbox (cadr boxes)) #t)))))

;; ---------------------------------------------------------------------------
;; 5. per-thread trace rings
;; ---------------------------------------------------------------------------
;; The trace history is a mutable ring of rings. Two threads sharing one would
;; interleave their frame names into each other's ribs, which is precisely the
;; case the backtrace exists to disambiguate.

(jolt-trace-enable!)                              ; parent initializes FIRST
(jolt-trace-push! "parent-frame")
(let* ((parent-ring (jolt-thread-slot-ref jolt-trace-ring))
       (rings (vector->list
                (fan-out workers
                  (lambda (i) (jolt-trace-push! (format "worker-~a" i))
                              (jolt-thread-slot-ref jolt-trace-ring))))))
  (ok "no worker records into the parent's trace ring"
      (for-all (lambda (r) (not (eq? r parent-ring))) rings))
  (ok (format "all ~a workers get their own trace history" workers)
      (all-distinct? rings)))

;; Each worker's SNAPSHOT contains its own frames and no other thread's — the
;; mutable history itself, not merely the container identity.
(let ((seen (vector->list
              (fan-out workers
                (lambda (i)
                  (let ((mine (format "worker-~a" i)))
                    (do ((k 0 (+ k 1))) ((= k 5)) (jolt-trace-push! mine))
                    (let ((snap (jolt-trace-snapshot)))
                      (and (for-all (lambda (n) (string=? n mine)) snap)
                           (> (length snap) 0)))))))))
  (ok "each worker's trace history holds only its own frames"
      (for-all (lambda (v) (eq? v #t)) seen)))

(ok "the parent's own trace history is intact"
    (let ((snap (jolt-trace-snapshot)))
      (and (pair? snap) (for-all (lambda (n) (string=? n "parent-frame")) snap))))

;; The tail mark travels with the ring: an inherited mark would mislabel a
;; child's first frame as a tail rotation into a rib that does not exist yet.
(jolt-trace-mark! #t)                             ; parent sets the mark FIRST
(let ((seen (vector->list
              (fan-out workers
                (lambda (i) (jolt-thread-slot-ref jolt-trace-tail?))))))
  (ok "no worker inherits the parent's pending tail mark"
      (for-all (lambda (v) (eq? v #f)) seen)))
(ok "the parent's mark is still pending" (eq? (jolt-thread-slot-ref jolt-trace-tail?) #t))
(jolt-trace-mark! #f)

;; ---------------------------------------------------------------------------
;; 6. the main-thread pump marker
;; ---------------------------------------------------------------------------
;; jolt-in-main-pump? says "this thread IS the pump, mid-job", and
;; call-on-main-thread reads it to decide between running a thunk inline and
;; marshalling it to the pump. Inherited, it is a misclassification with teeth: a
;; thread spawned by a pump thunk would claim to be the pump and run
;; main-thread-affine work on itself — the exact thing the pump exists to
;; prevent.
;;
;; The marker is only ever set inside the pump's dynamic-wind, so the control
;; sets it the same way the pump does and forks from inside that extent.

(jolt-set-in-main-pump! #t)                       ; parent marks itself FIRST
(ok "the parent reads its own pump marker" (eq? (jolt-in-main-pump?) #t))
(let ((seen (vector->list (fan-out workers (lambda (i) (jolt-in-main-pump?))))))
  (ok "no thread forked inside the pump extent inherits the marker"
      (for-all (lambda (v) (eq? v #f)) seen)))
(ok "the parent is still marked afterwards" (eq? (jolt-in-main-pump?) #t))
(jolt-set-in-main-pump! #f)
(ok "clearing the marker is visible to the parent" (eq? (jolt-in-main-pump?) #f))

;; CONTROL: the plain parameter the marker used to be.
(let ((p (make-thread-parameter #f)))
  (p #t)
  (let ((seen (vector->list (fan-out workers (lambda (i) (p))))))
    (ok "control: a parameter-backed pump marker is inherited by every child"
        (for-all (lambda (v) (eq? v #t)) seen))))

;; End-to-end against a REAL pump. The barrier is a condition variable on the
;; pump's own active flag, under the pump's own mutex — so this waits for the
;; pump to be up rather than assuming it, with no sleep and no retry.
(let ((ready-mu (make-mutex))
      (ready-cv (make-condition))
      (pump-thread-id #f)
      (child-thread-id #f)
      (job-thread-id #f)
      (done #f))
  (fork-thread
    (lambda ()
      ;; the driver: wait for the pump, then drive one job through it
      (with-mutex jolt-main-queue-mu
        (let wait ()
          (unless (unbox jolt-main-pump-active)
            (condition-wait jolt-main-queue-cv jolt-main-queue-mu)
            (wait))))
      (jolt-call-on-main-thread
        (lambda ()
          ;; T1 runs ON the pump. Spawn a child from inside the pump extent and
          ;; return at once, so the pump goes back to draining rather than
          ;; waiting on its own child.
          (set! pump-thread-id (get-thread-id))
          (fork-thread
            (lambda ()
              (set! child-thread-id (get-thread-id))
              ;; If the child is misclassified as the pump, this runs INLINE here
              ;; and job-thread-id is the child's. If not, the pump runs it.
              (jolt-call-on-main-thread
                (lambda () (set! job-thread-id (get-thread-id)) jolt-nil))
              (with-mutex ready-mu
                (set! done #t)
                (condition-broadcast ready-cv))))
          jolt-nil))
      (with-mutex ready-mu
        (let wait () (unless done (condition-wait ready-cv ready-mu) (wait))))
      (jolt-stop-main-pump)))
  (jolt-run-main-pump)
  (ok "the pump ran the driver's job on the pump thread"
      (and pump-thread-id (not (eqv? pump-thread-id child-thread-id))))
  (ok "a child spawned inside a pump thunk marshals back to the pump thread"
      (and job-thread-id (eqv? job-thread-id pump-thread-id)))
  (ok "and specifically did NOT run it inline on itself"
      (not (eqv? job-thread-id child-thread-id))))

;; ---------------------------------------------------------------------------

(printf "thread slots: ~a checks, ~a failures\n" total fails)
(exit (if (> fails 0) 1 0))
