;; class-providers.ss — the class-provider registry and evaluation coordinator.
;;
;; A provider maps a canonical Java class name to the namespace that owns its
;; host interop (constructors, statics, instance? tags). This file owns the
;; exact canonical-class -> provider-namespace registry and the serialized
;; provider-namespace evaluation state machine shared by every later dispatch
;; site.
;;
;; The evaluator is deliberately not wired to constructor/static/member misses
;; in this slice. Provider-owned host registrations are not staged or rolled
;; back here either. Those behaviors must land together later so a failed
;; provider can never leak a partial host world. Until then the coordinator is
;; exercised only through its direct Scheme gate.
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
;;     harmless, and reset-many! thaws the registry.
;;   - at most one thread owns a provider evaluation graph process-wide;
;;   - that owner may recursively evaluate a different provider, while every
;;     other thread waits;
;;   - owner re-entry into a provider already loading on its stack is a bounded
;;     structured cycle error;
;;   - callers waiting on one attempt observe that exact success or failure;
;;     only a later independent caller may replace a failed attempt and retry.
;;
;; Structured failures are raised as jolt ex-info whose ex-data carries a
;; :type keyword naming the category:
;;   :jolt.deps/invalid-class-provider        malformed class/provider token
;;   :jolt.deps/class-provider-conflict        same class, differing provider
;;   :jolt.deps/class-provider-registry-frozen a new key after freeze
;;   :jolt.deps/class-provider-cycle           owner re-entry while loading
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
(define cp-kw-type (keyword #f "type"))
(define cp-kw-class (keyword #f "class"))
(define cp-kw-provider (keyword #f "provider"))
(define cp-kw-existing (keyword #f "existing-provider"))
(define cp-kw-new (keyword #f "new-provider"))
(define cp-kw-reason (keyword #f "reason"))
(define cp-kw-generation (keyword #f "registry-generation"))
(define cp-kw-path (keyword #f "path"))

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
;; The owner itself must pass through so a nested provider can claim work and,
;; in the later transactional slice, publish its staged commit.
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
;; Preflight under the mutex: validate the batch cumulatively (intra-batch AND
;; against the live table), collect new keys, then commit only if nothing
;; rejected. A conflict or freeze raises before any hashtable-set! on the live
;; table, so a failed batch is a no-op.
(define (class-provider-register-many! pairs)
  (let ((normalized (cp-normalize-and-validate-pairs pairs)))
    (with-mutex class-provider-mu
      (class-provider-wait-evaluator-locked! (get-thread-id))
      (let ((batch (make-hashtable string-hash string=?))
            (new? #f)
            (first-new #f))
        (for-each
          (lambda (p)
            (let* ((class (car p))
                   (provider (cdr p))
                   (batch-old (hashtable-ref batch class #f))
                   (table-old (hashtable-ref class-providers-tbl class #f))
                   (old (or batch-old table-old)))
              (cond
                ((not old)
                 (hashtable-set! batch class provider)
                 (unless new?
                   (set! first-new p))
                 (set! new? #t))
                ((string=? old provider)
                 (hashtable-set! batch class provider))
                (else
                 (cp-conflict! class old provider)))))
          normalized)
        (when (and class-provider-frozen? new?)
          (cp-frozen! (car first-new) (cdr first-new)))
        (let-values (((ks vs) (hashtable-entries batch)))
          (let loop ((i 0) (n (vector-length ks)))
            (when (fx<? i n)
              (hashtable-set! class-providers-tbl (vector-ref ks i) (vector-ref vs i))
              (loop (fx+ i 1) n))))
        (when new?
          (set! class-provider-registry-generation
                (+ class-provider-registry-generation 1)))))
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

(define (class-provider-finish! provider attempt root?)
  (with-mutex class-provider-mu
    (cp-attempt-status-set! attempt 'succeeded)
    (hashtable-set! class-provider-states-tbl provider 'loaded)
    (when root? (set! class-provider-eval-owner #f))
    (condition-broadcast class-provider-cv)))

(define (class-provider-abort! provider attempt root? error)
  (with-mutex class-provider-mu
    (vector-set! attempt cp-attempt-error-index error)
    (cp-attempt-status-set! attempt 'failed)
    (hashtable-set! class-provider-states-tbl provider attempt)
    (when root? (set! class-provider-eval-owner #f))
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
;; LOAD! is explicit so the direct coordinator gate does not need loader.ss;
;; the production wrapper below supplies load-namespace.
(define (class-provider-load-provider-with! provider load!)
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
             (root? (caddr claim)))
         (guard (e (else
                     (class-provider-abort!
                       provider attempt root? e)
                     (raise e)))
           (parameterize
             ((class-provider-load-stack
                (cons provider (class-provider-load-stack))))
             (load! provider))
           (class-provider-finish! provider attempt root?)
           #t)))
      (else #f))))

(define (class-provider-load-provider! provider)
  (class-provider-load-provider-with!
    provider
    (lambda (namespace) (load-namespace namespace))))

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
