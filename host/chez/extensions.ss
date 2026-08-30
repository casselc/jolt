;; Extension points: a named contract letting core declare functionality whose
;; DATA it does not carry, and a library supply that data later.
;;
;; A point declares the type of its key, the type of its value (:fields), a TOTAL
;; :default, and what an unregistered key means (:fallback). A provider registers
;; a possibly PARTIAL value at a key; lookup is (merge default provider), so a
;; provider states only what differs, and an older provider stays valid when the
;; schema grows through refine-extension!.
;;
;;   (register-extension-point! :currency-data
;;     {:key :string :root ""
;;      :fields {:symbol :string :frac-digits :long}
;;      :default {:symbol "¤" :frac-digits 2}
;;      :fallback :strict})
;;   (register-extension! :currency-data "de" {:symbol "€"})
;;   (extension-value :currency-data "de")   ; => {:symbol "€" :frac-digits 2}
;;
;; :fallback :strict is the reason this exists rather than a map with a default.
;; It says the default answers the :root key and nothing else, so an unregistered
;; key RAISES naming the point and the key instead of quietly handing back a
;; default that is wrong for it. That is what lets core ship a point it cannot
;; populate — formatting a German amount with US separators is a silent wrong
;; answer, and refusing is the correct answer to an unanswerable question.
;;
;; Every mutation bumps extension-epoch-n. Resolution tiers above tier 3 (a plain
;; lookup) cache per call site and guard on that epoch, so a library required
;; after a site warmed up invalidates it — the same shape as jolt-proto-epoch.

;; ext-operations-mu covers only leaf snapshots and commits: the declaration's
;; check/create, refinement publication, provider write, and epoch bump. Parsing,
;; equality, map operations, rendering, and errors can reach user code or park,
;; so every one runs before the counted commit mutex is entered. A commit then
;; rechecks the immutable point identity it prepared against and retries when a
;; concurrent refinement won the race.
;;
;; Two things break without it, and they are the two the protocol registry and the
;; multimethod epoch broke in the same way. The declare is check-then-create, so
;; two threads declaring one point each build their own providers table and a
;; provider registered through one is invisible through the other. And the epoch
;; is a `set!` read-modify-write, so a lost bump leaves a warmed call site's cached
;; resolution never invalidated — the exact staleness the epoch exists to prevent.
;;
;; Reads stay unlocked. extension-points-tbl and each providers table are STRONG
;; hashtables read single-key, which is safe for the reasons set out at var-table,
;; and jolt-extension-value is the hot path this whole epoch scheme exists to keep
;; cheap.
(define ext-operations-mu (make-mutex))
(define extension-epoch-n 0)
;; call with ext-operations-mu HELD
(define (bump-extension-epoch!) (set! extension-epoch-n (fx+ extension-epoch-n 1)))

