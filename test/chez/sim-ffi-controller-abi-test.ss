;; jolt.internal.sim FFI controller ABI gate.
;;
;; install-ffi-controller!/restore-ffi-controller! (host/chez/sim/runtime.ss's
;; "jolt.internal.sim/install-ffi-controller! + restore-ffi-controller!"
;; section) drive the SAME FFI call-interception seam test/chez/
;; ffi-sim-hook-test.ss and ffi-native-sim-hook-test.ss exercise directly
;; (jolt-ffi-install-sim-hook!/-clear-sim-hook!, its strict-LIFO stack, and its
;; reentrancy guard) — no separate hook state of their own. The only new
;; behavior is: (1) the controller is an ORDINARY Jolt fn, resolved and driven
;; from ordinary Jolt source via jolt.internal.sim, not a raw Scheme lambda
;; installed by a Scheme-level test harness, and (2) each raw alist descriptor
;; is projected into one stable, immutable Jolt map before the controller ever
;; sees it.
;;
;; This exercises a compiler-source slice (emit-ffi-fn, jolt-core/jolt/
;; backend_scheme.clj — the same emitter ffi-sim-hook-test.ss exercises), so it
;; runs against a transient seed rather than the checked-in one:
;;
;;   CHEZ=/path/to/chez sh host/chez/transient-seed-gate.sh test/chez/sim-ffi-controller-abi-test.ss
;; or directly against a caller-supplied converged seed pair:
;;   chez --script test/chez/sim-ffi-controller-abi-test.ss PRELUDE IMAGE

(import (chezscheme))

(define seed-args (cdr (command-line)))
(unless (= (length seed-args) 2)
  (display "usage: sim-ffi-controller-abi-test.ss PRELUDE IMAGE\n" (current-error-port))
  (exit 2))

