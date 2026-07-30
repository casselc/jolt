;; class-provider EVALUATION COORDINATOR gate.
;;
;; Covers the direct Scheme state machine only. Host static/constructor/member
;; misses do not call the evaluator in this slice, and provider-owned host
;; registrations are not yet staged or published.
;;
;;   CHEZ=/path/to/chez make providerevaluator

(import (chezscheme))
(load "host/chez/run-gate-harness.ss")

;; --- structured failure helpers --------------------------------------------
(define t-type-kw (keyword #f "type"))
(define t-path-kw (keyword #f "path"))
(define t-cycle (keyword "jolt.deps" "class-provider-cycle"))
(define (t-condition-data e)
  (let ((v (jolt-unwrap-throw e)))
    (if (and (jolt-ex-info-record? v)
             (pmap? (jolt-ex-info-record-data v)))
        (jolt-ex-info-record-data v)
        jolt-nil)))
(define (t-condition-type e)
  (let ((data (t-condition-data e)))
    (if (pmap? data)
        (pmap-get data t-type-kw jolt-nil)
        jolt-nil)))

;; Capture success or the exact raised object without changing it.
(define (t-capture thunk)
  (guard (e (#t (vector 'error e)))
    (vector 'ok (thunk))))
(define (t-ok? result) (eq? (vector-ref result 0) 'ok))
(define (t-value result) (vector-ref result 1))

;; --- bounded thread latches -------------------------------------------------
;; Every wait has a five-second deadline so a coordinator regression reports a
;; failed row instead of hanging make ci.
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

;; --- exact lookup and sequential lifecycle ---------------------------------
(class-provider-reset-many!
  (list (cons "provider.eval.Exact" "provider.eval.exact")))
(let ((loads 0))
  (gate-check "exact class miss does not use a short-name provider"
    (class-provider-try-load-with!
      "Exact"
      (lambda (_) (set! loads (+ loads 1))))
    #f)
  (gate-check "short-name miss performed no evaluation" loads 0)
  (gate-check "exact class hit evaluates its provider"
    (class-provider-try-load-with!
      "provider.eval.Exact"
      (lambda (provider)
        (gate-check "loader receives exact provider namespace"
          provider "provider.eval.exact")
        (set! loads (+ loads 1))))
    #t)
  (gate-check "successful provider evaluated once" loads 1)
  (gate-check "successful provider is terminal"
    (class-provider-load-provider-with!
      "provider.eval.exact"
      (lambda (_) (set! loads (+ loads 1))))
    #f)
  (gate-check "terminal provider was not evaluated again" loads 1)
  (gate-check "successful provider state is loaded"
    (class-provider-provider-status "provider.eval.exact")
    'loaded)
  (gate-check "root success clears evaluator owner"
    (class-provider-evaluator-owner) #f))
(class-provider-reset-many!
  (list (cons "provider.eval.Exact" "provider.eval.exact")))
(gate-check "registry reset clears terminal evaluator state"
  (class-provider-provider-status "provider.eval.exact")
  'unloaded)

;; A failed attempt is retained for its waiters, but a later independent caller
;; replaces it and may retry cleanly.
(class-provider-reset-many! '())
(let ((marker (list 'provider-eval-failure))
      (loads 0))
  (let ((first
          (t-capture
            (lambda ()
              (class-provider-load-provider-with!
                "provider.eval.retry"
                (lambda (_)
                  (set! loads (+ loads 1))
                  (raise marker)))))))
    (gate-check "provider failure is propagated unchanged"
      (and (not (t-ok? first)) (eq? (t-value first) marker))
      #t)
    (gate-check "failed provider state is retained"
      (class-provider-provider-status "provider.eval.retry")
      'failed)
    (let ((failed-attempt
            (class-provider-evaluator-attempt-count)))
      (gate-check "later independent caller retries failed provider"
        (class-provider-load-provider-with!
          "provider.eval.retry"
          (lambda (_) (set! loads (+ loads 1))))
        #t)
      (gate-check "retry uses a fresh attempt id"
        (> (class-provider-evaluator-attempt-count)
           failed-attempt)
        #t)))
  (gate-check "failure plus retry evaluated twice" loads 2)
  (gate-check "successful retry leaves provider loaded"
    (class-provider-provider-status "provider.eval.retry")
    'loaded)
  (gate-check "root failure/retry clears evaluator owner"
    (class-provider-evaluator-owner) #f))

;; --- cycles and nested owner re-entry ---------------------------------------
(class-provider-reset-many! '())
(let ((outer
        (t-capture
          (lambda ()
            (class-provider-load-provider-with!
              "provider.eval.cycle"
              (lambda (_)
                (class-provider-load-provider-with!
                  "provider.eval.cycle"
                  (lambda (_) (error 'unreachable)))))))))
  (gate-check "owner re-entry raises structured provider cycle"
    (and (not (t-ok? outer))
         (equal? (t-condition-type (t-value outer)) t-cycle))
    #t)
  (let ((data (t-condition-data (t-value outer))))
    (gate-check "direct cycle reports bounded repeated path"
      (seq->list (pmap-get data t-path-kw jolt-nil))
      (list "provider.eval.cycle" "provider.eval.cycle")))
  (gate-check "cycle abort leaves failed attempt"
    (class-provider-provider-status "provider.eval.cycle")
    'failed)
  (gate-check "cycle abort clears evaluator owner"
    (class-provider-evaluator-owner) #f))

(class-provider-reset-many! '())
(let ((events '()))
  (gate-check "owner may evaluate a different nested provider"
    (class-provider-load-provider-with!
      "provider.eval.outer"
      (lambda (_)
        (set! events (cons 'outer-start events))
        (class-provider-load-provider-with!
          "provider.eval.inner"
          (lambda (_) (set! events (cons 'inner events))))
        (set! events (cons 'outer-end events))))
    #t)
  (gate-check "nested provider order is deterministic"
    (reverse events) '(outer-start inner outer-end))
  (gate-check "outer provider loaded"
    (class-provider-provider-status "provider.eval.outer") 'loaded)
  (gate-check "inner provider loaded"
    (class-provider-provider-status "provider.eval.inner") 'loaded)
  (gate-check "nested success clears root owner"
    (class-provider-evaluator-owner) #f))

;; --- process-wide serialization across different providers -----------------
(class-provider-reset-many! '())
(let ((entered-a (t-make-latch))
      (release-a (t-make-latch))
      (done-a (t-make-latch))
      (done-b (t-make-latch))
      (result-a (box #f))
      (result-b (box #f))
      (active 0)
      (max-active 0)
      (b-started? #f)
      (counter-mu (make-mutex)))
  (define (enter-loader!)
    (with-mutex counter-mu
      (set! active (+ active 1))
      (set! max-active (max max-active active))))
  (define (leave-loader!)
    (with-mutex counter-mu
      (set! active (- active 1))))
  (fork-thread
    (lambda ()
      (set-box! result-a
        (t-capture
          (lambda ()
            (class-provider-load-provider-with!
              "provider.eval.serial-a"
              (lambda (_)
                (enter-loader!)
                (t-open-latch! entered-a)
                (t-await-latch-raw! release-a)
                (leave-loader!))))))
      (t-open-latch! done-a)))
  (t-await-latch! "first loader entered" entered-a)
  (fork-thread
    (lambda ()
      (set-box! result-b
        (t-capture
          (lambda ()
            (class-provider-load-provider-with!
              "provider.eval.serial-b"
              (lambda (_)
                (enter-loader!)
                (set! b-started? #t)
                (leave-loader!))))))
      (t-open-latch! done-b)))
  (t-await-predicate!
    "different-provider caller waits behind active owner"
    (lambda () (> (class-provider-evaluator-waiters) 0)))
  (gate-check "second provider loader has not started while owner is active"
    b-started? #f)
  (t-open-latch! release-a)
  (t-await-latch! "first loader completed" done-a)
  (t-await-latch! "second loader completed" done-b)
  (gate-check "first serialized evaluation succeeded"
    (and (t-ok? (unbox result-a)) (t-value (unbox result-a))) #t)
  (gate-check "second serialized evaluation succeeded"
    (and (t-ok? (unbox result-b)) (t-value (unbox result-b))) #t)
  (gate-check "at most one provider loader was active"
    max-active 1)
  (gate-check "second provider eventually evaluated"
    b-started? #t)
  (gate-check "serialized evaluations clear owner"
    (class-provider-evaluator-owner) #f)
  (gate-check "serialized evaluations drain global waiters"
    (class-provider-evaluator-waiters) 0))

;; Registry publication by another thread also waits for a stable provider
;; world. This is the public registration path used by project/add-deps setup.
(class-provider-reset-many! '())
(let ((entered (t-make-latch))
      (release (t-make-latch))
      (done-owner (t-make-latch))
      (done-register (t-make-latch))
      (owner-result (box #f))
      (register-result (box #f)))
  (fork-thread
    (lambda ()
      (set-box! owner-result
        (t-capture
          (lambda ()
            (class-provider-load-provider-with!
              "provider.eval.registration-owner"
              (lambda (_)
                (t-open-latch! entered)
                (t-await-latch-raw! release))))))
      (t-open-latch! done-owner)))
  (t-await-latch! "registration owner entered" entered)
  (fork-thread
    (lambda ()
      (set-box! register-result
        (t-capture
          (lambda ()
            (class-provider-register-many!
              (list
                (cons "provider.eval.Registered"
                      "provider.eval.registered"))))))
      (t-open-latch! done-register)))
  (t-await-predicate!
    "external provider registration waits for stable evaluator"
    (lambda () (> (class-provider-evaluator-waiters) 0)))
  (gate-check "waiting registration has not published its mapping"
    (jolt-nil? (class-provider-for "provider.eval.Registered")) #t)
  (t-open-latch! release)
  (t-await-latch! "registration owner completed" done-owner)
  (t-await-latch! "external provider registration completed" done-register)
  (gate-check "registration owner succeeded"
    (and (t-ok? (unbox owner-result)) (t-value (unbox owner-result))) #t)
  (gate-check "external registration succeeded after stable boundary"
    (t-ok? (unbox register-result)) #t)
  (gate-check "external registration publishes after stable boundary"
    (class-provider-for "provider.eval.Registered")
    "provider.eval.registered")
  (gate-check "external registration drains global waiters"
    (class-provider-evaluator-waiters) 0))

;; --- callers joining the same successful attempt ---------------------------
(class-provider-reset-many! '())
(let ((entered (t-make-latch))
      (release (t-make-latch))
      (done-owner (t-make-latch))
      (done-waiter (t-make-latch))
      (owner-result (box #f))
      (waiter-result (box #f))
      (loads 0))
  (define (shared-loader _)
    (set! loads (+ loads 1))
    (t-open-latch! entered)
    (t-await-latch-raw! release))
  (fork-thread
    (lambda ()
      (set-box! owner-result
        (t-capture
          (lambda ()
            (class-provider-load-provider-with!
              "provider.eval.shared-success" shared-loader))))
      (t-open-latch! done-owner)))
  (t-await-latch! "shared-success owner entered" entered)
  (fork-thread
    (lambda ()
      (set-box! waiter-result
        (t-capture
          (lambda ()
            (class-provider-load-provider-with!
              "provider.eval.shared-success" shared-loader))))
      (t-open-latch! done-waiter)))
  (t-await-predicate!
    "same-provider waiter joins exact attempt"
    (lambda ()
      (= (class-provider-provider-waiters
           "provider.eval.shared-success")
         1)))
  (t-open-latch! release)
  (t-await-latch! "shared-success owner completed" done-owner)
  (t-await-latch! "shared-success waiter completed" done-waiter)
  (gate-check "shared-success owner returns retry permission"
    (and (t-ok? (unbox owner-result)) (t-value (unbox owner-result))) #t)
  (gate-check "shared-success waiter returns retry permission"
    (and (t-ok? (unbox waiter-result)) (t-value (unbox waiter-result))) #t)
  (gate-check "shared-success namespace evaluated exactly once" loads 1)
  (gate-check "shared-success drains attempt waiters"
    (class-provider-provider-waiters "provider.eval.shared-success") 0))

;; --- callers joining the same failed attempt --------------------------------
(class-provider-reset-many! '())
(let ((entered (t-make-latch))
      (release (t-make-latch))
      (done-owner (t-make-latch))
      (done-waiter (t-make-latch))
      (owner-result (box #f))
      (waiter-result (box #f))
      (marker (list 'shared-provider-failure))
      (loads 0))
  (define (failing-loader _)
    (set! loads (+ loads 1))
    (t-open-latch! entered)
    (t-await-latch-raw! release)
    (raise marker))
  (fork-thread
    (lambda ()
      (set-box! owner-result
        (t-capture
          (lambda ()
            (class-provider-load-provider-with!
              "provider.eval.shared-failure" failing-loader))))
      (t-open-latch! done-owner)))
  (t-await-latch! "shared-failure owner entered" entered)
  (fork-thread
    (lambda ()
      (set-box! waiter-result
        (t-capture
          (lambda ()
            (class-provider-load-provider-with!
              "provider.eval.shared-failure" failing-loader))))
      (t-open-latch! done-waiter)))
  (t-await-predicate!
    "shared-failure waiter joins exact attempt"
    (lambda ()
      (= (class-provider-provider-waiters
           "provider.eval.shared-failure")
         1)))
  (t-open-latch! release)
  (t-await-latch! "shared-failure owner completed" done-owner)
  (t-await-latch! "shared-failure waiter completed" done-waiter)
  (gate-check "shared-failure owner receives original error"
    (and (not (t-ok? (unbox owner-result)))
         (eq? (t-value (unbox owner-result)) marker))
    #t)
  (gate-check "shared-failure waiter receives same error object"
    (and (not (t-ok? (unbox waiter-result)))
         (eq? (t-value (unbox waiter-result)) marker))
    #t)
  (gate-check "shared-failure namespace evaluated exactly once" loads 1)
  (gate-check "shared-failure drains attempt waiters"
    (class-provider-provider-waiters "provider.eval.shared-failure") 0)
  (gate-check "later independent call retries shared failure"
    (class-provider-load-provider-with!
      "provider.eval.shared-failure"
      (lambda (_) (set! loads (+ loads 1))))
    #t)
  (gate-check "shared failure plus later retry evaluated twice" loads 2)
  (gate-check "shared failure retry clears owner"
    (class-provider-evaluator-owner) #f))

(gate-summary "class-provider-evaluator")
