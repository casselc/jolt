;; Internal declared-FFI interception gate.  This covers compiler-source
;; lowering, so run it through host/chez/transient-seed-gate.sh:
;;
;;   CHEZ=/path/to/chez sh host/chez/transient-seed-gate.sh \
;;     test/chez/ffi-sim-hook-test.ss
;;
;; The wrapper passes the fresh PRELUDE and IMAGE as the two script arguments.

(import (chezscheme))

(define seed-args (cdr (command-line)))
(unless (= (length seed-args) 2)
  (display "usage: ffi-sim-hook-test.ss PRELUDE IMAGE\n" (current-error-port))
  (exit 2))

(load "host/chez/rt.ss")
(set-chez-ns! "clojure.core")
(load (car seed-args))
(load "host/chez/post-prelude.ss")
(set-chez-ns! "user")
(load "host/chez/host-contract.ss")
(load (cadr seed-args))
(load "host/chez/compile-eval.ss")
(load "host/chez/loader.ss")
(set-source-roots! ldr-install-roots)
(load "host/chez/java/ffi.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a~n" name)))
(define (ev source) (jolt-compile-eval source "user"))
(define (dget descriptor key) (cdr (assq key descriptor)))
(define (throws? thunk)
  (guard (e (#t #t)) (thunk) #f))

;; Three real bindings plus two deliberately unresolvable bindings.  Merely
;; defining a binding must remain lazy; an installed hook must substitute the
;; ghost calls before Chez resolves their symbols.
(ev "(require '[jolt.ffi :as ffi])")
(ev "(ffi/load-library)")
(ev "(ffi/defcfn c-abs \"abs\" [:int] :int)")
(ev "(ffi/defcfn c-abs-lazy \"abs\" [:int] :int)")
(ev "(ffi/defcfn c-abs-captured \"abs\" [:int] :int {:capture-native-error true})")
(ev "(ffi/defcfn c-ghost \"definitely_not_a_real_c_symbol_ffi_hook_zzz9\" [:int :int] :int {:blocking true})")
(ev "(ffi/defcfn c-ghost-captured \"definitely_not_a_real_c_symbol_ffi_hook_capture_zzz9\" [] :int {:capture-native-error true})")
(define c-abs-fn (ev "c-abs"))

(ok "hook is disabled by default" (not jolt-ffi-declared-call-hook))
(ok "disabled path preserves real native execution"
    (= 7 (jnum->exact (ev "(c-abs -7)"))))

;; Substitution is returned verbatim for both ordinary and capture-declared
;; calls.  In particular, the compiler must not wrap a capture substitution in
;; [result native-error].
(define descriptors '())
(define (substitute-hook descriptor proceed)
  (set! descriptors (append descriptors (list descriptor)))
  (if (dget descriptor 'capture-native-error) 888 999))
(define substitution-token
  (jolt-ffi-install-declared-call-hook! substitute-hook))
(ok "nonexistent symbol is substituted before resolution"
    (= 999 (jnum->exact (ev "(c-ghost 42 7)"))))
(ok "ordinary substitution is returned unwrapped"
    (= 999 (jnum->exact (ev "(c-abs -9)"))))
(ok "capture-declared substitution is returned unwrapped"
    (= 888 (jnum->exact (ev "(c-ghost-captured)"))))
(ok "three calls produce three descriptors" (= 3 (length descriptors)))

(let ((d (list-ref descriptors 0)))
  (ok "descriptor kind is foreign-call" (eq? 'foreign-call (dget d 'kind)))
  (ok "descriptor symbol is exact"
      (string=? "definitely_not_a_real_c_symbol_ffi_hook_zzz9"
                (dget d 'csym)))
  (ok "descriptor argument types are exact"
      (equal? '("int" "int") (dget d 'argtypes)))
  (ok "descriptor return type is exact" (string=? "int" (dget d 'rettype)))
  (ok "descriptor blocking flag is exact" (eq? #t (dget d 'blocking)))
  (ok "descriptor capture flag is exact"
      (eq? #f (dget d 'capture-native-error)))
  (ok "descriptor arguments are exact" (equal? '(42 7) (dget d 'args))))
(let ((d (list-ref descriptors 2)))
  (ok "capture descriptor flag is exact"
      (eq? #t (dget d 'capture-native-error)))
  (ok "zero-argument descriptor types are empty"
      (null? (dget d 'argtypes)))
  (ok "zero-argument descriptor arguments are empty"
      (null? (dget d 'args))))

;; Metadata is a per-call snapshot.  Corrupt every mutable string in the first
;; descriptor, then call the same binding again and require pristine metadata.
(let ((d (list-ref descriptors 0)))
  (string-set! (dget d 'csym) 0 #\X)
  (string-set! (car (dget d 'argtypes)) 0 #\X)
  (string-set! (dget d 'rettype) 0 #\X))
(ok "repeated ghost call is still substituted"
    (= 999 (jnum->exact (ev "(c-ghost 43 8)"))))
(let ((d (list-ref descriptors 3)))
  (ok "later symbol metadata is independent"
      (string=? "definitely_not_a_real_c_symbol_ffi_hook_zzz9"
                (dget d 'csym)))
  (ok "later argument metadata is independent"
      (equal? '("int" "int") (dget d 'argtypes)))
  (ok "later return metadata is independent"
      (string=? "int" (dget d 'rettype)))
  (ok "later arguments are their own snapshot"
      (equal? '(43 8) (dget d 'args))))

;; c-abs-lazy has not resolved yet.  Intercept it now, then prove clear restores
;; both an already-resolved binding and this still-unresolved binding.
(ok "valid unresolved binding is intercepted"
    (= 999 (jnum->exact (ev "(c-abs-lazy -13)"))))
(jolt-ffi-clear-declared-call-hook! substitution-token)
(ok "clear restores disabled state" (not jolt-ffi-declared-call-hook))
(ok "clear restores an already-resolved real call"
    (= 11 (jnum->exact (ev "(c-abs -11)"))))
(ok "clear restores lazy resolution of an unresolved real call"
    (= 13 (jnum->exact (ev "(c-abs-lazy -13)"))))

;; Proceed calls the exact original body.  A capture-declared proceed must
;; return the ordinary [result native-error] vector shape, while substitution
;; above remains unwrapped.
(define proceed-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed) (jolt-invoke0 proceed))))
(ok "proceed executes the real ordinary abs"
    (= 17 (jnum->exact (ev "(c-abs -17)"))))
(let ((result (ev "(c-abs-captured -19)")))
  (ok "capture proceed returns a two-element Jolt vector"
      (= 2 (jolt-count result)))
  (ok "capture proceed preserves the native result"
      (= 19 (jnum->exact (jolt-nth result 0 jolt-nil))))
(ok "capture proceed preserves a numeric native-error snapshot"
      (number? (jolt-nth result 1 jolt-nil))))
(jolt-ffi-clear-declared-call-hook! proceed-token)

;; Model the important callback-bearing passthrough without another C helper:
;; an outer hook proceeds into its exact real-call body, and that body represents
;; native code synchronously calling back into Jolt and making c-abs.  The inner
;; generated call must be freshly intercepted and may use its own exact proceed.
;; This path is fully synchronous and contains no wait that can hang the gate.
(define callback-interceptions 0)
(define callback-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (set! callback-interceptions (+ callback-interceptions 1))
     (jolt-invoke0 proceed))))
(define callback-result
  (jolt-ffi-invoke-declared-call-hook
   (lambda (descriptor proceed) (jolt-invoke0 proceed))
   'callback-bearing-outer-call
   (lambda () (jolt-invoke c-abs-fn -47))))
(ok "proceed permits a synchronous callback to start fresh interception"
    (= 47 callback-result))
(ok "callback's declared FFI call is intercepted exactly once"
    (= 1 callback-interceptions))
(ok "callback passthrough restores no owner activation after return"
    (not (jolt-ffi-current-declared-call-activation)))
(jolt-ffi-clear-declared-call-hook! callback-token)

;; Proceed is synchronous and at-most-once.  The second call is rejected even
;; while the hook is still active; a saved proceed is rejected after hook exit.
(define second-proceed-rejected? #f)
(define twice-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (let ((answer (jolt-invoke0 proceed)))
       (set! second-proceed-rejected?
             (throws? (lambda () (jolt-invoke0 proceed))))
       answer))))
(ok "first proceed still returns the real call result"
    (= 23 (jnum->exact (ev "(c-abs -23)"))))
(ok "second proceed call fails closed" second-proceed-rejected?)
(jolt-ffi-clear-declared-call-hook! twice-token)

(define saved-proceed #f)
(define saved-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed) (set! saved-proceed proceed) 701)))
(ok "hook may substitute while retaining a proceed reference"
    (= 701 (jnum->exact (ev "(c-abs -7)"))))
(ok "saved proceed fails after its hook returns"
    (throws? (lambda () (jolt-invoke0 saved-proceed))))
(jolt-ffi-clear-declared-call-hook! saved-token)

;; Also reject a continuation captured *inside* the real-call body.  Invoke it
;; while the enclosing hook is still active so this discriminates proceed's own
;; retired dynamic-wind from the hook-extent retirement check.
(define saved-proceed-continuation #f)
(define proceed-resume-count 0)
(define initial-proceed-result #f)
(define proceed-reentry-rejected? #f)
(define proceed-continuation-result
  (jolt-ffi-invoke-declared-call-hook
   (lambda (descriptor proceed)
     (guard (e (#t
                (begin
                  (set! proceed-reentry-rejected? #t)
                  709)))
       (set! initial-proceed-result (jolt-invoke0 proceed))
       (saved-proceed-continuation 708)
       0))
   'direct-runtime-probe
   (lambda ()
     (let ((answer (call/cc
                    (lambda (k)
                      (set! saved-proceed-continuation k)
                      707))))
       (set! proceed-resume-count (+ proceed-resume-count 1))
       answer))))
(ok "initial proceed continuation returns normally" (= 707 initial-proceed-result))
(ok "initial proceed body reached its post-capture point" (= 1 proceed-resume-count))
(ok "retired proceed continuation fails closed on re-entry"
    proceed-reentry-rejected?)
(ok "proceed continuation fails before its body resumes"
    (and (= 1 proceed-resume-count) (= 709 proceed-continuation-result)))

;; A continuation captured in the hook cannot re-enter after the hook extent
;; retires.  The before thunk must reject it before the post-call/cc body resumes.
(define saved-hook-continuation #f)
(define hook-resume-count 0)
(define initial-continuation-result #f)
(define continuation-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (let ((answer (call/cc
                    (lambda (k)
                      (set! saved-hook-continuation k)
                      711))))
       (set! hook-resume-count (+ hook-resume-count 1))
       answer))))
(define hook-reentry-rejected?
  ;; Keep this one handler around BOTH the original hook invocation and the
  ;; attempted jump.  Invoking a continuation abandons its immediate caller's
  ;; dynamic context before the destination's dynamic-wind `before` runs, so a
  ;; guard established only around `(saved-hook-continuation ...)` cannot see
  ;; the deliberate retirement error.
  (guard (e (#t #t))
    (set! initial-continuation-result (ev "(c-abs -7)"))
    (saved-hook-continuation 712)
    #f))
(ok "initial hook continuation returns normally"
    (= 711 (jnum->exact initial-continuation-result)))
(ok "initial hook body reached its post-capture point" (= 1 hook-resume-count))
(ok "retired hook continuation fails closed on re-entry"
    hook-reentry-rejected?)
(ok "hook continuation fails before its body resumes" (= 1 hook-resume-count))
(jolt-ffi-clear-declared-call-hook! continuation-token)

;; A normal nested FFI call from the hook is rejected.  Only this invocation's
;; exact proceed closure bypasses interception.
(define nested-rejected? #f)
(define nested-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (set! nested-rejected?
           (throws? (lambda () (jolt-invoke c-abs-fn -29))))
     719)))
(ok "hook survives rejected nested FFI"
    (= 719 (jnum->exact (ev "(c-abs -7)"))))
(ok "nested FFI without exact proceed fails closed" nested-rejected?)
(jolt-ffi-clear-declared-call-hook! nested-token)

;; Installations form a strict stack.  Out-of-order clear and repeated clear
;; both fail without changing the current hook.
(define outer-token
  (jolt-ffi-install-declared-call-hook! (lambda (descriptor proceed) 731)))
(define inner-token
  (jolt-ffi-install-declared-call-hook! (lambda (descriptor proceed) 733)))
(ok "nested install selects inner hook"
    (= 733 (jnum->exact (ev "(c-abs -7)"))))
(ok "out-of-order clear fails closed"
    (throws? (lambda () (jolt-ffi-clear-declared-call-hook! outer-token))))
(ok "failed clear preserves inner hook"
    (= 733 (jnum->exact (ev "(c-abs -7)"))))
(jolt-ffi-clear-declared-call-hook! inner-token)
(ok "clearing inner hook restores outer hook"
    (= 731 (jnum->exact (ev "(c-abs -7)"))))
(jolt-ffi-clear-declared-call-hook! outer-token)
(ok "repeated clear of retired token fails closed"
    (throws? (lambda () (jolt-ffi-clear-declared-call-hook! outer-token))))
(ok "stack clear restores native call"
    (= 31 (jnum->exact (ev "(c-abs -31)"))))

;; A child thread inherits the parent's parameter cell.  Owner tagging must let
;; it enter its own hook invocation instead of treating the parent as recursive.
;; The parent hook spawns only for -37; the child's -41 path terminates directly.
(define child-mu (make-mutex))
(define child-cv (make-condition))
(define child-result #f)
(define child-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (if (equal? '(-37) (dget descriptor 'args))
         (begin
           (fork-thread
            (lambda ()
              (let ((answer (jolt-invoke c-abs-fn -41)))
                (with-mutex child-mu
                  (set! child-result answer)
                  (condition-broadcast child-cv)))))
           739)
         743))))
(ok "parent hook starts child probe"
    (= 739 (jnum->exact (ev "(c-abs -37)"))))
(let ((deadline (ms->deadline 5000)))
  (with-mutex child-mu
    (let loop ()
      (unless child-result
        (unless (condition-wait child-cv child-mu deadline)
          (error 'ffi-sim-hook-test
                 "timed out waiting for inherited-owner child"))
        (loop)))))
(ok "inherited child owner enters an independent hook invocation"
    (= 743 child-result))
(jolt-ffi-clear-declared-call-hook! child-token)

;; Hook exceptions are not translated or wrapped.
(define sentinel (list 'ffi-declared-call-sentinel))
(define sentinel-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed) (raise sentinel))))
(ok "hook-thrown sentinel propagates unchanged"
    (guard (e (#t (eq? e sentinel))) (ev "(c-abs -7)") #f))
(jolt-ffi-clear-declared-call-hook! sentinel-token)
(ok "sentinel cleanup restores native execution"
    (= 43 (jnum->exact (ev "(c-abs -43)"))))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
