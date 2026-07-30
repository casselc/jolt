;; class-providers.ss — the class-provider registry and evaluation coordinator.
;;
;; A provider maps a canonical Java class name to the namespace that owns its
;; host interop (constructors, statics, instance? tags). This file owns the
;; exact canonical-class -> provider-namespace registry and the serialized
;; provider-namespace evaluation state machine shared by every later dispatch
;; site.
;;
;; The evaluator is deliberately not wired to constructor/static/member misses
;; yet. Calls through the dedicated provider-registration hooks are staged during
;; namespace evaluation, published only after successful evaluation, and rolled
;; back as one covered registration transaction if publication fails. Ordinary
;; namespace definitions (including type/protocol forms) and arbitrary
;; application side effects are outside this boundary. Exact retry-on-miss
;; dispatch lands only after the boundary is independently gated.
;;
;; Invariants:
;;   - a class key is a canonical Java name: it contains a dot, has no leading,
;;     trailing, or double dot, and contains no slash;
;;   - a provider token is a nonblank string (a namespace name);
;;   - register-many! is preflighted: every declaration is normalized, validated,
;;     and conflict-checked BEFORE any mutation, so a rejected batch leaves no
;;     partial prefix of mappings behind;
;;   - an identical re-declaration is idempotent (no error, no generation bump);
;;   - a conflicting declaration (same class, different provider) raises
;;     :jolt.deps/class-provider-conflict and changes nothing;
;;   - once frozen, no NEW class key may enter; identical re-declarations remain
;;     harmless, and reset-many! thaws the registry;
;;   - at most one thread owns a provider evaluation graph process-wide;
;;   - that owner may recursively evaluate a different provider, while every
;;     other thread waits;
;;   - owner re-entry into a provider already loading on its stack is a bounded
;;     structured cycle error;
;;   - callers waiting on one attempt observe that exact success or failure;
;;     only a later independent caller may replace a failed attempt and retry;
;;   - dedicated Clojure-visible provider-registration hooks append mutations
;;     to an owner-thread, namespace-local stage instead of publishing during
;;     namespace evaluation;
;;   - an ordinary helper namespace required by a provider commits its own
;;     registrations before returning, so a later provider-root failure cannot
;;     leave the helper marked loaded with its registrations discarded;
;;   - a forked child cannot mutate its parent's active or aborted private stage;
;;     a child of a committed stage falls back to ordinary registration only
;;     after the complete evaluation graph is stable;
;;   - one accumulated mapping batch publishes first, then host operations
;;     preserve source order; a commit-time exception restores every mutable
;;     registry reachable through those hooks;
;;   - ordinary calls through the same dedicated hooks wait for the active
;;     evaluation graph, so rollback cannot erase one of those unrelated
;;     concurrent mutations;
;;   - raw mutators for every snapshotted host registry use the same serialized
;;     write boundary. Provider-owner raw definition effects remain deliberately
;;     outside the stage, but an unrelated writer cannot race a rollback.
;;
;; This unwired slice proves failure atomicity for the covered writes. Covered
;; readers do not yet join class-provider-mu, so concurrent reader isolation is
;; still a hard prerequisite for activating retry-on-miss dispatch. Activation
;; must also reject or otherwise make nonblocking a provider load triggered by a
;; child that inherited an active stage, because its parent may be joining that
;; child.
;;
;; Structured failures are raised as jolt ex-info whose ex-data carries a
;; :type keyword naming the category:
;;   :jolt.deps/invalid-class-provider        malformed class/provider token
;;   :jolt.deps/class-provider-conflict        same class, differing provider
;;   :jolt.deps/class-provider-registry-frozen a new key after freeze
;;   :jolt.deps/class-provider-cycle           owner re-entry while loading
;;   :jolt.deps/class-provider-cross-thread-registration
;;                                                forked child registration
;;
;; Loaded after the value/collection/error layers of rt.ss (it needs jolt-throw,
;; jolt-ex-info, jolt-hash-map, keyword, and the symbol accessors) and sits in
;; the host java/ class layer beside class-hierarchy.ss.