(load "host/chez/rt.ss")
(set-chez-ns! "clojure.core")
(load (car seed-args))
(load "host/chez/post-prelude.ss")
(set-chez-ns! "user")
(load "host/chez/host-contract.ss")
(load (cadr seed-args))
(load "host/chez/compile-eval.ss")
;; Match cli.ss's loader boundary, same as ffi-sim-hook-test.ss: the loader
;; must exist before jolt.ffi's host primitives install, so an ordinary
;; (require '[jolt.ffi :as ffi]) resolves stdlib/jolt/ffi.clj's macros.
(load "host/chez/loader.ss")
(set-source-roots! ldr-install-roots)
(load "host/chez/java/ffi.ss")
(load "host/chez/sim/runtime.ss")
((var-deref "jolt.backend-scheme" "set-sim-instrument!") #t)

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (ev s) (jolt-compile-eval s "user"))
(define (render s) (jolt-final-str (ev s)))
(define (is name s expected)
  (ok (string-append name " => " expected)
      (string=? (render s) expected)))
(define (jget m k) (pmap-get m k jolt-nil))

;; === malformed/ambiguous internal descriptors are rejected, not guessed =====
;; Direct Scheme-level unit tests of the projection itself — the compiler only
;; ever emits the two well-formed shapes below, so this is the only way to
;; drive the reject-outright path.
(ok "an empty alist is rejected"
    (guard (e (#t #t)) (jolt-sim-ffi-project-descriptor '()) #f))
(ok "a descriptor missing required cfn keys is rejected"
    (guard (e (#t #t))
      (jolt-sim-ffi-project-descriptor (list (cons 'csym "x") (cons 'args '())))
      #f))
(ok "a descriptor carrying both csym and native-op keys is rejected as malformed"
    (guard (e (#t #t))
      (jolt-sim-ffi-project-descriptor
       (list (cons 'csym "x") (cons 'kind 'native-op) (cons 'op "y") (cons 'args '())))
      #f))
(ok "a non-alist value is rejected"
    (guard (e (#t #t)) (jolt-sim-ffi-project-descriptor 42) #f))
(ok "a foreign descriptor with invalid metadata types is rejected"
    (guard (e (#t #t))
      (jolt-sim-ffi-project-descriptor
       (list (cons 'csym 'not-a-string)
             (cons 'argtypes (list "int"))
             (cons 'rettype "int")
             (cons 'blocking #f)
             (cons 'args (list 1))))
      #f))
(ok "a foreign descriptor with a non-string argument type is rejected"
    (guard (e (#t #t))
      (jolt-sim-ffi-project-descriptor
       (list (cons 'csym "sym")
             (cons 'argtypes (list "int" 'not-a-string))
             (cons 'rettype "int")
             (cons 'blocking #f)
             (cons 'args (list 1 2))))
      #f))
(ok "a foreign descriptor with a non-string return type is rejected"
    (guard (e (#t #t))
      (jolt-sim-ffi-project-descriptor
       (list (cons 'csym "sym")
             (cons 'argtypes (list "int"))
             (cons 'rettype 'not-a-string)
             (cons 'blocking #f)
             (cons 'args (list 1))))
      #f))
(ok "a foreign descriptor with a non-boolean blocking flag is rejected"
    (guard (e (#t #t))
      (jolt-sim-ffi-project-descriptor
       (list (cons 'csym "sym")
             (cons 'argtypes (list "int"))
             (cons 'rettype "int")
             (cons 'blocking 0)
             (cons 'args (list 1))))
      #f))
(ok "an unadvertised native operation is rejected"
    (guard (e (#t #t))
      (jolt-sim-ffi-project-descriptor
       (jolt-ffi-make-native-sim-descriptor "unknown-op" '()))
      #f))
(ok "a well-formed cfn descriptor still projects correctly"
    (let ((m (jolt-sim-ffi-project-descriptor
              (jolt-ffi-make-sim-descriptor "sym" (list "int") "int" #f (list 1)))))
      (and (= 7 (pmap-cnt m))
           (= 0 (jget m jolt-sim-kw-task))
           (eq? (jget m jolt-sim-kw-kind) jolt-sim-kw-foreign-function))))
(ok "a well-formed native-op descriptor still projects correctly"
    (let ((m (jolt-sim-ffi-project-descriptor
              (jolt-ffi-make-native-sim-descriptor "sizeof" (list 1)))))
      (and (= 4 (pmap-cnt m))
           (= 0 (jget m jolt-sim-kw-task))
           (eq? (jget m jolt-sim-kw-kind) jolt-sim-kw-native-operation))))

;; The validation allow-list and the public capability descriptor are
;; deliberately separate representations. Pin their exact coherence here;
;; ffi-native-sim-hook-test.ss independently exercises every advertised
;; ffi-sim-* call site.
(let* ((caps (jolt-sim-capabilities))
       (ffi-caps (jget caps jolt-sim-kw-ffi-interception))
       (advertised (jget ffi-caps jolt-sim-kw-native-operations)))
  (ok "native-operation validation and advertised capability lists agree exactly"
      (and (= (length jolt-sim-ffi-native-operation-names)
              (pvec-cnt advertised))
           (let loop ((names jolt-sim-ffi-native-operation-names) (i 0))
             (or (null? names)
                 (and (eq? (pvec-nth-d advertised i jolt-nil)
                           (keyword #f (car names)))
                      (loop (cdr names) (+ i 1))))))))

;; === ordinary jolt code: require jolt.ffi, bind a ghost + a real symbol =====
(ev "(require '[jolt.ffi :as ffi])")
(ev "(ffi/load-library)")
;; c-ghost binds a C symbol that does not exist; if the controller's presence
;; still let the foreign-procedure form get forced, Chez would raise right
;; here — success proves the native symbol was never looked up at all. (Both
;; args are :int, not :string — Chez's __collect_safe rejects a string
;; argument at compile time regardless of whether the branch calling it ever
;; runs, so a :blocking probe must avoid :string.)
(ev "(ffi/defcfn c-ghost \"definitely_not_a_real_c_symbol_zzz9\" [:int :int] :int :blocking)")
(ev "(ffi/defcfn c-ghost-zero \"definitely_not_a_real_c_symbol_zero_zzz9\" [] :int)")
(ev "(ffi/defcfn c-abs \"abs\" [:int] :int)")

(ok "no hook installed by default" (not jolt-ffi-sim-hook))
(ok "with no controller, ordinary defcfn code calls native code unchanged"
    (= 7 (jnum->exact (ev "(c-abs -7)"))))

;; === an ordinary Jolt controller, installed through the Jolt-facing ABI =====
(ev "(def sim-ffi-events (atom []))")
(ev "(defn sim-ffi-controller [desc]
       (swap! sim-ffi-events conj desc)
       (if (= :foreign-function (:kind desc)) 999 :native-op-sentinel))")
(ev "(def sim-ffi-token (jolt.internal.sim/install-ffi-controller! sim-ffi-controller))")

;; --- the nonexistent symbol is never resolved; the controller's return value
;; substitutes for the call exactly, unchanged -------------------------------
(ok "hook intercepts a call to a nonexistent C symbol without resolving it, exact substitution"
    (= 999 (jnum->exact (ev "(c-ghost 42 7)"))))
(ok "zero-argument ghost call is also intercepted with exact substitution"
    (= 999 (jnum->exact (ev "(c-ghost-zero)"))))

;; --- foreign-function descriptor: exact keys/types/values --------------------
(let* ((events (ev "@sim-ffi-events"))
       (d0 (pvec-nth-d events 0 jolt-nil)))
  (ok "two foreign-function descriptors captured" (= 2 (pvec-cnt events)))
  (ok "foreign-function descriptor carries exactly seven keys" (= 7 (pmap-cnt d0)))
  (ok "descriptor :kind is exactly :foreign-function"
      (eq? (jget d0 jolt-sim-kw-kind) jolt-sim-kw-foreign-function))
  (ok "top-level descriptor carries primordial task id zero"
      (= 0 (jget d0 jolt-sim-kw-task)))
  (ok "descriptor :symbol is the exact C symbol string"
      (string=? (jget d0 jolt-sim-kw-symbol) "definitely_not_a_real_c_symbol_zzz9"))
  (let ((argtypes (jget d0 jolt-sim-kw-argument-types)))
    (ok "descriptor :argument-types is a two-element vector of keywords"
        (and (= 2 (pvec-cnt argtypes))
             (eq? (pvec-nth-d argtypes 0 jolt-nil) (keyword #f "int"))
             (eq? (pvec-nth-d argtypes 1 jolt-nil) (keyword #f "int")))))
  (ok "descriptor :return-type is exactly :int"
      (eq? (jget d0 jolt-sim-kw-return-type) (keyword #f "int")))
  (ok "descriptor :blocking? is exactly true"
      (eq? (jget d0 jolt-sim-kw-blocking?) #t))
  (let ((arguments (jget d0 jolt-sim-kw-arguments)))
    (ok "descriptor :arguments preserves the exact call arguments in order"
        (and (= 2 (pvec-cnt arguments))
             (= 42 (jnum->exact (pvec-nth-d arguments 0 jolt-nil)))
             (= 7 (jnum->exact (pvec-nth-d arguments 1 jolt-nil)))))))

(let* ((events (ev "@sim-ffi-events"))
       (d1 (pvec-nth-d events 1 jolt-nil)))
  (ok "zero-argument descriptor argument-types/arguments are exact empty vectors"
      (and (= 0 (pvec-cnt (jget d1 jolt-sim-kw-argument-types)))
           (= 0 (pvec-cnt (jget d1 jolt-sim-kw-arguments)))))
  (ok "zero-argument descriptor blocking? is exactly false"
      (eq? (jget d1 jolt-sim-kw-blocking?) #f)))

;; Metadata is copied per call: mutating one descriptor's captured Scheme
;; string cannot corrupt a LATER descriptor's symbol name (mirrors
;; ffi-sim-hook-test.ss's snapshot-isolation check, one layer up through the
;; Jolt map projection).
(let ((d0 (pvec-nth-d (ev "@sim-ffi-events") 0 jolt-nil)))
  (string-set! (jget d0 jolt-sim-kw-symbol) 0 #\X))
(ok "a third call still reports the original, uncorrupted symbol name"
    (= 999 (jnum->exact (ev "(c-ghost 43 8)"))))
(let ((d2 (pvec-nth-d (ev "@sim-ffi-events") 2 jolt-nil)))
  (ok "the third descriptor's symbol is unaffected by the earlier mutation"
      (string=? (jget d2 jolt-sim-kw-symbol) "definitely_not_a_real_c_symbol_zzz9")))

;; Installing only the FFI controller does not invent lifecycle identities for
;; ordinary futures. Until a lifecycle controller is installed, their calls
;; are explicitly correlated to the unregistered task id 0.
(ok "a foreign call in a non-hooked future still returns its substitution"
    (= 999 (jnum->exact (ev "(deref (future (c-ghost 45 10)))"))))
(let ((non-hooked-future-desc (pvec-nth-d (ev "@sim-ffi-events") 3 jolt-nil)))
  (ok "an FFI-only future descriptor carries unregistered task id zero"
      (= 0 (jget non-hooked-future-desc jolt-sim-kw-task))))

;; A call made by an ordinary future carries the SAME stable task id observed
;; by the lifecycle controller, so an external scheduler can correlate the
;; effect with its task without a separate registry.
(ev "(def sim-ffi-lifecycle-events (atom []))")
(ev "(defn sim-ffi-lifecycle-controller [event id parent]
       (swap! sim-ffi-lifecycle-events conj [event id parent]))")
(ev "(def sim-ffi-lifecycle-token
       (jolt.internal.sim/install-controller! sim-ffi-lifecycle-controller))")
(ok "an intercepted foreign call inside an ordinary future returns its substitution"
    (= 999 (jnum->exact (ev "(deref (future (c-ghost 44 9)))"))))
(ev "(jolt.internal.sim/restore-controller! sim-ffi-lifecycle-token)")
(let* ((events (ev "@sim-ffi-events"))
       (future-desc (pvec-nth-d events 4 jolt-nil))
       (lifecycle-events (ev "@sim-ffi-lifecycle-events"))
       (spawn (pvec-nth-d lifecycle-events 0 jolt-nil))
       (task-id (pvec-nth-d spawn 1 jolt-nil)))
  (ok "future lifecycle emitted spawn/start/finish"
      (and (= 3 (pvec-cnt lifecycle-events))
           (eq? (pvec-nth-d spawn 0 jolt-nil) fhk-spawn)))
  (ok "the future FFI descriptor task matches the lifecycle task id"
      (and (> task-id 0)
           (= task-id (jget future-desc jolt-sim-kw-task)))))

;; === native-operation interception + live argument identity =================
(ev "(reset! sim-ffi-events [])")
(ev "(def sim-ffi-arr (byte-array [7 8 9]))")
(is "sizeof native op is intercepted and answered with the exact substitution"
    "(ffi/sizeof :int)" ":native-op-sentinel")
(is "write-array native op is intercepted and answered with the exact substitution"
    "(ffi/write-array 12345 sim-ffi-arr)" ":native-op-sentinel")

(let* ((events (ev "@sim-ffi-events"))
       (d0 (pvec-nth-d events 0 jolt-nil)))
  (ok "two native-op descriptors captured" (= 2 (pvec-cnt events)))
  (ok "native-operation descriptor carries exactly four keys" (= 4 (pmap-cnt d0)))
  (ok "descriptor :kind is exactly :native-operation"
      (eq? (jget d0 jolt-sim-kw-kind) jolt-sim-kw-native-operation))
  (ok "top-level native descriptor carries primordial task id zero"
      (= 0 (jget d0 jolt-sim-kw-task)))
  (ok "descriptor :operation is exactly :sizeof"
      (eq? (jget d0 jolt-sim-kw-operation) (keyword #f "sizeof")))
  (let ((args (jget d0 jolt-sim-kw-arguments)))
    (ok "sizeof descriptor :arguments carries the exact type keyword"
        (and (= 1 (pvec-cnt args))
             (eq? (pvec-nth-d args 0 jolt-nil) (keyword #f "int"))))))

(let* ((d1 (pvec-nth-d (ev "@sim-ffi-events") 1 jolt-nil))
       (args (jget d1 jolt-sim-kw-arguments))
       (captured-arr (pvec-nth-d args 1 jolt-nil))
       (live-arr (ev "sim-ffi-arr")))
  (ok "descriptor :operation is exactly :write-array"
      (eq? (jget d1 jolt-sim-kw-operation) (keyword #f "write-array")))
  (ok "write-array descriptor :arguments is a two-element vector"
      (= 2 (pvec-cnt args)))
  (ok "descriptor :arguments preserves live byte-array object identity, not a copy"
      (eq? captured-arr live-arr)))

;; --- restore returns to the unhooked baseline --------------------------------
(ev "(jolt.internal.sim/restore-ffi-controller! sim-ffi-token)")
(ok "restoring returns to the unhooked baseline" (not jolt-ffi-sim-hook))
(ok "restoring reinstates native execution for an existing harmless symbol"
    (= 7 (jnum->exact (ev "(c-abs -7)"))))

;; === exact restoration of a preexisting raw Scheme hook ======================
;; A hook installed directly through the existing low-level
;; jolt-ffi-install-sim-hook! (e.g. by a test harness or another Scheme-level
;; caller) BEFORE any Jolt-level install-ffi-controller! runs must be the
;; EXACT hook install-ffi-controller!/restore-ffi-controller! nests over and
;; restores back to — not merely "no hook"/#f.
(define low-level-ffi-events '())
(define (low-level-ffi-hook desc) (set! low-level-ffi-events (cons desc low-level-ffi-events)) 111)
(define preexisting-installation (jolt-ffi-install-sim-hook! low-level-ffi-hook))
(ok "the preexisting low-level hook intercepts an ordinary call"
    (= 111 (jnum->exact (ev "(c-abs -7)"))))
(ok "the low-level hook fired once" (= 1 (length low-level-ffi-events)))
(set! low-level-ffi-events '())

(ev "(def sim-ffi-nested-events (atom []))")
(ev "(defn sim-ffi-nested-controller [desc] (swap! sim-ffi-nested-events conj desc) 222)")
(ev "(def sim-ffi-nested-token (jolt.internal.sim/install-ffi-controller! sim-ffi-nested-controller))")
(ok "the nested Jolt-level FFI controller takes over from the low-level hook"
    (= 222 (jnum->exact (ev "(c-abs -7)"))))
(ok "the nested controller observed the call"
    (= 1 (pvec-cnt (ev "@sim-ffi-nested-events"))))
(ok "the low-level hook received no events while nested" (null? low-level-ffi-events))

(ev "(jolt.internal.sim/restore-ffi-controller! sim-ffi-nested-token)")
(ok "restoring after nesting reinstates the exact preexisting low-level hook"
    (= 111 (jnum->exact (ev "(c-abs -7)"))))
(ok "the low-level hook fired again after restore" (= 1 (length low-level-ffi-events)))
(ok "the nested Jolt controller received no further events after restore"
    (= 1 (pvec-cnt (ev "@sim-ffi-nested-events"))))

(jolt-ffi-clear-sim-hook! preexisting-installation)
(set! low-level-ffi-events '())
(ok "clearing the preexisting low-level hook restores native execution"
    (= 7 (jnum->exact (ev "(c-abs -7)"))))

;; === nested/out-of-order/repeated Jolt-level token behavior fails closed ====
(ev "(def sim-ffi-outer-count (atom 0))")
(ev "(def sim-ffi-inner-count (atom 0))")
(ev "(defn sim-ffi-outer-controller [desc] (swap! sim-ffi-outer-count inc) 1)")
(ev "(defn sim-ffi-inner-controller [desc] (swap! sim-ffi-inner-count inc) 2)")
(ev "(def sim-ffi-outer-token (jolt.internal.sim/install-ffi-controller! sim-ffi-outer-controller))")
(ev "(def sim-ffi-inner-token (jolt.internal.sim/install-ffi-controller! sim-ffi-inner-controller))")
(ok "the innermost installation is the active controller"
    (= 1 (jnum->exact (ev "(do (c-abs -7) @sim-ffi-inner-count)"))))
(ok "the outer controller has received no events while nested"
    (= 0 (jnum->exact (ev "@sim-ffi-outer-count"))))

(ok "an out-of-order restore of the outer (non-top) token fails"
    (guard (e (#t #t))
      (ev "(jolt.internal.sim/restore-ffi-controller! sim-ffi-outer-token)")
      #f))
(ok "the failed out-of-order restore left the inner controller active"
    (= 2 (jnum->exact (ev "(do (c-abs -7) @sim-ffi-inner-count)"))))
(ok "the failed out-of-order restore changed nothing about the outer controller"
    (= 0 (jnum->exact (ev "@sim-ffi-outer-count"))))

(ev "(jolt.internal.sim/restore-ffi-controller! sim-ffi-inner-token)")
(ok "restoring the inner token reinstates the outer controller"
    (= 1 (jnum->exact (ev "(do (c-abs -7) @sim-ffi-outer-count)"))))

(ok "repeating a restore of the already-restored inner token fails"
    (guard (e (#t #t))
      (ev "(jolt.internal.sim/restore-ffi-controller! sim-ffi-inner-token)")
      #f))
(ok "the failed repeated restore left the outer controller active"
    (= 2 (jnum->exact (ev "(do (c-abs -7) @sim-ffi-outer-count)"))))

(ev "(jolt.internal.sim/restore-ffi-controller! sim-ffi-outer-token)")
(ok "the final, in-order restore returns to unhooked native execution"
    (= 7 (jnum->exact (ev "(c-abs -7)"))))

;; === callback error propagation ==============================================
(ev "(defn sim-ffi-raising-controller [desc] (throw (ex-info \"boom\" {})))")
(ev "(def sim-ffi-raise-token (jolt.internal.sim/install-ffi-controller! sim-ffi-raising-controller))")
(ok "a Jolt-level controller's error propagates through the intercepted call"
    (guard (e (#t #t)) (ev "(c-abs -7)") #f))
(ev "(jolt.internal.sim/restore-ffi-controller! sim-ffi-raise-token)")
(ok "restoring after a controller error returns to native execution"
    (= 7 (jnum->exact (ev "(c-abs -7)"))))

;; === reentrant FFI from a Jolt-level controller fails closed =================
;; The reentrancy guard belongs to the shared low-level seam
;; (jolt-ffi-invoke-sim-hook), so it rejects a controller that performs ANY
;; intercepted FFI operation on the same thread — a native op from inside a
;; foreign-function call's controller, exactly like the defcfn-from-defcfn case
;; ffi-sim-hook-test.ss pins at the Scheme layer.
(ev "(defn sim-ffi-reentrant-controller [desc] (ffi/sizeof :int))")
(ev "(def sim-ffi-reentrant-token (jolt.internal.sim/install-ffi-controller! sim-ffi-reentrant-controller))")
(ok "reentrant FFI from a Jolt-level controller fails closed"
    (guard (e (#t #t)) (ev "(c-abs -7)") #f))
(ev "(jolt.internal.sim/restore-ffi-controller! sim-ffi-reentrant-token)")
(ok "restoring after a reentrancy rejection returns to native execution"
    (= 7 (jnum->exact (ev "(c-abs -7)"))))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
