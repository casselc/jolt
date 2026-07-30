;; Ordinary-image gate: host/chez/java/concurrency.ss, loaded WITHOUT the
;; simulation-only overlay (host/chez/sim/runtime.ss), carries none of the
;; future lifecycle hook — no hook global, no id allocator, no
;; jolt-hooked-future record, no install/clear vars — and clojure.core/future
;; still behaves exactly like ordinary Jolt. Run:
;;   chez --script test/chez/ordinary-future-no-sim-hook-test.ss
;;
;; This is the base-image counterpart to future-sim-hook-test.ss, which loads
;; the overlay explicitly and exercises the hook itself.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a~n" name)))
(define (ev s) (jolt-compile-eval (string-append "(do " s ")") "user"))
(define (render s) (jolt-final-str (ev s)))
(define (is name s expected)
  (ok (string-append name " => " expected)
      (string=? (render s) expected)))

;; --- the overlay's symbols must not exist in the ordinary image -------------
(for-each
 (lambda (sym)
   (ok (string-append "ordinary image has no " (symbol->string sym) " binding")
       (not (top-level-bound? sym))))
 '(jolt-future-hook
   jolt-future-hook-set!
   jolt-future-hook-clear!
   jolt-future-hook-errors-snapshot
   jolt-future-hook-errors-clear!
   jolt-future-alloc-id!
   jolt-future-next-id
   jolt-future-task-id
   jolt-future-current-task-id
   jolt-hooked-future?
   make-jolt-hooked-future
   jolt-sim-future-call
   jolt-sim-future-cancel
   fhk-spawn
   fhk-start
   fhk-finish
   fhk-cancel))

;; --- ordinary future/deref/cancel behavior is unaffected ---------------------
(is "future works with no overlay loaded"
    "(deref (future (+ 20 22)))"
    "42")
(is "future exception surfaces through deref"
    "(deref (future (try (/ 1 0) (catch Exception e :caught))))"
    ":caught")
(ok "an already-finished future cannot be cancelled"
    (string=? (render "(let [f (future 1)] (deref f) (future-cancel f))")
              "false"))
(ok "a slow future can be cancelled before it finishes"
    (string=? (render "(let [f (future (Thread/sleep 200) 1)] (future-cancel f))")
              "true"))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
