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
(define (attempt-unwrapped thunk)
  (guard (e (#t (cons 'error (jolt-unwrap-throw e))))
    (cons 'ok (thunk))))
(define (error-result? result) (and (pair? result) (eq? 'error (car result))))
(define (action-error-data result)
  (and (error-result? result)
       (jolt-ex-info-record? (cdr result))
       (jolt-ex-info-record-data (cdr result))))
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
(define kw-generation (keyword #f "generation"))
(define kw-seq (keyword #f "seq"))
(define kw-actor (keyword #f "actor"))
(define kw-id (keyword #f "id"))
(define kw-hit (keyword #f "hit"))
(define kw-action (keyword #f "action"))
(define kw-continue (keyword #f "continue"))
(define kw-yield (keyword #f "yield"))
(define kw-barrier (keyword #f "barrier"))
(define kw-fault (keyword #f "fault"))
(define kw-cancel (keyword #f "cancel"))
(define kw-error-checkpoint-type (keyword "jolt.checkpoint" "type"))
(define kw-error-checkpoint-generation (keyword "jolt.checkpoint" "generation"))
(define kw-error-checkpoint-seq (keyword "jolt.checkpoint" "seq"))
(define kw-error-checkpoint-actor (keyword "jolt.checkpoint" "actor"))
(define kw-error-checkpoint-id (keyword "jolt.checkpoint" "id"))
(define kw-error-checkpoint-hit (keyword "jolt.checkpoint" "hit"))

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

(let ((before (snapshot)))
  (ok "plan freezes after the first reservation"
      (error-result?
        (attempt
          (lambda ()
            (jolt-checkpoint-install-plan! (jolt-hash-map))))))
  (ok "rejected late plan replacement leaves snapshot plan unchanged"
      (jolt= (jolt-get before kw-plan)
             (jolt-get (snapshot) kw-plan))))

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

;; With this still-bound main actor, an action-bearing declaration with no plan
;; is an ordinary record-only decision. The dedicated unbound probes below
;; cover both thread and fiber fail-closed behavior.
(let ((before (snapshot)))
  (ok "bound action-bearing execution records an unplanned decision"
      (not (error-result?
             (attempt (lambda () (jolt-checkpoint! action-site '(continue yield)))))))
  (let* ((after (snapshot))
         (event (trace-event (snap-trace after)
                             (pvec-count (snap-trace before)))))
    (ok "unplanned generic action appends one inert event"
        (and (= (+ 1 (pvec-count (snap-trace before)))
                (pvec-count (snap-trace after)))
             (jolt-nil? (jolt-get event kw-action))))))

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
(define compiled-action-result
  (attempt (lambda () (execute-emitted compiled-action))))
(let* ((after (snapshot))
       (event (trace-event (snap-trace after) 1)))
  (ok "compiled action-bearing execution records its unplanned decision"
      (and (not (error-result? compiled-action-result))
           (= (+ 1 (pvec-count (snap-trace compiled-before)))
              (pvec-count (snap-trace after)))
           (= 2 (jolt-get event kw-seq))
           (string=? "compiled/a" (jolt-get event kw-actor))
           (string=? "test.compiled/action" (jolt-get event kw-id))
           (jolt-nil? (jolt-get event kw-action)))))

;; --- #54 generation-scoped per-actor recorder histories -------------------

(jolt-checkpoint-reset!)
(define recorder-generation (jolt-get (snapshot) kw-generation))
(ok "checkpoint snapshot exposes a positive generation"
    (and (integer? recorder-generation) (> recorder-generation 0)))

;; Hold actor A's actual recorder mutex after exact reservation and release A
;; into commit. Actor B must still reserve and commit. A global-recorder-lock
;; mutant blocks B here, while the same-recorder A commit remains blocked as a
;; non-vacuous control.
(define recorder-gate-mu (make-mutex))
(define recorder-gate-cv (make-condition))
(define recorder-a-token #f)
(define recorder-a-release #f)
(define recorder-a-committed #f)
(define recorder-b-go #f)
(define recorder-b-committed #f)
(define recorder-a-thread
  (fork-thread
    (lambda ()
      (jolt-checkpoint-bind-actor! "recorder/a")
      (let ((token
              (checkpoint-record-reserve! "test.recorder/independent")))
        (with-mutex recorder-gate-mu
          (set! recorder-a-token token)
          (condition-broadcast recorder-gate-cv)
          (let wait ()
            (unless recorder-a-release
              (condition-wait recorder-gate-cv recorder-gate-mu)
              (wait))))
        (checkpoint-record-commit! token)
        (with-mutex recorder-gate-mu
          (set! recorder-a-committed #t)
          (condition-broadcast recorder-gate-cv))))))
(define recorder-b-thread
  (fork-thread
    (lambda ()
      (with-mutex recorder-gate-mu
        (let wait ()
          (unless recorder-b-go
            (condition-wait recorder-gate-cv recorder-gate-mu)
            (wait))))
      (jolt-checkpoint-bind-actor! "recorder/b")
      (checkpoint-record-commit!
        (checkpoint-record-reserve! "test.recorder/independent"))
      (with-mutex recorder-gate-mu
        (set! recorder-b-committed #t)
        (condition-broadcast recorder-gate-cv)))))
(with-mutex recorder-gate-mu
  (let wait ()
    (unless recorder-a-token
      (condition-wait recorder-gate-cv recorder-gate-mu)
      (wait))))
(define recorder-a-mu
  (checkpoint-recorder-mu
    (checkpoint-binding-recorder
      (checkpoint-token-binding recorder-a-token))))
(mutex-acquire recorder-a-mu)
(with-mutex recorder-gate-mu
  (set! recorder-a-release #t)
  (set! recorder-b-go #t)
  (condition-broadcast recorder-gate-cv)
  (let wait ()
    (unless recorder-b-committed
      (condition-wait recorder-gate-cv recorder-gate-mu)
      (wait))))
(ok "actor-local recorder lock does not block another actor commit"
    (and recorder-b-committed (not recorder-a-committed)))
(mutex-release recorder-a-mu)
(thread-join recorder-a-thread)
(thread-join recorder-b-thread)
(let* ((trace (snap-trace (snapshot)))
       (b (trace-event trace 0))
       (a (trace-event trace 1)))
  (ok "same-recorder commit resumes and extends contiguous order"
      (and recorder-a-committed
           (= 2 (pvec-count trace))
           (= 1 (jolt-get b kw-seq))
           (string=? "recorder/b" (jolt-get b kw-actor))
           (= 2 (jolt-get a kw-seq))
           (string=? "recorder/a" (jolt-get a kw-actor)))))

;; A reservation token is affine to its execution context. Passing it to a
;; sibling thread must fail before clock allocation or trace publication; the
;; original driver can still commit that exact token afterwards.
(jolt-checkpoint-reset!)
(define driver-mu (make-mutex))
(define driver-cv (make-condition))
(define driver-token #f)
(define driver-release #f)
(define driver-thread
  (fork-thread
    (lambda ()
      (jolt-checkpoint-bind-actor! "driver/a")
      (let ((token (checkpoint-record-reserve! "test.recorder/driver")))
        (with-mutex driver-mu
          (set! driver-token token)
          (condition-broadcast driver-cv)
          (let wait ()
            (unless driver-release
              (condition-wait driver-cv driver-mu)
              (wait))))
        (checkpoint-record-commit! token)))))
(with-mutex driver-mu
  (let wait ()
    (unless driver-token
      (condition-wait driver-cv driver-mu)
      (wait))))
(ok "foreign execution context cannot commit another actor token"
    (error-result?
      (attempt (lambda () (checkpoint-record-commit! driver-token)))))
(ok "foreign token rejection publishes no event"
    (= 0 (pvec-count (snap-trace (snapshot)))))
(with-mutex driver-mu
  (set! driver-release #t)
  (condition-broadcast driver-cv))
(thread-join driver-thread)
(ok "original token driver remains able to commit exactly once"
    (= 1 (pvec-count (snap-trace (snapshot)))))

(jolt-checkpoint-reset!)
(jolt-checkpoint-bind-actor! "driver/once")
(define once-token
  (checkpoint-record-reserve! "test.recorder/driver-once"))
(checkpoint-record-commit! once-token)
(ok "same execution context cannot commit one token twice"
    (error-result?
      (attempt (lambda () (checkpoint-record-commit! once-token)))))
(ok "duplicate token commit appends no second event"
    (= 1 (pvec-count (snap-trace (snapshot)))))

;; A token belongs to one exact binding instance, not merely to its actor,
;; recorder, generation, or OS thread. Unbinding or rebinding retires an
;; outstanding reservation without consuming the actor's next hit.
(jolt-checkpoint-reset!)
(jolt-checkpoint-bind-actor! "binding/exact")
(define unbound-token
  (checkpoint-record-reserve! "test.recorder/exact-binding"))
(jolt-checkpoint-unbind-actor!)
(ok "unbind makes an outstanding token stale"
    (eq? checkpoint-stale (checkpoint-record-commit! unbound-token)))
(ok "stale unbound token consumes neither event nor hit"
    (= 0 (pvec-count (snap-trace (snapshot)))))

(jolt-checkpoint-bind-actor! "binding/exact")
(define rebound-token
  (checkpoint-record-reserve! "test.recorder/exact-binding"))
;; Rebinding the same actor on the same execution context deliberately creates
;; a fresh capability even though it reuses the actor's recorder.
(jolt-checkpoint-bind-actor! "binding/exact")
(ok "same-actor rebind makes the prior binding token stale"
    (eq? checkpoint-stale (checkpoint-record-commit! rebound-token)))
(jolt-checkpoint-continue! "test.recorder/exact-binding")
(let* ((trace (snap-trace (snapshot)))
       (event (trace-event trace 0)))
  (ok "abandoned bindings leave the next committed hit contiguous"
      (and (= 1 (pvec-count trace))
           (= 1 (jolt-get event kw-seq))
           (= 1 (jolt-get event kw-hit)))))

;; Exercise a deterministic concurrent cut while one exact token is reserved
;; but uncommitted and three independent actors publish. The first snapshot
;; must exclude the reservation; after release, the final snapshot must extend
;; that exact prefix. Worker failures are captured and always release waiters.
(jolt-checkpoint-reset!)
(define snapshot-race-actors 4)
(define snapshot-race-hits 40)
(define snapshot-race-mu (make-mutex))
(define snapshot-race-cv (make-condition))
(define snapshot-race-ready 0)
(define snapshot-race-go #f)
(define snapshot-race-paused #f)
(define snapshot-race-release #f)
(define snapshot-race-done 0)
(define snapshot-race-errors (make-vector snapshot-race-actors #f))
(define snapshot-race-threads
  (let loop ((i 0) (out '()))
    (if (= i snapshot-race-actors) out
        (loop
          (+ i 1)
          (cons
            (fork-thread
              (lambda ()
                (guard
                  (e (#t
                      (with-mutex snapshot-race-mu
                        (vector-set! snapshot-race-errors i e)
                        (when (= i 0) (set! snapshot-race-paused #t))
                        (set! snapshot-race-done (+ snapshot-race-done 1))
                        (condition-broadcast snapshot-race-cv))))
                  (with-mutex snapshot-race-mu
                    (set! snapshot-race-ready (+ snapshot-race-ready 1))
                    (condition-broadcast snapshot-race-cv)
                    (let wait ()
                      (unless snapshot-race-go
                        (condition-wait snapshot-race-cv snapshot-race-mu)
                        (wait))))
                  (jolt-checkpoint-bind-actor!
                    (string-append "snapshot/" (number->string i)))
                  (if (= i 0)
                      (let ((token
                              (checkpoint-record-reserve!
                                "test.recorder/snapshot-race")))
                        (with-mutex snapshot-race-mu
                          (set! snapshot-race-paused #t)
                          (condition-broadcast snapshot-race-cv)
                          (let wait ()
                            (unless snapshot-race-release
                              (condition-wait snapshot-race-cv snapshot-race-mu)
                              (wait))))
                        (checkpoint-record-commit! token)
                        (let hits ((n 1))
                          (when (< n snapshot-race-hits)
                            (jolt-checkpoint-continue!
                              "test.recorder/snapshot-race")
                            (hits (+ n 1)))))
                      (let hits ((n 0))
                        (when (< n snapshot-race-hits)
                          (jolt-checkpoint-continue!
                            "test.recorder/snapshot-race")
                          (hits (+ n 1)))))
                  (with-mutex snapshot-race-mu
                    (set! snapshot-race-done (+ snapshot-race-done 1))
                    (condition-broadcast snapshot-race-cv)))))
            out)))))
(define (snapshot-event-key event)
  (list (jolt-get event kw-seq)
        (jolt-get event kw-actor)
        (jolt-get event kw-id)
        (jolt-get event kw-hit)))
(define (list-prefix? prefix xs)
  (cond ((null? prefix) #t)
        ((null? xs) #f)
        (else (and (equal? (car prefix) (car xs))
                   (list-prefix? (cdr prefix) (cdr xs))))))
(define (snapshot-contiguous? s)
  (let* ((trace (vector->list (pvec-v (snap-trace s))))
         (seqs (map (lambda (event) (jolt-get event kw-seq)) trace)))
    (and (= (jolt-get s kw-next-seq) (+ 1 (length trace)))
         (equal? seqs
                 (let range ((n 1) (out '()))
                   (if (> n (length trace)) (reverse out)
                       (range (+ n 1) (cons n out))))))))
(with-mutex snapshot-race-mu
  (let wait ()
    (unless (= snapshot-race-ready snapshot-race-actors)
      (condition-wait snapshot-race-cv snapshot-race-mu)
      (wait)))
  (set! snapshot-race-go #t)
  (condition-broadcast snapshot-race-cv)
  (let wait ()
    (unless snapshot-race-paused
      (condition-wait snapshot-race-cv snapshot-race-mu)
      (wait))))
(define pending-snapshot (snapshot))
(define pending-keys
  (map snapshot-event-key
       (vector->list (pvec-v (snap-trace pending-snapshot)))))
(ok "snapshot excludes a reserved but uncommitted token"
    (and (snapshot-contiguous? pending-snapshot)
         (< (length pending-keys)
            (* snapshot-race-actors snapshot-race-hits))))
(with-mutex snapshot-race-mu
  (set! snapshot-race-release #t)
  (condition-broadcast snapshot-race-cv))
(for-each thread-join snapshot-race-threads)
(let ((final (snapshot)))
  (ok "concurrent commits and snapshot cuts preserve exact prefixes"
      (and (let errors ((i 0))
             (or (= i snapshot-race-actors)
                 (and (not (vector-ref snapshot-race-errors i))
                      (errors (+ i 1)))))
           (= snapshot-race-done snapshot-race-actors)
           (snapshot-contiguous? final)
           (list-prefix?
             pending-keys
             (map snapshot-event-key
                  (vector->list (pvec-v (snap-trace final)))))
           (> (pvec-count (snap-trace final)) (length pending-keys))
           (= (* snapshot-race-actors snapshot-race-hits)
              (pvec-count (snap-trace final)))
           (= (+ 1 (* snapshot-race-actors snapshot-race-hits))
              (jolt-get final kw-next-seq)))))

;; Reset is a generation fence. A token reserved in the prior generation may
;; retire only as stale; it cannot allocate a sequence or publish into the new
;; run. Fresh recording restarts sequence and hit at one.
(jolt-checkpoint-reset!)
(jolt-checkpoint-bind-actor! "generation/stale")
(define stale-generation (jolt-get (snapshot) kw-generation))
(define stale-token
  (checkpoint-record-reserve! "test.recorder/generation"))
(define stale-clock
  (checkpoint-generation-clock
    (checkpoint-binding-generation
      (checkpoint-token-binding stale-token))))
(jolt-checkpoint-reset!)
(define fresh-generation (jolt-get (snapshot) kw-generation))
(ok "reset advances the checkpoint generation"
    (= fresh-generation (+ stale-generation 1)))
(ok "stale reserved token is rejected without publication"
    (and (eq? checkpoint-stale (checkpoint-record-commit! stale-token))
         (= 0 (pvec-count (snap-trace (snapshot))))))
(ok "reset seals the prior generation against late allocation"
    (not (checkpoint-clock-allocate! stale-clock)))
(jolt-checkpoint-bind-actor! "generation/fresh")
(jolt-checkpoint-continue! "test.recorder/generation")
(let* ((s (snapshot))
       (trace (snap-trace s))
       (event (trace-event trace 0)))
  (ok "fresh post-reset recording restarts sequence and hit at one"
      (and (= 1 (pvec-count trace))
           (= 1 (jolt-get event kw-seq))
           (= 1 (jolt-get event kw-hit)))))

;; Binding failure occurs before reservation/config publication and leaves the
;; complete public controller snapshot unchanged.
(jolt-checkpoint-reset!)
(define unbound-before (snapshot))
(ok "unbound exact reservation fails closed"
    (error-result?
      (attempt
        (lambda ()
          (checkpoint-record-reserve! "test.recorder/unbound")))))
(ok "unbound reservation failure is controller-state-identical"
    (jolt= unbound-before (snapshot)))

;; --- action-bearing replay contract ---------------------------------------
;;
;; This is intentionally a narrow compatibility characterization, not a new
;; controller API: the existing public plan map remains [actor id hit] ->
;; keyword. Fault and cancel expose only their reviewed namespaced ex-data.
;; Every worker stores its own result, so an action failure cannot turn a
;; scheduler fault into a silent hang or leave an unbounded history behind.

(define (action-event-matches? event action actor id hit seq)
  (and (eq? action (jolt-get event kw-action))
       (string=? actor (jolt-get event kw-actor))
       (string=? id (jolt-get event kw-id))
       (= hit (jolt-get event kw-hit))
       (= seq (jolt-get event kw-seq))))

(define (canonical-action-error-matches? result type generation event)
  (let ((data (action-error-data result)))
    (and data
         (eq? type (jolt-get data kw-error-checkpoint-type))
         (= generation (jolt-get data kw-error-checkpoint-generation))
         (string=? (jolt-get event kw-actor)
                   (jolt-get data kw-error-checkpoint-actor))
         (string=? (jolt-get event kw-id)
                   (jolt-get data kw-error-checkpoint-id))
         (= (jolt-get event kw-hit) (jolt-get data kw-error-checkpoint-hit))
         (= (jolt-get event kw-seq) (jolt-get data kw-error-checkpoint-seq)))))

(define (after-action-plan plan-result thunk)
  ;; Keep a rejected setup as an ordinary worker result so this bounded suite
  ;; can report the remaining independent action contracts too.
  (if (error-result? plan-result)
      plan-result
      (attempt-unwrapped thunk)))

;; No binding must fail closed on either scheduler context.  These workers are
;; bounded one-shot probes; their captured errors also prove no inherited actor
;; binding becomes observable merely by crossing a thread/fiber boundary.
(jolt-checkpoint-reset!)
(define unbound-action-thread-result #f)
(define unbound-action-fiber-result #f)
(thread-join
  (fork-thread
    (lambda ()
      (set! unbound-action-thread-result
            (attempt-unwrapped
              (lambda ()
                (jolt-checkpoint! "test.action/unbound" '(continue yield))))))))
(sa-fiber-spawn
  (lambda ()
    (set! unbound-action-fiber-result
          (attempt-unwrapped
            (lambda ()
              (jolt-checkpoint! "test.action/unbound" '(continue yield)))))))
(sa-fiber-run-all)
(ok "unbound action execution fails closed in OS threads and fibers"
    (and (error-result? unbound-action-thread-result)
         (error-result? unbound-action-fiber-result)
         (= 0 (pvec-count (snap-trace (snapshot))))))

;; The action parser accepts only actions declared by that site, and a generic
;; execution turns its compatible plan choice into immutable recorded data
;; before freezing replacement.  A disallowed action is a fail-closed parser
;; control: it cannot publish a plan or begin a run.
(jolt-checkpoint-reset!)
(define decision-site "test.action/decision")
(jolt-checkpoint-register-site! decision-site '(continue yield))
(define disallowed-action-before (snapshot))
(ok "action plan rejects a choice outside the site's declared capability"
    (and (error-result?
           (attempt
             (lambda ()
               (jolt-checkpoint-install-plan!
                 (jolt-hash-map
                   (jolt-vector "decision/a" decision-site 1) kw-fault)))))
         (jolt= disallowed-action-before (snapshot))))
(define selected-continue-plan-result
  (attempt
    (lambda ()
      (jolt-checkpoint-install-plan!
        (jolt-hash-map
          (jolt-vector "decision/a" decision-site 1) kw-continue)))))
(jolt-checkpoint-bind-actor! "decision/a")
(define selected-continue-result
  (after-action-plan selected-continue-plan-result
    (lambda () (jolt-checkpoint! decision-site '(continue yield)))))
(define selected-continue-snapshot (snapshot))
(define selected-continue-trace (snap-trace selected-continue-snapshot))
(define selected-continue-event
  (and (= 1 (pvec-count selected-continue-trace))
       (trace-event selected-continue-trace 0)))
(ok "generic compatible action commits an immutable selected decision"
    (and (not (error-result? selected-continue-result))
         selected-continue-event
         (action-event-matches?
           selected-continue-event kw-continue "decision/a" decision-site 1 1)
         (eq? kw-continue
              (jolt-get (jolt-get selected-continue-snapshot kw-plan)
                        (jolt-vector "decision/a" decision-site 1)))
         (error-result?
           (attempt
             (lambda () (jolt-checkpoint-install-plan! (jolt-hash-map)))))))

;; :yield records once before it invokes the applicable scheduler yield.  This
;; characterizes deterministic selection/invocation, not a peer handoff order;
;; the separate thread probe ensures the generic action does not call fiber
;; yield off fiber.
(jolt-checkpoint-reset!)
(jolt-fiber-carrier-count-set! 1)
(define yield-site "test.action/yield")
(define yield-fiber-result #f)
(define yield-thread-result #f)
(jolt-checkpoint-register-site! yield-site '(continue yield))
(define yield-fiber-plan-result
  (attempt
    (lambda ()
      (jolt-checkpoint-install-plan!
        (jolt-hash-map (jolt-vector "yield/fiber" yield-site 1) kw-yield)))))
(sa-fiber-spawn
  (lambda ()
    (jolt-checkpoint-bind-actor! "yield/fiber")
    (set! yield-fiber-result
          (after-action-plan yield-fiber-plan-result
            (lambda () (jolt-checkpoint! yield-site '(continue yield)))))))
(sa-fiber-run-all)
(let* ((s (snapshot))
       (trace (snap-trace s))
       (event (and (= 1 (pvec-count trace)) (trace-event trace 0))))
  (ok "selected fiber yield records once and invokes the fiber yield path"
      (and (not (error-result? yield-fiber-result))
           event
           (eq? kw-yield
                (jolt-get (jolt-get s kw-plan)
                          (jolt-vector "yield/fiber" yield-site 1)))
           (action-event-matches? event kw-yield "yield/fiber" yield-site 1 1))))

(jolt-checkpoint-reset!)
(jolt-checkpoint-register-site! yield-site '(continue yield))
(define yield-thread-plan-result
  (attempt
    (lambda ()
      (jolt-checkpoint-install-plan!
        (jolt-hash-map (jolt-vector "yield/thread" yield-site 1) kw-yield)))))
(thread-join
  (fork-thread
    (lambda ()
      (jolt-checkpoint-bind-actor! "yield/thread")
      (set! yield-thread-result
            (after-action-plan yield-thread-plan-result
              (lambda () (jolt-checkpoint! yield-site '(continue yield))))))))
(let* ((trace (snap-trace (snapshot)))
       (event (and (= 1 (pvec-count trace)) (trace-event trace 0))))
  (ok "selected OS-thread yield records once without fiber-only failure"
      (and (not (error-result? yield-thread-result))
           event
           (action-event-matches? event kw-yield "yield/thread" yield-site 1 1))))

;; Barrier membership remains deliberately outside this gate.  Reviews disagree
;; whether a round is inferred from [site-id hit] or carried by an inert,
;; versioned descriptor that can rendezvous across selectors.  Do not freeze an
;; implementation through tests until that ABI review resolves it; reset safety
;; for the chosen waiter representation belongs in that subsequent slice.

;; Fault and cancel are both commit-then-throw actions.  The error data shape is
;; deliberately asserted by stable classification and the already-published
;; event identity, not a message or a new public descriptor type.
(jolt-checkpoint-reset!)
(define fault-site "test.action/fault")
(define fault-result #f)
(jolt-checkpoint-register-site! fault-site '(continue fault))
(define fault-plan-result
  (attempt
    (lambda ()
      (jolt-checkpoint-install-plan!
        (jolt-hash-map (jolt-vector "fault/a" fault-site 1) kw-fault)))))
(jolt-checkpoint-bind-actor! "fault/a")
(set! fault-result
      (after-action-plan fault-plan-result
        (lambda () (jolt-checkpoint! fault-site '(continue fault)))))
(let* ((s (snapshot))
       (trace (snap-trace s))
       (event (and (= 1 (pvec-count trace)) (trace-event trace 0))))
  (ok "fault records once then exposes canonical classified event data"
      (and event
           (action-event-matches? event kw-fault "fault/a" fault-site 1 1)
           (canonical-action-error-matches?
             fault-result kw-fault (jolt-get s kw-generation) event))))

(jolt-checkpoint-reset!)
(jolt-fiber-carrier-count-set! 1)
(define cancel-site "test.action/cancel")
(define cancel-late-site "test.action/cancel-late")
(define cancel-late-fast-site "test.action/cancel-late-fast")
(define cancel-result #f)
(define cancel-sticky-fast-path-result #f)
(define cancel-sticky-same-binding-result #f)
(define cancel-sticky-rebind-result #f)
(define cancel-sibling-result #f)
(define cancel-sibling-completed? #f)
(jolt-checkpoint-register-site! cancel-site '(continue cancel))
(define cancel-plan-result
  (attempt
    (lambda ()
      (jolt-checkpoint-install-plan!
        (jolt-hash-map (jolt-vector "cancel/a" cancel-site 1) kw-cancel)))))
(sa-fiber-spawn
  (lambda ()
    (jolt-checkpoint-bind-actor! "cancel/a")
    (set! cancel-result
          (after-action-plan cancel-plan-result
            (lambda () (jolt-checkpoint! cancel-site '(continue cancel)))))
    (set! cancel-sticky-fast-path-result
          (attempt-unwrapped
            (lambda ()
              (jolt-checkpoint-continue! cancel-late-fast-site))))
    ;; Sticky cancellation is actor-recorder state, not binding state. Both
    ;; probes use an unregistered later site so a wrong implementation is
    ;; caught if it allocates a hit/seq or mutates the site table before it
    ;; rethrows the original cancellation.
    (set! cancel-sticky-same-binding-result
          (attempt-unwrapped
            (lambda ()
              (jolt-checkpoint! cancel-late-site '(continue yield)))))
    (jolt-checkpoint-unbind-actor!)
    (jolt-checkpoint-bind-actor! "cancel/a")
    (set! cancel-sticky-rebind-result
          (attempt-unwrapped
            (lambda ()
              (jolt-checkpoint! cancel-late-site '(continue yield)))))))
(sa-fiber-spawn
  (lambda ()
    (jolt-checkpoint-bind-actor! "cancel/sibling")
    (set! cancel-sibling-result
          (after-action-plan cancel-plan-result
            (lambda () (jolt-checkpoint! cancel-site '(continue cancel)))))
    (set! cancel-sibling-completed? (not (error-result? cancel-sibling-result)))))
(sa-fiber-run-all)
(let* ((s (snapshot))
       (trace (snap-trace s))
       (e0 (and (= 2 (pvec-count trace)) (trace-event trace 0)))
       (e1 (and (= 2 (pvec-count trace)) (trace-event trace 1))))
  (ok "cancel is cooperative and confined to the current actor"
      (and e0 e1
           (action-event-matches? e0 kw-cancel "cancel/a" cancel-site 1 1)
           (canonical-action-error-matches?
             cancel-result kw-cancel (jolt-get s kw-generation) e0)
           (canonical-action-error-matches?
             cancel-sticky-fast-path-result
             kw-cancel (jolt-get s kw-generation) e0)
           (canonical-action-error-matches?
             cancel-sticky-same-binding-result
             kw-cancel (jolt-get s kw-generation) e0)
           (canonical-action-error-matches?
             cancel-sticky-rebind-result
             kw-cancel (jolt-get s kw-generation) e0)
           cancel-sibling-completed?
           (jolt-nil? (jolt-get (jolt-get s kw-sites) cancel-late-fast-site))
           (jolt-nil? (jolt-get (jolt-get s kw-sites) cancel-late-site))
           (action-event-matches? e1 jolt-nil "cancel/sibling" cancel-site 1 2))))

(jolt-checkpoint-reset!)
(define cancel-reset-site "test.action/cancel-reset")
(jolt-checkpoint-register-site! cancel-reset-site '(continue))
(jolt-checkpoint-install-plan!
  (jolt-hash-map (jolt-vector "cancel/a" cancel-reset-site 1) kw-continue))
(jolt-checkpoint-bind-actor! "cancel/a")
(define cancel-reset-result
  (attempt-unwrapped
    (lambda () (jolt-checkpoint! cancel-reset-site '(continue)))))
(let* ((s (snapshot))
       (trace (snap-trace s))
       (event (and (= 1 (pvec-count trace)) (trace-event trace 0))))
  (ok "reset clears sticky cancel for a fresh generation"
      (and (not (error-result? cancel-reset-result))
           event
           (action-event-matches?
             event kw-continue "cancel/a" cancel-reset-site 1 1))))

(if (= fails 0)
    (printf "checkpoint runtime: ~a checks passed\n" total)
    (begin
      (printf "checkpoint runtime: ~a/~a checks FAILED\n" fails total)
      (exit 1)))
