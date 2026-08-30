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

(define scope-roots '("host/chez" "host/chez/java"))
(define allowlist-file "host/chez/park-lock-allowlist.txt")
(define debt-file "host/chez/park-lock-known-debt.txt")
(define issue-prefix "issue=chucklehead-dev/jolt-aspect-packs#")

;; The two switch points. Every park in the runtime ends at one of them, and each
;; one must call the assertion — checked below, because a check nobody calls is
;; indistinguishable from a check that passes.
(define switch-points '(jolt-fiber-to-scheduler! jolt-sm-park!))
(define assertion 'jolt-locks-assert-none!)

;; A function on this list may reach a switch point without making its callers
;; parkers only while it directly asserts that no counted lock is held before
;; every direct call that can park.
;; This is deliberately a one-name escape hatch, not an annotation mechanism:
;; deleting or moving the assertion makes the teeth check fail closed.
(define guarded-park-boundaries '(jolt-publication-gate-wait!))

;; The closure's seeds: the switch points themselves and the two wrappers that
;; exist only to reach them.
(define park-seeds
  '(jolt-fiber-to-scheduler! jolt-sm-park! jolt-fiber-park! sa-fiber-yield))

;; Calling into code the lock did not write. `apply` is modeled explicitly below,
;; because its target appears in value position even though it is invoked.
(define dynamic-call '|procedure-valued-dispatch|)
(define trusted-dynamic-call '|trusted-procedure-valued-dispatch|)
(define local-recursive-call '|local-recursive-call|)

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
;;     documented decide-under-mutex protocol.
(define trusted-direct-dispatch-sites
  '((pw-byte-port-memo 2 (standard-output-port standard-error-port))
    (ldr-libs-update! 1 (lambda))
    (jolt-lock-wait 2 (lambda))))

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
      (walk-forms (cddr d) lexical-lock? manual-lock?
                  (append (formal-names (cdadr d)) bound) emit)
      (walk-forms (cddr d) lexical-lock? manual-lock? bound emit)))

(define (walk-case d lexical-lock? manual-lock? bound emit)
  ;; (case key ((datum …) expr …) … (else expr …)) — the datum lists are DATA
  (walk (cadr d) lexical-lock? manual-lock? bound emit)
  (let ((key-state (manual-state-after (cadr d) manual-lock?)))
    (for-each (lambda (cl) (when (pair? cl)
                             (walk-forms (cdr cl) lexical-lock? key-state bound emit)))
            (cddr d))))

(define (walk-cond d lexical-lock? manual-lock? bound emit)
  (let loop ((clauses (cdr d)) (fallthrough manual-lock?))
    (unless (null? clauses)
      (let ((cl (car clauses)))
       (when (pair? cl)
        ;; The clause list itself is not a procedure application. `=>` is the
        ;; exception: cond invokes the receiver value, so record one dynamic
        ;; dispatch in addition to walking its expressions.
        (let ((arrow (memq '=> cl)))
          (when (and arrow (pair? (cdr arrow)))
            (let ((receiver (cadr arrow)))
              (cond ((symbol? receiver)
                     (emit (resolve-operator receiver bound)
                           (or lexical-lock? (pair? manual-lock?)) #t))
                    (else (emit dynamic-call
                                (or lexical-lock? (pair? manual-lock?)) #t))))))
        (if (eq? (car cl) 'else)
            (walk-forms (filter (lambda (x) (not (eq? x '=>))) (cdr cl))
                        lexical-lock? fallthrough bound emit)
            (begin
              (walk (car cl) lexical-lock? fallthrough bound emit)
              (let ((test-state (manual-state-after (car cl) fallthrough)))
                (walk-forms (filter (lambda (x) (not (eq? x '=>))) (cdr cl))
                            lexical-lock? test-state bound emit)
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
            (let ((arrow (memq '=> cl)))
              (when (and arrow (pair? (cdr arrow)))
                (let ((receiver (cadr arrow)))
                  (emit (if (symbol? receiver)
                            (resolve-operator receiver bound)
                            dynamic-call)
                        (or lexical-lock? (pair? caught-state)) #t))))
            (walk-forms cl lexical-lock? caught-state
                        (if (symbol? (caadr d)) (cons (caadr d) bound) bound)
                        emit)))
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

(define (walk x lexical-lock? manual-lock? bound emit)
  (define in-lock? (or lexical-lock? (pair? manual-lock?)))
  (cond
    ((symbol? x) (emit x in-lock? #f))   ; a value position: (apply jolt-invoke …)
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
         ((lambda) (walk-lambda-body x lexical-lock? manual-lock? bound emit))
         ((case-lambda) (walk-case-lambda x lexical-lock? manual-lock? bound emit))
         ((define define-syntax) (walk-define x lexical-lock? manual-lock? bound emit))
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
          (when (pair? (cddr x))
            (walk-forms (cddr x) lexical-lock? manual-lock? bound emit)))
         (else
          (cond
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
                ;; `apply` invokes its first argument. Record every named target,
                ;; not only today's generic seeds. A computed target is opaque
                ;; procedure-valued dispatch and therefore fails closed.
                (emit (if (symbol? (cadr x))
                          (resolve-operator (cadr x) bound)
                          dynamic-call)
                      in-lock? #t)
                (emit head in-lock? #t))
               ((symbol? head)
                (emit (resolve-operator head bound) in-lock? #t))
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
;; (file name calls locked-calls raw-body).
;; calls is every operator-position symbol in the body (the call graph edge set),
;; and locked-calls is its subset inside a counted-lock region. Top-level forms
;; that are not definitions use a file-unique name so file-scope locks are read.

(define (unit-file u) (car u))
(define (unit-name u) (cadr u))
(define (unit-calls u) (caddr u))
(define (unit-locked u) (cadddr u))
(define (unit-body u) (car (cddddr u)))

(define (definition-name d)
  (and (pair? d) (eq? 'define (car d)) (pair? (cdr d))
       (if (pair? (cadr d)) (car (cadr d)) (cadr d))))

(define (collect-unit file name forms bound)
  (let ((calls '()) (locked '()))
    (walk-forms forms #f '() (trusted-bound name bound)
      (lambda (sym in-lock? operator?)
        (when operator? (set! calls (cons sym calls)))
        (when (and in-lock? operator?) (set! locked (cons sym locked)))))
    (list file name calls locked forms)))

(define (collect-file file)
  (let loop ((ds (read-datums file)) (acc '()))
    (cond
      ((null? ds) (reverse acc))
      (else
       (let* ((d (car ds))
              (nm (definition-name d)))
         (loop (cdr ds)
               (cons (if nm
                         (collect-unit file nm (cddr d)
                           (if (pair? (cadr d)) (formal-names (cdadr d)) '()))
                         (collect-unit file
                           (string->symbol (string-append file "::toplevel"))
                           (list d) '()))
                     acc)))))))

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
         ;; Unit call lists are stored in reverse source order.
         (good (list (mk 'jolt-publication-gate-wait!
                         '(jolt-fiber-to-scheduler! jolt-locks-assert-none!)
                         '((jolt-locks-assert-none! 'guard)
                           (jolt-fiber-to-scheduler! f)))
                     (mk 'synthetic-caller '(jolt-publication-gate-wait!)
                         '((jolt-publication-gate-wait! gate me)))))
         (deleted (list (mk 'jolt-publication-gate-wait!
                            '(jolt-fiber-to-scheduler!)
                            '((jolt-fiber-to-scheduler! f)))))
         (reordered (list (mk 'jolt-publication-gate-wait!
                              '(jolt-locks-assert-none! jolt-fiber-to-scheduler!)
                              '((jolt-fiber-to-scheduler! f)
                                (jolt-locks-assert-none! 'guard)))))
         (conditional (list (mk 'jolt-publication-gate-wait!
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
                      guard-arrow-safe trusted-only
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
         (has? 'jolt-lock-wait 'dispatch)
         (memq trusted-dynamic-call (unit-locked trusted-only))
         (not (memq dynamic-call (unit-locked trusted-only)))
         (memq dynamic-call (unit-locked trusted-plus-opaque))
         (not (has? 'manual-safe 'dispatch))
         (not (has? 'syntax-safe 'dispatch))
         (not (has? 'deferred-safe 'dispatch)))))

;; ---------------------------------------------------------------------------
;; issue-tagged dispatch debt
;; ---------------------------------------------------------------------------

(define (words s)
  (let ((n (string-length s)))
    (let loop ((i 0) (start #f) (out '()))
      (cond
        ((= i n)
         (reverse (if start (cons (substring s start i) out) out)))
        ((char-whitespace? (string-ref s i))
         (loop (+ i 1) #f
               (if start (cons (substring s start i) out) out)))
        (else (loop (+ i 1) (or start i) out))))))

(define (join-with-space xs)
  (if (null? xs) ""
      (let loop ((rest (cdr xs)) (out (car xs)))
        (if (null? rest) out
            (loop (cdr rest) (string-append out " " (car rest)))))))

(define (issue-token? s)
  (let ((lp (string-length issue-prefix)) (ls (string-length s)))
    (and (> ls lp)
         (string=? issue-prefix (substring s 0 lp))
         (for-all char-numeric? (string->list (substring s lp ls)))
         (let ((n (string->number (substring s lp ls))))
           (and n (integer? n) (> n 0))))))

;; Parsed debt: (key count issue raw). The exact key is the finding's first four
;; fields; count and issue are separate so a change cannot hide behind text.
(define (parse-debt-line line)
  (let ((ws (words line)))
    (and (= (length ws) 6)
         (string=? (list-ref ws 2) "dispatch")
         (let ((count (string->number (list-ref ws 4))))
           (and count (integer? count) (> count 0)
                (issue-token? (list-ref ws 5))
                (list (join-with-space (list-head ws 4)) count
                      (list-ref ws 5) line))))))

(define (read-data-lines path)
  (if (file-exists? path)
      (let ((p (open-input-file path)))
        (let loop ((out '()))
          (let ((line (get-line p)))
            (cond ((eof-object? line) (close-port p) (reverse out))
                  ((or (string=? line "")
                       (and (> (string-length line) 0)
                            (char=? #\# (string-ref line 0))))
                   (loop out))
                  (else (loop (cons line out)))))))
      '()))

;; -> (entries . errors), rejecting malformed rows and duplicate exact keys.
(define (validate-debt-lines lines)
  (let ((seen (make-hashtable string-hash string=?)))
    (let loop ((ls lines) (entries '()) (errors '()))
      (if (null? ls)
          (cons (reverse entries) (reverse errors))
          (let ((entry (parse-debt-line (car ls))))
            (cond
              ((not entry)
               (loop (cdr ls) entries
                     (cons (string-append "malformed debt entry: " (car ls)) errors)))
              ((hashtable-ref seen (car entry) #f)
               (loop (cdr ls) entries
                     (cons (string-append "duplicate debt key: " (car entry)) errors)))
              (else
               (hashtable-set! seen (car entry) #t)
               (loop (cdr ls) (cons entry entries) errors))))))))

(define (debt-problems got-lines validated)
  (let ((entries (car validated)) (errors (cdr validated))
        (by-key (make-hashtable string-hash string=?))
        (got-by-key (make-hashtable string-hash string=?)))
    (for-each (lambda (e) (hashtable-set! by-key (car e) e)) entries)
    (for-each (lambda (g) (hashtable-set! got-by-key (line-key g) g)) got-lines)
    (let ((problems errors))
      (for-each
        (lambda (g)
          (let* ((key (line-key g)) (entry (hashtable-ref by-key key #f)))
            (cond ((not entry)
                   (set! problems (cons (string-append "untagged new dispatch: " g) problems)))
                  ((> (line-count g) (cadr entry))
                   (set! problems
                     (cons (string-append "increased dispatch debt: " g " (was "
                                          (number->string (cadr entry)) ")") problems)))
                  ((< (line-count g) (cadr entry))
                   (set! problems
                     (cons (string-append "decreased/stale dispatch debt: " (cadddr entry)
                                          " -> " (number->string (line-count g))) problems))))))
        got-lines)
      (for-each
        (lambda (entry)
          (unless (hashtable-ref got-by-key (car entry) #f)
            (set! problems
              (cons (string-append "dropped/stale dispatch debt: " (cadddr entry)
                                   " -> 0") problems))))
        entries)
      (reverse problems))))

(define (debt-self-test)
  (let* ((g1 "synthetic f dispatch jolt= 1")
         (g2 "synthetic f dispatch jolt= 2")
         (good "synthetic f dispatch jolt= 1 issue=chucklehead-dev/jolt-aspect-packs#26")
         (higher "synthetic f dispatch jolt= 2 issue=chucklehead-dev/jolt-aspect-packs#26")
         (bad "synthetic f dispatch jolt= 1")
         (valid-good (validate-debt-lines (list good))))
    (and (null? (debt-problems (list g1) valid-good))
         (pair? (debt-problems (list g1) (validate-debt-lines '())))
         (pair? (debt-problems (list g2) valid-good))
         (pair? (debt-problems '() valid-good))
         (pair? (debt-problems (list g1) (validate-debt-lines (list higher))))
         (pair? (cdr (validate-debt-lines (list bad))))
         (pair? (cdr (validate-debt-lines (list good good)))))))

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

;; A line is "<file> <definition> <kind> <callee> <count>". The KEY is everything
;; but the count, so a site keeps its identity while its count moves.
(define (last-space l)
  (let loop ((i (- (string-length l) 1)))
    (cond ((< i 0) #f)
          ((char=? #\space (string-ref l i)) i)
          (else (loop (- i 1))))))

(define (line-key l)
  (let ((i (last-space l))) (if i (substring l 0 i) l)))

(define (line-count l)
  (let ((i (last-space l)))
    (if i (or (string->number (substring l (+ i 1) (string-length l))) 0) 0)))

;; "…/loader.ss ldr-begin-load! park ldr-wait-for-load! 1" -> the kind field
(define (line-kind l)
  (let loop ((i 0) (spaces 0) (start 0))
    (cond
      ((>= i (string-length l)) "")
      ((char=? #\space (string-ref l i))
       (cond ((= spaces 2) (substring l start i))
             (else (loop (+ i 1) (+ spaces 1) (+ i 1)))))
      (else (loop (+ i 1) spaces start)))))

(define (fix-hint l)
  (if (string=? "dispatch" (line-kind l))
      (string-append " — this region hands control to code the lock did not write,"
                     " which may park; move the call out of the region")
      (string-append " — commit under the lock and switch outside it"
                     " (jolt-lock-wait, host/chez/locks.ss)")))

(define (find-line key lines)
  (let loop ((ls lines))
    (cond ((null? ls) #f)
          ((string=? key (line-key (car ls))) (car ls))
          (else (loop (cdr ls))))))

(define (main args)
  (let* ((files (find-files))
         (units (let loop ((fs files) (acc '()) (errs '()))
                  (if (null? fs)
                      (cons acc (reverse errs))
                      (guard (e (#t (loop (cdr fs) acc
                                          (cons (car fs) errs))))
                        (loop (cdr fs) (append (collect-file (car fs)) acc) errs)))))
         (bad-reads (cdr units))
         (units (car units)))
    ;; A file that will not read is a HOLE, not something to skip past.
    (unless (null? bad-reads)
      (for-each (lambda (f) (printf "  UNREADABLE: ~a\n" f)) bad-reads)
      (printf "park/lock check: FAILED\n")
      (exit 1))
    (let* ((parks (build-parkers units))
           (dispatches (build-dispatchers units))
           (got (map finding->line (findings units parks dispatches)))
           (park-got (filter (lambda (g) (string=? "park" (line-kind g))) got))
           (dispatch-got (filter (lambda (g) (string=? "dispatch" (line-kind g))) got))
           (debt (validate-debt-lines (read-data-lines debt-file)))
           (missing (append (missing-switch-assertions units)
                            (bad-guarded-boundaries units parks)
                            (bad-trusted-callbacks units parks dispatches)
                            (bad-trusted-direct-dispatch-sites units)))
           (self-test-ok? (and (guarded-boundary-self-test)
                               (dispatch-self-test)
                               (debt-self-test)
                               (primitive-whitelist-self-test))))
      (cond
        ((and (pair? args) (string=? (car args) "--self-test"))
         (if (and self-test-ok? (null? missing))
             (begin
               (printf "park/lock checker self-test: PASS (guard/receiver, transitive dynamic-helper, manual/control/compound-expression/alias/apply mutations, primitive whitelist safe/unknown teeth, safe/deferred controls, call-site trusted callbacks, issue-tagged debt mutations)\n")
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
             (add! "  CHECKER SELF-TEST FAILED: park guard or dispatch/manual-lock mutation was not detected"))
           (for-each
             (lambda (m)
               (add! (string-append "  SWITCH POINT UNGUARDED: " (symbol->string (car m))
                                    " " (cdr m) " — the runtime half of the rule is"
                                    " gone (host/chez/locks.ss)")))
             missing)
           (for-each
             (lambda (p) (add! (string-append "  DEBT: " p)))
             (debt-problems dispatch-got debt))
           (for-each
             (lambda (g)
               (let ((w (find-line (line-key g) want)))
                 (cond
                   ((not w)
                    (add! (string-append "  NEW site: " g (fix-hint g))))
                   ((> (line-count g) (line-count w))
                    (add! (string-append "  MORE of them: " g " (was "
                                         (number->string (line-count w)) ")"
                                         (fix-hint g)))))))
             park-got)
           (for-each
             (lambda (w)
               (let ((g (find-line (line-key w) park-got)))
                 (when (< (if g (line-count g) 0) (line-count w))
                   (add! (string-append "  STALE allowlist entry: " w " -> "
                                        (number->string (if g (line-count g) 0))
                                        " — rerun with --regen")))))
             want)
           (cond
             ((pair? problems)
              (for-each (lambda (p) (printf "~a\n" p)) (reverse problems))
              (printf "park/lock check: FAILED\n")
              (exit 1))
             (else
              (printf "park/lock check: passed (~a files, ~a definitions, ~a can park, ~a park allowlist, ~a issue-tagged dispatch debts)\n"
                      (length files) (length units)
                      (vector-length (hashtable-keys parks)) (length park-got)
                      (length dispatch-got))
              (exit 0)))))))))

(main (cdr (command-line)))
