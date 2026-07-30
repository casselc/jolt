;; host/chez/sim/runtime.ss — simulation-only runtime overlay.
;;
;; Loaded ONLY by the special `sim` Jolt build (host/chez/build-jolt.ss profile
;; "sim", target/sim/jolt) — never by an ordinary release/debug binary and never
;; by the checked-in seed's clojure.core/jolt-core. It reinstates, over the
;; branch-free base runtime (host/chez/java/concurrency.ss,
;; host/chez/java/ffi.ss), the disabled-by-default observability + interception
;; seams those files used to carry directly:
;;
;;   - future lifecycle hook: :spawn/:start/:finish/:cancel events around every
;;     ordinary future-call, install/clear via jolt-future-hook-set!/-clear!.
;;   - FFI call interception: every jolt.ffi/defcfn call whose compilation unit
;;     had sim-instrument? on (emit-ffi-fn, jolt-core/jolt/backend_scheme.clj)
;;     references jolt-ffi-sim-hook directly in its emitted Scheme, so that
;;     variable — and install/clear/invoke — must exist wherever such code runs.
;;   - raw native-op interception: the SAME hook extended to jolt.ffi's runtime
;;     primitives (load-library, loaded?, alloc, free, read, write, read-bytes,
;;     write-bytes, read-array, write-array, ptr->string, string->ptr, sizeof).
;;
;; Each seam is expressed here as a NEW procedure that snapshots the relevant
;; hook once and falls through to the base (now branch-free) procedure when no
;; hook is installed — so the native/no-hook path is byte-for-byte the base
;; runtime's own behavior, not a re-implementation of it. The public vars
;; (clojure.core/future-call, future-cancel; jolt.ffi/load-library, loaded?,
;; alloc, free, read, write, sizeof, read-bytes, write-bytes, read-array,
;; write-array, ptr->string, string->ptr) are then REBOUND via def-var! to
;; these hook-aware versions, exactly as post-prelude.ss re-asserts vars over
;; an earlier layer's.
;;
;; Load after host/chez/java/concurrency.ss and host/chez/java/ffi.ss (both
;; part of the ordinary runtime chain rt.ss already loads); see
;; host/chez/build-jolt.ss (jb-sim-init-form / the "sim" profile) and
;; host/chez/build.ss (bld-emit-runtime, gated on jolt-sim-flavor?) for how it
;; is wired into the sim binary's own load order and embedded-resource closure.

