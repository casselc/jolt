;; class-providers.ss — the class-provider REGISTRY CORE.
;;
;; A provider maps a canonical Java class name to the namespace that owns its
;; host interop (constructors, statics, instance? tags). This file holds ONLY the
;; registry: one canonical-class -> provider-namespace table guarded by a mutex,
;; a generation counter, and a freeze flag. There is deliberately NO lazy class
;; loading, NO provider evaluation, NO attempt counters or wait queues, and NO
;; world snapshot/restore here — those are evaluation-time concerns layered on
;; later. This is the bounded registry bookkeeping every later layer shares.
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
;;
;; Structured failures are raised as jolt ex-info whose ex-data carries a
;; :type keyword naming the category:
;;   :jolt.deps/invalid-class-provider        malformed class/provider token
;;   :jolt.deps/class-provider-conflict        same class, differing provider
;;   :jolt.deps/class-provider-registry-frozen a new key after freeze
;;
;; Loaded after the value/collection/error layers of rt.ss (it needs jolt-throw,
;; jolt-ex-info, jolt-hash-map, keyword, and the symbol accessors) and sits in
;; the host java/ class layer beside class-hierarchy.ss.

;; --- registry state ---------------------------------------------------------
;; canonical-class-string -> provider-namespace-string. Mutation only under the
;; mutex so reads (class-provider-for/mappings/namespaces) see a consistent table.
(define class-providers-tbl (make-hashtable string-hash string=?))
(define class-provider-mu (make-mutex))
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
(define cp-kw-type (keyword #f "type"))
(define cp-kw-class (keyword #f "class"))
(define cp-kw-provider (keyword #f "provider"))
(define cp-kw-existing (keyword #f "existing-provider"))
(define cp-kw-new (keyword #f "new-provider"))
(define cp-kw-reason (keyword #f "reason"))
(define cp-kw-generation (keyword #f "registry-generation"))

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

;; --- atomic preflighted registration ----------------------------------------
;; Preflight under the mutex: validate the batch cumulatively (intra-batch AND
;; against the live table), collect new keys, then commit only if nothing
;; rejected. A conflict or freeze raises before any hashtable-set! on the live
;; table, so a failed batch is a no-op.
(define (class-provider-register-many! pairs)
  (let ((normalized (cp-normalize-and-validate-pairs pairs)))
    (with-mutex class-provider-mu
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
      (set! class-providers-tbl replacement)
      (set! class-provider-frozen? #f)
      (set! class-provider-registry-generation
            (+ class-provider-registry-generation 1))))
  jolt-nil)

;; Close the provider world around a resolved dependency graph. Identical
;; re-declarations remain idempotent; a NEW class key after this raises
;; :jolt.deps/class-provider-registry-frozen. reset-many! reopens the world.
(define (class-provider-freeze!)
  (with-mutex class-provider-mu
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
