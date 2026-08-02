;; Focused source-runtime gate for the complete atomic sim-image controller ABI.
(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/ffi.ss")
(load "host/chez/sim/runtime.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a~n" name)))
(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))
(define (kw s) (keyword #f s))
(define (mget m s) (jolt-get m (kw s)))
(define (ev s) (jolt-compile-eval s "user"))
(define (controller-config future ffi clock)
  (jolt-hash-map (kw "future") future (kw "ffi") ffi (kw "clock") clock))
(define (quiet-future event id parent) jolt-nil)
(define (native-ffi descriptor proceed) (jolt-invoke proceed))
(define (native-clock descriptor proceed) (jolt-invoke proceed))
(define (install ffi clock)
  (jolt-sim-install-controller! (controller-config quiet-future ffi clock)))
(define (controller-state)
  (list (unbox jolt-future-hook) jolt-ffi-sim-hook jolt-ffi-sim-hook-top
        jolt-sim-clock-top jolt-sim-controller-top))
(define (same-state? a b)
  (and (= (length a) (length b))
       (for-all (lambda (p) (eq? (car p) (cdr p))) (map cons a b))))

;; Exact public descriptor and exact ordered raw operation registry.
(define caps (jolt-sim-capabilities))
(ok "controller ABI is exactly prerelease 6" (= 6 (mget caps "abi-version")))
(ok "FFI descriptor is exactly 5"
    (= 5 (mget (mget caps "ffi-interception") "descriptor-version")))
(ok "clock descriptor is exactly 1"
    (= 1 (mget (mget caps "clock-interception") "descriptor-version")))
(ok "public installation descriptor names one exact complete config"
    (equal? (vector->list (pvec-v (mget (mget caps "installation")
                                      "configuration-keys")))
            (map kw '("future" "ffi" "clock"))))
(ok "raw-op registry is exact and ordered"
    (equal? (vector->list (pvec-v (mget (mget caps "ffi-interception")
                                      "native-operations")))
            (map kw '("load-library" "loaded?" "alloc" "free" "read" "write"
                      "sizeof" "read-bytes" "write-bytes" "read-array"
                      "read-array!" "write-array" "borrow-byte-array"
                      "release-byte-array" "ptr->string" "string->ptr"))))
(define expected-capabilities
  (ev "{:abi-version 6
        :future-lifecycle true
        :controller-errors true
        :events [:spawn :start :finish :cancel :exit :abort]
        :installation {:configuration-keys [:future :ffi :clock]
                       :install-arity 1 :restore-arity 1
                       :atomic? true :strict-lifo? true
                       :future-controller-arity 3
                       :ffi-controller-arity 2
                       :clock-controller-arity 2}
        :ffi-interception {:descriptor-version 5
                           :kinds [:foreign-function :native-operation]
                           :arguments :live
                           :task-identity :future-lifecycle
                           :native-operations [:load-library :loaded? :alloc :free
                                               :read :write :sizeof :read-bytes
                                               :write-bytes :read-array :read-array!
                                               :write-array :borrow-byte-array
                                               :release-byte-array :ptr->string :string->ptr]
                           :proceed-routing {:controller-arity 2 :proceed-arity 0
                                             :single-use true :dynamic-extent true
                                             :owner-thread true :lifo true
                                             :scoped-byte-array-release :runtime-owned}}
        :clock-interception {:descriptor-version 1
                             :operations [:mono-nanos]
                             :result :exact-integer-nanoseconds
                             :nondecreasing? true
                             :supervisor-operation :supervisor-mono-nanos
                             :proceed-routing {:controller-arity 2 :proceed-arity 0
                                               :single-use true :dynamic-extent true
                                               :owner-thread true :lifo true}}}"))
(ok "capability map matches the one exact ABI 6 contract"
    (jolt=2 caps expected-capabilities))
(ok "sim public ABI exports no independent subcontroller installers"
    (for-all
     (lambda (name) (not (var-cell-lookup "jolt.internal.sim" name)))
     '("install-ffi-controller!" "install-ffi-routing-controller!"
       "restore-ffi-controller!" "install-clock-controller!"
       "install-clock-routing-controller!" "restore-clock-controller!")))

;; Unknown/malformed projected operations fail before a controller or OS call.
(ok "unknown native operation fails closed"
    (raises? (lambda ()
               (jolt-sim-project-ffi-descriptor
                (list (cons 'kind 'native-operation)
                      (cons 'operation "ghost") (cons 'arguments '()))))))
(ok "wrong read-array! arity fails closed"
    (raises? (lambda ()
               (jolt-sim-project-ffi-descriptor
                (list (cons 'kind 'native-operation)
                      (cons 'operation "read-array!")
                      (cons 'arguments (list 1 2 3)))))))

;; Complete config validation precedes every public mutation.
(define pristine (controller-state))
(ok "missing complete config key is rejected"
    (raises? (lambda ()
               (jolt-sim-install-controller!
                (jolt-hash-map (kw "future") quiet-future
                               (kw "ffi") native-ffi)))))
(ok "invalid config leaves all controller state unchanged"
    (same-state? pristine (controller-state)))
(ok "wrong callback arity is rejected"
    (raises? (lambda ()
               (jolt-sim-install-controller!
                (controller-config (lambda (_) jolt-nil)
                                   native-ffi native-clock)))))
(ok "arity rejection leaves all controller state unchanged"
    (same-state? pristine (controller-state)))

;; One token stack owns future+FFI+clock. Nested/out-of-order/stale/foreign
;; restores validate every state before mutating any of it.
(define outer-future (lambda (event id parent) jolt-nil))
(define inner-future (lambda (event id parent) jolt-nil))
(define outer
  (jolt-sim-install-controller!
   (controller-config outer-future (lambda (_ __) 111) (lambda (_ __) 1000))))
(define outer-state (controller-state))
(ok "outer unified install owns all three states"
    (and (eq? (jolt-sim-current-future-controller) outer-future)
         (= 111 (ffi-sim-alloc 1)) (= 1000 (jolt-mono-nanos))))
(ok "invalid nested complete config is rejected before mutation"
    (raises? (lambda ()
               (jolt-sim-install-controller!
                (controller-config quiet-future (lambda (_) 7) native-clock)))))
(ok "invalid nested config preserves the active composite"
    (same-state? outer-state (controller-state)))
(define inner
  (jolt-sim-install-controller!
   (controller-config inner-future (lambda (_ __) 222) (lambda (_ __) 2000))))
(define inner-state (controller-state))
(ok "inner unified install replaces all three states"
    (and (eq? (jolt-sim-current-future-controller) inner-future)
         (= 222 (ffi-sim-alloc 1)) (= 2000 (jolt-mono-nanos))))
(ok "out-of-order restore is rejected" (raises? (lambda () (jolt-sim-restore-controller! outer))))
(ok "out-of-order restore mutates no controller state" (same-state? inner-state (controller-state)))
(ok "foreign token is rejected" (raises? (lambda () (jolt-sim-restore-controller! (vector 'foreign)))))
(ok "foreign token mutates no controller state" (same-state? inner-state (controller-state)))
(jolt-sim-restore-controller! inner)
(ok "nested restore reinstates all outer state"
    (and (same-state? outer-state (controller-state))
         (= 111 (ffi-sim-alloc 1))))
(define after-inner (controller-state))
(ok "stale token is rejected" (raises? (lambda () (jolt-sim-restore-controller! inner))))
(ok "stale token mutates no controller state" (same-state? after-inner (controller-state)))
(jolt-sim-restore-controller! outer)
(ok "outer restore returns the complete pristine state" (same-state? pristine (controller-state)))

;; Concurrent accessor discriminator. Readers accept only no public controller
;; or one complete outer/inner identity triple from a single immutable token.
(define stress-mu (make-mutex))
(define stress-cv (make-condition))
(define stress-start? #f)
(define stress-stop? #f)
(define stress-done 0)
(define stress-bad? #f)
(define stress-saw-outer? #f)
(define stress-saw-inner? #f)
(define stress-outer-future (lambda (e i p) jolt-nil))
(define stress-inner-future (lambda (e i p) jolt-nil))
(define stress-outer-ffi (lambda (d p) 1))
(define stress-inner-ffi (lambda (d p) 2))
(define stress-outer-clock (lambda (d p) 10))
(define stress-inner-clock (lambda (d p) 20))
(define (stress-stopped?) (with-mutex stress-mu stress-stop?))
(define (stress-triple? snap f ffi clock)
  (and (pair? snap) (= 3 (length snap))
       (eq? (list-ref snap 0) f) (eq? (list-ref snap 1) ffi)
       (eq? (list-ref snap 2) clock)))
(define (stress-reader)
  (guard (e (#t (with-mutex stress-mu
                    (set! stress-bad? #t)
                    (set! stress-done (+ stress-done 1))
                    (condition-broadcast stress-cv))))
    (with-mutex stress-mu
      (let ((deadline (ms->deadline 5000)))
        (let wait ()
          (unless stress-start?
            (unless (condition-wait stress-cv stress-mu deadline)
              (error 'stress "start deadline"))
            (wait)))))
    (let loop ()
      (let ((snap (jolt-sim-effective-controller-snapshot)))
        (cond
          ((not snap) #f)
          ((stress-triple? snap stress-outer-future stress-outer-ffi stress-outer-clock)
           (with-mutex stress-mu
             (set! stress-saw-outer? #t) (condition-broadcast stress-cv)))
          ((stress-triple? snap stress-inner-future stress-inner-ffi stress-inner-clock)
           (with-mutex stress-mu
             (set! stress-saw-inner? #t) (condition-broadcast stress-cv)))
          (else (with-mutex stress-mu (set! stress-bad? #t)))))
      (unless (stress-stopped?) (loop)))
    (with-mutex stress-mu
      (set! stress-done (+ stress-done 1))
      (condition-broadcast stress-cv))))
(do ((i 0 (+ i 1))) ((= i 4)) (fork-thread stress-reader))
(with-mutex stress-mu
  (set! stress-start? #t) (condition-broadcast stress-cv))
(define stress-outer-token
  (jolt-sim-install-controller!
   (controller-config stress-outer-future stress-outer-ffi stress-outer-clock)))
(define stress-outer-timeout? #f)
(with-mutex stress-mu
  (let ((deadline (ms->deadline 5000)))
    (let wait ()
      (unless stress-saw-outer?
        (unless (condition-wait stress-cv stress-mu deadline)
          (set! stress-outer-timeout? #t))
        (unless stress-outer-timeout? (wait))))))
(define stress-inner-token
  (jolt-sim-install-controller!
   (controller-config stress-inner-future stress-inner-ffi stress-inner-clock)))
(define stress-inner-timeout? #f)
(with-mutex stress-mu
  (let ((deadline (ms->deadline 5000)))
    (let wait ()
      (unless stress-saw-inner?
        (unless (condition-wait stress-cv stress-mu deadline)
          (set! stress-inner-timeout? #t))
        (unless stress-inner-timeout? (wait))))))
(jolt-sim-restore-controller! stress-inner-token)
(jolt-sim-restore-controller! stress-outer-token)
(with-mutex stress-mu
  (set! stress-stop? #t) (condition-broadcast stress-cv))
(define stress-readers-timeout? #f)
(with-mutex stress-mu
  (let ((deadline (ms->deadline 5000)))
    (let wait ()
      (unless (= stress-done 4)
        (unless (condition-wait stress-cv stress-mu deadline)
          (set! stress-readers-timeout? #t))
        (unless stress-readers-timeout? (wait))))))
(ok "concurrent composite accessors meet all deadlines"
    (not (or stress-outer-timeout? stress-inner-timeout? stress-readers-timeout?)))
(ok "concurrent readers observed both complete stack levels"
    (and stress-saw-outer? stress-saw-inner?))
(ok "concurrent accessors never observed a torn composite" (not stress-bad?))

;; One successful public install actually controls future lifecycle, raw FFI,
;; and both central monotonic surfaces together.
(define event-mu (make-mutex))
(define event-cv (make-condition))
(define events '())
(define (combined-future event id parent)
  (with-mutex event-mu
    (set! events (cons event events))
    (condition-broadcast event-cv))
  jolt-nil)
(define combined
  (jolt-sim-install-controller!
   (controller-config combined-future (lambda (_ __) 333) (lambda (_ __) 444))))
(define combined-f (jolt-sim-future-call (lambda () 42)))
(define combined-timeout (list 'combined-timeout))
(ok "unified future controller preserves body result within deadline"
    (equal? 42 (jolt-future-deref-timed combined-f 5000 combined-timeout)))
(define combined-exit-timeout? #f)
(with-mutex event-mu
  (let ((deadline (ms->deadline 5000)))
    (let wait ()
      (unless (memq fhk-exit events)
        (unless (condition-wait event-cv event-mu deadline)
          (set! combined-exit-timeout? #t))
        (unless combined-exit-timeout? (wait))))))
(ok "future exit acknowledgement arrived within deadline" (not combined-exit-timeout?))
(ok "one install controls future lifecycle" (and (memq fhk-spawn events) (memq fhk-exit events)))
(ok "one install controls raw FFI" (= 333 (ffi-sim-alloc 1)))
(ok "one install controls System/nanoTime" (= 444 (jolt-mono-nanos)))
(ok "one install controls jolt.host monotonic source"
    (= 444 ((var-deref "jolt.host" "mono-nanos"))))
(ok "supervisor monotonic bypass remains native"
    (not (= 444 (jnum->exact (jolt-sim-supervisor-mono-nanos)))))
(jolt-sim-restore-controller! combined)

(define clock-values (box '(100 100 99)))
(define clock-token
  (install native-ffi
           (lambda (_ proceed)
             (let ((n (car (unbox clock-values))))
               (set-box! clock-values (cdr (unbox clock-values))) n))))
(ok "modeled clock accepts exact nondecreasing nanoseconds" (= 100 (jolt-mono-nanos)))
(ok "modeled clock accepts an equal nanosecond value" (= 100 (jolt-mono-nanos)))
(ok "modeled clock rejects a backward value" (raises? jolt-mono-nanos))
(jolt-sim-restore-controller! clock-token)
(define invalid-clock-token (install native-ffi (lambda (_ __) (kw "not-nanos"))))
(ok "modeled clock rejects a non-integer result" (raises? jolt-mono-nanos))
(jolt-sim-restore-controller! invalid-clock-token)

;; Domain discriminator: every controller in ONE nested composite stack shares
;; the outermost scope's monotonic domain. An outer clock advances the shared
;; domain, an inner clock advances it further, and restoring back to the outer
;; controller does not reset that shared domain — a smaller value the outer
;; closure now reports must fail closed exactly like any other regression. A
;; wholly new outermost install (installed only after every earlier composite
;; has fully restored) owns a fresh domain and may start at any virtual
;; origin, including zero.
(define domain-outer-token (install native-ffi (lambda (_ __) 1000)))
(ok "domain outer accepts its first exact value" (= 1000 (jolt-mono-nanos)))
(define domain-inner-token (install native-ffi (lambda (_ __) 2000)))
(ok "domain inner advances the one shared domain" (= 2000 (jolt-mono-nanos)))
(jolt-sim-restore-controller! domain-inner-token)
(ok "restored outer sharing the nested domain fails closed on regression"
    (raises? jolt-mono-nanos))
(jolt-sim-restore-controller! domain-outer-token)
(define domain-fresh-token (install native-ffi (lambda (_ __) 0)))
(ok "a new outermost scope may restart the domain at virtual zero"
    (= 0 (jolt-mono-nanos)))
(jolt-sim-restore-controller! domain-fresh-token)

;; Pin read-array!'s argument order and both current write-array arities without
;; allowing fake pointers to reach Chez.
(define seen '())
(define raw-token
  (install
   (lambda (d proceed)
     (set! seen (cons d seen))
     (if (eq? (mget d "operation") (kw "alloc")) 424242 0))
   native-clock))
(ok "modeled alloc bypasses native" (= 424242 (ffi-sim-alloc 8)))
(define ba (na-byte-array (jolt-vector 1 -1 3 4)))
(ffi-sim-write-array 424242 ba)
(ffi-sim-write-array 424242 ba 1 2)
(ffi-sim-read-array! 424242 2 ba 1)
(ok "read-array! args are [ptr len dest dest-off]"
    (let ((d (car seen)))
      (and (eq? (mget d "operation") (kw "read-array!"))
           (= 4 (pvec-count (mget d "arguments")))
           (eq? ba (pvec-nth-d (mget d "arguments") 2 jolt-nil)))))
(ok "write-array exposes both exact arities"
    (equal? (map (lambda (d) (pvec-count (mget d "arguments")))
                 (filter (lambda (d) (eq? (mget d "operation") (kw "write-array")))
                         (reverse seen))) '(2 4)))
(jolt-sim-restore-controller! raw-token)

;; The sim overlay must preserve ordinary Jolt IFn callback semantics. A map is
;; a valid two-argument callable (key plus not-found), even though it is not a
;; raw Scheme procedure. This discriminator catches a simulation-only narrowing
;; of with-byte-array-pointer's unchanged callback contract.
(define callable-map-ba (na-byte-array (jolt-vector 7 8 9)))
(define callable-map (ev "{}"))
(ok "no-controller byte-array loan accepts a callable map"
    (= 3 (ffi-sim-with-byte-array-pointer callable-map-ba callable-map)))
(define callable-map-token (install native-ffi native-clock))
(ok "controlled proceeded byte-array loan accepts the same callable map"
    (= 3 (ffi-sim-with-byte-array-pointer callable-map-ba callable-map)))
(jolt-sim-restore-controller! callable-map-token)

;; loaded? always publishes a Jolt Boolean, including when a modeled controller
;; naturally returns nil for a negative result. Raw Scheme truthiness would
;; incorrectly turn jolt-nil into true.
(define public-loaded? (var-deref "jolt.ffi" "loaded?"))
(ok "no-controller loaded? preserves ordinary false"
    (eq? #f (public-loaded? "jolt-sim-definitely-not-loaded")))
(define modeled-loaded-result (box jolt-nil))
(define modeled-loaded-token
  (install
   (lambda (d proceed)
     (if (eq? (mget d "operation") (kw "loaded?"))
         (unbox modeled-loaded-result)
         (jolt-invoke proceed)))
   native-clock))
(ok "controlled loaded? normalizes nil to false"
    (eq? #f (public-loaded? "modeled-library")))
(set-box! modeled-loaded-result #f)
(ok "controlled loaded? preserves false"
    (eq? #f (public-loaded? "modeled-library")))
(set-box! modeled-loaded-result #t)
(ok "controlled loaded? preserves true"
    (eq? #t (public-loaded? "modeled-library")))
(jolt-sim-restore-controller! modeled-loaded-token)

;; Side-effect-free ordinary validation runs before a modeled raw handler.
(define validation-handler-calls 0)
(define validation-token
  (install
   (lambda (d proceed)
     (set! validation-handler-calls (+ validation-handler-calls 1))
     17)
   native-clock))
(define validation-ba (na-byte-array (jolt-vector 1 2 3)))
(define validation-native-p (ffi-alloc 2))
(foreign-set! 'unsigned-8 validation-native-p 0 91)
(foreign-set! 'unsigned-8 validation-native-p 1 92)
(define fractional-array (na-double-array (jolt-vector 7.0 1.5)))
(ok "whole write-array fractional element fails before handler or native write"
    (raises? (lambda ()
               (ffi-sim-write-array validation-native-p fractional-array))))
(ok "failed whole write-array leaves the complete native range untouched"
    (and (= 91 (foreign-ref 'unsigned-8 validation-native-p 0))
         (= 92 (foreign-ref 'unsigned-8 validation-native-p 1))))
(ok "negative allocation fails before handler"
    (raises? (lambda () (ffi-sim-alloc -1))))
(ok "negative read-bytes length fails before handler"
    (raises? (lambda () (ffi-sim-read-bytes 123 -1))))
(ok "negative read-array length fails before handler"
    (raises? (lambda () (ffi-sim-read-array 123 -1))))
(ok "read type fails before handler"
    (raises? (lambda () (ffi-sim-read 123 (kw "not-a-native-type")))))
(ok "read offset fails before handler"
    (raises? (lambda () (ffi-sim-read 123 (kw "int32") :bad-offset))))
(ok "write type fails before handler"
    (raises? (lambda () (ffi-sim-write 123 (kw "not-a-native-type") 0 1))))
(ok "write offset fails before handler"
    (raises? (lambda () (ffi-sim-write 123 (kw "int32") :bad-offset 1))))
(ok "read-array! destination not a jolt-array fails before handler"
    (raises? (lambda () (ffi-sim-read-array! 123 1 (jolt-vector 0) 0))))
(ok "read-array! wrong array kind fails before handler"
    (raises? (lambda ()
               (ffi-sim-read-array! 123 1 (na-int-array (jolt-vector 1 2 3)) 0))))
(ok "read-array! range fails before handler"
    (raises? (lambda () (ffi-sim-read-array! 123 2 validation-ba 2))))
(ok "read-array! negative range fails before handler"
    (raises? (lambda () (ffi-sim-read-array! 123 -1 validation-ba 0))))
(ok "whole write-array type fails before handler"
    (raises? (lambda () (ffi-sim-write-array 123 (jolt-vector 1)))))
(ok "ranged write-array type fails before handler"
    (raises? (lambda () (ffi-sim-write-array 123 (jolt-vector 1) 0 1))))
(ok "ranged write-array wrong array kind fails before handler"
    (raises? (lambda ()
               (ffi-sim-write-array 123 (na-int-array (jolt-vector 1 2 3)) 0 1))))
(ok "ranged write-array range fails before handler"
    (raises? (lambda () (ffi-sim-write-array 123 validation-ba 3 1))))
(ok "ranged write-array negative length fails before handler"
    (raises? (lambda () (ffi-sim-write-array 123 validation-ba 0 -1))))
(ok "byte-array loan range fails before handler"
    (raises? (lambda ()
               (ffi-sim-with-byte-array-pointer
                validation-ba 3 1 (lambda (p n) jolt-nil)))))
(ok "all pinned invalid raw calls bypassed the handler" (= 0 validation-handler-calls))
;; Chez foreign-set!'s target-width value coercion is the one documented
;; provider-owned validation boundary. A model may deliberately accept a value
;; that a real native write would reject.
(ok "modeled write value coercion remains provider-owned"
    (= 17 (ffi-sim-write 123 (kw "int32") 0 (kw "modeled-value"))))
(ok "provider-owned modeled write reached handler" (= 1 validation-handler-calls))
(jolt-sim-restore-controller! validation-token)
(ffi-free validation-native-p)

;; Proceed one-shot and dynamic-extent escape rejection.
(define escaped-proceed #f)
(define twice-rejected #f)
(define proceed-token
  (install
   (lambda (d proceed)
     (set! escaped-proceed proceed)
     (let ((r (jolt-invoke proceed)))
       (set! twice-rejected (raises? (lambda () (jolt-invoke proceed)))) r))
   native-clock))
(define real-p (ffi-sim-alloc 4))
(ok "proceed is one-shot" twice-rejected)
(ok "escaped proceed is rejected" (raises? (lambda () (jolt-invoke escaped-proceed))))
(jolt-sim-restore-controller! proceed-token)
(ffi-free real-p)

;; A native thunk that throws still consumes its proceed token. The controller
;; may catch the native exception, but it cannot use the same authority to run
;; the native branch a second time.
(define throwing-proceed-consumed? #f)
(define throwing-proceed-token
  (install
   (lambda (d proceed)
     (guard (e (#t
                (set! throwing-proceed-consumed?
                      (raises? (lambda () (jolt-invoke proceed))))
                77))
       (jolt-invoke proceed)))
   native-clock))
(ok "native failure still consumes proceed"
    (= 77
       (jolt-ffi-invoke-sim-hook
        (jolt-sim-current-ffi-hook)
        (jolt-ffi-make-native-sim-descriptor "alloc" (list 1))
        (lambda () (error 'proceed-test "native failure")))))
(ok "consumed throwing proceed rejects a second invocation"
    throwing-proceed-consumed?)
(jolt-sim-restore-controller! throwing-proceed-token)

;; Synthetic synchronous-native-callback discriminator. Controller-phase FFI
;; remains rejected, but once proceed enters its native thunk a nested ordinary
;; FFI call is intercepted and may proceed under a properly nested token.
(define nested-ffi-count 0)
(define controller-reentry-rejected? #f)
(define nested-ffi-token
  (install
   (lambda (d proceed)
     (set! nested-ffi-count (+ nested-ffi-count 1))
     (when (= nested-ffi-count 1)
       (set! controller-reentry-rejected?
             (raises? (lambda () (ffi-sim-sizeof (kw "int32"))))))
     (jolt-invoke proceed))
   native-clock))
(define nested-size
  (jolt-ffi-invoke-sim-hook
   (jolt-sim-current-ffi-hook)
   (jolt-ffi-make-native-sim-descriptor "alloc" (list 1))
   (lambda () (ffi-sim-sizeof (kw "int32")))))
(ok "controller-phase nested FFI remains rejected" controller-reentry-rejected?)
(ok "native proceed permits synchronous nested FFI"
    (and (= 2 nested-ffi-count) (= nested-size (ffi-sizeof (kw "int32")))))
(jolt-sim-restore-controller! nested-ffi-token)

;; Owner-thread rejection despite inherited thread parameters.
(define owner-mu (make-mutex))
(define owner-cv (make-condition))
(define owner-done? #f)
(define owner-rejected? #f)
(define owner-token
  (install
   (lambda (d proceed)
     (fork-thread
      (lambda ()
        (let ((rejected (raises? (lambda () (jolt-invoke proceed)))))
          (with-mutex owner-mu
            (set! owner-rejected? rejected) (set! owner-done? #t)
            (condition-broadcast owner-cv)))))
     (with-mutex owner-mu
       (let ((deadline (ms->deadline 5000)))
         (let wait ()
           (unless owner-done?
             (unless (condition-wait owner-cv owner-mu deadline)
               (error 'owner-test "child deadline"))
             (wait)))))
     (jolt-invoke proceed))
   native-clock))
(define owner-p (ffi-sim-alloc 1))
(ok "proceed rejects a non-owner thread" owner-rejected?)
(jolt-sim-restore-controller! owner-token)
(ffi-free owner-p)

;; Nested clock->FFI effects enforce strict proceed LIFO.
(define outer-clock-proceed #f)
(define lifo-rejected? #f)
(define lifo-token
  (install
   (lambda (d proceed)
     (set! lifo-rejected? (raises? (lambda () (jolt-invoke outer-clock-proceed))))
     909)
   (lambda (_ proceed)
     (set! outer-clock-proceed proceed) (ffi-sim-alloc 1) (jolt-invoke proceed))))
(jolt-mono-nanos)
(ok "nested proceed tokens enforce strict LIFO" lifo-rejected?)
(jolt-sim-restore-controller! lifo-token)

;; A modeled loan release cannot native-proceed because no real lock exists.
(define modeled-release-rejected? #f)
(define modeled-loan-token
  (install
   (lambda (d proceed)
     (case (keyword-t-name (mget d "operation"))
       (("borrow-byte-array") 700001)
       (("release-byte-array")
        (set! modeled-release-rejected? (raises? (lambda () (jolt-invoke proceed))))
        jolt-nil)
       (else (jolt-invoke proceed))))
   native-clock))
(define modeled-ba (na-byte-array (jolt-vector 1 2)))
(ffi-sim-with-byte-array-pointer modeled-ba (lambda (p n) jolt-nil))
(ok "modeled loan release cannot native-proceed" modeled-release-rejected?)
(jolt-sim-restore-controller! modeled-loan-token)

;; A real staged loan release is offered once and cleans up once even when the
;; callback raises; copyback still folds unsigned 255 to signed -1.
(define real-release-count 0)
(define real-loan-tmp #f)
(define real-loan-locked-inside? #f)
(define real-loan-token
  (install
   (lambda (d proceed)
     (when (eq? (mget d "operation") (kw "release-byte-array"))
       (set! real-release-count (+ real-release-count 1)))
     (jolt-invoke proceed))
   native-clock))
(define real-ba (na-byte-array (jolt-vector 10 20 30)))
(ok "exceptional real loan callback propagates"
    (raises?
     (lambda ()
       (ffi-sim-with-byte-array-pointer
        real-ba 1 1
        (lambda (p n)
          (set! real-loan-tmp (reference-address->object p))
          (set! real-loan-locked-inside? (locked-object? real-loan-tmp))
          (foreign-set! 'unsigned-8 p 0 255)
          (error 'loan-test "callback failure"))))))
(ok "exceptional real loan release proceeds exactly once" (= 1 real-release-count))
(ok "exceptional staged cleanup copies back signed bytes"
    (= -1 (vector-ref (jolt-array-vec real-ba) 1)))
(ok "exceptional staged cleanup unlocks its exact temporary"
    (and real-loan-locked-inside?
         (bytevector? real-loan-tmp)
         (not (locked-object? real-loan-tmp))))
(jolt-sim-restore-controller! real-loan-token)

(define observer-release-count 0)
(define observer-loan-tmp #f)
(define observer-loan-locked-inside? #f)
(define observer-token
  (install
   (lambda (d proceed)
     (if (eq? (mget d "operation") (kw "release-byte-array"))
         (begin (set! observer-release-count (+ observer-release-count 1))
                (error 'loan-observer "release observer failure"))
         (jolt-invoke proceed)))
   native-clock))
(define observer-ba (na-byte-array (jolt-vector 4 5)))
(ok "release observer exception propagates after forced cleanup"
    (raises? (lambda ()
               (ffi-sim-with-byte-array-pointer
                observer-ba
                (lambda (p n)
                  (set! observer-loan-tmp (reference-address->object p))
                  (set! observer-loan-locked-inside?
                        (locked-object? observer-loan-tmp))
                  (foreign-set! 'unsigned-8 p 0 254))))))
(ok "throwing release observer was invoked exactly once" (= 1 observer-release-count))
(ok "throwing release observer still copied back signed bytes"
    (= -2 (vector-ref (jolt-array-vec observer-ba) 0)))
(ok "throwing release observer unlocks its exact temporary"
    (and observer-loan-locked-inside?
         (bytevector? observer-loan-tmp)
         (not (locked-object? observer-loan-tmp))))
(jolt-sim-restore-controller! observer-token)

;; A release observer may deliberately model release without native-proceed.
;; Core still owns the real proceeded temporary and must force its copyback and
;; unlock exactly once after the observer returns.
(define skipped-release-count 0)
(define skipped-release-tmp #f)
(define skipped-release-locked-inside? #f)
(define skipped-release-token
  (install
   (lambda (d proceed)
     (if (eq? (mget d "operation") (kw "release-byte-array"))
         (begin (set! skipped-release-count (+ skipped-release-count 1)) jolt-nil)
         (jolt-invoke proceed)))
   native-clock))
(define skipped-release-ba (na-byte-array (jolt-vector 1 2)))
(ffi-sim-with-byte-array-pointer
 skipped-release-ba
 (lambda (p n)
   (set! skipped-release-tmp (reference-address->object p))
   (set! skipped-release-locked-inside? (locked-object? skipped-release-tmp))
   (foreign-set! 'unsigned-8 p 0 253)))
(ok "modeled release observer runs once without native-proceed"
    (= 1 skipped-release-count))
(ok "release-without-proceed still copies back"
    (= -3 (vector-ref (jolt-array-vec skipped-release-ba) 0)))
(ok "release-without-proceed unlocks its exact temporary"
    (and skipped-release-locked-inside?
         (bytevector? skipped-release-tmp)
         (not (locked-object? skipped-release-tmp))))
(jolt-sim-restore-controller! skipped-release-token)

;; If a controller proceeds the real borrow but substitutes a different pointer,
;; fail before the callback and release the exact temporary it just created.
(define substituted-pointer-tmp #f)
(define substituted-pointer-locked-inside? #f)
(define substituted-pointer-callback-count 0)
(define substituted-pointer-token
  (install
   (lambda (d proceed)
     (if (eq? (mget d "operation") (kw "borrow-byte-array"))
         (let ((p (jolt-invoke proceed)))
           (set! substituted-pointer-tmp (reference-address->object p))
           (set! substituted-pointer-locked-inside?
                 (locked-object? substituted-pointer-tmp))
           (+ p 1))
         (jolt-invoke proceed)))
   native-clock))
(define substituted-pointer-ba (na-byte-array (jolt-vector 8)))
(ok "controller cannot substitute a proceeded loan pointer"
    (raises?
     (lambda ()
       (ffi-sim-with-byte-array-pointer
        substituted-pointer-ba
        (lambda (p n)
          (set! substituted-pointer-callback-count
                (+ substituted-pointer-callback-count 1)))))))
(ok "pointer substitution rejects before callback"
    (= 0 substituted-pointer-callback-count))
(ok "pointer-substitution failure unlocks its exact temporary"
    (and substituted-pointer-locked-inside?
         (bytevector? substituted-pointer-tmp)
         (not (locked-object? substituted-pointer-tmp))))
(jolt-sim-restore-controller! substituted-pointer-token)

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
