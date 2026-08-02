;; host/chez/sim/runtime.ss — private simulation-only runtime overlay.
;;
;; Loaded only by the `sim` Jolt image and by applications that image builds.
;; Ordinary release/debug images remain free of simulation state and branches.
;;
;; This is the complete prerelease controller overlay. It owns lifecycle,
;; monotonic-clock, typed foreign-call, and raw native-operation interception,
;; unified behind ONE atomic install/restore pair — there is no independent
;; per-subcontroller install or restore operation in the public ABI.

(define jolt-sim-runtime-image? #t)
;; The sole public controller-state pointer. A successful complete install or
;; restore publishes exactly one immutable composite through this binding.
(define jolt-sim-controller-top #f)

;; A sim-built application that retains the embedded compiler must arm the
;; current compiler unit before any application top-level form can eval/load
;; source. build.ss emits this call only for that retained-compiler flavor; a
;; compiler-dropped/tree-shaken output emits no call. Keep the lookup guarded so
;; the overlay itself remains valid in every sim output flavor.
(define (jolt-sim-arm-compiler!)
  (let ((cell (var-cell-lookup "jolt.backend-scheme" "set-sim-instrument!")))
    (when (and cell (var-cell-defined? cell) (procedure? (var-cell-root cell)))
      ((var-cell-root cell) #t)))
  jolt-nil)

;; === future lifecycle hook ===================================================
;; A disabled-by-default observability + gating seam over the centralized
;; fork-thread future path (host/chez/java/concurrency.ss's jolt-future-call).
;; When a hook fn (a jolt IFn) is installed via the controller below, each
;; ordinary future-call fires lifecycle events to it (called with jolt values):
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
  (let ((hook (jolt-sim-current-future-controller)))
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

;; === scoped native proceed ==================================================
;; Every routing continuation is an owner-thread, one-shot token at the top of
;; this thread's dynamic proceed stack. Consuming the token precedes the native
;; call, so an exception cannot make the same OS effect eligible to run twice.
;; Retiring in dynamic-wind's after thunk rejects escape and continuation
;; re-entry. Chez thread parameters are inherited, hence the explicit owner id.
(define-record-type jolt-sim-proceed-token
  (fields owner native (mutable live?) (mutable used?))
  (nongenerative jolt-sim-proceed-token-v1))
(define jolt-sim-proceed-stack-cell (make-thread-parameter #f))
(define (jolt-sim-current-proceed-stack)
  (let ((cell (jolt-sim-proceed-stack-cell)) (id (get-thread-id)))
    (if (and (pair? cell) (eqv? (car cell) id)) (cdr cell) '())))
(define (jolt-sim-call-routing-controller h descriptor native)
  (let* ((owner (get-thread-id))
         (outer (jolt-sim-current-proceed-stack))
         (token (make-jolt-sim-proceed-token owner native #t #f)))
    (let ((proceed
           (lambda ()
             (unless (jolt-sim-proceed-token-live? token)
               (error 'jolt-sim-proceed "native proceed is outside its dynamic extent"))
             (unless (eqv? owner (get-thread-id))
               (error 'jolt-sim-proceed "native proceed must run on its owner thread"))
             (unless (and (pair? (jolt-sim-current-proceed-stack))
                          (eq? token (car (jolt-sim-current-proceed-stack))))
               (error 'jolt-sim-proceed "native proceed must be consumed in LIFO order"))
             (when (jolt-sim-proceed-token-used? token)
               (error 'jolt-sim-proceed "native proceed may be invoked only once"))
             (jolt-sim-proceed-token-used?-set! token #t)
             ((jolt-sim-proceed-token-native token)))))
      (dynamic-wind
        (lambda ()
          (unless (jolt-sim-proceed-token-live? token)
            (error 'jolt-sim-proceed "routing controller cannot be re-entered")))
        (lambda ()
          (parameterize ((jolt-sim-proceed-stack-cell
                          (cons owner (cons token outer))))
            (jolt-invoke2 h descriptor proceed)))
        (lambda () (jolt-sim-proceed-token-live?-set! token #f))))))

;; === exact FFI interception =================================================
(define-record-type jolt-ffi-sim-hook-installation
  (fields hook routing? previous)
  (nongenerative jolt-ffi-sim-hook-installation-v3))
(define jolt-ffi-sim-hook #f)
(define jolt-ffi-sim-hook-top #f)
(define jolt-ffi-sim-hook-active-owner (make-thread-parameter #f))
(define (jolt-sim-current-future-controller)
  (let ((installation jolt-sim-controller-top))
    (if installation
        (jolt-sim-controller-installation-future installation)
        (unbox jolt-future-hook))))
(define (jolt-sim-current-ffi-hook)
  (let ((installation jolt-sim-controller-top))
    (if installation
        (jolt-sim-controller-installation-ffi installation)
        jolt-ffi-sim-hook)))

;; Scalar metadata only in descriptor v5. Aggregate and varargs declarations
;; are deliberately not recognized or advertised by this prerelease slice.
(define (jolt-ffi-make-sim-descriptor
         symbol argument-types return-type blocking? capture? arguments)
  (unless (and (string? symbol)
               (list? argument-types) (for-all string? argument-types)
               (string? return-type) (boolean? blocking?) (boolean? capture?)
               (list? arguments) (= (length argument-types) (length arguments)))
    (error 'jolt-ffi-make-sim-descriptor
           "malformed scalar foreign-function descriptor"))
  (list (cons 'symbol (string-copy symbol))
        (cons 'argument-types (map string-copy argument-types))
        (cons 'return-type (string-copy return-type))
        (cons 'blocking? blocking?)
        (cons 'capture-native-error? capture?)
        (cons 'arguments arguments)))
(define (jolt-ffi-make-native-sim-descriptor operation arguments)
  (list (cons 'kind 'native-operation)
        (cons 'operation (string-copy operation))
        (cons 'arguments arguments)))

(define (jolt-ffi-invoke-sim-hook installation descriptor native)
  (let ((owner (get-thread-id)))
    (when (eqv? owner (jolt-ffi-sim-hook-active-owner))
      (error 'jolt-ffi-invoke-sim-hook
             "reentrant FFI from a controller is not supported"))
    (parameterize ((jolt-ffi-sim-hook-active-owner owner))
      (let ((h (jolt-ffi-sim-hook-installation-hook installation)))
        (if (jolt-ffi-sim-hook-installation-routing? installation)
            ;; The active-owner parameter denotes CONTROLLER execution, not the
            ;; proceeded native phase. Suspend only that guard while native runs:
            ;; a synchronous native callback may perform nested FFI, whose own
            ;; controller/proceed token nests above this still-live outer token.
            (jolt-sim-call-routing-controller
             h descriptor
             (lambda ()
               (parameterize ((jolt-ffi-sim-hook-active-owner #f))
                 (native))))
            (jolt-invoke h descriptor))))))
(define (jolt-ffi-invoke-native-sim-op h operation arguments native)
  (jolt-ffi-invoke-sim-hook
   h (jolt-ffi-make-native-sim-descriptor operation arguments) native))

;; These sixteen wrappers are the complete descriptor-v5 raw operation set.
;; Each snapshots the installation once; malformed public descriptors are
;; rejected by the projection below before the native thunk can be offered.
(define (ffi-sim-load-library . args)
  (let ((h (jolt-sim-current-ffi-hook)))
    (if h (begin
            (when (> (length args) 1)
              (throw-jvm (quote IllegalArgumentException)
                         "jolt.ffi/load-library: expected zero or one argument"))
            (when (pair? args)
              (unless (jolt-nil? (car args)) (jolt-str-render-one (car args))))
            (jolt-ffi-invoke-native-sim-op
             h "load-library" args (lambda () (apply ffi-load-library args))))
        (apply ffi-load-library args))))
(define (ffi-sim-loaded? name)
  (let ((h (jolt-sim-current-ffi-hook)))
    (if h (begin
            (jolt-str-render-one name)
            (jolt-ffi-invoke-native-sim-op h "loaded?" (list name)
                                           (lambda () (ffi-loaded? name))))
        (ffi-loaded? name))))
(define (ffi-sim-alloc n)
  (let ((h (jolt-sim-current-ffi-hook)))
    (if h (begin
            (ffi-validate-allocation-size n)
            (jolt-ffi-invoke-native-sim-op h "alloc" (list n)
                                           (lambda () (ffi-alloc n))))
        (ffi-alloc n))))
(define (ffi-sim-free p)
  (let ((h (jolt-sim-current-ffi-hook)))
    (if h (begin
            (ffi-validate-pointer p)
            (jolt-ffi-invoke-native-sim-op h "free" (list p)
                                           (lambda () (ffi-free p))))
        (ffi-free p))))
(define (ffi-sim-read p ty . off)
  (let ((h (jolt-sim-current-ffi-hook)))
    (if h (begin
            (ffi-validate-read-args p ty off)
            (jolt-ffi-invoke-native-sim-op
             h "read" (cons p (cons ty off))
             (lambda () (apply ffi-read p ty off))))
        (apply ffi-read p ty off))))
(define (ffi-sim-write p ty off value)
  ;; Pointer, type, and offset conversion are pure and validated here. Chez's
  ;; target-type value coercion is inseparable from foreign-set! and therefore
  ;; remains provider-owned when the operation is modeled.
  (let ((h (jolt-sim-current-ffi-hook)))
    (if h (begin
            (ffi-validate-write-args p ty off)
            (jolt-ffi-invoke-native-sim-op
             h "write" (list p ty off value)
             (lambda () (ffi-write p ty off value))))
        (ffi-write p ty off value))))
(define (ffi-sim-sizeof ty)
  (let ((h (jolt-sim-current-ffi-hook)))
    (if h (begin
            (ffi-type->chez ty)
            (jolt-ffi-invoke-native-sim-op h "sizeof" (list ty)
                                           (lambda () (ffi-sizeof ty))))
        (ffi-sizeof ty))))
(define (ffi-sim-read-bytes p n)
  (let ((h (jolt-sim-current-ffi-hook)))
    (if h (begin
            (ffi-validate-transfer-count "read-bytes" p n)
            (jolt-ffi-invoke-native-sim-op h "read-bytes" (list p n)
                                           (lambda () (ffi-read-bytes p n))))
        (ffi-read-bytes p n))))
(define (ffi-sim-write-bytes p s)
  (let ((h (jolt-sim-current-ffi-hook)))
    (if h (begin
            (let ((bv (string->utf8 (jolt-str-render-one s))))
              (ffi-validate-transfer-count "write-bytes" p (bytevector-length bv)))
            (jolt-ffi-invoke-native-sim-op h "write-bytes" (list p s)
                                           (lambda () (ffi-write-bytes p s))))
        (ffi-write-bytes p s))))
(define (ffi-sim-read-array p n)
  (let ((h (jolt-sim-current-ffi-hook)))
    (if h (begin
            (ffi-validate-transfer-count "read-array" p n)
            (jolt-ffi-invoke-native-sim-op h "read-array" (list p n)
                                           (lambda () (ffi-read-array p n))))
        (ffi-read-array p n))))
(define (ffi-sim-read-array! p n dest off)
  (let ((h (jolt-sim-current-ffi-hook)))
    (if h (begin
            (ffi-validate-read-array!-args p n dest off)
            (jolt-ffi-invoke-native-sim-op
             h "read-array!" (list p n dest off)
             (lambda () (ffi-read-array! p n dest off))))
        (ffi-read-array! p n dest off))))
(define ffi-sim-write-array
  (case-lambda
    ((p arr)
     (let ((h (jolt-sim-current-ffi-hook)))
       (if h (begin
               (ffi-validate-write-array-whole p arr)
               (jolt-ffi-invoke-native-sim-op
                h "write-array" (list p arr)
                (lambda () (ffi-write-array p arr))))
           (ffi-write-array p arr))))
    ((p arr off n)
     (let ((h (jolt-sim-current-ffi-hook)))
       (if h (begin
               (ffi-validate-write-array-range p arr off n)
               (jolt-ffi-invoke-native-sim-op
                h "write-array" (list p arr off n)
                (lambda () (ffi-write-array p arr off n))))
           (ffi-write-array p arr off n))))))
(define (ffi-sim-ptr->string p)
  (let ((h (jolt-sim-current-ffi-hook)))
    (if h (begin
            (ffi-validate-pointer p)
            (jolt-ffi-invoke-native-sim-op h "ptr->string" (list p)
                                           (lambda () (ffi-ptr->string p))))
        (ffi-ptr->string p))))
(define (ffi-sim-string->ptr s)
  (let ((h (jolt-sim-current-ffi-hook)))
    (if h (begin
            (string->utf8 (jolt-str-render-one s))
            (jolt-ffi-invoke-native-sim-op h "string->ptr" (list s)
                                           (lambda () (ffi-string->ptr s))))
        (ffi-string->ptr s))))

;; Staged signed-byte loans. A real proceed allocates and locks the same kind
;; of temporary bytevector as the ordinary base primitive. Cleanup retires
;; first, then copybacks/unlocks exactly once even if the release observer
;; raises. A modeled borrow never fabricates a real lock, and proceeding its
;; release fails before any native operation.
(define (ffi-sim-with-byte-array-pointer-range arr off len f)
  (let* ((v (ffi-byte-array-vector "with-byte-array-pointer" arr))
         (start (jnum->exact off)) (cnt (jnum->exact len))
         (owner (get-thread-id))
         (active (ffi-current-byte-array-loans))
         (h (jolt-sim-current-ffi-hook)))
    (ffi-check-array-range "with-byte-array-pointer" v start cnt)
    (when (memq arr active)
      (throw-jvm (quote IllegalStateException)
                 "jolt.ffi/with-byte-array-pointer: nested loan of the same byte-array"))
    (if (not h)
        (ffi-with-byte-array-pointer-range arr start cnt f)
        (let ((p #f) (real-p #f) (tmp #f) (borrowed? #f) (retired? #f))
          (letrec ((release-real!
                    (lambda ()
                      (unless tmp
                        (error 'jolt-ffi-proceed "real byte-array loan is already released"))
                      (let ((owned tmp))
                        ;; Claim cleanup before user-visible copyback can raise.
                        (set! tmp #f)
                        (dynamic-wind
                          void
                          (lambda () (ffi-copy-bytevector-to-vector! owned v start cnt))
                          (lambda () (unlock-object owned))))
                      jolt-nil)))
            (dynamic-wind
              (lambda ()
                (when retired?
                  (error 'jolt.ffi "scoped byte-array pointer cannot be re-entered")))
              (lambda ()
                (parameterize ((ffi-byte-array-loan-cell
                                (cons owner (cons arr active))))
                  (set! p
                        (jolt-ffi-invoke-native-sim-op
                         h "borrow-byte-array" (list arr start cnt)
                         (lambda ()
                           (let ((candidate (make-bytevector cnt 0)))
                             (ffi-copy-vector-to-bytevector! v start candidate cnt)
                             (lock-object candidate)
                             ;; Publish cleanup ownership only after the lock
                             ;; succeeds; every published tmp is unlocked once.
                             (set! tmp candidate)
                             (set! real-p (object->reference-address candidate))
                             real-p))))
                  (unless (and (integer? p) (> p 0))
                    (error 'jolt.ffi "simulated byte-array loan must return a positive integer pointer"))
                  (when (and real-p (not (= p real-p)))
                    (error 'jolt.ffi "controller changed a proceeded byte-array pointer"))
                  (set! borrowed? #t)
                  (jolt-invoke2 f p cnt)))
              (lambda ()
                (set! retired? #t)
                (cond
                  (tmp
                   (if borrowed?
                       (guard (e (#t (when tmp (release-real!)) (raise e)))
                         (jolt-ffi-invoke-native-sim-op
                          h "release-byte-array" (list p) release-real!)
                         (when tmp (release-real!)))
                       ;; Borrow/proceed failed before a pointer escaped. There
                       ;; is no successful borrow to report, only owned cleanup.
                       (release-real!)))
                  (borrowed?
                   (jolt-ffi-invoke-native-sim-op
                    h "release-byte-array" (list p)
                    (lambda ()
                      (error 'jolt-ffi-proceed
                             "cannot proceed release of a modeled byte-array loan"))))))))))))
(define ffi-sim-with-byte-array-pointer
  (case-lambda
    ((arr f)
     (let ((v (ffi-byte-array-vector "with-byte-array-pointer" arr)))
       (ffi-sim-with-byte-array-pointer-range arr 0 (vector-length v) f)))
    ((arr off len f) (ffi-sim-with-byte-array-pointer-range arr off len f))))

;; Rebind only in this overlay. With no installed controller each wrapper calls
;; the branch-free ordinary base primitive unchanged.
(def-var! "jolt.ffi" "load-library" ffi-sim-load-library)
(def-var! "jolt.ffi" "loaded?"
          (lambda (n) (if (jolt-truthy? (ffi-sim-loaded? n)) #t #f)))
(def-var! "jolt.ffi" "alloc" ffi-sim-alloc)
(def-var! "jolt.ffi" "free" ffi-sim-free)
(def-var! "jolt.ffi" "read" ffi-sim-read)
(def-var! "jolt.ffi" "write" ffi-sim-write)
(def-var! "jolt.ffi" "sizeof" ffi-sim-sizeof)
(def-var! "jolt.ffi" "read-bytes" ffi-sim-read-bytes)
(def-var! "jolt.ffi" "write-bytes" ffi-sim-write-bytes)
(def-var! "jolt.ffi" "read-array" ffi-sim-read-array)
(def-var! "jolt.ffi" "read-array!" ffi-sim-read-array!)
(def-var! "jolt.ffi" "write-array" ffi-sim-write-array)
(def-var! "jolt.ffi" "with-byte-array-pointer" ffi-sim-with-byte-array-pointer)
(def-var! "jolt.ffi" "ptr->string" ffi-sim-ptr->string)
(def-var! "jolt.ffi" "string->ptr" ffi-sim-string->ptr)

;; === monotonic clock interception ===========================================
;; Save the central native source, then replace that one top-level procedure.
;; System/nanoTime (host-static-methods.ss) calls jolt-mono-nanos BY NAME at
;; invocation time, so redirecting the Scheme binding redirects it too. The
;; public jolt.host/mono-nanos var (rt.ss) was captured BY VALUE at def-var!
;; time, before this overlay ever loads, so it does NOT observe a plain `set!`
;; of jolt-mono-nanos — it must be re-registered explicitly below. The
;; supervisor primitive captured here calls the ORIGINAL saved procedure
;; directly and can therefore drive jolt-sim's drain watchdog even while
;; modeled time is frozen or under active control.
(define jolt-sim-supervisor-mono-nanos-source jolt-mono-nanos)
(define-record-type jolt-sim-clock-domain
  (fields mu (mutable last))
  (nongenerative jolt-sim-clock-domain-v1))
(define-record-type jolt-sim-clock-installation
  (fields hook routing? previous domain)
  (nongenerative jolt-sim-clock-installation-v2))
(define jolt-sim-clock-top #f)
(define jolt-sim-clock-active-owner (make-thread-parameter #f))
(define (jolt-sim-current-clock-installation)
  (let ((installation jolt-sim-controller-top))
    (if installation
        (jolt-sim-controller-installation-clock installation)
        jolt-sim-clock-top)))
(define jolt-sim-kw-kind (keyword #f "kind"))
(define jolt-sim-kw-clock (keyword #f "clock"))
(define jolt-sim-kw-operation (keyword #f "operation"))
(define jolt-sim-kw-mono-nanos (keyword #f "mono-nanos"))
(define jolt-sim-clock-descriptor
  (jolt-hash-map jolt-sim-kw-kind jolt-sim-kw-clock
                 jolt-sim-kw-operation jolt-sim-kw-mono-nanos))
(define (jolt-sim-clock-validate! installation n)
  (unless (and (integer? n) (exact? n))
    (error 'jolt-sim-clock "monotonic clock must return exact integer nanoseconds"))
  ;; Every nested composite installation shares the outermost scope's domain.
  ;; A fresh outer scope may start virtual time at any origin, but an inner
  ;; controller cannot advance the clock and then reveal an older outer value
  ;; after restoration.
  (let ((domain (jolt-sim-clock-installation-domain installation)))
    (with-mutex (jolt-sim-clock-domain-mu domain)
      (let ((last (jolt-sim-clock-domain-last domain)))
        (when (and last (< n last))
          (error 'jolt-sim-clock "monotonic clock moved backward"))
        (jolt-sim-clock-domain-last-set! domain n))))
  n)
(define (jolt-sim-mono-nanos)
  (let ((installation (jolt-sim-current-clock-installation)))
    (if (not installation)
        (jolt-sim-supervisor-mono-nanos-source)
        (let ((owner (get-thread-id)))
          (when (eqv? owner (jolt-sim-clock-active-owner))
            (error 'jolt-sim-clock "reentrant controlled clock access is not supported"))
          (parameterize ((jolt-sim-clock-active-owner owner))
            (jolt-sim-clock-validate!
             installation
             (if (jolt-sim-clock-installation-routing? installation)
                 (jolt-sim-call-routing-controller
                  (jolt-sim-clock-installation-hook installation)
                  jolt-sim-clock-descriptor
                  jolt-sim-supervisor-mono-nanos-source)
                 (jolt-invoke (jolt-sim-clock-installation-hook installation)
                              jolt-sim-clock-descriptor))))))))
;; Redirect both call paths: System/nanoTime resolves jolt-mono-nanos by name
;; at call time (the `set!` alone covers it); jolt.host/mono-nanos was already
;; published by value and needs an explicit re-registration to the same
;; interceptable procedure.
(set! jolt-mono-nanos jolt-sim-mono-nanos)
(def-var! "jolt.host" "mono-nanos" jolt-sim-mono-nanos)
(define (jolt-sim-supervisor-mono-nanos)
  (->num (jolt-sim-supervisor-mono-nanos-source)))

;; === public prerelease controller ABI =======================================
(define jolt-sim-native-operation-names
  '("load-library" "loaded?" "alloc" "free" "read" "write" "sizeof"
    "read-bytes" "write-bytes" "read-array" "read-array!" "write-array"
    "borrow-byte-array" "release-byte-array" "ptr->string" "string->ptr"))
(define jolt-sim-kw-abi-version (keyword #f "abi-version"))
(define jolt-sim-kw-future-lifecycle (keyword #f "future-lifecycle"))
(define jolt-sim-kw-controller-errors (keyword #f "controller-errors"))
(define jolt-sim-kw-events (keyword #f "events"))
(define jolt-sim-kw-ffi-interception (keyword #f "ffi-interception"))
(define jolt-sim-kw-clock-interception (keyword #f "clock-interception"))
(define jolt-sim-kw-descriptor-version (keyword #f "descriptor-version"))
(define jolt-sim-kw-kinds (keyword #f "kinds"))
(define jolt-sim-kw-foreign-function (keyword #f "foreign-function"))
(define jolt-sim-kw-native-operation (keyword #f "native-operation"))
(define jolt-sim-kw-arguments (keyword #f "arguments"))
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
    jolt-sim-kw-descriptor-version 5
    jolt-sim-kw-kinds (jolt-vector jolt-sim-kw-foreign-function
                                   jolt-sim-kw-native-operation)
    jolt-sim-kw-arguments jolt-sim-kw-live
    jolt-sim-kw-task-identity jolt-sim-kw-future-lifecycle
    jolt-sim-kw-native-operations
    (apply jolt-vector (map (lambda (s) (keyword #f s))
                            jolt-sim-native-operation-names))
    jolt-sim-kw-proceed-routing
    (jolt-assoc jolt-sim-proceed-capabilities
                jolt-sim-kw-scoped-byte-array-release jolt-sim-kw-runtime-owned))
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
;; linearize at one assignment to jolt-sim-controller-top under one mutex.
(define-record-type jolt-sim-controller-installation
  (fields future ffi-controller ffi clock previous)
  (nongenerative jolt-sim-controller-installation-v6))
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
  ;; No public state is read or mutated until the whole value and all callback
  ;; arities have passed. The wrappers/records are also allocated before commit.
  (let* ((controllers (jolt-sim-validate-controller-config config))
         (future (list-ref controllers 0))
         (ffi-controller (list-ref controllers 1))
         (clock-controller (list-ref controllers 2))
         (ffi-wrapper
          (lambda (desc proceed)
            (let ((projected (jolt-sim-project-ffi-descriptor desc)))
              (jolt-invoke2 ffi-controller projected proceed)))))
    (with-mutex jolt-sim-controller-mu
      ;; All allocation remains before the commit assignments and under the one
      ;; public ownership lock, so `previous` is one coherent public state.
      (let* ((previous jolt-sim-controller-top)
             (clock-domain
              (if previous
                  (jolt-sim-clock-installation-domain
                   (jolt-sim-controller-installation-clock previous))
                  (make-jolt-sim-clock-domain (make-mutex) #f)))
             (ffi* (make-jolt-ffi-sim-hook-installation
                    ffi-wrapper #t jolt-ffi-sim-hook-top))
             (clock* (make-jolt-sim-clock-installation
                      clock-controller #t jolt-sim-clock-top clock-domain))
             (i (make-jolt-sim-controller-installation
                  future ffi-controller ffi* clock* previous)))
        ;; Linearization point: one pointer publishes all three controllers.
        (set! jolt-sim-controller-top i)
        i))))
(define (jolt-sim-restore-controller! installation)
  ;; Private-ABI precondition: every worker/callback that may use this
  ;; installation must be quiescent. The external jolt-sim adapter proves that
  ;; by draining lifecycle ownership before it calls restore; the host does not
  ;; maintain a second live-task registry solely to duplicate that policy.
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
               (jolt-sim-controller-installation-ffi-controller installation)
               (jolt-sim-clock-installation-hook
                (jolt-sim-controller-installation-clock installation))))))
(define jolt-sim-kw-event (keyword #f "event"))
(define jolt-sim-kw-task (keyword #f "task"))
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

;; Exact descriptor-v5 projection. Key order, kind, operation membership, and
;; native-operation arities are checked before a public controller sees a
;; proceed thunk; unknown/malformed input therefore cannot reach the OS.
(define jolt-sim-kw-symbol (keyword #f "symbol"))
(define jolt-sim-kw-argument-types (keyword #f "argument-types"))
(define jolt-sim-kw-return-type (keyword #f "return-type"))
(define jolt-sim-kw-blocking? (keyword #f "blocking?"))
(define jolt-sim-kw-capture-native-error? (keyword #f "capture-native-error?"))
(define (jolt-sim-raw-keys d) (and (list? d) (for-all pair? d) (map car d)))
(define (jolt-sim-native-arity-valid? op args)
  (let ((n (length args)))
    (cond
      ((member op '("load-library")) (or (= n 0) (= n 1)))
      ((member op '("loaded?" "alloc" "free" "sizeof" "ptr->string"
                    "string->ptr" "release-byte-array")) (= n 1))
      ((member op '("read-bytes" "write-bytes" "read-array")) (= n 2))
      ((string=? op "read") (or (= n 2) (= n 3)))
      ((string=? op "write") (= n 4))
      ((string=? op "write-array") (or (= n 2) (= n 4)))
      ((string=? op "borrow-byte-array") (= n 3))
      ((string=? op "read-array!") (= n 4))
      (else #f))))
(define (jolt-sim-project-ffi-descriptor desc)
  (let ((ks (jolt-sim-raw-keys desc)))
    (cond
      ((and (equal? ks '(symbol argument-types return-type blocking?
                                capture-native-error? arguments))
            (string? (cdr (assq 'symbol desc)))
            (list? (cdr (assq 'argument-types desc)))
            (for-all string? (cdr (assq 'argument-types desc)))
            (string? (cdr (assq 'return-type desc)))
            (boolean? (cdr (assq 'blocking? desc)))
            (boolean? (cdr (assq 'capture-native-error? desc)))
            (list? (cdr (assq 'arguments desc)))
            (= (length (cdr (assq 'argument-types desc)))
               (length (cdr (assq 'arguments desc)))))
       (jolt-hash-map
        jolt-sim-kw-kind jolt-sim-kw-foreign-function
        jolt-sim-kw-task (jolt-future-current-task-id)
        jolt-sim-kw-symbol (cdr (assq 'symbol desc))
        jolt-sim-kw-argument-types
        (apply jolt-vector (map (lambda (s) (keyword #f s))
                                (cdr (assq 'argument-types desc))))
        jolt-sim-kw-return-type (keyword #f (cdr (assq 'return-type desc)))
        jolt-sim-kw-blocking? (cdr (assq 'blocking? desc))
        jolt-sim-kw-capture-native-error? (cdr (assq 'capture-native-error? desc))
        jolt-sim-kw-arguments (apply jolt-vector (cdr (assq 'arguments desc)))))
      ((and (equal? ks '(kind operation arguments))
            (eq? (cdr (assq 'kind desc)) 'native-operation)
            (string? (cdr (assq 'operation desc)))
            (member (cdr (assq 'operation desc)) jolt-sim-native-operation-names)
            (list? (cdr (assq 'arguments desc)))
            (jolt-sim-native-arity-valid? (cdr (assq 'operation desc))
                                          (cdr (assq 'arguments desc))))
       (jolt-hash-map
        jolt-sim-kw-kind jolt-sim-kw-native-operation
        jolt-sim-kw-task (jolt-future-current-task-id)
        jolt-sim-kw-operation (keyword #f (cdr (assq 'operation desc)))
        jolt-sim-kw-arguments (apply jolt-vector (cdr (assq 'arguments desc)))))
      (else
       (error 'jolt-sim-project-ffi-descriptor
              "malformed or unknown FFI controller operation" desc)))))
(def-var! "jolt.internal.sim" "capabilities" jolt-sim-capabilities)
(def-var! "jolt.internal.sim" "install-controller!" jolt-sim-install-controller!)
(def-var! "jolt.internal.sim" "restore-controller!" jolt-sim-restore-controller!)
(def-var! "jolt.internal.sim" "controller-errors" jolt-sim-controller-errors)
(def-var! "jolt.internal.sim" "clear-controller-errors!" jolt-future-hook-errors-clear!)
(def-var! "jolt.internal.sim" "supervisor-mono-nanos"
          jolt-sim-supervisor-mono-nanos)
