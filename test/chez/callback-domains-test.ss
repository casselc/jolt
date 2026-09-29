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
        (tags jt-user-value-tags-arms) (prefix jolt-invoke-prefix-arms))
    (dynamic-wind
      (lambda () (set! jt-user-value-tags-arms '())) thunk
      (lambda () (set! jolt-eq-arms eqs) (set! jolt-class-arms classes)
        (set! jt-user-value-tags-arms tags) (set! jolt-invoke-prefix-arms prefix)))))

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

(printf "callback-domains: ~a/~a assertions passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
