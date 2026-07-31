;; jolt.ffi call-INTERCEPTION (simulation) seam gate.
;;
;; A disabled-by-default hook lets an internal/test-oriented controller
;; intercept every jolt.ffi/defcfn call BEFORE the native symbol is ever
;; resolved. The hook receives a stable plain descriptor (C symbol, argument
;; types, return type, the :blocking and :capture-native-error flags, and the
;; actual jolt call arguments) and its return value stands in for the complete
;; public call result. With no hook installed, ordinary defcfn code is
;; unchanged: a lazily cached foreign-procedure, resolved on first call.
;;
;; The interception seam itself is only EMITTED for a compilation unit whose
;; sim-instrument? flag is on (set-sim-instrument!, jolt.backend-scheme — see
;; ffi-sim-flavor-test.ss for that compile-time gate); ordinary jolt code
;; compiles with no jolt-ffi-sim-hook reference at all. This gate is about the
;; runtime install/clear behavior of the seam once it IS emitted, so it turns
;; the flavor on for its whole spine below.
;;
;; This exercises a compiler-source slice (emit-ffi-fn, jolt-core/jolt/
;; backend_scheme.clj), so — like alias-resolution-test.ss — it runs against a
;; transient seed rather than the checked-in one:
;;
;;   CHEZ=/path/to/chez sh host/chez/transient-seed-gate.sh test/chez/ffi-sim-hook-test.ss
;; or directly against a caller-supplied converged seed pair:
;;   chez --script test/chez/ffi-sim-hook-test.ss PRELUDE IMAGE

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
;; Match cli.ss's loader boundary: the loader (source roots -> real file
;; loading for `require`) must exist before jolt.ffi's host primitives
;; install, so an ordinary (require '[jolt.ffi :as ffi]) resolves
;; stdlib/jolt/ffi.clj's foreign-fn/defcfn macros exactly like a real
;; library — not the low-level jolt.ffi/__cfn special form directly.
(load "host/chez/loader.ss")
(set-source-roots! ldr-install-roots)
(load "host/chez/java/ffi.ss")
;; The install/clear/invoke machinery this gate drives (jolt-ffi-sim-hook,
;; jolt-ffi-install-sim-hook!, jolt-ffi-invoke-sim-hook, …) lives in the
;; simulation-only overlay, not in java/ffi.ss itself — an ordinary
;; release/debug binary never loads it. See ordinary-ffi-no-sim-hook-test.ss
;; for the gate proving java/ffi.ss alone carries none of it.
(load "host/chez/sim/runtime.ss")

;; This gate exercises the RUNTIME install/clear behavior of the interception
;; seam, so turn the compile-time flavor on for every defcfn compiled below —
;; ffi-sim-flavor-test.ss pins that it is off by default and gated per unit.
((var-deref "jolt.backend-scheme" "set-sim-instrument!") #t)

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
;; eval one form (string) in `user`, like the loader does form-by-form.
(define (ev s) (jolt-compile-eval s "user"))
(define (dget d k) (cdr (assq k d)))

;; --- ordinary jolt code: require jolt.ffi, bind a real libc symbol ----------
(ev "(require '[jolt.ffi :as ffi])")
(ev "(ffi/load-library)")
(ev "(ffi/defcfn c-abs \"abs\" [:int] :int)")
(ev "(ffi/defcfn c-abs-lazy \"abs\" [:int] :int)")
(ev "(ffi/defcfn c-abs-blocking \"abs\" [:int] :int :blocking)")

(ok "no hook installed by default" (not jolt-ffi-sim-hook))
(ok "with no hook, ordinary defcfn code calls native code unchanged"
    (= 7 (jnum->exact (ev "(c-abs -7)"))))

;; --- hook installed: every call is intercepted, no native resolution --------
;; c-ghost binds a C symbol that does not exist. If the hook's presence still
;; let the foreign-procedure form get forced, Chez would raise right here —
;; success proves the native symbol was never looked up at all. (Args are both
;; :int, not :string — Chez's __collect_safe rejects a string argument outright
;; at compile time regardless of whether the branch calling it ever runs, so a
;; :blocking probe must avoid :string to isolate what this seam actually tests.)
(ev "(ffi/defcfn c-ghost \"definitely_not_a_real_c_symbol_zzz9\" [:int :int] :int :blocking)")
(ev "(ffi/defcfn c-ghost-captured
       \"definitely_not_a_real_c_symbol_zzz9\" [:int :int] :int
       {:blocking true :capture-native-error true})")
(ev "(ffi/defcfn c-ghost-varargs
       \"definitely_not_a_real_c_symbol_varargs_zzz9\" [:int :int :int] :int
       {:blocking true :capture-native-error true :varargs-after 2})")
(ev "(ffi/defcfn c-ghost-zero \"definitely_not_a_real_c_symbol_zero_zzz9\" [] :int)")

(define captured '())
(define (record-hook! desc)
  (set! captured (append captured (list desc)))
  (if (dget desc 'capture-native-error)
      (jolt-vector -1 73)
      999))

(define record-installation (jolt-ffi-install-sim-hook! record-hook!))
(ok "hook intercepts a call to a nonexistent C symbol without resolving it"
    (= 999 (jnum->exact (ev "(c-ghost 42 7)"))))
(ok "exactly one descriptor captured after one call" (= 1 (length captured)))
(let ((d (list-ref captured 0)))
  (ok "descriptor csym is exact"
      (string=? (dget d 'csym) "definitely_not_a_real_c_symbol_zzz9"))
  (ok "descriptor argtypes are exact" (equal? (dget d 'argtypes) (list "int" "int")))
  (ok "descriptor rettype is exact" (string=? (dget d 'rettype) "int"))
  (ok "descriptor blocking flag is exact" (eq? (dget d 'blocking) #t))
  (ok "ordinary descriptor disables native-error capture"
      (eq? (dget d 'capture-native-error) #f))
  (ok "descriptor args are the exact jolt call arguments" (equal? (dget d 'args) (list 42 7))))

;; Metadata strings are snapshots, not shared compiler literals. Corrupt this
;; descriptor deliberately; a later call to the same binding must still report
;; the original symbol and type names.
(let ((d (list-ref captured 0)))
  (string-set! (dget d 'csym) 0 #\X)
  (string-set! (car (dget d 'argtypes)) 0 #\X)
  (string-set! (dget d 'rettype) 0 #\X))

;; zero-argument bindings must produce exact empty argtype/argument lists.
(ok "zero-argument defcfn is intercepted without resolving its symbol"
    (= 999 (jnum->exact (ev "(c-ghost-zero)"))))
(ok "two descriptors captured after zero-argument call" (= 2 (length captured)))
(let ((d (list-ref captured 1)))
  (ok "zero-argument descriptor csym is exact"
      (string=? (dget d 'csym) "definitely_not_a_real_c_symbol_zero_zzz9"))
  (ok "zero-argument descriptor argtypes are empty"
      (equal? (dget d 'argtypes) '()))
  (ok "zero-argument descriptor args are empty"
      (equal? (dget d 'args) '()))
  (ok "zero-argument descriptor blocking flag is false"
      (eq? (dget d 'blocking) #f))
  (ok "zero-argument descriptor capture flag is false"
      (eq? (dget d 'capture-native-error) #f)))

;; repeated calls are intercepted, not just the first
(ok "a second call is also intercepted"
    (= 999 (jnum->exact (ev "(c-ghost 43 8)"))))
(ok "three descriptors captured after repeated call" (= 3 (length captured)))
(let ((d (list-ref captured 2)))
  (ok "second descriptor carries its own call arguments"
      (equal? (dget d 'args) (list 43 8)))
  (ok "mutating one descriptor cannot corrupt later symbol metadata"
      (string=? (dget d 'csym) "definitely_not_a_real_c_symbol_zzz9"))
  (ok "mutating one descriptor cannot corrupt later argument metadata"
      (equal? (dget d 'argtypes) (list "int" "int")))
  (ok "mutating one descriptor cannot corrupt later return metadata"
      (string=? (dget d 'rettype) "int")))

;; the hook intercepts EVERY ffi call while installed, including an
;; already-resolved defcfn whose foreign-procedure was cached before the hook
;; went in.
(ok "an unrelated, already-resolved defcfn is also intercepted while hooked"
    (= 999 (jnum->exact (ev "(c-abs -7)"))))
(ok "four descriptors captured, including the already-resolved call"
    (= 4 (length captured)))
(ok "the already-resolved call's descriptor is exact"
    (let ((d (list-ref captured 3)))
      (and (string=? (dget d 'csym) "abs")
           (equal? (dget d 'argtypes) (list "int"))
           (string=? (dget d 'rettype) "int")
           (eq? (dget d 'blocking) #f)
           (equal? (dget d 'args) (list -7)))))

;; This valid binding has never reached its native branch. Intercept it first,
;; then clear the hook and prove its original lazy resolution still works.
(ok "a valid but unresolved binding is intercepted first"
    (= 999 (jnum->exact (ev "(c-abs-lazy -13)"))))
(ok "five descriptors captured, including the unresolved valid binding"
    (= 5 (length captured)))

;; Capture mode is part of the descriptor even when every other signature field
;; is identical. The hook returns the complete public pair as one Jolt value;
;; the emitter must not feed that one value to the native branch's two-value
;; continuation.
(ok "paired scalar binding is intercepted with matching call arguments"
    (= 999 (jnum->exact (ev "(c-ghost 42 7)"))))
(ok "six descriptors captured before the paired captured binding"
    (= 6 (length captured)))
(ok "captured binding accepts the hook's complete public [result error] value"
    (jolt-truthy? (ev "(= [-1 73] (c-ghost-captured 42 7))")))
(ok "seven descriptors captured after the otherwise-identical captured binding"
    (= 7 (length captured)))
(let ((scalar (list-ref captured 5))
      (captured-call (list-ref captured 6)))
  (ok "capture mode is the only metadata difference between paired bindings"
      (and (string=? (dget scalar 'csym) (dget captured-call 'csym))
           (equal? (dget scalar 'argtypes) (dget captured-call 'argtypes))
           (string=? (dget scalar 'rettype) (dget captured-call 'rettype))
           (eq? (dget scalar 'blocking) (dget captured-call 'blocking))
           (eq? (dget scalar 'capture-native-error) #f)
           (eq? (dget captured-call 'capture-native-error) #t)
           (equal? (dget scalar 'args) (dget captured-call 'args)))))

;; :varargs-after is native-lowering policy, not part of the stable v3
;; controller descriptor. Intercept a never-resolved variadic symbol with all
;; three options enabled and pin the descriptor's exact existing key set.
(ok "variadic binding is intercepted without resolving its symbol"
    (jolt-truthy? (ev "(= [-1 73] (c-ghost-varargs 11 22 33))")))
(ok "eight descriptors captured after the variadic binding"
    (= 8 (length captured)))
(let ((d (list-ref captured 7)))
  (ok "variadic binding preserves the exact v3 descriptor shape"
      (equal? (map car d)
              '(csym argtypes rettype blocking capture-native-error args)))
  (ok "variadic binding descriptor retains its ordinary metadata"
      (and (string=? (dget d 'csym)
                     "definitely_not_a_real_c_symbol_varargs_zzz9")
           (equal? (dget d 'argtypes) (list "int" "int" "int"))
           (string=? (dget d 'rettype) "int")
           (eq? (dget d 'blocking) #t)
           (eq? (dget d 'capture-native-error) #t)
           (equal? (dget d 'args) (list 11 22 33)))))

;; --- clearing restores the normal path ---------------------------------------
(jolt-ffi-clear-sim-hook! record-installation)
(ok "clear restores no-hook state" (not jolt-ffi-sim-hook))
(ok "clearing restores the normal path for an existing harmless native symbol"
    (= 7 (jnum->exact (ev "(c-abs -7)"))))
(ok "a cleared hook is not called again" (= 8 (length captured)))
(ok "a binding first called under the hook resolves natively after clear"
    (= 13 (jnum->exact (ev "(c-abs-lazy -13)"))))
(ok "fresh-emitter blocking native branch remains callable"
    (= 17 (jnum->exact (ev "(c-abs-blocking -17)"))))

;; Nested installs restore exactly their predecessor. An out-of-order clear is
;; rejected and must not disable the current owner.
(define outer-installation
  (jolt-ffi-install-sim-hook! (lambda (desc) 111)))
(define inner-installation
  (jolt-ffi-install-sim-hook! (lambda (desc) 222)))
(ok "nested installation selects the inner hook"
    (= 222 (jnum->exact (ev "(c-abs -7)"))))
(ok "out-of-order clear fails closed"
    (guard (e (#t #t))
      (jolt-ffi-clear-sim-hook! outer-installation)
      #f))
(ok "failed out-of-order clear preserves the inner hook"
    (= 222 (jnum->exact (ev "(c-abs -7)"))))
(jolt-ffi-clear-sim-hook! inner-installation)
(ok "clearing the inner hook restores the outer hook"
    (= 111 (jnum->exact (ev "(c-abs -7)"))))
(jolt-ffi-clear-sim-hook! outer-installation)
(ok "clearing the outer hook restores native execution"
    (= 7 (jnum->exact (ev "(c-abs -7)"))))

;; Code emitted by descriptor-v1/v2/v3 sim compilers calls the shared helper
;; with only [installation descriptor]. Preserve that old form for established
;; hooks, and fail closed if a routing hook is paired with no native thunk.
(define legacy-direct-desc
  (jolt-ffi-make-sim-descriptor "legacy-direct" '() "int" #f #f '()))
(define legacy-direct-installation
  (jolt-ffi-install-sim-hook! (lambda (desc) 616)))
(ok "legacy two-argument invocation still reaches an established hook"
    (= 616
       (jolt-ffi-invoke-sim-hook jolt-ffi-sim-hook legacy-direct-desc)))
(jolt-ffi-clear-sim-hook! legacy-direct-installation)
(define legacy-routing-call-count 0)
(define legacy-routing-installation
  (jolt-ffi-install-routing-hook!
   (lambda (desc proceed)
     (set! legacy-routing-call-count (+ legacy-routing-call-count 1))
     717)))
(ok "legacy invocation under a routing hook fails for missing proceed thunk"
    (guard (e (#t #t))
      (jolt-ffi-invoke-sim-hook jolt-ffi-sim-hook legacy-direct-desc)
      #f))
(ok "missing legacy proceed fails before invoking the routing controller"
    (= 0 legacy-routing-call-count))
(jolt-ffi-clear-sim-hook! legacy-routing-installation)

;; Consumption happens before the native thunk. Catch a deliberate native
;; failure inside the controller, retry the same proceed, and prove the thunk
;; itself ran only once while the retry failed at the single-use guard.
(define failing-native-call-count 0)
(define failing-native-sentinel (list 'failing-native-sentinel))
(define failing-native-retry-rejected? #f)
(define failing-native-installation
  (jolt-ffi-install-routing-hook!
   (lambda (desc proceed)
     (guard
      (e ((eq? e failing-native-sentinel)
          (guard (e2 (#t
                      (set! failing-native-retry-rejected? #t)
                      'retry-rejected))
            (proceed)
            'retry-unexpected))
         (#t (raise e)))
      (proceed)))))
(ok "native failure leaves the same proceed consumed"
    (eq? 'retry-rejected
         (jolt-ffi-invoke-sim-hook
          jolt-ffi-sim-hook legacy-direct-desc
          (lambda ()
            (set! failing-native-call-count (+ failing-native-call-count 1))
            (raise failing-native-sentinel)))))
(ok "native failure plus retry executes the native thunk exactly once"
    (and failing-native-retry-rejected? (= 1 failing-native-call-count)))
(jolt-ffi-clear-sim-hook! failing-native-installation)

;; A hook that itself invokes FFI fails promptly instead of recursing forever.
(define c-abs-fn (ev "c-abs"))
(define reentrant-installation
  (jolt-ffi-install-sim-hook!
   (lambda (desc) (jolt-invoke c-abs-fn -7))))
(ok "reentrant FFI from a simulation hook fails closed"
    (guard (e (#t #t))
      (ev "(c-abs -7)")
      #f))
(jolt-ffi-clear-sim-hook! reentrant-installation)

;; Chez child threads inherit thread parameters. An inherited parent owner id
;; must not poison the child after it begins its own independent hooked call.
(define child-mu (make-mutex))
(define child-cv (make-condition))
(define child-result #f)
(define child-installation
  (jolt-ffi-install-sim-hook! (lambda (desc) 333)))
(parameterize ((jolt-ffi-sim-hook-active-owner (get-thread-id)))
  (fork-thread
   (lambda ()
     (let ((result (jolt-invoke c-abs-fn -7)))
       (with-mutex child-mu
         (set! child-result result)
         (condition-broadcast child-cv))))))
(let ((deadline (ms->deadline 5000)))
  (with-mutex child-mu
    (let loop ()
      (unless child-result
        (unless (condition-wait child-cv child-mu deadline)
          (error 'ffi-sim-hook-test
                 "timed out waiting for inherited-owner child"))
        (loop)))))
(ok "inherited parent owner id does not poison a child thread"
    (= 333 child-result))
(jolt-ffi-clear-sim-hook! child-installation)

;; --- a hook-thrown sentinel propagates unchanged -----------------------------
(define sentinel (list 'ffi-sim-sentinel))
(define sentinel-installation
  (jolt-ffi-install-sim-hook! (lambda (desc) (raise sentinel))))
(ok "a hook-thrown sentinel propagates unchanged"
    (guard (e (#t (eq? e sentinel))) (ev "(c-abs -7)") #f))
(jolt-ffi-clear-sim-hook! sentinel-installation)

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