;; A generic operation may synchronously reenter this registry. Each public
;; mutation therefore carries an execution-context-owned token. A successful
;; nested mutation invalidates only active ancestors owned by this same fiber or
;; thread; a sibling fiber can inherit the dynamic stack without becoming
;; synchronous reentry. The outer operation then fails before retrying or
;; publishing, so the nested winner remains and its triggering dispatch runs
;; exactly once. Idempotent no-ops and failed nested operations invalidate
;; nothing.
;;
;; token = #(owner invalid? ancestors)
(define ext-operation-tokens (make-parameter '()))
(define (ext-with-operation thunk)
  (let ((token (vector (jolt-execution-context-identity) #f
                       (ext-operation-tokens))))
    (parameterize ((ext-operation-tokens
                     (cons token (ext-operation-tokens))))
      (thunk token))))
(define (ext-token-invalid? token) (vector-ref token 1))
(define (ext-note-mutation! token)
  (let ((me (jolt-execution-context-identity)))
    ;; Only active same-owner ancestors prepared state that this commit can make
    ;; stale. Keep that ancestry on the explicit token as well as the dynamic
    ;; parameter so a commit after a fiber suspension cannot lose it.
    (for-each (lambda (ancestor)
                (when (eq? (vector-ref ancestor 0) me)
                  (vector-set! ancestor 1 #t)))
              (vector-ref token 2))))
(define (ext-assert-token! who token)
  (when (ext-token-invalid? token)
    (throw-jvm
      (quote IllegalStateException)
      (string-append who
                     ": reentrant extension mutation changed the registry; "
                     "the nested mutation was kept and the stale outer operation was rejected"))))

;; Capture state-dependent preparation errors until the commit mutex has
;; established whether the immutable point snapshot is still current. A stale
;; error is retried against the new schema; an error following same-owner
;; reentry is preserved as the earlier failure in evaluation order.
;; #(success? value-or-condition)
(define (ext-capture thunk)
  (guard (e (#t (vector #f e)))
    (vector #t (thunk))))

(define extension-points-tbl (make-hashtable string-hash string=?))

(define-record-type ext-point
  (fields id key-kind root fallback
          hint                      ; string appended to a strict miss, or #f
          ;; Keep the v1 record descriptor compatible with existing state
          ;; images.  Refinement no longer uses these setters: it publishes a
          ;; fresh point so readers still observe an immutable generation.
          (mutable fields)          ; alist (field-name . type-name), declaration order
          (mutable default)         ; jolt map, total over fields
          providers)                ; hashtable: normalized key string -> jolt map
  (nongenerative chez-ext-point-v1))

(define (ext-bad! msg) (throw-jvm (quote IllegalArgumentException) msg))
(define (ext-get m k) (jolt-get-dispatch m k jolt-nil))
(define (ext-kw m name) (ext-get m (keyword #f name)))

;; A point id and the enum-ish spec values are keywords; render them with the
;; leading colon so an error message reads the way the source does.
(define (ext-id-str id)
  (unless (keyword? id) (ext-bad! (string-append "extension point id must be a keyword, got "
                                                 (jolt-pr-readable id))))
  (keyword-t-name id))
(define (ext-show-id id) (string-append ":" id))

(define (ext-kw-name v who)
  (unless (keyword? v) (ext-bad! (string-append who " must be a keyword, got " (jolt-pr-readable v))))
  (keyword-t-name v))

;; ---- the declared type system ----------------------------------------------
;; Deliberately small: these are the shapes host data actually takes. :any opts a
;; field out of checking rather than leaving the checker guessing.
(define (ext-type-ok? type v)
  (cond ((string=? type "string")  (string? v))
        ((string=? type "long")    (and (exact? v) (integer? v)))
        ((string=? type "double")  (flonum? v))
        ((string=? type "boolean") (boolean? v))
        ((string=? type "keyword") (keyword? v))
        ((string=? type "any")     #t)
        (else #f)))
(define (ext-known-type? type)
  (member type '("string" "long" "double" "boolean" "keyword" "any")))

(define (ext-key-kind-ok? kind v)
  (cond ((string=? kind "string")  (string? v))
        ((string=? kind "keyword") (keyword? v))
        (else #f)))
;; Providers are keyed by a normalized string so the table has one key type; the
;; point's declared :key kind is what decides whether a given value is admissible.
(define (ext-key->string point k)
  (let ((kind (ext-point-key-kind point)))
    (unless (ext-key-kind-ok? kind k)
      (ext-bad! (string-append "extension point " (ext-show-id (ext-point-id point))
                               " takes a " kind " key, got " (jolt-pr-readable k))))
    (if (string=? kind "keyword") (keyword-t-name k) k)))

;; ---- declaration ------------------------------------------------------------
;; :fields as an alist in the map's own order, each value naming a known type.
(define (ext-parse-fields fields id)
  (unless (jolt-map? fields)
    (ext-bad! (string-append "extension point " (ext-show-id id) " :fields must be a map")))
  (reverse
    (pmap-fold-fwd fields
      (lambda (k v acc)
        (let ((fname (ext-kw-name k (string-append (ext-show-id id) " field name")))
              (tname (ext-kw-name v (string-append (ext-show-id id) " field type"))))
          (unless (ext-known-type? tname)
            (ext-bad! (string-append "extension point " (ext-show-id id) " field :" fname
                                     " has unknown type :" tname)))
          (cons (cons fname tname) acc)))
      '())))

;; Check a value map against the field list. total? demands every field be present
;; (the :default contract); a provider is partial, so it only checks what it states.
(define (ext-check-value! id fields m total? what)
  (unless (jolt-map? m)
    (ext-bad! (string-append what " for extension point " (ext-show-id id) " must be a map")))
  (pmap-fold-fwd m
    (lambda (k v acc)
      (let* ((fname (ext-kw-name k (string-append what " key")))
             (fld (assoc fname fields)))
        (unless fld
          (ext-bad! (string-append what " for extension point " (ext-show-id id)
                                   " has unknown field :" fname)))
        (unless (ext-type-ok? (cdr fld) v)
          (ext-bad! (string-append what " for extension point " (ext-show-id id)
                                   " field :" fname " must be :" (cdr fld)
                                   ", got " (jolt-pr-readable v))))
        acc))
    '())
  (when total?
    (for-each (lambda (fld)
                (unless (jolt-contains? m (keyword #f (car fld)))
                  (ext-bad! (string-append what " for extension point " (ext-show-id id)
                                           " is missing field :" (car fld)
                                           " — the default must be total over :fields"))))
              fields)))

;; Re-declaring a point identically is a no-op (two loads of the same file, a
;; library declaring a point core also declares). Re-declaring it DIFFERENTLY is
;; drift — two sources disagreeing about one contract — and raises rather than
;; letting last-write-wins pick silently.
(define (ext-same-declaration? p key-kind root fallback hint fields default)
  (and (string=? (ext-point-key-kind p) key-kind)
       (string=? (ext-point-fallback p) fallback)
       (equal? (ext-point-hint p) hint)
       (jolt=2 (ext-point-root p) root)
       (equal? (ext-point-fields p) fields)
       (jolt=2 (ext-point-default p) default)))

(define (jolt-register-extension-point! id spec)
  (ext-with-operation
    (lambda (token)
      ;; Every caller-controlled operation in declaration parsing runs once,
      ;; outside the leaf commit mutex.
      (let ((idn (ext-id-str id)))
        (unless (jolt-map? spec)
          (ext-bad! (string-append "extension point " (ext-show-id idn) " spec must be a map")))
        (let* ((key-kind (ext-kw-name (ext-kw spec "key")
                                      (string-append (ext-show-id idn) " :key")))
               (fallback (ext-kw-name (ext-kw spec "fallback")
                                      (string-append (ext-show-id idn) " :fallback")))
               (root (ext-kw spec "root"))
               (fields (ext-parse-fields (ext-kw spec "fields") idn))
               (default (ext-kw spec "default"))
               ;; optional: what a caller should DO about a strict miss, appended to
               ;; the raise so the message ends in an action rather than a diagnosis.
               (hint (let ((h (ext-kw spec "hint")))
                       (cond ((jolt-nil? h) #f)
                             ((string? h) h)
                             (else
                              (ext-bad!
                                (string-append "extension point " (ext-show-id idn)
                                               " :hint must be a string")))))))
          (unless (member key-kind '("string" "keyword"))
            (ext-bad! (string-append "extension point " (ext-show-id idn)
                                     " :key must be :string or :keyword, got :" key-kind)))
          (unless (member fallback '("strict" "default"))
            (ext-bad! (string-append "extension point " (ext-show-id idn)
                                     " :fallback must be :strict or :default, got :" fallback)))
          (ext-check-value! idn fields default #t ":default")
          ;; :strict answers exactly one key from the default, so that key must be named
          ;; and must itself be a legal key.
          (when (string=? fallback "strict")
            (when (jolt-nil? root)
              (ext-bad! (string-append "extension point " (ext-show-id idn)
                                       " is :strict and must declare the :root key its :default answers for")))
            (unless (ext-key-kind-ok? key-kind root)
              (ext-bad! (string-append "extension point " (ext-show-id idn) " :root must be a "
                                       key-kind ", got " (jolt-pr-readable root)))))
          (let retry ()
            (let ((prior (jolt-with-mutex ext-operations-mu
                           (hashtable-ref extension-points-tbl idn #f))))
              (if prior
                  (let* ((comparison
                           (ext-capture
                             (lambda ()
                               (ext-same-declaration?
                                 prior key-kind root fallback hint fields default))))
                         (decision
                           (jolt-with-mutex ext-operations-mu
                             (let ((current (hashtable-ref extension-points-tbl idn #f)))
                               (cond
                                 ;; Preserve an earlier comparison failure after
                                 ;; synchronous reentry instead of replacing it.
                                 ((and (not (vector-ref comparison 0))
                                       (ext-token-invalid? token))
                                  'raise)
                                 ((ext-token-invalid? token) 'stale)
                                 ((not (eq? current prior)) 'retry)
                                 ((not (vector-ref comparison 0)) 'raise)
                                 ((vector-ref comparison 1) 'same)
                                 (else 'drift))))))
                    (case decision
                      ((retry) (retry))
                      ((raise) (raise (vector-ref comparison 1)))
                      ((stale) (ext-assert-token! "register-extension-point!" token))
                      ((same) jolt-nil)
                      (else
                       (ext-bad! (string-append "extension point " (ext-show-id idn)
                                                " is already declared with a different contract")))))
                  (let ((decision
                          (jolt-with-mutex ext-operations-mu
                            (cond
                              ((ext-token-invalid? token) 'stale)
                              ((hashtable-ref extension-points-tbl idn #f) 'retry)
                              (else
                               (hashtable-set! extension-points-tbl idn
                                 (make-ext-point idn key-kind root fallback hint fields default
                                                 (make-hashtable string-hash string=?)))
                               (bump-extension-epoch!)
                               'created)))))
                    (case decision
                      ((retry) (retry))
                      ((stale) (ext-assert-token! "register-extension-point!" token))
                      (else (ext-note-mutation! token) jolt-nil)))))))))))

(define (ext-point-of id who)
  (let* ((idn (ext-id-str id))
         (p (hashtable-ref extension-points-tbl idn #f)))
    (unless p
      (ext-bad! (string-append who ": no extension point " (ext-show-id idn) " is declared")))
    p))

;; ---- schema refinement ------------------------------------------------------
;; Grow the value type with new OPTIONAL fields plus their defaults. Every already
;; registered provider keeps validating, and gains the new field's default through
;; the merge — refinement of the type, not a breaking redeclaration.
(define (jolt-refine-extension! id spec)
  (ext-with-operation
    (lambda (token)
      (let* ((idn (ext-id-str id))
             ;; Preserve the original API order: an undeclared point fails
             ;; before caller-controlled spec predicates or traversal run.
             (initial-p
               (jolt-with-mutex ext-operations-mu
                 (hashtable-ref extension-points-tbl idn #f))))
        (unless initial-p
          (ext-bad! (string-append "refine-extension!: no extension point "
                                   (ext-show-id idn) " is declared")))
        (unless (jolt-map? spec)
          (ext-bad! (string-append "refine-extension! " (ext-show-id idn) " spec must be a map")))
        ;; These depend only on caller input and therefore run once. The merge
        ;; below may be retried only when a concurrent immutable point generation
        ;; wins publication.
        (let ((new-fields (ext-parse-fields (ext-kw spec "fields") idn))
              (new-default (ext-kw spec "default")))
          (let retry ((p initial-p))
              (unless p
                (ext-bad! (string-append "refine-extension!: no extension point "
                                         (ext-show-id idn) " is declared")))
              (let* ((prepared
                       (ext-capture
                         (lambda ()
                           ;; A field already declared may be repeated only at
                           ;; the same type; a different type is contract drift.
                           (for-each (lambda (fld)
                                       (let ((old (assoc (car fld) (ext-point-fields p))))
                                         (when (and old (not (string=? (cdr old) (cdr fld))))
                                           (ext-bad!
                                             (string-append "refine-extension! "
                                                            (ext-show-id idn) " field :"
                                                            (car fld) " is already declared as :"
                                                            (cdr old))))))
                                     new-fields)
                           (let ((merged-fields
                                   (append
                                     (ext-point-fields p)
                                     (filter
                                       (lambda (f)
                                         (not (assoc (car f) (ext-point-fields p))))
                                       new-fields))))
                             (ext-check-value! idn merged-fields new-default #f ":default")
                             ;; Every added field needs either an old or a new
                             ;; default so the merged default remains total.
                             (for-each
                               (lambda (fld)
                                 (unless
                                   (or (jolt-contains? (ext-point-default p)
                                                       (keyword #f (car fld)))
                                       (jolt-contains? new-default
                                                       (keyword #f (car fld))))
                                   (ext-bad!
                                     (string-append "refine-extension! "
                                                    (ext-show-id idn) " field :"
                                                    (car fld) " needs a :default"))))
                               new-fields)
                             (let ((merged-default
                                     (pmap-fold-fwd
                                       new-default
                                       (lambda (k v acc) (jolt-assoc1 acc k v))
                                       (ext-point-default p))))
                               ;; Build the complete immutable generation before
                               ;; entering the leaf publication mutex.
                               (make-ext-point idn
                                               (ext-point-key-kind p)
                                               (ext-point-root p)
                                               (ext-point-fallback p)
                                               (ext-point-hint p)
                                               merged-fields
                                               merged-default
                                               (ext-point-providers p)))))))
                     (decision
                       (jolt-with-mutex ext-operations-mu
                         (let ((current (hashtable-ref extension-points-tbl idn #f)))
                           (cond
                             ((and (not (vector-ref prepared 0))
                                   (ext-token-invalid? token))
                              'raise)
                             ((ext-token-invalid? token) 'stale)
                             ((not (eq? current p)) 'retry)
                             ((not (vector-ref prepared 0)) 'raise)
                             (else
                              (hashtable-set! extension-points-tbl idn
                                              (vector-ref prepared 1))
                              (bump-extension-epoch!)
                              'published))))))
                (case decision
                  ((retry)
                   (retry
                     (jolt-with-mutex ext-operations-mu
                       (hashtable-ref extension-points-tbl idn #f))))
                  ((raise) (raise (vector-ref prepared 1)))
                  ((stale) (ext-assert-token! "refine-extension!" token))
                  (else (ext-note-mutation! token) jolt-nil)))))))))

;; ---- registration + lookup --------------------------------------------------
(define (jolt-register-extension! id k value)
  (ext-with-operation
    (lambda (token)
      (let ((idn (ext-id-str id)))
        (let retry ()
          (let ((p (jolt-with-mutex ext-operations-mu
                     (hashtable-ref extension-points-tbl idn #f))))
            (unless p
              (ext-bad! (string-append "register-extension!: no extension point "
                                       (ext-show-id idn) " is declared")))
            (let* ((prepared
                     (ext-capture
                       (lambda ()
                         (let ((ks (ext-key->string p k)))
                           (ext-check-value! (ext-point-id p)
                                             (ext-point-fields p)
                                             value #f "provider")
                           ks))))
                   (decision
                     (jolt-with-mutex ext-operations-mu
                       (let ((current (hashtable-ref extension-points-tbl idn #f)))
                         (cond
                           ((and (not (vector-ref prepared 0))
                                 (ext-token-invalid? token))
                            'raise)
                           ((ext-token-invalid? token) 'stale)
                           ((not (eq? current p)) 'retry)
                           ((not (vector-ref prepared 0)) 'raise)
                           (else
                            ;; Provider writes need no prior-value conflict
                            ;; check: preparation depends only on the immutable
                            ;; point schema, and writes linearize here in commit
                            ;; order. Point identity detects concurrent refine.
                            (hashtable-set! (ext-point-providers p)
                                            (vector-ref prepared 1) value)
                            (bump-extension-epoch!)
                            'published))))))
              (case decision
                ((retry) (retry))
                ((raise) (raise (vector-ref prepared 1)))
                ((stale) (ext-assert-token! "register-extension!" token))
                (else (ext-note-mutation! token) jolt-nil)))))))))

(define (ext-merge default provider)
  (pmap-fold-fwd provider (lambda (k v acc) (jolt-assoc1 acc k v)) default))

(define (jolt-extension-value id k)
  (let* ((p (ext-point-of id "extension-value"))
         (ks (ext-key->string p k))
         (hit (hashtable-ref (ext-point-providers p) ks #f)))
    (cond
      (hit (ext-merge (ext-point-default p) hit))
      ((string=? (ext-point-fallback p) "default") (ext-point-default p))
      ((jolt=2 (ext-point-root p) k) (ext-point-default p))
      (else
       (ext-bad! (string-append "No " (ext-show-id (ext-point-id p)) " provider for key "
                                (jolt-pr-readable k)
                                ". The point carries a default for its root key "
                                (jolt-pr-readable (ext-point-root p))
                                " only; a library must register this key."
                                (if (ext-point-hint p)
                                    (string-append " " (ext-point-hint p))
                                    "")))))))

;; Whether a key resolves without raising — lets a caller offer a better message
;; than the raise, and lets a gate assert the tiers agree on misses too.
(define (jolt-extension-has? id k)
  (let* ((p (ext-point-of id "extension-has?"))
         (ks (ext-key->string p k)))
    (or (and (hashtable-ref (ext-point-providers p) ks #f) #t)
        (string=? (ext-point-fallback p) "default")
        (jolt=2 (ext-point-root p) k))))

(def-var! "jolt.host" "register-extension-point!" jolt-register-extension-point!)
(def-var! "jolt.host" "register-extension!" jolt-register-extension!)
(def-var! "jolt.host" "refine-extension!" jolt-refine-extension!)
(def-var! "jolt.host" "extension-value" jolt-extension-value)
(def-var! "jolt.host" "extension-has?" jolt-extension-has?)
(def-var! "jolt.host" "extension-epoch" (lambda () extension-epoch-n))
