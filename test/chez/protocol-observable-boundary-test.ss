(import (chezscheme))
(load "host/chez/rt.ss")
(define total 0)
(define fails 0)
(define (ok name value)
  (set! total (+ total 1))
  (unless value (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (thrown f) (guard (e (#t #t)) (f) #f))
(define make-site
  (if (equal? (getenv "PROTOCOL_BOUNDARY_CONTROL") "omitted")
      (lambda (proto method . hooks) (make-protocol-method-site proto method))
      make-protocol-method-site))
(define proto "boundary/Methods")
(define ordinary (lambda (x) 0))
(define changed (lambda (x) 1))
(register-protocol-method "Object" proto "m" ordinary)
(register-protocol-method "nil" proto "m" ordinary)
(define register-class (var-deref "clojure.core" "__register-class!"))
(register-class (lambda (x) #f) (lambda (x) "boundary.Never")
                (lambda (x) empty-pvec) (keyword #f "host-table"))
(define calls 0)
(define site
  (make-site proto "m" (lambda () (set! calls (+ calls 1)))))
(ok "cold ordinary selection" (eq? ordinary (site "a")))
(ok "cold classification has a boundary" (= calls 1))
(set! calls 0)
(site "b") (site "c")
(ok "proven pure warm string family skips boundary" (= calls 0))

;; An unknown tag producer is observable even when registry lookup is cached.
(let ((tags value-host-tags) (trace '()) (prefix "hidden"))
  (let ((buffered
         (make-site proto "m"
           (lambda ()
             (ok "boundary not under counted lock" (= (jolt-locks-held) 0))
             (set! prefix "published")
             (set! trace (cons 'boundary trace))))))
    (dynamic-wind
      (lambda () (set! value-host-tags
                   (lambda (x)
                     (ok "predicate sees complete published prefix" (string=? prefix "published"))
                     (set! trace (cons 'predicate trace)) (tags x))))
      (lambda ()
        (buffered #t) (set! prefix "hidden") (buffered #f)
        (ok "boundary precedes every observable cold and cached classification"
            (equal? (reverse trace) '(boundary predicate boundary predicate))))
      (lambda () (set! value-host-tags tags)))))

;; The hook can itself extend a method. Capture the selected registry/graph
;; state after the hook; the returned method must honor its completed change.
(let ((once? #t))
  (let ((updating
         (make-site proto "m"
           (lambda () (when once?
             (set! once? #f)
             (register-protocol-method "java.lang.String" proto "m" changed))))))
    (ok "completed hook extension is visible" (eq? changed (updating "update")))
    (ok "new family cache selects changed method" (eq? changed (updating "warm")))))

(let ((tags value-host-tags) (classified 0))
  (dynamic-wind
    (lambda () (set! value-host-tags (lambda (x) (set! classified (+ classified 1)) (tags x))))
    (lambda ()
      (let ((rejecting (make-site proto "m"
                         (lambda () (error 'boundary-test "stop before predicate")))))
        (ok "hook exception propagates" (thrown (lambda () (rejecting #t))))
        (ok "predicate not executed after hook exception" (= classified 0))))
    (lambda () (set! value-host-tags tags))))

(ok "invalid boundary rejected at construction"
    (thrown (lambda () (make-protocol-method-site proto "m" #f))))
(ok "two boundaries rejected at construction"
    (thrown (lambda () (make-protocol-method-site proto "m" (lambda () #t) (lambda () #t)))))
(ok "existing two-argument site remains supported"
    (eq? changed ((make-protocol-method-site proto "m") "plain")))
(printf "protocol-observable-boundary: ~a/~a checks passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
