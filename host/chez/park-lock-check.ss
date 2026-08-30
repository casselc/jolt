;; park-lock-check.ss — no fiber may leave the CPU while its carrier holds a
;; counted lock, checked as a SHAPE before it can run.
;;
;; THE RULE, which host/chez/locks.ss states and both switch points enforce:
;;
;;   a fiber never leaves the CPU while its carrier holds a counted lock.
;;
;; The runtime check (jolt-locks-assert-none!) is sound and complete for parks
;; that HAPPEN — it sees a park one call away, or inside user code the lock never
;; wrote, because it reads the lock count at the switch. What it cannot do is see
;; a park that nothing exercises. jolt-04ee was exactly that: loader.ss parked a
;; waiting fiber inside ldr-load-mu for two releases, and the window needed
;; concurrent requires of one namespace from several fibers and threads at once,
;; so it sat there reported-but-unreproduced. This check is the half that does not
;; need the window. It reads the code.
;;
;; WHAT IT DOES. Every handwritten host .ss file is read AS DATA (comments and
;; strings cannot lie that way, and the previous mechanism was grep). Then:
;;
;;   1. build the call graph over host definitions — every symbol in OPERATOR
;;      position in each definition's body, with quote bodies, binding names and
;;      case datums walked past so a local named like a primitive is not a call to
;;      it.
;;   2. close "can park" over that graph from the two switch points and their
;;      wrappers, to a fixpoint. So a helper that parks is a parker, and so is
;;      anything that calls the helper, however deep.
;;   3. report every call to a parker or generic-dispatch boundary inside either
;;      a jolt-with-mutex body or a balanced manual jolt-lock!/jolt-unlock!
;;      region, naming the file, the enclosing definition and the callee.
;;   4. identify every jolt-with-logical-mutex region by its top-level mutex
;;      binding, report generic dispatch there as separate issue-backed debt,
;;      close named acquisitions through helpers, and reject unknown identities
;;      or a cycle in the resulting whole-program lock-order graph.
;;
;; Step 2 is the whole value: the lexical scan this replaces found NOTHING in the
;; pre-fix loader, because ldr-begin-load!'s region called ldr-wait-for-load! and
;; the park was in there. One level of indirection was enough to hide it.
;;
;; TWO KINDS OF FINDING, because the two hazards are found two different ways and
;; mixing them made the check useless before it made it wrong:
;;
;;   park       a call, at any depth in the call graph, to one of the runtime's own
;;              park primitives. This is jolt-04ee, and the transitive closure is
;;              what sees it.
;;   dispatch   a call, at any depth in the call graph, to an explicit generic
;;              boundary: jolt-invoke, generic equality, renderer entrypoints,
;;              or ac-xrf-apply. Named boundaries close just as parkers do. A
;;              procedure-valued operator directly in a region is also reported;
;;              treating every internal higher-order helper as a transitive seed
;;              made unrelated runtime code one giant false-positive component.
;;   logical-dispatch
;;              the same explicit generic boundary while a named logical mutex
;;              is held. It may park safely, but remains a semantic reentry and
;;              contention obligation owned by that logical region.
;;
;; WHAT IT DOES NOT DO, stated rather than left to be discovered:
;;
;;   - arbitrary control flow around a hand-held lock is not proved. The checker
;;     recognizes balanced acquire/release calls in one sequential body. A
;;     branch-dependent or escaping region remains the runtime check's job.
;;   - an unannotated global cell containing a procedure is indistinguishable
;;     from an ordinary named procedure. Known runtime hooks are enumerated
;;     below; lexically bound procedure operators are recognized structurally.
;;
;; So neither half is sufficient and the pair is: this one rejects the shape
;; before it runs, and the other one catches what a static reading cannot see.
;;
;; It also checks its own teeth. If jolt-locks-assert-none! ever stops being
;; called from a switch point, the runtime half is gone and every gate still
;; passes — so the switch points are checked BY NAME for that call, and losing it
;; fails here.
;;
;;   sh host/chez/park-lock-check.sh          check against the allowlist
;;   sh host/chez/park-lock-check.sh --regen  regenerate it (review the diff!)
(import (chezscheme))
(load "host/chez/static-analysis-debt.ss")

