;; host/chez/sim/runtime.ss — private simulation-only runtime overlay.
;;
;; Loaded only by the `sim` Jolt image and by applications that image builds.
;; Ordinary release/debug images remain free of simulation state and branches.
;; This slice is source-loaded: the build-system wiring that will propagate the
;; overlay into a sim image flavor is deliberately NOT part of it, and the
;; checked-in seed is unchanged. Load after host/chez/java/ffi.ss (the overlay
;; installs its bridge through that file's declared-call seam).
;;
;; This is the complete prerelease controller overlay: composite ABI 6 with FFI
;; descriptor version 8 (unreleased; no compatibility with any earlier FFI
;; descriptor shape). It owns
;; future-lifecycle, monotonic-clock, typed foreign-call, and raw
;; native-operation interception, unified behind ONE atomic install/restore
;; pair — there is no independent per-subcontroller install or restore
;; operation in the public ABI.
;;
;; Unlike the historical overlay, this slice adds NO raw FFI wrappers and NO
;; parallel hook stack. The canonical seam (host/chez/java/ffi.ss) already
;; intercepts every declared foreign call and every raw jolt.ffi native
;; operation with an owner-thread, at-most-once, dynamic-extent proceed. At
;; load this overlay installs exactly ONE persistent bridge through
;; jolt-ffi-install-declared-call-hook!. The bridge snapshots the single
;; composite controller pointer and either routes the projected descriptor to
;; that installation's :ffi controller with the canonical proceed untouched,
;; or — with no controller installed — invokes that exact proceed itself.
;; Install/restore therefore changes only the one composite pointer, and the
;; overlay never duplicates a native operation body.

(define jolt-sim-runtime-image? #t)

;; === composite controller state ==============================================
;; The sole public controller-state pointer. A successful complete install or
;; restore publishes exactly one immutable composite through this binding.
;; `domain` is the clock-linearization domain shared by every nested
;; installation (see the clock section); `previous` is the strict-LIFO link.
(define-record-type jolt-sim-controller-installation
  (fields future ffi clock domain previous)
  (nongenerative jolt-sim-controller-installation-v6))
(define jolt-sim-controller-top #f)

;; === installation-affine routing =============================================
;; One owner-tagged task context carries the owning thread id, the captured
;; composite installation, and the current task id. A controlled future
;; CAPTURES the effective composite installation at spawn and its worker runs
;; its whole extent under a context with that capture, so the task's nested
;; futures, FFI bridge calls, and controlled clock calls keep routing to the
;; captured composite even when another token is installed globally afterwards.
;; Chez thread parameters are inherited, so the context is owner-tagged: an
;; inherited context whose owner is not the current thread reads as NO context
;; — no captured installation (routing falls back to the global pointer) and
;; task id 0. A RAW fork-thread made by a controlled task is therefore not
;; installation-affine and reports task/parent 0: while an inner installation
;; is globally current it routes to inner, by design. Covering such
;; pre-existing uncontrolled/raw work is a QUIESCENCE PRECONDITION on
;; install+restore that the external adapter owns — see
;; jolt-sim-restore-controller!.
(define-record-type jolt-sim-task-context
  (fields owner-id installation task-id)
  (nongenerative jolt-sim-task-context-v1))
(define jolt-sim-task-context-cell (make-thread-parameter #f))
;; The current thread's OWN context, or #f: an inherited context owned by a
;; different thread collapses to nothing (no captured installation, task id 0).
(define (jolt-sim-current-task-context)
  (let ((cell (jolt-sim-task-context-cell)) (id (get-thread-id)))
    (and (jolt-sim-task-context? cell)
         (eqv? id (jolt-sim-task-context-owner-id cell))
         cell)))
(define (jolt-sim-effective-installation)
  (let ((ctx (jolt-sim-current-task-context)))
    (if ctx
        (jolt-sim-task-context-installation ctx)
        jolt-sim-controller-top)))
;; Run one lifecycle callback under the event's captured installation routing
;; context on this thread: the hook's own FFI bridge calls, controlled clock
;; calls, and nested futures route to THAT installation (not whatever is
;; globally current mid-callback), stamped with the given routing task id.
(define (jolt-sim-call-lifecycle-hook invoke hook installation routing-task event id parent)
  (parameterize ((jolt-sim-task-context-cell
                  (make-jolt-sim-task-context
                   (get-thread-id) installation routing-task)))
    (invoke hook event id parent)))

;; === future lifecycle hook ===================================================
;; A disabled-by-default observability + gating seam over the centralized
;; fork-thread future path (host/chez/java/concurrency.ss's jolt-future-call).
;; When the composite controller is installed, each ordinary future-call fires
;; lifecycle events to its :future controller (called with jolt values):
;;   (:spawn  id parent)  on the SPAWNING thread, before the worker forks
;;   (:start  id parent)  on the WORKER thread, BEFORE the body runs — the hook
;;                        MAY BLOCK here (e.g. park on a promise) so a single
;;                        controller chooses which ordinary future begins
;;   (:finish id parent)  on the WORKER thread, AFTER its guarded attempt ends
;;                        (body result or pre-body setup/start failure), BEFORE
;;                        the result is published
;;   (:cancel id parent)  on the CANCELLING thread, BEFORE cancellation is
;;                        published; exactly one of :finish/:cancel wins
;;   (:exit   id parent)  on the WORKER thread, AFTER the winning result or
;;                        cancellation is published; every forked worker
;;                        attempts exactly one exit callback, even when start
;;                        or the body failed or cancellation won
;;   (:abort  id parent)  on the SPAWNING thread if :spawn registration or the
;;                        subsequent fork fails; no worker exists for that task
;; `id` is a stable, unique, positive int (1, 2, 3, …; never recycled) assigned
;; per future-call; `parent` is the task id in effect on the spawning thread (0
;; for the primordial thread / any thread that is not itself a hooked future).
;; A :spawn hook failure propagates synchronously before any worker is forked.
;; A :start hook failure is captured as that future's failure, so deref cannot
;; hang and the body is not run. Terminal-hook failures never replace the
;; application result/cancellation; they are retained in a structured
;; supervisor-error latch. Dynamic bindings, cancellation, and
;; ExecutionException propagation are otherwise identical to the fast path.
;; This is a TEST/simulation hook, not an application task DSL — it is
;; deliberately kept off the clojure.core/jolt.host surface (install/restore
;; only through the composite controller below).
(define-record-type jolt-hooked-future
  (parent jolt-future)
  (fields hook installation task-id parent-id (mutable settling?))
  (nongenerative jolt-hooked-future-v2))

(define jolt-future-id-mu (make-mutex))      ; guards the monotonic id counter
(define jolt-future-next-id (box 1))
(define fhk-spawn  (keyword #f "spawn"))
(define fhk-start  (keyword #f "start"))
(define fhk-finish (keyword #f "finish"))
(define fhk-cancel (keyword #f "cancel"))
(define fhk-exit   (keyword #f "exit"))
(define fhk-abort  (keyword #f "abort"))
(define jolt-future-hook-error-mu (make-mutex))
(define jolt-future-hook-errors '())

;; This thread's task id from its OWN task context (0 without one — including
;; on a raw fork that merely inherited an outer task's context). A future
;; whose body spawns another future reports this id as the child's parent; the
;; same id is stamped into every projected FFI descriptor as :task.
(define (jolt-future-current-task-id)
  (let ((ctx (jolt-sim-current-task-context)))
    (if ctx (jolt-sim-task-context-task-id ctx) 0)))
(define (jolt-future-alloc-id!)
  (with-mutex jolt-future-id-mu
    (let ((n (unbox jolt-future-next-id)))
      (set-box! jolt-future-next-id (+ n 1))
      n)))
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

;; The effective future controller is exactly the effective composite's
;; :future fn; there is no secondary legacy hook cell in this ABI.
(define (jolt-sim-current-future-controller)
  (let ((installation (jolt-sim-effective-installation)))
    (and installation
         (jolt-sim-controller-installation-future installation))))

;; Hook-aware future-call: with NO controller installed this defers to the base
;; jolt-future-call unchanged (no id, no wrapped record, no extra locking).
;; When a controller is installed it observes :spawn/:start, one of
;; :finish/:cancel, and the worker's final :exit acknowledgement. It may block
;; at :start so a controller can order ordinary futures — see the seam above.
;; The effective installation (itself possibly captured by an outer controlled
;; task) is captured with the future at spawn, and the worker's whole extent
;; runs under a task context with it and the child id, so this task's nested
;; futures, FFI bridge calls, and controlled clock calls remain affine to it —
;; an outer task keeps reporting to the outer controller while an inner token
;; is current globally. :spawn/:abort run on the spawning thread under the
;; same captured installation, retaining the caller's own task id exactly when
;; that caller context belongs to the captured installation (an uncontrolled
;; or raw-fork caller has none, so its routing task id and the child's parent
;; are both 0).
(define (jolt-sim-future-call thunk)
  (let ((installation (jolt-sim-effective-installation)))
    (if (not installation)
        (jolt-future-call thunk)
        (let* ((hook (jolt-sim-controller-installation-future installation))
               (snap (dyn-binding-stack))
               (parent (jolt-future-current-task-id))
               (id (jolt-future-alloc-id!))
               (f (make-jolt-hooked-future
                   #f #f #f jolt-nil (make-mutex) (make-condition)
                   hook installation id parent #f)))
          ;; :spawn fires synchronously on this thread before the worker forks,
          ;; so any gate the hook arms for `id` is in place before :start runs.
          ;; Fail closed before the fork: a controller that cannot register
          ;; this task must not let the ordinary future escape uncontrolled. If
          ;; registration or fork-thread itself fails, :abort balances the
          ;; announced id so an external controller need not guess whether a
          ;; worker still exists.
          (guard (e (#t
                     (jolt-sim-call-lifecycle-hook
                      jolt-future-hook-terminal-invoke
                      hook installation parent fhk-abort id parent)
                     (raise e)))
            (jolt-sim-call-lifecycle-hook
             jolt-future-hook-invoke hook installation parent fhk-spawn id parent)
            (fork-thread
             (lambda ()
               ;; This worker's extent runs under a task context owned by this
               ;; thread, so the affinity never leaks to threads it forks
               ;; outside the future seam.
               (parameterize ((jolt-sim-task-context-cell
                               (make-jolt-sim-task-context
                                (get-thread-id) installation id)))
               ;; Capture worker setup and a start-hook failure in the same
               ;; result channel as a body failure. The body is skipped and
               ;; deref observes ordinary ExecutionException semantics instead
               ;; of hanging, while the worker still reaches :exit.
               (let ((r (guard (e (#t (cons #f e)))
                          (*txn* #f)
                          (dyn-binding-stack snap)
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
                 ;; running, wait until its :cancel hook and publication
                 ;; finish. :exit is supervisor-style: its failure is latched
                 ;; and cannot replace the already-published result or
                 ;; cancellation.
                 (jolt-hooked-future-await-published! f)
                 (jolt-future-hook-terminal-invoke
                  hook fhk-exit id parent))))))
          f))))

;; Hook-aware future-cancel: a hooked future's cancellation is a terminal
;; event, published only after the controller's :cancel observer runs; any
;; other future (no controller was installed when it was spawned) defers to the
;; base jolt-future-cancel. The observer runs under the TARGET future's
;; captured installation (an outer future's cancellation stays outer even when
;; an inner token is globally current), retaining the cancelling thread's own
;; task id only when its context belongs to that same installation — otherwise
;; the routing task id is 0.
(define (jolt-sim-future-cancel f)
  (if (jolt-hooked-future? f)
      (if (jolt-hooked-future-claim-terminal! f)
          (let* ((installation (jolt-hooked-future-installation f))
                 (ctx (jolt-sim-current-task-context))
                 (routing-task
                  (if (and ctx
                           (eq? (jolt-sim-task-context-installation ctx)
                                installation))
                      (jolt-sim-task-context-task-id ctx)
                      0)))
            (jolt-sim-call-lifecycle-hook
             jolt-future-hook-terminal-invoke
             (jolt-hooked-future-hook f)
             installation routing-task fhk-cancel
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

;; Rebind only in this overlay. With no installed controller each entry defers
;; to the branch-free ordinary base primitive unchanged.
(def-var! "clojure.core" "future-call" jolt-sim-future-call)
(def-var! "clojure.core" "future-cancel" jolt-sim-future-cancel)

;; === exact descriptor-v8 projection ==========================================
;; The canonical seam hands the bridge one of two raw host alists per
;; intercepted call:
;;   foreign:  ((kind . foreign-call) (csym . string) (argtypes . (string …))
;;              (rettype . string) (blocking . bool)
;;              (capture-native-error . bool) (varargs-after . #f|positive-int)
;;              (args . (…)))
;;   native:   ((kind . native-op) (op . string) (args . (…)))
;; Every public :ffi controller sees the EXACT jolt-sim map projection below,
;; and only that: key order, kind, operation membership, fixed argument count
;; against argtypes, and per-operation arity are all validated first, so a
;; malformed descriptor fails before the controller or any proceed can run.
;; The raw compiler/host metadata stays behind; the exact optional variadic
;; boundary is retained in descriptor 8 for handler matching and trace fidelity.
;; Arguments remain the exact live Jolt values: a substitute may need to model
;; writes through an array or pointer.
(define jolt-sim-native-operation-names
  ;; The current 15-operation set: exactly the intercepted raw operations of
  ;; host/chez/java/ffi.ss, including null? and excluding borrow/release —
  ;; with-byte-array-pointer's scoped loan lifecycle is runtime-owned, so no
  ;; loan descriptor ever reaches a controller (its enclosed FFI is
  ;; intercepted normally by the canonical seam). The scoped byte-array view
  ;; vars at the bottom of this file are likewise NOT operations here: they
  ;; copy between a controller and the runtime-owned locked temporary behind
  ;; an active loan directly and carry no descriptor at all.
  '("load-library" "loaded?" "alloc" "free" "read" "write" "sizeof" "null?"
    "read-bytes" "write-bytes" "read-array" "read-array!" "write-array"
    "ptr->string" "string->ptr"))
(define jolt-sim-kw-kind (keyword #f "kind"))
(define jolt-sim-kw-task (keyword #f "task"))
(define jolt-sim-kw-foreign-function (keyword #f "foreign-function"))
(define jolt-sim-kw-native-operation (keyword #f "native-operation"))
(define jolt-sim-kw-symbol (keyword #f "symbol"))
(define jolt-sim-kw-argument-types (keyword #f "argument-types"))
(define jolt-sim-kw-return-type (keyword #f "return-type"))
(define jolt-sim-kw-blocking? (keyword #f "blocking?"))
(define jolt-sim-kw-capture-native-error? (keyword #f "capture-native-error?"))
(define jolt-sim-kw-varargs-after (keyword #f "varargs-after"))
(define jolt-sim-kw-operation (keyword #f "operation"))
(define jolt-sim-kw-arguments (keyword #f "arguments"))
(define (jolt-sim-raw-keys d) (and (list? d) (for-all pair? d) (map car d)))
(define (jolt-sim-native-arity-valid? op args)
  (let ((n (length args)))
    (cond
      ((member op '("load-library")) (or (= n 0) (= n 1)))
      ((member op '("loaded?" "alloc" "free" "sizeof" "null?" "ptr->string"
                    "string->ptr")) (= n 1))
      ((member op '("read-bytes" "write-bytes" "read-array")) (= n 2))
      ((string=? op "read") (or (= n 2) (= n 3)))
      ((string=? op "write") (= n 4))
      ((string=? op "write-array") (or (= n 2) (= n 4)))
      ((string=? op "read-array!") (= n 4))
      (else #f))))
(define (jolt-sim-project-ffi-descriptor desc)
  (let ((ks (jolt-sim-raw-keys desc)))
    (cond
      ((and (equal? ks '(kind csym argtypes rettype blocking
                              capture-native-error varargs-after args))
            (eq? (cdr (assq 'kind desc)) 'foreign-call)
            (string? (cdr (assq 'csym desc)))
            (list? (cdr (assq 'argtypes desc)))
            (for-all string? (cdr (assq 'argtypes desc)))
            (string? (cdr (assq 'rettype desc)))
            (boolean? (cdr (assq 'blocking desc)))
            (boolean? (cdr (assq 'capture-native-error desc)))
            (let ((varargs-after (cdr (assq 'varargs-after desc))))
              (or (not varargs-after)
                  (and (number? varargs-after) (exact? varargs-after)
                       (integer? varargs-after) (> varargs-after 0)
                       (<= varargs-after
                           (length (cdr (assq 'argtypes desc)))))))
            (list? (cdr (assq 'args desc)))
            (= (length (cdr (assq 'argtypes desc)))
               (length (cdr (assq 'args desc)))))
       (jolt-hash-map
        jolt-sim-kw-kind jolt-sim-kw-foreign-function
        jolt-sim-kw-task (jolt-future-current-task-id)
        jolt-sim-kw-symbol (cdr (assq 'csym desc))
        jolt-sim-kw-argument-types
        (apply jolt-vector (map (lambda (s) (keyword #f s))
                                (cdr (assq 'argtypes desc))))
        jolt-sim-kw-return-type (keyword #f (cdr (assq 'rettype desc)))
        jolt-sim-kw-blocking? (cdr (assq 'blocking desc))
        jolt-sim-kw-capture-native-error? (cdr (assq 'capture-native-error desc))
        jolt-sim-kw-varargs-after
        (let ((varargs-after (cdr (assq 'varargs-after desc))))
          (if varargs-after (->num varargs-after) jolt-nil))
        jolt-sim-kw-arguments (apply jolt-vector (cdr (assq 'args desc)))))
      ((and (equal? ks '(kind op args))
            (eq? (cdr (assq 'kind desc)) 'native-op)
            (string? (cdr (assq 'op desc)))
            (member (cdr (assq 'op desc)) jolt-sim-native-operation-names)
            (list? (cdr (assq 'args desc)))
            (jolt-sim-native-arity-valid? (cdr (assq 'op desc))
                                          (cdr (assq 'args desc))))
       (jolt-hash-map
        jolt-sim-kw-kind jolt-sim-kw-native-operation
        jolt-sim-kw-task (jolt-future-current-task-id)
        jolt-sim-kw-operation (keyword #f (cdr (assq 'op desc)))
        jolt-sim-kw-arguments (apply jolt-vector (cdr (assq 'args desc)))))
      (else
       (error 'jolt-sim-project-ffi-descriptor
              "malformed or unknown FFI controller operation" desc)))))

;; === the one persistent FFI bridge ===========================================
;; Installed exactly once, at overlay load, through the canonical
;; jolt-ffi-install-declared-call-hook! seam, and never cleared: the bridge is
;; the simulation image's permanent disposition of that seam, not a per-
;; controller installation. Every intercepted call snapshots the EFFECTIVE
;; composite ONCE (the calling task's captured installation, else the global
;; pointer). A installed composite routes the projected descriptor to its :ffi
;; controller with the canonical proceed passed through untouched — one-shot,
;; owner-thread, dynamic-extent, and nested-activation enforcement all remain
;; the canonical hook's own (a controller-phase nested FFI call fails against
;; its activation; a synchronous native callback reached through proceed
;; starts a fresh interception). With NO effective composite installed the
;; bridge invokes that exact proceed itself, so intercepted operations run
;; their untouched original bodies through the persistent simulation bridge.
;;
;; Host-internal code may still install through the canonical seam ABOVE this
;; bridge. That is a TEMPORARY SUSPENSION/OVERRIDE of bridge routing under the
;; canonical token-cleared stack discipline — never public controller
;; behavior: public controllers are installed and restored ONLY through the
;; composite install/restore below, which never touches the canonical stack.
;; Clearing the override restores the bridge (and with it the active
;; composite's routing) as the effective hook.
(define (jolt-sim-ffi-bridge descriptor proceed)
  (let ((installation (jolt-sim-effective-installation)))
    (if installation
        (jolt-invoke2 (jolt-sim-controller-installation-ffi installation)
                      (jolt-sim-project-ffi-descriptor descriptor)
                      proceed)
        (proceed))))
(define jolt-sim-ffi-bridge-installation
  (jolt-ffi-install-declared-call-hook! jolt-sim-ffi-bridge))

;; === monotonic clock interception ============================================
;; Save the central native source, then replace that one top-level procedure.
;; System/nanoTime (host-static-methods.ss) calls jolt-mono-nanos BY NAME at
;; invocation time, so redirecting the Scheme binding redirects it too. The
;; public jolt.host/mono-nanos var (rt.ss) was captured BY VALUE at def-var!
;; time, before this overlay ever loads, so it does NOT observe a plain `set!`
;; of jolt-mono-nanos — it must be re-registered explicitly below. The
;; supervisor primitive captured here calls the ORIGINAL saved procedure
;; directly — it is never routed through any controller — and can therefore
;; drive jolt-sim's drain watchdog even while modeled time is frozen or under
;; active control.
(define jolt-sim-supervisor-mono-nanos-source jolt-mono-nanos)
;; One linearization domain per outermost composite scope: the mutex that makes
;; sample+validate+publish atomic and the last published value. Nested
;; installations SHARE the outermost scope's domain (see install), so an inner
;; controller cannot advance the clock and then reveal an older outer value
;; after restoration; a fresh outer scope may start virtual time at any origin.
(define-record-type jolt-sim-clock-domain
  (fields mu (mutable last))
  (nongenerative jolt-sim-clock-domain-v1))
(define jolt-sim-clock-active-owner (make-thread-parameter #f))
;; Private test rendezvous, disabled by default. When non-false, invoked with
;; no arguments immediately BEFORE domain-lock acquisition in every controlled
;; clock call. Nothing in production sets it; the focused gate uses it to prove
;; acquisition ordering deterministically, without timing assumptions.
(define jolt-sim-clock-acquire-test-hook #f)
(define jolt-sim-kw-clock (keyword #f "clock"))
(define jolt-sim-kw-mono-nanos (keyword #f "mono-nanos"))
(define jolt-sim-clock-descriptor
  (jolt-hash-map jolt-sim-kw-kind jolt-sim-kw-clock
                 jolt-sim-kw-operation jolt-sim-kw-mono-nanos))
;; Validates a raw sample against the domain's last-published value and (when
;; accepted) publishes it as the new last. MUST run with the domain mutex
;; already held by the caller — see jolt-sim-mono-nanos below for why the
;; acquire has to enclose the sample itself, not just this check.
(define (jolt-sim-clock-validate-locked! domain n)
  (unless (and (integer? n) (exact? n))
    (error 'jolt-sim-clock "monotonic clock must return exact integer nanoseconds"))
  (let ((last (jolt-sim-clock-domain-last domain)))
    (when (and last (< n last))
      (error 'jolt-sim-clock "monotonic clock moved backward"))
    (jolt-sim-clock-domain-last-set! domain n))
  n)
;; The clock's proceed is the unhooked supervisor source itself, offered under
;; the same one-shot / owner-thread / dynamic-extent discipline the canonical
;; FFI hook enforces for its proceed. This is deliberately small and local —
;; it is not a second general proceed stack, and the FFI path adds no proceed
;; machinery of its own at all.
(define (jolt-sim-call-clock-controller controller)
  (let* ((owner (get-thread-id)) (live? #t) (used? #f))
    (define (proceed)
      (unless live?
        (error 'jolt-sim-clock-proceed "clock proceed is outside its dynamic extent"))
      (unless (eqv? owner (get-thread-id))
        (error 'jolt-sim-clock-proceed "clock proceed must run on its owner thread"))
      (when used?
        (error 'jolt-sim-clock-proceed "clock proceed may be invoked only once"))
      (set! used? #t)
      (jolt-sim-supervisor-mono-nanos-source))
    (dynamic-wind
      (lambda ()
        (unless live?
          (error 'jolt-sim-clock-proceed "clock controller cannot be re-entered")))
      (lambda () (jolt-invoke2 controller jolt-sim-clock-descriptor proceed))
      (lambda () (set! live? #f)))))
(define (jolt-sim-mono-nanos)
  (let ((installation (jolt-sim-effective-installation)))
    (if (not installation)
        (jolt-sim-supervisor-mono-nanos-source)
        (let ((owner (get-thread-id)))
          (when (eqv? owner (jolt-sim-clock-active-owner))
            (error 'jolt-sim-clock "reentrant controlled clock access is not supported"))
          (parameterize ((jolt-sim-clock-active-owner owner))
            ;; Sampling used to precede this mutex. Two threads could sample a
            ;; real monotonic source as n1<n2, then validate in reverse order
            ;; and falsely reject n1 as backward. Obtain, validate, and publish
            ;; now share one domain-wide linearization point. The owner check
            ;; above remains outside the mutex so same-thread reentry fails
            ;; instead of deadlocking.
            (let ((domain (jolt-sim-controller-installation-domain installation)))
              (let ((rendezvous jolt-sim-clock-acquire-test-hook))
                (when rendezvous (rendezvous)))
              (with-mutex (jolt-sim-clock-domain-mu domain)
                (jolt-sim-clock-validate-locked!
                 domain
                 (jolt-sim-call-clock-controller
                  (jolt-sim-controller-installation-clock installation))))))))))
;; Redirect both call paths: System/nanoTime resolves jolt-mono-nanos by name
;; at call time (the `set!` alone covers it); jolt.host/mono-nanos was already
;; published by value and needs an explicit re-registration to the same
;; interceptable procedure.
(set! jolt-mono-nanos jolt-sim-mono-nanos)
(def-var! "jolt.host" "mono-nanos" jolt-sim-mono-nanos)
(define (jolt-sim-supervisor-mono-nanos)
  (->num (jolt-sim-supervisor-mono-nanos-source)))

;; === public prerelease controller ABI (composite 6, FFI descriptor 8) ========
(define jolt-sim-kw-abi-version (keyword #f "abi-version"))
(define jolt-sim-kw-future-lifecycle (keyword #f "future-lifecycle"))
(define jolt-sim-kw-controller-errors (keyword #f "controller-errors"))
(define jolt-sim-kw-events (keyword #f "events"))
(define jolt-sim-kw-ffi-interception (keyword #f "ffi-interception"))
(define jolt-sim-kw-clock-interception (keyword #f "clock-interception"))
(define jolt-sim-kw-descriptor-version (keyword #f "descriptor-version"))
(define jolt-sim-kw-kinds (keyword #f "kinds"))
(define jolt-sim-kw-live (keyword #f "live"))
(define jolt-sim-kw-task-identity (keyword #f "task-identity"))
(define jolt-sim-kw-native-operations (keyword #f "native-operations"))
(define jolt-sim-kw-proceed-routing (keyword #f "proceed-routing"))
(define jolt-sim-kw-controller-arity (keyword #f "controller-arity"))
(define jolt-sim-kw-proceed-arity (keyword #f "proceed-arity"))
(define jolt-sim-kw-single-use (keyword #f "single-use"))
(define jolt-sim-kw-dynamic-extent (keyword #f "dynamic-extent"))
(define jolt-sim-kw-owner-thread (keyword #f "owner-thread"))
(define jolt-sim-kw-lifo (keyword #f "lifo"))
(define jolt-sim-kw-scoped-byte-array-release (keyword #f "scoped-byte-array-release"))
(define jolt-sim-kw-scoped-byte-array-view (keyword #f "scoped-byte-array-view"))
(define jolt-sim-kw-read-active-byte-array-view
  (keyword #f "read-active-byte-array-view"))
(define jolt-sim-kw-write-active-byte-array-view!
  (keyword #f "write-active-byte-array-view!"))
(define jolt-sim-kw-read-arity (keyword #f "read-arity"))
(define jolt-sim-kw-write-arity (keyword #f "write-arity"))
(define jolt-sim-kw-runtime-owned (keyword #f "runtime-owned"))
(define jolt-sim-kw-operations (keyword #f "operations"))
(define jolt-sim-kw-result (keyword #f "result"))
(define jolt-sim-kw-exact-integer-nanoseconds (keyword #f "exact-integer-nanoseconds"))
(define jolt-sim-kw-nondecreasing? (keyword #f "nondecreasing?"))
(define jolt-sim-kw-supervisor-operation (keyword #f "supervisor-operation"))
(define jolt-sim-kw-supervisor-mono-nanos (keyword #f "supervisor-mono-nanos"))
(define jolt-sim-kw-installation (keyword #f "installation"))
(define jolt-sim-kw-configuration-keys (keyword #f "configuration-keys"))
(define jolt-sim-kw-future (keyword #f "future"))
(define jolt-sim-kw-ffi (keyword #f "ffi"))
(define jolt-sim-kw-clock-controller (keyword #f "clock"))
(define jolt-sim-kw-install-arity (keyword #f "install-arity"))
(define jolt-sim-kw-restore-arity (keyword #f "restore-arity"))
(define jolt-sim-kw-atomic? (keyword #f "atomic?"))
(define jolt-sim-kw-strict-lifo? (keyword #f "strict-lifo?"))
(define jolt-sim-kw-future-controller-arity (keyword #f "future-controller-arity"))
(define jolt-sim-kw-ffi-controller-arity (keyword #f "ffi-controller-arity"))
(define jolt-sim-kw-clock-controller-arity (keyword #f "clock-controller-arity"))
;; The canonical declared-call hook owns every one of these properties for the
;; FFI path; the clock's local proceed above enforces the same contract.
(define jolt-sim-proceed-capabilities
  (jolt-hash-map jolt-sim-kw-controller-arity 2
                 jolt-sim-kw-proceed-arity 0
                 jolt-sim-kw-single-use #t
                 jolt-sim-kw-dynamic-extent #t
                 jolt-sim-kw-owner-thread #t
                 jolt-sim-kw-lifo #t))
(define (jolt-sim-capabilities)
  (jolt-hash-map
   jolt-sim-kw-abi-version 6
   jolt-sim-kw-future-lifecycle #t
   jolt-sim-kw-controller-errors #t
   jolt-sim-kw-events
   (jolt-vector fhk-spawn fhk-start fhk-finish fhk-cancel fhk-exit fhk-abort)
   jolt-sim-kw-installation
   (jolt-hash-map
    jolt-sim-kw-configuration-keys
    (jolt-vector jolt-sim-kw-future jolt-sim-kw-ffi jolt-sim-kw-clock-controller)
    jolt-sim-kw-install-arity 1
    jolt-sim-kw-restore-arity 1
    jolt-sim-kw-atomic? #t
    jolt-sim-kw-strict-lifo? #t
    jolt-sim-kw-future-controller-arity 3
    jolt-sim-kw-ffi-controller-arity 2
    jolt-sim-kw-clock-controller-arity 2)
   jolt-sim-kw-ffi-interception
   (jolt-hash-map
    jolt-sim-kw-descriptor-version 8
    jolt-sim-kw-kinds (jolt-vector jolt-sim-kw-foreign-function
                                   jolt-sim-kw-native-operation)
    jolt-sim-kw-arguments jolt-sim-kw-live
    jolt-sim-kw-task-identity jolt-sim-kw-future-lifecycle
    jolt-sim-kw-native-operations
    (apply jolt-vector (map (lambda (s) (keyword #f s))
                            jolt-sim-native-operation-names))
    jolt-sim-kw-proceed-routing
    (jolt-assoc jolt-sim-proceed-capabilities
                jolt-sim-kw-scoped-byte-array-release jolt-sim-kw-runtime-owned)
    ;; The OPTIONAL scoped byte-array view: a controller's only window into
    ;; the runtime-owned temporary behind an ACTIVE with-byte-array-pointer
    ;; loan of its own thread. Both operations return nil for an unmatched
    ;; address (stale/post-extent, cross-thread, never-loaned) and fail closed
    ;; with IndexOutOfBoundsException for a matched address with an
    ;; out-of-range span. No acquire/release or borrow/release operation or
    ;; descriptor exists: the loan's dynamic extent owns the temporary, and
    ;; copy-back on exit remains the only publisher of temporary writes.
    jolt-sim-kw-scoped-byte-array-view
    (jolt-hash-map
     jolt-sim-kw-operations
     (jolt-vector jolt-sim-kw-read-active-byte-array-view
                  jolt-sim-kw-write-active-byte-array-view!)
     jolt-sim-kw-read-arity 2
     jolt-sim-kw-write-arity 2
     jolt-sim-kw-owner-thread #t
     jolt-sim-kw-dynamic-extent #t
     jolt-sim-kw-runtime-owned #t))
   jolt-sim-kw-clock-interception
   (jolt-hash-map
    jolt-sim-kw-descriptor-version 1
    jolt-sim-kw-operations (jolt-vector jolt-sim-kw-mono-nanos)
    jolt-sim-kw-result jolt-sim-kw-exact-integer-nanoseconds
    jolt-sim-kw-nondecreasing? #t
    jolt-sim-kw-supervisor-operation jolt-sim-kw-supervisor-mono-nanos
    jolt-sim-kw-proceed-routing jolt-sim-proceed-capabilities)))

;; One immutable public installation owns all effective controller state.
;; Validation and allocation precede publication; install and restore each
;; linearize at one assignment to jolt-sim-controller-top under one mutex. The
;; canonical hook stack is never touched by either operation: the persistent
;; bridge above reads this one pointer, so these are the ONLY mutations a
;; controller install/restore can publish.
(define jolt-sim-controller-mu (make-mutex))
(define (jolt-sim-controller-callable-arity? f arity)
  (and (procedure? f) (fxlogbit? arity (procedure-arity-mask f))))
(define (jolt-sim-validate-controller-config config)
  (unless (and (pmap? config)
               (= 3 (jolt-count config))
               (pmap-contains? config jolt-sim-kw-future)
               (pmap-contains? config jolt-sim-kw-ffi)
               (pmap-contains? config jolt-sim-kw-clock-controller))
    (error 'jolt-sim-install-controller!
           "controller configuration must contain exactly :future, :ffi, and :clock"))
  (let ((future (jolt-get config jolt-sim-kw-future))
        (ffi (jolt-get config jolt-sim-kw-ffi))
        (clock (jolt-get config jolt-sim-kw-clock-controller)))
    (unless (jolt-sim-controller-callable-arity? future 3)
      (error 'jolt-sim-install-controller! ":future controller must accept 3 arguments"))
    (unless (jolt-sim-controller-callable-arity? ffi 2)
      (error 'jolt-sim-install-controller! ":ffi controller must accept 2 arguments"))
    (unless (jolt-sim-controller-callable-arity? clock 2)
      (error 'jolt-sim-install-controller! ":clock controller must accept 2 arguments"))
    (list future ffi clock)))
(define (jolt-sim-install-controller! config)
  ;; Private-ABI precondition (shared with restore below): every pre-existing
  ;; worker/callback the host cannot enumerate — raw fork-threads, in-flight
  ;; calls that already snapshotted routing state, work outside the future
  ;; seam — must be quiescent across install/restore if the caller needs them
  ;; governed by exactly one composite. Such work is not installation-affine
  ;; and observes only the global pointer; the external adapter owns that
  ;; boundary. Controlled futures spawned AFTER this install are affine to the
  ;; effective composite at their spawn and need no such drain to keep
  ;; reporting to it (see the affinity section at the top of this file).
  ;; No public state is read or mutated until the whole value and all callback
  ;; arities have passed. The installation record is also allocated before
  ;; commit.
  (let* ((controllers (jolt-sim-validate-controller-config config))
         (future (list-ref controllers 0))
         (ffi (list-ref controllers 1))
         (clock (list-ref controllers 2)))
    (with-mutex jolt-sim-controller-mu
      ;; All allocation remains before the commit assignment and under the one
      ;; public ownership lock, so `previous` is one coherent public state. The
      ;; clock domain is the outermost live scope's: nested installations
      ;; linearize against the same last-published value.
      (let* ((previous jolt-sim-controller-top)
             (domain
              (if previous
                  (jolt-sim-controller-installation-domain previous)
                  (make-jolt-sim-clock-domain (make-mutex) #f)))
             (i (make-jolt-sim-controller-installation
                 future ffi clock domain previous)))
        ;; Linearization point: one pointer publishes all three controllers.
        (set! jolt-sim-controller-top i)
        i))))
(define (jolt-sim-restore-controller! installation)
  ;; Private-ABI precondition: every worker/callback that may use this
  ;; installation must be quiescent — including installation-affine controlled
  ;; tasks, which keep routing to it even while a later token is current
  ;; globally, and any raw/uncontrolled work the host cannot enumerate. The
  ;; external jolt-sim adapter proves that by draining lifecycle ownership
  ;; before it calls restore; the host does not maintain a second live-task
  ;; registry solely to duplicate that policy.
  (with-mutex jolt-sim-controller-mu
    ;; Validate before the sole assignment. A stale, foreign, or out-of-order
    ;; token leaves the complete effective controller state unchanged.
    (unless (and (eq? installation jolt-sim-controller-top)
                 (jolt-sim-controller-installation? installation))
      (error 'jolt-sim-restore-controller!
             "controller token is stale, foreign, or out of strict LIFO order"))
    ;; Linearization point: one pointer reinstates all prior controllers.
    (set! jolt-sim-controller-top
          (jolt-sim-controller-installation-previous installation)))
  jolt-nil)
;; Test/supervisor introspection of one atomic pointer read. #f means no public
;; controller; otherwise the three values came from the same immutable token.
(define (jolt-sim-effective-controller-snapshot)
  (let ((installation jolt-sim-controller-top))
    (and installation
         (list (jolt-sim-controller-installation-future installation)
               (jolt-sim-controller-installation-ffi installation)
               (jolt-sim-controller-installation-clock installation)))))
(define jolt-sim-kw-event (keyword #f "event"))
(define jolt-sim-kw-parent (keyword #f "parent"))
(define jolt-sim-kw-error (keyword #f "error"))
(define (jolt-sim-controller-errors)
  (apply jolt-vector
         (map (lambda (e)
                (jolt-hash-map jolt-sim-kw-event (list-ref e 0)
                               jolt-sim-kw-task (list-ref e 1)
                               jolt-sim-kw-parent (list-ref e 2)
                               jolt-sim-kw-error (list-ref e 3)))
              (jolt-future-hook-errors-snapshot))))

(def-var! "jolt.internal.sim" "capabilities" jolt-sim-capabilities)
(def-var! "jolt.internal.sim" "install-controller!" jolt-sim-install-controller!)
(def-var! "jolt.internal.sim" "restore-controller!" jolt-sim-restore-controller!)
(def-var! "jolt.internal.sim" "controller-errors" jolt-sim-controller-errors)
(def-var! "jolt.internal.sim" "clear-controller-errors!" jolt-future-hook-errors-clear!)
(def-var! "jolt.internal.sim" "supervisor-mono-nanos"
          jolt-sim-supervisor-mono-nanos)
;; The OPTIONAL scoped byte-array view vars (advertised under
;; :ffi-interception/:scoped-byte-array-view). They are the safe controller
;; window into the runtime-owned locked temporary behind an ACTIVE
;; with-byte-array-pointer loan of the calling thread: unmatched addresses
;; (stale/post-extent, cross-thread, never-loaned) answer nil, a matched
;; address with an out-of-range span fails closed with
;; IndexOutOfBoundsException, and neither var exposes loan acquire/release —
;; the loan's dynamic extent and copy-back own the temporary's lifetime. Both
;; are the exact host entries from host/chez/java/ffi.ss, unwrapped: they are
;; not intercepted and carry no descriptor.
(def-var! "jolt.internal.sim" "read-active-byte-array-view"
          ffi-read-active-byte-array-view)
(def-var! "jolt.internal.sim" "write-active-byte-array-view!"
          ffi-write-active-byte-array-view!)
