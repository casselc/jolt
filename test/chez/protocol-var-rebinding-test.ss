;; Inference annotations do not license ignoring method Vars in open-world mode.
(import (chezscheme))
(load "host/chez/run-gate-harness.ss")

(define analyze (var-deref "jolt.analyzer" "analyze"))
(define emit-top (var-deref "jolt.backend-scheme" "emit-top-form"))
(define set-dl! (var-deref "jolt.backend-scheme" "set-direct-link!"))
(define kw (lambda (name) (keyword #f name)))
(define U ((var-deref "jolt.passes.types" "new-unit")))
((var-deref "jolt.backend-scheme" "set-emit-unit!") U)
((var-deref "jolt.backend-scheme" "set-prelude-mode!") #t)
(define (evals source) (jolt-compile-eval (string-append "(do " source ")") "user"))
(define (run-emit source) (eval (read (open-input-string source)) (interaction-environment)))

(evals "(defprotocol LiveMethod (answer [x]))
        (defrecord Box [n] LiveMethod (answer [x] (:n x)))
        (extend-type String LiveMethod (answer [x] :string))
        (def box (->Box 7))")

(define (annotated-call name mono?)
  (let* ((dn (analyze (make-analyze-ctx "user")
                      (jolt-ce-read (string-append "(def " name " (fn [x] (answer x)))"))))
         (init (jolt-get dn (kw "init")))
         (arity (jolt-nth (jolt-get init (kw "arities")) 0))
         (body (jolt-get arity (kw "body")))
         (marked (jolt-assoc body (kw "proto") "user/LiveMethod" (kw "method") "answer"))
         (marked (if mono?
                     (jolt-assoc marked (kw "devirt-type") "user.Box"
                                (kw "devirt-proto") "user/LiveMethod"
                                (kw "devirt-method") "answer") marked)))
    (jolt-assoc dn (kw "init")
                (jolt-assoc init (kw "arities")
                            (jolt-vector (jolt-assoc arity (kw "body") marked))))))

(for-each
  (lambda (mono?)
    (let* ((name (if mono? "open-mono" "open-poly"))
           (node (annotated-call name mono?)))
      (set-dl! #f)
      (let ((emitted (emit-top node)))
        (gate-check "open-world retains method Var lookup"
                    (gate-sub? emitted "\"answer\"") #t)
        (gate-check "open-world does not emit PIC" (gate-sub? emitted "jolt-pic-") #f)
        (gate-check "open-world does not emit devirt" (gate-sub? emitted "devirt-resolve") #f)
        (run-emit emitted)
        (gate-check "open-world ordinary dispatch" (evals (string-append "(" name " box)")) 7)
        (gate-check "open-world honors warmed method Var replacement"
                    (evals (string-append "(with-redefs [answer (fn [x] :rebound)] (" name " box))"))
                    (keyword #f "rebound"))
        (gate-check "open-world restores original method"
                    (evals (string-append "(" name " box)")) 7)
        ;; Nonprocedure IFn roots must retain ordinary invocation dispatch too.
        (gate-check "open-world invokes replacement map"
                    (evals (string-append "(with-redefs [answer {box :map-root}] (" name " box))"))
                    (keyword #f "map-root"))
        (unless mono?
          (gate-check "external extension dispatch" (evals (string-append "(" name " \"x\")"))
                      (keyword #f "string"))
          (gate-check "external extension honors Var replacement"
                      (evals (string-append "(with-redefs [answer (fn [x] :external)] (" name " \"x\"))"))
                      (keyword #f "external"))))
      ;; Non-vacuity: the same annotations retain optimization in release mode.
      (set-dl! #t)
      (let ((emitted (emit-top (annotated-call (if mono? "closed-mono" "closed-poly") mono?))))
        (gate-check "closed-world keeps selected protocol optimization"
                    (gate-sub? emitted (if mono? "devirt-resolve" "jolt-pic-make")) #t)
        (run-emit emitted)
        (gate-check "closed-world correct dispatch"
                    (evals (if mono? "(closed-mono box)" "(closed-poly box)")) 7))
      (set-dl! #f)))
  '(#f #t))

(evals "(extend-type Box LiveMethod (answer [x] (* (:n x) 10)))")
(gate-check "closed PIC retains live extension invalidation" (evals "(closed-poly box)") 70)
(gate-check "closed devirt retains live extension invalidation" (evals "(closed-mono box)") 70)
(gate-check "open-world observes live extension" (evals "(open-poly box)") 70)
(gate-summary "protocol-var-rebinding")
