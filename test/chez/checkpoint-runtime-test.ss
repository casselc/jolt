;; Record/continue checkpoint controller: inert plans, deterministic trace, and
;; fail-closed action-bearing execution through the real rt.ss load order.
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
  (guard (e (#t (cons 'error e)))
    (cons 'ok (thunk))))
(define (error-result? result) (and (pair? result) (eq? 'error (car result))))
(define (contains-text? text needle)
  (let ((text-length (string-length text))
        (needle-length (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i needle-length) text-length) #f)
            ((string=? (substring text i (+ i needle-length)) needle) #t)
            (else (loop (+ i 1)))))))

(define kw-sites (keyword #f "sites"))
(define kw-plan (keyword #f "plan"))
(define kw-trace (keyword #f "trace"))
(define kw-next-seq (keyword #f "next-seq"))
(define kw-seq (keyword #f "seq"))
(define kw-actor (keyword #f "actor"))
(define kw-id (keyword #f "id"))
(define kw-hit (keyword #f "hit"))
(define kw-action (keyword #f "action"))
(define kw-continue (keyword #f "continue"))

(define site "test.runtime/continue")
(define action-site "test.runtime/action")

(define (snapshot) (jolt-checkpoint-snapshot))
(define (snap-trace s) (jolt-get s kw-trace))
(define (trace-event trace i) (pvec-nth! trace i))

(jolt-checkpoint-reset!)

(ok "runtime entrypoints are exported through jolt.host"
    (and (procedure? (var-deref "jolt.host" "checkpoint-register-site!"))
         (procedure? (var-deref "jolt.host" "checkpoint-install-plan!"))
         (procedure? (var-deref "jolt.host" "checkpoint-bind-actor!"))
         (procedure? (var-deref "jolt.host" "checkpoint-unbind-actor!"))
         (procedure? (var-deref "jolt.host" "checkpoint-reset!"))
         (procedure? (var-deref "jolt.host" "checkpoint-snapshot"))))

(ok "execution without explicit actor fails closed"
    (error-result? (attempt (lambda () (jolt-checkpoint-continue! site)))))
(ok "failed unbound execution records nothing"
    (= 0 (pvec-count (snap-trace (snapshot)))))

;; Site registration is set-canonical but exact: order does not matter, while a
;; second declaration with a different disposition set is rejected.
(jolt-checkpoint-register-site! site '(continue))
(jolt-checkpoint-register-site! site (jolt-hash-set kw-continue))
(ok "same site and disposition set registers idempotently"
    (= 1 (pmap-cnt (jolt-get (snapshot) kw-sites))))
(ok "duplicate site with different dispositions fails"
    (error-result?
      (attempt (lambda () (jolt-checkpoint-register-site! site '(continue yield))))))

(ok "plan cannot name an unregistered site"
    (error-result?
      (attempt
        (lambda ()
          (jolt-checkpoint-install-plan!
            (jolt-hash-map (jolt-vector "actor/a" "test.runtime/missing" 1)
                           kw-continue))))))

;; Even procedure-shaped data is rejected, never invoked.  This is a direct
;; tooth for the no-callback controller contract.
(define callback-count 0)
(define forbidden-callback (lambda () (set! callback-count (+ callback-count 1))))
(ok "plan rejects procedure actions"
    (error-result?
      (attempt
        (lambda ()
          (jolt-checkpoint-install-plan!
            (jolt-hash-map (jolt-vector "actor/a" site 1) forbidden-callback))))))
(ok "rejected procedure action is never invoked" (= callback-count 0))
(ok "plan rejects unsupported inert actions"
    (error-result?
      (attempt
        (lambda ()
          (jolt-checkpoint-install-plan!
            (jolt-hash-map (jolt-vector "actor/a" site 1)
                           (keyword #f "yield")))))))

;; Install a replay plan before the run. Plans are keyed by per-actor
;; [actor,id,hit], not global sequence.
(jolt-checkpoint-install-plan!
  (jolt-hash-map (jolt-vector "actor/a" site 1) kw-continue))
(jolt-checkpoint-bind-actor! "actor/a")
(jolt-checkpoint-continue! site)
(jolt-checkpoint-continue! site)
(jolt-checkpoint-bind-actor! "actor/b")
(jolt-checkpoint-continue! site)
(jolt-checkpoint-bind-actor! "actor/a")
(jolt-checkpoint-continue! site)

(let* ((s (snapshot))
       (trace (snap-trace s))
       (e0 (trace-event trace 0))
       (e1 (trace-event trace 1))
       (e2 (trace-event trace 2))
       (e3 (trace-event trace 3)))
  (ok "trace contains every record/continue execution" (= 4 (pvec-count trace)))
  (ok "global sequence is deterministic and contiguous"
      (equal? '(1 2 3 4)
              (map (lambda (e) (jolt-get e kw-seq)) (list e0 e1 e2 e3))))
  (ok "actor a hit count advances independently"
      (equal? '(1 2 3)
              (map (lambda (e) (jolt-get e kw-hit)) (list e0 e1 e3))))
  (ok "actor b starts at hit one" (= 1 (jolt-get e2 kw-hit)))
  (ok "trace preserves explicit actors"
      (equal? '("actor/a" "actor/a" "actor/b" "actor/a")
              (map (lambda (e) (jolt-get e kw-actor)) (list e0 e1 e2 e3))))
  (ok "trace preserves stable site ids"
      (and (string=? site (jolt-get e0 kw-id))
           (string=? site (jolt-get e3 kw-id))))
  (ok "record-only entries carry no selected action"
      (and (jolt-nil? (jolt-get e1 kw-action))
           (jolt-nil? (jolt-get e2 kw-action))
           (jolt-nil? (jolt-get e3 kw-action))))
  (ok "planned continue is recorded as inert action data"
      (eq? kw-continue (jolt-get e0 kw-action)))
  (ok "snapshot carries the next global sequence" (= 5 (jolt-get s kw-next-seq)))
  (ok "snapshot carries the installed replay plan"
      (eq? kw-continue
           (jolt-get (jolt-get s kw-plan) (jolt-vector "actor/a" site 1))))

  ;; A later publish cannot change a prior persistent snapshot.
  (jolt-checkpoint-continue! site)
  (ok "prior trace snapshot remains immutable" (= 4 (pvec-count trace)))
  (ok "new snapshot observes later publication"
      (= 5 (pvec-count (snap-trace (snapshot))))))

;; Concurrent publishers linearize on one contiguous sequence while each
;; explicitly bound actor owns an independent hit counter.
(define race-actors 4)
(define race-hits 20)
(define race-threads
  (let loop ((i 0) (out '()))
    (if (= i race-actors) out
        (loop (+ i 1)
              (cons
                (fork-thread
                  (lambda ()
                    (let ((actor (string-append "race/" (number->string i))))
                      (jolt-checkpoint-bind-actor! actor)
                      (let hits ((n 0))
                        (when (< n race-hits)
                          (jolt-checkpoint-continue! site)
                          (hits (+ n 1)))))))
                out)))))
(for-each thread-join race-threads)
(let* ((trace (snap-trace (snapshot)))
       (events (vector->list (pvec-v trace))))
  (ok "concurrent publishers retain one contiguous global sequence"
      (and (= (+ 5 (* race-actors race-hits)) (length events))
           (let loop ((rest events) (seq 1))
             (or (null? rest)
                 (and (= seq (jolt-get (car rest) kw-seq))
                      (loop (cdr rest) (+ seq 1)))))))
  (ok "concurrent actors retain independent contiguous hit counts"
      (let actors ((i 0))
        (or (= i race-actors)
            (let* ((actor (string-append "race/" (number->string i)))
                   (hits
                     (sort <
                       (map (lambda (event) (jolt-get event kw-hit))
                            (filter (lambda (event)
                                      (string=? actor (jolt-get event kw-actor)))
                                    events)))))
              (and (equal? hits
                           (let range ((n 1) (out '()))
                             (if (> n race-hits) (reverse out)
                                 (range (+ n 1) (cons n out)))))
                   (actors (+ i 1))))))))

;; The generic ABI is reserved for action-bearing sites and must fail before it
;; registers or records anything in this continue-only runtime slice.
(let ((before (snapshot)))
  (ok "action-bearing execution fails closed"
      (error-result?
        (attempt (lambda () (jolt-checkpoint! action-site '(continue yield))))))
  (let ((after (snapshot)))
    (ok "failed action-bearing execution does not register a site"
        (jolt-nil? (jolt-get (jolt-get after kw-sites) action-site)))
    (ok "failed action-bearing execution does not append trace"
        (= (pvec-count (snap-trace before)) (pvec-count (snap-trace after))))))

(jolt-checkpoint-unbind-actor!)
(ok "explicit unbind restores fail-closed execution"
    (error-result? (attempt (lambda () (jolt-checkpoint-continue! site)))))

;; --- adversarial execution-context ownership -------------------------------

;; Exact same-carrier interleaving: fiber A binds then yields; fiber B must not
;; see A's actor before its own explicit bind; A must recover its binding later.
(jolt-checkpoint-reset!)
(jolt-fiber-carrier-count-set! 1)
(define sibling-unbound #f)
(define fiber-a
  (sa-fiber-spawn
    (lambda ()
      (jolt-checkpoint-bind-actor! "fiber/a")
      (jolt-checkpoint-continue! "test.runtime/fiber")
      (sa-fiber-yield)
      (jolt-checkpoint-continue! "test.runtime/fiber"))))
(define fiber-b
  (sa-fiber-spawn
    (lambda ()
      (set! sibling-unbound
            (error-result?
              (attempt
                (lambda () (jolt-checkpoint-continue! "test.runtime/fiber")))))
      (jolt-checkpoint-bind-actor! "fiber/b")
      (jolt-checkpoint-continue! "test.runtime/fiber"))))
(sa-fiber-run-all)
(let* ((trace (snap-trace (snapshot)))
       (actors (map (lambda (event) (jolt-get event kw-actor))
                    (vector->list (pvec-v trace)))))
  (ok "sibling fiber does not inherit or observe parked fiber actor"
      sibling-unbound)
  (ok "same-carrier fibers retain isolated actors across yield"
      (equal? actors '("fiber/a" "fiber/b" "fiber/a"))))

;; OS threads have distinct noninherited interrupt-box identities even when the
;; parent has an active binding.
(jolt-checkpoint-reset!)
(jolt-checkpoint-bind-actor! "thread/parent")
(ok "same execution context may idempotently rebind its actor"
    (not (error-result?
           (attempt (lambda () (jolt-checkpoint-bind-actor! "thread/parent"))))))
(define child-result #f)
(define child-duplicate-bind-result #f)
(thread-join
  (fork-thread
    (lambda ()
      (set! child-duplicate-bind-result
            (attempt (lambda () (jolt-checkpoint-bind-actor! "thread/parent"))))
      (set! child-result
            (attempt
              (lambda () (jolt-checkpoint-continue! "test.runtime/child")))))))
(ok "second live context cannot claim an already-bound actor"
    (error-result? child-duplicate-bind-result))
(ok "child OS thread does not inherit parent actor" (error-result? child-result))
(ok "failed inherited-thread probe records nothing"
    (= 0 (pvec-count (snap-trace (snapshot)))))

;; A live thread binds before reset and attempts execution only afterwards. The
;; new run must reject its stale context binding globally, not merely clear the
;; thread that called reset.
(jolt-checkpoint-reset!)
(define reset-mu (make-mutex))
(define reset-cv (make-condition))
(define reset-ready #f)
(define reset-go #f)
(define reset-thread-result #f)
(define reset-thread
  (fork-thread
    (lambda ()
      (jolt-checkpoint-bind-actor! "thread/stale")
      (with-mutex reset-mu
        (set! reset-ready #t)
        (condition-broadcast reset-cv)
        (let wait ()
          (unless reset-go
            (condition-wait reset-cv reset-mu)
            (wait))))
      (set! reset-thread-result
            (attempt
              (lambda () (jolt-checkpoint-continue! "test.runtime/reset")))))))
(with-mutex reset-mu
  (let wait ()
    (unless reset-ready
      (condition-wait reset-cv reset-mu)
      (wait))))
(jolt-checkpoint-reset!)
(with-mutex reset-mu
  (set! reset-go #t)
  (condition-broadcast reset-cv))
(thread-join reset-thread)
(ok "reset invalidates another live thread's prebound actor"
    (error-result? reset-thread-result))
(ok "stale post-reset thread execution records nothing"
    (= 0 (pvec-count (snap-trace (snapshot)))))

;; --- mutable string ownership ---------------------------------------------

(jolt-checkpoint-reset!)
(define mutable-actor (string-copy "mutable/a"))
(define mutable-site (string-copy "test.mutable/site"))
(define mutable-plan-actor (string-copy "mutable/a"))
(define mutable-plan-site (string-copy "test.mutable/site"))
(jolt-checkpoint-register-site! mutable-site '(continue))
(jolt-checkpoint-bind-actor! mutable-actor)
(jolt-checkpoint-install-plan!
  (jolt-hash-map (jolt-vector mutable-plan-actor mutable-plan-site 1) kw-continue))
;; Rewrite every caller-owned string after the APIs returned.
(string-set! mutable-actor 0 #\X)
(string-set! mutable-site 0 #\X)
(string-set! mutable-plan-actor 0 #\X)
(string-set! mutable-plan-site 0 #\X)
(define mutable-exec-site (string-copy "test.mutable/site"))
(jolt-checkpoint-continue! mutable-exec-site)
(string-set! mutable-exec-site 0 #\X)
(define mutable-snapshot (snapshot))
(define mutable-event (trace-event (snap-trace mutable-snapshot) 0))
(ok "actor/id copies preserve plan lookup after caller mutation"
    (and (string=? "mutable/a" (jolt-get mutable-event kw-actor))
         (string=? "test.mutable/site" (jolt-get mutable-event kw-id))
         (eq? kw-continue (jolt-get mutable-event kw-action))))
(ok "site registry key survives caller string mutation"
    (not (jolt-nil?
           (jolt-get (jolt-get mutable-snapshot kw-sites) "test.mutable/site"))))
(ok "plan key survives caller string mutation"
    (eq? kw-continue
         (jolt-get (jolt-get mutable-snapshot kw-plan)
                   (jolt-vector "mutable/a" "test.mutable/site" 1))))

;; Snapshot strings are detached too: mutating a returned event and plan key
;; cannot rewrite the controller's internal strings or a later snapshot.
(define returned-actor (jolt-get mutable-event kw-actor))
(define returned-id (jolt-get mutable-event kw-id))
(define returned-plan-key
  (pmap-fold (jolt-get mutable-snapshot kw-plan) (lambda (k v a) k) #f))
(define returned-site-key
  (pmap-fold (jolt-get mutable-snapshot kw-sites) (lambda (k v a) k) #f))
(string-set! returned-actor 0 #\X)
(string-set! returned-id 0 #\X)
(string-set! (pvec-nth! returned-plan-key 0) 0 #\X)
(string-set! (pvec-nth! returned-plan-key 1) 0 #\X)
(string-set! returned-site-key 0 #\X)
(let* ((fresh (snapshot))
       (event (trace-event (snap-trace fresh) 0)))
  (ok "later trace snapshot is detached from mutated prior snapshot"
      (and (string=? "mutable/a" (jolt-get event kw-actor))
           (string=? "test.mutable/site" (jolt-get event kw-id))))
  (ok "later plan snapshot is detached from mutated prior snapshot"
      (eq? kw-continue
           (jolt-get (jolt-get fresh kw-plan)
                     (jolt-vector "mutable/a" "test.mutable/site" 1))))
  (ok "later site snapshot is detached from mutated prior snapshot"
      (not (jolt-nil? (jolt-get (jolt-get fresh kw-sites) "test.mutable/site")))))

;; --- actual controlled compiler/runtime integration ------------------------

(define controlled-new-unit (var-deref "jolt.passes.types" "new-unit"))
(define controlled-configure! (var-deref "jolt.checkpoints" "configure-unit!"))
(define controlled-set-emit-unit!
  (var-deref "jolt.backend-scheme" "set-emit-unit!"))
(define (compile-controlled source)
  (let-values (((form next) (rdr-read-form source 0 (string-length source))))
    (let ((ctx (make-analyze-ctx "checkpoint.runtime.integration"))
          (unit (controlled-new-unit)))
      (controlled-configure! unit (keyword #f "controlled"))
      (controlled-set-emit-unit! unit)
      (jolt-ce-emit
        (jolt-ce-run-passes (jolt-ce-analyze ctx form) ctx unit)))))
(define (execute-emitted scheme)
  (eval (read (open-string-input-port scheme)) (interaction-environment)))

(jolt-checkpoint-reset!)
(jolt-checkpoint-bind-actor! "compiled/a")
(define compiled-continue
  (compile-controlled
    "(do (jolt.checkpoints/checkpoint! :test.compiled/continue #{:continue}) :answer)"))
(ok "controlled compiler emits the closed continue runtime leaf"
    (contains-text? compiled-continue "jolt-checkpoint-continue!"))
(define compiled-outer-mu (make-mutex))
(define compiled-result
  (jolt-with-mutex compiled-outer-mu
    (execute-emitted compiled-continue)))
(let* ((compiled-trace (snap-trace (snapshot)))
       (event (trace-event compiled-trace 0)))
  (ok "controlled emitted program preserves its source result"
      (eq? (keyword #f "answer") compiled-result))
  (ok "controlled emitted leaf executes through the real runtime"
      (and (= 1 (pvec-count compiled-trace))
           (= 1 (jolt-get event kw-seq))
           (= 1 (jolt-get event kw-hit))
           (string=? "compiled/a" (jolt-get event kw-actor))
           (string=? "test.compiled/continue" (jolt-get event kw-id)))))

(define compiled-action
  (compile-controlled
    "(jolt.checkpoints/checkpoint! :test.compiled/action #{:continue :yield})"))
(ok "controlled compiler emits generic action-bearing runtime entry"
    (and (contains-text? compiled-action "jolt-checkpoint!")
         (not (contains-text? compiled-action "jolt-checkpoint-continue!"))))
(define compiled-before (snapshot))
(ok "compiled action-bearing execution fails closed"
    (error-result? (attempt (lambda () (execute-emitted compiled-action)))))
(ok "compiled action-bearing failure leaves all controller state unchanged"
    (jolt= compiled-before (snapshot)))

(if (= fails 0)
    (printf "checkpoint runtime: ~a checks passed\n" total)
    (begin
      (printf "checkpoint runtime: ~a/~a checks FAILED\n" fails total)
      (exit 1)))
