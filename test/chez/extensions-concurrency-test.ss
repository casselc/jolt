;; extensions-concurrency-test.ss -- logical serialization for extension points.
;;
;; The registry calls generic equality, map, rendering, and error paths.  Those
;; calls may run user code or park, so the semantic operation is protected by an
;; execution-context logical mutex while every generic call observes zero
;; counted locks.  The tests below pin that shape, concurrent union/epoch
;; publication, and the fail-fast rule for a same-owner recursive mutation.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n" name)))

(define (kw s) (keyword #f s))
(define (jm . kvs) (apply jolt-hash-map kvs))
(define (field-map name type) (jm (kw name) (kw type)))
(define (default-map name value) (jm (kw name) value))
(define (declare-spec field type value)
  (jm (kw "key") (kw "string")
      (kw "root") ""
      (kw "fields") (field-map field type)
      (kw "default") (default-map field value)
      (kw "fallback") (kw "strict")))
(define (refine-spec field type value)
  (jm (kw "fields") (field-map field type)
      (kw "default") (default-map field value)))
(define (map-get m name)
  (jolt-get-dispatch m (kw name) jolt-nil))

(define (string-has? s needle)
  (and (string? s)
       (let ((n (string-length s)) (m (string-length needle)))
         (let loop ((i 0))
           (and (<= (+ i m) n)
                (or (string=? (substring s i (+ i m)) needle)
                    (loop (+ i 1))))))))

;; Bounded thread result and simultaneous-start helpers.  Timeouts are watchdogs,
;; never the synchronization mechanism.
(define (thread-result thunk)
  (let ((mu (make-mutex)) (cv (make-condition))
        (done? #f) (value #f) (raised #f))
    (fork-thread
      (lambda ()
        (guard (e (#t (jolt-with-mutex mu
                         (set! raised e)
                         (set! done? #t)
                         (condition-broadcast cv))))
          (let ((v (thunk)))
            (jolt-with-mutex mu
              (set! value v)
              (set! done? #t)
              (condition-broadcast cv))))))
    (vector mu cv (lambda () done?) (lambda () value) (lambda () raised))))

(define (thread-result-await tr)
  (let ((deadline (+ (now-millis) 10000)))
    (jolt-with-mutex (vector-ref tr 0)
      (let loop ()
        (unless ((vector-ref tr 2))
          (when (>= (now-millis) deadline)
            (error 'extensions-concurrency-test "thread watchdog expired"))
          (jolt-condition-wait (vector-ref tr 1) (vector-ref tr 0)
                               (jolt-millis->time deadline))
          (loop))))
    (let ((e ((vector-ref tr 4))))
      (if e (raise e) ((vector-ref tr 3))))))

(define (make-start-gate count)
  (let ((mu (make-mutex)) (cv (make-condition)) (arrived 0) (open? #f))
    (lambda ()
      (jolt-with-mutex mu
        (set! arrived (+ arrived 1))
        (if (= arrived count)
            (begin (set! open? #t) (condition-broadcast cv))
            (let loop ()
              (unless open?
                (jolt-condition-wait cv mu)
                (loop))))))))

(define (raised thunk)
  (guard (e (#t e)) (thunk) #f))

(define (illegal-state? e)
  (and e
       (let ((v (jolt-unwrap-throw e)))
         (and (jolt-ex-info-record? v)
              (string=? "java.lang.IllegalStateException"
                        (jolt-ex-info-record-class-name v))))))

(printf "== generic dispatch can yield with no counted lock ==\n")
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)

;; jolt-get-dispatch: declaration parsing.
(define original-get jolt-get-dispatch)
(define get-visited? #f)
(set! jolt-get-dispatch
  (lambda (m k d)
    (unless get-visited?
      (set! get-visited? #t)
      (ok "map get runs with zero counted locks" (= 0 (jolt-locks-held)))
      (sa-fiber-yield))
    (original-get m k d)))
(define get-fiber
  (sa-fiber-spawn
    (lambda ()
      (jolt-register-extension-point! (kw "xc-get")
                                      (declare-spec "base" "string" "g")))))
(sa-fiber-run-all)
(set! jolt-get-dispatch original-get)
(ok "declaration finishes after get yields"
    (and get-visited? (eq? 'done (jolt-fiber-state get-fiber))))

;; jolt=2: identical declaration comparison.
(define original-eq jolt=2)
(define eq-visited? #f)
(set! jolt=2
  (lambda (a b)
    (unless eq-visited?
      (set! eq-visited? #t)
      (ok "generic equality runs with zero counted locks" (= 0 (jolt-locks-held)))
      (sa-fiber-yield))
    (original-eq a b)))
(define eq-fiber
  (sa-fiber-spawn
    (lambda ()
      (jolt-register-extension-point! (kw "xc-get")
                                      (declare-spec "base" "string" "g")))))
(sa-fiber-run-all)
(set! jolt=2 original-eq)
(ok "idempotent declaration finishes after equality yields"
    (and eq-visited? (eq? 'done (jolt-fiber-state eq-fiber))))

;; jolt-assoc1: default merge during refinement.
(define original-assoc jolt-assoc1)
(define assoc-visited? #f)
(define assoc-old-point (hashtable-ref extension-points-tbl "xc-get" #f))
(set! jolt-assoc1
  (lambda (m k v)
    (unless assoc-visited?
      (set! assoc-visited? #t)
      (ok "map assoc runs with zero counted locks" (= 0 (jolt-locks-held)))
      (jolt-fiber-park!))
    (original-assoc m k v)))
(define assoc-fiber
  (sa-fiber-spawn
    (lambda ()
      (jolt-refine-extension! (kw "xc-get")
                              (refine-spec "added" "long" 7)))))
(sa-fiber-run-all)
(ok "refinement may park while retaining logical ownership"
    (and assoc-visited?
         (eq? 'parked (jolt-fiber-state assoc-fiber))
         (jolt-logical-mutex-locked? ext-operations-mu)))
(ok "parked preparation has not exposed a partial schema"
    (not (jolt-contains? (jolt-extension-value (kw "xc-get") "")
                         (kw "added"))))
(sa-fiber-resume assoc-fiber)
(let loop ((n 0))
  (when (and (< n 10) (not (memq (jolt-fiber-state assoc-fiber) '(done dead))))
    (sa-fiber-run-all)
    (loop (+ n 1))))
(set! jolt-assoc1 original-assoc)
(ok "refinement finishes after assoc park/resume"
    (and assoc-visited? (eq? 'done (jolt-fiber-state assoc-fiber))))
(ok "resumed refinement published its value"
    (= 7 (map-get (jolt-extension-value (kw "xc-get") "") "added")))
(define assoc-new-point (hashtable-ref extension-points-tbl "xc-get" #f))
(ok "refinement publishes a fresh coherent point generation"
    (and (not (eq? assoc-old-point assoc-new-point))
         (not (jolt-contains? (ext-point-default assoc-old-point) (kw "added")))
         (not (assoc "added" (ext-point-fields assoc-old-point)))
         (= 7 (map-get (ext-point-default assoc-new-point) "added"))
         (assoc "added" (ext-point-fields assoc-new-point))))

;; jolt-pr-readable: invalid provider rendering/error path.
(define original-render jolt-pr-readable)
(define render-visited? #f)
(set! jolt-pr-readable
  (lambda (v)
    (unless render-visited?
      (set! render-visited? #t)
      (ok "renderer runs with zero counted locks" (= 0 (jolt-locks-held)))
      (sa-fiber-yield))
    (original-render v)))
(define render-fiber
  (sa-fiber-spawn
    (lambda ()
      (guard (e (#t 'expected-error))
        (jolt-register-extension! (kw "xc-get") "bad"
                                  (default-map "base" 99))
        'unexpected-success))))
(sa-fiber-run-all)
(set! jolt-pr-readable original-render)
(ok "error unwind releases registry after renderer yields"
    (and render-visited?
         (eq? 'done (jolt-fiber-state render-fiber))
         (eq? 'expected-error (jolt-fiber-result render-fiber))
         (not (jolt-logical-mutex-locked? ext-operations-mu))))

(printf "\n== concurrent declarations and refinements are linearized ==\n")
(define declare-id (kw "xc-declare"))
(define declare-value (declare-spec "base" "string" "d"))
(define declare-epoch extension-epoch-n)
(define declare-start (make-start-gate 2))
(define declare-a
  (thread-result (lambda () (declare-start)
                   (jolt-register-extension-point! declare-id declare-value))))
(define declare-b
  (thread-result (lambda () (declare-start)
                   (jolt-register-extension-point! declare-id declare-value))))
(thread-result-await declare-a)
(thread-result-await declare-b)
(ok "two identical concurrent declarations create once"
    (= (+ declare-epoch 1) extension-epoch-n))
(ok "concurrent declaration remains usable"
    (string=? "d" (map-get (jolt-extension-value declare-id "") "base")))

(define redeclare-epoch extension-epoch-n)
(jolt-register-extension-point! declare-id declare-value)
(ok "idempotent redeclaration does not bump epoch"
    (= redeclare-epoch extension-epoch-n))
(define drift-error
  (raised (lambda ()
            (jolt-register-extension-point!
              declare-id (declare-spec "base" "string" "different")))))
(ok "declaration drift is rejected"
    (and drift-error
         (string-has? (condition-message drift-error) "different contract")))
(ok "drift rejection leaves the original contract"
    (string=? "d" (map-get (jolt-extension-value declare-id "") "base")))

(define refine-epoch extension-epoch-n)
(define refine-start (make-start-gate 2))
(define refine-a
  (thread-result (lambda () (refine-start)
                   (jolt-refine-extension! declare-id
                                           (refine-spec "left" "long" 11)))))
(define refine-b
  (thread-result (lambda () (refine-start)
                   (jolt-refine-extension! declare-id
                                           (refine-spec "right" "long" 22)))))
(thread-result-await refine-a)
(thread-result-await refine-b)
(define refined (jolt-extension-value declare-id ""))
(ok "concurrent refinements preserve their union"
    (and (= 11 (map-get refined "left"))
         (= 22 (map-get refined "right"))))
(ok "each concurrent refinement publishes one epoch"
    (= (+ refine-epoch 2) extension-epoch-n))

(define register-count 8)
(define register-epoch extension-epoch-n)
(define register-start (make-start-gate register-count))
(define register-results
  (let loop ((i 0) (acc '()))
    (if (= i register-count)
        acc
        (loop (+ i 1)
              (cons
                (thread-result
                  (lambda ()
                    (register-start)
                    (jolt-register-extension!
                      declare-id (string-append "p" (number->string i))
                      (default-map "base" (string-append "v" (number->string i))))))
                acc)))))
(for-each thread-result-await register-results)
(ok "concurrent provider registrations lose no epoch bumps"
    (= (+ register-epoch register-count) extension-epoch-n))
(ok "every concurrent provider remains visible"
    (let loop ((i 0))
      (or (= i register-count)
          (and (string=? (string-append "v" (number->string i))
                         (map-get (jolt-extension-value
                                    declare-id (string-append "p" (number->string i)))
                                  "base"))
               (loop (+ i 1))))))

(printf "\n== reentrant mutation retains nested state and rejects stale outer publish ==\n")
(define reentrant-id (kw "xc-reentrant"))
(define reentrant-spec (declare-spec "base" "string" "root"))
(jolt-register-extension-point! reentrant-id reentrant-spec)

;; An idempotent same-owner nested declaration changes no generation and is safe.
(define reentrant-eq-original jolt=2)
(define reentrant-idempotent? #f)
(set! jolt=2
  (lambda (a b)
    (unless reentrant-idempotent?
      (set! reentrant-idempotent? #t)
      (jolt-register-extension-point! reentrant-id reentrant-spec))
    (reentrant-eq-original a b)))
(define idempotent-epoch extension-epoch-n)
(jolt-register-extension-point! reentrant-id reentrant-spec)
(set! jolt=2 reentrant-eq-original)
(ok "same-owner idempotent recursion is accepted"
    (and reentrant-idempotent? (= idempotent-epoch extension-epoch-n)))

;; Declaration snapshots the generation before parsing.  A generic map lookup
;; that recursively performs a real mutation must run once, keep that nested
;; provider, and make the outer create fail before publication.  Bypassing the
;; declaration site's ext-assert-generation! makes the named rejection assertion
;; below fail because xc-decl-outer is silently created.
(define declaration-get-original jolt-get-dispatch)
(define declaration-dispatch-count 0)
(define declaration-triggered? #f)
(set! jolt-get-dispatch
  (lambda (m k d)
    (unless declaration-triggered?
      (set! declaration-triggered? #t)
      (set! declaration-dispatch-count (+ declaration-dispatch-count 1))
      (jolt-register-extension! reentrant-id "decl-nested"
                                (default-map "base" "decl-nested-value")))
    (declaration-get-original m k d)))
(define declaration-outer-error
  (raised
    (lambda ()
      (jolt-register-extension-point!
        (kw "xc-decl-outer") (declare-spec "base" "string" "outer")))))
(set! jolt-get-dispatch declaration-get-original)
(ok "declaration reentry invokes its nested user dispatch exactly once"
    (= 1 declaration-dispatch-count))
(ok "outer declaration generation check rejects stale create"
    (and (illegal-state? declaration-outer-error)
         (not (hashtable-ref extension-points-tbl "xc-decl-outer" #f))))
(ok "outer declaration rejection retains nested provider state"
    (string=? "decl-nested-value"
              (map-get (jolt-extension-value reentrant-id "decl-nested") "base")))

;; Provider validation folds a generic map.  Reenter by registering the SAME
;; provider key with a nested value.  The nested write linearizes and remains;
;; the stale outer write must fail instead of overwriting it.  Bypassing the
;; provider site's ext-assert-generation! kills both named assertions below.
(define provider-fold-original pmap-fold-fwd)
(define provider-dispatch-count 0)
(define provider-triggered? #f)
(set! pmap-fold-fwd
  (lambda (m f init)
    (unless provider-triggered?
      (set! provider-triggered? #t)
      (set! provider-dispatch-count (+ provider-dispatch-count 1))
      (jolt-register-extension! reentrant-id "provider-same-key"
                                (default-map "base" "nested-wins")))
    (provider-fold-original m f init)))
(define provider-outer-error
  (raised
    (lambda ()
      (jolt-register-extension! reentrant-id "provider-same-key"
                                (default-map "base" "stale-outer")))))
(set! pmap-fold-fwd provider-fold-original)
(ok "provider reentry invokes its nested user dispatch exactly once"
    (= 1 provider-dispatch-count))
(ok "outer provider generation check rejects stale overwrite"
    (illegal-state? provider-outer-error))
(ok "outer provider rejection retains nested same-key value"
    (string=? "nested-wins"
              (map-get (jolt-extension-value reentrant-id "provider-same-key") "base")))

;; A nested provider mutation during outer default construction bumps the
;; generation.  The nested provider must remain, and the stale outer refinement
;; must fail before changing fields/default.  Deleting ext-assert-generation!
;; makes this test observe the forbidden silent outer publication.
(define mutation-assoc-original jolt-assoc1)
(define nested-mutation? #f)
(set! jolt-assoc1
  (lambda (m k v)
    (unless nested-mutation?
      (set! nested-mutation? #t)
      (jolt-register-extension! reentrant-id "nested"
                                (default-map "base" "nested-value")))
    (mutation-assoc-original m k v)))
(define stale-outer-error
  (raised (lambda ()
            (jolt-refine-extension! reentrant-id
                                    (refine-spec "outer" "long" 41)))))
(set! jolt-assoc1 mutation-assoc-original)
(define reentrant-root (jolt-extension-value reentrant-id ""))
(ok "stale outer operation fails fast after nested mutation"
    (and (illegal-state? stale-outer-error)
         (string-has? (condition-message stale-outer-error)
                      "nested mutation was kept")))
(ok "nested provider mutation is retained"
    (string=? "nested-value"
              (map-get (jolt-extension-value reentrant-id "nested") "base")))
(ok "rejected outer refinement publishes neither field nor default"
    (not (jolt-contains? reentrant-root (kw "outer"))))
(ok "reentrant failure unwinds logical ownership"
    (not (jolt-logical-mutex-locked? ext-operations-mu)))

;; A later operation from another OS thread proves exception unwind did not
;; strand logical ownership on the throwing execution context.
(define after-error
  (thread-result
    (lambda ()
      (jolt-register-extension! reentrant-id "after"
                                (default-map "base" "after-value")))))
(thread-result-await after-error)
(ok "another thread mutates after reentrant fail-fast unwind"
    (string=? "after-value"
              (map-get (jolt-extension-value reentrant-id "after") "base")))

(jolt-fiber-pool-reset!)
(printf "\nextensions-concurrency-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "extensions-concurrency-test: PASS\n") (exit 0))
    (exit 1))
