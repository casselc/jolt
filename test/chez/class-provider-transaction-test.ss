;; class-provider TRANSACTIONAL REGISTRATION gate.
;;
;; Covers staging and rollback for every dedicated Clojure-visible class-provider
;; host-registration hook. Ordinary namespace definitions and application side
;; effects, including type/protocol definition forms, are outside this bounded
;; transaction. Host retry-on-miss dispatch remains deliberately unwired in this
;; slice.
;;
;;   CHEZ=/path/to/chez make providertransactions

(import (chezscheme))
(load "host/chez/run-gate-harness.ss")
(load "host/chez/loader.ss")
(set-source-roots!
  (cons "test/chez/class-provider-transactions/src" ldr-install-roots))

;; --- invocation, capture, and bounded wait helpers --------------------------
(define (t-call ns name . args)
  (apply jolt-invoke (var-deref ns name) args))

(define (t-capture thunk)
  (guard (e (#t (vector 'error e)))
    (vector 'ok (thunk))))
(define (t-ok? result) (eq? (vector-ref result 0) 'ok))
(define (t-value result) (vector-ref result 1))
(define t-type-kw (keyword #f "type"))
(define t-cross-thread
  (keyword "jolt.deps" "class-provider-cross-thread-registration"))
(define (t-condition-type e)
  (let ((v (jolt-unwrap-throw e)))
    (if (and (jolt-ex-info-record? v)
             (pmap? (jolt-ex-info-record-data v)))
        (pmap-get (jolt-ex-info-record-data v) t-type-kw jolt-nil)
        jolt-nil)))
(define (t-captured-error-type result)
  (if (t-ok? result)
      'no-error
      (t-condition-type (t-value result))))

(define (t-make-latch)
  (vector #f (make-mutex) (make-condition)))
(define (t-open-latch! latch)
  (with-mutex (vector-ref latch 1)
    (vector-set! latch 0 #t)
    (condition-broadcast (vector-ref latch 2))))
(define (t-await-latch-raw! latch)
  (with-mutex (vector-ref latch 1)
    (let ((deadline (ms->deadline 5000)))
      (let loop ()
        (cond
          ((vector-ref latch 0) #t)
          ((condition-wait
             (vector-ref latch 2) (vector-ref latch 1) deadline)
           (loop))
          (else (vector-ref latch 0)))))))
(define (t-await-latch! label latch)
  (let ((ok (t-await-latch-raw! latch)))
    (gate-check label ok #t)
    ok))
(define (t-await-predicate! label pred)
  (let loop ((remaining 200000))
    (cond
      ((pred) (gate-check label #t #t) #t)
      ((fx=? remaining 0) (gate-check label #f #t) #f)
      (else
        (thread-yield!)
        (loop (fx- remaining 1))))))

;; --- unique names and raw registry probes -----------------------------------
(define t-missing (list 'provider-transaction-missing))
(define (t-name stem suffix)
  (string-append "tx." stem "." suffix))
(define (t-provider-class stem) (t-name stem "ProviderClass"))
(define (t-host-class stem) (t-name stem "HostClass"))
(define (t-hierarchy-simple stem)
  (string-append "Tx" stem "HierarchyClass"))
(define (t-hierarchy-class stem)
  (string-append "tx.hierarchy." (t-hierarchy-simple stem)))
(define (t-tag stem) (string-append "tx/" stem))

(define (t-static-member stem)
  (let ((h (hashtable-ref class-statics-tbl (t-host-class stem) #f)))
    (if h (hashtable-ref h "answer" t-missing) t-missing)))
(define (t-ctor stem)
  (hashtable-ref class-ctors-tbl (t-host-class stem) t-missing))
(define (t-tagged-method stem)
  (let ((h
          (hashtable-ref
            tagged-methods-tbl
            (tag->method-key (t-tag stem))
            #f)))
    (if h (hashtable-ref h "ping" t-missing) t-missing)))
(define (t-mutable-value stem)
  (let ((cell
          (mutable-static-cell (t-host-class stem) "mutableAnswer" #f)))
    (if cell (vector-ref cell 0) t-missing)))
(define (t-direct-supers stem)
  (hashtable-ref jvm-class-parents (t-hierarchy-class stem) t-missing))

;; Count every mutable registry covered by the transaction. The hierarchy
;; caches are derived and intentionally excluded: rollback invalidates them.
(define (t-world-counts)
  (vector
    (hashtable-size class-providers-tbl)
    (class-provider-generation)
    (hashtable-size class-statics-tbl)
    (hashtable-size class-ctors-tbl)
    (hashtable-size mutable-statics-tbl)
    (hashtable-size tagged-methods-tbl)
    (hashtable-size jvm-class-parents)
    (length user-instance-checks)
    (length jolt-eq-arms)
    (length jolt-hash-arms)
    (length str-render-registry)
    (length jolt-pr-str-arms)
    (length jolt-pr-readable-arms)
    (length jolt-compare-arms)
    (length jolt-class-arms)
    (length jt-user-value-tags-arms)))

(define (t-world-deltas after before)
  (let* ((n (vector-length after))
         (result (make-vector n 0)))
    (let loop ((i 0))
      (when (fx<? i n)
        (vector-set!
          result i
          (- (vector-ref after i) (vector-ref before i)))
        (loop (fx+ i 1))))
    result))

(define (t-unique-world-absent? stem)
  (and
    (jolt-nil? (class-provider-for (t-provider-class stem)))
    (eq? (t-static-member stem) t-missing)
    (eq? (t-ctor stem) t-missing)
    (eq? (t-tagged-method stem) t-missing)
    (eq? (t-mutable-value stem) t-missing)
    (eq? (t-direct-supers stem) t-missing)))

;; Exercise every Clojure-visible provider registration hook. Predicates return
;; false for ordinary values, so committed test arms cannot perturb later cases.
(define (t-register-entire-world! stem)
  (let ((false1 (lambda (_) #f))
        (false2 (lambda (_ __) #f))
        (zero1 (lambda (_) 0))
        (zero2 (lambda (_ __) 0))
        (empty1 (lambda (_) ""))
        (host (t-host-class stem)))
    (t-call
      "jolt.host" "register-class-providers!"
      (jolt-hash-map
        (t-provider-class stem)
        (t-name stem "provider")))
    (t-call
      "clojure.core" "__register-class-ctor!"
      host
      (lambda args stem))
    (t-call
      "clojure.core" "__register-class-statics!"
      host
      (jolt-hash-map "answer" (lambda _ stem)))
    (t-call
      "clojure.core" "__register-class-methods!"
      (t-tag stem)
      (jolt-hash-map "ping" (lambda args stem)))
    (t-call
      "jolt.host" "register-class-supers!"
      (t-hierarchy-class stem)
      (jolt-vector "java.lang.Object"))
    (t-call
      "jolt.host" "set-static-field!"
      host "mutableAnswer" stem)
    (t-call "clojure.core" "__register-instance-check!" (lambda (_ __) jolt-nil))
    (t-call "clojure.core" "__register-eq!" false2 false2)
    (t-call "clojure.core" "__register-hash!" false1 zero1)
    (t-call "clojure.core" "__register-str!" false1 empty1)
    (t-call "clojure.core" "__register-pr!" false1 empty1)
    (t-call "clojure.core" "__register-compare!" false2 zero2)
    (t-call
      "clojure.core" "__register-class!"
      false1
      (lambda (_) host)
      (lambda (_) (jolt-vector host "java.lang.Object")))))

;; --- successful stage: invisible during load, atomic after return -----------
(class-provider-reset-many! '())
(let* ((stem "SuccessA7")
       (before (t-world-counts))
       (events '()))
  ;; Prime both lazily derived hierarchy indices with a miss.
  (gate-check "success fixture initially unknown to hierarchy"
    (jch-known? (t-hierarchy-class stem)) #f)
  (gate-check "success simple-name cache initially misses"
    (jch-fqn-of-simple (t-hierarchy-simple stem))
    (t-hierarchy-simple stem))
  (gate-check "successful provider transaction returns retry permission"
    (class-provider-load-provider-with!
      (t-name stem "provider")
      (lambda (_)
        (t-register-entire-world! stem)
        (class-provider-stage-operation!
          (lambda () (set! events (append events '(first)))))
        (class-provider-stage-operation!
          (lambda () (set! events (append events '(second)))))
        (gate-check "staged hooks are invisible during namespace evaluation"
          (t-unique-world-absent? stem) #t)
        (gate-check "staging changes no covered registry count"
          (t-world-counts) before)))
    #t)
  (gate-check "successful commit publishes provider mapping"
    (class-provider-for (t-provider-class stem))
    (t-name stem "provider"))
  (gate-check "successful commit publishes static"
    (procedure? (t-static-member stem)) #t)
  (gate-check "successful commit publishes constructor"
    (procedure? (t-ctor stem)) #t)
  (gate-check "successful commit publishes tagged method"
    (procedure? (t-tagged-method stem)) #t)
  (gate-check "successful commit publishes mutable static"
    (t-mutable-value stem) stem)
  (gate-check "successful commit publishes hierarchy row"
    (t-direct-supers stem) '("java.lang.Object"))
  (gate-check "successful hierarchy commit invalidates known-class miss"
    (jch-known? (t-hierarchy-class stem)) #t)
  (gate-check "successful hierarchy commit invalidates simple-name miss"
    (jch-fqn-of-simple (t-hierarchy-simple stem))
    (t-hierarchy-class stem))
  (gate-check "staged operations commit in source order"
    events '(first second))
  (gate-check "successful transaction marks provider loaded"
    (class-provider-provider-status (t-name stem "provider")) 'loaded)
  (gate-check "successful transaction publishes every covered hook exactly once"
    (t-world-deltas (t-world-counts) before)
    (vector 1 1 2 1 1 1 1 1 1 1 1 1 1 1 1 1)))

;; --- source exception: discard the unopened stage ---------------------------
(class-provider-reset-many! '())
(let* ((stem "SourceFailureB8")
       (before (t-world-counts))
       (marker (list 'provider-source-failure))
       (result
         (t-capture
           (lambda ()
             (class-provider-load-provider-with!
               (t-name stem "provider")
               (lambda (_)
                 (t-register-entire-world! stem)
                 (raise marker)))))))
  (gate-check "source failure propagates exact error"
    (and (not (t-ok? result)) (eq? (t-value result) marker)) #t)
  (gate-check "source failure publishes no unique registration"
    (t-unique-world-absent? stem) #t)
  (gate-check "source failure leaves every covered registry unchanged"
    (t-world-counts) before)
  (gate-check "source failure leaves failed provider attempt"
    (class-provider-provider-status (t-name stem "provider")) 'failed)
  (gate-check "source failure clears evaluator owner"
    (class-provider-evaluator-owner) #f))

;; --- commit exception: restore every published prefix -----------------------
(class-provider-reset-many! '())
(let* ((stem "CommitFailureC9")
       (marker (list 'provider-commit-failure))
       (old-ctor (lambda args 'old-ctor))
       (old-static (lambda args 'old-static))
       (old-tagged (lambda args 'old-tagged))
       (old-mutable (list 'old-mutable))
       (old-supers '("java.lang.Number"))
       (host (t-host-class stem)))
  ;; Seed representative existing values. The staged hooks overwrite each one
  ;; before the final commit operation raises; rollback must restore identity
  ;; and value, not merely aggregate table sizes.
  (register-class-ctor! host old-ctor)
  (register-class-statics! host (list (cons "answer" old-static)))
  (register-tagged-methods!
    (t-tag stem) (list (cons "ping" old-tagged)))
  (vector-set! (mutable-static-cell host "mutableAnswer" #t) 0 old-mutable)
  (jch-register-supers! (t-hierarchy-class stem) old-supers)
  (let ((before (t-world-counts))
        (short-table (hashtable-ref class-statics-tbl "Collections" #f))
        (fqn-table
          (hashtable-ref class-statics-tbl "java.util.Collections" #f)))
    (gate-check "rollback control starts with shared core static alias"
      (and short-table fqn-table (eq? short-table fqn-table)) #t)
    (gate-check "rollback fixture starts with seeded hierarchy"
      (t-direct-supers stem) old-supers)
    (let ((result
            (t-capture
              (lambda ()
                (class-provider-load-provider-with!
                  (t-name stem "provider")
                  (lambda (_)
                    (t-register-entire-world! stem)
                    ;; Runs after every public-hook operation and forces rollback
                    ;; of the provider-map prefix plus every covered registry.
                    (class-provider-stage-operation!
                      (lambda () (raise marker)))))))))
      (gate-check "commit failure propagates exact error"
        (and (not (t-ok? result)) (eq? (t-value result) marker)) #t))
    (gate-check "commit rollback removes pending provider mapping"
      (jolt-nil? (class-provider-for (t-provider-class stem))) #t)
    (gate-check "commit rollback restores constructor identity"
      (t-ctor stem) old-ctor)
    (gate-check "commit rollback restores static identity"
      (t-static-member stem) old-static)
    (gate-check "commit rollback restores tagged-method identity"
      (t-tagged-method stem) old-tagged)
    (gate-check "commit rollback restores mutable static value"
      (t-mutable-value stem) old-mutable)
    (gate-check "commit rollback restores hierarchy value"
      (t-direct-supers stem) old-supers)
    (gate-check "commit rollback restores every covered registry count"
      (t-world-counts) before)
    (gate-check "rollback preserves shared short/FQN inner-table identity"
      (eq?
        (hashtable-ref class-statics-tbl "Collections" #f)
        (hashtable-ref class-statics-tbl "java.util.Collections" #f))
      #t)
    (gate-check "rollback invalidates hierarchy caches to restored graph"
      (jch-known? (t-hierarchy-class stem)) #t)
    (gate-check "rollback restores seeded simple-name mapping"
      (jch-fqn-of-simple (t-hierarchy-simple stem))
      (t-hierarchy-class stem))
    (gate-check "commit failure leaves failed provider attempt"
      (class-provider-provider-status (t-name stem "provider")) 'failed)
    (gate-check "later independent retry can publish cleanly"
      (class-provider-load-provider-with!
        (t-name stem "provider")
        (lambda (_)
          (t-call
            "clojure.core" "__register-class-ctor!"
            (t-host-class stem)
            (lambda args 'retry))))
      #t)
    (gate-check "clean retry publishes its constructor"
      (and (procedure? (t-ctor stem))
           (not (eq? (t-ctor stem) old-ctor)))
      #t)
    (gate-check "clean retry marks provider loaded"
      (class-provider-provider-status (t-name stem "provider")) 'loaded)))

;; A caller that joins the exact attempt before a commit-time failure must
;; observe that same error object. Only a later independent caller may retry.
(class-provider-reset-many! '())
(let ((provider "tx.CommitWaiter.provider")
      (entered (t-make-latch))
      (release (t-make-latch))
      (done-owner (t-make-latch))
      (done-waiter (t-make-latch))
      (owner-result (box #f))
      (waiter-result (box #f))
      (marker (list 'provider-commit-waiter-failure)))
  (fork-thread
    (lambda ()
      (set-box!
        owner-result
        (t-capture
          (lambda ()
            (class-provider-load-provider-with!
              provider
              (lambda (_)
                (t-call
                  "clojure.core" "__register-class-ctor!"
                  "tx.CommitWaiter.Host"
                  (lambda args 'must-not-leak))
                (class-provider-stage-operation!
                  (lambda () (raise marker)))
                (t-open-latch! entered)
                (t-await-latch-raw! release))))))
      (t-open-latch! done-owner)))
  (t-await-latch! "commit-failure owner enters source" entered)
  (fork-thread
    (lambda ()
      (set-box!
        waiter-result
        (t-capture
          (lambda ()
            (class-provider-load-provider-with!
              provider
              (lambda (_)
                (error 'commit-waiter "waiter loader must not run"))))))
      (t-open-latch! done-waiter)))
  (t-await-predicate!
    "commit-failure waiter joins exact attempt"
    (lambda () (> (class-provider-provider-waiters provider) 0)))
  (t-open-latch! release)
  (t-await-latch! "commit-failure owner completes" done-owner)
  (t-await-latch! "commit-failure waiter completes" done-waiter)
  (gate-check "commit-failure owner receives exact error"
    (and (not (t-ok? (unbox owner-result)))
         (eq? (t-value (unbox owner-result)) marker))
    #t)
  (gate-check "commit-failure waiter receives same exact error"
    (and (not (t-ok? (unbox waiter-result)))
         (eq? (t-value (unbox waiter-result)) marker))
    #t)
  (gate-check "commit-failure waiter sees no constructor prefix"
    (hashtable-ref class-ctors-tbl "tx.CommitWaiter.Host" #f) #f)
  (gate-check "commit-failure attempt remains failed"
    (class-provider-provider-status provider) 'failed)
  (gate-check "commit-failure waiters drain"
    (class-provider-provider-waiters provider) 0)
  (gate-check "commit-failure graph clears evaluator owner"
    (class-provider-evaluator-owner) #f))

;; A caught conflict in a staged provider-map batch must leave no pending prefix.
(class-provider-reset-many!
  (list
    (cons "tx.ConflictD1.Existing" "tx.conflict.original")))
(let ((caught #f))
  (gate-check "provider can catch a staged mapping conflict and continue"
    (class-provider-load-provider-with!
      "tx.ConflictD1.provider"
      (lambda (_)
        (guard (e (#t (set! caught e) jolt-nil))
          (t-call
            "jolt.host" "register-class-providers!"
            (jolt-hash-map
              "tx.ConflictD1.NewPrefix" "tx.conflict.new"
              "tx.ConflictD1.Existing" "tx.conflict.other")))
        (t-call
          "clojure.core" "__register-class-ctor!"
          "tx.ConflictD1.Host"
          (lambda args 'ok))))
    #t)
  (gate-check "staged mapping conflict was observed" (and caught #t) #t)
  (gate-check "caught staged conflict leaves no pending new prefix"
    (jolt-nil? (class-provider-for "tx.ConflictD1.NewPrefix")) #t)
  (gate-check "caught staged conflict preserves existing mapping"
    (class-provider-for "tx.ConflictD1.Existing")
    "tx.conflict.original")
  (gate-check "other staged registrations still commit after caught conflict"
    (procedure?
      (hashtable-ref class-ctors-tbl "tx.ConflictD1.Host" #f))
    #t))

;; --- nested provider: inner success survives outer source failure -----------
(class-provider-reset-many! '())
(let ((outer-marker (list 'outer-provider-source-failure)))
  (let ((outer
          (t-capture
            (lambda ()
              (class-provider-load-provider-with!
                "tx.NestedOuter.provider"
                (lambda (_)
                  (t-call
                    "jolt.host" "register-class-providers!"
                    (jolt-hash-map
                      "tx.NestedOuter.Class" "tx.NestedOuter.provider"))
                  (t-call
                    "clojure.core" "__register-class-ctor!"
                    "tx.NestedOuter.Host"
                    (lambda args 'outer))
                  (class-provider-load-provider-with!
                    "tx.NestedInner.provider"
                    (lambda (_)
                      (t-call
                        "jolt.host" "register-class-providers!"
                        (jolt-hash-map
                          "tx.NestedInner.Class" "tx.NestedInner.provider"))
                      (t-call
                        "clojure.core" "__register-class-ctor!"
                        "tx.NestedInner.Host"
                        (lambda args 'inner))))
                  (gate-check "nested inner mapping publishes inside outer load"
                    (class-provider-for "tx.NestedInner.Class")
                    "tx.NestedInner.provider")
                  (gate-check "nested outer mapping remains staged"
                    (jolt-nil?
                      (class-provider-for "tx.NestedOuter.Class"))
                    #t)
                  (raise outer-marker)))))))
    (gate-check "outer source failure propagates exact error"
      (and (not (t-ok? outer))
           (eq? (t-value outer) outer-marker))
      #t))
  (gate-check "nested inner provider remains published"
    (class-provider-for "tx.NestedInner.Class")
    "tx.NestedInner.provider")
  (gate-check "nested inner constructor remains published"
    (procedure?
      (hashtable-ref class-ctors-tbl "tx.NestedInner.Host" #f))
    #t)
  (gate-check "nested inner provider remains loaded"
    (class-provider-provider-status "tx.NestedInner.provider") 'loaded)
  (gate-check "failed outer mapping was discarded"
    (jolt-nil? (class-provider-for "tx.NestedOuter.Class")) #t)
  (gate-check "failed outer constructor was discarded"
    (hashtable-ref class-ctors-tbl "tx.NestedOuter.Host" #f) #f)
  (gate-check "failed outer attempt remains retryable"
    (class-provider-provider-status "tx.NestedOuter.provider") 'failed)
  (gate-check "nested graph failure clears evaluator owner"
    (class-provider-evaluator-owner) #f))

;; Chez thread parameters are inherited. A child forked by provider source must
;; be rejected immediately if it calls a registration hook. Waiting as an
;; external caller would deadlock when the provider joins it, and delayed
;; publication could leak work caused by a provider that later fails.
(class-provider-reset-many! '())
(let ((done-child (t-make-latch))
      (child-result (box #f)))
  (gate-check "provider can join a rejected forked registration"
    (class-provider-load-provider-with!
      "tx.InheritedStage.provider"
      (lambda (_)
        (t-call
          "clojure.core" "__register-class-ctor!"
          "tx.InheritedStage.OwnerHost"
          (lambda args 'owner))
        (fork-thread
          (lambda ()
            (set-box!
              child-result
              (t-capture
                (lambda ()
                  (t-call
                    "clojure.core" "__register-class-ctor!"
                    "tx.InheritedStage.ChildHost"
                    (lambda args 'child)))))
            (t-open-latch! done-child)))
        (t-await-latch! "provider joins forked registration without deadlock"
          done-child)
        (gate-check "forked operation hook fails with structured category"
          (t-captured-error-type (unbox child-result))
          t-cross-thread)
        (gate-check "rejected forked operation stays unpublished"
          (hashtable-ref
            class-ctors-tbl "tx.InheritedStage.ChildHost" #f)
          #f)))
    #t)
  (gate-check "provider owner registration committed"
    (procedure?
      (hashtable-ref class-ctors-tbl "tx.InheritedStage.OwnerHost" #f))
    #t)
  (gate-check "rejected forked operation never publishes"
    (hashtable-ref class-ctors-tbl "tx.InheritedStage.ChildHost" #f) #f)
  (gate-check "joined forked rejection creates no evaluator waiter"
    (class-provider-evaluator-waiters) 0))

;; A successfully committed root no longer poisons a long-lived child with its
;; inherited stage. Once the complete graph is stable, the child falls back to
;; the ordinary synchronized hook path.
(class-provider-reset-many! '())
(let ((child-ready (t-make-latch))
      (release-child (t-make-latch))
      (done-child (t-make-latch))
      (child-result (box #f))
      (child-stage (box #f)))
  (gate-check "provider with delayed child commits"
    (class-provider-load-provider-with!
      "tx.CommittedChild.provider"
      (lambda (_)
        (fork-thread
          (lambda ()
            (set-box! child-stage (class-provider-registration-stage))
            (t-open-latch! child-ready)
            (t-await-latch-raw! release-child)
            (set-box!
              child-result
              (t-capture
                (lambda ()
                  (t-call
                    "clojure.core" "__register-class-ctor!"
                    "tx.CommittedChild.Host"
                    (lambda args 'child)))))
            (t-open-latch! done-child)))
        (t-await-latch-raw! child-ready)))
    #t)
  (gate-check "committed inherited stage clears operation closures"
    (vector-ref (unbox child-stage) cp-stage-operations-index) '())
  (gate-check "committed inherited stage clears pending mappings"
    (vector-ref (unbox child-stage) cp-stage-mappings-index) #f)
  (gate-check "committed inherited stage retains terminal provenance"
    (vector-ref (unbox child-stage) cp-stage-state-index) 'committed)
  (t-open-latch! release-child)
  (t-await-latch! "committed provider child completes later" done-child)
  (gate-check "committed provider child may use ordinary hook"
    (t-ok? (unbox child-result)) #t)
  (gate-check "committed provider child publishes after graph completion"
    (procedure?
      (hashtable-ref class-ctors-tbl "tx.CommittedChild.Host" #f))
    #t)
  (gate-check "committed child leaves evaluator waiters clear"
    (class-provider-evaluator-waiters) 0))

;; A helper may commit before its outer provider graph completes. Its child is
;; still rejected while that different owner is active, so an outer join cannot
;; turn into a wait-for-owner deadlock.
(class-provider-reset-many! '())
(let ((release-child (t-make-latch))
      (done-child (t-make-latch))
      (child-result (box #f)))
  (gate-check "outer provider can join committed helper child safely"
    (class-provider-load-provider-with!
      "tx.HelperChildOuter.provider"
      (lambda (_)
        (class-provider-load-namespace-with-stage!
          "tx.HelperChild.namespace"
          (lambda ()
            (fork-thread
              (lambda ()
                (t-await-latch-raw! release-child)
                (set-box!
                  child-result
                  (t-capture
                    (lambda ()
                      (t-call
                        "clojure.core" "__register-class-ctor!"
                        "tx.HelperChild.Host"
                        (lambda args 'child)))))
                (t-open-latch! done-child))))
          (lambda (_namespace _stage) #f))
        (t-open-latch! release-child)
        (t-await-latch!
          "outer provider joins committed helper child without deadlock"
          done-child)
        (gate-check "committed helper child is rejected during outer graph"
          (t-captured-error-type (unbox child-result))
          t-cross-thread)))
    #t)
  (gate-check "committed helper child publishes nothing during outer graph"
    (hashtable-ref class-ctors-tbl "tx.HelperChild.Host" #f) #f)
  (gate-check "committed helper child creates no evaluator waiter"
    (class-provider-evaluator-waiters) 0))

;; Provider-map registration uses a separate hook path and must enforce the same
;; owner rule. A rejected child cannot leak its mapping after the parent fails.
(class-provider-reset-many! '())
(let ((done-child (t-make-latch))
      (child-result (box #f))
      (parent-marker (list 'forked-parent-failure)))
  (let ((parent
          (t-capture
            (lambda ()
              (class-provider-load-provider-with!
                "tx.ForkedFailure.provider"
                (lambda (_)
                  (fork-thread
                    (lambda ()
                      (set-box!
                        child-result
                        (t-capture
                          (lambda ()
                            (t-call
                              "jolt.host" "register-class-providers!"
                              (jolt-hash-map
                                "tx.ForkedFailure.ChildClass"
                                "tx.ForkedFailure.child")))))
                      (t-open-latch! done-child)))
                  (t-await-latch!
                    "failing provider joins rejected forked map registration"
                    done-child)
                  (raise parent-marker)))))))
    (gate-check "failed parent preserves exact source error"
      (and (not (t-ok? parent))
           (eq? (t-value parent) parent-marker))
      #t))
  (gate-check "forked provider-map hook fails with structured category"
    (t-captured-error-type (unbox child-result))
    t-cross-thread)
  (gate-check "rejected forked provider mapping never leaks"
    (jolt-nil? (class-provider-for "tx.ForkedFailure.ChildClass")) #t)
  (gate-check "failed forked parent clears evaluator owner"
    (class-provider-evaluator-owner) #f)
  (gate-check "failed forked parent creates no evaluator waiter"
    (class-provider-evaluator-waiters) 0))

;; A child delayed until after parent failure retains an aborted stage and stays
;; fail closed; causally failed provider work must never publish later.
(class-provider-reset-many! '())
(let ((child-ready (t-make-latch))
      (release-child (t-make-latch))
      (done-child (t-make-latch))
      (child-result (box #f))
      (child-stage (box #f))
      (parent-marker (list 'delayed-forked-parent-failure)))
  (let ((parent
          (t-capture
            (lambda ()
              (class-provider-load-provider-with!
                "tx.AbortedChild.provider"
                (lambda (_)
                  (fork-thread
                    (lambda ()
                      (set-box! child-stage (class-provider-registration-stage))
                      (t-open-latch! child-ready)
                      (t-await-latch-raw! release-child)
                      (set-box!
                        child-result
                        (t-capture
                          (lambda ()
                            (t-call
                              "clojure.core" "__register-class-ctor!"
                              "tx.AbortedChild.Host"
                              (lambda args 'child)))))
                      (t-open-latch! done-child)))
                  (t-await-latch-raw! child-ready)
                  (raise parent-marker)))))))
    (gate-check "delayed child parent preserves exact failure"
      (and (not (t-ok? parent))
           (eq? (t-value parent) parent-marker))
      #t))
  (gate-check "aborted inherited stage clears operation closures"
    (vector-ref (unbox child-stage) cp-stage-operations-index) '())
  (gate-check "aborted inherited stage clears pending mappings"
    (vector-ref (unbox child-stage) cp-stage-mappings-index) #f)
  (gate-check "aborted inherited stage retains terminal provenance"
    (vector-ref (unbox child-stage) cp-stage-state-index) 'aborted)
  (t-open-latch! release-child)
  (t-await-latch! "aborted provider child completes later" done-child)
  (gate-check "aborted provider child remains structured-rejected"
    (t-captured-error-type (unbox child-result))
    t-cross-thread)
  (gate-check "aborted provider child never publishes later"
    (hashtable-ref class-ctors-tbl "tx.AbortedChild.Host" #f) #f)
  (gate-check "aborted provider child leaves evaluator waiters clear"
    (class-provider-evaluator-waiters) 0))

;; --- external registration waits, then survives provider rollback -----------
(class-provider-reset-many! '())
(let ((entered (t-make-latch))
      (release (t-make-latch))
      (done-owner (t-make-latch))
      (done-external (t-make-latch))
      (owner-result (box #f))
      (external-result (box #f))
      (marker (list 'concurrent-provider-commit-failure)))
  (fork-thread
    (lambda ()
      (set-box!
        owner-result
        (t-capture
          (lambda ()
            (class-provider-load-provider-with!
              "tx.ConcurrentOwner.provider"
              (lambda (_)
                (t-call
                  "clojure.core" "__register-class-ctor!"
                  "tx.ConcurrentOwner.Host"
                  (lambda args 'owner))
                (class-provider-stage-operation!
                  (lambda () (raise marker)))
                (t-open-latch! entered)
                (t-await-latch-raw! release))))))
      (t-open-latch! done-owner)))
  (t-await-latch! "concurrent provider owner entered" entered)
  (fork-thread
    (lambda ()
      (set-box!
        external-result
        (t-capture
          (lambda ()
            (t-call
              "clojure.core" "__register-class-ctor!"
              "tx.ConcurrentExternal.Host"
              (lambda args 'external)))))
      (t-open-latch! done-external)))
  (t-await-predicate!
    "ordinary host registration waits behind provider evaluator"
    (lambda () (> (class-provider-evaluator-waiters) 0)))
  (gate-check "waiting external registration is not published early"
    (hashtable-ref class-ctors-tbl "tx.ConcurrentExternal.Host" #f) #f)
  (t-open-latch! release)
  (t-await-latch! "concurrent provider owner completed" done-owner)
  (t-await-latch! "external registration completed" done-external)
  (gate-check "concurrent owner receives commit error"
    (and (not (t-ok? (unbox owner-result)))
         (eq? (t-value (unbox owner-result)) marker))
    #t)
  (gate-check "failed provider prefix rolled back"
    (hashtable-ref class-ctors-tbl "tx.ConcurrentOwner.Host" #f) #f)
  (gate-check "external registration succeeds after rollback"
    (t-ok? (unbox external-result)) #t)
  (gate-check "external registration survives rollback boundary"
    (procedure?
      (hashtable-ref class-ctors-tbl "tx.ConcurrentExternal.Host" #f))
    #t)
  (gate-check "concurrent rollback drains evaluator waiters"
    (class-provider-evaluator-waiters) 0)
  (gate-check "concurrent rollback clears evaluator owner"
    (class-provider-evaluator-owner) #f))

;; --- real loader: root commit failure reopens exactly the provider root -------
;; A malformed staged static member key fails after the root loader returns. Its
;; counter is an intentionally nontransactional side effect proving that cleanup
;; re-evaluates the discarded root.
(define t-real-root-load-count 0)
(def-var! "tx.fixture.control" "root-tick!"
  (lambda ()
    (set! t-real-root-load-count (+ t-real-root-load-count 1))
    t-real-root-load-count))
(class-provider-reset-many! '())
(let* ((provider "txfixture.commit-failure")
       (first
         (t-capture
           (lambda () (class-provider-load-provider! provider)))))
  (gate-check "real namespace commit failure raises"
    (t-ok? first) #f)
  (gate-check "real provider root evaluated before first commit failure"
    t-real-root-load-count 1)
  (gate-check "real commit failure removes loader dedup mark"
    (hashtable-ref loaded-ns provider #f) #f)
  (gate-check "real commit failure rolls back published ctor prefix"
    (hashtable-ref
      class-ctors-tbl "tx.RealCommitFailure.Host" #f)
    #f)
  (gate-check "real commit failure records a failed provider attempt"
    (class-provider-provider-status provider) 'failed)
  (let ((failed-attempt
          (class-provider-provider-attempt-id provider)))
    (let ((second
            (t-capture
              (lambda () (class-provider-load-provider! provider)))))
      (gate-check "later real loader retry reaches commit and fails again"
        (t-ok? second) #f)
      (gate-check "real loader retry uses a fresh evaluator attempt"
        (> (class-provider-provider-attempt-id provider) failed-attempt) #t)))
  (gate-check "real loader retry re-evaluates provider root"
    t-real-root-load-count 2)
  (gate-check "second real commit failure leaves namespace retryable"
    (hashtable-ref loaded-ns provider #f) #f)
  (gate-check "second real commit failure leaves no ctor prefix"
    (hashtable-ref
      class-ctors-tbl "tx.RealCommitFailure.Host" #f)
    #f)
  (gate-check "real loader failures clear evaluator owner"
    (class-provider-evaluator-owner) #f))

;; A helper's staged publication fails inside the outer provider's loader call.
;; Both loader marks must reopen, and the helper's published prefix must roll
;; back, so an independent outer retry evaluates the helper again.
(define t-helper-commit-failure-count 0)
(def-var! "tx.fixture.control" "helper-commit-failure-tick!"
  (lambda ()
    (set! t-helper-commit-failure-count
          (+ t-helper-commit-failure-count 1))
    t-helper-commit-failure-count))
(class-provider-reset-many! '())
(let* ((outer "txfixture.helper-failure-outer")
       (helper "txfixture.helper-commit-failure")
       (first
         (t-capture
           (lambda () (class-provider-load-provider! outer)))))
  (gate-check "helper commit failure propagates through provider load"
    (t-ok? first) #f)
  (gate-check "failing helper evaluated before first commit failure"
    t-helper-commit-failure-count 1)
  (gate-check "helper commit failure reopens outer root"
    (hashtable-ref loaded-ns outer #f) #f)
  (gate-check "helper commit failure reopens helper"
    (hashtable-ref loaded-ns helper #f) #f)
  (gate-check "helper commit failure rolls back helper ctor prefix"
    (hashtable-ref class-ctors-tbl "tx.HelperCommitFailure.Host" #f) #f)
  (gate-check "helper commit failure records failed outer attempt"
    (class-provider-provider-status outer) 'failed)
  (let ((second
          (t-capture
            (lambda () (class-provider-load-provider! outer)))))
    (gate-check "helper commit failure remains retryable"
      (t-ok? second) #f))
  (gate-check "helper commit failure retry re-evaluates helper"
    t-helper-commit-failure-count 2)
  (gate-check "helper retry leaves outer root open"
    (hashtable-ref loaded-ns outer #f) #f)
  (gate-check "helper retry leaves helper open"
    (hashtable-ref loaded-ns helper #f) #f)
  (gate-check "helper retry leaves no ctor prefix"
    (hashtable-ref class-ctors-tbl "tx.HelperCommitFailure.Host" #f) #f)
  (gate-check "helper failure graph clears evaluator owner"
    (class-provider-evaluator-owner) #f))

;; --- real loader: namespace-local helper/nested commits survive outer failure
;; The helper commits before returning to the outer provider. The nested provider
;; then requires the already loaded helper and commits independently. A later
;; outer commit failure must preserve both successful namespaces and retry only
;; the outer root.
(define t-shared-helper-load-count 0)
(define t-shared-nested-load-count 0)
(define t-shared-outer-load-count 0)
(define t-shared-helper-observed-count 0)
(def-var! "tx.fixture.control" "shared-helper-tick!"
  (lambda ()
    (set! t-shared-helper-load-count (+ t-shared-helper-load-count 1))
    t-shared-helper-load-count))
(def-var! "tx.fixture.control" "shared-nested-tick!"
  (lambda ()
    (set! t-shared-nested-load-count (+ t-shared-nested-load-count 1))
    t-shared-nested-load-count))
(def-var! "tx.fixture.control" "shared-outer-tick!"
  (lambda ()
    (set! t-shared-outer-load-count (+ t-shared-outer-load-count 1))
    t-shared-outer-load-count))
(def-var! "tx.fixture.control" "load-shared-nested!"
  (lambda ()
    (class-provider-load-provider! "txfixture.shared-nested")))
(def-var! "tx.fixture.control" "observe-shared-helper!"
  (lambda ()
    (let ((ctor
            (hashtable-ref
              class-ctors-tbl "tx.SharedHelper.Host" #f)))
      (unless (procedure? ctor)
        (error
          'observe-shared-helper!
          "helper was marked loaded before its registration committed"))
      (set! t-shared-helper-observed-count
            (+ t-shared-helper-observed-count 1))
      (jolt-invoke ctor))))
(class-provider-reset-many! '())
(let* ((outer "txfixture.shared-outer")
       (nested "txfixture.shared-nested")
       (helper "txfixture.shared-helper")
       (first
         (t-capture
           (lambda () (class-provider-load-provider! outer)))))
  (gate-check "shared outer first commit fails"
    (t-ok? first) #f)
  (gate-check "shared outer first source evaluation ran"
    t-shared-outer-load-count 1)
  (gate-check "shared helper evaluated exactly once before outer failure"
    t-shared-helper-load-count 1)
  (gate-check "shared nested provider evaluated exactly once"
    t-shared-nested-load-count 1)
  (gate-check "nested provider observed committed helper registration"
    t-shared-helper-observed-count 1)
  (gate-check "failed shared outer root is unmarked"
    (hashtable-ref loaded-ns outer #f) #f)
  (gate-check "successful shared helper remains marked"
    (hashtable-ref loaded-ns helper #f) #t)
  (gate-check "successful shared nested provider remains marked"
    (hashtable-ref loaded-ns nested #f) #t)
  (gate-check "shared helper constructor remains callable"
    (jolt-invoke
      (hashtable-ref class-ctors-tbl "tx.SharedHelper.Host" #f))
    (keyword #f "shared-helper"))
  (gate-check "shared nested constructor remains callable"
    (jolt-invoke
      (hashtable-ref class-ctors-tbl "tx.SharedNested.Host" #f))
    (keyword #f "shared-nested"))
  (gate-check "failed shared outer constructor is absent"
    (hashtable-ref class-ctors-tbl "tx.SharedOuter.Host" #f) #f)
  (gate-check "shared nested provider remains loaded"
    (class-provider-provider-status nested) 'loaded)
  (gate-check "shared outer provider records failed attempt"
    (class-provider-provider-status outer) 'failed)
  (gate-check "shared outer retry succeeds"
    (class-provider-load-provider! outer) #t)
  (gate-check "shared outer retry evaluates only the outer source"
    t-shared-outer-load-count 2)
  (gate-check "shared outer retry deduplicates successful helper"
    t-shared-helper-load-count 1)
  (gate-check "shared outer retry deduplicates successful nested provider"
    t-shared-nested-load-count 1)
  (gate-check "shared outer retry does not re-run nested helper observation"
    t-shared-helper-observed-count 1)
  (gate-check "shared outer retry marks root loaded"
    (hashtable-ref loaded-ns outer #f) #t)
  (gate-check "shared outer provider becomes loaded"
    (class-provider-provider-status outer) 'loaded)
  (gate-check "shared outer constructor becomes callable"
    (jolt-invoke
      (hashtable-ref class-ctors-tbl "tx.SharedOuter.Host" #f))
    (keyword #f "shared-outer"))
  (gate-check "shared graph leaves evaluator owner clear"
    (class-provider-evaluator-owner) #f)
  (gate-check "shared graph leaves evaluator waiters clear"
    (class-provider-evaluator-waiters) 0))

(gate-summary "class-provider-transactions")