(define scope-roots '("host/chez" "host/chez/java"))
(define allowlist-file "host/chez/park-lock-allowlist.txt")
(define debt-file "host/chez/park-lock-known-debt.txt")
(define logical-debt-file "host/chez/logical-region-known-debt.txt")
(define issue-prefix "issue=chucklehead-dev/jolt-aspect-packs#")

;; The two switch points. Every park in the runtime ends at one of them, and each
;; one must call the assertion — checked below, because a check nobody calls is
;; indistinguishable from a check that passes.
(define switch-points '(jolt-fiber-to-scheduler! jolt-sm-park!))
(define assertion 'jolt-locks-assert-none!)

;; A function on this list may reach a switch point without making its callers
;; parkers only while it directly asserts that no counted lock is held before
;; every direct call that can park.
;; This is deliberately a tiny explicit list, not an annotation mechanism:
;; deleting or moving the assertion makes the teeth check fail closed.
(define guarded-park-boundaries
  '(jolt-logical-mutex-wait! jolt-publication-gate-wait!))

;; The closure's seeds: the switch points themselves and the two wrappers that
;; exist only to reach them.
(define park-seeds
  '(jolt-fiber-to-scheduler! jolt-sm-park! jolt-fiber-park! sa-fiber-yield))

;; Calling into code the lock did not write. `apply` is modeled explicitly below,
;; because its target appears in value position even though it is invoked.
(define dynamic-call '|procedure-valued-dispatch|)
(define trusted-dynamic-call '|trusted-procedure-valued-dispatch|)
(define local-recursive-call '|local-recursive-call|)

;; Checkpoints have a deliberately asymmetric ABI.  The compiler emits the
;; closed continue-only leaf with one canonical literal identifier; every call
;; through the generic entry point may select an action and is therefore a
;; counted-lock hazard.  Keep the hazard as a synthetic call-graph node so a
;; wrapper around either an action-bearing call or an unsupported leaf shape is
;; rejected transitively without contaminating the reviewed continue-only leaf.
(define checkpoint-continue-call 'jolt-checkpoint-continue!)
(define checkpoint-generic-call 'jolt-checkpoint!)
(define checkpoint-hazard-call '|checkpoint-action-or-unknown|)

(define (checkpoint-entrypoint? x)
  (or (eq? x checkpoint-continue-call)
      (eq? x checkpoint-generic-call)))

(define (qualified-checkpoint-id? x)
  (and (string? x)
       (let ((n (string-length x)))
         (and (> n 2)
              (let loop ((i 1))
                (cond ((>= i (- n 1)) #f)
                      ((char=? (string-ref x i) #\/) #t)
                      (else (loop (+ i 1)))))))))

(define (canonical-continue-checkpoint-call? x resolved)
  (and (eq? resolved checkpoint-continue-call)
       (= (length x) 2)
       (qualified-checkpoint-id? (cadr x))))

;; Scheme macro wrappers are outside the supported checkpoint surface. Jolt
;; checkpoint declarations are compiler-owned IR, and ordinary named Scheme
;; procedures already participate in the transitive hazard closure. Scan syntax
;; transformer data structurally (including templates) so expansion identity is
;; never required for this safety property.
(define (checkpoint-symbols-in-syntax x)
  (cond ((symbol? x) (if (checkpoint-entrypoint? x) (list x) '()))
        ((pair? x)
         (append (checkpoint-symbols-in-syntax (car x))
                 (checkpoint-symbols-in-syntax (cdr x))))
        (else '())))

(define (emit-checkpoint-syntax-hazards forms in-lock? emit)
  (for-each (lambda (sym) (emit sym in-lock? #f))
            (checkpoint-symbols-in-syntax forms)))

(define (walk-local-syntax d lexical-lock? manual-lock? bound emit)
  (let ((bindings (and (pair? (cdr d)) (cadr d))))
    (when (list? bindings)
      (for-each
        (lambda (binding)
          ;; Exclude the macro's binding name; only its transformer is policy
          ;; relevant. A macro may happen to use a checkpoint-like local name.
          (when (and (pair? binding) (pair? (cdr binding)))
            (emit-checkpoint-syntax-hazards
              (cdr binding) (or lexical-lock? (pair? manual-lock?)) emit)))
        bindings))
    ;; Transformer execution is compile-time. Runtime effects live in the body.
    (walk-forms (cddr d) lexical-lock? manual-lock? bound emit)))

;; Chez reads #N%op as ($primitive N op), and #%op as ($primitive op).
;; Only the current arithmetic/bitwise leaves are exempt: they cannot invoke a
;; callback, transfer control, block, or park. A new/unknown primitive fails
;; closed as procedure-valued dispatch until this reviewed list is extended.
(define leaf-primitive-names
  '(/ bitwise-and fl* fl+ fx* fx+ fx- fx<? fx=? fx>=?
      fxand fxior fxsll fxsra fxsrl fxxor))

(define (primitive-head-name head)
  (and (list? head) (pair? head) (eq? (car head) '$primitive)
       (cond ((and (= (length head) 2) (symbol? (cadr head))) (cadr head))
             ((and (= (length head) 3) (integer? (cadr head))
                   (symbol? (caddr head)))
              (caddr head))
             (else #f))))

(define (leaf-primitive-head? head)
  (let ((name (primitive-head-name head)))
    (and name (memq name leaf-primitive-names))))

;; Named public/generic boundaries. Some are also discovered structurally today
;; (jolt=2 walks predicate/handler arms; ac-xrf-apply reaches jolt-invoke), but
;; naming the contract keeps a refactor from silently weakening the gate.
(define dispatch-seeds
  (list 'jolt-invoke 'jolt= 'jolt=2 'ac-xrf-apply
        'jolt-str-render-one 'jolt-pr-str 'jolt-pr-readable
        'jolt-pr-readable-dispatch 'jolt-object-content))

;; Globals invoked as procedures rather than defined as procedures. The print
;; hook is user-installed and therefore generic. The fiber wake hook is the one
;; trusted exception: async.ss invokes it while holding alt-handler-wmu, but
;; fibers-async.ss installs exactly sa-fiber-resume after both halves load. The
;; teeth check below verifies that source fact and that the target is neither a
;; parker nor a generic dispatcher before the exception is accepted.
(define procedure-value-calls '(pr-user-method-render jolt-fiber-wake-fn))
(define trusted-installed-callbacks '((jolt-fiber-wake-fn . sa-fiber-resume)))

;; Private higher-order helpers whose callback providers are exhaustively visible
;; in this host tree. Each spec is (definition callback-argument allowed-symbols),
;; where the symbol `lambda` permits literal lambda providers. The teeth check
;; rejects a new opaque provider, so this is narrower than an allowlist entry:
;;   - pw-byte-port-memo receives only Chez's standard stream openers;
;;   - ldr-libs-update! receives only loader-owned set transforms;
;;   - jolt-lock-wait receives only runtime decision thunks implementing its
;;     documented decide-under-mutex protocol;
;;   - maybe-cc-range receives only parse-cc-body's named-let continuation.
(define trusted-direct-dispatch-sites
  '((pw-byte-port-memo 2 (standard-output-port standard-error-port))
    (ldr-libs-update! 1 (lambda))
    (jolt-lock-wait 2 (lambda))
    (maybe-cc-range 6 (loop))))

;; Chez procedures whose callback positions are invoked synchronously before the
;; consumer returns. Positions are one-based in the argument list. Literal
;; callback bodies can therefore be analyzed in the caller's execution region;
;; a computed callback remains an explicit dispatch boundary.
(define synchronous-callback-consumers
  '((for-each 1) (filter 1)))

(define (synchronous-callback-positions name)
  (let ((entry (assq name synchronous-callback-consumers)))
    (if entry (cdr entry) '())))

(define (trusted-bound name bound)
  (let ((spec (assq name trusted-direct-dispatch-sites)))
    (if (not spec)
        bound
        (let ((i (- (cadr spec) 1)))
          (if (or (< i 0) (>= i (length bound))
                  (not (symbol? (list-ref bound i))))
              bound
              (let ((callback (list-ref bound i)))
                (map (lambda (entry)
                       (if (and (symbol? entry) (eq? entry callback))
                           (cons entry trusted-dynamic-call)
                           entry))
                     bound)))))))

;; The lock region. Only jolt-with-mutex: a MONITOR is not a counted lock —
;; ownership is a field, which is what lets a fiber hold one across a park — so
;; jolt-with-monitor bodies are not regions and must not be flagged.
(define lock-form 'jolt-with-mutex)
(define manual-lock-calls '(jolt-lock! jolt-chan-lock!))
(define manual-unlock-calls '(jolt-unlock! jolt-chan-unlock!))

;; Logical mutexes deliberately permit arbitrary work and fiber parks.  They
;; therefore need a different property from counted locks: generic dispatch is
;; reviewed as an explicit obligation, while nested named acquisitions form a
            ;; whole-program lock-order graph whose cycles are rejected.  Dynamic parameters
;; let the existing syntax-aware walker carry region identity without growing a
;; second, subtly different source walker.
(define logical-lock-form 'jolt-with-logical-mutex)
(define unknown-logical-lock '|unknown-logical-mutex|)
(define known-logical-locks (make-parameter (make-eq-hashtable)))
(define current-logical-regions (make-parameter '()))
(define logical-effects-enabled? (make-parameter #t))
(define logical-acquire-emitter (make-parameter (lambda (held acquired) (void))))
(define logical-hard-emitter (make-parameter (lambda (kind detail) (void))))

(define (logical-lock-identity x bound)
  (if (symbol? x)
      (let ((target (resolve-bound-operator x bound)))
        (if (and (not (eq? target dynamic-call))
                 (hashtable-ref (known-logical-locks) target #f))
            target
            unknown-logical-lock))
      unknown-logical-lock))

;; ---------------------------------------------------------------------------
;; small helpers
;; ---------------------------------------------------------------------------

(define (has-suffix? s p)
  (let ((ls (string-length s)) (lp (string-length p)))
    (and (>= ls lp) (string=? (substring s (- ls lp) ls) p))))

(define (sort-list lst cmp) (sort cmp lst))

(define (files-in dir)
  (let loop ((es (directory-list dir)) (acc '()))
    (cond
      ((null? es) acc)
      ((and (has-suffix? (car es) ".ss")
            (not (file-directory? (string-append dir "/" (car es)))))
       (loop (cdr es) (cons (string-append dir "/" (car es)) acc)))
      (else (loop (cdr es) acc)))))

(define (find-files)
  (sort-list
    (let loop ((ds scope-roots) (acc '()))
      (if (null? ds) acc (loop (cdr ds) (append (files-in (car ds)) acc))))
    string<?))

(define (read-datums path)
  (let ((p (open-input-file path)))
    (let loop ((acc '()))
      (let ((x (read p)))
        (if (eof-object? x)
            (begin (close-port p) (reverse acc))
            (loop (cons x acc)))))))

;; ---------------------------------------------------------------------------
;; the walk
;; ---------------------------------------------------------------------------
;; One walker, three jobs, distinguished by what the caller does with each
;; emission: the call graph (operator position), the park findings (operator
;; position inside a region), and the dispatch findings (operator position in a
;; region). Written once so the three can never disagree about what a call is.
;;
;; emit is called as (emit sym in-lock? operator?) for every symbol reached, with
;; quote bodies, binding names, lambda formals and case datums walked past.
;; BOUND records lexical variables so `(render x)` is a procedure-valued call,
;; not a fictitious edge to a global definition named render.

(define (formal-names f)
  (cond ((null? f) '())
        ((symbol? f) (list f))
        ((pair? f) (append (formal-names (car f)) (formal-names (cdr f))))
        (else '())))

;; A bound entry is either NAME (an unknown/procedure-valued local) or
;; (NAME . TARGET), a proven direct alias to a named procedure.  Keeping aliases
;; in the lexical environment closes the otherwise-silent hole in
;; `(let ((f callback)) (jolt-with-mutex mu (f)))`, while allowing
;; `(let ((f internal-leaf)) ... (f))` to retain the precise internal edge.
(define (bound-entry name bound)
  (let loop ((xs bound))
    (cond ((null? xs) #f)
          ((and (symbol? (car xs)) (eq? name (car xs))) (car xs))
          ((and (pair? (car xs)) (eq? name (caar xs))) (car xs))
          (else (loop (cdr xs))))))

(define (resolve-bound-operator name bound)
  (let ((entry (bound-entry name bound)))
    (cond ((not entry) name)
          ((symbol? entry) dynamic-call)
          (else (cdr entry)))))

(define (resolve-operator name bound)
  (let ((target (resolve-bound-operator name bound)))
    (if (or (eq? target dynamic-call)
            (and (memq target procedure-value-calls)
                 (not (assq target trusted-installed-callbacks))))
        dynamic-call
        target)))

(define (binding-names b)
  (if (pair? b) (formal-names (car b)) '()))

(define (binding-aliases b bound)
  (let ((names (binding-names b))
        (init (and (pair? b) (pair? (cdr b)) (cadr b))))
    (cond
      ;; A destructuring/multi-value binding has no statically exact
      ;; name-to-value correspondence here; fail closed if one is invoked.
      ((not (= (length names) 1)) names)
      ((or (not init)
           (and (pair? init) (memq (car init) '(lambda case-lambda))))
       names)
      ((symbol? init)
       (let ((target (resolve-bound-operator init bound)))
         (if (eq? target dynamic-call)
             names
             (list (cons (car names) target)))))
      (else names))))

(define (manual-acquire? f)
  (and (pair? f) (symbol? (car f)) (memq (car f) manual-lock-calls)))
(define (manual-release? f)
  (and (pair? f) (symbol? (car f)) (memq (car f) manual-unlock-calls)))

;; Manual ownership is a multiset of syntactic lock identities. A release removes
;; exactly one proven matching acquisition; a mismatched release preserves every
;; held lock. This models counted re-entry and prevents an unlock of B from
;; laundering a held A. Branch joins retain the maximum count for each identity.
(define unknown-lock '|unknown-counted-lock|)
(define (manual-lock-key f)
  (if (and (pair? f) (pair? (cdr f)))
      (list (if (memq (car f) '(jolt-lock! jolt-unlock!))
                'runtime-lock 'channel-lock)
            (cadr f))
      unknown-lock))

(define (remove-one-equal key xs)
  (cond ((null? xs) '())
        ((equal? key (car xs)) (cdr xs))
        (else (cons (car xs) (remove-one-equal key (cdr xs))))))

(define (equal-count key xs)
  (fold-left (lambda (n x) (if (equal? key x) (+ n 1) n)) 0 xs))

(define (repeat-cons x n out)
  (if (= n 0) out (repeat-cons x (- n 1) (cons x out))))

(define (manual-state-join a b)
  (let loop ((keys (append a b)) (seen '()) (out '()))
    (cond ((null? keys) out)
          ((member (car keys) seen) (loop (cdr keys) seen out))
          (else
           (let* ((key (car keys))
                  (n (max (equal-count key a) (equal-count key b))))
             (loop (cdr keys) (cons key seen) (repeat-cons key n out)))))))

(define (manual-state-after-forms forms state)
  (fold-left (lambda (s f) (manual-state-after f s)) state forms))

(define (manual-state-after-let f state)
  (let* ((named? (and (pair? (cdr f)) (symbol? (cadr f))))
         (bs (if named? (caddr f) (cadr f)))
         (body (if named? (cdddr f) (cddr f)))
         (after-inits
           (if (list? bs)
               (fold-left
                 (lambda (s b)
                   (if (and (pair? b) (pair? (cdr b)))
                       (manual-state-after (cadr b) s) s))
                 state bs)
               state)))
    (manual-state-after-forms body after-inits)))

(define (manual-state-join* states)
  (fold-left manual-state-join '() states))

(define (manual-state-after-cond clauses state)
  (let loop ((cs clauses) (fallthrough state) (out '()))
    (cond
      ((null? cs) (manual-state-join out fallthrough))
      ((not (pair? (car cs))) (loop (cdr cs) fallthrough out))
      ((eq? (caar cs) 'else)
       (manual-state-join out
                          (manual-state-after-forms (cdar cs) fallthrough)))
      (else
       (let* ((test-state (manual-state-after (caar cs) fallthrough))
              (match-state (manual-state-after-forms (cdar cs) test-state)))
         (loop (cdr cs) test-state (manual-state-join out match-state)))))))

(define (manual-state-after-case f state)
  (let ((key-state (if (pair? (cdr f))
                       (manual-state-after (cadr f) state) state)))
    (let loop ((cs (if (pair? (cdr f)) (cddr f) '()))
               (out '()) (has-else? #f))
      (if (null? cs)
          (if has-else? out (manual-state-join out key-state))
          (let ((cl (car cs)))
            (if (pair? cl)
                (loop (cdr cs)
                      (manual-state-join
                        out (manual-state-after-forms (cdr cl) key-state))
                      (or has-else? (eq? (car cl) 'else)))
                (loop (cdr cs) out has-else?)))))))

(define (contains-manual-acquire? x)
  (cond ((not (pair? x)) #f)
        ((and (list? x) (eq? (car x) 'quote)) #f)
        ((manual-acquire? x) #t)
        (else (or (contains-manual-acquire? (car x))
                  (contains-manual-acquire? (cdr x))))))

(define (manual-state-after-guard f state)
  (let* ((body (if (pair? (cdr f)) (cddr f) '()))
         (body-state (manual-state-after-forms body state))
         ;; An exception may leave any prefix of the body active. If it contains
         ;; an acquire, retain a sticky unknown ownership through the handler.
         (caught-state (if (contains-manual-acquire? body)
                           (cons unknown-lock (manual-state-join state body-state))
                           (manual-state-join state body-state)))
         (clauses (if (and (pair? (cdr f)) (pair? (cadr f)))
                      (cdadr f) '())))
    (manual-state-join*
      (cons body-state
            (map (lambda (cl)
                   (if (pair? cl)
                       (manual-state-after-forms cl caught-state)
                       caught-state))
                 clauses)))))

(define (manual-state-after-do f state)
  (let* ((bindings (if (pair? (cdr f)) (cadr f) '()))
         (after-inits
           (if (list? bindings)
               (fold-left
                 (lambda (s b)
                   (if (and (pair? b) (pair? (cdr b)))
                       (manual-state-after (cadr b) s) s))
                 state bindings)
               state))
         (test-clause (if (pair? (cddr f)) (caddr f) '()))
         (test-state (if (pair? test-clause)
                         (manual-state-after (car test-clause) after-inits)
                         after-inits))
         (done-state (if (pair? test-clause)
                         (manual-state-after-forms (cdr test-clause) test-state)
                         test-state))
         (body-state (manual-state-after-forms (if (pair? (cddr f)) (cdddr f) '())
                                               test-state))
         (step-state
           (if (list? bindings)
               (fold-left
                 (lambda (s b)
                   (if (and (pair? b) (pair? (cddr b)))
                       (manual-state-after (caddr b) s) s))
                 body-state bindings)
               body-state))
         (loop-forms (append (if (pair? (cddr f)) (cdddr f) '())
                             (if (list? bindings)
                                 (filter
                                   (lambda (x) x)
                                   (map (lambda (b)
                                          (and (pair? b) (pair? (cddr b))
                                               (caddr b)))
                                        bindings))
                                 '())))
         (joined (manual-state-join done-state step-state)))
    ;; Iteration count is not statically bounded. Any acquire in the loop may
    ;; have happened more times than visible releases, so keep ownership sticky.
    (if (contains-manual-acquire? loop-forms)
        (cons unknown-lock joined)
        joined)))

(define (manual-state-after-short-circuit forms state)
  ;; The first expression is evaluated; after each expression execution may
  ;; either stop or continue. Join every possible stopping prefix.
  (if (null? forms)
      state
      (let loop ((rest forms) (continued state) (out '()))
        (if (null? rest)
            out
            (let ((next (manual-state-after (car rest) continued)))
              (loop (cdr rest) next (manual-state-join out next)))))))

(define (manual-state-after f state)
  (cond ((manual-acquire? f) (cons (manual-lock-key f) state))
        ((manual-release? f)
         (let ((key (manual-lock-key f)))
           (if (member key state) (remove-one-equal key state) state)))
        ((and (pair? f) (eq? (car f) 'begin))
         (manual-state-after-forms (cdr f) state))
        ((and (pair? f) (memq (car f)
                              '(let let* letrec letrec* let-values let*-values)))
         (manual-state-after-let f state))
        ((and (pair? f) (eq? (car f) 'if) (pair? (cdr f)))
         (let* ((test-state (manual-state-after (cadr f) state))
                (yes-state (if (pair? (cddr f))
                               (manual-state-after (caddr f) test-state)
                               test-state))
                (no-state (if (pair? (cdddr f))
                              (manual-state-after (cadddr f) test-state)
                              test-state)))
           (manual-state-join yes-state no-state)))
        ((and (pair? f) (eq? (car f) 'cond))
         (manual-state-after-cond (cdr f) state))
        ((and (pair? f) (eq? (car f) 'case))
         (manual-state-after-case f state))
        ((and (pair? f) (memq (car f) '(when unless)) (pair? (cdr f)))
         (let* ((test-state (manual-state-after (cadr f) state))
                (body-state (manual-state-after-forms (cddr f) test-state)))
           (manual-state-join test-state body-state)))
        ((and (pair? f) (eq? (car f) 'guard))
         (manual-state-after-guard f state))
        ((and (pair? f) (eq? (car f) 'do))
         (manual-state-after-do f state))
        ((and (pair? f) (memq (car f) '(and or)))
         (manual-state-after-short-circuit (cdr f) state))
        ((and (pair? f) (memq (car f)
                              '(quote lambda case-lambda define define-syntax)))
         state)
        ;; For an ordinary compound expression the operator expression and every
        ;; argument are evaluated. Propagate syntactically visible lock effects
        ;; without assuming anything about the callee's implementation.
        ((pair? f) (manual-state-after-forms f state))
        (else state)))

;; Sequential bodies advance the identity-aware state after each form. Nested
;; control forms return conservative joined state, so ownership cannot disappear
;; merely because an acquire was conditional or lexically nested.
(define (walk-forms forms lexical-lock? manual-state bound emit)
  (let loop ((fs forms) (state manual-state))
    (unless (null? fs)
      (let ((f (car fs)))
        (walk f lexical-lock? state bound emit)
        (loop (cdr fs) (manual-state-after f state))))))

;; binding lists: walk the INITS, not the names. (let ((jolt-invoke 1)) …) binds a
;; local; it is not a call, and a scan that counted it would be answered with an
;; allowlist entry rather than a fix.
(define (walk-bindings bs lexical-lock? manual-state bound emit)
  (fold-left
    (lambda (state b)
      (if (and (pair? b) (pair? (cdr b)))
          (begin (walk (cadr b) lexical-lock? state bound emit)
                 (manual-state-after (cadr b) state))
          state))
    manual-state bs))

(define (walk-let d lexical-lock? manual-state bound emit)
  (let* ((named? (and (pair? (cdr d)) (symbol? (cadr d))))
         (bs (if named? (caddr d) (cadr d)))
         (body (if named? (cdddr d) (cddr d)))
         (kind (car d)))
    (when (list? bs)
      (if (memq kind '(let* let*-values))
          ;; Sequential forms see aliases introduced by earlier bindings.
          (let loop ((rest bs) (env bound) (state manual-state))
            (if (null? rest)
                (walk-forms body lexical-lock? state env emit)
                (let ((b (car rest)))
                  (when (and (pair? b) (pair? (cdr b)))
                    (walk (cadr b) lexical-lock? state env emit))
                  (loop (cdr rest)
                        (append (binding-aliases b env) env)
                        (if (and (pair? b) (pair? (cdr b)))
                            (manual-state-after (cadr b) state) state)))))
          (begin
            (let ((after-inits
                    (walk-bindings bs lexical-lock? manual-state bound emit))
                  (body-bound
                    (append
                      ;; Named-let recursion is a precise self edge, while its
                      ;; loop variables are ordinary unknown lexical values.
                      (if named? (list (cons (cadr d) local-recursive-call)) '())
                      (fold-left
                        (lambda (env b) (append (binding-aliases b bound) env))
                        '() bs)
                      bound)))
              (walk-forms body lexical-lock? after-inits body-bound emit)))))))

(define (walk-lambda-body d lexical-lock? manual-lock? bound emit)
  ;; (lambda formals body …) — formals are names, never calls
  (walk-forms (cddr d) lexical-lock? manual-lock?
              (append (formal-names (cadr d)) bound) emit))

(define (walk-case-lambda d lexical-lock? manual-lock? bound emit)
  (for-each (lambda (cl)
              (when (pair? cl)
                (walk-forms (cdr cl) lexical-lock? manual-lock?
                            (append (formal-names (car cl)) bound) emit)))
            (cdr d)))

(define (walk-define d lexical-lock? manual-lock? bound emit)
  ;; (define (name . formals) body …) or (define name expr)
  (if (pair? (cadr d))
      (parameterize ((logical-effects-enabled? #f))
        (walk-forms (cddr d) lexical-lock? manual-lock?
                    (append (formal-names (cdadr d)) bound) emit))
      (walk-forms (cddr d) lexical-lock? manual-lock? bound emit)))

(define (walk-case d lexical-lock? manual-lock? bound emit)
  ;; (case key ((datum …) expr …) … (else expr …)) — the datum lists are DATA
  (walk (cadr d) lexical-lock? manual-lock? bound emit)
  (let ((key-state (manual-state-after (cadr d) manual-lock?)))
    (for-each (lambda (cl) (when (pair? cl)
                             (walk-forms (cdr cl) lexical-lock? key-state bound emit)))
            (cddr d))))

(define (walk-arrow-receiver receiver lexical-lock? manual-lock? bound emit)
  ;; `cond` and `guard` evaluate the receiver expression and then invoke the
  ;; resulting procedure synchronously.  A literal lambda is therefore fully
  ;; visible and must be analyzed in the current region; it is not an opaque
  ;; dynamic call.  A computed receiver remains fail-closed after its expression
  ;; has been evaluated.
  (cond
    ((symbol? receiver)
     (emit (resolve-operator receiver bound)
           (or lexical-lock? (pair? manual-lock?)) #t))
    ((and (pair? receiver) (eq? (car receiver) 'lambda))
     (walk-lambda-body receiver lexical-lock? manual-lock? bound emit))
    (else
     (walk receiver lexical-lock? manual-lock? bound emit)
     (emit dynamic-call (or lexical-lock? (pair? manual-lock?)) #t))))

(define (walk-cond d lexical-lock? manual-lock? bound emit)
  (let loop ((clauses (cdr d)) (fallthrough manual-lock?))
    (unless (null? clauses)
      (let ((cl (car clauses)))
       (when (pair? cl)
        (if (eq? (car cl) 'else)
            (walk-forms (cdr cl) lexical-lock? fallthrough bound emit)
            (begin
              (walk (car cl) lexical-lock? fallthrough bound emit)
              (let ((test-state (manual-state-after (car cl) fallthrough)))
                (let ((arrow (memq '=> (cdr cl))))
                  (if (and arrow (pair? (cdr arrow)))
                      (begin
                        (walk-arrow-receiver (cadr arrow) lexical-lock?
                                             test-state bound emit)
                        ;; Invalid trailing forms remain visible to the checker
                        ;; instead of becoming an analysis hole.
                        (walk-forms (cddr arrow) lexical-lock?
                                    test-state bound emit))
                      (walk-forms (cdr cl) lexical-lock?
                                  test-state bound emit)))
                (set! fallthrough test-state)))))
       (loop (cdr clauses) fallthrough)))))

(define (walk-guard d lexical-lock? manual-lock? bound emit)
  ;; (guard (var clause ...) body ...): the binding and clause lists are syntax,
  ;; not applications. The body runs first; a selected clause runs on escape.
  (when (pair? (cdr d))
    (walk-forms (cddr d) lexical-lock? manual-lock? bound emit)
    (when (pair? (cadr d))
      (let ((caught-state
              (let ((body-state (manual-state-after-forms (cddr d) manual-lock?)))
                (if (contains-manual-acquire? (cddr d))
                    (cons unknown-lock (manual-state-join manual-lock? body-state))
                    (manual-state-join manual-lock? body-state)))))
      (for-each
        (lambda (cl)
          (when (pair? cl)
            (let ((clause-bound
                    (if (symbol? (caadr d)) (cons (caadr d) bound) bound)))
              (if (eq? (car cl) 'else)
                  (walk-forms (cdr cl) lexical-lock? caught-state
                              clause-bound emit)
                  (begin
                    (walk (car cl) lexical-lock? caught-state clause-bound emit)
                    (let* ((test-state
                             (manual-state-after (car cl) caught-state))
                           (arrow (memq '=> (cdr cl))))
                      (if (and arrow (pair? (cdr arrow)))
                          (begin
                            (walk-arrow-receiver
                              (cadr arrow) lexical-lock? test-state
                              clause-bound emit)
                            (walk-forms (cddr arrow) lexical-lock? test-state
                                        clause-bound emit))
                          (walk-forms (cdr cl) lexical-lock? test-state
                                      clause-bound emit))))))))
        (cdadr d))))))

(define (walk-do d lexical-lock? manual-lock? bound emit)
  (let* ((bindings (cadr d))
         (after-inits
           (fold-left
             (lambda (state b)
               (if (and (pair? b) (pair? (cdr b)))
                   (begin (walk (cadr b) lexical-lock? state bound emit)
                          (manual-state-after (cadr b) state))
                   state))
             manual-lock? bindings))
         (test-clause (if (pair? (cddr d)) (caddr d) '()))
         (step-forms
           (if (list? bindings)
               (map caddr
                    (filter (lambda (b) (and (pair? b) (pair? (cddr b))))
                            bindings))
               '()))
         (loop-forms (append (if (pair? (cddr d)) (cdddr d) '()) step-forms))
         (loop-state (if (contains-manual-acquire? loop-forms)
                         (cons unknown-lock after-inits) after-inits))
         (test-state
           (if (pair? test-clause)
               (begin (walk (car test-clause) lexical-lock? loop-state bound emit)
                      (manual-state-after (car test-clause) loop-state))
               loop-state)))
    (when (pair? test-clause)
      (walk-forms (cdr test-clause) lexical-lock? test-state bound emit))
    (when (pair? (cddr d))
      (walk-forms (cdddr d) lexical-lock? test-state bound emit))
    (let ((after-body (manual-state-after-forms
                        (if (pair? (cddr d)) (cdddr d) '()) test-state)))
      (let loop ((bs bindings) (state after-body))
        (unless (null? bs)
          (let ((b (car bs)))
            (if (and (pair? b) (pair? (cddr b)))
                (begin (walk (caddr b) lexical-lock? state bound emit)
                       (loop (cdr bs) (manual-state-after (caddr b) state)))
                (loop (cdr bs) state))))))))

(define (walk-if d lexical-lock? manual-lock? bound emit)
  ;; The test runs first. Consequent and alternate then start independently from
  ;; its possible ownership state; an unlock in one branch must never make its
  ;; sibling look unlocked.
  (when (pair? (cdr d))
    (walk (cadr d) lexical-lock? manual-lock? bound emit)
    (let ((branch-held (manual-state-after (cadr d) manual-lock?)))
      (when (pair? (cddr d))
        (walk (caddr d) lexical-lock? branch-held bound emit))
      (when (pair? (cdddr d))
        (walk (cadddr d) lexical-lock? branch-held bound emit)))))

(define (walk-synchronous-callback-call d consumer positions
                                        lexical-lock? manual-lock? bound emit)
  (define in-lock? (or lexical-lock? (pair? manual-lock?)))
  (emit consumer in-lock? #t)
  (let loop ((args (cdr d)) (position 1))
    (unless (null? args)
      (let ((arg (car args)))
        (if (memv position positions)
            (cond
              ((and (pair? arg) (eq? (car arg) 'lambda))
               (walk-lambda-body arg lexical-lock? manual-lock? bound emit))
              ((symbol? arg)
               (emit (resolve-operator arg bound) in-lock? #t))
              (else
               ;; The callback expression is evaluated first; its resulting
               ;; procedure is then invoked synchronously and opaquely.
               (walk arg lexical-lock? manual-lock? bound emit)
               (emit dynamic-call in-lock? #t)))
            (walk arg lexical-lock? manual-lock? bound emit))
        (loop (cdr args) (+ position 1))))))

(define (walk x lexical-lock? manual-lock? bound emit)
  (define in-lock? (or lexical-lock? (pair? manual-lock?)))
  (cond
    ((symbol? x)
     ;; A checkpoint entry point escaping as a value loses the syntactic proof
     ;; that the closed leaf has canonical arity and a literal qualified ID.
     ;; Record a hard hazard in addition to the value-flow edge used to follow
     ;; top-level aliases and alias chains.
     (when (checkpoint-entrypoint? x)
       (emit checkpoint-hazard-call in-lock? #t))
     (emit x in-lock? #f))               ; a value position: (apply jolt-invoke …)
    ((not (pair? x)) (void))
    ((not (list? x))                     ; improper: (a . b) — walk both halves
     (walk (car x) lexical-lock? manual-lock? bound emit)
     (walk (cdr x) lexical-lock? manual-lock? bound emit))
    (else
     (let ((head (car x)))
       (case head
         ((quote) (void))                ; data, not code
         ((let let* letrec letrec* let-values let*-values)
          (walk-let x lexical-lock? manual-lock? bound emit))
         ;; An ordinary lambda literal is created now but its body is deferred.
         ;; Keep walking it for the general call graph, while excluding its body
         ;; from the enclosing unit's synchronous logical-region effects.
         ((lambda)
          (parameterize ((logical-effects-enabled? #f))
            (walk-lambda-body x lexical-lock? manual-lock? bound emit)))
         ((case-lambda)
          (parameterize ((logical-effects-enabled? #f))
            (walk-case-lambda x lexical-lock? manual-lock? bound emit)))
         ((define) (walk-define x lexical-lock? manual-lock? bound emit))
         ((define-syntax)
          ;; Preserve this as a structural hard finding instead of trying to
          ;; infer the names and shapes of its eventual expansions.
          (emit-checkpoint-syntax-hazards
            (cddr x) in-lock? emit))
         ((let-syntax letrec-syntax)
          (walk-local-syntax x lexical-lock? manual-lock? bound emit))
         ((case) (walk-case x lexical-lock? manual-lock? bound emit))
         ((cond) (walk-cond x lexical-lock? manual-lock? bound emit))
         ((guard) (walk-guard x lexical-lock? manual-lock? bound emit))
         ((do) (walk-do x lexical-lock? manual-lock? bound emit))
         ((if) (walk-if x lexical-lock? manual-lock? bound emit))
         ((fork-thread)
          ;; The child thunk runs on another OS thread. Its effects are not
          ;; effects of the spawning definition while that definition's carrier
          ;; holds a counted lock. Walk only any non-thunk trailing arguments.
          (emit head in-lock? #t)
          (when (pair? (cdr x))
            (let ((thunk-expr (cadr x)))
              ;; A literal body is deferred to the child. A computed thunk
              ;; expression is evaluated synchronously before the spawn.
              (unless (and (pair? thunk-expr) (eq? (car thunk-expr) 'lambda))
                (walk thunk-expr lexical-lock? manual-lock? bound emit))))
          (when (pair? (cddr x))
            (walk-forms (cddr x) lexical-lock? manual-lock? bound emit)))
         (else
          (cond
            ((and (symbol? head)
                  (pair? (synchronous-callback-positions
                           (resolve-operator head bound))))
             (let ((consumer (resolve-operator head bound)))
               (walk-synchronous-callback-call
                 x consumer (synchronous-callback-positions consumer)
                 lexical-lock? manual-lock? bound emit)))
            ;; A logical mutex's first argument is evaluated before acquisition;
            ;; its literal thunk body runs in the named logical region.  Keep
            ;; acquisition separate from dispatch: an acyclic named edge is
            ;; useful inventory, whereas opaque work is reviewable debt.
            ((eq? head logical-lock-form)
             ;; Preserve the ordinary call for counted-lock analysis without
             ;; double-attributing this analyzer-owned wrapper as dispatch in an
             ;; enclosing logical region.
             (parameterize ((logical-effects-enabled? #f))
               (emit head in-lock? #t))
             (if (= (length x) 3)
                 (let* ((lock-expr (cadr x))
                        (thunk-expr (caddr x))
                        (effects? (logical-effects-enabled?))
                        (lock-id (logical-lock-identity lock-expr bound)))
                   ;; Scheme evaluates both arguments before the wrapper enters.
                   (walk lock-expr lexical-lock? manual-lock? bound emit)
                   (unless (and (pair? thunk-expr)
                                (eq? (car thunk-expr) 'lambda))
                     (walk thunk-expr lexical-lock? manual-lock? bound emit))
                   ((logical-acquire-emitter) (current-logical-regions) lock-id)
                   (parameterize
                     ((current-logical-regions
                        (cons lock-id (current-logical-regions)))
                      (logical-effects-enabled? effects?))
                     (if (and (pair? thunk-expr)
                              (eq? (car thunk-expr) 'lambda))
                         (walk-lambda-body thunk-expr lexical-lock? manual-lock?
                                           bound emit)
                         ;; Invocation, unlike expression evaluation, occurs
                         ;; after acquisition and is necessarily opaque.
                         (emit dynamic-call
                               (or lexical-lock? (pair? manual-lock?)) #t))))
                 (begin
                   ((logical-hard-emitter) 'unsupported-wrapper-arity
                    logical-lock-form)
                   (walk-forms (cdr x) lexical-lock? manual-lock? bound emit))))
            ;; THE REGION. (jolt-with-mutex mu body …): the mutex expression is
            ;; evaluated before the lock is taken, the body under it.
            ((eq? head lock-form)
             (when (pair? (cdr x))
               (walk (cadr x) lexical-lock? manual-lock? bound emit))
             (when (pair? (cdr x))
               (walk-forms (cddr x) #t manual-lock? bound emit)))
            (else
             (cond
               ;; In `(apply target ...)` the target appears in value position
               ;; but is invoked. Model that call shape directly so ordinary
               ;; argument values remain ordinary.
               ((and (eq? head 'apply) (pair? (cdr x)))
                (let ((target (if (symbol? (cadr x))
                                  (resolve-operator (cadr x) bound)
                                  dynamic-call)))
                  (when (eq? target logical-lock-form)
                    ((logical-hard-emitter) 'unsupported-apply logical-lock-form))
                  ;; The list's runtime shape is not statically available, so
                  ;; callback positions cannot be recovered soundly.
                  (when (pair? (synchronous-callback-positions target))
                    ((logical-hard-emitter) 'unsupported-synchronous-apply target))
                  ;; Even the closed leaf is unsupported through apply: neither
                  ;; its arity nor its literal ID remains statically visible.
                  (when (or (eq? target checkpoint-continue-call)
                            (eq? target checkpoint-generic-call))
                    (emit checkpoint-hazard-call in-lock? #t)))
                ;; `apply` invokes its first argument. Record every named target,
                ;; not only today's generic seeds. A computed target is opaque
                ;; procedure-valued dispatch and therefore fails closed.
                (emit (if (symbol? (cadr x))
                          (resolve-operator (cadr x) bound)
                          dynamic-call)
                      in-lock? #t)
                (emit head in-lock? #t))
               ((symbol? head)
                (let ((resolved (resolve-operator head bound)))
                  (when (eq? resolved logical-lock-form)
                    ((logical-hard-emitter) 'unsupported-alias logical-lock-form))
                  (cond
                    ((canonical-continue-checkpoint-call? x resolved)
                     (emit checkpoint-continue-call in-lock? #t))
                    ((or (eq? resolved checkpoint-continue-call)
                         (eq? resolved checkpoint-generic-call))
                     (emit checkpoint-hazard-call in-lock? #t))
                    (else (emit resolved in-lock? #t)))))
               ;; the head may itself be a form: ((f x) y)
               ;; Only explicitly reviewed arithmetic/bitwise Chez primitives
               ;; are leaves. Unknown primitive heads fall through to dynamic.
               ((leaf-primitive-head? head) (void))
               ((and (pair? head) (eq? (car head) 'record-constructor)) (void))
               (else (emit dynamic-call in-lock? #t)
                     (walk head lexical-lock? manual-lock? bound emit)))
             (walk-forms (cdr x) lexical-lock? manual-lock? bound emit)))))))))

;; ---------------------------------------------------------------------------
;; per-file collection
;; ---------------------------------------------------------------------------
;; A "unit" is one top-level definition:
;; (file name calls locked-calls raw-body logical-calls acquisitions edges
;;  unknowns synchronous-calls value-symbols).
;; calls is every operator-position symbol in the body (the call graph edge set),
;; and locked-calls is its subset inside a counted-lock region. Top-level forms
;; that are not definitions use a file-unique name so file-scope locks are read.

(define (unit-file u) (car u))
(define (unit-name u) (cadr u))
(define (unit-calls u) (caddr u))
(define (unit-locked u) (cadddr u))
(define (unit-body u) (car (cddddr u)))
(define (unit-logical-calls u) (if (> (length u) 5) (list-ref u 5) '()))
(define (unit-logical-acquires u) (if (> (length u) 6) (list-ref u 6) '()))
(define (unit-logical-edges u) (if (> (length u) 7) (list-ref u 7) '()))
(define (unit-logical-unknowns u) (if (> (length u) 8) (list-ref u 8) '()))
(define (unit-logical-sync-calls u) (if (> (length u) 9) (list-ref u 9) '()))
(define (unit-value-symbols u) (if (> (length u) 10) (list-ref u 10) '()))

(define (definition-name d)
  (and (pair? d) (eq? 'define (car d)) (pair? (cdr d))
       (if (pair? (cadr d)) (car (cadr d)) (cadr d))))

(define (logical-lock-definition-name d)
  (and (list? d) (= (length d) 3) (eq? (car d) 'define)
       (symbol? (cadr d))
       (let ((rhs (caddr d)))
         (and (list? rhs) (= (length rhs) 1)
              (eq? (car rhs) 'jolt-logical-mutex-new)
              (cadr d)))))

(define (analyze-logical-lock-identities datums)
  (let ((locks (make-eq-hashtable)) (definitions (make-eq-hashtable))
        (mutations (make-eq-hashtable)) (identity-errors '()))
    (define (scan-mutations x)
      (cond
        ((not (pair? x)) (void))
        ((and (list? x) (pair? x) (eq? (car x) 'quote)) (void))
        ((and (list? x) (>= (length x) 2) (eq? (car x) 'set!)
              (symbol? (cadr x)))
         (hashtable-set! mutations (cadr x) #t)
         (for-each scan-mutations (cddr x)))
        (else
         (scan-mutations (car x))
         (scan-mutations (cdr x)))))
    (for-each
      (lambda (d)
        (let ((defined (definition-name d))
              (lock-name (logical-lock-definition-name d)))
          (when defined
            (hashtable-set! definitions defined
              (+ 1 (hashtable-ref definitions defined 0))))
          (when lock-name (hashtable-set! locks lock-name #t))
          (scan-mutations d)))
      datums)
    (for-each
      (lambda (name)
        (let ((count (hashtable-ref definitions name 0)))
          (unless (= count 1)
            (set! identity-errors
              (cons (string-append "logical mutex " (symbol->string name)
                                   " has " (number->string count)
                                   " top-level definitions")
                    identity-errors)))
          (when (hashtable-ref mutations name #f)
            (set! identity-errors
              (cons (string-append "logical mutex " (symbol->string name)
                                   " is mutated with set!")
                    identity-errors)))))
      (vector->list (hashtable-keys locks)))
    (cons locks (sort-list identity-errors string<?))))

(define (discover-logical-locks files)
  (let ((datums '()) (read-errors '()))
    (for-each
      (lambda (file)
        (guard (e (#t (set! read-errors (cons file read-errors))))
          (set! datums (append (read-datums file) datums))))
      files)
    (let ((analysis (analyze-logical-lock-identities datums)))
      (list (car analysis) (reverse read-errors) (cdr analysis)))))

(define (collect-unit file name forms bound)
  (let ((calls '()) (locked '()) (logical-calls '())
        (logical-acquires '()) (logical-edges '()) (logical-unknowns '())
        (logical-sync-calls '()) (value-symbols '()))
    (parameterize
      ((current-logical-regions '())
       (logical-acquire-emitter
         (lambda (held acquired)
           (when (logical-effects-enabled?)
             (set! logical-acquires (cons acquired logical-acquires))
             (when (eq? acquired unknown-logical-lock)
               (set! logical-unknowns
                 (cons '(unknown-acquisition . wrapper) logical-unknowns)))
             (for-each
               (lambda (owner)
                 (cond
                   ((or (eq? owner unknown-logical-lock)
                        (eq? acquired unknown-logical-lock))
                    (set! logical-unknowns
                      (cons '(unknown-order-edge . wrapper) logical-unknowns)))
                   ;; Reentrant acquisition is valid and is not an order edge.
                   ((not (eq? owner acquired))
                    (set! logical-edges
                      (cons (cons owner acquired) logical-edges)))))
               held))))
       (logical-hard-emitter
         (lambda (kind detail)
           (set! logical-unknowns (cons (cons kind detail) logical-unknowns)))))
      (walk-forms forms #f '() (trusted-bound name bound)
        (lambda (sym in-lock? operator?)
          (when operator? (set! calls (cons sym calls)))
          (unless operator? (set! value-symbols (cons sym value-symbols)))
          (when (and in-lock? operator?) (set! locked (cons sym locked)))
          ;; Structural census: these capabilities may not be stored or selected
          ;; as values. Canonical wrapper calls are handled without walking the
          ;; head, and approved low-level calls are checked below.
          (when (and (not operator?)
                     (memq sym '(jolt-with-logical-mutex
                                 jolt-logical-mutex-enter!
                                 jolt-logical-mutex-exit!)))
            (set! logical-unknowns
              (cons (cons 'unsupported-capability-value sym) logical-unknowns)))
          (when (and operator?
                     (memq sym '(jolt-logical-mutex-enter!
                                 jolt-logical-mutex-exit!))
                     (not (eq? name 'jolt-with-logical-mutex)))
            (set! logical-unknowns
              (cons (cons 'unsupported-low-level sym) logical-unknowns)))
          (when (and operator? (logical-effects-enabled?))
            (set! logical-sync-calls (cons sym logical-sync-calls))
            (for-each
              (lambda (owner)
                (set! logical-calls (cons (cons owner sym) logical-calls)))
              (current-logical-regions))))))
    (list file name calls locked forms logical-calls logical-acquires
          logical-edges logical-unknowns logical-sync-calls value-symbols)))

(define (collect-case-lambda-unit file name clauses)
  (let ((parts
          (map (lambda (clause)
                 (collect-unit file name (cdr clause)
                   (formal-names (car clause))))
               clauses)))
    (define (join-field i)
      (fold-left (lambda (out u) (append (list-ref u i) out)) '() parts))
    (list file name (join-field 2) (join-field 3) clauses
          (join-field 5) (join-field 6) (join-field 7) (join-field 8)
          (join-field 9) (join-field 10))))

(define (collect-definition file d)
  (let ((nm (definition-name d)))
    (if nm
        (let ((rhs (and (not (pair? (cadr d)))
                        (pair? (cddr d)) (caddr d))))
          (cond
            ((and (list? rhs) (pair? rhs) (eq? (car rhs) 'lambda))
             (collect-unit file nm (cddr rhs) (formal-names (cadr rhs))))
            ((and (list? rhs) (pair? rhs) (eq? (car rhs) 'case-lambda))
             (collect-case-lambda-unit file nm (cdr rhs)))
            (else
             (collect-unit file nm (cddr d)
               (if (pair? (cadr d)) (formal-names (cdadr d)) '())))))
        (collect-unit file
          (string->symbol (string-append file "::toplevel"))
          (list d) '()))))

(define (collect-file file)
  (let loop ((ds (read-datums file)) (acc '()))
    (cond
      ((null? ds) (reverse acc))
      (else
       (loop (cdr ds) (cons (collect-definition file (car ds)) acc))))))

;; ---------------------------------------------------------------------------
;; the closure: which host definitions can park
;; ---------------------------------------------------------------------------
;; Seeded with the switch points and jolt-invoke, then grown to a fixpoint: a
;; definition parks if it calls anything that parks. This is what sees a park one
;; call away from a lock region, which is the shape a lexical scan misses and the
;; shape jolt-04ee actually had.
;;
;; Deliberately name-based and therefore over-approximate in one direction: two
;; definitions with one name in different files are one node. The runtime has no
;; such pair (the host is one flat namespace, so it could not), and erring towards
;; "parks" is the safe direction for a check whose false answers should be
;; false ALARMS, not false silence.

(define (build-parkers units)
  (let ((parks (make-eq-hashtable)))
    (for-each (lambda (s) (hashtable-set! parks s #t)) park-seeds)
    (let grow ()
      (let ((changed #f))
        (for-each
          (lambda (u)
            (unless (or (memq (unit-name u) guarded-park-boundaries)
                        (hashtable-ref parks (unit-name u) #f))
              (when (let loop ((cs (unit-calls u)))
                      (cond ((null? cs) #f)
                            ((hashtable-ref parks (car cs) #f) #t)
                            (else (loop (cdr cs)))))
                (hashtable-set! parks (unit-name u) #t)
                (set! changed #t))))
          units)
        (when changed (grow))))
    parks))

(define (build-dispatchers units)
  (let ((dispatches (make-eq-hashtable)))
    (for-each (lambda (s) (hashtable-set! dispatches s #t)) dispatch-seeds)
    ;; An opaque procedure-valued invocation is itself a generic boundary. Seed
    ;; it into the closure so a helper that invokes its callback contaminates a
    ;; locked caller one or more ordinary calls away. Trusted callbacks use a
    ;; distinct call-site marker and therefore do not broaden this seed.
    (hashtable-set! dispatches dynamic-call #t)
    (let grow ()
      (let ((changed #f))
        (for-each
          (lambda (u)
            (unless (hashtable-ref dispatches (unit-name u) #f)
              (when (exists (lambda (c) (hashtable-ref dispatches c #f))
                            (unit-calls u))
                (hashtable-set! dispatches (unit-name u) #t)
                (set! changed #t))))
          units)
        (when changed (grow))))
    dispatches))

(define (build-checkpoint-hazards units)
  (let ((hazards (make-eq-hashtable)))
    (hashtable-set! hazards checkpoint-hazard-call #t)
    (let grow ()
      (let ((changed #f))
        (for-each
          (lambda (u)
            (unless (hashtable-ref hazards (unit-name u) #f)
              (when (or (exists (lambda (c) (hashtable-ref hazards c #f))
                                (unit-calls u))
                        ;; A procedure capability stored or returned as a value
                        ;; is intentionally fail-closed. This second edge class
                        ;; follows `(define cp jolt-checkpoint!)` and arbitrary
                        ;; chains such as `(define cp2 cp)` without treating the
                        ;; canonical direct leaf's operator as a value escape.
                        (exists (lambda (v) (hashtable-ref hazards v #f))
                                (unit-value-symbols u)))
                (hashtable-set! hazards (unit-name u) #t)
                (set! changed #t))))
          units)
        (when changed (grow))))
    hazards))

(define (build-logical-dispatchers units)
  (let ((dispatches (make-eq-hashtable)))
    (for-each (lambda (s) (hashtable-set! dispatches s #t)) dispatch-seeds)
    (hashtable-set! dispatches dynamic-call #t)
    (let grow ()
      (let ((changed #f))
        (for-each
          (lambda (u)
            (unless (hashtable-ref dispatches (unit-name u) #f)
              (when (exists (lambda (c) (hashtable-ref dispatches c #f))
                            (unit-logical-sync-calls u))
                (hashtable-set! dispatches (unit-name u) #t)
                (set! changed #t))))
          units)
        (when changed (grow))))
    dispatches))

;; ---------------------------------------------------------------------------
;; logical-region summaries and lock-order graph
;; ---------------------------------------------------------------------------

(define (adjoinq x xs) (if (memq x xs) xs (cons x xs)))
(define (symbol<? a b) (string<? (symbol->string a) (symbol->string b)))
(define (logical-edge<? a b)
  (or (symbol<? (car a) (car b))
      (and (eq? (car a) (car b)) (symbol<? (cdr a) (cdr b)))))

(define (build-logical-acquisitions units)
  (let ((acquires (make-eq-hashtable)))
    (for-each
      (lambda (u)
        (hashtable-set! acquires (unit-name u)
          (fold-left (lambda (xs x) (adjoinq x xs)) '()
                     (unit-logical-acquires u))))
      units)
    (let grow ()
      (let ((changed #f))
        (for-each
          (lambda (u)
            (let ((before (hashtable-ref acquires (unit-name u) '())))
              (let ((after
                      (fold-left
                        (lambda (xs callee)
                          (fold-left (lambda (ys lock) (adjoinq lock ys)) xs
                                     (hashtable-ref acquires callee '())))
                        before (unit-logical-sync-calls u))))
                (unless (= (length before) (length after))
                  (hashtable-set! acquires (unit-name u) after)
                  (set! changed #t)))))
          units)
        (when changed (grow))))
    acquires))

;; An edge is (held . acquired). Include direct lexical nesting and acquisitions
;; reached transitively through a named helper called while HELD. Unknown
;; identities are retained as hard findings rather than becoming graph nodes.
(define (logical-order-edges units acquires)
  (let ((edges '()))
    (define (add-edge! edge)
      (unless (or (eq? (car edge) (cdr edge)) (member edge edges))
        (set! edges (cons edge edges))))
    (for-each
      (lambda (u)
        (for-each add-edge! (unit-logical-edges u))
        (for-each
          (lambda (site)
            (for-each
              (lambda (acquired) (add-edge! (cons (car site) acquired)))
              (hashtable-ref acquires (cdr site) '())))
          (unit-logical-calls u)))
      units)
    (sort-list edges logical-edge<?)))

(define (logical-unknown-findings units acquires)
  (let ((out '()))
    (define (add! line) (unless (member line out) (set! out (cons line out))))
    (for-each
      (lambda (u)
        (for-each
          (lambda (problem)
            (add!
              (string-append (unit-file u) " " (symbol->string (unit-name u))
                             " " (symbol->string (car problem)) " "
                             (symbol->string (cdr problem)))))
          (unit-logical-unknowns u))
        (for-each
          (lambda (site)
            (when (and (not (eq? (car site) unknown-logical-lock))
                       (memq unknown-logical-lock
                             (hashtable-ref acquires (cdr site) '())))
              (add!
                (string-append (unit-file u) " " (symbol->string (unit-name u))
                               " transitive-unknown "
                               (symbol->string (car site)) "->"
                               (symbol->string (cdr site))))))
          (unit-logical-calls u)))
      units)
    (sort-list out string<?)))

;; Return one concrete cycle path, or #f. Reentrant self-acquisition was removed
;; while constructing the graph, so every returned cycle is an order inversion.
(define (logical-order-cycle edges)
  (let ((nodes '()) (adj (make-eq-hashtable)))
    (for-each
      (lambda (edge)
        (unless (or (eq? (car edge) unknown-logical-lock)
                    (eq? (cdr edge) unknown-logical-lock))
          (set! nodes (adjoinq (car edge) (adjoinq (cdr edge) nodes)))
          (hashtable-set! adj (car edge)
            (adjoinq (cdr edge) (hashtable-ref adj (car edge) '())))))
      edges)
    (set! nodes (sort-list nodes symbol<?))
    (for-each
      (lambda (node)
        (hashtable-set! adj node
          (sort-list (hashtable-ref adj node '()) symbol<?)))
      nodes)
    (let ((done (make-eq-hashtable)) (active (make-eq-hashtable)))
      (letrec
        ((visit
           (lambda (node path)
             (cond
               ((hashtable-ref active node #f)
                (let ((cycle (memq node path)))
                  (and cycle (append cycle (list node)))))
               ((hashtable-ref done node #f) #f)
               (else
                (hashtable-set! active node #t)
                (let loop ((next (hashtable-ref adj node '())))
                  (cond
                    ((null? next)
                     (hashtable-delete! active node)
                     (hashtable-set! done node #t)
                     #f)
                    (else
                     (let ((found (visit (car next) (append path (list node)))))
                       (if found found (loop (cdr next))))))))))))
        (let loop ((rest nodes))
          (and (pair? rest)
               (or (visit (car rest) '()) (loop (cdr rest)))))))))

;; ---------------------------------------------------------------------------
;; findings
;; ---------------------------------------------------------------------------
;; (file definition kind callee count), sorted, one line each.

(define (tally syms keep?)
  (let ((t (make-eq-hashtable)))
    (for-each (lambda (s) (when (keep? s) (hashtable-set! t s (+ 1 (hashtable-ref t s 0)))))
              syms)
    t))

(define (tally->findings file name kind t)
  (map (lambda (c) (list file name kind c (hashtable-ref t c 0)))
       (sort-list (vector->list (hashtable-keys t))
                  (lambda (a b) (string<? (symbol->string a) (symbol->string b))))))

(define (findings units parks dispatches)
  (sort-list
    (let loop ((us units) (out '()))
      (if (null? us)
          out
          (let ((u (car us)))
            (loop (cdr us)
                  (append
                    (tally->findings (unit-file u) (unit-name u) 'park
                      (tally (unit-locked u) (lambda (s) (hashtable-ref parks s #f))))
                    (tally->findings (unit-file u) (unit-name u) 'dispatch
                      (tally (unit-locked u)
                             (lambda (s) (or (eq? s dynamic-call)
                                             (hashtable-ref dispatches s #f)))))
                    out)))))
    (lambda (a b) (string<? (finding->line a) (finding->line b)))))

(define (checkpoint-findings units hazards)
  (sort-list
    (fold-left
      (lambda (out u)
        (append
          (tally->findings (unit-file u) (unit-name u) 'checkpoint
            (tally (unit-locked u)
                   (lambda (s) (hashtable-ref hazards s #f))))
          out))
      '() units)
    (lambda (a b) (string<? (finding->line a) (finding->line b)))))

;; Checkpoint entry points are non-storable capabilities.  This structural
;; finding is intentionally independent of the enclosing unit's name: forms
;; such as `(set! cp jolt-checkpoint!)` and `define-values` are collected in a
;; synthetic top-level unit, where an alias-name analysis cannot be sound.
(define (checkpoint-value-findings units)
  (sort-list
    (fold-left
      (lambda (out u)
        (append
          (tally->findings (unit-file u) (unit-name u) 'checkpoint-value
            (tally (unit-value-symbols u) checkpoint-entrypoint?))
          out))
      '() units)
    (lambda (a b) (string<? (finding->line a) (finding->line b)))))

(define (logical-dispatch-findings units dispatches)
  (sort-list
    (fold-left
      (lambda (out u)
        (let ((t (make-eq-hashtable)))
          (for-each
            (lambda (site)
              (when (or (eq? (cdr site) dynamic-call)
                        (hashtable-ref dispatches (cdr site) #f))
                (let ((key
                        (string->symbol
                          (string-append (symbol->string (car site)) "->"
                                         (symbol->string (cdr site))))))
                  (hashtable-set! t key (+ 1 (hashtable-ref t key 0))))))
            (unit-logical-calls u))
          (append (tally->findings (unit-file u) (unit-name u)
                                   'logical-dispatch t)
                  out)))
      '() units)
    (lambda (a b) (string<? (finding->line a) (finding->line b)))))

(define (finding->line f)
  (string-append (car f) " " (symbol->string (cadr f)) " " (symbol->string (caddr f))
                 " " (symbol->string (cadddr f)) " "
                 (number->string (car (cddddr f)))))

;; ---------------------------------------------------------------------------
;; the teeth check: the switch points must still call the assertion
;; ---------------------------------------------------------------------------

(define (missing-switch-assertions units)
  (let loop ((sps switch-points) (missing '()))
    (cond
      ((null? sps) (reverse missing))
      (else
       (let* ((sp (car sps))
              (defs (let f ((us units) (acc '()))
                      (cond ((null? us) acc)
                            ((eq? (unit-name (car us)) sp) (cons (car us) acc))
                            (else (f (cdr us) acc))))))
         (loop (cdr sps)
               (cond
                 ((null? defs) (cons (cons sp "not defined anywhere") missing))
                 ((let g ((ds defs))
                    (cond ((null? ds) #f)
                          ((memq assertion (unit-calls (car ds))) #t)
                          (else (g (cdr ds)))))
                  missing)
                 (else (cons (cons sp "does not call the assertion") missing)))))))))

;; Syntactic proof for guarded boundaries. The assertion must be the first raw
;; body form and an ordinary direct call -- not merely the first call the walker
;; happens to encounter, which would accept `(when false (assert))`. unit-calls
;; is accumulated in reverse walk order, hence the reverse below. A boundary is
;; trusted only if it has at least one direct parker and that leading assertion
;; precedes every one. This catches deletion, reordering, and dead-branching.
(define (leading-assertion? u)
  (let ((body (unit-body u)))
    (and (pair? body)
         (let ((f (car body)))
           (and (pair? f) (eq? (car f) assertion))))))

(define (bad-guarded-boundaries units parks)
  (let loop ((names guarded-park-boundaries) (bad '()))
    (if (null? names)
        (reverse bad)
        (let* ((name (car names))
               (defs (filter (lambda (u) (eq? (unit-name u) name)) units)))
          (loop
            (cdr names)
            (cond
              ((null? defs) (cons (cons name "not defined anywhere") bad))
              ((and (null? (cdr defs))
                    (leading-assertion? (car defs))
                    (let scan ((calls (reverse (unit-calls (car defs))))
                               (asserted? #f) (saw-parker? #f))
                      (cond
                        ((null? calls) (and asserted? saw-parker?))
                        ((eq? (car calls) assertion)
                         (scan (cdr calls) #t saw-parker?))
                        ((hashtable-ref parks (car calls) #f)
                         (and asserted? (scan (cdr calls) asserted? #t)))
                        (else (scan (cdr calls) asserted? saw-parker?)))))
               bad)
              (else
               (cons (cons name "must call the lock assertion before every direct parker")
                     bad))))))))

;; Mutation/teeth check over synthetic units. A guarded boundary that directly
;; calls the assertion must cut propagation; deletion, reordering, conditional
;; placement, and duplicate-definition escape attempts must all be detected.
(define (guarded-boundary-self-test)
  (let* ((mk (lambda (name calls body)
               (list "synthetic" name calls '() body)))
         (logical-good
           (mk 'jolt-logical-mutex-wait!
               '(jolt-fiber-to-scheduler! jolt-locks-assert-none!)
               '((jolt-locks-assert-none! 'logical-guard)
                 (jolt-fiber-to-scheduler! f))))
         ;; Unit call lists are stored in reverse source order.
         (good (list logical-good
                     (mk 'jolt-publication-gate-wait!
                         '(jolt-fiber-to-scheduler! jolt-locks-assert-none!)
                         '((jolt-locks-assert-none! 'guard)
                           (jolt-fiber-to-scheduler! f)))
                     (mk 'synthetic-caller '(jolt-publication-gate-wait!)
                         '((jolt-publication-gate-wait! gate me)))))
         (deleted (list logical-good
                        (mk 'jolt-publication-gate-wait!
                            '(jolt-fiber-to-scheduler!)
                            '((jolt-fiber-to-scheduler! f)))))
         (reordered (list logical-good
                          (mk 'jolt-publication-gate-wait!
                              '(jolt-locks-assert-none! jolt-fiber-to-scheduler!)
                              '((jolt-fiber-to-scheduler! f)
                                (jolt-locks-assert-none! 'guard)))))
         (conditional (list logical-good
                            (mk 'jolt-publication-gate-wait!
                                '(jolt-fiber-to-scheduler! jolt-locks-assert-none! when)
                                '((when #f (jolt-locks-assert-none! 'guard))
                                  (jolt-fiber-to-scheduler! f)))))
         (duplicate (append good
                            (list (mk 'jolt-publication-gate-wait!
                                      '(jolt-fiber-to-scheduler!)
                                      '((jolt-fiber-to-scheduler! f))))))
         (parks (build-parkers good))
         (deleted-parks (build-parkers deleted))
         (reordered-parks (build-parkers reordered))
         (conditional-parks (build-parkers conditional))
         (duplicate-parks (build-parkers duplicate)))
    (and (not (hashtable-ref parks 'jolt-publication-gate-wait! #f))
         (not (hashtable-ref parks 'synthetic-caller #f))
         (null? (bad-guarded-boundaries good parks))
         (pair? (bad-guarded-boundaries deleted deleted-parks))
         (pair? (bad-guarded-boundaries reordered reordered-parks))
         (pair? (bad-guarded-boundaries conditional conditional-parks))
         (pair? (bad-guarded-boundaries duplicate duplicate-parks)))))

;; Return how many exact `(set! hook target)` installations occur in executable
;; source. Quote bodies are data. This is deliberately narrower than an alias
;; analysis: the trusted callback contract is one named cell, one named internal
;; target, installed once after both definitions load.
(define (callback-install-count units hook target)
  (define (count x)
    (cond ((not (pair? x)) 0)
          ((and (list? x) (eq? (car x) 'quote)) 0)
          ((and (list? x) (= (length x) 3) (eq? (car x) 'set!)
                (eq? (cadr x) hook) (eq? (caddr x) target)) 1)
          (else (+ (count (car x)) (count (cdr x))))))
  (fold-left (lambda (n u) (+ n (count (unit-body u)))) 0 units))

(define (bad-trusted-callbacks units parks dispatches)
  (let loop ((entries trusted-installed-callbacks) (bad '()))
    (if (null? entries)
        (reverse bad)
        (let* ((entry (car entries))
               (hook (car entry)) (target (cdr entry))
               (installs (callback-install-count units hook target))
               (defined? (exists (lambda (u) (eq? (unit-name u) target)) units))
               (problem
                 (cond ((not (= installs 1))
                        (cons hook "must have exactly one direct installation of its trusted target"))
                       ((not defined?) (cons hook "trusted target is not defined"))
                       ((hashtable-ref parks target #f) (cons hook "trusted target can park"))
                       ((hashtable-ref dispatches target #f)
                        (cons hook "trusted target can invoke generic code"))
                       (else #f))))
          (loop (cdr entries) (if problem (cons problem bad) bad))))))

(define (call-forms units name)
  (define (scan x)
    (cond ((not (pair? x)) '())
          ((and (list? x) (eq? (car x) 'quote)) '())
          (else (append (if (and (list? x) (eq? (car x) name)) (list x) '())
                        (scan (car x)) (scan (cdr x))))))
  (fold-left (lambda (out u) (append (scan (unit-body u)) out)) '() units))

(define (trusted-provider? x allowed)
  (or (and (pair? x) (eq? (car x) 'lambda) (memq 'lambda allowed))
      (and (symbol? x) (memq x allowed))))

(define (bad-trusted-direct-dispatch-sites units)
  (let loop ((specs trusted-direct-dispatch-sites) (bad '()))
    (if (null? specs)
        (reverse bad)
        (let* ((spec (car specs)) (name (car spec)) (arg-index (cadr spec))
               (allowed (caddr spec))
               (defs (filter (lambda (u) (eq? (unit-name u) name)) units))
               (calls (call-forms units name))
               (ok? (and (= (length defs) 1) (pair? calls)
                         (memq trusted-dynamic-call (unit-calls (car defs)))
                         (for-all
                           (lambda (c)
                             (and (> (length c) arg-index)
                                  (trusted-provider? (list-ref c arg-index) allowed)))
                           calls))))
          (loop (cdr specs)
                (if ok? bad
                    (cons (cons name "trusted callback provider set changed") bad)))))))

;; Non-vacuous synthetic mutations for #26. Each unsafe shape must produce the
;; expected dispatch finding, while releasing before the same helper must not.
;; These use the real collector/closure/finding pipeline, not a duplicate model.
(define (dispatch-self-test)
  (let* ((eq-helper (collect-unit "synthetic" 'eq-helper
                                  '((jolt= a b)) '(a b)))
         (xrf-helper (collect-unit "synthetic" 'xrf-helper
                                   '((ac-xrf-apply ch v)) '(ch v)))
         (opaque-helper (collect-unit "synthetic" 'opaque-helper
                                      '((f x)) '(f x)))
         (opaque-helper-caller
           (collect-unit "synthetic" 'opaque-helper-caller-mutation
                         '((jolt-with-mutex mu (opaque-helper f x)))
                         '(mu f x)))
         (lexical (collect-unit "synthetic" 'lexical-mutation
                                '((jolt-with-mutex mu (eq-helper a b)))
                                '(mu a b)))
         (direct (collect-unit "synthetic" 'direct-procedure-mutation
                               '((jolt-with-mutex mu (f x)))
                               '(mu f x)))
         (primitive-safe
           (collect-unit "synthetic" 'leaf-primitive-safe
                         '((jolt-with-mutex mu (#3%fx+ 1 2)))
                         '(mu)))
         (primitive-unknown
           (collect-unit "synthetic" 'unknown-primitive-mutation
                         '((jolt-with-mutex mu (($primitive 3 call/cc) f)))
                         '(mu f)))
         (let-formal (collect-unit "synthetic" 'let-formal-mutation
                                   '((let ((alias f))
                                       (jolt-with-mutex mu (alias x))))
                                   '(mu f x)))
         (let-lambda (collect-unit "synthetic" 'let-lambda-mutation
                                   '((let ((alias (lambda (x) (leaf x))))
                                       (jolt-with-mutex mu (alias x))))
                                   '(mu x)))
         (leaf (collect-unit "synthetic" 'leaf '((+ x 1)) '(x)))
         (let-leaf (collect-unit "synthetic" 'let-leaf-safe
                                 '((let ((alias leaf))
                                     (jolt-with-mutex mu (alias x))))
                                 '(mu x)))
         (named-let (collect-unit "synthetic" 'named-let-safe
                                  '((jolt-with-mutex mu
                                      (let loop ((n 3))
                                        (if (zero? n) n (loop (- n 1))))))
                                  '(mu)))
         (manual (collect-unit "synthetic" 'manual-mutation
                               '((jolt-lock! mu)
                                 (xrf-helper ch v)
                                 (jolt-unlock! mu))
                               '(mu ch v)))
         (nested-lock (collect-unit "synthetic" 'nested-lock-mutation
                                    '((jolt-lock! a)
                                      (jolt-lock! b)
                                      (jolt-unlock! b)
                                      (eq-helper x y)
                                      (jolt-unlock! a))
                                    '(a b x y)))
         (counted-reentry (collect-unit "synthetic" 'counted-reentry-mutation
                                        '((jolt-lock! a)
                                          (jolt-lock! a)
                                          (jolt-unlock! a)
                                          (eq-helper x y)
                                          (jolt-unlock! a))
                                        '(a x y)))
         (mismatched-lock (collect-unit "synthetic" 'mismatched-unlock-mutation
                                        '((jolt-lock! a)
                                          (jolt-unlock! b)
                                          (eq-helper x y)
                                          (jolt-unlock! a))
                                        '(a b x y)))
         (mismatched-family (collect-unit "synthetic" 'mismatched-family-mutation
                                          '((jolt-lock! a)
                                            (jolt-chan-unlock! a)
                                            (eq-helper x y)
                                            (jolt-unlock! a))
                                          '(a x y)))
         (begin-escape (collect-unit "synthetic" 'begin-lock-escape-mutation
                                     '((begin (jolt-lock! a))
                                       (eq-helper x y)
                                       (jolt-unlock! a))
                                     '(a x y)))
         (let-escape (collect-unit "synthetic" 'let-lock-escape-mutation
                                   '((let () (jolt-lock! a))
                                     (eq-helper x y)
                                     (jolt-unlock! a))
                                   '(a x y)))
         (let-balanced (collect-unit "synthetic" 'let-balanced-safe
                                     '((let ()
                                         (jolt-lock! a)
                                         (jolt-unlock! a))
                                       (eq-helper x y))
                                     '(a x y)))
         (argument-escape
           (collect-unit "synthetic" 'argument-lock-escape-mutation
                         '((consume (jolt-lock! a))
                           (eq-helper x y)
                           (jolt-unlock! a))
                         '(consume a x y)))
         (argument-balanced
           (collect-unit "synthetic" 'argument-balanced-safe
                         '((consume (begin (jolt-lock! a) (jolt-unlock! a)))
                           (eq-helper x y))
                         '(consume a x y)))
         (and-escape
           (collect-unit "synthetic" 'and-lock-escape-mutation
                         '((and p (jolt-lock! a))
                           (eq-helper x y)
                           (jolt-unlock! a))
                         '(p a x y)))
         (and-balanced
           (collect-unit "synthetic" 'and-balanced-safe
                         '((and p (begin (jolt-lock! a) (jolt-unlock! a)))
                           (eq-helper x y))
                         '(p a x y)))
         (cond-escape (collect-unit "synthetic" 'cond-lock-escape-mutation
                                    '((cond (p (jolt-lock! a)))
                                      (eq-helper x y)
                                      (jolt-unlock! a))
                                    '(a p x y)))
         (when-escape (collect-unit "synthetic" 'when-lock-escape-mutation
                                    '((when p (jolt-lock! a))
                                      (eq-helper x y)
                                      (jolt-unlock! a))
                                    '(a p x y)))
         (cond-balanced (collect-unit "synthetic" 'cond-balanced-safe
                                      '((cond (p (jolt-lock! a) (jolt-unlock! a))
                                              (else #f))
                                        (eq-helper x y))
                                      '(a p x y)))
         (if-launder (collect-unit "synthetic" 'if-unlock-launder-mutation
                                   '((jolt-lock! mu)
                                     (if p
                                         (jolt-unlock! mu)
                                         (eq-helper a b))
                                     (jolt-unlock! mu))
                                   '(mu p a b)))
         (if-acquire (collect-unit "synthetic" 'if-acquire-mutation
                                   '((if p (jolt-lock! mu) #f)
                                     (eq-helper a b))
                                   '(mu p a b)))
         (apply-helper (collect-unit "synthetic" 'apply-helper-mutation
                                     '((jolt-with-mutex mu
                                         (apply eq-helper args)))
                                     '(mu args)))
         (computed-apply (collect-unit "synthetic" 'computed-apply-mutation
                                       '((jolt-with-mutex mu
                                           (apply (if p f g) args)))
                                       '(mu p f g args)))
         (computed-apply-safe (collect-unit "synthetic" 'computed-apply-safe
                                            '((jolt-lock! mu)
                                              (jolt-unlock! mu)
                                              (apply (if p f g) args))
                                            '(mu p f g args)))
         (do-test-escape
           (collect-unit "synthetic" 'do-test-lock-mutation
                         '((do ()
                              ((begin (jolt-lock! a) done?))
                            (eq-helper x y)
                            (jolt-unlock! a)))
                         '(a done? x y)))
         (guard-arrow
           (collect-unit "synthetic" 'guard-arrow-mutation
                         '((jolt-with-mutex mu
                             (guard (e (#t => f)) (raise problem))))
                         '(mu f problem)))
         (guard-arrow-safe
           (collect-unit "synthetic" 'guard-arrow-safe
                         '((jolt-with-mutex mu
                             (guard (e (#t => leaf)) (raise problem))))
                         '(mu problem)))
         (cond-arrow-literal
           (collect-unit "synthetic" 'cond-arrow-literal-safe
                         '((jolt-with-mutex mu
                             (cond ((ready?) => (lambda (v) v)))))
                         '(mu)))
         (cond-arrow-literal-dispatch
           (collect-unit "synthetic" 'cond-arrow-literal-mutation
                         '((jolt-with-mutex mu
                             (cond ((ready?) =>
                                    (lambda (v) (jolt-invoke v))))))
                         '(mu)))
         (cond-arrow-computed
           (collect-unit "synthetic" 'cond-arrow-computed-mutation
                         '((jolt-with-mutex mu
                             (cond ((ready?) => (if p f g)))))
                         '(mu p f g)))
         (guard-arrow-literal
           (collect-unit "synthetic" 'guard-arrow-literal-safe
                         '((jolt-with-mutex mu
                             (guard (e (#t => (lambda (v) v)))
                               (raise problem))))
                         '(mu problem)))
         (guard-arrow-literal-dispatch
           (collect-unit "synthetic" 'guard-arrow-literal-mutation
                         '((jolt-with-mutex mu
                             (guard (e (#t =>
                                        (lambda (v) (jolt-invoke v))))
                               (raise problem))))
                         '(mu problem)))
         (trusted-only (collect-unit "synthetic" 'jolt-lock-wait
                                     '((jolt-with-mutex mu (decide)))
                                     '(mu decide)))
         (trusted-plus-opaque (collect-unit "synthetic" 'jolt-lock-wait
                                            '((jolt-with-mutex mu
                                                (decide)
                                                (opaque)))
                                            '(mu decide opaque)))
         (safe (collect-unit "synthetic" 'manual-safe
                             '((jolt-lock! mu)
                               (jolt-unlock! mu)
                               (xrf-helper ch v))
                             '(mu ch v)))
         (syntax-safe (collect-unit "synthetic" 'syntax-safe
                                    '((jolt-with-mutex mu
                                        (cond ((ready?) => values)
                                              (else (guard (e (#t leaf)) leaf)))))
                                    '(mu)))
         (deferred-safe (collect-unit "synthetic" 'deferred-safe
                                      '((jolt-with-mutex mu
                                          (fork-thread (lambda () (jolt-invoke f)))))
                                      '(mu f)))
         (units (list eq-helper xrf-helper opaque-helper opaque-helper-caller
                      lexical direct primitive-safe primitive-unknown
                      let-formal let-lambda
                      leaf let-leaf named-let manual nested-lock counted-reentry
                      mismatched-lock
                      mismatched-family
                      begin-escape let-escape let-balanced argument-escape
                      argument-balanced and-escape and-balanced cond-escape when-escape
                      cond-balanced if-launder if-acquire apply-helper
                      computed-apply computed-apply-safe do-test-escape guard-arrow
                      guard-arrow-safe cond-arrow-literal
                      cond-arrow-literal-dispatch cond-arrow-computed
                      guard-arrow-literal guard-arrow-literal-dispatch trusted-only
                      trusted-plus-opaque safe
                      syntax-safe deferred-safe))
         (parks (build-parkers units))
         (dispatches (build-dispatchers units))
         (got (findings units parks dispatches)))
    (define (has? name kind)
      (exists (lambda (f) (and (eq? (cadr f) name) (eq? (caddr f) kind))) got))
    (and (has? 'lexical-mutation 'dispatch)
         (has? 'opaque-helper-caller-mutation 'dispatch)
         (has? 'direct-procedure-mutation 'dispatch)
         (not (has? 'leaf-primitive-safe 'dispatch))
         (has? 'unknown-primitive-mutation 'dispatch)
         (has? 'let-formal-mutation 'dispatch)
         (has? 'let-lambda-mutation 'dispatch)
         (not (has? 'let-leaf-safe 'dispatch))
         (not (has? 'named-let-safe 'dispatch))
         (has? 'manual-mutation 'dispatch)
         (has? 'nested-lock-mutation 'dispatch)
         (has? 'counted-reentry-mutation 'dispatch)
         (has? 'mismatched-unlock-mutation 'dispatch)
         (has? 'mismatched-family-mutation 'dispatch)
         (has? 'begin-lock-escape-mutation 'dispatch)
         (has? 'let-lock-escape-mutation 'dispatch)
         (not (has? 'let-balanced-safe 'dispatch))
         (has? 'argument-lock-escape-mutation 'dispatch)
         (not (has? 'argument-balanced-safe 'dispatch))
         (has? 'and-lock-escape-mutation 'dispatch)
         (not (has? 'and-balanced-safe 'dispatch))
         (has? 'cond-lock-escape-mutation 'dispatch)
         (has? 'when-lock-escape-mutation 'dispatch)
         (not (has? 'cond-balanced-safe 'dispatch))
         (has? 'if-unlock-launder-mutation 'dispatch)
         (has? 'if-acquire-mutation 'dispatch)
         (has? 'apply-helper-mutation 'dispatch)
         (has? 'computed-apply-mutation 'dispatch)
         (not (has? 'computed-apply-safe 'dispatch))
         (has? 'do-test-lock-mutation 'dispatch)
         (has? 'guard-arrow-mutation 'dispatch)
         (not (has? 'guard-arrow-safe 'dispatch))
         (not (has? 'cond-arrow-literal-safe 'dispatch))
         (has? 'cond-arrow-literal-mutation 'dispatch)
         (has? 'cond-arrow-computed-mutation 'dispatch)
         (not (has? 'guard-arrow-literal-safe 'dispatch))
         (has? 'guard-arrow-literal-mutation 'dispatch)
         (has? 'jolt-lock-wait 'dispatch)
         (memq trusted-dynamic-call (unit-locked trusted-only))
         (not (memq dynamic-call (unit-locked trusted-only)))
         (memq dynamic-call (unit-locked trusted-plus-opaque))
         (not (has? 'manual-safe 'dispatch))
         (not (has? 'syntax-safe 'dispatch))
         (not (has? 'deferred-safe 'dispatch)))))

(define (checkpoint-disposition-self-test)
  (let* ((direct-continue
           (collect-unit "synthetic" 'checkpoint-direct-continue-safe
             '((jolt-with-mutex mu
                 (jolt-checkpoint-continue! "test/direct"))) '(mu)))
         (continue-helper
           (collect-unit "synthetic" 'checkpoint-continue-helper
             '((jolt-checkpoint-continue! "test/helper")) '()))
         (through-continue
           (collect-unit "synthetic" 'checkpoint-through-continue-safe
             '((jolt-with-mutex mu (checkpoint-continue-helper))) '(mu)))
         (direct-generic
           (collect-unit "synthetic" 'checkpoint-direct-generic-mutation
             '((jolt-with-mutex mu
                 (jolt-checkpoint! "test/generic" '(continue yield)))) '(mu)))
         (generic-helper
           (collect-unit "synthetic" 'checkpoint-generic-helper
             '((jolt-checkpoint! "test/helper" '(continue fault))) '()))
         (through-generic
           (collect-unit "synthetic" 'checkpoint-through-generic-mutation
             '((jolt-with-mutex mu (checkpoint-generic-helper))) '(mu)))
         (generic-wrapper
           (collect-unit "synthetic" 'checkpoint-generic-wrapper
             '((checkpoint-generic-helper)) '()))
         (through-wrapper
           (collect-unit "synthetic" 'checkpoint-through-wrapper-mutation
             '((jolt-with-mutex mu (checkpoint-generic-wrapper))) '(mu)))
         (dynamic-id
           (collect-unit "synthetic" 'checkpoint-dynamic-id-mutation
             '((jolt-with-mutex mu (jolt-checkpoint-continue! id))) '(mu id)))
         (malformed-id
           (collect-unit "synthetic" 'checkpoint-malformed-id-mutation
             '((jolt-with-mutex mu
                 (jolt-checkpoint-continue! "unqualified"))) '(mu)))
         (leaf-extra-argument
           (collect-unit "synthetic" 'checkpoint-leaf-arity-mutation
             '((jolt-with-mutex mu
                 (jolt-checkpoint-continue! "test/arity" extra))) '(mu extra)))
         (applied
           (collect-unit "synthetic" 'checkpoint-apply-mutation
             '((jolt-with-mutex mu
                 (apply jolt-checkpoint-continue! args))) '(mu args)))
         ;; Exercise the real top-level definition collector: these exact value
         ;; aliases were the escape that the operator-only call graph missed.
         (generic-alias
           (collect-definition "synthetic" '(define cp jolt-checkpoint!)))
         (through-generic-alias
           (collect-unit "synthetic" 'checkpoint-through-generic-alias-mutation
             '((jolt-with-mutex mu
                 (cp "test/alias" '(continue yield))))
             '(mu)))
         (generic-alias-chain
           (collect-definition "synthetic" '(define cp2 cp)))
         (through-generic-alias-chain
           (collect-unit "synthetic"
             'checkpoint-through-generic-alias-chain-mutation
             '((jolt-with-mutex mu
                 (cp2 "test/alias-chain" '(continue fault)))) '(mu)))
         (continue-alias
           (collect-definition "synthetic"
             '(define continue-cp jolt-checkpoint-continue!)))
         (through-continue-alias
           (collect-unit "synthetic" 'checkpoint-through-continue-alias-mutation
             '((jolt-with-mutex mu
                 (continue-cp "test/continue-alias"))) '(mu)))
         (through-continue-alias-dynamic
           (collect-unit "synthetic"
             'checkpoint-through-continue-alias-dynamic-mutation
             '((jolt-with-mutex mu (continue-cp id))) '(mu id)))
         (set-alias
           (collect-definition "synthetic"
             '(set! mutable-cp jolt-checkpoint!)))
         (define-values-alias
           (collect-definition "synthetic"
             '(define-values (values-cp)
                (values jolt-checkpoint-continue!))))
         (define-syntax-wrapper
           (collect-definition "define-syntax-synthetic"
             '(define-syntax checkpoint-macro
                (syntax-rules ()
                  ((_ id dispositions)
                   (jolt-checkpoint! id dispositions))))))
         (through-define-syntax
           (collect-unit "synthetic"
             'checkpoint-through-define-syntax-mutation
             '((jolt-with-mutex mu
                 (checkpoint-macro "test/macro" '(continue yield)))) '(mu)))
         (local-syntax-wrapper
           (collect-unit "synthetic" 'checkpoint-local-syntax-mutation
             '((let-syntax
                 ((local-checkpoint
                    (syntax-rules ()
                      ((_ id)
                       (jolt-checkpoint-continue! id)))))
                 (jolt-with-mutex mu
                   (local-checkpoint "test/local-macro")))) '(mu)))
         (local-recursive-syntax-wrapper
           (collect-unit "synthetic" 'checkpoint-local-recursive-syntax-mutation
             '((letrec-syntax
                 ((local-checkpoint
                    (syntax-rules ()
                      ((_ id dispositions)
                       (jolt-checkpoint! id dispositions)))))
                 (jolt-with-mutex mu
                   (local-checkpoint
                     "test/local-recursive-macro" '(continue cancel))))) '(mu)))
         (manual
           (collect-unit "synthetic" 'checkpoint-manual-lock-mutation
             '((jolt-lock! mu)
               (jolt-checkpoint! "test/manual" '(continue cancel))
               (jolt-unlock! mu)) '(mu)))
         (after-unlock
           (collect-unit "synthetic" 'checkpoint-after-unlock-safe
             '((jolt-lock! mu)
               (snapshot-state)
               (jolt-unlock! mu)
               (jolt-checkpoint! "test/after" '(continue barrier))) '(mu)))
         (before-unlock
           (collect-unit "synthetic" 'checkpoint-before-unlock-mutation
             '((jolt-lock! mu)
               (snapshot-state)
               (jolt-checkpoint! "test/before" '(continue barrier))
               (jolt-unlock! mu)) '(mu)))
         (units
           (list direct-continue continue-helper through-continue direct-generic
                 generic-helper through-generic generic-wrapper through-wrapper
                 dynamic-id malformed-id leaf-extra-argument applied manual
                 generic-alias through-generic-alias generic-alias-chain
                 through-generic-alias-chain continue-alias
                 through-continue-alias through-continue-alias-dynamic
                 set-alias define-values-alias
                 define-syntax-wrapper through-define-syntax
                 local-syntax-wrapper local-recursive-syntax-wrapper
                 after-unlock before-unlock))
         (hazards (build-checkpoint-hazards units))
         (got (checkpoint-findings units hazards))
         (value-got (checkpoint-value-findings units)))
    (define (has? name)
      (exists (lambda (f) (eq? (cadr f) name)) got))
    (define (has-value? unit-name entrypoint)
      (exists
        (lambda (f)
          (and (eq? (cadr f) unit-name)
               (eq? (cadddr f) entrypoint)))
        value-got))
    (and (not (has? 'checkpoint-direct-continue-safe))
         (not (has-value? 'checkpoint-direct-continue-safe
                          checkpoint-continue-call))
         (not (has? 'checkpoint-through-continue-safe))
         (has? 'checkpoint-direct-generic-mutation)
         (has? 'checkpoint-through-generic-mutation)
         (has? 'checkpoint-through-wrapper-mutation)
         (has? 'checkpoint-dynamic-id-mutation)
         (has? 'checkpoint-malformed-id-mutation)
         (has? 'checkpoint-leaf-arity-mutation)
         (has? 'checkpoint-apply-mutation)
         (has? 'checkpoint-through-generic-alias-mutation)
         (has? 'checkpoint-through-generic-alias-chain-mutation)
         (has? 'checkpoint-through-continue-alias-mutation)
         (has? 'checkpoint-through-continue-alias-dynamic-mutation)
         (has-value? 'cp checkpoint-generic-call)
         (has-value? 'continue-cp checkpoint-continue-call)
         (has-value? 'synthetic::toplevel checkpoint-generic-call)
         (has-value? 'synthetic::toplevel checkpoint-continue-call)
         (has-value? 'define-syntax-synthetic::toplevel
                     checkpoint-generic-call)
         (has-value? 'checkpoint-local-syntax-mutation
                     checkpoint-continue-call)
         (has-value? 'checkpoint-local-recursive-syntax-mutation
                     checkpoint-generic-call)
         (has? 'checkpoint-manual-lock-mutation)
         (not (has? 'checkpoint-after-unlock-safe))
         (has? 'checkpoint-before-unlock-mutation))))

(define (logical-region-self-test)
  (let ((locks (make-eq-hashtable)))
    (for-each (lambda (x) (hashtable-set! locks x #t)) '(mu-a mu-b mu-c))
    (parameterize ((known-logical-locks locks))
      (let* ((direct
               (collect-unit "synthetic" 'direct
                 '((jolt-with-logical-mutex mu-a
                     (lambda () (jolt-invoke f x)))) '()))
             (dispatch-helper
               (collect-unit "synthetic" 'dispatch-helper
                 '((jolt-invoke f x)) '()))
             (through-dispatch
               (collect-unit "synthetic" 'through-dispatch
                 '((jolt-with-logical-mutex mu-a
                     (lambda () (dispatch-helper)))) '()))
             (opaque-body
               (collect-unit "synthetic" 'opaque-body
                 '((jolt-with-logical-mutex mu-a thunk)) '(thunk)))
             (safe-leaf
               (collect-unit "synthetic" 'safe-leaf
                 '((jolt-with-logical-mutex mu-a (lambda () (#3%fx+ 1 2)))) '()))
             (sync-callback
               (collect-unit "synthetic" 'sync-callback
                 '((jolt-with-logical-mutex mu-a
                     (lambda ()
                       (for-each
                         (lambda (x)
                           (jolt-invoke f x)
                           (jolt-with-logical-mutex mu-b (lambda () x)))
                         xs)))) '()))
             (sync-alias
               (collect-unit "synthetic" 'sync-alias
                 '((jolt-with-logical-mutex mu-a
                     (lambda ()
                       (let ((each for-each))
                         (each
                           (lambda (x)
                             (jolt-with-logical-mutex mu-b (lambda () x)))
                           xs))))) '()))
             (sync-shadow
               (collect-unit "synthetic" 'sync-shadow
                 '((jolt-with-logical-mutex mu-a
                     (lambda ()
                       (let ((for-each deferred-consumer))
                         (for-each
                           (lambda (x)
                             (jolt-with-logical-mutex mu-b (lambda () x)))
                           xs))))) '()))
             (computed-callback-factory
               (collect-unit "synthetic" 'computed-callback-factory
                 '((jolt-with-logical-mutex mu-b (lambda () callback))) '()))
             (sync-computed
               (collect-unit "synthetic" 'sync-computed
                 '((jolt-with-logical-mutex mu-a
                     (lambda ()
                       (for-each (computed-callback-factory) xs)))) '()))
             (deferred-factory
               (collect-unit "synthetic" 'deferred-factory
                 '((lambda ()
                     (jolt-with-logical-mutex mu-b
                       (lambda () (jolt-invoke f x))))) '()))
             (through-deferred
               (collect-unit "synthetic" 'through-deferred
                 '((jolt-with-logical-mutex mu-a
                     (lambda () (deferred-factory)))) '()))
             (nested
               (collect-unit "synthetic" 'nested
                 '((jolt-with-logical-mutex mu-a
                     (lambda ()
                       (jolt-with-logical-mutex mu-b (lambda () 1))))) '()))
             (helper
               (collect-unit "synthetic" 'helper
                 '((jolt-with-logical-mutex mu-b (lambda () 1))) '()))
             (through-helper
               (collect-unit "synthetic" 'through-helper
                 '((jolt-with-logical-mutex mu-a (lambda () (helper)))) '()))
             (reentrant
               (collect-unit "synthetic" 'reentrant
                 '((jolt-with-logical-mutex mu-a
                     (lambda ()
                       (jolt-with-logical-mutex mu-a (lambda () 1))))) '()))
             (deferred
               (collect-unit "synthetic" 'deferred
                 '((jolt-with-logical-mutex mu-a
                     (lambda ()
                       (fork-thread
                         (lambda ()
                           (jolt-with-logical-mutex mu-b (lambda () 1))))))) '()))
             (computed-factory
               (collect-unit "synthetic" 'computed-factory
                 '((jolt-with-logical-mutex mu-b (lambda () thunk))) '()))
             (fork-computed
               (collect-unit "synthetic" 'fork-computed
                 '((jolt-with-logical-mutex mu-a
                     (lambda () (fork-thread (computed-factory))))) '()))
             (wrapper-computed
               (collect-unit "synthetic" 'wrapper-computed
                 '((jolt-with-logical-mutex mu-a (computed-factory))) '()))
             (unknown
               (collect-unit "synthetic" 'unknown
                 '((jolt-with-logical-mutex (choose-lock) (lambda () 1))) '()))
             (unknown-held
               (collect-unit "synthetic" 'unknown-held
                 '((jolt-with-logical-mutex mu-a
                     (lambda ()
                       (jolt-with-logical-mutex runtime-lock
                         (lambda () 1))))) '(runtime-lock)))
             (shadowed
               (collect-unit "synthetic" 'shadowed
                 '((jolt-with-logical-mutex mu-a (lambda () 1))) '(mu-a)))
             (let-shadowed
               (collect-unit "synthetic" 'let-shadowed
                 '((let ((mu-a runtime-lock))
                     (jolt-with-logical-mutex mu-a (lambda () 1)))) '()))
             (malformed
               (collect-unit "synthetic" 'malformed
                 '((jolt-with-logical-mutex mu-a)) '()))
             (aliased
               (collect-unit "synthetic" 'aliased
                 '((let ((hold jolt-with-logical-mutex))
                     (hold mu-a (lambda () 1)))) '()))
             (applied
               (collect-unit "synthetic" 'applied
                 '((apply jolt-with-logical-mutex
                          (list mu-a (lambda () 1)))) '()))
             (apply-argument
               (collect-unit "synthetic" 'apply-argument
                 '((jolt-with-logical-mutex mu-a
                     (lambda ()
                       (apply f
                         (list
                           (jolt-with-logical-mutex mu-b (lambda () 1)))))))
                 '(f)))
             (apply-synchronous
               (collect-unit "synthetic" 'apply-synchronous
                 '((apply for-each args)) '()))
             (low-level
               (collect-unit "synthetic" 'low-level
                 '((jolt-logical-mutex-enter! mu-a)) '()))
             (top-long
               (collect-definition "synthetic"
                 '(define top-long
                    (lambda ()
                      (jolt-with-logical-mutex mu-a
                        (lambda () (jolt-invoke f x)))))))
             (top-case-long
               (collect-definition "synthetic"
                 '(define top-case-long
                    (case-lambda
                      (() (jolt-with-logical-mutex mu-a
                            (lambda () (jolt-invoke f x))))
                      ((x) x)))))
             (nested-define
               (collect-unit "synthetic" 'nested-define
                 '((jolt-with-logical-mutex mu-a
                     (lambda ()
                       (define (later)
                         (jolt-with-logical-mutex mu-b (lambda () 1)))
                       1))) '()))
             (top-alias
               (collect-definition "synthetic"
                 '(define hold jolt-with-logical-mutex)))
             (computed-head
               (collect-unit "synthetic" 'computed-head
                 '(((if p jolt-with-logical-mutex other)
                    mu-a (lambda () 1))) '()))
             (back-edge
               (collect-unit "synthetic" 'back-edge
                 '((jolt-with-logical-mutex mu-b
                     (lambda ()
                       (jolt-with-logical-mutex mu-a (lambda () 1))))) '()))
             (dispatch-units
               (list direct dispatch-helper through-dispatch opaque-body safe-leaf
                     sync-callback sync-computed computed-callback-factory
                     top-long top-case-long deferred-factory through-deferred))
             (dispatches (build-logical-dispatchers dispatch-units))
             (all (list helper through-helper))
             (acquires (build-logical-acquisitions all))
             (transitive-edges (logical-order-edges all acquires))
             (acyclic-edges
               (logical-order-edges (list nested)
                 (build-logical-acquisitions (list nested))))
             (cycle-edges
               (logical-order-edges (list nested back-edge)
                 (build-logical-acquisitions (list nested back-edge))))
             (prefix-a
               (collect-unit "synthetic" 'prefix-a
                 '((jolt-with-logical-mutex mu-a
                     (lambda ()
                       (jolt-with-logical-mutex mu-b (lambda () 1))))) '()))
             (prefix-b
               (collect-unit "synthetic" 'prefix-b
                 '((jolt-with-logical-mutex mu-b
                     (lambda ()
                       (jolt-with-logical-mutex mu-c (lambda () 1))))) '()))
             (prefix-c
               (collect-unit "synthetic" 'prefix-c
                 '((jolt-with-logical-mutex mu-c
                     (lambda ()
                       (jolt-with-logical-mutex mu-b (lambda () 1))))) '()))
             (prefix-units (list prefix-a prefix-b prefix-c))
             (prefix-cycle
               (logical-order-cycle
                 (logical-order-edges prefix-units
                   (build-logical-acquisitions prefix-units))))
             (identity-analysis
               (analyze-logical-lock-identities
                 '((define mu-a (jolt-logical-mutex-new))
                   (define mu-a other)
                   (set! mu-a replacement)))))
        (let ((failures 0))
          (define (exact label actual expected)
            (unless (equal? actual expected)
              (set! failures (+ failures 1))
              (printf "logical-region self-test FAIL ~a\n  expected: ~s\n  actual:   ~s\n"
                      label expected actual)))
          (exact 'dispatch-findings
            (map finding->line
              (logical-dispatch-findings
                (list direct through-dispatch opaque-body safe-leaf sync-callback
                      sync-computed top-long top-case-long through-deferred)
                dispatches))
            '("synthetic direct logical-dispatch mu-a->jolt-invoke 1"
              "synthetic opaque-body logical-dispatch mu-a->procedure-valued-dispatch 1"
              "synthetic sync-callback logical-dispatch mu-a->jolt-invoke 1"
              "synthetic sync-computed logical-dispatch mu-a->procedure-valued-dispatch 1"
              "synthetic through-dispatch logical-dispatch mu-a->dispatch-helper 1"
              "synthetic top-case-long logical-dispatch mu-a->jolt-invoke 1"
              "synthetic top-long logical-dispatch mu-a->jolt-invoke 1"))
          (exact 'direct-edge (unit-logical-edges nested) '((mu-a . mu-b)))
          (exact 'transitive-edge transitive-edges '((mu-a . mu-b)))
          (exact 'reentrant-control (unit-logical-edges reentrant) '())
          (exact 'deferred-control (unit-logical-edges deferred) '())
          (exact 'synchronous-callback-edge
                 (unit-logical-edges sync-callback) '((mu-a . mu-b)))
          (exact 'synchronous-callback-alias
                 (unit-logical-edges sync-alias) '((mu-a . mu-b)))
          (exact 'synchronous-callback-shadow
                 (unit-logical-edges sync-shadow) '())
          (exact 'synchronous-computed-callback-edge
            (logical-order-edges
              (list computed-callback-factory sync-computed)
              (build-logical-acquisitions
                (list computed-callback-factory sync-computed)))
            '((mu-a . mu-b)))
          (exact 'nested-define-control
                 (unit-logical-edges nested-define) '())
          (exact 'apply-argument-evaluation
                 (unit-logical-edges apply-argument) '((mu-a . mu-b)))
          ;; Only a computed fork thunk expression is synchronous; the literal
          ;; child body and an ordinary returned lambda remain deferred.
          (exact 'computed-fork-expression
            (logical-order-edges (list computed-factory fork-computed)
              (build-logical-acquisitions (list computed-factory fork-computed)))
            '((mu-a . mu-b)))
          (exact 'computed-wrapper-evaluation
            (logical-order-edges (list computed-factory wrapper-computed)
              (build-logical-acquisitions (list computed-factory wrapper-computed)))
            '())
          (exact 'computed-wrapper-dispatch
            (map finding->line
              (logical-dispatch-findings (list wrapper-computed)
                (build-logical-dispatchers
                  (list computed-factory wrapper-computed))))
            '("synthetic wrapper-computed logical-dispatch mu-a->procedure-valued-dispatch 1"))
          (exact 'computed-fork-dispatch-side
            (map finding->line
              (logical-dispatch-findings (list fork-computed)
                (build-logical-dispatchers
                  (list computed-factory fork-computed))))
            '())
          (exact 'ordinary-deferred-lambda
            (logical-order-edges (list deferred-factory through-deferred)
              (build-logical-acquisitions (list deferred-factory through-deferred)))
            '())
          (exact 'unknown-identities
            (logical-unknown-findings
              (list unknown unknown-held shadowed let-shadowed)
              (build-logical-acquisitions
                (list unknown unknown-held shadowed let-shadowed)))
            '("synthetic let-shadowed unknown-acquisition wrapper"
              "synthetic shadowed unknown-acquisition wrapper"
              "synthetic unknown unknown-acquisition wrapper"
              "synthetic unknown-held unknown-acquisition wrapper"
              "synthetic unknown-held unknown-order-edge wrapper"))
          (exact 'unsupported-syntax
            (logical-unknown-findings
              (list aliased applied apply-synchronous computed-head low-level
                    malformed top-alias)
              (build-logical-acquisitions
                (list aliased applied apply-synchronous computed-head low-level
                      malformed top-alias)))
            '("synthetic aliased unsupported-alias jolt-with-logical-mutex"
              "synthetic aliased unsupported-capability-value jolt-with-logical-mutex"
              "synthetic applied unsupported-apply jolt-with-logical-mutex"
              "synthetic applied unsupported-capability-value jolt-with-logical-mutex"
              "synthetic apply-synchronous unsupported-synchronous-apply for-each"
              "synthetic computed-head unsupported-capability-value jolt-with-logical-mutex"
              "synthetic hold unsupported-capability-value jolt-with-logical-mutex"
              "synthetic low-level unsupported-low-level jolt-logical-mutex-enter!"
              "synthetic malformed unsupported-wrapper-arity jolt-with-logical-mutex"))
          (exact 'acyclic-control (logical-order-cycle acyclic-edges) #f)
          (exact 'two-node-cycle (logical-order-cycle cycle-edges)
                 '(mu-a mu-b mu-a))
          (exact 'trimmed-prefix-cycle prefix-cycle '(mu-b mu-c mu-b))
          (exact 'identity-discovery (cdr identity-analysis)
            '("logical mutex mu-a has 2 top-level definitions"
              "logical mutex mu-a is mutated with set!"))
          (exact 'identity-discovery-lock
                 (hashtable-ref (car identity-analysis) 'mu-a #f) #t)
          (= failures 0))))))

(define (primitive-whitelist-self-test)
  (and (eq? (primitive-head-name '($primitive 3 fx+)) 'fx+)
       (eq? (primitive-head-name '($primitive fx+)) 'fx+)
       (leaf-primitive-head? '($primitive 3 fx+))
       (not (leaf-primitive-head? '($primitive 3 call/cc)))
       (not (primitive-head-name '($primitive 3 fx+ extra)))))

;; ---------------------------------------------------------------------------
;; allowlist
;; ---------------------------------------------------------------------------

(define (allowlist-lines)
  (if (file-exists? allowlist-file)
      (let ((p (open-input-file allowlist-file)))
        (let loop ((acc '()))
          (let ((l (get-line p)))
            (cond
              ((eof-object? l) (close-port p) (reverse acc))
              ((or (string=? l "")
                   (and (> (string-length l) 0) (char=? #\# (string-ref l 0))))
               (loop acc))
              (else (loop (cons l acc)))))))
      '()))

(define (write-allowlist! lines)
  (let ((p (open-output-file allowlist-file 'truncate)))
    (for-each (lambda (l) (put-string p l) (put-string p "\n"))
      (list "# host/chez/park-lock-allowlist.txt — generated. Regenerate with:"
            "#   sh host/chez/park-lock-check.sh --regen"
            "# Park-only format: <file> <definition> park <callee> <count>."
            "# This file remains empty. Generic dispatch debt belongs in"
            "# park-lock-known-debt.txt and requires an exact central issue tag."))
    (for-each (lambda (l) (put-string p l) (put-string p "\n")) lines)
    (close-port p)))

;; ---------------------------------------------------------------------------
;; main
;; ---------------------------------------------------------------------------

(define (fix-hint l)
  (if (string=? "dispatch" (analysis-finding-kind l))
      (string-append " — this region hands control to code the lock did not write,"
                     " which may park; move the call out of the region")
      (string-append " — commit under the lock and switch outside it"
                     " (jolt-lock-wait, host/chez/locks.ss)")))

(define (find-line key lines)
  (let loop ((ls lines))
    (cond ((null? ls) #f)
          ((string=? key (analysis-finding-key (car ls))) (car ls))
          (else (loop (cdr ls))))))

(define (main args)
  (let* ((files (find-files))
         (logical-lock-scan (discover-logical-locks files))
         (units
           (parameterize ((known-logical-locks (car logical-lock-scan)))
             (let loop ((fs files) (acc '()) (errs '()))
               (if (null? fs)
                   (cons acc (reverse errs))
                   (guard (e (#t (loop (cdr fs) acc
                                       (cons (car fs) errs))))
                     (loop (cdr fs) (append (collect-file (car fs)) acc) errs))))))
         (bad-reads (append (cadr logical-lock-scan) (cdr units)))
         (logical-identity-errors (caddr logical-lock-scan))
         (units (car units)))
    ;; A file that will not read is a HOLE, not something to skip past.
    (unless (null? bad-reads)
      (for-each (lambda (f) (printf "  UNREADABLE: ~a\n" f)) bad-reads)
      (printf "park/lock check: FAILED\n")
      (exit 1))
    (unless (null? logical-identity-errors)
      (for-each (lambda (problem) (printf "  LOGICAL IDENTITY: ~a\n" problem))
                logical-identity-errors)
      (printf "park/lock check: FAILED\n")
      (exit 1))
    (let* ((parks (build-parkers units))
           (dispatches (build-dispatchers units))
           (checkpoint-hazards (build-checkpoint-hazards units))
           (logical-dispatchers (build-logical-dispatchers units))
           (logical-acquires (build-logical-acquisitions units))
           (logical-edges (logical-order-edges units logical-acquires))
           (logical-cycle (logical-order-cycle logical-edges))
           (logical-unknowns (logical-unknown-findings units logical-acquires))
           (got (map finding->line (findings units parks dispatches)))
           (park-got
             (filter (lambda (g) (string=? "park" (analysis-finding-kind g))) got))
           (dispatch-got
             (filter (lambda (g) (string=? "dispatch" (analysis-finding-kind g))) got))
           (checkpoint-got
             (map finding->line
                  (checkpoint-findings units checkpoint-hazards)))
           (checkpoint-value-got
             (map finding->line (checkpoint-value-findings units)))
           (logical-dispatch-got
             (map finding->line
                  (logical-dispatch-findings units logical-dispatchers)))
           (debt
             (analysis-validate-debt-lines
               (analysis-read-data-lines debt-file) '("dispatch") issue-prefix))
           (logical-debt
             (analysis-validate-debt-lines
               (analysis-read-data-lines logical-debt-file)
               '("logical-dispatch") issue-prefix))
           (missing (append (missing-switch-assertions units)
                            (bad-guarded-boundaries units parks)
                            (bad-trusted-callbacks units parks dispatches)
                            (bad-trusted-direct-dispatch-sites units)))
           (self-test-ok? (and (guarded-boundary-self-test)
                               (dispatch-self-test)
                               (checkpoint-disposition-self-test)
                               (logical-region-self-test)
                               (analysis-debt-self-test '("dispatch") issue-prefix)
                               (primitive-whitelist-self-test))))
      (cond
        ((and (pair? args) (string=? (car args) "--logical-report"))
         (for-each (lambda (line) (printf "~a\n" line)) logical-dispatch-got)
         (for-each
           (lambda (edge)
             (printf "logical-acquire ~a->~a\n"
                     (symbol->string (car edge)) (symbol->string (cdr edge))))
           logical-edges)
         (for-each
           (lambda (site) (printf "logical-unknown ~a\n" site))
           logical-unknowns)
         (when logical-cycle (printf "logical-cycle ~s\n" logical-cycle))
         (exit 0))
        ((and (pair? args) (string=? (car args) "--self-test"))
         (if (and self-test-ok? (null? missing))
             (begin
               (printf "park/lock checker self-test: PASS (guard/receiver, counted and logical transitive dispatch, checkpoint literal/dynamic/direct/transitive/manual/after-unlock/value-alias/set!/define-values/define-syntax/local-syntax mutations, named/transitive logical acquisition, reentry/deferred controls, unknown identity and cycle mutations, manual/control/compound-expression/alias/apply mutations, primitive whitelist safe/unknown teeth, call-site trusted callbacks, issue-tagged debt mutations)\n")
               (exit 0))
             (begin
               (printf "park/lock checker self-test: FAILED\n")
               (exit 1))))
        ((and (pair? args) (string=? (car args) "--regen"))
         ;; Generic dispatch debt is never generated: every accepted row needs a
         ;; reviewed issue. --regen owns only the park allowlist, whose target is 0.
         (write-allowlist! park-got)
         (printf "park/lock check: regenerated ~a park entries (dispatch debt unchanged)\n"
                 (length park-got))
         (exit 0))
        (else
         (let ((want (allowlist-lines)) (problems '()))
           (define (add! s) (set! problems (cons s problems)))
           ;; the teeth first: without the runtime half this check is a lint
           (unless self-test-ok?
             (add! "  CHECKER SELF-TEST FAILED: park, dispatch, checkpoint, or manual-lock mutation was not detected"))
           (for-each
             (lambda (g)
               (add! (string-append "  CHECKPOINT UNDER COUNTED LOCK: " g)))
             checkpoint-got)
           (for-each
             (lambda (g)
               (add! (string-append
                       "  STORED CHECKPOINT CAPABILITY: " g
                       " — call the canonical entry point directly")))
             checkpoint-value-got)
           (for-each
             (lambda (m)
               (add! (string-append "  SWITCH POINT UNGUARDED: " (symbol->string (car m))
                                    " " (cdr m) " — the runtime half of the rule is"
                                    " gone (host/chez/locks.ss)")))
             missing)
           (for-each
             (lambda (p) (add! (string-append "  DEBT: " p)))
             (analysis-debt-problems dispatch-got debt))
           (for-each
             (lambda (p) (add! (string-append "  LOGICAL DEBT: " p)))
             (analysis-debt-problems logical-dispatch-got logical-debt))
           (for-each
             (lambda (site)
               (add! (string-append "  UNKNOWN LOGICAL MUTEX: " site)))
             logical-unknowns)
           (when logical-cycle
             (add! (string-append "  LOGICAL LOCK-ORDER CYCLE: "
                                  (format "~s" logical-cycle))))
           (for-each
             (lambda (g)
               (let ((w (find-line (analysis-finding-key g) want)))
                 (cond
                   ((not w)
                    (add! (string-append "  NEW site: " g (fix-hint g))))
                   ((> (analysis-finding-count g) (analysis-finding-count w))
                    (add! (string-append "  MORE of them: " g " (was "
                                         (number->string (analysis-finding-count w)) ")"
                                         (fix-hint g)))))))
             park-got)
           (for-each
             (lambda (w)
               (let ((g (find-line (analysis-finding-key w) park-got)))
                 (when (< (if g (analysis-finding-count g) 0)
                          (analysis-finding-count w))
                   (add! (string-append "  STALE allowlist entry: " w " -> "
                                        (number->string
                                          (if g (analysis-finding-count g) 0))
                                        " — rerun with --regen")))))
             want)
           (cond
             ((pair? problems)
              (for-each (lambda (p) (printf "~a\n" p)) (reverse problems))
              (printf "park/lock check: FAILED\n")
              (exit 1))
             (else
              (printf "park/lock check: passed (~a files, ~a definitions, ~a can park, ~a park allowlist, ~a checkpoint hazards, ~a stored checkpoint capabilities, ~a counted dispatch debts, ~a logical dispatch debts, ~a logical order edges)\n"
                      (length files) (length units)
                      (vector-length (hashtable-keys parks)) (length park-got)
                      (length checkpoint-got)
                      (length checkpoint-value-got)
                      (length dispatch-got) (length logical-dispatch-got)
                      (length logical-edges))
              (exit 0)))))))))

(main (cdr (command-line)))
