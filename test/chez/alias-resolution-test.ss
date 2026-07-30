;; Categorical namespace-alias resolution against a caller-supplied compiler
;; seed. host/chez/transient-seed-gate.sh supplies a source-converged pair while
;; the rebase deliberately defers the one checked-in seed remint.
;;
;;   chez --script test/chez/alias-resolution-test.ss PRELUDE IMAGE
(import (chezscheme))

(define args (cdr (command-line)))
(unless (= (length args) 2)
  (display "usage: alias-resolution-test.ss PRELUDE IMAGE\n" (current-error-port))
  (exit 2))

(load "host/chez/rt.ss")
(set-chez-ns! "clojure.core")
(load (car args))
(load "host/chez/post-prelude.ss")
(set-chez-ns! "user")
(load "host/chez/host-contract.ss")
(load (cadr args))
(load "host/chez/compile-eval.ss")

(define tests
  (list
    (list
      "defined alias member resolves in its target namespace"
      "(do (eval '(ns unit.alias_defined_target)) (eval '(def answer 42)) (eval '(ns unit.alias_defined_consumer)) (alias 't 'unit.alias_defined_target) (eval 't/answer))"
      "42")
    (list
      "declare permits an alias-qualified forward reference"
      "(do (eval '(ns unit.alias_declared_target)) (eval '(declare late-value)) (eval '(ns unit.alias_declared_consumer)) (alias 't 'unit.alias_declared_target) (eval '(defn read-late [] (t/late-value))) (eval '(ns unit.alias_declared_target)) (eval '(defn late-value [] 43)) (eval '(ns unit.alias_declared_consumer)) ((resolve 'read-late)))"
      "43")
    (list
      "missing alias member reports a structured analysis error"
      "(do (eval '(ns unit.alias_missing_target)) (eval '(ns unit.alias_missing_consumer)) (alias 't 'unit.alias_missing_target) (try (eval 't/missing) :not-thrown (catch clojure.lang.ExceptionInfo e (get-in (ex-data e) [:jolt/error :type])) (catch Throwable e :wrong-error)))"
      ":unresolved-symbol")
    (list
      "missing alias member stays strict in a nested body"
      "(do (eval '(ns unit.alias_nested_target)) (eval '(ns unit.alias_nested_consumer)) (alias 't 'unit.alias_nested_target) (try (eval '(defn nested-missing [] t/missing)) :not-thrown (catch clojure.lang.ExceptionInfo e (get-in (ex-data e) [:jolt/error :type])) (catch Throwable e :wrong-error)))"
      ":unresolved-symbol")
    (list
      "class-like alias member cannot fall through to host static"
      "(do (eval '(ns unit.alias_classlike_target)) (eval '(ns unit.alias_classlike_consumer)) (alias 't 'unit.alias_classlike_target) (try (eval 't/String) :not-thrown (catch clojure.lang.ExceptionInfo e (get-in (ex-data e) [:jolt/error :type])) (catch Throwable e :wrong-error)))"
      ":unresolved-symbol")
    (list
      "allow-unresolved-vars does not loosen a qualified alias"
      "(do (eval '(ns unit.alias_allow_target)) (eval '(ns unit.alias_allow_consumer)) (alias 't 'unit.alias_allow_target) (binding [*allow-unresolved-vars* true] (try (eval 't/missing) :not-thrown (catch clojure.lang.ExceptionInfo e (get-in (ex-data e) [:jolt/error :type])) (catch Throwable e :wrong-error))))"
      ":unresolved-symbol")
    (list
      "known alias shadows a real host class qualifier"
      "(do (eval '(ns unit.alias_hostclass_target)) (eval '(ns unit.alias_hostclass_consumer)) (alias 'Math 'unit.alias_hostclass_target) (try (eval '(Math/abs -4)) :not-thrown (catch clojure.lang.ExceptionInfo e (get-in (ex-data e) [:jolt/error :type])) (catch Throwable e :wrong-error)))"
      ":unresolved-symbol")
    (list
      "real host static dispatch remains available"
      "(Math/abs -4)"
      "4")))

(define pass 0)
(define fails '())

(for-each
  (lambda (row)
    (let ((label (car row)) (expr (cadr row)) (expected (caddr row)))
      (guard (e (#t
                  (set! fails (cons (list label "raised" e) fails))))
        (let ((actual (jolt-repl-str (jolt-compile-eval expr "user"))))
          (if (string=? actual expected)
              (set! pass (+ pass 1))
              (set! fails (cons (list label actual expected) fails)))))
      (set-chez-ns! "user")))
  tests)

(if (null? fails)
    (begin
      (printf "alias resolution gate: ~a/~a passed\n" pass (length tests))
      (exit 0))
    (begin
      (printf "alias resolution gate: ~a/~a passed\n" pass (length tests))
      (for-each
        (lambda (failure)
          (printf "  FAIL ~a: got ~s expected ~s\n"
                  (car failure) (cadr failure) (caddr failure)))
        (reverse fails))
      (exit 1)))
