;; ffi-sim-flavor-test.ss — compile-time-selectable jolt-ffi-sim-hook emission.
;;
;; emit-ffi-fn (jolt-core/jolt/backend_scheme.clj) emits the jolt-ffi-sim-hook
;; interception branch around a defcfn's lazy foreign-procedure call ONLY when
;; the compiling unit's sim-instrument? flag (jolt.passes.types/new-unit) is on
;; (set-sim-instrument!, jolt.backend-scheme); off — the default — it emits just the
;; ordinary lazy foreign-procedure call, with no jolt-ffi-sim-hook reference at
;; all. This gate pins:
;;   - normal emission carries no sim-hook reference, and that is the default;
;;   - sim emission does carry it;
;;   - both preserve the same blocking/lazy foreign-procedure shape;
;;   - a fresh compilation unit (ei-fresh-unit!, emit-image.ss — what a `jolt
;;     build` run FROM the special `sim` Jolt binary does per build) does not
;;     lose sim mode once that binary's launcher has turned the flavor on
;;     (jolt-enable-sim-instrumentation!, compile-eval.ss).
;;
;; Exercises a compiler-source slice (emit-ffi-fn, jolt-core/jolt/
;; backend_scheme.clj; new-unit, jolt-core/jolt/passes/types.clj), so — like
;; ffi-sim-hook-test.ss — it runs against a transient seed rather than the
;; checked-in one:
;;
;;   sh host/chez/transient-seed-gate.sh test/chez/ffi-sim-flavor-test.ss
;; or directly against a caller-supplied converged seed pair:
;;   chez --script test/chez/ffi-sim-flavor-test.ss PRELUDE IMAGE

(import (chezscheme))

(define seed-args (cdr (command-line)))
(unless (= (length seed-args) 2)
  (display "usage: ffi-sim-flavor-test.ss PRELUDE IMAGE\n" (current-error-port))
  (exit 2))

(load "host/chez/rt.ss")
(set-chez-ns! "clojure.core")
(load (car seed-args))
(load "host/chez/post-prelude.ss")
(set-chez-ns! "user")
(load "host/chez/host-contract.ss")
(load (cadr seed-args))
(load "host/chez/compile-eval.ss")
(load "host/chez/emit-image.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (contains? s sub)
  (let ((ns (string-length s)) (nsub (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i nsub) ns) #f)
            ((string=? (substring s i (+ i nsub)) sub) #t)
            (else (loop (+ i 1)))))))

(define new-unit       (var-deref "jolt.passes.types" "new-unit"))
(define set-emit-unit! (var-deref "jolt.backend-scheme" "set-emit-unit!"))
(define set-sim-instrument!
  (var-deref "jolt.backend-scheme" "set-sim-instrument!"))

;; analyze+emit one form (string) in a namespace through the real build entry —
;; unoptimized (no run-passes/direct-link), exactly like unit-context-test.ss.
(define (emit-form ns-name str)
  (let-values (((f j) (rdr-read-form str 0 (string-length str))))
    (ei-compile-form (make-analyze-ctx ns-name) f #f)))

(define non-blocking "(jolt.ffi/__cfn \"abs\" [:int] :int)")
(define blocking     "(jolt.ffi/__cfn \"recv\" [:int] :int :blocking)")
(define captured
  "(jolt.ffi/__cfn \"close\" [:int] :int {:capture-native-error true})")

;; --- U1: a fresh unit, sim never turned on — normal is the default ----------
(define U1 (new-unit))
(set-emit-unit! U1)
(let ((e (emit-form "app" non-blocking)))
  (ok "normal emission has no sim-hook reference" (not (contains? e "jolt-ffi-sim-hook")))
  (ok "normal emission has no sim descriptor reference" (not (contains? e "jolt-ffi-make-sim-descriptor")))
  (ok "normal emission keeps the lazy foreign-procedure shape"
      (and (contains? e "(or p (begin (set! p ") (contains? e "(foreign-procedure "))))
(let ((eb (emit-form "app" blocking)))
  (ok "normal blocking emission still uses __collect_safe" (contains? eb "__collect_safe"))
  (ok "normal blocking emission has no sim-hook reference" (not (contains? eb "jolt-ffi-sim-hook"))))
(let ((ec (emit-form "app" captured)))
  (ok "normal captured emission uses the target-native error procedure"
      (contains? ec "jolt-ffi-native-error-procedure"))
  (ok "normal captured emission collects the native call's two values"
      (contains? ec "call-with-values"))
  (ok "normal captured emission has no sim-hook reference"
      (not (contains? ec "jolt-ffi-sim-hook"))))

;; --- U2: sim mode explicitly turned on for this unit only -------------------
(define U2 (new-unit))
(set-emit-unit! U2)
(set-sim-instrument! #t)
(let ((e (emit-form "app" non-blocking)))
  (ok "sim emission references the sim hook" (contains? e "jolt-ffi-sim-hook"))
  (ok "sim emission builds a sim descriptor" (contains? e "jolt-ffi-make-sim-descriptor"))
  (ok "sim emission still falls through to the lazy foreign-procedure shape"
      (and (contains? e "(or p (begin (set! p ") (contains? e "(foreign-procedure "))))
(let ((eb (emit-form "app" blocking)))
  (ok "sim blocking emission still uses __collect_safe" (contains? eb "__collect_safe"))
  (ok "sim blocking emission references the sim hook" (contains? eb "jolt-ffi-sim-hook")))
(let ((ec (emit-form "app" captured)))
  (ok "sim captured emission advertises capture mode to its descriptor"
      (contains? ec "jolt-ffi-make-sim-descriptor"))
  (ok "sim captured emission preserves the target-native fallback"
      (and (contains? ec "jolt-ffi-native-error-procedure")
           (contains? ec "call-with-values")))
  (ok "sim captured emission lets the hook return one complete public value"
      (contains? ec "(if h (jolt-ffi-invoke-sim-hook h ")))

;; --- U1 unaffected by U2 (per-unit isolation, the property unit-context-test
;; pins for the other emit-session flags) ------------------------------------
(set-emit-unit! U1)
(let ((e (emit-form "app" non-blocking)))
  (ok "normal unit still has no sim-hook reference after another unit turned it on"
      (not (contains? e "jolt-ffi-sim-hook"))))

;; --- fresh build units inside a sim binary do not lose sim mode -------------
;; Simulates what `jolt build` does per build (ei-fresh-unit!, emit-image.ss)
;; once the special `sim` binary's launcher has turned the flavor on
;; (jolt-enable-sim-instrumentation!, compile-eval.ss): the flag must survive
;; onto every NEW
;; unit a build creates, with no second generated seed and no process-global
;; Clojure atom (jolt-sim-flavor? is the narrow Scheme-side latch that
;; carries it forward — see compile-eval.ss / emit-image.ss's ei-fresh-unit!).
(jolt-enable-sim-instrumentation!)
(ei-fresh-unit!)
(let ((e (emit-form "app" non-blocking)))
  (ok "a fresh build unit inside a sim binary keeps sim mode"
      (contains? e "jolt-ffi-sim-hook")))
(ei-fresh-unit!)
(let ((e (emit-form "app" non-blocking)))
  (ok "a second fresh build unit also keeps sim mode (no second seed needed)"
      (contains? e "jolt-ffi-sim-hook")))

(set-emit-unit! #f)
(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
