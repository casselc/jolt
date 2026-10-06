;; Explicit host-table callback domains; no inferred predicate purity/cache.
;; Run from the repository root through the workspace's pinned Chez wrapper.
(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define register-eq (var-deref "clojure.core" "__register-eq!"))
(define register-class (var-deref "clojure.core" "__register-class!"))
(define register-instance (var-deref "clojure.core" "__register-instance-check!"))
(define domain (keyword #f "host-table"))
(define (table) (jolt-tagged-table (keyword "callback.domain" "test")))
(define (thrown thunk)
  (guard (e (#t (if (jolt-throw-condition? e) (jolt-throw-condition-value e) e)))
    (thunk) #f))
(define (error-class? name thunk)
  (let ((e (thrown thunk)))
    (and (jolt-ex-info-record? e)
         (string=? name (jolt-ex-info-record-class-name e)))))
;; Synchronous cases only: no fibers park through these test-local winders.
(define (isolated thunk)
  (let ((eqs jolt-eq-arms) (classes jolt-class-arms)
        (tags jt-user-value-tags-arms) (prefix jolt-invoke-prefix-arms)
        (tag-domains jt-user-value-tags-domain-snapshot))
    (dynamic-wind
      (lambda () (set! jt-user-value-tags-arms '())) thunk
      (lambda () (set! jolt-eq-arms eqs) (set! jolt-class-arms classes)
        (set! jt-user-value-tags-arms tags)
        (set! jt-user-value-tags-domain-snapshot tag-domains)
        (set! jolt-invoke-prefix-arms prefix)))))

;; Preserve the new upstream class fast-path guard, including atomic rejection.
(isolated (lambda ()
  (let ((classes jolt-class-arms) (tags jt-user-value-tags-arms))
    (ok "legacy class cannot claim runtime-owned strings"
      (thrown (lambda () (register-class string? (lambda (x) "bad.Class")
                          (lambda (x) (jolt-vector "bad.Class"))))))
    (ok "rejected class registration preserves both registries"
      (and (eq? classes jolt-class-arms) (eq? tags jt-user-value-tags-arms))))))

;; Reject before even invoking a callback, including equality's registration
;; probes. Namespaced keywords, strings, nil and false are NOT domain aliases.
(for-each (lambda (bad)
  (isolated (lambda ()
    (let ((eqs jolt-eq-arms) (classes jolt-class-arms)
          (tags jt-user-value-tags-arms) (calls 0))
      (define (p . args) (set! calls (+ calls 1)) #f)
      (ok "invalid eq domain throws typed before registration"
        (error-class? "java.lang.IllegalArgumentException"
          (lambda () (register-eq p p bad))))
      (ok "invalid class domain throws typed before registration"
        (error-class? "java.lang.IllegalArgumentException"
          (lambda () (register-class p p p bad))))
      (ok "invalid domain invokes no callbacks" (= calls 0))
      (ok "invalid domain preserves all registry identities"
        (and (eq? eqs jolt-eq-arms) (eq? classes jolt-class-arms)
             (eq? tags jt-user-value-tags-arms)))))))
  (list jolt-nil #f "host-table" (keyword #f "unknown")
        (keyword "other" "host-table")))

(isolated (lambda ()
  (let ((calls 0))
    (define (unexpected . args) (set! calls (+ calls 1)) 'yes)
    (register-eq unexpected unexpected domain)
    (register-class unexpected unexpected unexpected domain)
    (ok "domain prevents out-of-domain registration probes" (= calls 0))
    (for-each (lambda (v)
      (ok "eq predicate rejects non-table pair without callback"
          (eq? #f ((caar jolt-eq-arms) car v)))
      (ok "class predicate rejects non-table without callback"
          (eq? #f ((caar jolt-class-arms) v)))
      (value-host-tags v))
      (list "child" 7 empty-pmap (jolt-vector 1) car jolt-nil))
    (ok "actual mixed equality remains false" (not (jolt=2 car "child")))
    (ok "no predicate/handler/tag callbacks outside domain" (= calls 0)))))

;; Either operand is sufficient; preserve truthiness and argument/effect order.
(isolated (lambda ()
  (let ((left (table)) (right (table)) (trace '()))
    (register-eq
      (lambda (a b) (set! trace (cons (list 'p a b) trace)) 'yes)
      (lambda (a b) (set! trace (cons (list 'h a b) trace)) 'yes) domain)
    (for-each (lambda (pair)
      (set! trace '())
      (ok "either/both host-table operands reach equality" (jolt=2 (car pair) (cdr pair)))
      (ok "one predicate then one handler with original operands"
        (equal? (list (list 'p (car pair) (cdr pair))
                      (list 'h (car pair) (cdr pair))) (reverse trace))))
      (list (cons left "other") (cons car right) (cons left right))))))

(isolated (lambda ()
  (let ((obj (table)) (trace '()))
    (register-class
      (lambda (x) (set! trace (cons 'pred trace)) 'yes)
      (lambda (x) (set! trace (cons 'class trace)) "domain.Class")
      (lambda (x) (set! trace (cons 'tags trace))
        (jolt-vector "domain.Class" "java.lang.Object")) domain)
    (ok "in-domain class predicate coerces truthiness" ((caar jolt-class-arms) obj))
    (ok "in-domain class callback result" (string=? "domain.Class" ((cdar jolt-class-arms) obj)))
    (ok "in-domain protocol tags converted unchanged"
        (equal? '("domain.Class" "java.lang.Object") (value-host-tags obj)))
    (ok "class and tag callback effect order" (equal? '(pred class pred tags) (reverse trace))))))

;; Legacy callbacks still observe ordinary values and may claim mixed function
;; pairs. Adding a domain arm must not bypass unrestricted older registrations.
(isolated (lambda ()
  (let ((trace '()))
    (register-eq
      (lambda (a b) (set! trace (cons 'legacy trace)) (and (procedure? a) (string? b)))
      (lambda (a b) (set! trace (cons 'handler trace)) #t))
    (register-eq (lambda (a b) (error 'test "outside domain")) (lambda (a b) #f) domain)
    (set! trace '())
    (ok "legacy mixed procedure/string equality remains legal" (jolt=2 car "child"))
    (ok "legacy predicate/handler effects retained" (equal? '(legacy handler) (reverse trace)))
    ;; Upstream 0.8.14 refuses library claims on runtime-owned class types.
    ;; A raw Scheme vector is a non-table extension value, not a Jolt vector.
    (register-class (lambda (x) (set! trace (cons 'class-p trace)) (vector? x))
      (lambda (x) "legacy.Class") (lambda (x) (jolt-vector "legacy.Class")))
    (set! trace '())
    (ok "legacy tags still claim non-table extension" (equal? '("legacy.Class") (value-host-tags (vector 'child))))
    (ok "legacy class predicate effect retained" (equal? '(class-p) (reverse trace))))))

(isolated (lambda ()
  (let ((obj (table)) (trace '()))
    (register-eq (lambda (a b) (set! trace (cons 'old trace)) #t)
      (lambda (a b) (set! trace (cons 'handler trace)) #t) domain)
    (register-eq (lambda (a b) (set! trace (cons 'new trace)) jolt-nil)
      (lambda (a b) (error 'test "nil predicate handler")) domain)
    (ok "nil predicate falls through" (jolt=2 obj "child"))
    (ok "domain equality remains newest-first" (equal? '(new old handler) (reverse trace)))
    (register-class (lambda (x) #t) (lambda (x) "domain.Old")
      (lambda (x) (jolt-vector "domain.Old")) domain)
    (register-class (lambda (x) #t) (lambda (x) "domain.New")
      (lambda (x) (jolt-vector "domain.New")) domain)
    (ok "class arms remain newest-first" (string=? "domain.New" ((cdar jolt-class-arms) obj)))
    (ok "tag arms remain oldest-first" (equal? '("domain.Old") (value-host-tags obj))))))

;; The domain gate reuses the original bridge fallback, rather than fixed-arity
;; invocation that could bypass keyword-prefix callables or freeze Var roots.
(isolated (lambda ()
  (let ((obj (table)) (p (keyword "domain" "pred")) (h (keyword "domain" "handler"))
        (c (keyword "domain" "class")) (t (keyword "domain" "tags")) (seen '()))
    (register-invoke-prefix-arm! (lambda (f) (memq f (list p h c t)))
      (lambda (f args) (set! seen (cons f seen))
        (cond ((eq? f c) "domain.Prefix") ((eq? f t) (jolt-vector "domain.Prefix"))
              (else #t))))
    (register-eq p h domain)
    (register-class p c t domain)
    (ok "nonprocedure domain eq invokes prefix" (jolt=2 obj "child"))
    (ok "nonprocedure domain class predicate invokes prefix" ((caar jolt-class-arms) obj))
    (ok "nonprocedure domain class callback invokes prefix"
      (string=? "domain.Prefix" ((cdar jolt-class-arms) obj)))
    (ok "nonprocedure domain tags invoke prefix" (equal? '("domain.Prefix") (value-host-tags obj)))
    (ok "all fallback callback effects in order" (equal? (list p h p c p t) (reverse seen))))))

(isolated (lambda ()
  (let ((obj (table)) (cell (jolt-var "callback.domain.test" "pred")) (calls 0))
    (var-cell-root-set! cell (lambda args (set! calls (+ calls 1)) #f))
    (register-eq cell (lambda (a b) #t) domain)
    (register-class cell (lambda (x) "domain.Live") (lambda (x) (jolt-vector "domain.Live")) domain)
    (ok "Var predicate initially false" (not ((caar jolt-eq-arms) obj "child")))
    (var-cell-root-set! cell (lambda args (set! calls (+ calls 1)) #t))
    (ok "Var eq predicate replacement remains live" (jolt=2 obj "child"))
    (ok "Var class predicate replacement remains live" (equal? '("domain.Live") (value-host-tags obj)))
    (set! calls 0)
    ((caar jolt-eq-arms) car "child")
    (value-host-tags "child")
    (ok "rebound always-true predicate still suppressed outside domain" (= calls 0)))))

(isolated (lambda ()
  (let ((obj (table)) (marker (vector 'callback-error)))
    (register-eq (lambda (a b) (raise marker)) (lambda (a b) #t) domain)
    (ok "domain eq predicate exception identity"
      (eq? marker (thrown (lambda () (jolt=2 obj "child")))))
    (register-eq (lambda (a b) #t) (lambda (a b) (raise marker)) domain)
    (ok "domain eq handler exception identity"
      (eq? marker (thrown (lambda () (jolt=2 obj "child")))))
    (register-class (lambda (x) (raise marker)) (lambda (x) "unused")
      (lambda (x) (jolt-vector "unused")) domain)
    (ok "domain class predicate exception identity"
      (eq? marker (thrown (lambda () (value-host-tags obj)))))
    (register-eq (lambda (x) #t) (lambda (a b) #t) domain)
    (ok "wrong arity remains invocation-time fallback"
      (error-class? "clojure.lang.ArityException" (lambda () (jolt=2 obj "child")))))))

;; Instance callbacks are oldest-first and tri-state. Never cache their result,
;; even for values with the same kind and an unchanged registration epoch.
(define (isolated-instance thunk)
  (let ((saved user-instance-checks))
    (dynamic-wind
      (lambda () (set! user-instance-checks '())
        (set! instance-arms-epoch (fx+ instance-arms-epoch 1)))
      thunk
      (lambda () (set! user-instance-checks saved)
        (set! instance-arms-epoch (fx+ instance-arms-epoch 1))))))
(isolated-instance (lambda ()
  (let ((saved user-instance-checks) (epoch instance-arms-epoch) (calls 0))
    (for-each (lambda (bad)
      (ok "invalid instance domain throws before registration"
        (error-class? "java.lang.IllegalArgumentException"
          (lambda () (register-instance (lambda args (set! calls (+ calls 1)) #t) bad)))))
      (list jolt-nil #f "host-table" (keyword "other" "host-table")))
    (ok "invalid instance domain preserves registry, epoch and effects"
      (and (eq? saved user-instance-checks) (= epoch instance-arms-epoch) (= calls 0))))))
(isolated-instance (lambda ()
  (let ((obj (table)) (answer #t) (trace '())
        (name (jolt-symbol #f "domain.Instance"))
        (site (jolt-instance-site-make)))
    (register-instance
      (lambda (cn v) (set! trace (cons (list cn v) trace)) answer) domain)
    (for-each (lambda (v)
      (ok "non-table instance falls through" (not (jolt-instance-site site name v))))
      (list "child" 7 #f empty-pmap (jolt-vector 1) car jolt-nil))
    (ok "no instance callbacks outside domain" (null? trace))
    (ok "in-domain instance true" (jolt-instance-site site name obj))
    (set! answer #f)
    (ok "same-kind false answer stays live" (not (jolt-instance-site site name obj)))
    (set! answer jolt-nil)
    (register-instance (lambda (cn v) #t))
    (ok "nil instance answer falls through to legacy" (jolt-instance-site site name obj))
    (ok "legacy can claim primitive through warmed site" (jolt-instance-site site name "child"))
    (ok "domain callback receives unchanged class name and receiver"
      (equal? (list (list "domain.Instance" obj) (list "domain.Instance" obj)
                    (list "domain.Instance" obj)) (reverse trace)))
    (set! trace '())
    (ok "Object rule remains ahead of callbacks" (instance-check (jolt-symbol #f "Object") obj))
    (ok "Object invokes no callbacks" (null? trace)))))
(isolated-instance (lambda ()
  (let ((obj (table)) (marker (vector 'instance-error)))
    (register-instance (lambda (cn v) (raise marker)) domain)
    (ok "in-domain instance exception identity"
      (eq? marker (thrown (lambda () (instance-check (jolt-symbol #f "domain.Bad") obj)))))
    (ok "instance exception suppressed outside domain"
      (not (instance-check (jolt-symbol #f "domain.Bad") "child"))))))
(isolated-instance (lambda ()
  (let ((obj (table)) (calls 0) (name (jolt-symbol #f "domain.Order")))
    (register-instance (lambda (cn v) #f) domain)
    (register-instance (lambda (cn v) (set! calls (+ calls 1)) #t))
    (ok "oldest definitive false wins" (not (instance-check name obj)))
    (ok "false does not invoke later callbacks" (= calls 0)))))
(isolated-instance (lambda ()
  (let ((obj (table)) (cell (jolt-var "callback.domain.test" "instance"))
        (name (jolt-symbol #f "domain.Live")))
    (var-cell-root-set! cell (lambda (cn v) #f))
    (register-instance cell domain)
    (ok "instance Var starts false" (not (instance-check name obj)))
    (var-cell-root-set! cell (lambda (cn v) #t))
    (ok "instance Var replacement stays live" (instance-check name obj)))))
(isolated (lambda () (isolated-instance (lambda ()
  (let ((obj (table)) (callback (keyword "domain" "instance")) (calls 0))
    (register-invoke-prefix-arm! (lambda (f) (eq? f callback))
      (lambda (f args) (set! calls (+ calls 1)) #t))
    (register-instance callback domain)
    (ok "instance nonprocedure invokes prefix fallback"
      (instance-check (jolt-symbol #f "domain.Prefix") obj))
    (ok "instance prefix effect count" (= calls 1)))))))

;; A summary qualifies only its exact immutable arm list. Domain fast rejection
;; is a consequence of explicit opt-in, never inferred predicate purity.
(isolated (lambda ()
  (let ((obj (table)) (domain-calls 0) (legacy-calls 0))
    (register-class
      (lambda (x) (set! domain-calls (+ domain-calls 1)) (eq? x obj))
      (lambda (x) "tag.domain.Test")
      (lambda (x) (jolt-vector "tag.domain.Test" "Object")) domain)
    (ok "tag domain summary matches current list"
      (eq? jt-user-value-tags-arms (vector-ref jt-user-value-tags-domain-snapshot 0)))
    (ok "one explicit domain proves all-domain summary"
      (vector-ref jt-user-value-tags-domain-snapshot 1))
    (set! domain-calls 0)
    (for-each value-host-tags (list "plain" 42 #f empty-pvec empty-pmap))
    (ok "fast domain rejection has no user effects" (= domain-calls 0))
    (ok "positive table route retains tags"
      (equal? (value-host-tags obj) '("tag.domain.Test" "Object")))
    (ok "positive table predicate still executes once" (= domain-calls 1))
    (let ((old-summary jt-user-value-tags-domain-snapshot))
      (register-class
        (lambda (x) (set! legacy-calls (+ legacy-calls 1)) #f)
        (lambda (x) "tag.domain.Never") (lambda (x) empty-pvec))
      (ok "legacy registration invalidates all-domain claim"
        (not (vector-ref jt-user-value-tags-domain-snapshot 1)))
      (set! legacy-calls 0)
      (value-host-tags "plain")
      (ok "legacy predicate effects remain visible" (= legacy-calls 1))
      ;; Simulate the publication gap / stale metadata after a changed arm list.
      (set! jt-user-value-tags-domain-snapshot old-summary)
      (set! legacy-calls 0)
      (value-host-tags "plain")
      (ok "stale summary cannot skip newly installed legacy arm" (= legacy-calls 1))
      (register-class (lambda (x) #f) (lambda (x) "tag.domain.Never2")
                      (lambda (x) empty-pvec) domain)
      (ok "uncertain prior summary cannot regain all-domain claim"
        (not (vector-ref jt-user-value-tags-domain-snapshot 1)))))))

(printf "callback-domains: ~a/~a assertions passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
