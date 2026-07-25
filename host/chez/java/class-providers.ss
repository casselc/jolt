;; class-providers.ss — bounded lazy providers for modeled Java classes.
;;
;; A resolved dependency graph registers exact canonical class-name ->
;; provider-namespace mappings before application compilation.  A constructor,
;; static, Class/forName, or eligible instance-member miss evaluates exactly that
;; namespace and retries the same lookup once.
;;
;; Provider evaluation is process-wide serialized.  The owner thread may load a
;; nested provider, while every other thread waits for the whole outer evaluation
;; graph to stabilize.  This deliberately trades parallel provider startup for a
;; small, auditable deadlock surface and prevents another thread from observing a
;; dependency whose registration namespace is only half initialized.
;;
;; This file is literally loaded by host-static.ss.  The build flattener follows
;; literal top-level loads, so do not hide that load behind a conditional.

(define class-providers-tbl (make-hashtable string-hash string=?))
;; provider namespace -> 'loaded | attempt vector
;; attempt: [id provider owner status error waiter-count]
(define class-provider-states-tbl (make-hashtable string-hash string=?))
(define class-provider-mu (make-mutex 'class-providers))
(define class-provider-cv (make-condition))
(define class-provider-eval-owner #f)
(define class-provider-attempt-counter 0)
(define class-provider-registry-generation 0)
(define class-provider-load-stack (make-thread-parameter '()))

;; A provider's Clojure-visible registration hooks append mutations here while
;; its namespace evaluates.  They commit only after the namespace returns
;; successfully.  The stage is a vector [operations pending-provider-mappings].
(define class-provider-registration-stage (make-thread-parameter #f))

;; Class -> number of callers blocked at the stable-registry boundary.  This is
;; also useful operational state (and gives deterministic concurrency controls).
(define class-provider-stable-waiters (make-hashtable string-hash string=?))

(define (class-provider-error type message details)
  (jolt-throw
    (jolt-ex-info
      message
      (jolt-hash-map
        (keyword "jolt" "error")
        (jolt-assoc1 details (keyword #f "type") (keyword #f type))))))

(define (class-provider-name x what)
  (cond ((string? x) x)
        ((symbol-t? x) (symbol-t-name x))
        (else
          (class-provider-error
            "invalid-class-provider"
            (string-append what " must be a string or symbol")
            (jolt-hash-map (keyword #f "value") x)))))

(define (class-provider-canonical-name? class)
  ;; Provider identity is exact and canonical.  Array descriptor classes are
  ;; already intrinsic to the runtime and are not dependency-owned providers.
  (let ((n (string-length class)))
    (and (> n 2)
         (not (char=? (string-ref class 0) #\.))
         (not (char=? (string-ref class (- n 1)) #\.))
         (let loop ((i 0) (saw-dot? #f) (previous-dot? #f))
           (if (= i n)
               saw-dot?
               (let ((ch (string-ref class i)))
                 (and (not (char=? ch #\/))
                      (not (and previous-dot? (char=? ch #\.)))
                      (loop (+ i 1)
                            (or saw-dot? (char=? ch #\.))
                            (char=? ch #\.)))))))))

(define (class-provider-validate-names class provider)
  (let ((class (class-provider-name class "class-provider class"))
        (provider (class-provider-name provider "class-provider namespace")))
    (when (or (= (string-length class) 0)
              (not (class-provider-canonical-name? class)))
      (class-provider-error
        "invalid-class-provider"
        "class-provider class must be a canonical fully-qualified name"
        (jolt-hash-map (keyword #f "class") class)))
    (when (= (string-length provider) 0)
      (class-provider-error
        "invalid-class-provider" "class-provider namespace must not be empty"
        (jolt-hash-map (keyword #f "class") class
                       (keyword #f "provider") provider)))
    (cons class provider)))

(define (class-provider-conflict! class old provider)
  (class-provider-error
    "class-provider-conflict"
    (string-append "Conflicting class providers for " class
                   ": " old " and " provider)
    (jolt-hash-map
      (keyword #f "class") class
      (keyword #f "existing-provider") old
      (keyword #f "new-provider") provider)))

(define (class-provider-wait-evaluator-locked! self)
  (let loop ()
    (when (and class-provider-eval-owner
               (not (eqv? class-provider-eval-owner self)))
      (condition-wait class-provider-cv class-provider-mu)
      (loop))))

;; Register one exact mapping.  During provider evaluation, mappings are staged
;; with the other registrations.  Outside it, a whole-map caller preflights first
;; (class-provider-register-many!) so conflicts cannot partially install a map.
(define (class-provider-register-one! class0 provider0)
  (let* ((names (class-provider-validate-names class0 provider0))
         (class (car names))
         (provider (cdr names))
         (stage (class-provider-registration-stage)))
    (if stage
        (with-mutex class-provider-mu
          (let* ((pending (vector-ref stage 1))
                 (old (or (hashtable-ref pending class #f)
                          (hashtable-ref class-providers-tbl class #f))))
            (cond
              ((not old) (hashtable-set! pending class provider))
              ((string=? old provider) #f)
              (else (class-provider-conflict! class old provider)))))
        (with-mutex class-provider-mu
          (class-provider-wait-evaluator-locked! (get-thread-id))
          (let ((old (hashtable-ref class-providers-tbl class #f)))
            (cond
              ((not old)
               (hashtable-set! class-providers-tbl class provider)
               (set! class-provider-registry-generation
                     (+ class-provider-registry-generation 1)))
              ((string=? old provider) #f)
              (else (class-provider-conflict! class old provider))))))
    jolt-nil))

;; Whole-map registration is atomic: normalize and check every declaration before
;; changing the global table.  `pairs` is a Scheme alist of raw class/provider
;; values produced by the Clojure map bridge.
(define (class-provider-register-many! pairs)
  (let ((normalized
          (map (lambda (p)
                 (class-provider-validate-names (car p) (cdr p)))
               pairs))
        (stage (class-provider-registration-stage)))
    (if stage
        (with-mutex class-provider-mu
          ;; Preflight into a private table first.  A provider is allowed to
          ;; catch a registration conflict; doing so must not leave the prefix
          ;; of that rejected map in its otherwise-successful evaluation stage.
          (let ((pending (vector-ref stage 1))
                (batch (make-hashtable string-hash string=?)))
            (for-each
              (lambda (p)
                (let* ((class (car p))
                       (provider (cdr p))
                       (old (or (hashtable-ref batch class #f)
                                (hashtable-ref pending class #f)
                                (hashtable-ref class-providers-tbl class #f))))
                  (cond
                    ((not old) (hashtable-set! batch class provider))
                    ((string=? old provider) #f)
                    (else (class-provider-conflict! class old provider)))))
              normalized)
            (vector-for-each
              (lambda (class provider)
                (hashtable-set! pending class provider))
              (hashtable-keys batch)
              (hashtable-values batch))))
        (with-mutex class-provider-mu
          (class-provider-wait-evaluator-locked! (get-thread-id))
          ;; Preflight both the existing table and duplicates within this batch.
          (let ((pending (make-hashtable string-hash string=?)))
            (for-each
              (lambda (p)
                (let* ((class (car p))
                       (provider (cdr p))
                       (old (or (hashtable-ref pending class #f)
                                (hashtable-ref class-providers-tbl class #f))))
                  (cond
                    ((not old) (hashtable-set! pending class provider))
                    ((string=? old provider) #f)
                    (else (class-provider-conflict! class old provider)))))
              normalized)
            (vector-for-each
              (lambda (class provider)
                (unless (hashtable-ref class-providers-tbl class #f)
                  (hashtable-set! class-providers-tbl class provider)
                  (set! class-provider-registry-generation
                        (+ class-provider-registry-generation 1))))
              (hashtable-keys pending)
              (hashtable-values pending)))))
    jolt-nil))

;; A build is an explicit closed-world transaction.  Replace ambient declarations
;; with the map resolved for that build before the entry namespace is loaded.
(define (class-provider-reset-many! pairs)
  (with-mutex class-provider-mu
    (class-provider-wait-evaluator-locked! (get-thread-id))
    (hashtable-clear! class-providers-tbl)
    (hashtable-clear! class-provider-states-tbl)
    (hashtable-clear! class-provider-stable-waiters)
    (set! class-provider-registry-generation
          (+ class-provider-registry-generation 1)))
  (class-provider-register-many! pairs))

;; Append one provider-owned registration mutation to the current evaluation
;; stage.  Returns #t when staged and #f outside provider evaluation.
(define (class-provider-stage-operation! proc)
  (let ((stage (class-provider-registration-stage)))
    (and stage
         (begin
           (vector-set! stage 0 (cons proc (vector-ref stage 0)))
           #t))))

;; Ordinary (non-provider) registration must not race a provider transaction:
;; otherwise a rollback could restore its older snapshot over an unrelated
;; successful mutation. The operation itself runs under the coordinator lock,
;; so a provider claim cannot begin between the stable-world check and publish.
(define (class-provider-run-operation! proc)
  (with-mutex class-provider-mu
    (class-provider-wait-evaluator-locked! (get-thread-id))
    (proc)))

(define (class-provider-copy-string-table table copy-value)
  (let ((result (make-hashtable string-hash string=?)))
    (let-values (((keys vals) (hashtable-entries table)))
      (vector-for-each
        (lambda (key value)
          (hashtable-set! result key (copy-value value)))
        keys vals))
    result))

;; Copy a string table whose values are themselves string tables. Preserve
;; shared inner tables: core's historic short/FQN aliases intentionally point at
;; one member table, and rollback must not split that identity.
(define (class-provider-copy-nested-string-table table copy-leaf)
  (let ((result (make-hashtable string-hash string=?))
        (seen (make-eq-hashtable)))
    (let-values (((keys vals) (hashtable-entries table)))
      (vector-for-each
        (lambda (key inner)
          (let ((copy
                  (or (hashtable-ref seen inner #f)
                      (let ((new
                              (class-provider-copy-string-table
                                inner copy-leaf)))
                        (hashtable-set! seen inner new)
                        new))))
            (hashtable-set! result key copy)))
        keys vals))
    result))

(define (class-provider-copy-vector value)
  (list->vector (vector->list value)))

;; Snapshot exactly the mutable registries reachable through the provider
;; registration hooks. Arbitrary provider top-level side effects remain outside
;; the transaction, as documented.
(define (class-provider-world-snapshot)
  (let ((provider-table
          (with-mutex class-provider-mu
            (class-provider-copy-string-table
              class-providers-tbl (lambda (x) x))))
        (provider-generation
          (with-mutex class-provider-mu
            class-provider-registry-generation)))
    (vector
      provider-table
      provider-generation
      (class-provider-copy-nested-string-table
        class-statics-tbl (lambda (x) x))
      (class-provider-copy-string-table class-ctors-tbl (lambda (x) x))
      (class-provider-copy-nested-string-table
        mutable-statics-tbl class-provider-copy-vector)
      (class-provider-copy-nested-string-table
        tagged-methods-tbl (lambda (x) x))
      (class-provider-copy-string-table jvm-class-parents (lambda (x) x))
      user-instance-checks
      jolt-eq-arms
      jolt-hash-arms
      str-render-registry
      jolt-pr-str-arms
      jolt-pr-readable-arms
      jolt-compare-arms
      jolt-class-arms
      jt-user-value-tags-arms)))

(define (class-provider-world-restore! snapshot)
  (with-mutex class-provider-mu
    (set! class-providers-tbl (vector-ref snapshot 0))
    (set! class-provider-registry-generation (vector-ref snapshot 1)))
  (set! class-statics-tbl (vector-ref snapshot 2))
  (set! class-ctors-tbl (vector-ref snapshot 3))
  (set! mutable-statics-tbl (vector-ref snapshot 4))
  (set! tagged-methods-tbl (vector-ref snapshot 5))
  (set! jvm-class-parents (vector-ref snapshot 6))
  (set! user-instance-checks (vector-ref snapshot 7))
  (set! jolt-eq-arms (vector-ref snapshot 8))
  (set! jolt-hash-arms (vector-ref snapshot 9))
  (set! str-render-registry (vector-ref snapshot 10))
  (set! jolt-pr-str-arms (vector-ref snapshot 11))
  (set! jolt-pr-readable-arms (vector-ref snapshot 12))
  (set! jolt-compare-arms (vector-ref snapshot 13))
  (set! jolt-class-arms (vector-ref snapshot 14))
  (set! jt-user-value-tags-arms (vector-ref snapshot 15))
  ;; The restored hierarchy is authoritative; discard every derived cache.
  (with-mutex jch-cache-mutex
    (set! jch-closure-cache (make-hashtable string-hash string=?))
    (set! jch-tags-cache (make-hashtable string-hash string=?)))
  (set! jch-known-cache #f)
  (set! jch-simple->fqn-cache #f))

(define (class-provider-commit-stage! stage)
  (let ((snapshot (class-provider-world-snapshot)))
    (guard (e (else
                (class-provider-world-restore! snapshot)
                (raise e)))
      ;; Mapping conflicts were preflighted when staged, but an external
      ;; add-deps caller may have registered while source evaluated. The global
      ;; evaluator owner blocks such callers; register-many! still rechecks
      ;; defensively.
      (let ((pending (vector-ref stage 1)))
        (let-values (((keys vals) (hashtable-entries pending)))
          (class-provider-register-many!
            (let loop ((i 0) (acc '()))
              (if (= i (vector-length keys))
                  (reverse acc)
                  (loop (+ i 1)
                        (cons
                          (cons (vector-ref keys i) (vector-ref vals i))
                          acc)))))))
      ;; Source order matters for representation hooks, hence the reverse.
      (for-each
        (lambda (proc) (proc))
        (reverse (vector-ref stage 0))))))

;; Exact provider lookup.  There is intentionally no last-segment fallback:
;; namespace imports are canonicalized by the analyzer.
(define (class-provider-for class)
  (with-mutex class-provider-mu
    (hashtable-ref class-providers-tbl class #f)))

;; Deterministic mappings/provider namespace lists for dependency and AOT build
;; manifests.
(define (class-provider-mappings)
  (with-mutex class-provider-mu
    (let-values (((keys vals) (hashtable-entries class-providers-tbl)))
      (sort (lambda (a b) (string<? (car a) (car b)))
            (let loop ((i 0) (acc '()))
              (if (= i (vector-length keys))
                  acc
                  (loop (+ i 1)
                        (cons (cons (vector-ref keys i) (vector-ref vals i))
                              acc))))))))

(define (class-provider-namespaces)
  (let ((seen (make-hashtable string-hash string=?))
        (result '()))
    (for-each
      (lambda (p)
        (unless (hashtable-ref seen (cdr p) #f)
          (hashtable-set! seen (cdr p) #t)
          (set! result (cons (cdr p) result))))
      (class-provider-mappings))
    (sort string<? result)))

(define (class-provider-generation)
  (with-mutex class-provider-mu class-provider-registry-generation))

(define (class-provider-cycle! provider)
  (let ((path (reverse (cons provider (class-provider-load-stack)))))
    (class-provider-error
      "class-provider-cycle"
      (string-append
        "Re-entrant class-provider load: "
        (let loop ((xs path) (out ""))
          (cond
            ((null? xs) out)
            ((string=? out "") (loop (cdr xs) (car xs)))
            (else (loop (cdr xs)
                        (string-append out " -> " (car xs)))))))
      (jolt-hash-map
        (keyword #f "provider") provider
        (keyword #f "path") (list->cseq path)))))

(define (class-provider-attempt-status attempt) (vector-ref attempt 3))
(define (class-provider-attempt-status-set! attempt status)
  (vector-set! attempt 3 status))
(define (class-provider-failed-attempt? state)
  (and (vector? state)
       (eq? (class-provider-attempt-status state) 'failed)))

;; Claim a provider evaluation.  A result is one of:
;;   'already-loaded | 'retry
;;   (wait . attempt)
;;   (load attempt root-owner?)
(define (class-provider-claim provider)
  (with-mutex class-provider-mu
    (let loop ((waited-evaluator? #f))
      (let ((state (hashtable-ref class-provider-states-tbl provider #f))
            (self (get-thread-id)))
        (cond
          ((eq? state 'loaded)
           (if waited-evaluator? 'retry 'already-loaded))
          ((and (vector? state)
                (eq? (class-provider-attempt-status state) 'loading))
           (if (eqv? (vector-ref state 2) self)
               'cycle
               (begin
                 (vector-set! state 5 (+ 1 (vector-ref state 5)))
                 (cons 'wait state))))
          ((and class-provider-eval-owner
                (not (eqv? class-provider-eval-owner self)))
           (condition-wait class-provider-cv class-provider-mu)
           (loop #t))
          (else
            (let ((root? (not class-provider-eval-owner)))
              (when root? (set! class-provider-eval-owner self))
              (set! class-provider-attempt-counter
                    (+ class-provider-attempt-counter 1))
              (let ((attempt
                      (vector class-provider-attempt-counter provider self
                              'loading #f 0)))
                (hashtable-set! class-provider-states-tbl provider attempt)
                (list 'load attempt root?)))))))))

(define (class-provider-finish! provider attempt root?)
  (with-mutex class-provider-mu
    (class-provider-attempt-status-set! attempt 'succeeded)
    (hashtable-set! class-provider-states-tbl provider 'loaded)
    (when root? (set! class-provider-eval-owner #f))
    (condition-broadcast class-provider-cv)))

(define (class-provider-abort! provider attempt root? error)
  (with-mutex class-provider-mu
    (vector-set! attempt 4 error)
    (class-provider-attempt-status-set! attempt 'failed)
    ;; Keep the completed attempt in the table.  Existing waiters hold this same
    ;; object and observe its error even if a later independent caller replaces
    ;; the table entry with a fresh attempt.
    (hashtable-set! class-provider-states-tbl provider attempt)
    (when root? (set! class-provider-eval-owner #f))
    (condition-broadcast class-provider-cv)))

(define (class-provider-wait-attempt attempt)
  (let ((outcome
          (with-mutex class-provider-mu
            (let loop ()
              (if (eq? (class-provider-attempt-status attempt) 'loading)
                  (begin
                    (condition-wait class-provider-cv class-provider-mu)
                    (loop))
                  (let ((status (class-provider-attempt-status attempt))
                        (error (vector-ref attempt 4)))
                    (vector-set! attempt 5 (- (vector-ref attempt 5) 1))
                    (cons status error)))))))
    (if (eq? (car outcome) 'succeeded)
        #t
        (raise (cdr outcome)))))

(define (class-provider-load-provider! provider)
  (let ((claim (class-provider-claim provider)))
    (cond
      ((eq? claim 'already-loaded) #f)
      ((eq? claim 'retry) #t)
      ((eq? claim 'cycle) (class-provider-cycle! provider))
      ((and (pair? claim) (eq? (car claim) 'wait))
       (class-provider-wait-attempt (cdr claim)))
      ((and (pair? claim) (eq? (car claim) 'load))
       (let* ((attempt (cadr claim))
              (root? (caddr claim))
              (stage (vector '() (make-hashtable string-hash string=?))))
         (guard (e (else
                     ;; load-namespace returned successfully before a commit-time
                     ;; registration failure, so its ordinary loader guard no
                     ;; longer owns the loaded mark. Remove it here; otherwise a
                     ;; later claim no-ops the namespace load and falsely marks
                     ;; this failed provider loaded.
                     (guard (ignored (else #f))
                       (ldr-unmark-loaded! provider))
                     (class-provider-abort! provider attempt root? e)
                     (raise e)))
           (parameterize
             ((class-provider-load-stack
                (cons provider (class-provider-load-stack)))
              (class-provider-registration-stage stage))
             (load-namespace provider))
           ;; Commit while this thread still owns the process-wide evaluator.
           ;; Other threads remain behind class-provider-call-stable.
           (class-provider-commit-stage! stage)
           (class-provider-finish! provider attempt root?)
           #t)))
      (else #f))))

;; Returns #t only when the caller should retry its exact lookup once.
(define (class-provider-try-load! class)
  (let ((provider (class-provider-for class)))
    (and provider (class-provider-load-provider! provider))))

;; Run a short registry read against a stable provider world.  For a mapped class,
;; another thread's entire nested evaluation graph must finish before `proc`
;; observes registrations.  PROC receives #t when CLASS has an exact provider.
(define (class-provider-call-stable class proc)
  (with-mutex class-provider-mu
    (let* ((provider (hashtable-ref class-providers-tbl class #f))
           (self (get-thread-id))
           ;; Remember the provider state at the boundary.  If this caller waits
           ;; while the active evaluation graph attempts and fails this provider,
           ;; it must observe that exact failure rather than silently starting a
           ;; second attempt and replaying the provider's top-level effects.
           (initial-state
             (and provider
                  (hashtable-ref class-provider-states-tbl provider #f)))
           ;; Attempts are mutable: abort changes a loading vector's status to
           ;; failed in place. Snapshot whether this was already a completed
           ;; failure rather than asking the same vector after the wait.
           (initial-failed-id
             (and (class-provider-failed-attempt? initial-state)
                  (vector-ref initial-state 0))))
      (if (not provider)
          (proc #f)
          (let loop ((waiting? #f))
            (if (and class-provider-eval-owner
                     (not (eqv? class-provider-eval-owner self)))
                (begin
                  (unless waiting?
                    (hashtable-set!
                      class-provider-stable-waiters class
                      (+ 1 (hashtable-ref class-provider-stable-waiters class 0))))
                  (condition-wait class-provider-cv class-provider-mu)
                  (loop #t))
                (begin
                  (when waiting?
                    (hashtable-set!
                      class-provider-stable-waiters class
                      (- (hashtable-ref class-provider-stable-waiters class 1) 1)))
                  (let ((current
                          (hashtable-ref
                            class-provider-states-tbl provider #f)))
                    (if (and waiting?
                             (class-provider-failed-attempt? current)
                             ;; An unchanged failure predating this wait remains
                             ;; retryable.  A loading/missing/older attempt that
                             ;; became this failure belongs to the graph we joined.
                             (not (and initial-failed-id
                                       (= initial-failed-id
                                          (vector-ref current 0)))))
                        (raise (vector-ref current 4))
                        (proc #t))))))))))

;; A value can carry several canonical class/interface tags.  Provider identity
;; remains exact; simple tags are ignored unless they are themselves explicitly
;; declared canonical provider keys (which validation rejects).
(define (class-provider-try-load-for-value! obj method-name)
  (let loop ((tags (value-host-tags obj)))
    (cond
      ((null? tags) #f)
      ((class-provider-for (car tags))
       (class-provider-try-load! (car tags)))
      (else (loop (cdr tags))))))

;; Operational/debug state.  This is read-only and does not wait for the
;; evaluator; tests use the waiter counts as deterministic barriers.
(define (class-provider-state class0)
  (let ((class (class-provider-name class0 "class-provider state class")))
    (with-mutex class-provider-mu
      (let* ((provider (hashtable-ref class-providers-tbl class #f))
             (state (and provider
                         (hashtable-ref class-provider-states-tbl provider #f)))
             (status (cond ((eq? state 'loaded) "loaded")
                           ((vector? state)
                            (symbol->string (class-provider-attempt-status state)))
                           (else "unloaded")))
             (attempt (if (vector? state) (vector-ref state 0) jolt-nil))
             (waiters (if (vector? state) (vector-ref state 5) 0))
             (stable (hashtable-ref class-provider-stable-waiters class 0)))
        (jolt-hash-map
          (keyword #f "class") class
          (keyword #f "provider") (or provider jolt-nil)
          (keyword #f "state") (keyword #f status)
          (keyword #f "attempt") attempt
          (keyword #f "waiters") waiters
          (keyword #f "stable-waiters") stable)))))
