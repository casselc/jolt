;; Live protocol/method/type index; no compiler or timing workload required.
;; Run from repository root: make protoindex
(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0)
(define fails 0)
(define (ok label pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" label)))

;; Independent pre-index resolver from 3dc3a471. Keep its original registry
;; lookups: comparing two routes through the new helper would be vacuous.
(define (original-resolve proto-name method-name obj)
  (cond
    ((and (jrec? obj)
          (let* ((desc (jrec-desc obj))
                 (f (find-protocol-method-desc desc proto-name method-name)))
            (or f (find-protocol-method (jrdesc-tag desc) proto-name method-name)))))
    ((reified-methods obj)
     => (lambda (rm)
          (or (hashtable-ref rm method-name #f)
              (let loop ((tags (value-host-tags obj)))
                (cond ((null? tags) (protocol-miss-throw proto-name method-name obj))
                      ((find-protocol-method (car tags) proto-name method-name))
                      (else (loop (cdr tags))))))))
    (else
     (let loop ((tags (value-host-tags obj)))
       (cond ((null? tags) (protocol-miss-throw proto-name method-name obj))
             ((find-protocol-method (car tags) proto-name method-name))
             (else (loop (cdr tags))))))))

(define (resolution resolver proto method obj)
  (guard (e (#t (let ((v (jolt-unwrap-throw e)))
                 (if (jolt-ex-info-record? v)
                     (list 'miss (jolt-ex-info-record-class-name v)
                           (jolt-ex-info-record-message v))
                     (raise e)))))
    (resolver proto method obj)))
(define (same-resolution label proto method obj)
  (let ((expected (resolution original-resolve proto method obj))
        (actual (resolution protocol-resolve proto method obj)))
    (ok label (if (procedure? expected) (eq? expected actual)
                  (equal? expected actual)))))
(define (answer id) (lambda args id))
(define default-fn (answer 'default))
(define ancestor-fn (answer 'ancestor))
(define specific-fn (answer 'specific))
(define replacement-fn (answer 'replacement))
(define p "pmi.test/Dispatch")

;; Real classes, ancestors, aliases, numeric boundaries and default/miss paths.
(for-each
  (lambda (tag) (register-protocol-method tag p "m" ancestor-fn))
  '("CharSequence" "Map" "Collection" "Number"))
(register-protocol-method "Object" p "m" default-fn)
(register-protocol-method "Long" p "m" specific-fn)
(for-each
  (lambda (obj)
    (same-resolution "builtin ordered host tags" p "m" obj)
    (same-resolution "missing method retains exact exception" p "absent" obj))
  (list "text" #t #\x jolt-nil 1 (greatest-fixnum)
        (- (expt 2 63) 1) (expt 2 63) (- (- (expt 2 63)) 1) 3/2 1.5
        (keyword #f "key") (jolt-symbol #f "sym")
        empty-pmap empty-pmap-hash (jolt-vector 1) (jolt-list 1)))
(ok "String selects CharSequence ancestor"
    (eq? ancestor-fn (protocol-resolve p "m" "text")))
(ok "map selects Map ancestor"
    (eq? ancestor-fn (protocol-resolve p "m" empty-pmap)))
(ok "Long selects concrete before Number"
    (eq? specific-fn (protocol-resolve p "m" 1)))
(ok "Boolean selects Object default"
    (eq? default-fn (protocol-resolve p "m" #t)))
(ok "nil does not inherit Object"
    (pair? (resolution protocol-resolve p "m" jolt-nil)))
(register-protocol-method "nil" p "m" specific-fn)
(same-resolution "nil extension after miss" p "m" jolt-nil)

;; A miss and a hit are both live: no cached absence or chosen implementation.
(same-resolution "fresh protocol miss" "pmi.test/Fresh" "m" "text")
(register-protocol-method "String" "pmi.test/Fresh" "m" specific-fn)
(ok "fresh protocol becomes visible"
    (eq? specific-fn (protocol-resolve "pmi.test/Fresh" "m" "text")))
(register-protocol-method "String" p "m" specific-fn)
(ok "new concrete extension outranks existing ancestor"
    (eq? specific-fn (protocol-resolve p "m" "text")))
(register-protocol-method "String" p "m" replacement-fn)
(ok "reextension replaces warmed concrete method"
    (eq? replacement-fn (protocol-resolve p "m" "text")))
(register-protocol-method "Object" p "m" replacement-fn)
(ok "default replacement is live"
    (eq? replacement-fn (protocol-resolve p "m" #t)))
(register-protocol-method "String" "pmi.other/Dispatch" "m" ancestor-fn)
(ok "same method in distinct qualified protocols remains separate"
    (and (eq? replacement-fn (protocol-resolve p "m" "text"))
         (eq? ancestor-fn (protocol-resolve "pmi.other/Dispatch" "m" "text"))))

;; Actual library tag callback, not a value-host-tags replacement. Its first
;; invocation registers a previously absent protocol/method before returning tags.
(define callback-object (vector 'callback-object))
(define callback-count 0)
((var-deref "clojure.core" "__register-class!")
 (lambda (x) (eq? x callback-object))
 (lambda (x) "pmi.Callback")
 (lambda (x)
   (set! callback-count (+ callback-count 1))
   (register-protocol-method "pmi.Callback" "pmi.callback/New" "new-m" specific-fn)
   (jolt-vector "pmi.Callback" "Object")))
(ok "callback's protocol/method starts absent"
    (not (protocol-method-types "pmi.callback/New" "new-m")))
(ok "tag callback registration precedes method table lookup"
    (eq? specific-fn (protocol-resolve "pmi.callback/New" "new-m" callback-object)))
(ok "tag callback ran exactly once" (= callback-count 1))
(same-resolution "callback result matches original resolver"
                 "pmi.callback/New" "new-m" callback-object)

;; Exercise removal with a private host tag, without disturbing runtime types.
(define removal-object (vector 'removal-object))
((var-deref "clojure.core" "__register-class!")
 (lambda (x) (eq? x removal-object))
 (lambda (x) "pmi.Remove")
 (lambda (x) (jolt-vector "pmi.Remove" "Object")))
(register-protocol-method "pmi.Remove" p "m" specific-fn)
(define removal-leaf (protocol-method-types p "m"))
(ok "removal fixture really selects own method"
    (eq? specific-fn (protocol-resolve p "m" removal-object)))
(forget-type-methods! "pmi.Remove")
(ok "forget removes the reverse entry"
    (not (hashtable-ref removal-leaf "pmi.Remove" #f)))
(same-resolution "forgotten type falls back identically" p "m" removal-object)
(register-protocol-method "pmi.Remove" p "m" specific-fn)
(ok "reregistration retains live leaf identity"
    (and (eq? removal-leaf (protocol-method-types p "m"))
         (eq? specific-fn (protocol-resolve p "m" removal-object))))
(prune-type-registry! (lambda (tag) (not (string=? tag "pmi.Remove"))))
(ok "prune removes reverse entry independently"
    (not (hashtable-ref removal-leaf "pmi.Remove" #f)))
(same-resolution "pruned type falls back identically" p "m" removal-object)
(same-resolution "prune preserves retained type" p "m" "text")
(register-protocol-method "pmi.Remove" p "m" replacement-fn)
(ok "same names after prune use current registration"
    (eq? replacement-fn (protocol-resolve p "m" removal-object)))
;; A keep? callback may observe deletions made by earlier callbacks. Do not
;; defer reverse deletion to a later sweep: the old tree has removed them now.
(define prune-object (vector "pmi.PruneA"))
((var-deref "clojure.core" "__register-class!")
 (lambda (x) (eq? x prune-object))
 (lambda (x) (vector-ref x 0))
 (lambda (x) (jolt-vector (vector-ref x 0) "Object")))
(define prune-tags '("pmi.PruneA" "pmi.PruneB" "pmi.PruneC"))
(for-each (lambda (tag) (register-protocol-method tag p "m" specific-fn)) prune-tags)
(define last-rejected #f)
(define prune-observations 0)
(define prune-visible? #t)
(prune-type-registry!
  (lambda (tag)
    (when last-rejected
      (set! prune-observations (+ prune-observations 1))
      (vector-set! prune-object 0 last-rejected)
      (unless (and (eq? replacement-fn (protocol-resolve p "m" prune-object))
                   (eq? (original-resolve p "m" prune-object)
                        (protocol-resolve p "m" prune-object)))
        (set! prune-visible? #f)))
    (if (member tag prune-tags) (begin (set! last-rejected tag) #f) #t)))
(ok "prune observation fixture is nonvacuous" (>= prune-observations 2))
(ok "later keep? callbacks observe earlier deletions" prune-visible?)
;; keep? must not be called under rec-tbl-mu. try-acquire avoids hanging on a
;; callback-under-lock mutant and checks the actual mutex, not a comment.
(define keep-outside-lock? #t)
(prune-type-registry!
  (lambda (tag)
    (if (mutex-acquire rec-tbl-mu #f) (mutex-release rec-tbl-mu)
        (set! keep-outside-lock? #f))
    #t))
(ok "prune predicate runs outside registry mutex" keep-outside-lock?)

;; Marker-only protocols remain type metadata, never callable index entries.
(define marker-name (jolt-symbol #f "PmiMarker"))
(define marker-ctor (make-deftype-ctor marker-name (jolt-vector)))
(register-inline-protocol! "PmiMarker" "pmi.test/Marker")
(ok "marker protocol still satisfies by its type"
    (type-satisfies? (jrec-tag (marker-ctor)) "pmi.test/Marker"))
(ok "inline marker is not a method"
    (not (protocol-method-types "pmi.test/Marker" inline-mark)))
(mark-extend! (jrec-tag (marker-ctor)) "pmi.test/Marker")
(ok "extend marker is not a method"
    (not (protocol-method-types "pmi.test/Marker" extend-mark)))
(same-resolution "marker-only protocol has unchanged miss"
                 "pmi.test/Marker" "missing" (marker-ctor))

;; Preserve descriptor and instance-local paths, including old descriptors.
(define record-name (jolt-symbol #f "PmiRecord"))
(define record-ctor (make-deftype-ctor record-name (jolt-vector)))
(register-record-type! record-name)
(register-inline-protocol! "PmiRecord" p)
(register-inline-method "PmiRecord" p "m" specific-fn)
(define old-record (record-ctor))
(ok "record has a populated descriptor implementation"
    (eq? specific-fn (find-protocol-method-desc (jrec-desc old-record) p "m")))
(same-resolution "record own method wins" p "m" old-record)
(define new-record-ctor (make-deftype-ctor record-name (jolt-vector)))
(register-record-type! record-name)
(ok "redefinition invalidates old descriptor" (not (jrdesc-ptable (jrec-desc old-record))))
(same-resolution "old record after redef uses same fallback" p "m" old-record)
(register-inline-method "PmiRecord" p "m" replacement-fn)
(same-resolution "old record follows new registration" p "m" old-record)
(same-resolution "new record keeps descriptor path" p "m" (new-record-ctor))
(define reify-methods (make-hashtable string-hash string=?))
(hashtable-set! reify-methods "m" specific-fn)
(define own-reify (make-jreify reify-methods (list p) #f))
(define fallback-reify (make-jreify (make-hashtable string-hash string=?) '() #f))
(same-resolution "reify local method wins over Object" p "m" own-reify)
(same-resolution "reify fallback uses current Object method" p "m" fallback-reify)

;; Mechanism control: builtin host dispatch no longer walks the original tree.
;; Assert the trap is live first; leave the original oracle uninstrumented above.
(let ((saved find-protocol-method) (trap (list 'original-tree-called)))
  (dynamic-wind
    (lambda () (set! find-protocol-method (lambda args (raise trap))))
    (lambda ()
      (ok "tree trap is nonvacuous"
          (guard (e (#t (eq? e trap)))
            (find-protocol-method "String" p "m") #f))
      (ok "host lookup bypasses nested type tree"
          (guard (e (#t #f))
            (eq? replacement-fn (protocol-resolve p "m" "text")))))
    (lambda () (set! find-protocol-method saved))))

;; Concurrent first creation must not lose sibling methods/protocols. All
;; readers below run after a condition-variable completion handoff, not sleeps.
(define sync-mu (make-mutex))
(define sync-cv (make-condition))
(define ready 0)
(define released? #f)
(define finished 0)
(define thread-errors '())
(define (wait-for pred)
  (let ((deadline (ms->deadline 5000)))
    (with-mutex sync-mu
      (let loop ()
        (cond ((pred) #t)
              ((condition-wait sync-cv sync-mu deadline) (loop))
              (else (pred)))))))
(define writers 4)
(do ((i 0 (+ i 1))) ((= i writers))
  (let ((i i))
    (fork-thread
      (lambda ()
        (guard (e (#t (with-mutex sync-mu (set! thread-errors (cons e thread-errors)))))
          (with-mutex sync-mu
            (set! ready (+ ready 1)) (condition-broadcast sync-cv)
            (let wait () (unless released? (condition-wait sync-cv sync-mu) (wait))))
          (do ((n 0 (+ n 1))) ((= n 64))
            (let ((proto (string-append "pmi.concurrent/P" (number->string n)))
                  (method (string-append "m" (number->string i))))
              (register-protocol-method "String" proto method specific-fn)
              (register-protocol-method "String" proto method replacement-fn))))
        (with-mutex sync-mu
          (set! finished (+ finished 1)) (condition-broadcast sync-cv))))))
(ok "all registrars reached start barrier" (wait-for (lambda () (= ready writers))))
(with-mutex sync-mu (set! released? #t) (condition-broadcast sync-cv))
(let ((done? (wait-for (lambda () (= finished writers)))))
  (ok "all registrars completed" done?)
  (unless done? (exit 1)))
(ok "no registrar raised" (null? thread-errors))
(define publication-ok? #t)
(do ((n 0 (+ n 1))) ((= n 64))
  (do ((i 0 (+ i 1))) ((= i writers))
    (let* ((proto (string-append "pmi.concurrent/P" (number->string n)))
           (method (string-append "m" (number->string i)))
           (actual (resolution protocol-resolve proto method "text")))
      (unless (and (eq? replacement-fn actual)
                   (eq? (original-resolve proto method "text") actual))
        (set! publication-ok? #f)))))
(ok "every synchronized registration/reextension is visible" publication-ok?)

(printf "protocol-method-index: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