;; --- registry state ---------------------------------------------------------
;; canonical-class-string -> provider-namespace-string. Mutation only under the
;; mutex so reads (class-provider-for/mappings/namespaces) see a consistent table.
(define class-providers-tbl (make-hashtable string-hash string=?))
(define class-provider-mu (make-mutex))
;; provider namespace -> 'loaded | attempt vector. An attempt is
;; [id provider owner status error waiter-count], where status is loading,
;; succeeded, or failed. Failed attempts remain reachable by their waiters; a
;; later independent claim replaces the table entry with a fresh attempt.
(define class-provider-states-tbl (make-hashtable string-hash string=?))
(define class-provider-cv (make-condition))
;; One process-wide evaluation graph. The owner may nest provider loads on the
;; same thread; a different thread waits for the complete outer graph.
(define class-provider-eval-owner #f)
(define class-provider-attempt-counter 0)
(define class-provider-global-waiters 0)
(define class-provider-load-stack (make-thread-parameter '()))
;; A provider stage is
;; [reverse-ordered operations, pending provider mappings, owner thread id,
;;  exact namespace, active | committed | aborted].
;; Chez thread parameters are inherited by forked threads, so the explicit owner
;; prevents a child from mutating its parent's private stage. Ordinary required
;; namespaces and nested providers shadow the outer stage and publish
;; independently; this keeps each loader dedup mark coherent with the
;; registrations produced by that exact namespace.
(define class-provider-registration-stage (make-thread-parameter #f))
(define class-provider-registration-world-lock-held?
  (make-thread-parameter #f))
(define cp-stage-operations-index 0)
(define cp-stage-mappings-index 1)
(define cp-stage-owner-index 2)
(define cp-stage-namespace-index 3)
(define cp-stage-state-index 4)
;; Bumped when registration adds keys and once for every successful reset; never
;; decrements. A reset is an explicit world boundary even if its map is identical.
(define class-provider-registry-generation 0)
;; Closed-world boundary: once #t, register-many! rejects any NEW class key.
;; Identical re-declarations stay idempotent; reset-many! clears it.
(define class-provider-frozen? #f)

;; --- error category keywords + ex-data field keys ---------------------------
(define cp-type-invalid (keyword "jolt.deps" "invalid-class-provider"))
(define cp-type-conflict (keyword "jolt.deps" "class-provider-conflict"))
(define cp-type-frozen (keyword "jolt.deps" "class-provider-registry-frozen"))
(define cp-type-cycle (keyword "jolt.deps" "class-provider-cycle"))
(define cp-type-cross-thread
  (keyword "jolt.deps" "class-provider-cross-thread-registration"))
(define cp-kw-type (keyword #f "type"))
(define cp-kw-class (keyword #f "class"))
(define cp-kw-provider (keyword #f "provider"))
(define cp-kw-existing (keyword #f "existing-provider"))
(define cp-kw-new (keyword #f "new-provider"))
(define cp-kw-reason (keyword #f "reason"))
(define cp-kw-generation (keyword #f "registry-generation"))
(define cp-kw-path (keyword #f "path"))
(define cp-kw-namespace (keyword #f "namespace"))
(define cp-kw-owner-thread (keyword #f "owner-thread"))
(define cp-kw-current-thread (keyword #f "current-thread"))
(define cp-kw-stage-state (keyword #f "stage-state"))

(define (cp-invalid! class provider reason)
  (jolt-throw
    (jolt-ex-info
      (string-append "Invalid class-provider declaration: " reason)
      (jolt-hash-map
        cp-kw-type cp-type-invalid
        cp-kw-class (or class jolt-nil)
        cp-kw-provider (or provider jolt-nil)
        cp-kw-reason reason))))

(define (cp-conflict! class existing provider)
  (jolt-throw
    (jolt-ex-info
      (string-append "Class-provider conflict for " class
                     ": existing provider " existing
                     ", new provider " provider)
      (jolt-hash-map
        cp-kw-type cp-type-conflict
        cp-kw-class class
        cp-kw-existing existing
        cp-kw-new provider))))

(define (cp-frozen! class provider)
  (jolt-throw
    (jolt-ex-info
      (string-append "Class-provider registry is frozen; declare " class
                     " in resolved deps.edn metadata")
      (jolt-hash-map
        cp-kw-type cp-type-frozen
        cp-kw-class class
        cp-kw-provider provider
        cp-kw-generation class-provider-registry-generation))))

(define (cp-cycle! provider)
  (let ((path (reverse (cons provider (class-provider-load-stack)))))
    (jolt-throw
      (jolt-ex-info
        (string-append
          "Re-entrant class-provider load: "
          (let loop ((xs path) (out ""))
            (cond
              ((null? xs) out)
              ((string=? out "") (loop (cdr xs) (car xs)))
              (else
                (loop (cdr xs) (string-append out " -> " (car xs)))))))
        (jolt-hash-map
          cp-kw-type cp-type-cycle
          cp-kw-provider provider
          cp-kw-path (list->cseq path))))))

(define (cp-cross-thread-registration! stage)
  (let ((owner (vector-ref stage cp-stage-owner-index))
        (current (get-thread-id))
        (namespace (vector-ref stage cp-stage-namespace-index))
        (state (vector-ref stage cp-stage-state-index)))
    (jolt-throw
      (jolt-ex-info
        (string-append
          "Provider registration from a forked thread is not allowed for "
          namespace " while its stage is "
          (symbol->string state))
        (jolt-hash-map
          cp-kw-type cp-type-cross-thread
          cp-kw-namespace namespace
          cp-kw-owner-thread owner
          cp-kw-current-thread current
          cp-kw-stage-state state)))))

;; --- normalization ----------------------------------------------------------
;; Accept a string or a (jolt) symbol and reduce it to its canonical string
;; spelling. A bare symbol yields its name; a namespaced symbol yields "ns/name".
;; Returns #f for any other type so the caller can fail structured.
(define (cp-normalize-token x)
  (cond
    ((string? x) x)
    ((jolt-symbol? x)
     (let ((ns (symbol-t-ns x)) (nm (symbol-t-name x)))
       (if (or (jolt-nil? ns) (not ns) (eq? ns '()))
           nm
           (string-append ns "/" nm))))
    (else #f)))

(define (cp-string-contains-char? s ch)
  (let loop ((i 0) (n (string-length s)))
    (cond ((fx=? i n) #f)
          ((char=? (string-ref s i) ch) #t)
          (else (loop (fx+ i 1) n)))))

(define (cp-string-contains-substr? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (if (fx>? m n) #f
        (let loop ((i 0))
          (cond ((fx>? (fx+ i m) n) #f)
                ((string=? (substring s i (fx+ i m)) sub) #t)
                (else (loop (fx+ i 1))))))))

;; Canonical Java class name: nonempty, contains a dot, no leading/trailing/double
;; dot, no slash. A provider key MUST be canonical so lookups, hierarchy grafts,
;; and the frozen-map emit all agree on one spelling.
(define (cp-canonical-class-string? s)
  (and (string? s)
       (not (string=? s ""))
       (cp-string-contains-char? s #\.)
       (not (char=? (string-ref s 0) #\.))
       (not (char=? (string-ref s (fx- (string-length s) 1)) #\.))
       (not (cp-string-contains-char? s #\/))
       (not (cp-string-contains-substr? s ".."))))

;; Provider token: a nonblank string (at least one non-whitespace char). It is a
;; namespace name, so dots are fine; only emptiness/all-whitespace is rejected.
(define (cp-nonblank-string? s)
  (and (string? s)
       (let loop ((i 0) (n (string-length s)))
         (cond ((fx=? i n) #f)
               ((not (char-whitespace? (string-ref s i))) #t)
               (else (loop (fx+ i 1) n))))))

;; Normalize AND validate every (class . provider) pair. Pure: never touches the
;; shared table, so raising partway through leaves no trace. Returns the list of
;; validated (class-string . provider-string) Scheme pairs.
(define (cp-normalize-and-validate-pairs pairs)
  (map
    (lambda (p)
      (cond
        ((not (pair? p))
         (cp-invalid! #f #f "each mapping must be a (class . provider) pair"))
        (else
         (let* ((raw-class (car p))
                (raw-provider (cdr p))
                (class (cp-normalize-token raw-class))
                (provider (cp-normalize-token raw-provider)))
           (cond
             ((not class)
              (cp-invalid! raw-class provider
                           "class must be a string or symbol"))
             ((not provider)
              (cp-invalid! class raw-provider
                           "provider must be a string or symbol"))
             ((not (cp-canonical-class-string? class))
              (cp-invalid! class provider
                           (string-append
                             "class must be a canonical Java name: "
                             "requires a dot, no leading/trailing/double dot, "
                             "no slash")))
             ((not (cp-nonblank-string? provider))
              (cp-invalid! class provider
                           "provider must be a nonblank token"))
             (else (cons class provider)))))))
    pairs))

;; Wait until a different thread's entire provider-evaluation graph is stable.
;; The owner itself must pass through so a nested provider can claim work and
;; publish its staged commit.
(define (class-provider-wait-evaluator-locked! self)
  (let loop ()
    (when (and class-provider-eval-owner
               (not (eqv? class-provider-eval-owner self)))
      (set! class-provider-global-waiters
            (+ class-provider-global-waiters 1))
      (condition-wait class-provider-cv class-provider-mu)
      (set! class-provider-global-waiters
            (- class-provider-global-waiters 1))
      (loop))))

;; --- atomic preflighted registration ----------------------------------------
;; Build the genuinely new portion of NORMALIZED while the provider mutex is
;; held. PENDING is either the current evaluation stage's private mapping table
;; or #f. The private BATCH makes a caught conflict/freeze a true no-op: no prefix
;; reaches PENDING or the live table.
(define (cp-preflight-new-mappings-locked normalized pending)
  (let ((batch (make-hashtable string-hash string=?)))
    (for-each
      (lambda (p)
        (let* ((class (car p))
               (provider (cdr p))
               (old
                 (or (hashtable-ref batch class #f)
                     (and pending (hashtable-ref pending class #f))
                     (hashtable-ref class-providers-tbl class #f))))
          (cond
            ((not old)
             (when class-provider-frozen?
               (cp-frozen! class provider))
             (hashtable-set! batch class provider))
            ((string=? old provider) #f)
            (else (cp-conflict! class old provider)))))
      normalized)
    batch))

(define (cp-merge-string-table! target additions)
  (let-values (((ks vs) (hashtable-entries additions)))
    (let loop ((i 0) (n (vector-length ks)))
      (when (fx<? i n)
        (hashtable-set! target (vector-ref ks i) (vector-ref vs i))
        (loop (fx+ i 1) n)))))

;; Publish one normalized batch. The caller owns class-provider-mu. A batch is
;; one registry generation even when it adds several keys, preserving the
;; current v0.5.11 registry contract.
(define (cp-publish-normalized-mappings-locked! normalized)
  (let ((batch (cp-preflight-new-mappings-locked normalized #f)))
    (unless (fx=? (hashtable-size batch) 0)
      (cp-merge-string-table! class-providers-tbl batch)
      (set! class-provider-registry-generation
            (+ class-provider-registry-generation 1)))))

;; Whole-map registration is atomic both outside and inside provider evaluation.
;; A provider stage accumulates only its effective new mappings; successful
;; publication treats that private map as one transaction generation.
(define (class-provider-register-many! pairs)
  (let* ((stage (class-provider-registration-stage-for-hook))
         (normalized (cp-normalize-and-validate-pairs pairs)))
    (if stage
        (with-mutex class-provider-mu
          (let* ((pending (vector-ref stage cp-stage-mappings-index))
                 (batch
                   (cp-preflight-new-mappings-locked normalized pending)))
            (cp-merge-string-table! pending batch)))
        (with-mutex class-provider-mu
          (class-provider-wait-evaluator-locked! (get-thread-id))
          (cp-publish-normalized-mappings-locked! normalized)))
    jolt-nil))

;; Atomically replace the registry and thaw it. Build and conflict-check the
;; replacement before taking the mutex so a rejected reset leaves the current
;; map, frozen state, and generation untouched.
(define (class-provider-reset-many! pairs)
  (let ((normalized (cp-normalize-and-validate-pairs pairs))
        (replacement (make-hashtable string-hash string=?)))
    (for-each
      (lambda (p)
        (let* ((class (car p))
               (provider (cdr p))
               (old (hashtable-ref replacement class #f)))
          (cond
            ((not old) (hashtable-set! replacement class provider))
            ((string=? old provider) #f)
            (else (cp-conflict! class old provider)))))
      normalized)
    (with-mutex class-provider-mu
      (class-provider-wait-evaluator-locked! (get-thread-id))
      (set! class-providers-tbl replacement)
      (set! class-provider-states-tbl
            (make-hashtable string-hash string=?))
      (set! class-provider-frozen? #f)
      (set! class-provider-registry-generation
            (+ class-provider-registry-generation 1))))
  jolt-nil)

;; Close the provider world around a resolved dependency graph. Identical
;; re-declarations remain idempotent; a NEW class key after this raises
;; :jolt.deps/class-provider-registry-frozen. reset-many! reopens the world.
(define (class-provider-freeze!)
  (with-mutex class-provider-mu
    (class-provider-wait-evaluator-locked! (get-thread-id))
    (set! class-provider-frozen? #t))
  jolt-nil)

;; --- failure-atomic dedicated-hook publication ------------------------------
(define (class-provider-make-registration-stage namespace)
  (vector
    '()
    (make-hashtable string-hash string=?)
    (get-thread-id)
    namespace
    'active))

(define (class-provider-registration-stage-active? stage)
  (eq? (vector-ref stage cp-stage-state-index) 'active))

(define (class-provider-registration-stage-state-set! stage state)
  (vector-set! stage cp-stage-state-index state))

;; Forked children retain their inherited stage vector. Keep only the small
;; ownership/provenance fields after completion; otherwise a long-lived worker
;; would pin every staged closure and pending mapping.
(define (class-provider-registration-stage-finalize! stage state)
  (class-provider-registration-stage-state-set! stage state)
  (vector-set! stage cp-stage-operations-index '())
  (vector-set! stage cp-stage-mappings-index #f))

;; Return the active stage only to its owning thread. A forked child inherits
;; the thread parameter value but must not mutate it.
(define (class-provider-owned-registration-stage)
  (let ((stage (class-provider-registration-stage)))
    (and stage
         (class-provider-registration-stage-active? stage)
         (eqv? (vector-ref stage cp-stage-owner-index) (get-thread-id))
         stage)))

;; Registration from a forked child must fail immediately. Treating it as an
;; ordinary external mutation could deadlock when the provider joins the child,
;; or publish work caused by a provider that later fails.
(define (class-provider-registration-stage-for-hook)
  (let ((stage (class-provider-registration-stage)))
    (cond
      ((not stage) #f)
      ((and
         (class-provider-registration-stage-active? stage)
         (eqv? (vector-ref stage cp-stage-owner-index) (get-thread-id)))
       stage)
      ((eq? (vector-ref stage cp-stage-state-index) 'committed)
       ;; A helper can commit while its outer provider graph is still active.
       ;; Its child must not fall through to a blocking ordinary registration
       ;; that the outer owner might join.
       (if
         (with-mutex class-provider-mu
           (and class-provider-eval-owner
                (not
                  (eqv? class-provider-eval-owner (get-thread-id)))))
         (cp-cross-thread-registration! stage)
         #f))
      (else (cp-cross-thread-registration! stage)))))

;; Append one provider-owned mutation to the current evaluation stage. Returns
;; #t when staged and #f for an ordinary call outside provider evaluation.
(define (class-provider-stage-operation! proc)
  (let ((stage (class-provider-registration-stage-for-hook)))
    (and stage
         (begin
           (vector-set!
             stage
             cp-stage-operations-index
             (cons proc (vector-ref stage cp-stage-operations-index)))
           #t))))

;; Ordinary calls through the covered hooks must not race a provider transaction:
;; otherwise rollback could restore an older snapshot over an unrelated
;; successful mutation. The operation stays under the coordinator mutex from the
;; stable check through publication, so a provider cannot claim between them.
(define (class-provider-run-serialized-registration! proc)
  (if (class-provider-registration-world-lock-held?)
      (proc)
      (with-mutex class-provider-mu
        (class-provider-wait-evaluator-locked! (get-thread-id))
        (parameterize ((class-provider-registration-world-lock-held? #t))
          (proc)))))

(define (class-provider-run-operation! proc)
  (class-provider-run-serialized-registration! proc))

;; Runtime definition forms and host bootstrap code also call the underlying
;; registry mutators directly. They remain outside the provider stage so an
;; owning provider retains its historical immediate definition behavior, but
;; they share the evaluator's write boundary. Checking the inherited stage first
;; preserves the dedicated-hook fail-closed rule for a forked child instead of
;; letting a parent/child join become a mutex wait cycle.
(define (class-provider-run-raw-registration! proc)
  (class-provider-registration-stage-for-hook)
  (class-provider-run-serialized-registration! proc))

;; Shared adapter for the dedicated Clojure-visible hooks. The raw mutation PROC
;; is staged for a provider and otherwise executes against a stable covered
;; registration world.
(define (class-provider-register-operation! proc)
  (unless (class-provider-stage-operation! proc)
    (class-provider-run-operation! proc))
  jolt-nil)

;; The value, printer, comparison, and class-hierarchy mutators are defined
;; before this coordinator loads. Install their raw-write adapters now; all
;; later bootstrap registrations and runtime definition forms therefore share
;; the rollback write boundary. Composite mutators such as register-pr-arm! may
;; call another wrapped mutator while the thread parameter is set and execute
;; directly without reacquiring the nonrecursive mutex.
(define (class-provider-wrap-raw-registration proc)
  (lambda args
    (class-provider-run-raw-registration!
      (lambda () (apply proc args)))))

(set! register-eq-arm!
  (class-provider-wrap-raw-registration register-eq-arm!))
(set! register-hash-arm!
  (class-provider-wrap-raw-registration register-hash-arm!))
(set! register-str-render!
  (class-provider-wrap-raw-registration register-str-render!))
(set! register-pr-str-arm!
  (class-provider-wrap-raw-registration register-pr-str-arm!))
(set! register-pr-readable-arm!
  (class-provider-wrap-raw-registration register-pr-readable-arm!))
(set! register-pr-arm!
  (class-provider-wrap-raw-registration register-pr-arm!))
(set! register-compare-arm!
  (class-provider-wrap-raw-registration register-compare-arm!))
(set! jch-register-supers!
  (class-provider-wrap-raw-registration jch-register-supers!))
(set! jch-set-supers!
  (class-provider-wrap-raw-registration jch-set-supers!))

(define (class-provider-copy-string-table table copy-value)
  (let ((result (make-hashtable string-hash string=?)))
    (let-values (((keys vals) (hashtable-entries table)))
      (let loop ((i 0) (n (vector-length keys)))
        (when (fx<? i n)
          (hashtable-set!
            result
            (vector-ref keys i)
            (copy-value (vector-ref vals i)))
          (loop (fx+ i 1) n))))
    result))

;; Copy a string table whose values are string tables. Preserve shared inner
;; identity: core's historic short/FQN aliases intentionally point at one member
;; table, and rollback must not split them.
(define (class-provider-copy-nested-string-table table copy-leaf)
  (let ((result (make-hashtable string-hash string=?))
        (seen (make-eq-hashtable)))
    (let-values (((keys vals) (hashtable-entries table)))
      (let loop ((i 0) (n (vector-length keys)))
        (when (fx<? i n)
          (let* ((key (vector-ref keys i))
                 (inner (vector-ref vals i))
                 (copy
                   (or (hashtable-ref seen inner #f)
                       (let ((new
                               (class-provider-copy-string-table
                                 inner copy-leaf)))
                         (hashtable-set! seen inner new)
                         new))))
            (hashtable-set! result key copy))
          (loop (fx+ i 1) n))))
    result))

(define (class-provider-copy-vector value)
  (list->vector (vector->list value)))

;; Named fields make the rollback coverage auditable as registries evolve.
(define-record-type cp-world-snapshot
  (fields
    provider-table
    provider-generation
    provider-frozen
    class-statics
    class-ctors
    mutable-statics
    tagged-methods
    class-hierarchy
    user-instance-checks
    eq-arms
    hash-arms
    str-arms
    pr-str-arms
    pr-readable-arms
    compare-arms
    class-arms
    value-tag-arms)
  (nongenerative jolt-class-provider-world-snapshot-v1))

;; Snapshot exactly the mutable registries reachable through the dedicated
;; provider-registration hooks. Vars, type/record/protocol definitions, extend
;; state, and arbitrary provider top-level side effects remain outside the
;; transaction. The caller owns class-provider-mu.
(define (class-provider-world-snapshot-locked)
  (make-cp-world-snapshot
    (class-provider-copy-string-table
      class-providers-tbl (lambda (x) x))
    class-provider-registry-generation
    class-provider-frozen?
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
    jt-user-value-tags-arms))

;; Restore a failed commit while class-provider-mu is held. Hierarchy caches are
;; derived rather than snapshotted; invalidating all four classes of cache makes
;; the restored graph authoritative again.
(define (class-provider-world-restore-locked! snapshot)
  (set! class-providers-tbl
        (cp-world-snapshot-provider-table snapshot))
  (set! class-provider-registry-generation
        (cp-world-snapshot-provider-generation snapshot))
  (set! class-provider-frozen?
        (cp-world-snapshot-provider-frozen snapshot))
  (set! class-statics-tbl
        (cp-world-snapshot-class-statics snapshot))
  (set! class-ctors-tbl
        (cp-world-snapshot-class-ctors snapshot))
  (set! mutable-statics-tbl
        (cp-world-snapshot-mutable-statics snapshot))
  (set! tagged-methods-tbl
        (cp-world-snapshot-tagged-methods snapshot))
  (set! jvm-class-parents
        (cp-world-snapshot-class-hierarchy snapshot))
  (set! user-instance-checks
        (cp-world-snapshot-user-instance-checks snapshot))
  (set! jolt-eq-arms (cp-world-snapshot-eq-arms snapshot))
  (set! jolt-hash-arms (cp-world-snapshot-hash-arms snapshot))
  (set! str-render-registry (cp-world-snapshot-str-arms snapshot))
  (set! jolt-pr-str-arms (cp-world-snapshot-pr-str-arms snapshot))
  (set! jolt-pr-readable-arms
        (cp-world-snapshot-pr-readable-arms snapshot))
  (set! jolt-compare-arms (cp-world-snapshot-compare-arms snapshot))
  (set! jolt-class-arms (cp-world-snapshot-class-arms snapshot))
  (set! jt-user-value-tags-arms
        (cp-world-snapshot-value-tag-arms snapshot))
  (jch-invalidate-caches!))

;; Publish one successful provider namespace. Pending mappings go first, then
;; host operations in source order. A commit-time exception restores the entire
;; covered registration world before it escapes to the evaluator.
(define (class-provider-commit-stage! stage)
  (with-mutex class-provider-mu
    (parameterize ((class-provider-registration-world-lock-held? #t))
      (let ((snapshot (class-provider-world-snapshot-locked)))
        (guard (e (else
                    (class-provider-world-restore-locked! snapshot)
                    (raise e)))
          (let ((pending (vector-ref stage cp-stage-mappings-index)))
            (unless (fx=? (hashtable-size pending) 0)
              (let-values (((keys vals) (hashtable-entries pending)))
                (cp-publish-normalized-mappings-locked!
                  (let loop ((i 0) (acc '()))
                    (if (fx=? i (vector-length keys))
                        (reverse acc)
                        (loop
                          (fx+ i 1)
                          (cons
                            (cons (vector-ref keys i) (vector-ref vals i))
                            acc))))))))
          (for-each
            (lambda (proc) (proc))
            (reverse (vector-ref stage cp-stage-operations-index))))))))

;; LOAD! evaluates one namespace inside an active provider graph. Reuse the
;; provider-created stage only for that exact provider root. An ordinary helper
;; gets a private shadow stage and commits before its loader call returns, so its
;; successful dedup mark and registrations cannot be split by a later outer
;; failure. CLEANUP! restores the helper's pre-call loaded state if either source
;; evaluation or staged publication fails.
(define (class-provider-load-namespace-with-stage!
          namespace load! cleanup!)
  (let ((outer (class-provider-owned-registration-stage)))
    (cond
      ((not outer) (load!))
      ((string=?
         namespace
         (vector-ref outer cp-stage-namespace-index))
       (load!))
      (else
        (let ((stage (class-provider-make-registration-stage namespace)))
          (guard (e (else
                      (class-provider-registration-stage-state-set!
                        stage 'aborted)
                      (guard (ignored (else #f))
                        (cleanup! namespace stage))
                      (class-provider-registration-stage-finalize!
                        stage 'aborted)
                      (raise e)))
            (parameterize ((class-provider-registration-stage stage))
              (load!))
            (class-provider-commit-stage! stage)
            (class-provider-registration-stage-finalize!
              stage 'committed)))))))

;; --- readers ----------------------------------------------------------------
;; Exact lookup: the provider string for CLASS, or jolt-nil when absent. No class
;; hierarchy walk — direct table hit only, so two same-simple-name provider
;; classes never shadow one another.
(define (class-provider-for class)
  (let ((c (cp-normalize-token class)))
    (if (not c)
        jolt-nil
        (with-mutex class-provider-mu
          (or (hashtable-ref class-providers-tbl c #f) jolt-nil)))))

;; All mappings as a list of (class . provider) Scheme pairs, sorted by class.
;; Deterministic across runs regardless of the table's HAMT iteration order.
(define (class-provider-mappings)
  (with-mutex class-provider-mu
    (let-values (((ks vs) (hashtable-entries class-providers-tbl)))
      (let loop ((i 0) (n (vector-length ks)) (acc '()))
        (if (fx=? i n)
            (list-sort (lambda (a b) (string<? (car a) (car b))) acc)
            (loop (fx+ i 1) n
                  (cons (cons (vector-ref ks i) (vector-ref vs i)) acc)))))))

;; Distinct provider namespaces, sorted and deduplicated.
(define (class-provider-namespaces)
  (with-mutex class-provider-mu
    (let-values (((ks vs) (hashtable-entries class-providers-tbl)))
      (let loop ((i 0) (n (vector-length vs))
                 (seen (make-hashtable string-hash string=?)))
        (if (fx=? i n)
            (list-sort string<? (vector->list (hashtable-keys seen)))
            (begin
              (hashtable-set! seen (vector-ref vs i) #t)
              (loop (fx+ i 1) n seen)))))))

;; The current generation counter (monotonic across register/reset).
(define (class-provider-generation)
  (with-mutex class-provider-mu
    class-provider-registry-generation))

;; --- serialized provider evaluation -----------------------------------------
;; Attempt vector slots. Named accessors keep the state machine auditable and
;; make it harder for a later diagnostic to read the wrong mutable field.
(define cp-attempt-id-index 0)
(define cp-attempt-provider-index 1)
(define cp-attempt-owner-index 2)
(define cp-attempt-status-index 3)
(define cp-attempt-error-index 4)
(define cp-attempt-waiters-index 5)

(define (cp-attempt-status attempt)
  (vector-ref attempt cp-attempt-status-index))
(define (cp-attempt-status-set! attempt status)
  (vector-set! attempt cp-attempt-status-index status))
(define (cp-attempt-failed? state)
  (and (vector? state) (eq? (cp-attempt-status state) 'failed)))

;; Claim one provider evaluation. Results:
;;   already-loaded              provider completed before this call
;;   retry                       caller waited for another graph that loaded it
;;   cycle                       this owner re-entered its active provider
;;   (wait . attempt)            wait for this exact active attempt
;;   (failed . attempt)          graph joined by this caller failed this provider
;;   (load attempt root-owner?)  this thread owns a fresh attempt
(define (class-provider-claim provider)
  (with-mutex class-provider-mu
    (let* ((initial-state
             (hashtable-ref class-provider-states-tbl provider #f))
           (initial-failed-id
             (and (cp-attempt-failed? initial-state)
                  (vector-ref initial-state cp-attempt-id-index))))
      (let loop ((waited-evaluator? #f))
        (let ((state
                (hashtable-ref class-provider-states-tbl provider #f))
              (self (get-thread-id)))
          (cond
            ;; A caller joining this exact in-flight attempt keeps the attempt
            ;; object, so a later retry cannot replace the error it must observe.
            ((and (vector? state)
                  (eq? (cp-attempt-status state) 'loading))
             (if (eqv? (vector-ref state cp-attempt-owner-index) self)
                 'cycle
                 (begin
                   (vector-set!
                     state cp-attempt-waiters-index
                     (+ 1 (vector-ref state cp-attempt-waiters-index)))
                   (cons 'wait state))))

            ;; A different provider may be active in the same outer evaluation
            ;; graph. Wait for the whole graph, not merely one nested namespace.
            ((and class-provider-eval-owner
                  (not (eqv? class-provider-eval-owner self)))
             (set! class-provider-global-waiters
                   (+ class-provider-global-waiters 1))
             (condition-wait class-provider-cv class-provider-mu)
             (set! class-provider-global-waiters
                   (- class-provider-global-waiters 1))
             (loop #t))

            ((eq? state 'loaded)
             (if waited-evaluator? 'retry 'already-loaded))

            ;; If the graph this caller joined attempted and failed its provider,
            ;; share that exact failure. An unchanged failure that predates the
            ;; wait remains independently retryable.
            ((and waited-evaluator?
                  (cp-attempt-failed? state)
                  (not (and initial-failed-id
                            (= initial-failed-id
                               (vector-ref state cp-attempt-id-index)))))
             (cons 'failed state))

            (else
              (let ((root? (not class-provider-eval-owner)))
                (when root? (set! class-provider-eval-owner self))
                (set! class-provider-attempt-counter
                      (+ class-provider-attempt-counter 1))
                (let ((attempt
                        (vector
                          class-provider-attempt-counter
                          provider
                          self
                          'loading
                          #f
                          0)))
                  (hashtable-set!
                    class-provider-states-tbl provider attempt)
                  (list 'load attempt root?))))))))))

(define (class-provider-finish! provider attempt root? stage)
  (with-mutex class-provider-mu
    (cp-attempt-status-set! attempt 'succeeded)
    (hashtable-set! class-provider-states-tbl provider 'loaded)
    (when root? (set! class-provider-eval-owner #f))
    (class-provider-registration-stage-finalize! stage 'committed)
    (condition-broadcast class-provider-cv)))

(define (class-provider-abort! provider attempt root? error stage)
  (with-mutex class-provider-mu
    (vector-set! attempt cp-attempt-error-index error)
    (cp-attempt-status-set! attempt 'failed)
    (hashtable-set! class-provider-states-tbl provider attempt)
    (when root? (set! class-provider-eval-owner #f))
    (class-provider-registration-stage-finalize! stage 'aborted)
    (condition-broadcast class-provider-cv)))

(define (class-provider-wait-attempt attempt)
  (let ((outcome
          (with-mutex class-provider-mu
            (let loop ()
              (if (eq? (cp-attempt-status attempt) 'loading)
                  (begin
                    (condition-wait class-provider-cv class-provider-mu)
                    (loop))
                  (begin
                    ;; A nested provider can finish while its outer provider is
                    ;; still evaluating. Do not expose that half-stable graph.
                    (class-provider-wait-evaluator-locked! (get-thread-id))
                    (let ((status (cp-attempt-status attempt))
                          (error
                            (vector-ref attempt cp-attempt-error-index)))
                      (vector-set!
                        attempt cp-attempt-waiters-index
                        (- (vector-ref attempt cp-attempt-waiters-index) 1))
                      (cons status error))))))))
    (if (eq? (car outcome) 'succeeded)
        #t
        (raise (cdr outcome)))))

;; Evaluate PROVIDER with LOAD!, which receives the provider namespace string.
;; CLEANUP! receives the provider and its stage. The production loader reopens
;; the provider root when namespace evaluation returned successfully but its
;; staged publication then failed.
(define (class-provider-load-provider-with-cleanup!
          provider load! cleanup!)
  (let ((claim (class-provider-claim provider)))
    (cond
      ((eq? claim 'already-loaded) #f)
      ((eq? claim 'retry) #t)
      ((eq? claim 'cycle) (cp-cycle! provider))
      ((and (pair? claim) (eq? (car claim) 'wait))
       (class-provider-wait-attempt (cdr claim)))
      ((and (pair? claim) (eq? (car claim) 'failed))
       (raise
         (vector-ref (cdr claim) cp-attempt-error-index)))
      ((and (pair? claim) (eq? (car claim) 'load))
       (let ((attempt (cadr claim))
             (root? (caddr claim))
             (stage (class-provider-make-registration-stage provider)))
         (guard (e (else
                     ;; load-namespace clears its own mark on a source exception.
                     ;; A provider-root commit exception occurs after its normal
                     ;; return, so restore the root's pre-call loaded state for a
                     ;; later independent provider retry.
                     (guard (ignored (else #f))
                       (cleanup! provider stage))
                     (class-provider-abort!
                       provider attempt root? e stage)
                     (raise e)))
           (parameterize
             ((class-provider-load-stack
                (cons provider (class-provider-load-stack)))
              (class-provider-registration-stage stage))
             (load! provider))
           ;; Publish while this thread still owns the process-wide evaluator.
           ;; Another provider may be nested inside an outer stage; commit uses
           ;; raw locked publication so the inner transaction cannot be
           ;; accidentally appended to that outer stage.
           (class-provider-commit-stage! stage)
           (class-provider-finish! provider attempt root? stage)
           #t)))
      (else #f))))

;; Test seam: the direct coordinator/transaction gates provide a loader closure
;; without needing to model loader.ss's loaded-namespace bookkeeping.
(define (class-provider-load-provider-with! provider load!)
  (class-provider-load-provider-with-cleanup!
    provider load! (lambda (_ __) #f)))

(define (class-provider-load-provider! provider)
  (class-provider-load-provider-with-cleanup!
    provider
    (lambda (namespace) (load-namespace namespace))
    (lambda (namespace _stage)
      (ldr-unmark-loaded! namespace))))

;; Exact class lookup followed by one coordinated provider evaluation. This is
;; intentionally not called by host dispatch yet.
(define (class-provider-try-load-with! class load!)
  (let ((provider (class-provider-for class)))
    (and (not (jolt-nil? provider))
         (class-provider-load-provider-with! provider load!))))
(define (class-provider-try-load! class)
  (let ((provider (class-provider-for class)))
    (and (not (jolt-nil? provider))
         (class-provider-load-provider! provider))))

;; Read-only Scheme diagnostics used by the direct state-machine gate.
(define (class-provider-provider-status provider)
  (with-mutex class-provider-mu
    (let ((state
            (hashtable-ref class-provider-states-tbl provider #f)))
      (cond
        ((eq? state 'loaded) 'loaded)
        ((vector? state) (cp-attempt-status state))
        (else 'unloaded)))))
(define (class-provider-provider-attempt-id provider)
  (with-mutex class-provider-mu
    (let ((state
            (hashtable-ref class-provider-states-tbl provider #f)))
      (if (vector? state)
          (vector-ref state cp-attempt-id-index)
          #f))))
(define (class-provider-provider-waiters provider)
  (with-mutex class-provider-mu
    (let ((state
            (hashtable-ref class-provider-states-tbl provider #f)))
      (if (vector? state)
          (vector-ref state cp-attempt-waiters-index)
          0))))
(define (class-provider-evaluator-owner)
  (with-mutex class-provider-mu class-provider-eval-owner))
(define (class-provider-evaluator-waiters)
  (with-mutex class-provider-mu class-provider-global-waiters))
(define (class-provider-evaluator-attempt-count)
  (with-mutex class-provider-mu class-provider-attempt-counter))
