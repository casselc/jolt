;; Callback bridge semantics and allocation mechanism, not a timing benchmark.
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
(define (mixed? a b) (and (procedure? a) (string? b)))
(define (thrown thunk)
  (guard (e (#t (if (jolt-throw-condition? e) (jolt-throw-condition-value e) e)))
    (thunk) #f))
(define (arity-error? thunk)
  (let ((e (thrown thunk)))
    (and (jolt-ex-info-record? e)
         (string=? "clojure.lang.ArityException" (jolt-ex-info-record-class-name e)))))
;; No test registration escapes its case. These are synchronous raw callbacks:
;; no fibers park through the test-local dynamic-wind interceptors.
(define (isolated thunk)
  (let ((eqs jolt-eq-arms) (classes jolt-class-arms)
        (tags jt-user-value-tags-arms) (prefix jolt-invoke-prefix-arms))
    (dynamic-wind
      (lambda () (set! jt-user-value-tags-arms '())) thunk
      (lambda () (set! jolt-eq-arms eqs) (set! jolt-class-arms classes)
        (set! jt-user-value-tags-arms tags) (set! jolt-invoke-prefix-arms prefix)))))
(define (observe-invoke thunk)
  (let ((original jolt-invoke) (calls 0))
    (dynamic-wind
      (lambda () (set! jolt-invoke
        (lambda (f . args) (set! calls (+ calls 1)) (apply original f args))))
      (lambda () (let ((v (thunk))) (vector v calls)))
      (lambda () (set! jolt-invoke original)))))

;; This legal mixed procedure/string arm MUST remain reachable; an identity-only
;; sentinel comparison would silently skip it. Registration probes still reject
;; a predicate that claims the runtime-owned procedure/procedure pair.
(isolated (lambda ()
  (register-eq mixed? (lambda (a b) #t))
  (let ((r (observe-invoke (lambda () (jolt=2 car "child")))))
    (ok "mixed procedure/string arm participates" (vector-ref r 0))
    (ok "ordinary eq callbacks avoid generic invocation" (= 0 (vector-ref r 1))))
  (ok "runtime-owned pair is still rejected"
      (thrown (lambda () (register-eq
        (lambda (a b) (and (procedure? a) (procedure? b))) (lambda (a b) #t)))))))

;; Each predicate runs exactly once in newest-first order; the first match wins.
(isolated (lambda ()
  (let ((trace '()))
    (register-eq (lambda (a b) (set! trace (cons 'old trace)) (mixed? a b))
                 (lambda (a b) (set! trace (cons 'handler trace)) 'truthy))
    (register-eq (lambda (a b) (set! trace (cons 'new trace)) jolt-nil)
                 (lambda (a b) (error 'test "unreachable handler")))
    (set! trace '())
    (ok "truthy result coerces to true" (eq? #t (jolt=2 car "child")))
    (ok "predicate and handler order" (equal? '(new old handler) (reverse trace))))))
(for-each (lambda (falsey)
  (isolated (lambda ()
    (register-eq mixed? (lambda (a b) falsey))
    (ok "false/nil handler coerces to false" (eq? #f (jolt=2 car "child"))))))
  (list #f jolt-nil))

;; Accepted arities include case-lambda and variadic procedures. Their bodies
;; still observe mutable captured state; only immutable callable/arity selection
;; moves to registration time.
(for-each (lambda (handler)
  (isolated (lambda ()
    (register-eq mixed? handler)
    (let ((r (observe-invoke (lambda () (jolt=2 car "child")))))
      (ok "case-lambda/variadic accepted" (vector-ref r 0))
      (ok "accepted two-arity bypasses generic invocation" (= 0 (vector-ref r 1)))))))
  (list (case-lambda ((x) #f) ((a b) #t)) (lambda (a . rest) (= 1 (length rest)))))
(isolated (lambda ()
  (let ((answer #f))
    (register-eq mixed? (lambda (a b) answer))
    (ok "captured mutable state initially false" (not (jolt=2 car "child")))
    (set! answer #t)
    (ok "captured mutable state remains live" (jolt=2 car "child")))))

;; Wrong arity is not rejected eagerly. The original eq registration swallows
;; predicate exceptions during probes; actual dispatch must still throw typed.
(isolated (lambda ()
  (ok "wrong-arity eq predicate registration stays lazy"
      (not (thrown (lambda () (register-eq (lambda (a) #t) (lambda (a b) #t))))))
  (ok "wrong-arity eq predicate throws at call" (arity-error? (lambda () (jolt=2 car "x"))))))
(isolated (lambda ()
  (ok "wrong-arity eq handler registration stays lazy"
      (not (thrown (lambda () (register-eq mixed? (lambda (a) #t))))))
  (ok "wrong-arity eq handler throws at call" (arity-error? (lambda () (jolt=2 car "x"))))))
(for-each (lambda (throw-pred?)
  (isolated (lambda ()
    (let ((sentinel (vector 'callback-exception)))
      (register-eq
        (if throw-pred? (lambda (a b) (if (mixed? a b) (raise sentinel) #f)) mixed?)
        (lambda (a b) (raise sentinel)))
      (ok "predicate/handler exception identity retained"
          (eq? sentinel (thrown (lambda () (jolt=2 car "x")))))))))
  '(#t #f))

;; All three class callbacks use the adapter; predicate truthiness and tag-list
;; conversion stay at their original seams. Observe the actual registered arms.
(isolated (lambda ()
  (let ((obj (vector 'ours)) (trace '()))
    (register-class
      (lambda (x) (set! trace (cons 'pred trace)) (if (eq? obj x) 'yes jolt-nil))
      (case-lambda ((x) (set! trace (cons 'class trace)) "bridge.Class") ((x y) #f))
      (lambda args (set! trace (cons 'tags trace)) (jolt-vector "bridge.Class" "java.lang.Object")))
    (let ((r (observe-invoke (lambda ()
      (let* ((matches? ((caar jolt-class-arms) obj))
             (class ((cdar jolt-class-arms) obj)) (tags (value-host-tags obj)))
        (list matches? class tags))))))
      (ok "class predicate and converted tags"
          (equal? '(#t "bridge.Class" ("bridge.Class" "java.lang.Object")) (vector-ref r 0)))
      (ok "ordinary class callbacks avoid generic invocation" (= 0 (vector-ref r 1)))
      (ok "class callback order unchanged" (equal? '(pred class pred tags) (reverse trace))))
    (ok "class predicate nil coerces to false" (eq? #f ((caar jolt-class-arms) 'other))))))
(for-each (lambda (which)
  (isolated (lambda ()
    (let ((bad (lambda () #t)))
      (ok "wrong-arity class registration stays lazy"
        (not (thrown (lambda () (register-class
          (if (= which 0) bad (lambda (x) #t))
          (if (= which 1) bad (lambda (x) "bridge.Class"))
          (if (= which 2) bad (lambda (x) (jolt-vector "bridge.Class"))))))))
      (ok "wrong-arity class callback throws at call"
        (arity-error? (lambda ()
          (case which
            ((0) ((caar jolt-class-arms) 'x))
            ((1) ((cdar jolt-class-arms) 'x))
            ((2) ((cdar jt-user-value-tags-arms) 'x))))))))))
  '(0 1 2))
(for-each (lambda (which)
  (isolated (lambda ()
    (let* ((sentinel (vector 'class-exception)) (bad (lambda (x) (raise sentinel))))
      (register-class (if (= which 0) bad (lambda (x) #t))
        (if (= which 1) bad (lambda (x) "bridge.Class"))
        (if (= which 2) bad (lambda (x) (jolt-vector "bridge.Class"))))
      (ok "class callback exception identity retained"
        (eq? sentinel (thrown (lambda ()
          (case which
            ((0) ((caar jolt-class-arms) 'x))
            ((1) ((cdar jolt-class-arms) 'x))
            ((2) ((cdar jt-user-value-tags-arms) 'x)))))))))))
  '(0 1 2))
(isolated (lambda ()
  (register-class (lambda (x) #t) (lambda (x) "bridge.Old")
                  (lambda (x) (jolt-vector "bridge.Old")))
  (register-class (lambda (x) #t) (lambda (x) "bridge.New")
                  (lambda (x) (jolt-vector "bridge.New")))
  (ok "class arms remain newest-first" (string=? "bridge.New" ((cdar jolt-class-arms) 'x)))
  (ok "tag arms remain oldest-first" (equal? '("bridge.Old") (value-host-tags 'x)))))

;; Nonprocedure callables retain ORIGINAL prefix precedence, even for a keyword
;; that fixed-arity jolt-invoke1/2 would otherwise treat as a lookup first.
(isolated (lambda ()
  (let ((p (keyword "bridge" "pred")) (h (keyword "bridge" "handler")) (seen '()))
    (register-invoke-prefix-arm! (lambda (f) (or (eq? f p) (eq? f h)))
      (lambda (f args) (set! seen (cons f seen))
        (if (eq? f p) (apply mixed? args) #t)))
    (register-eq p h)
    (set! seen '())
    (let ((r (observe-invoke (lambda () (jolt=2 car "x")))))
      (ok "keyword eq callback uses prefix" (vector-ref r 0))
      (ok "nonprocedure eq callbacks retain generic invocation" (= 2 (vector-ref r 1)))
      (ok "nonprocedure callback order" (equal? (list p h) (reverse seen)))))))
(isolated (lambda ()
  (let ((p (keyword "bridge" "pred")) (c (keyword "bridge" "class"))
        (t (keyword "bridge" "tags")))
    (register-invoke-prefix-arm! (lambda (f) (or (eq? f p) (eq? f c) (eq? f t)))
      (lambda (f args)
        (cond ((eq? f p) #t) ((eq? f c) "bridge.Prefix")
              (else (jolt-vector "bridge.Prefix")))))
    (register-class p c t)
    (let ((r (observe-invoke (lambda ()
      (list ((caar jolt-class-arms) 'x) ((cdar jolt-class-arms) 'x) (value-host-tags 'x))))))
      (ok "keyword class callbacks use prefix"
        (equal? '(#t "bridge.Prefix" ("bridge.Prefix")) (vector-ref r 0)))
      (ok "nonprocedure class callbacks retain generic invocation" (= 4 (vector-ref r 1)))))))

;; Passing a Var captures the Var object, so later roots remain live; passing its
;; present procedure value captures that value, as the original wrappers did.
(isolated (lambda ()
  (let ((cell (jolt-var "callback.bridge.test" "answer")))
    (var-cell-root-set! cell (lambda (a b) #f))
    (register-eq mixed? (var-cell-root cell))
    (var-cell-root-set! cell (lambda (a b) #t))
    (ok "captured procedure ignores later Var root" (not (jolt=2 car "x")))
    (register-eq mixed? cell)
    (ok "Var callback reads current root" (jolt=2 car "x"))
    (var-cell-root-set! cell (lambda (a b) #f))
    (ok "Var callback observes subsequent root" (not (jolt=2 car "x"))))))

;; A large arity mask is a bignum. Preserve the ORIGINAL generic dispatcher's
;; raw Scheme error on invocation, not a new registration-time rejection or an
;; invented ArityException. Include masks that also accept the requested arity.
(define (large-mask-error? thunk)
  (let ((e (thrown thunk)))
    (and (condition? e) (not (jolt-throw-condition? e))
         (message-condition? e) (string=? "~s is not a fixnum" (condition-message e)))))
(for-each (lambda (arity)
  (for-each (lambda (small-arm?)
    (isolated (lambda ()
      (let* ((large (map (lambda (i) (gensym "large")) (iota 70)))
             (small (map (lambda (i) (gensym "small")) (iota arity)))
             (f (eval (if small-arm? `(case-lambda (,small #t) (,large #t))
                          `(lambda ,large #t)) (environment '(chezscheme)))))
        (ok "large-mask registration remains accepted"
          (not (thrown (lambda ()
            (if (= arity 1)
                (register-class f (lambda (x) "bridge.Large")
                  (lambda (x) (jolt-vector "bridge.Large")))
                (register-eq f (lambda (a b) #t)))))))
        (ok "large-mask generic error remains invocation-time"
          (large-mask-error? (lambda ()
            (if (= arity 1) ((caar jolt-class-arms) 'x) (jolt=2 car "x")))))))))
    '(#f #t)))
  '(1 2))

(printf "callback-bridges: ~a/~a assertions passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
