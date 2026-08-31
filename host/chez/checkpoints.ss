;; Deterministic record/continue checkpoints for controlled builds.
;;
;; The controller stores inert data only. Configuration, binding, reset, and a
;; snapshot cut use checkpoint-controller-mu. Established checkpoint hits use
;; only their actor recorder plus one native CAS on the generation clock; actors
;; never serialize through the controller. A checkpoint never invokes a
;; controller callback.

(define checkpoint-controller-mu (make-mutex))

(define checkpoint-bindings (make-weak-eq-hashtable))
(define checkpoint-unbound (list 'checkpoint-unbound))
(define checkpoint-stale (list 'checkpoint-stale))

(define-record-type checkpoint-config
  (fields sites plan)
  (nongenerative jolt-checkpoint-config-v1))

(define-record-type checkpoint-generation
  (fields id config recorders clock started)
  (nongenerative jolt-checkpoint-generation-v1))

(define-record-type checkpoint-recorder
  (fields actor mu hits (mutable trace-rev) (mutable sticky))
  (nongenerative jolt-checkpoint-recorder-v2))

(define-record-type checkpoint-binding
  (fields generation recorder)
  (nongenerative jolt-checkpoint-binding-v1))

(define-record-type checkpoint-clock-state
  (fields open? cut next-seq)
  (nongenerative jolt-checkpoint-clock-state-v1))

(define-record-type checkpoint-token
  (fields binding driver id (mutable phase))
  (nongenerative jolt-checkpoint-token-v1))

(define-record-type checkpoint-event
  (fields seq cut actor id hit action)
  (nongenerative jolt-checkpoint-event-v2))

;; Commit returns one immutable decision that owns the already-published event.
;; Dispatch is deliberately outside the recorder lock; :cancel retains that
;; exact decision in its actor recorder until reset replaces the generation.
(define-record-type checkpoint-decision
  (fields action event generation)
  (nongenerative jolt-checkpoint-decision-v1))

(define (checkpoint-empty-config)
  (make-checkpoint-config (make-hashtable string-hash string=?)
                          (make-hashtable equal-hash equal?)))

(define checkpoint-next-generation-id 0)

(define (checkpoint-new-generation)
  (set! checkpoint-next-generation-id (+ checkpoint-next-generation-id 1))
  (make-checkpoint-generation
    checkpoint-next-generation-id
    (box (checkpoint-empty-config))
    (make-hashtable string-hash string=?)
    ;; Event allocation, snapshot cuts, and reset closure share one exact
    ;; nonparking CAS linearization point.
    (box (make-checkpoint-clock-state #t 0 1))
    (box #f)))

(define checkpoint-current-generation (box (checkpoint-new-generation)))

(define (checkpoint-box-publish! cell next)
  (let loop ((prior (unbox cell)))
    (if (box-cas! cell prior next) prior (loop (unbox cell)))))

(define (checkpoint-current) (unbox checkpoint-current-generation))

(define jolt-vreg-checkpoint-binding 10)

(define (checkpoint-current-binding)
  (let ((fiber (jolt-current-fiber)))
    (if fiber
        (jolt-fiber-checkpoint-binding fiber)
        (let ((binding (virtual-register jolt-vreg-checkpoint-binding)))
          (if (eqv? binding 0) #f binding)))))

(define (checkpoint-current-binding-set! binding)
  (let ((fiber (jolt-current-fiber)))
    (if fiber
        (jolt-fiber-checkpoint-binding-set! fiber binding)
        (set-virtual-register! jolt-vreg-checkpoint-binding (or binding 0)))))

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

;; Must be called with checkpoint-controller-mu held. Configuration tables are
;; copy-on-write: established hits can read one immutable published snapshot
;; without taking the controller lock.
(define (checkpoint-table-copy table hash equiv)
  (let ((next (make-hashtable hash equiv)))
    (let-values (((keys vals) (hashtable-entries table)))
      (let loop ((i 0))
        (unless (= i (vector-length keys))
          (hashtable-set! next (vector-ref keys i) (vector-ref vals i))
          (loop (+ i 1)))))
    next))

(define (checkpoint-register-normalized!/generation who generation id dispositions)
  (let* ((config (unbox (checkpoint-generation-config generation)))
         (sites (checkpoint-config-sites config))
         (prior (hashtable-ref sites id #f)))
    (cond ((not prior)
           (let ((next-sites (checkpoint-table-copy sites string-hash string=?)))
             (hashtable-set! next-sites id dispositions)
             (checkpoint-box-publish!
               (checkpoint-generation-config generation)
               (make-checkpoint-config next-sites (checkpoint-config-plan config)))))
          ((not (equal? prior dispositions))
           (checkpoint-bad who "duplicate checkpoint id has different dispositions"
                           id prior dispositions)))))

(define (jolt-checkpoint-register-site! id dispositions)
  (let ((id (checkpoint-qualified-id 'checkpoint-register-site! id))
        (dispositions
          (checkpoint-normalize-dispositions 'checkpoint-register-site! dispositions)))
    (jolt-with-mutex checkpoint-controller-mu
      (checkpoint-register-normalized!/generation
        'checkpoint-register-site! (checkpoint-current) id dispositions))
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
    (cond ((string=? name "continue") 'continue)
          ((string=? name "yield") 'yield)
          ((string=? name "fault") 'fault)
          ((string=? name "cancel") 'cancel)
          ;; Barrier/manifest/replay are deliberately a later ABI slice.
          (else
           (checkpoint-bad who "unsupported checkpoint action" action)))))

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
      (let* ((generation (checkpoint-current))
             (config (unbox (checkpoint-generation-config generation)))
             (sites (checkpoint-config-sites config)))
      (when (unbox (checkpoint-generation-started generation))
        (checkpoint-bad 'checkpoint-install-plan!
                        "checkpoint plan is frozen after the first reservation"))
      ;; Validate against the exact registered site snapshot and publish only
      ;; after every entry succeeds.  No user procedure runs in this section.
      (for-each
        (lambda (entry)
          (let* ((key (car entry))
                 (id (cadr key))
                 (action (cdr entry))
                 (site (hashtable-ref sites id #f)))
            (unless site
              (checkpoint-bad 'checkpoint-install-plan!
                              "checkpoint plan names an unregistered site" id))
            (unless (member (symbol->string action) site)
              (checkpoint-bad 'checkpoint-install-plan!
                              "checkpoint site does not permit selected action"
                              id action))))
        entries)
      (let ((next (make-hashtable equal-hash equal?)))
        (for-each (lambda (entry) (hashtable-set! next (car entry) (cdr entry))) entries)
        (checkpoint-box-publish!
          (checkpoint-generation-config generation)
          (make-checkpoint-config sites next)))))
    jolt-nil))

(define (checkpoint-mark-started! generation id . who)
  ;; Only the first reservation takes the controller. This serializes the
  ;; plan-freeze boundary with install-plan!; all established hits see #t and
  ;; stay on the actor-local/CAS path.
  (unless (unbox (checkpoint-generation-started generation))
    (jolt-with-mutex checkpoint-controller-mu
      (unless (eq? generation (checkpoint-current))
        (checkpoint-bad (if (null? who) 'jolt-checkpoint-continue! (car who))
                        "checkpoint actor binding is stale after reset" id))
      (unless (unbox (checkpoint-generation-started generation))
        (set-box! (checkpoint-generation-started generation) #t)))))

(define (jolt-checkpoint-bind-actor! actor)
  (unless (and (string? actor) (> (string-length actor) 0))
    (checkpoint-bad 'checkpoint-bind-actor! "checkpoint actor must be a nonempty string" actor))
  (let ((actor (string-copy actor))
        (context (jolt-execution-context-identity)))
    (jolt-with-mutex checkpoint-controller-mu
      (let* ((generation (checkpoint-current))
             (recorders (checkpoint-generation-recorders generation)))
      ;; One live execution context owns an actor at a time.  Otherwise two
      ;; schedulable contexts race for that actor's next hit and make a replay
      ;; plan scheduler-dependent. Bind is rare, so scan the weak context table
      ;; rather than adding a reverse table that would strongly retain contexts.
      (let-values (((contexts actors) (hashtable-entries checkpoint-bindings)))
        (let scan ((i 0))
          (unless (= i (vector-length contexts))
            (let ((binding (vector-ref actors i)))
              ;; Reset replaces this weak table wholesale, so the generation
              ;; check is defensive today. Keep it explicit: it prevents a
              ;; future table-retention optimization from reviving stale owners.
              (when (and (not (eq? context (vector-ref contexts i)))
                         (eq? generation (checkpoint-binding-generation binding))
                         (string=? actor
                                   (checkpoint-recorder-actor
                                     (checkpoint-binding-recorder binding))))
              (checkpoint-bad 'checkpoint-bind-actor!
                              "checkpoint actor is already bound to another execution context"
                              actor)))
            (scan (+ i 1)))))
      (let* ((prior (hashtable-ref recorders actor #f))
             (recorder
               (or prior
                   (let ((fresh
                           (make-checkpoint-recorder actor (make-mutex)
                                                    (make-hashtable equal-hash equal?)
                                                    '() #f)))
                     (hashtable-set! recorders actor fresh)
                     fresh)))
             (binding (make-checkpoint-binding generation recorder)))
        (hashtable-set! checkpoint-bindings context binding)
        (checkpoint-current-binding-set! binding)))))
  jolt-nil)

(define (jolt-checkpoint-unbind-actor!)
  (let ((context (jolt-execution-context-identity)))
    (jolt-with-mutex checkpoint-controller-mu
      (hashtable-delete! checkpoint-bindings context)
      (checkpoint-current-binding-set! #f)))
  jolt-nil)

(define (jolt-checkpoint-reset!)
  (jolt-with-mutex checkpoint-controller-mu
    ;; Close the old generation before publishing its replacement. A commit
    ;; allocation that wins the CAS is ordered before reset; one that loses can
    ;; no longer allocate and retires stale without consuming a hit.
    (checkpoint-clock-close!
      (checkpoint-generation-clock (checkpoint-current)))
    ;; Replacing the central context table invalidates bindings in every live
    ;; thread and fiber at once. Context-local copies carry the old generation
    ;; and fail closed even though another live context cannot be mutated here.
    (set! checkpoint-bindings (make-weak-eq-hashtable))
    (checkpoint-box-publish! checkpoint-current-generation
                             (checkpoint-new-generation))
    (checkpoint-current-binding-set! #f))
  jolt-nil)

;; Exact per-actor reservation. The optional normalized dispositions preserve
;; the closed :continue fast path while the generic entrypoint registers and
;; validates its complete declaration. A sticky cancellation is consulted
;; before site registration, hit allocation, or clock allocation.
(define (checkpoint-record-reserve! id . options)
  (let* ((dispositions (if (null? options) '("continue") (car options)))
         (who (if (or (null? options) (null? (cdr options)))
                  'jolt-checkpoint-continue!
                  (cadr options)))
         (binding (checkpoint-current-binding))
         (generation (checkpoint-current)))
    (when (or (not binding)
              (not (eq? generation (checkpoint-binding-generation binding))))
      (checkpoint-bad who
                      "checkpoint execution requires an explicit actor binding" id))
    (let ((sticky
            (jolt-with-mutex (checkpoint-recorder-mu
                               (checkpoint-binding-recorder binding))
              (checkpoint-recorder-sticky
                (checkpoint-binding-recorder binding)))))
      (if sticky
          sticky
          (let ensure-site ()
            (let* ((config (unbox (checkpoint-generation-config generation)))
                   (site (hashtable-ref (checkpoint-config-sites config) id #f)))
              (cond
                ((not site)
                 (jolt-with-mutex checkpoint-controller-mu
                   (unless (eq? generation (checkpoint-current))
                     (checkpoint-bad who
                                     "checkpoint actor binding is stale after reset" id))
                   (checkpoint-register-normalized!/generation
                     who generation id dispositions))
                 (ensure-site))
                ((not (equal? site dispositions))
                 (checkpoint-bad who
                                 "duplicate checkpoint id has different dispositions"
                                 id site dispositions))
                (else
                 (checkpoint-mark-started! generation id who)
                 ;; Reservation deliberately consumes neither a hit nor a
                 ;; sequence. An abandoned token therefore cannot create a
                 ;; hole in either observational order.
                 (make-checkpoint-token binding
                                        (jolt-execution-context-identity)
                                        id 'reserved)))))))))

;; Allocate one event identity and snapshot-cut membership with a single native
;; CAS, then publish only to the owning recorder. Snapshot advances the same
;; pair, so every returned trace is an exact contiguous committed prefix.
(define (checkpoint-clock-allocate! clock)
  (let loop ((prior (unbox clock)))
    (if (not (checkpoint-clock-state-open? prior))
        #f
        (let ((next
                (make-checkpoint-clock-state
                  #t
                  (checkpoint-clock-state-cut prior)
                  (+ 1 (checkpoint-clock-state-next-seq prior)))))
          (if (box-cas! clock prior next)
              prior
              (loop (unbox clock)))))))

(define (checkpoint-clock-close! clock)
  (let loop ((prior (unbox clock)))
    (if (not (checkpoint-clock-state-open? prior))
        prior
        (let ((next
                (make-checkpoint-clock-state
                  #f
                  (checkpoint-clock-state-cut prior)
                  (checkpoint-clock-state-next-seq prior))))
          (if (box-cas! clock prior next)
              prior
              (loop (unbox clock)))))))

(define (checkpoint-record-commit! token)
  (unless (and (checkpoint-token? token)
               (eq? (checkpoint-token-driver token)
                    (jolt-execution-context-identity)))
    (checkpoint-bad 'checkpoint-record-commit!
                    "checkpoint token belongs to another execution context"
                    token))
  (let* ((binding (checkpoint-token-binding token))
         (generation (checkpoint-binding-generation binding))
         (recorder (checkpoint-binding-recorder binding)))
    (jolt-with-mutex (checkpoint-recorder-mu recorder)
      (unless (eq? 'reserved (checkpoint-token-phase token))
        (checkpoint-bad 'checkpoint-record-commit!
                        "checkpoint token is already retired" token))
      (if (or (not (eq? binding (checkpoint-current-binding)))
              (not (eq? generation (checkpoint-current))))
          (begin
            (checkpoint-token-phase-set! token 'stale)
            checkpoint-stale)
          (let* ((id (checkpoint-token-id token))
                 (hit (+ 1 (hashtable-ref
                             (checkpoint-recorder-hits recorder) id 0)))
                 ;; checkpoint-mark-started! froze this immutable config before
                 ;; the token was issued; plan selection is part of commit so a
                 ;; stale or abandoned reservation consumes no actor hit.
                 (config (unbox (checkpoint-generation-config generation)))
                 (plan-key
                   (list (checkpoint-recorder-actor recorder) id hit))
                 (action
                   (hashtable-ref (checkpoint-config-plan config) plan-key #f))
                 (stamp
                   (checkpoint-clock-allocate!
                     (checkpoint-generation-clock generation)))
                 (cut (and stamp (checkpoint-clock-state-cut stamp)))
                 (seq (and stamp (checkpoint-clock-state-next-seq stamp))))
            (if (not stamp)
                (begin
                  (checkpoint-token-phase-set! token 'stale)
                  checkpoint-stale)
                (let* ((event
                         (make-checkpoint-event
                           seq cut
                           (checkpoint-recorder-actor recorder)
                           id hit action))
                       (decision
                         (make-checkpoint-decision
                           action event (checkpoint-generation-id generation))))
                  (hashtable-set! (checkpoint-recorder-hits recorder) id hit)
                  (checkpoint-recorder-trace-rev-set!
                    recorder
                    (cons event (checkpoint-recorder-trace-rev recorder)))
                  ;; Stickiness is published under this same actor-local lock
                  ;; as the event. A later reservation sees this immutable
                  ;; decision before it can touch sites, hits, or the clock.
                  (when (eq? action 'cancel)
                    (checkpoint-recorder-sticky-set! recorder decision))
                  (checkpoint-token-phase-set! token 'committed)
                  decision)))))))

(define kw-checkpoint-error-type (keyword "jolt.checkpoint" "type"))
(define kw-checkpoint-error-generation (keyword "jolt.checkpoint" "generation"))
(define kw-checkpoint-error-seq (keyword "jolt.checkpoint" "seq"))
(define kw-checkpoint-error-actor (keyword "jolt.checkpoint" "actor"))
(define kw-checkpoint-error-id (keyword "jolt.checkpoint" "id"))
(define kw-checkpoint-error-hit (keyword "jolt.checkpoint" "hit"))
(define kw-checkpoint-fault (keyword #f "fault"))
(define kw-checkpoint-cancel (keyword #f "cancel"))

(define (checkpoint-action-error! type decision)
  (let ((event (checkpoint-decision-event decision)))
    (jolt-throw
      (jolt-ex-info
        (if (eq? type 'fault) "checkpoint fault" "checkpoint cancelled")
        (jolt-hash-map
          kw-checkpoint-error-type
            (if (eq? type 'fault) kw-checkpoint-fault kw-checkpoint-cancel)
          kw-checkpoint-error-generation (checkpoint-decision-generation decision)
          kw-checkpoint-error-seq (checkpoint-event-seq event)
          kw-checkpoint-error-actor (string-copy (checkpoint-event-actor event))
          kw-checkpoint-error-id (string-copy (checkpoint-event-id event))
          kw-checkpoint-error-hit (checkpoint-event-hit event))))))

(define (checkpoint-dispatch! who decision)
  ;; Always invoked after checkpoint-record-commit! has released the recorder
  ;; mutex. A selected action therefore cannot park, yield, or throw while an
  ;; actor-local publication lock is owned.
  (let ((action (checkpoint-decision-action decision)))
    (cond ((not action) jolt-nil)           ; record-only default
          ((eq? action 'continue) jolt-nil)
          ((eq? action 'yield)
           (if (jolt-current-fiber)
               (sa-fiber-yield)
               (thread-yield!))
           jolt-nil)
          ((eq? action 'fault) (checkpoint-action-error! 'fault decision))
          ((eq? action 'cancel) (checkpoint-action-error! 'cancel decision))
          (else
           (checkpoint-bad who "unsupported checkpoint action" action)))))

(define (checkpoint-execute! who id dispositions)
  (let* ((reserved (checkpoint-record-reserve! id dispositions who))
         (decision
           (if (checkpoint-decision? reserved)
               reserved
               (checkpoint-record-commit! reserved))))
    (cond ((eq? decision checkpoint-stale)
           (checkpoint-bad who "checkpoint actor binding is stale after reset" id))
          ((checkpoint-decision? decision)
           (checkpoint-dispatch! who decision))
          (else
           (checkpoint-bad who "invalid checkpoint runtime decision" decision)))))

;; Closed nonparking leaf for a continue-only site. Its declaration remains
;; exact, so a controlled action site cannot enter through this fast path.
(define (jolt-checkpoint-continue! id)
  (checkpoint-execute! 'jolt-checkpoint-continue!
                       (checkpoint-qualified-id 'jolt-checkpoint-continue! id)
                       '("continue")))

;; Generic action-bearing entrypoint. Barrier, manifests, replay and minimizer
;; state are deliberately absent from this ship-ready slice.
(define (jolt-checkpoint! id dispositions)
  (let ((id (checkpoint-qualified-id 'jolt-checkpoint! id))
        (dispositions
          (checkpoint-normalize-dispositions 'jolt-checkpoint! dispositions)))
    (when (member "barrier" dispositions)
      (checkpoint-bad 'jolt-checkpoint!
                      "barrier checkpoint execution is not implemented" id))
    (checkpoint-execute! 'jolt-checkpoint! id dispositions)))

(define kw-checkpoint-sites (keyword #f "sites"))
(define kw-checkpoint-plan (keyword #f "plan"))
(define kw-checkpoint-trace (keyword #f "trace"))
(define kw-checkpoint-next-seq (keyword #f "next-seq"))
(define kw-checkpoint-generation (keyword #f "generation"))
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

(define (checkpoint-action-value action)
  (if action
      (keyword #f (symbol->string action))
      jolt-nil))

(define (checkpoint-plan-value pairs)
  (apply jolt-hash-map
    (fold-right
      (lambda (entry out)
        (cons (jolt-vector (string-copy (caar entry))
                           (string-copy (cadar entry))
                           (caddar entry))
              (cons (checkpoint-action-value (cdr entry)) out)))
      '()
      (sort checkpoint-plan-entry<? pairs))))

(define (checkpoint-event-value event)
  (jolt-hash-map
    kw-checkpoint-seq (checkpoint-event-seq event)
    kw-checkpoint-actor (string-copy (checkpoint-event-actor event))
    kw-checkpoint-id (string-copy (checkpoint-event-id event))
    kw-checkpoint-hit (checkpoint-event-hit event)
    kw-checkpoint-action
      (checkpoint-action-value (checkpoint-event-action event))))

(define (checkpoint-clock-cut! clock)
  (let loop ((prior (unbox clock)))
    (unless (checkpoint-clock-state-open? prior)
      (checkpoint-bad 'checkpoint-snapshot
                      "current checkpoint generation is closed"))
    (let ((next
            (make-checkpoint-clock-state
              #t
              (+ 1 (checkpoint-clock-state-cut prior))
              (checkpoint-clock-state-next-seq prior))))
      (if (box-cas! clock prior next)
          prior
          (loop (unbox clock))))))

(define (checkpoint-recorder-prefix recorder cut)
  (let ((head
          (jolt-with-mutex (checkpoint-recorder-mu recorder)
            (checkpoint-recorder-trace-rev recorder))))
    (filter (lambda (event) (<= (checkpoint-event-cut event) cut)) head)))

(define (jolt-checkpoint-snapshot)
  ;; Capture the immutable config, recorder set, and one atomic clock cut under
  ;; the terminal controller mutex. Each recorder head is then captured under
  ;; only its own lock. Persistent Jolt values and sorting happen after release.
  (let* ((raw
           (jolt-with-mutex checkpoint-controller-mu
             (let* ((generation (checkpoint-current))
                    (config (unbox (checkpoint-generation-config generation)))
                    (stamp
                      (checkpoint-clock-cut!
                        (checkpoint-generation-clock generation))))
               (vector
                 (checkpoint-generation-id generation)
                 (checkpoint-table-pairs (checkpoint-config-sites config))
                 (checkpoint-table-pairs (checkpoint-config-plan config))
                 (map cdr
                      (checkpoint-table-pairs
                        (checkpoint-generation-recorders generation)))
                 (checkpoint-clock-state-cut stamp)
                 (checkpoint-clock-state-next-seq stamp)))))
         (generation-id (vector-ref raw 0))
         (sites (vector-ref raw 1))
         (plan (vector-ref raw 2))
         (recorders (vector-ref raw 3))
         (cut (vector-ref raw 4))
         (next-seq (vector-ref raw 5))
         (trace
           (sort
             (lambda (a b) (< (checkpoint-event-seq a) (checkpoint-event-seq b)))
             (fold-left
               (lambda (events recorder)
                 (append (checkpoint-recorder-prefix recorder cut) events))
               '()
               recorders))))
    (jolt-hash-map
      kw-checkpoint-generation generation-id
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
