;; Deterministic record/continue checkpoints for controlled builds.
;;
;; The controller stores inert data only.  A checkpoint never invokes a
;; controller callback: it registers its site, allocates one global sequence
;; number and one per-[actor,id] hit, records the event, and interprets the
;; selected inert action after releasing checkpoint-controller-mu.

(define checkpoint-controller-mu (make-mutex))

(define checkpoint-sites (make-hashtable string-hash string=?))
(define checkpoint-plan (make-hashtable equal-hash equal?))
(define checkpoint-hits (make-hashtable equal-hash equal?))
(define checkpoint-bindings (make-weak-eq-hashtable))
(define checkpoint-trace-rev '())
(define checkpoint-next-seq 1)
(define checkpoint-unbound (list 'checkpoint-unbound))

(define-record-type checkpoint-event
  (fields seq actor id hit action)
  (nongenerative jolt-checkpoint-event-v1))

(define checkpoint-disposition-names
  '("barrier" "cancel" "continue" "fault" "yield"))

(define (checkpoint-bad who message . irritants)
  (apply error who message irritants))

(define (checkpoint-qualified-id who id)
  (unless (and (string? id)
               (> (string-length id) 2)
               (let ((slash
                       (let find ((i 0))
                         (cond ((= i (string-length id)) #f)
                               ((char=? (string-ref id i) #\/) i)
                               (else (find (+ i 1)))))))
                 (and slash (> slash 0) (< slash (- (string-length id) 1)))))
    (checkpoint-bad who "checkpoint id must be a qualified string" id))
  ;; Chez strings are mutable.  Every controller boundary owns a fresh copy so
  ;; callers cannot rewrite a site, plan key, or prior event after validation.
  (string-copy id))

(define (checkpoint-name who x)
  (let ((name
          (cond ((symbol? x) (symbol->string x))
                ((keyword? x) (keyword-t-name x))
                ((string? x) x)
                (else
                 (checkpoint-bad who
                                 "checkpoint name must be a symbol, keyword, or string"
                                 x)))))
    (string-copy name)))

(define (checkpoint-coll->list who xs)
  (cond ((list? xs) xs)
        ((pvec? xs) (vector->list (pvec-v xs)))
        ((pset? xs) (pset-fold xs cons '()))
        (else (checkpoint-bad who "checkpoint dispositions must be a list, vector, or set" xs))))

(define (checkpoint-normalize-dispositions who xs)
  (let ((names (sort string<? (map (lambda (x) (checkpoint-name who x))
                                   (checkpoint-coll->list who xs)))))
    (let loop ((rest names) (prior #f))
      (unless (null? rest)
        (let ((name (car rest)))
          (unless (member name checkpoint-disposition-names)
            (checkpoint-bad who "unsupported checkpoint disposition" name))
          (when (and prior (string=? prior name))
            (checkpoint-bad who "duplicate checkpoint disposition" name))
          (loop (cdr rest) name))))
    (unless (member "continue" names)
      (checkpoint-bad who "checkpoint dispositions must include continue" names))
    names))

;; Must be called with checkpoint-controller-mu held.  Registration is
;; idempotent only when the complete normalized disposition set agrees.
(define (checkpoint-register-normalized! who id dispositions)
  (let ((prior (hashtable-ref checkpoint-sites id #f)))
    (cond ((not prior) (hashtable-set! checkpoint-sites id dispositions))
          ((not (equal? prior dispositions))
           (checkpoint-bad who "duplicate checkpoint id has different dispositions"
                           id prior dispositions)))))

(define (jolt-checkpoint-register-site! id dispositions)
  (let ((id (checkpoint-qualified-id 'checkpoint-register-site! id))
        (dispositions
          (checkpoint-normalize-dispositions 'checkpoint-register-site! dispositions)))
    (jolt-with-mutex checkpoint-controller-mu
      (checkpoint-register-normalized! 'checkpoint-register-site! id dispositions))
    jolt-nil))

(define (checkpoint-plan-key who key)
  (unless (and (pvec? key) (= (pvec-count key) 3))
    (checkpoint-bad who "checkpoint plan key must be [actor id hit]" key))
  (let ((actor (pvec-nth! key 0))
        (id (pvec-nth! key 1))
        (hit (pvec-nth! key 2)))
    (unless (and (string? actor) (> (string-length actor) 0))
      (checkpoint-bad who "checkpoint actor must be a nonempty string" actor))
    (set! actor (string-copy actor))
    (set! id (checkpoint-qualified-id who id))
    (unless (and (integer? hit) (> hit 0))
      (checkpoint-bad who "checkpoint hit must be a positive integer" hit))
    (list actor id (if (exact? hit) hit (exact hit)))))

(define (checkpoint-action who action)
  (let ((name (checkpoint-name who action)))
    (unless (string=? name "continue")
      (checkpoint-bad who "only the continue checkpoint action is supported" action))
    'continue))

(define (checkpoint-parse-plan plan)
  (unless (pmap? plan)
    (checkpoint-bad 'checkpoint-install-plan! "checkpoint plan must be a map" plan))
  ;; Parsing persistent data does not touch controller state and happens before
  ;; the counted mutex.  Each entry becomes a fresh inert Scheme key/action.
  (pmap-fold
    plan
    (lambda (key action entries)
      (let ((key (checkpoint-plan-key 'checkpoint-install-plan! key))
            (action (checkpoint-action 'checkpoint-install-plan! action)))
        (when (assoc key entries)
          (checkpoint-bad 'checkpoint-install-plan! "duplicate checkpoint plan key" key))
        (cons (cons key action) entries)))
    '()))

(define (jolt-checkpoint-install-plan! plan)
  (let ((entries (checkpoint-parse-plan plan)))
    (jolt-with-mutex checkpoint-controller-mu
      ;; Validate against the exact registered site snapshot and publish only
      ;; after every entry succeeds.  No user procedure runs in this section.
      (for-each
        (lambda (entry)
          (let* ((key (car entry))
                 (id (cadr key))
                 (site (hashtable-ref checkpoint-sites id #f)))
            (unless site
              (checkpoint-bad 'checkpoint-install-plan!
                              "checkpoint plan names an unregistered site" id))
            (unless (member "continue" site)
              (checkpoint-bad 'checkpoint-install-plan!
                              "checkpoint site does not permit continue" id))))
        entries)
      (let ((next (make-hashtable equal-hash equal?)))
        (for-each (lambda (entry) (hashtable-set! next (car entry) (cdr entry))) entries)
        (set! checkpoint-plan next)))
    jolt-nil))

(define (jolt-checkpoint-bind-actor! actor)
  (unless (and (string? actor) (> (string-length actor) 0))
    (checkpoint-bad 'checkpoint-bind-actor! "checkpoint actor must be a nonempty string" actor))
  (let ((actor (string-copy actor))
        (context (jolt-execution-context-identity)))
    (jolt-with-mutex checkpoint-controller-mu
      ;; One live execution context owns an actor at a time.  Otherwise two
      ;; schedulable contexts race for that actor's next hit and make a replay
      ;; plan scheduler-dependent. Bind is rare, so scan the weak context table
      ;; rather than adding a reverse table that would strongly retain contexts.
      (let-values (((contexts actors) (hashtable-entries checkpoint-bindings)))
        (let scan ((i 0))
          (unless (= i (vector-length contexts))
            (when (and (not (eq? context (vector-ref contexts i)))
                       (string=? actor (vector-ref actors i)))
              (checkpoint-bad 'checkpoint-bind-actor!
                              "checkpoint actor is already bound to another execution context"
                              actor))
            (scan (+ i 1)))))
      (hashtable-set! checkpoint-bindings context actor)))
  jolt-nil)

(define (jolt-checkpoint-unbind-actor!)
  (let ((context (jolt-execution-context-identity)))
    (jolt-with-mutex checkpoint-controller-mu
      (hashtable-delete! checkpoint-bindings context)))
  jolt-nil)

(define (jolt-checkpoint-reset!)
  (jolt-with-mutex checkpoint-controller-mu
    (set! checkpoint-sites (make-hashtable string-hash string=?))
    (set! checkpoint-plan (make-hashtable equal-hash equal?))
    (set! checkpoint-hits (make-hashtable equal-hash equal?))
    ;; Replacing the central context table invalidates bindings in every live
    ;; thread and fiber at once; no inherited/stale parameter can survive reset.
    (set! checkpoint-bindings (make-weak-eq-hashtable))
    (set! checkpoint-trace-rev '())
    (set! checkpoint-next-seq 1))
  jolt-nil)

;; Closed nonparking leaf for a continue-only site.  This function performs only
;; runtime-owned normalization, snapshot/publication, and inert action dispatch;
;; it never invokes controller or user code before, during, or after its mutex.
;; That is the property that permits record-only continue sites under an outer
;; counted lock.
(define (jolt-checkpoint-continue! id)
  (let* ((id (checkpoint-qualified-id 'jolt-checkpoint-continue! id))
         (context (jolt-execution-context-identity))
         (selected
             (jolt-with-mutex checkpoint-controller-mu
               (let ((actor (hashtable-ref checkpoint-bindings context #f)))
                 (if (not actor)
                     checkpoint-unbound
                     (begin
                       (checkpoint-register-normalized! 'jolt-checkpoint-continue!
                                                        id '("continue"))
                       (let* ((hit-key (list actor id))
                              (hit (+ 1 (hashtable-ref checkpoint-hits hit-key 0)))
                              (plan-key (list actor id hit))
                              (action (hashtable-ref checkpoint-plan plan-key #f))
                              (seq checkpoint-next-seq))
                         (hashtable-set! checkpoint-hits hit-key hit)
                         (set! checkpoint-next-seq (+ seq 1))
                         (set! checkpoint-trace-rev
                               (cons (make-checkpoint-event seq actor id hit action)
                                     checkpoint-trace-rev))
                         action)))))))
    (cond ((eq? selected checkpoint-unbound)
           (checkpoint-bad 'jolt-checkpoint-continue!
                           "checkpoint execution requires an explicit actor binding" id))
          ((not selected) jolt-nil)       ; record-only
          ((eq? selected 'continue) jolt-nil)
          (else
           ;; Defensive fail-closed seam for later action implementations.
           (checkpoint-bad 'jolt-checkpoint-continue!
                           "unsupported checkpoint action" selected)))))

;; Reserved for action-bearing sites.  Their yield/barrier/fault/cancel
;; semantics are deliberately absent in this slice, so executing one fails
;; before registering, recording, or consulting a plan.
(define (jolt-checkpoint! id dispositions)
  (checkpoint-qualified-id 'jolt-checkpoint! id)
  (checkpoint-normalize-dispositions 'jolt-checkpoint! dispositions)
  (checkpoint-bad 'jolt-checkpoint!
                  "action-bearing checkpoint execution is not implemented" id))

(define kw-checkpoint-sites (keyword #f "sites"))
(define kw-checkpoint-plan (keyword #f "plan"))
(define kw-checkpoint-trace (keyword #f "trace"))
(define kw-checkpoint-next-seq (keyword #f "next-seq"))
(define kw-checkpoint-seq (keyword #f "seq"))
(define kw-checkpoint-actor (keyword #f "actor"))
(define kw-checkpoint-id (keyword #f "id"))
(define kw-checkpoint-hit (keyword #f "hit"))
(define kw-checkpoint-action (keyword #f "action"))
(define kw-checkpoint-continue (keyword #f "continue"))

(define (checkpoint-site-entry<? a b) (string<? (car a) (car b)))
(define (checkpoint-plan-entry<? a b)
  (let ((ak (car a)) (bk (car b)))
    (or (string<? (car ak) (car bk))
        (and (string=? (car ak) (car bk))
             (or (string<? (cadr ak) (cadr bk))
                 (and (string=? (cadr ak) (cadr bk))
                      (< (caddr ak) (caddr bk))))))))

(define (checkpoint-table-pairs table)
  (let-values (((ks vs) (hashtable-entries table)))
    (let loop ((i 0) (out '()))
      (if (= i (vector-length ks)) out
          (loop (+ i 1) (cons (cons (vector-ref ks i) (vector-ref vs i)) out))))))

(define (checkpoint-sites-value pairs)
  (apply jolt-hash-map
    (fold-right
      (lambda (entry out)
        (cons (string-copy (car entry))
              (cons (apply jolt-vector
                           (map (lambda (name) (keyword #f (string-copy name)))
                                (cdr entry)))
                    out)))
      '()
      (sort checkpoint-site-entry<? pairs))))

(define (checkpoint-plan-value pairs)
  (apply jolt-hash-map
    (fold-right
      (lambda (entry out)
        (cons (jolt-vector (string-copy (caar entry))
                           (string-copy (cadar entry))
                           (caddar entry))
              (cons kw-checkpoint-continue out)))
      '()
      (sort checkpoint-plan-entry<? pairs))))

(define (checkpoint-event-value event)
  (jolt-hash-map
    kw-checkpoint-seq (checkpoint-event-seq event)
    kw-checkpoint-actor (string-copy (checkpoint-event-actor event))
    kw-checkpoint-id (string-copy (checkpoint-event-id event))
    kw-checkpoint-hit (checkpoint-event-hit event)
    kw-checkpoint-action
      (if (checkpoint-event-action event) kw-checkpoint-continue jolt-nil)))

(define (jolt-checkpoint-snapshot)
  ;; Copy every mutable controller root while locked.  Persistent Jolt values are
  ;; built afterwards, so the returned snapshot cannot mutate controller state.
  (let* ((raw
           (jolt-with-mutex checkpoint-controller-mu
             (vector (checkpoint-table-pairs checkpoint-sites)
                     (checkpoint-table-pairs checkpoint-plan)
                     (reverse checkpoint-trace-rev)
                     checkpoint-next-seq)))
         (sites (vector-ref raw 0))
         (plan (vector-ref raw 1))
         (trace (vector-ref raw 2))
         (next-seq (vector-ref raw 3)))
    (jolt-hash-map
      kw-checkpoint-sites (checkpoint-sites-value sites)
      kw-checkpoint-plan (checkpoint-plan-value plan)
      kw-checkpoint-trace (apply jolt-vector (map checkpoint-event-value trace))
      kw-checkpoint-next-seq next-seq)))

(def-var! "jolt.host" "checkpoint-register-site!" jolt-checkpoint-register-site!)
(def-var! "jolt.host" "checkpoint-install-plan!" jolt-checkpoint-install-plan!)
(def-var! "jolt.host" "checkpoint-bind-actor!" jolt-checkpoint-bind-actor!)
(def-var! "jolt.host" "checkpoint-unbind-actor!" jolt-checkpoint-unbind-actor!)
(def-var! "jolt.host" "checkpoint-reset!" jolt-checkpoint-reset!)
(def-var! "jolt.host" "checkpoint-snapshot" jolt-checkpoint-snapshot)