;; === future lifecycle hook ===================================================
;; A disabled-by-default observability + gating seam over the centralized
;; fork-thread future path (host/chez/java/concurrency.ss's jolt-future-call).
;; When a hook fn (a jolt IFn) is installed via jolt-future-hook-set!, each
;; ordinary future-call fires three lifecycle events to it (called with jolt
;; values):
;;   (:spawn  id parent)  on the SPAWNING thread, before the worker forks
;;   (:start  id parent)  on the WORKER thread, BEFORE the body runs — the hook
;;                        MAY BLOCK here (e.g. park on a promise) so a single
;;                        controller chooses which ordinary future begins
;;   (:finish id parent)  on the WORKER thread, AFTER the body computes a result
;;                        (value OR thrown condition), BEFORE it is published
;;   (:cancel id parent)  on the CANCELLING thread, BEFORE cancellation is
;;                        published; exactly one of :finish/:cancel wins
;; `id` is a stable, unique, nonnegative int (1, 2, 3, …; never recycled) assigned
;; per future-call; `parent` is the task id in effect on the spawning thread (0 for
;; the primordial thread / any thread that is not itself a hooked future). A
;; :spawn hook failure propagates synchronously before any worker is forked. A
;; :start hook failure is captured as that future's failure, so deref cannot hang
;; and the body is not run. Terminal-hook failures never replace the application
;; result/cancellation; they are retained in a structured supervisor-error latch.
;; Dynamic bindings, cancellation, and ExecutionException propagation are
;; otherwise identical to the fast path. This is a TEST/simulation hook, not an
;; application task DSL — it is deliberately kept off the clojure.core/jolt.host
;; surface (install/clear through the Scheme procs below).
(define-record-type jolt-hooked-future
  (parent jolt-future)
  (fields hook task-id parent-id (mutable settling?))
  (nongenerative jolt-hooked-future-v1))

(define jolt-future-hook (box #f))           ; #f (disabled) or a jolt hook fn
(define jolt-future-id-mu (make-mutex))      ; guards the monotonic id counter
(define jolt-future-next-id (box 1))
;; This thread's task id (0 outside any hooked future). A future whose body spawns
;; another future reports this id as the child's parent.
(define jolt-future-task-id (make-thread-parameter 0))
(define fhk-spawn  (keyword #f "spawn"))
(define fhk-start  (keyword #f "start"))
(define fhk-finish (keyword #f "finish"))
(define fhk-cancel (keyword #f "cancel"))
(define jolt-future-hook-error-mu (make-mutex))
(define jolt-future-hook-errors '())

(define (jolt-future-current-task-id) (jolt-future-task-id))
(define (jolt-future-alloc-id!)
  (with-mutex jolt-future-id-mu
    (let ((n (unbox jolt-future-next-id)))
      (set-box! jolt-future-next-id (+ n 1))
      n)))
(define (jolt-future-hook-set! f) (set-box! jolt-future-hook f) jolt-nil)
(define (jolt-future-hook-clear!) (set-box! jolt-future-hook #f) jolt-nil)
(define (jolt-future-hook-error-record! event id parent e)
  (with-mutex jolt-future-hook-error-mu
    (set! jolt-future-hook-errors
          (cons (list event id parent e) jolt-future-hook-errors)))
  #f)
(define (jolt-future-hook-errors-snapshot)
  (with-mutex jolt-future-hook-error-mu
    (reverse jolt-future-hook-errors)))
(define (jolt-future-hook-errors-clear!)
  (with-mutex jolt-future-hook-error-mu
    (set! jolt-future-hook-errors '()))
  jolt-nil)
(define (jolt-future-hook-invoke hook event id parent)
  (guard (e (#t
             (jolt-future-hook-error-record! event id parent e)
             (raise e)))
    (jolt-invoke hook event id parent)))
(define (jolt-future-hook-terminal-invoke hook event id parent)
  (guard (e (#t (jolt-future-hook-error-record! event id parent e)))
    (jolt-invoke hook event id parent)))

(define (jolt-hooked-future-claim-terminal! f)
  (with-mutex (jolt-future-mu f)
    (if (or (jolt-future-done? f) (jolt-hooked-future-settling? f))
        #f
        (begin
          (jolt-hooked-future-settling?-set! f #t)
          #t))))

(define (jolt-hooked-future-publish-result! f r)
  (with-mutex (jolt-future-mu f)
    (jolt-future-ok?-set! f (car r))
    (jolt-future-payload-set! f (cdr r))
    (jolt-hooked-future-settling?-set! f #f)
    (jolt-future-done?-set! f #t)
    (condition-broadcast (jolt-future-cv f))))

;; Hook-aware future-call: with NO hook installed this defers to the base
;; jolt-future-call unchanged (no id, no wrapped record, no extra locking).
;; When a hook fn is installed it observes :spawn/:start/:finish and may block
;; at :start so a controller can order ordinary futures — see the seam above.
(define (jolt-sim-future-call thunk)
  (let ((hook (unbox jolt-future-hook)))
    (if (not hook)
        (jolt-future-call thunk)
        (let* ((snap (dyn-binding-stack))
               (parent (jolt-future-task-id))
               (id (jolt-future-alloc-id!))
               (f (make-jolt-hooked-future
                   #f #f #f jolt-nil (make-mutex) (make-condition)
                   hook id parent #f)))
          ;; :spawn fires synchronously on this thread before the worker forks,
          ;; so any gate the hook arms for `id` is in place before :start runs.
          ;; Fail closed before the fork: a controller that cannot register this
          ;; task must not let the ordinary future escape uncontrolled.
          (jolt-future-hook-invoke hook fhk-spawn id parent)
          (fork-thread
           (lambda ()
             (*txn* #f)
             (dyn-binding-stack snap)
             (jolt-future-task-id id)        ; this body's spawns report id as parent
             ;; :start may BLOCK so a controller chooses when this body begins.
             ;; Capture a start-hook failure in the same result channel as a body
             ;; failure: the body is skipped and deref observes normal future
             ;; ExecutionException semantics instead of hanging.
             (let ((r (guard (e (#t (cons #f e)))
                        (jolt-future-hook-invoke hook fhk-start id parent)
                        (cons #t (jolt-invoke thunk)))))
               ;; Exactly one terminal claimant wins. Its hook runs before the
               ;; result/cancellation becomes visible, and never while holding
               ;; the future mutex, so the controller is a causal boundary
               ;; without creating a hook/mutex deadlock.
               (when (jolt-hooked-future-claim-terminal! f)
                 (jolt-future-hook-terminal-invoke hook fhk-finish id parent)
                 (jolt-hooked-future-publish-result! f r)))))
          f))))

;; Hook-aware future-cancel: a hooked future's cancellation is a terminal event,
;; published only after the controller's :cancel observer runs; any other future
;; (no hook was installed when it was spawned) defers to the base jolt-future-cancel.
(define (jolt-sim-future-cancel f)
  (if (jolt-hooked-future? f)
      (if (jolt-hooked-future-claim-terminal! f)
          (begin
            (jolt-future-hook-terminal-invoke
             (jolt-hooked-future-hook f)
             fhk-cancel
             (jolt-hooked-future-task-id f)
             (jolt-hooked-future-parent-id f))
            (with-mutex (jolt-future-mu f)
              (jolt-future-cancelled?-set! f #t)
              (jolt-hooked-future-settling?-set! f #f)
              (jolt-future-done?-set! f #t)
              (condition-broadcast (jolt-future-cv f)))
            #t)
          #f)
      (jolt-future-cancel f)))

(def-var! "clojure.core" "future-call" jolt-sim-future-call)
(def-var! "clojure.core" "future-cancel" jolt-sim-future-cancel)

;; === FFI call interception (simulation seam) =================================
;; jolt-ffi-sim-hook, when non-#f, intercepts EVERY jolt.ffi/defcfn call before
;; the native symbol is ever resolved: emit-ffi-fn (jolt-core/jolt/backend_scheme.clj)
;; emits a reference to this variable for a compilation unit whose
;; sim-instrument? flag is on, checked on EVERY call (not just the first); when
;; set it calls the hook with a descriptor instead of forcing the
;; `foreign-procedure` form — so the untaken branch means the native symbol is
;; never looked up.
;;
;; Internal/test-oriented only: no jolt.ffi/... var exposes this, and it is not a
;; public simulation DSL — a simulation controller installs/clears it directly
;; from Scheme (see test/chez/ffi-sim-hook-test.ss).
;;
;; Installations form a strict stack. Clearing requires the token returned by
;; install and only the current owner may clear. This gives nested simulations a
;; precise restore operation and makes an out-of-order concurrent clear fail
;; closed instead of silently disabling another controller.
(define-record-type jolt-ffi-sim-hook-installation
  (fields hook previous)
  (nongenerative jolt-ffi-sim-hook-installation-v1))
(define jolt-ffi-sim-hook #f) ; current hook, kept separate for the hot-path read
(define jolt-ffi-sim-hook-top #f)
(define jolt-ffi-sim-hook-mu (make-mutex))
(define jolt-ffi-sim-hook-active-owner (make-thread-parameter #f))

(define (jolt-ffi-install-sim-hook! h)
  (unless h
    (error 'jolt-ffi-install-sim-hook! "hook must be non-false"))
  (with-mutex jolt-ffi-sim-hook-mu
    (let ((installation
           (make-jolt-ffi-sim-hook-installation h jolt-ffi-sim-hook-top)))
      (set! jolt-ffi-sim-hook-top installation)
      (set! jolt-ffi-sim-hook h)
      installation)))

(define (jolt-ffi-clear-sim-hook! installation)
  (with-mutex jolt-ffi-sim-hook-mu
    (unless (eq? installation jolt-ffi-sim-hook-top)
      (error 'jolt-ffi-clear-sim-hook!
             "simulation hooks must be cleared by their current owner"))
    (let ((previous
           (jolt-ffi-sim-hook-installation-previous installation)))
      (set! jolt-ffi-sim-hook-top previous)
      (set! jolt-ffi-sim-hook
            (and previous
                 (jolt-ffi-sim-hook-installation-hook previous)))))
  jolt-nil)

;; A stable plain descriptor for one intercepted call: an alist keyed by csym /
;; argtypes / rettype / blocking / args. argtypes is a list of type-name strings
;; (foreign-fn's keyword names, without the leading colon, e.g. "int" "string");
;; args is the list of actual jolt arguments in call order. Descriptor metadata
;; strings are copied on every call so a hook cannot mutate a later descriptor.
;; Argument objects deliberately remain live: a native stub must be able to
;; emulate writes through byte arrays/pointers. The hook's return value stands
;; in for the call's result.
(define (jolt-ffi-make-sim-descriptor csym argtypes rettype blocking args)
  (list (cons 'csym (string-copy csym))
        (cons 'argtypes (map string-copy argtypes))
        (cons 'rettype (string-copy rettype))
        (cons 'blocking blocking)
        (cons 'args args)))

(define (jolt-ffi-invoke-sim-hook h descriptor)
  ;; A hook that performs FFI would otherwise recursively intercept itself.
  ;; Fail closed until a future explicit, scoped real-call continuation exists;
  ;; clearing/reinstalling the process-global hook is never a safe bypass.
  ;;
  ;; Chez thread parameters are inherited by forked threads, so retain the
  ;; active thread id rather than a boolean. A child inheriting its parent's id
  ;; is not permanently poisoned; only recursion on the same dynamic thread is
  ;; rejected.
  (let ((self (get-thread-id)))
    (when (eqv? self (jolt-ffi-sim-hook-active-owner))
      (error 'jolt-ffi-invoke-sim-hook
             "reentrant FFI from a simulation hook is not supported"))
    (parameterize ((jolt-ffi-sim-hook-active-owner self))
      (jolt-invoke h descriptor))))

;; A native-op interception extends the SAME hook (and so its stack ownership +
;; reentrancy guard above) to the runtime primitives a jolt library uses to load
;; shared objects and manage raw foreign memory: load-library, loaded?, alloc,
;; free, read, write, read-bytes, write-bytes, read-array, write-array,
;; ptr->string, string->ptr, sizeof. Each primitive below snapshots the same
;; hot-path variable ONCE and, when a hook is installed, routes the call through
;; it instead of the base (branch-free) OS loader / Chez foreign-memory ops in
;; host/chez/java/ffi.ss; with no hook the base primitive runs unchanged.
;;
;; The descriptor is a stable plain alist with kind `native-op`, `op` (a
;; snapshot of the operation name), and `args` (the live jolt call arguments, in
;; call order). The kind/op keys distinguish it from a defcfn call descriptor,
;; which is keyed by `csym`. Argument objects deliberately remain live so a hook
;; can emulate writes through byte arrays / pointers (out-param emulation); the
;; hook's return value stands in for the primitive's result. Under a hook,
;; nonexistent libraries and the fake pointers a hook may hand back therefore
;; never reach the OS loader or Chez's foreign memory primitives.
(define (jolt-ffi-make-native-sim-descriptor op args)
  (list (cons 'kind 'native-op)
        (cons 'op (string-copy op))
        (cons 'args args)))

(define (jolt-ffi-invoke-native-sim-op h op args)
  (jolt-ffi-invoke-sim-hook h
                            (jolt-ffi-make-native-sim-descriptor op args)))

(define (ffi-sim-load-library . args)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op h "load-library" args)
        (apply ffi-load-library args))))
(define (ffi-sim-loaded? name)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op h "loaded?" (list name))
        (ffi-loaded? name))))
(define (ffi-sim-alloc nbytes)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op h "alloc" (list nbytes))
        (ffi-alloc nbytes))))
(define (ffi-sim-free ptr)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op h "free" (list ptr))
        (ffi-free ptr))))
(define (ffi-sim-read ptr ty . off)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op h "read" (cons ptr (cons ty off)))
        (apply ffi-read ptr ty off))))
(define (ffi-sim-write ptr ty off val)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op h "write" (list ptr ty off val))
        (ffi-write ptr ty off val))))
(define (ffi-sim-sizeof ty)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op h "sizeof" (list ty))
        (ffi-sizeof ty))))
(define (ffi-sim-read-bytes ptr n)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op h "read-bytes" (list ptr n))
        (ffi-read-bytes ptr n))))
(define (ffi-sim-write-bytes ptr s)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op h "write-bytes" (list ptr s))
        (ffi-write-bytes ptr s))))
(define (ffi-sim-read-array ptr n)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op h "read-array" (list ptr n))
        (ffi-read-array ptr n))))
(define (ffi-sim-write-array ptr arr)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op h "write-array" (list ptr arr))
        (ffi-write-array ptr arr))))
(define (ffi-sim-ptr->string ptr)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op h "ptr->string" (list ptr))
        (ffi-ptr->string ptr))))
(define (ffi-sim-string->ptr s)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op h "string->ptr" (list s))
        (ffi-string->ptr s))))

(def-var! "jolt.ffi" "load-library" ffi-sim-load-library)
(def-var! "jolt.ffi" "loaded?" (lambda (n) (if (ffi-sim-loaded? n) #t #f)))
(def-var! "jolt.ffi" "alloc" ffi-sim-alloc)
(def-var! "jolt.ffi" "free" ffi-sim-free)
(def-var! "jolt.ffi" "read" ffi-sim-read)
(def-var! "jolt.ffi" "write" ffi-sim-write)
(def-var! "jolt.ffi" "sizeof" ffi-sim-sizeof)
(def-var! "jolt.ffi" "read-bytes" ffi-sim-read-bytes)
(def-var! "jolt.ffi" "write-bytes" ffi-sim-write-bytes)
(def-var! "jolt.ffi" "read-array" ffi-sim-read-array)
(def-var! "jolt.ffi" "write-array" ffi-sim-write-array)
(def-var! "jolt.ffi" "ptr->string" ffi-sim-ptr->string)
(def-var! "jolt.ffi" "string->ptr" ffi-sim-string->ptr)
