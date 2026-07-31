;; host/chez/sim/runtime.ss — simulation-only runtime overlay.
;;
;; Loaded ONLY by the special `sim` Jolt build (host/chez/build-jolt.ss profile
;; "sim", target/sim/jolt) — never by an ordinary release/debug binary and never
;; by the checked-in seed's clojure.core/jolt-core. It reinstates, over the
;; branch-free base runtime (host/chez/java/concurrency.ss,
;; host/chez/java/ffi.ss), the disabled-by-default observability + interception
;; seams those files used to carry directly:
;;
;;   - future lifecycle hook: :spawn/:start/:finish/:cancel/:exit/:abort events
;;     around every ordinary future-call, install/clear via
;;     jolt-future-hook-set!/-clear!.
;;   - FFI call interception: every jolt.ffi/defcfn call whose compilation unit
;;     had sim-instrument? on (emit-ffi-fn, jolt-core/jolt/backend_scheme.clj)
;;     references jolt-ffi-sim-hook directly in its emitted Scheme, so that
;;     variable — and install/clear/invoke — must exist wherever such code runs.
;;   - raw native-op interception: the SAME hook extended to jolt.ffi's runtime
;;     primitives (load-library, loaded?, alloc, free, read, write, read-bytes,
;;     write-bytes, read-array, write-array, borrow-byte-array,
;;     release-byte-array, ptr->string, string->ptr, sizeof).
;;
;; Each seam is expressed here as a NEW procedure that snapshots the relevant
;; hook once and falls through to the base (now branch-free) procedure when no
;; hook is installed — so the native/no-hook path is byte-for-byte the base
;; runtime's own behavior, not a re-implementation of it. The public vars
;; (clojure.core/future-call, future-cancel; jolt.ffi/load-library, loaded?,
;; alloc, free, read, write, sizeof, read-bytes, write-bytes, read-array,
;; write-array, with-byte-array-pointer, ptr->string, string->ptr) are then
;; REBOUND via def-var! to these hook-aware versions, exactly as post-prelude.ss
;; re-asserts vars over an earlier layer's.
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
;; ordinary future-call fires lifecycle events to it (called with jolt values):
;;   (:spawn  id parent)  on the SPAWNING thread, before the worker forks
;;   (:start  id parent)  on the WORKER thread, BEFORE the body runs — the hook
;;                        MAY BLOCK here (e.g. park on a promise) so a single
;;                        controller chooses which ordinary future begins
;;   (:finish id parent)  on the WORKER thread, AFTER the body computes a result
;;                        (value OR thrown condition), BEFORE it is published
;;   (:cancel id parent)  on the CANCELLING thread, BEFORE cancellation is
;;                        published; exactly one of :finish/:cancel wins
;;   (:exit   id parent)  on the WORKER thread, AFTER the winning result or
;;                        cancellation is published; every forked worker
;;                        attempts exactly one exit callback, even when start
;;                        or the body failed or cancellation won
;;   (:abort  id parent)  on the SPAWNING thread if :spawn registration or the
;;                        subsequent fork fails; no worker exists for that task
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
(define fhk-exit   (keyword #f "exit"))
(define fhk-abort  (keyword #f "abort"))
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

;; A worker that loses the terminal claim to future-cancel must not publish its
;; computed result, but its :exit acknowledgement still has to follow the
;; canceller's :cancel callback and publication. claim-terminal! alone is not
;; that boundary: the winner invokes its hook outside the mutex before setting
;; done?. Wait on the future's existing condition so :exit observes the
;; published terminal state in both winner cases.
(define (jolt-hooked-future-await-published! f)
  (with-mutex (jolt-future-mu f)
    (let loop ()
      (unless (jolt-future-done? f)
        (condition-wait (jolt-future-cv f) (jolt-future-mu f))
        (loop)))))

;; Hook-aware future-call: with NO hook installed this defers to the base
;; jolt-future-call unchanged (no id, no wrapped record, no extra locking).
;; When a hook fn is installed it observes :spawn/:start, one of
;; :finish/:cancel, and the worker's final :exit acknowledgement. It may block
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
          ;; task must not let the ordinary future escape uncontrolled. If
          ;; registration or fork-thread itself fails, :abort balances the
          ;; announced id so an external controller need not guess whether a
          ;; worker still exists.
          (guard (e (#t
                     (jolt-future-hook-terminal-invoke
                      hook fhk-abort id parent)
                     (raise e)))
            (jolt-future-hook-invoke hook fhk-spawn id parent)
            (fork-thread
             (lambda ()
               ;; Capture worker setup and a start-hook failure in the same
               ;; result channel as a body failure. The body is skipped and
               ;; deref observes ordinary ExecutionException semantics instead
               ;; of hanging, while the worker still reaches :exit.
               (let ((r (guard (e (#t (cons #f e)))
                          (*txn* #f)
                          (dyn-binding-stack snap)
                          ;; This body's spawns report id as their parent.
                          (jolt-future-task-id id)
                          (jolt-future-hook-invoke hook fhk-start id parent)
                          (cons #t (jolt-invoke thunk)))))
                 ;; Exactly one terminal claimant wins. Its hook runs before
                 ;; the result/cancellation becomes visible, and never while
                 ;; holding the future mutex, so the controller is a causal
                 ;; boundary without creating a hook/mutex deadlock.
                 (when (jolt-hooked-future-claim-terminal! f)
                   (jolt-future-hook-terminal-invoke
                    hook fhk-finish id parent)
                   (jolt-hooked-future-publish-result! f r))
                 ;; If cancellation won while this non-interruptible worker was
                 ;; running, wait until its :cancel hook and publication finish.
                 ;; :exit is supervisor-style: its failure is latched and cannot
                 ;; replace the already-published result or cancellation.
                 (jolt-hooked-future-await-published! f)
                 (jolt-future-hook-terminal-invoke
                  hook fhk-exit id parent)))))
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
  (fields hook routing? previous)
  (nongenerative jolt-ffi-sim-hook-installation-v2))
;; The hot-path value is the current immutable installation snapshot, not just
;; its callback. Keeping callback mode and strict-stack identity in one object
;; prevents a concurrent install/restore from pairing a hook with the wrong
;; invocation contract.
(define jolt-ffi-sim-hook #f)
(define jolt-ffi-sim-hook-top #f)
(define jolt-ffi-sim-hook-mu (make-mutex))
(define jolt-ffi-sim-hook-active-owner (make-thread-parameter #f))

(define (jolt-ffi-install-sim-hook-mode! h routing?)
  (unless h
    (error 'jolt-ffi-install-sim-hook-mode! "hook must be non-false"))
  (with-mutex jolt-ffi-sim-hook-mu
    (let ((installation
           (make-jolt-ffi-sim-hook-installation
            h routing? jolt-ffi-sim-hook-top)))
      (set! jolt-ffi-sim-hook-top installation)
      (set! jolt-ffi-sim-hook installation)
      installation)))

;; The established one-argument hook contract remains exact. Only the new
;; routing installer opts into receiving a second, scoped native continuation.
(define (jolt-ffi-install-sim-hook! h)
  (jolt-ffi-install-sim-hook-mode! h #f))
(define (jolt-ffi-install-routing-hook! h)
  (jolt-ffi-install-sim-hook-mode! h #t))

(define (jolt-ffi-clear-sim-hook! installation)
  (with-mutex jolt-ffi-sim-hook-mu
    (unless (eq? installation jolt-ffi-sim-hook-top)
      (error 'jolt-ffi-clear-sim-hook!
             "simulation hooks must be cleared by their current owner"))
    (let ((previous
           (jolt-ffi-sim-hook-installation-previous installation)))
      (set! jolt-ffi-sim-hook-top previous)
      (set! jolt-ffi-sim-hook previous)))
  jolt-nil)

;; A stable plain descriptor for one intercepted call: an alist keyed by csym /
;; argtypes / rettype / blocking / capture-native-error / args. argtypes is a
;; list of type-name strings (foreign-fn's keyword names, without the leading
;; colon, e.g. "int" "string"); args is the list of actual jolt arguments in
;; call order. Descriptor metadata strings are copied on every call so a hook
;; cannot mutate a later descriptor. Argument objects deliberately remain live:
;; a native stub must be able to emulate writes through byte arrays/pointers.
;; The hook's return value stands in for the complete public binding result:
;; scalar for an ordinary binding, or [native-result error-code] for one with
;; :capture-native-error enabled.
(define (jolt-ffi-make-sim-descriptor
         csym argtypes rettype blocking capture-native-error args)
  (list (cons 'csym (string-copy csym))
        (cons 'argtypes (map string-copy argtypes))
        (cons 'rettype (string-copy rettype))
        (cons 'blocking blocking)
        (cons 'capture-native-error capture-native-error)
        (cons 'args args)))

(define (jolt-ffi-invoke-sim-hook* installation descriptor native-call)
  ;; A hook that performs FFI would otherwise recursively intercept itself.
  ;; The routing API authorizes only its supplied native-call continuation;
  ;; clearing/reinstalling the process-global hook is never a safe bypass, and
  ;; any separate FFI made by a controller remains reentrant and fails closed.
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
      (let ((h (jolt-ffi-sim-hook-installation-hook installation)))
        (if (not (jolt-ffi-sim-hook-installation-routing? installation))
            (jolt-invoke h descriptor)
            (begin
              (unless native-call
                (error 'jolt-ffi-invoke-sim-hook
                       "instrumented call does not carry a native proceed thunk"))
              (let ((live? #t)
                    (used? #f))
                (let ((proceed
                       (lambda ()
                         (unless live?
                           (error 'jolt-ffi-proceed
                                  "native proceed is outside its dynamic extent"))
                         (unless (eqv? self (get-thread-id))
                           (error 'jolt-ffi-proceed
                                  "native proceed must run on its controller thread"))
                         (when used?
                           (error 'jolt-ffi-proceed
                                  "native proceed may be invoked only once"))
                         ;; Consumption is failure-atomic: a native exception
                         ;; does not make the same effect eligible to run twice.
                         (set! used? #t)
                         (native-call))))
                  (dynamic-wind
                    (lambda ()
                      (unless live?
                        (error
                         'jolt-ffi-invoke-sim-hook
                         "routing controller continuation cannot be re-entered")))
                    (lambda () (jolt-invoke2 h descriptor proceed))
                    (lambda () (set! live? #f)))))))))))

;; Retain the two-argument entry point for code compiled by descriptor-v1/v2/v3
;; sim compilers. It remains fully usable with the established one-argument
;; hook; a new routing hook fails closed rather than pretending such a call has
;; a native continuation.
(define jolt-ffi-invoke-sim-hook
  (case-lambda
    ((installation descriptor)
     (jolt-ffi-invoke-sim-hook* installation descriptor #f))
    ((installation descriptor native-call)
     (jolt-ffi-invoke-sim-hook* installation descriptor native-call))))

;; A native-op interception extends the SAME hook (and so its stack ownership +
;; reentrancy guard above) to the runtime primitives a jolt library uses to load
;; shared objects and manage raw foreign memory: load-library, loaded?, alloc,
;; free, read, write, read-bytes, write-bytes, read-array, write-array,
;; borrow-byte-array, release-byte-array, ptr->string, string->ptr, sizeof. Each
;; primitive below snapshots the same
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

(define (jolt-ffi-invoke-native-sim-op h op args native-call)
  (jolt-ffi-invoke-sim-hook h
                            (jolt-ffi-make-native-sim-descriptor op args)
                            native-call))

(define (ffi-sim-load-library . args)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op
         h "load-library" args (lambda () (apply ffi-load-library args)))
        (apply ffi-load-library args))))
(define (ffi-sim-loaded? name)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op
         h "loaded?" (list name) (lambda () (ffi-loaded? name)))
        (ffi-loaded? name))))
(define (ffi-sim-alloc nbytes)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op
         h "alloc" (list nbytes) (lambda () (ffi-alloc nbytes)))
        (ffi-alloc nbytes))))
(define (ffi-sim-free ptr)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op
         h "free" (list ptr) (lambda () (ffi-free ptr)))
        (ffi-free ptr))))
(define (ffi-sim-read ptr ty . off)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op
         h "read" (cons ptr (cons ty off))
         (lambda () (apply ffi-read ptr ty off)))
        (apply ffi-read ptr ty off))))
(define (ffi-sim-write ptr ty off val)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op
         h "write" (list ptr ty off val)
         (lambda () (ffi-write ptr ty off val)))
        (ffi-write ptr ty off val))))
(define (ffi-sim-sizeof ty)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op
         h "sizeof" (list ty) (lambda () (ffi-sizeof ty)))
        (ffi-sizeof ty))))
(define (ffi-sim-read-bytes ptr n)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op
         h "read-bytes" (list ptr n) (lambda () (ffi-read-bytes ptr n)))
        (ffi-read-bytes ptr n))))
(define (ffi-sim-write-bytes ptr s)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op
         h "write-bytes" (list ptr s) (lambda () (ffi-write-bytes ptr s)))
        (ffi-write-bytes ptr s))))
(define (ffi-sim-read-array ptr n)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op
         h "read-array" (list ptr n) (lambda () (ffi-read-array ptr n)))
        (ffi-read-array ptr n))))
(define (ffi-sim-write-array ptr arr)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op
         h "write-array" (list ptr arr) (lambda () (ffi-write-array ptr arr)))
        (ffi-write-array ptr arr))))
(define (ffi-sim-with-byte-array-pointer-range arr off len f)
  ;; Stage a modeled loan around, not inside, the hook. borrow-byte-array sees
  ;; the SAME live array plus its validated range and returns a fake pointer.
  ;; The ordinary callback runs after that hook invocation has returned, so its
  ;; nested defcfn and raw-memory calls are intercepted normally instead of
  ;; tripping the same-thread hook reentrancy guard. release-byte-array retires
  ;; the fake pointer on every exit.
  ;;
  ;; Capture the issuing hook once: cleanup belongs to the controller that
  ;; created the pointer. A routing controller may proceed with the exact real
  ;; borrow, but the runtime then owns and unconditionally balances its real
  ;; lock; a separate release decision can delay or observe cleanup, never leak
  ;; the lock or unlock a modeled pointer. As in the real scope, a continuation
  ;; cannot re-enter after its first exit because the pointer is retired.
  (let* ((start (jnum->exact off))
         (cnt (jnum->exact len))
         (bv (ffi-byte-array-backing "with-byte-array-pointer" arr))
         (h jolt-ffi-sim-hook))
    (ffi-check-array-range "with-byte-array-pointer" bv start cnt)
    (if (not h)
        (ffi-with-byte-array-pointer-range arr start cnt f)
        (let ((p #f)
              (real-p #f)
              (real-bv #f)
              (borrowed? #f)
              (retired? #f))
          (letrec
              ((release-real!
                (lambda ()
                  (unless real-bv
                    (error 'jolt-ffi-proceed
                           "real byte-array loan is already released"))
                  (ffi-release-locked-byte-range real-bv)
                  (set! real-bv #f)
                  jolt-nil)))
            (dynamic-wind
              (lambda ()
                (when retired?
                  (error
                   'jolt.ffi
                   "scoped byte-array pointer continuation cannot be re-entered")))
              (lambda ()
                (set! p
                      (jnum->exact
                       (jolt-ffi-invoke-native-sim-op
                        h "borrow-byte-array" (list arr start cnt)
                        (lambda ()
                          (let ((rp
                                 (ffi-borrow-locked-byte-range
                                  "with-byte-array-pointer" bv start cnt)))
                            (set! real-p rp)
                            (set! real-bv bv)
                            rp)))))
                (when (<= p 0)
                  (error 'jolt.ffi
                         "simulated byte-array loan must return a positive pointer"))
                ;; Once the controller performs a real borrow it may observe or
                ;; wrap the result, but it may not substitute a different
                ;; pointer and strand the runtime-owned real lock.
                (when (and real-bv (not (= p real-p)))
                  (error 'jolt.ffi
                         "routing controller changed a real byte-array pointer"))
                (set! borrowed? #t)
                ;; This callback remains outside either controller invocation,
                ;; so its own FFI effects are intercepted normally rather than
                ;; rejected as same-thread controller reentrancy.
                (jolt-invoke2 f p cnt))
              (lambda ()
                (set! retired? #t)
                (cond
                  (real-bv
                   ;; If borrow completed, report the paired release and offer
                   ;; its exact real unlock. Whether the controller proceeds,
                   ;; returns a modeled value, or raises, force the unlock once.
                   (if borrowed?
                       (guard
                        (e (#t
                            (when real-bv (release-real!))
                            (raise e)))
                        (jolt-ffi-invoke-native-sim-op
                         h "release-byte-array" (list p) release-real!)
                        (when real-bv (release-real!)))
                       (release-real!)))
                  (borrowed?
                   ;; A modeled borrow has no real lock. Calling proceed on its
                   ;; release is rejected before Chez can see an unmatched
                   ;; unlock; returning normally preserves the v3 model path.
                   (jolt-ffi-invoke-native-sim-op
                    h "release-byte-array" (list p)
                    (lambda ()
                      (error 'jolt-ffi-proceed
                             "cannot proceed release of a modeled byte-array loan"))))))))))))
(define ffi-sim-with-byte-array-pointer
  (case-lambda
    ((arr f)
     (let ((bv (ffi-byte-array-backing "with-byte-array-pointer" arr)))
       (ffi-sim-with-byte-array-pointer-range
        arr 0 (bytevector-length bv) f)))
    ((arr off len f)
     (ffi-sim-with-byte-array-pointer-range arr off len f))))
(define (ffi-sim-ptr->string ptr)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op
         h "ptr->string" (list ptr) (lambda () (ffi-ptr->string ptr)))
        (ffi-ptr->string ptr))))
(define (ffi-sim-string->ptr s)
  (let ((h jolt-ffi-sim-hook))
    (if h
        (jolt-ffi-invoke-native-sim-op
         h "string->ptr" (list s) (lambda () (ffi-string->ptr s)))
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
(def-var! "jolt.ffi" "with-byte-array-pointer"
          ffi-sim-with-byte-array-pointer)
(def-var! "jolt.ffi" "ptr->string" ffi-sim-ptr->string)
(def-var! "jolt.ffi" "string->ptr" ffi-sim-string->ptr)

;; === controller ABI (jolt.internal.sim, sim-image-only) =====================
;; A small internal Jolt namespace exposing the future lifecycle hook and the
;; FFI call-interception seam above (and the future hook's supervisor-error
;; latch) to ORDINARY Jolt source running inside the sim image — NOT a public
;; application DSL. The FFI half (install-ffi-controller!/
;; install-ffi-routing-controller!/restore-ffi-controller!) is a thin projection
;; over the existing
;; jolt-ffi-install-sim-hook!/-clear-sim-hook! strict-LIFO stack + reentrancy
;; guard, not a second hook — see that section below for the install/clear/
;; invoke machinery itself. Every var below is def-var!'d only here, so none of
;; them exist outside a sim build; see ordinary-future-no-sim-hook-test.ss and
;; ordinary-ffi-no-sim-hook-test.ss for the base-image counterparts pinning
;; their absence.
;;
;; jolt.internal.sim/capabilities — a stable descriptor a controller can probe
;; before trusting this ABI: :abi-version (int, bumped on any breaking change to
;; this seam), :future-lifecycle / :controller-errors (both true), :events (the
;; exact ordered set of lifecycle event keywords a controller fn observes), and
;; :ffi-interception — a nested, exact descriptor of the FFI controller ABI
;; below (jolt.internal.sim/install-ffi-controller!): :descriptor-version (int,
;; independent of :abi-version so the FFI projection shape can evolve on its
;; own), :kinds (the exact set of projected descriptor :kind values), :arguments
;; :live (arguments reaching a controller are the SAME live jolt objects the
;; call site passed, never copies), :task-identity :future-lifecycle (every
;; descriptor carries the current hooked-future task id, or 0 outside one), and
;; :native-operations (the exact ordered set of native-op names a
;; native-operation descriptor's :operation may be). ABI v4 preserves the
;; descriptor-v3 shapes and established one-argument controller exactly, and
;; adds :proceed-routing plus install-ffi-routing-controller!: a two-argument
;; controller receives [descriptor proceed], where proceed is a zero-argument,
;; single-use, dynamic-extent, owner-thread thunk for the exact native branch.
(define jolt-sim-kw-abi-version        (keyword #f "abi-version"))
(define jolt-sim-kw-future-lifecycle   (keyword #f "future-lifecycle"))
(define jolt-sim-kw-controller-errors  (keyword #f "controller-errors"))
(define jolt-sim-kw-events             (keyword #f "events"))
(define jolt-sim-kw-ffi-interception   (keyword #f "ffi-interception"))
(define jolt-sim-kw-descriptor-version (keyword #f "descriptor-version"))
(define jolt-sim-kw-kinds              (keyword #f "kinds"))
(define jolt-sim-kw-arguments          (keyword #f "arguments"))
(define jolt-sim-kw-live               (keyword #f "live"))
(define jolt-sim-kw-task-identity      (keyword #f "task-identity"))
(define jolt-sim-kw-native-operations  (keyword #f "native-operations"))
(define jolt-sim-kw-proceed-routing    (keyword #f "proceed-routing"))
(define jolt-sim-kw-controller-arity  (keyword #f "controller-arity"))
(define jolt-sim-kw-proceed-arity     (keyword #f "proceed-arity"))
(define jolt-sim-kw-single-use        (keyword #f "single-use"))
(define jolt-sim-kw-dynamic-extent    (keyword #f "dynamic-extent"))
(define jolt-sim-kw-owner-thread      (keyword #f "owner-thread"))
(define jolt-sim-kw-scoped-byte-array-release
  (keyword #f "scoped-byte-array-release"))
(define jolt-sim-kw-runtime-owned     (keyword #f "runtime-owned"))
(define jolt-sim-kw-kind               (keyword #f "kind"))
(define jolt-sim-kw-foreign-function   (keyword #f "foreign-function"))
(define jolt-sim-kw-native-operation   (keyword #f "native-operation"))
(define jolt-sim-kw-symbol             (keyword #f "symbol"))
(define jolt-sim-kw-argument-types     (keyword #f "argument-types"))
(define jolt-sim-kw-return-type        (keyword #f "return-type"))
(define jolt-sim-kw-blocking?          (keyword #f "blocking?"))
(define jolt-sim-kw-capture-native-error?
                                          (keyword #f "capture-native-error?"))
(define jolt-sim-kw-operation          (keyword #f "operation"))
(define (jolt-sim-capabilities)
  (jolt-hash-map
   jolt-sim-kw-abi-version 4
   jolt-sim-kw-future-lifecycle #t
   jolt-sim-kw-controller-errors #t
   jolt-sim-kw-events
   (jolt-vector
    fhk-spawn fhk-start fhk-finish fhk-cancel fhk-exit fhk-abort)
   jolt-sim-kw-ffi-interception
   (jolt-hash-map
    ;; ABI v4 does not change descriptor v3: it keeps v2's exact descriptor
    ;; shapes and native-error flag plus v3's staged scoped byte-array loan
    ;; lifecycle. Proceed is a separate controller calling convention.
    jolt-sim-kw-descriptor-version 3
    jolt-sim-kw-kinds (jolt-vector jolt-sim-kw-foreign-function
                                    jolt-sim-kw-native-operation)
    jolt-sim-kw-arguments jolt-sim-kw-live
    jolt-sim-kw-task-identity jolt-sim-kw-future-lifecycle
    jolt-sim-kw-native-operations
    (jolt-vector (keyword #f "load-library") (keyword #f "loaded?")
                 (keyword #f "alloc") (keyword #f "free")
                 (keyword #f "read") (keyword #f "write")
                 (keyword #f "sizeof") (keyword #f "read-bytes")
                 (keyword #f "write-bytes") (keyword #f "read-array")
                 (keyword #f "write-array")
                 (keyword #f "borrow-byte-array")
                 (keyword #f "release-byte-array")
                 (keyword #f "ptr->string")
                 (keyword #f "string->ptr"))
    jolt-sim-kw-proceed-routing
    (jolt-hash-map
     jolt-sim-kw-controller-arity 2
     jolt-sim-kw-proceed-arity 0
     jolt-sim-kw-single-use #t
     jolt-sim-kw-dynamic-extent #t
     jolt-sim-kw-owner-thread #t
     jolt-sim-kw-scoped-byte-array-release jolt-sim-kw-runtime-owned))))

;; jolt.internal.sim/install-controller! + restore-controller! — a Jolt-callable
;; strict-LIFO stack of jolt-future-hook installations, mirroring the
;; jolt-ffi-sim-hook-installation stack above exactly: install snapshots
;; whatever hook is CURRENTLY active — whether it got there via a prior
;; install-controller! or was set directly through the low-level
;; jolt-future-hook-set! (e.g. by a test harness or another Scheme-level
;; caller) — and restore puts back exactly that snapshot. Only the current top
;; of the stack may restore; an out-of-order or repeated restore is rejected
;; BEFORE it touches the active hook (fail closed), so a nested simulation can
;; never be silently disabled by a stale or reused token.
(define-record-type jolt-sim-controller-installation
  (fields hook previous)
  (nongenerative jolt-sim-controller-installation-v1))
(define jolt-sim-controller-top #f)
(define jolt-sim-controller-mu (make-mutex))
(define (jolt-sim-install-controller! f)
  (unless f
    (error 'jolt-sim-install-controller! "controller must be non-false"))
  (with-mutex jolt-sim-controller-mu
    (let* ((prior (unbox jolt-future-hook))
           (installation (make-jolt-sim-controller-installation prior jolt-sim-controller-top)))
      (set! jolt-sim-controller-top installation)
      (set-box! jolt-future-hook f)
      installation)))
(define (jolt-sim-restore-controller! installation)
  (with-mutex jolt-sim-controller-mu
    (unless (eq? installation jolt-sim-controller-top)
      (error 'jolt-sim-restore-controller!
             "simulation controllers must be restored by their current owner"))
    (set-box! jolt-future-hook (jolt-sim-controller-installation-hook installation))
    (set! jolt-sim-controller-top (jolt-sim-controller-installation-previous installation)))
  jolt-nil)

;; jolt.internal.sim/controller-errors + clear-controller-errors! — project the
;; future hook's supervisor-error latch (jolt-future-hook-errors, above) into a
;; Jolt collection of plain maps a controller can inspect from ordinary Jolt
;; source, and clear it. :error is the ORIGINAL condition/value the failing
;; hook raised, unwrapped — this is supervisor evidence, not a rethrow.
(define jolt-sim-kw-event  (keyword #f "event"))
(define jolt-sim-kw-task   (keyword #f "task"))
(define jolt-sim-kw-parent (keyword #f "parent"))
(define jolt-sim-kw-error  (keyword #f "error"))
(define (jolt-sim-controller-errors)
  (apply jolt-vector
         (map (lambda (entry)
                (jolt-hash-map
                 jolt-sim-kw-event  (list-ref entry 0)
                 jolt-sim-kw-task   (list-ref entry 1)
                 jolt-sim-kw-parent (list-ref entry 2)
                 jolt-sim-kw-error  (list-ref entry 3)))
              (jolt-future-hook-errors-snapshot))))

;; jolt.internal.sim/install-ffi-controller! +
;; install-ffi-routing-controller! + restore-ffi-controller! — expose
;; the FFI call-interception seam above (jolt-ffi-install-sim-hook!/
;; jolt-ffi-clear-sim-hook!, "=== FFI call interception (simulation seam) ===")
;; to a Jolt-callable controller. This is a thin projection over that EXACT
;; existing strict-LIFO stack + reentrancy guard: install wraps the supplied
;; Jolt IFn in a Scheme lambda that projects the raw alist descriptor
;; (jolt-ffi-make-sim-descriptor / jolt-ffi-make-native-sim-descriptor) into one
;; stable, immutable Jolt map BEFORE invoking it, then installs that wrapper via
;; jolt-ffi-install-sim-hook! and returns the EXACT installation record it
;; produces — the same opaque token type the low-level Scheme API uses, not a
;; new one — so nesting, ordering, and restore-by-owner behave identically to a
;; caller using the low-level hook stack directly. The established installer
;; invokes f with the exact descriptor-v3 map. The routing installer invokes f
;; with [descriptor proceed]; restore accepts either installation token and
;; passes it straight to jolt-ffi-clear-sim-hook!, unchanged.
;;
;; A projected descriptor's :kind selects its exact key set:
;;   {:kind :foreign-function :task :symbol :argument-types :return-type
;;    :blocking? :capture-native-error? :arguments}
;;                    — one jolt.ffi/defcfn call (jolt-ffi-make-sim-descriptor)
;;   {:kind :native-operation :task :operation :arguments}
;;                      — one raw native op (jolt-ffi-make-native-sim-descriptor)
;; :task is jolt-future-current-task-id at interception time: the positive,
;; stable future-lifecycle id while inside a hooked future, or 0 on the
;; primordial/unregistered thread. This correlates effect observations with the
;; lifecycle controller without adding a second task registry.
;; :symbol/:argument-types/:return-type are copied metadata (already snapshotted
;; per call by the makers above); :capture-native-error? is part of handler
;; identity so otherwise-identical scalar and captured bindings cannot collide;
;; :arguments is the SAME live jolt call arguments in call order, not copies —
;; a controller must be able to emulate writes through a live byte array or
;; pointer. An internal descriptor that matches neither exact shape is rejected
;; outright rather than guessed at.
(define jolt-ffi-sim-cfn-desc-keys
  '(csym argtypes rettype blocking capture-native-error args))
(define jolt-ffi-sim-native-desc-keys '(kind op args))
(define jolt-sim-ffi-native-operation-names
  '("load-library" "loaded?" "alloc" "free" "read" "write" "sizeof"
    "read-bytes" "write-bytes" "read-array" "write-array"
    "borrow-byte-array" "release-byte-array" "ptr->string" "string->ptr"))
(define (jolt-sim-ffi-descriptor-keys desc)
  (and (list? desc) (for-all pair? desc) (map car desc)))
(define (jolt-sim-ffi-project-descriptor desc)
  (let ((ks (jolt-sim-ffi-descriptor-keys desc)))
    (cond
      ((and (equal? ks jolt-ffi-sim-cfn-desc-keys)
            (string? (cdr (assq 'csym desc)))
            (list? (cdr (assq 'argtypes desc)))
            (for-all string? (cdr (assq 'argtypes desc)))
            (string? (cdr (assq 'rettype desc)))
            (boolean? (cdr (assq 'blocking desc)))
            (boolean? (cdr (assq 'capture-native-error desc)))
            (list? (cdr (assq 'args desc)))
            (= (length (cdr (assq 'argtypes desc)))
               (length (cdr (assq 'args desc)))))
       (jolt-hash-map
        jolt-sim-kw-kind jolt-sim-kw-foreign-function
        jolt-sim-kw-task (jolt-future-current-task-id)
        jolt-sim-kw-symbol (cdr (assq 'csym desc))
        jolt-sim-kw-argument-types
        (apply jolt-vector (map (lambda (t) (keyword #f t)) (cdr (assq 'argtypes desc))))
        jolt-sim-kw-return-type (keyword #f (cdr (assq 'rettype desc)))
        jolt-sim-kw-blocking? (cdr (assq 'blocking desc))
        jolt-sim-kw-capture-native-error?
        (cdr (assq 'capture-native-error desc))
        jolt-sim-kw-arguments (apply jolt-vector (cdr (assq 'args desc)))))
      ((and (equal? ks jolt-ffi-sim-native-desc-keys)
            (eq? (cdr (assq 'kind desc)) 'native-op)
            (string? (cdr (assq 'op desc)))
            (member (cdr (assq 'op desc))
                    jolt-sim-ffi-native-operation-names)
            (list? (cdr (assq 'args desc))))
       (jolt-hash-map
        jolt-sim-kw-kind jolt-sim-kw-native-operation
        jolt-sim-kw-task (jolt-future-current-task-id)
        jolt-sim-kw-operation (keyword #f (cdr (assq 'op desc)))
        jolt-sim-kw-arguments (apply jolt-vector (cdr (assq 'args desc)))))
      (else
       (error 'jolt-sim-ffi-project-descriptor
              "malformed or ambiguous FFI simulation descriptor" desc)))))
(define (jolt-sim-make-ffi-controller-wrapper f)
  (lambda (desc) (jolt-invoke f (jolt-sim-ffi-project-descriptor desc))))
(define (jolt-sim-make-ffi-routing-controller-wrapper f)
  (lambda (desc proceed)
    (jolt-invoke2 f (jolt-sim-ffi-project-descriptor desc) proceed)))
(define (jolt-sim-install-ffi-controller! f)
  (unless f
    (error 'jolt-sim-install-ffi-controller! "controller must be non-false"))
  (jolt-ffi-install-sim-hook! (jolt-sim-make-ffi-controller-wrapper f)))
(define (jolt-sim-install-ffi-routing-controller! f)
  (unless f
    (error 'jolt-sim-install-ffi-routing-controller!
           "controller must be non-false"))
  (jolt-ffi-install-routing-hook!
   (jolt-sim-make-ffi-routing-controller-wrapper f)))
(define (jolt-sim-restore-ffi-controller! installation)
  (jolt-ffi-clear-sim-hook! installation))

(def-var! "jolt.internal.sim" "capabilities" jolt-sim-capabilities)
(def-var! "jolt.internal.sim" "install-controller!" jolt-sim-install-controller!)
(def-var! "jolt.internal.sim" "restore-controller!" jolt-sim-restore-controller!)
(def-var! "jolt.internal.sim" "controller-errors" jolt-sim-controller-errors)
(def-var! "jolt.internal.sim" "clear-controller-errors!" jolt-future-hook-errors-clear!)
(def-var! "jolt.internal.sim" "install-ffi-controller!" jolt-sim-install-ffi-controller!)
(def-var! "jolt.internal.sim" "install-ffi-routing-controller!"
          jolt-sim-install-ffi-routing-controller!)
(def-var! "jolt.internal.sim" "restore-ffi-controller!" jolt-sim-restore-ffi-controller!)
