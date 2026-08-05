;; Sim controller bridge gate (host/chez/sim/runtime.ss, composite ABI 6 with
;; FFI descriptor version 8).
;; The overlay installs one persistent bridge through the canonical
;; declared-call seam and this gate drives declared calls AND raw native ops
;; through that bridge, so run it against a fresh transient seed through
;; host/chez/transient-seed-gate.sh:
;;
;;   CHEZ=/path/to/chez sh host/chez/transient-seed-gate.sh \
;;     test/chez/sim-controller-bridge-test.ss
;;
;; The wrapper passes the fresh PRELUDE and IMAGE as the two script arguments.

(import (chezscheme))

(define seed-args (cdr (command-line)))
(unless (= (length seed-args) 2)
  (display "usage: sim-controller-bridge-test.ss PRELUDE IMAGE\n"
           (current-error-port))
  (exit 2))

(load "host/chez/rt.ss")
(set-chez-ns! "clojure.core")
(load (car seed-args))
(load "host/chez/post-prelude.ss")
(set-chez-ns! "user")
(load "host/chez/host-contract.ss")
(load (cadr seed-args))
(load "host/chez/compile-eval.ss")
(load "host/chez/loader.ss")
(set-source-roots! ldr-install-roots)
(load "host/chez/java/ffi.ss")
(load "host/chez/sim/runtime.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a~n" name)))
(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))
(define (ev source) (jolt-compile-eval source "user"))
(define (kw s) (keyword #f s))
(define (mget m s) (jolt-get m (kw s)))
(define (controller-config future ffi clock)
  (jolt-hash-map (kw "future") future (kw "ffi") ffi (kw "clock") clock))
(define (quiet-future event id parent) jolt-nil)
(define (native-ffi descriptor proceed) (jolt-invoke proceed))
(define (native-clock descriptor proceed) (jolt-invoke proceed))
(define (install ffi clock)
  (jolt-sim-install-controller! (controller-config quiet-future ffi clock)))

;; Real declared bindings plus two deliberately unresolvable ones. Defining a
;; binding stays lazy; a ghost only reaches native resolution through an exact
;; proceed.
(ev "(require '[jolt.ffi :as ffi])")
(ev "(ffi/load-library)")
(ev "(ffi/defcfn c-bridge-abs \"abs\" [:int] :int)")
(ev "(ffi/defcfn c-bridge-cap-abs \"abs\" [:int] :int {:capture-native-error true})")
(ev "(ffi/defcfn c-bridge-ghost \"definitely_not_a_real_c_symbol_bridge_zzz9\" [:int :int] :int {:blocking true})")
(ev "(ffi/defcfn c-bridge-ghost-cap \"definitely_not_a_real_c_symbol_bridge_cap_zzz9\" [] :int {:capture-native-error true})")

;; --- A. persistent bridge + exact advertised ABI ------------------------------
(ok "overlay installs the bridge as the current canonical hook"
    (eq? jolt-ffi-declared-call-hook jolt-sim-ffi-bridge))
(ok "bridge installation is the canonical stack top"
    (eq? jolt-ffi-declared-call-hook-top jolt-sim-ffi-bridge-installation))
(ok "bridge installation has no predecessor"
    (not (jolt-ffi-declared-call-hook-installation-previous
          jolt-sim-ffi-bridge-installation)))
(ok "no composite controller is installed at boot" (not jolt-sim-controller-top))

(define caps (jolt-sim-capabilities))
(ok "controller ABI is exactly prerelease 6" (= 6 (mget caps "abi-version")))
(ok "FFI descriptor is exactly 8"
    (= 8 (mget (mget caps "ffi-interception") "descriptor-version")))
(ok "clock descriptor is exactly 1"
    (= 1 (mget (mget caps "clock-interception") "descriptor-version")))
(ok "public installation descriptor names one exact complete config"
    (equal? (vector->list (pvec-v (mget (mget caps "installation")
                                      "configuration-keys")))
            (map kw '("future" "ffi" "clock"))))
(ok "raw-op registry is exact, ordered, and excludes borrow/release"
    (equal? (vector->list (pvec-v (mget (mget caps "ffi-interception")
                                      "native-operations")))
            (map kw '("load-library" "loaded?" "alloc" "free" "read" "write"
                      "sizeof" "null?" "read-bytes" "write-bytes" "read-array"
                      "read-array!" "write-array" "ptr->string"
                      "string->ptr"))))
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
        :ffi-interception {:descriptor-version 8
                           :kinds [:foreign-function :native-operation]
                           :arguments :live
                           :task-identity :future-lifecycle
                           :native-operations [:load-library :loaded? :alloc :free
                                               :read :write :sizeof :null?
                                               :read-bytes :write-bytes :read-array
                                               :read-array! :write-array
                                               :ptr->string :string->ptr]
                           :proceed-routing {:controller-arity 2 :proceed-arity 0
                                             :single-use true :dynamic-extent true
                                             :owner-thread true :lifo true
                                             :scoped-byte-array-release :runtime-owned}
                           :scoped-byte-array-view
                           {:operations [:read-active-byte-array-view
                                         :write-active-byte-array-view!]
                            :read-arity 2 :write-arity 2
                            :owner-thread true :dynamic-extent true
                            :runtime-owned true}}
        :clock-interception {:descriptor-version 1
                             :operations [:mono-nanos]
                             :result :exact-integer-nanoseconds
                             :nondecreasing? true
                             :supervisor-operation :supervisor-mono-nanos
                             :proceed-routing {:controller-arity 2 :proceed-arity 0
                                               :single-use true :dynamic-extent true
                                               :owner-thread true :lifo true}}}"))
(ok "capability map matches the one exact ABI 6 / descriptor 8 contract"
    (jolt=2 caps expected-capabilities))
(ok "sim public ABI exports no independent subcontroller installers"
    (for-all
     (lambda (name) (not (var-cell-lookup "jolt.internal.sim" name)))
     '("install-ffi-controller!" "install-ffi-routing-controller!"
       "restore-ffi-controller!" "install-clock-controller!"
       "install-clock-routing-controller!" "restore-clock-controller!")))

;; --- B. no controller: the bridge invokes exact proceed -----------------------
(ok "no-controller declared call reaches the real native binding"
    (= 9 (jnum->exact (ev "(c-bridge-abs -9)"))))
(ok "no-controller ghost declared call reaches real symbol resolution"
    (raises? (lambda () (ev "(c-bridge-ghost 1 2)"))))
(ok "no-controller raw roundtrip uses real memory"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 8)]
            (ffi/write p :int 0 -7)
            (let [v (ffi/read p :int)]
              (ffi/free p)
              (= v -7)))")))
(ok "no-controller null?/sizeof answer for real"
    (jolt-truthy?
     (ev "(and (ffi/null? ffi/null) (not (ffi/null? 16)) (= 4 (ffi/sizeof :int)))")))
(ok "no-controller loaded? is really false for an unknown library"
    (eq? #f ((var-deref "jolt.ffi" "loaded?") "jolt-sim-bridge-never-loaded")))
(ok "no-controller clock is the real monotonic source"
    (let ((a (jolt-mono-nanos)) (b (jolt-mono-nanos)))
      (and (integer? a) (exact? a) (>= b a))))
(ok "no-controller future allocates no simulation id"
    (and (= 42 (jnum->exact (ev "(deref (future (+ 20 22)))")))
         (= 1 (unbox jolt-future-next-id))))

;; --- C. projection: exact shapes, fail-closed malformed ------------------------
(define (project-foreign csym argtypes rettype blocking capture args)
  (jolt-sim-project-ffi-descriptor
   (list (cons 'kind 'foreign-call)
         (cons 'csym csym)
         (cons 'argtypes argtypes)
         (cons 'rettype rettype)
         (cons 'blocking blocking)
         (cons 'capture-native-error capture)
         (cons 'args args))))
(define (project-native op args)
  (jolt-sim-project-ffi-descriptor
   (list (cons 'kind 'native-op) (cons 'op op) (cons 'args args))))

(define fixed-foreign (project-foreign "fixed" '("int") "int" #f #f (list 7)))
(ok "fixed foreign projection carries exact nil variadic boundary"
    (jolt-nil? (mget fixed-foreign "varargs-after")))
(ok "foreign projection kind and renamed fields"
    (and (eq? (mget fixed-foreign "kind") (kw "foreign-function"))
         (string=? "fixed" (mget fixed-foreign "symbol"))
         (equal? (vector->list (pvec-v (mget fixed-foreign "argument-types")))
                 (list (kw "int")))
         (eq? (mget fixed-foreign "return-type") (kw "int"))
         (eq? #f (mget fixed-foreign "blocking?"))
         (eq? #f (mget fixed-foreign "capture-native-error?"))
         (= 0 (mget fixed-foreign "task"))
         (= 1 (pvec-count (mget fixed-foreign "arguments")))
         (= 7 (pvec-nth-d (mget fixed-foreign "arguments") 0 jolt-nil))))
(ok "native projection kind, operation, task, arguments"
    (let ((d (project-native "read" (list 5 (kw "int") 0))))
      (and (eq? (mget d "kind") (kw "native-operation"))
           (eq? (mget d "operation") (kw "read"))
           (= 0 (mget d "task"))
           (= 3 (pvec-count (mget d "arguments"))))))

;; Every operation of the current 15-op set at every valid arity is accepted.
(define valid-native-cases
  '(("load-library" 0) ("load-library" 1)
    ("loaded?" 1) ("alloc" 1) ("free" 1)
    ("read" 2) ("read" 3) ("write" 4) ("sizeof" 1) ("null?" 1)
    ("read-bytes" 2) ("write-bytes" 2)
    ("read-array" 2) ("read-array!" 4)
    ("write-array" 2) ("write-array" 4)
    ("ptr->string" 1) ("string->ptr" 1)))
(ok "all 15 operations project at every current valid arity"
    (for-all (lambda (case)
               (guard (e (#t #f))
                 (project-native (car case)
                                 (make-list (cadr case) 0))
                 #t))
             valid-native-cases))
;; …and every other arity of each operation fails closed.
(define invalid-native-cases
  '(("load-library" 2) ("loaded?" 0) ("loaded?" 2)
    ("alloc" 0) ("alloc" 2) ("free" 0) ("free" 2)
    ("read" 1) ("read" 4) ("write" 3) ("write" 5)
    ("sizeof" 0) ("sizeof" 2) ("null?" 0) ("null?" 2)
    ("read-bytes" 1) ("read-bytes" 3)
    ("write-bytes" 1) ("write-bytes" 3)
    ("read-array" 1) ("read-array" 3)
    ("read-array!" 3) ("read-array!" 5)
    ("write-array" 1) ("write-array" 3) ("write-array" 5)
    ("ptr->string" 0) ("ptr->string" 2)
    ("string->ptr" 0) ("string->ptr" 2)))
(ok "every invalid native arity fails closed"
    (for-all (lambda (case)
               (raises? (lambda ()
                          (project-native (car case)
                                          (make-list (cadr case) 0)))))
             invalid-native-cases))
(ok "scoped-loan operations are excluded from the operation set"
    (and (raises? (lambda () (project-native "borrow-byte-array" (list 1 2 3))))
         (raises? (lambda () (project-native "release-byte-array" (list 1))))))
(ok "unknown native operation fails closed"
    (raises? (lambda () (project-native "ghost" '()))))
(ok "non-string operation fails closed"
    (raises? (lambda () (project-native (kw "alloc") (list 1)))))
(ok "non-list native arguments fail closed"
    (raises? (lambda () (project-native "alloc" 1))))
(ok "descriptor with a non-pair element fails closed"
    (raises? (lambda ()
               (jolt-sim-project-ffi-descriptor
                (list (cons 'kind 'native-op) 'op (cons 'args '()))))))
(ok "native descriptor with reordered keys fails closed"
    (raises? (lambda ()
               (jolt-sim-project-ffi-descriptor
                (list (cons 'op "alloc") (cons 'kind 'native-op)
                      (cons 'args (list 1)))))))
(ok "foreign descriptor with reordered keys fails closed"
    (raises? (lambda ()
               (jolt-sim-project-ffi-descriptor
                (list (cons 'csym "x") (cons 'kind 'foreign-call)
                      (cons 'argtypes '()) (cons 'rettype "int")
                      (cons 'blocking #f) (cons 'capture-native-error #f)
                      (cons 'args '()))))))
(ok "foreign kind mismatch fails closed"
    (raises? (lambda ()
               (jolt-sim-project-ffi-descriptor
                (list (cons 'kind 'native-op) (cons 'csym "x")
                      (cons 'argtypes '()) (cons 'rettype "int")
                      (cons 'blocking #f) (cons 'capture-native-error #f)
                      (cons 'args '()))))))
(ok "non-string csym fails closed"
    (raises? (lambda () (project-foreign 1 '("int") "int" #f #f (list 1)))))
(ok "non-list argtypes fails closed"
    (raises? (lambda () (project-foreign "x" "int" "int" #f #f (list 1)))))
(ok "non-string argtype element fails closed"
    (raises? (lambda () (project-foreign "x" (list (kw "int")) "int" #f #f (list 1)))))
(ok "non-string rettype fails closed"
    (raises? (lambda () (project-foreign "x" '("int") (kw "int") #f #f (list 1)))))
(ok "non-boolean blocking flag fails closed"
    (raises? (lambda () (project-foreign "x" '("int") "int" 0 #f (list 1)))))
(ok "non-boolean capture flag fails closed"
    (raises? (lambda () (project-foreign "x" '("int") "int" #f 0 (list 1)))))
(ok "non-list foreign arguments fail closed"
    (raises? (lambda () (project-foreign "x" '("int") "int" #f #f 1))))
(ok "argument count must equal argtype count"
    (and (raises? (lambda () (project-foreign "x" '("int") "int" #f #f (list 1 2))))
         (raises? (lambda () (project-foreign "x" '("int" "int") "int" #f #f (list 1))))))
(ok "superseded descriptor shape fails closed"
    (raises? (lambda ()
               (jolt-sim-project-ffi-descriptor
                (list (cons 'symbol "old")
                      (cons 'argument-types '("int"))
                      (cons 'return-type "int")
                      (cons 'blocking? #f)
                      (cons 'capture-native-error? #f)
                      (cons 'varargs-after #f)
                      (cons 'arguments (list 1)))))))

;; Malformed descriptors fail through the bridge before handler or proceed.
(define malformed-seen 0)
(define malformed-proceed-used? #f)
(define malformed-token
  (install (lambda (d proceed) (set! malformed-seen (+ malformed-seen 1)) 1)
           native-clock))
(ok "malformed bridge input raises"
    (raises? (lambda ()
               (jolt-sim-ffi-bridge
                (list (cons 'kind 'native-op) (cons 'op "ghost") (cons 'args '()))
                (lambda () (set! malformed-proceed-used? #t) 9)))))
(ok "malformed foreign-count bridge input raises"
    (raises? (lambda ()
               (jolt-sim-ffi-bridge
                (list (cons 'kind 'foreign-call) (cons 'csym "x")
                      (cons 'argtypes '("int")) (cons 'rettype "int")
                      (cons 'blocking #f) (cons 'capture-native-error #f)
                      (cons 'args (list 1 2)))
                (lambda () (set! malformed-proceed-used? #t) 9)))))
(ok "malformed input never reached the controller" (= 0 malformed-seen))
(ok "malformed input never ran proceed" (not malformed-proceed-used?))
(jolt-sim-restore-controller! malformed-token)

;; --- D. atomic install/restore + strict LIFO -----------------------------------
(define (controller-state)
  (list jolt-sim-controller-top jolt-ffi-declared-call-hook
        jolt-ffi-declared-call-hook-top))
(define pristine (controller-state))
(ok "missing complete config key is rejected"
    (raises? (lambda ()
               (jolt-sim-install-controller!
                (jolt-hash-map (kw "future") quiet-future (kw "ffi") native-ffi)))))
(ok "extra config key is rejected"
    (raises? (lambda ()
               (jolt-sim-install-controller!
                (jolt-assoc (controller-config quiet-future native-ffi native-clock)
                            (kw "extra") 1)))))
(ok "invalid config leaves all controller state unchanged"
    (equal? pristine (controller-state)))
(ok "wrong future arity is rejected"
    (raises? (lambda ()
               (jolt-sim-install-controller!
                (controller-config (lambda (_ __) jolt-nil) native-ffi native-clock)))))
(ok "wrong ffi arity is rejected"
    (raises? (lambda ()
               (jolt-sim-install-controller!
                (controller-config quiet-future (lambda (_) 1) native-clock)))))
(ok "wrong clock arity is rejected"
    (raises? (lambda ()
               (jolt-sim-install-controller!
                (controller-config quiet-future native-ffi (lambda (_) 1))))))
(ok "arity rejections leave all controller state unchanged"
    (equal? pristine (controller-state)))

(define outer-future (lambda (event id parent) jolt-nil))
(define inner-future (lambda (event id parent) jolt-nil))
(define outer
  (jolt-sim-install-controller!
   (controller-config outer-future (lambda (_ __) 111) (lambda (_ __) 1000))))
(define outer-state (controller-state))
(ok "outer unified install owns all three controllers"
    (and (eq? (jolt-sim-current-future-controller) outer-future)
         (= 111 (ffi-alloc 1))
         (= 1000 (jolt-mono-nanos))))
(ok "install changes only the one composite pointer"
    (and (eq? jolt-ffi-declared-call-hook jolt-sim-ffi-bridge)
         (eq? jolt-ffi-declared-call-hook-top jolt-sim-ffi-bridge-installation)))
(ok "invalid nested complete config is rejected before mutation"
    (raises? (lambda ()
               (jolt-sim-install-controller!
                (controller-config quiet-future (lambda (_) 7) native-clock)))))
(ok "invalid nested config preserves the active composite"
    (equal? outer-state (controller-state)))
(define inner
  (jolt-sim-install-controller!
   (controller-config inner-future (lambda (_ __) 222) (lambda (_ __) 2000))))
(define inner-state (controller-state))
(ok "inner unified install replaces all three controllers"
    (and (eq? (jolt-sim-current-future-controller) inner-future)
         (= 222 (ffi-alloc 1))
         (= 2000 (jolt-mono-nanos))))
(ok "out-of-order restore is rejected" (raises? (lambda () (jolt-sim-restore-controller! outer))))
(ok "out-of-order restore mutates no controller state" (equal? inner-state (controller-state)))
(ok "foreign token is rejected" (raises? (lambda () (jolt-sim-restore-controller! (vector 'foreign)))))
(ok "foreign token mutates no controller state" (equal? inner-state (controller-state)))
(jolt-sim-restore-controller! inner)
(ok "nested restore reinstates the complete outer composite"
    (and (equal? outer-state (controller-state)) (= 111 (ffi-alloc 1))))
(define after-inner (controller-state))
(ok "stale token is rejected" (raises? (lambda () (jolt-sim-restore-controller! inner))))
(ok "stale token mutates no controller state" (equal? after-inner (controller-state)))
(jolt-sim-restore-controller! outer)
(ok "outer restore returns the complete pristine state"
    (equal? pristine (controller-state)))
(ok "restore never touched the canonical hook stack"
    (eq? jolt-ffi-declared-call-hook-top jolt-sim-ffi-bridge-installation))

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

;; --- E. future lifecycle: ids, events, drain, error latch ----------------------
(define event-mu (make-mutex))
(define event-cv (make-condition))
(define events '())
(define (record-event! event id parent)
  (with-mutex event-mu
    (set! events (cons (list event id parent) events))
    (condition-broadcast event-cv)))
(define (events-for id)
  (with-mutex event-mu
    (reverse (filter (lambda (e) (= (cadr e) id)) events))))
(define (await-event pred)
  (with-mutex event-mu
    (let ((deadline (ms->deadline 5000)))
      (let wait ()
        (unless (pred events)
          (unless (condition-wait event-cv event-mu deadline)
            (error 'event-test "event deadline"))
          (wait))))))
(define lifecycle-token
  (jolt-sim-install-controller!
   (controller-config record-event! native-ffi native-clock)))
(define life-f (jolt-sim-future-call (lambda () 42)))
(define life-timeout (list 'life-timeout))
(ok "controlled future preserves body result within deadline"
    (equal? 42 (jolt-future-deref-timed life-f 5000 life-timeout)))
(define life-id (jolt-hooked-future-task-id life-f))
(await-event (lambda (es) (memq fhk-exit (map car es))))
(define life-events (events-for life-id))
(ok "controlled future fires the complete ordered lifecycle"
    (equal? (map car life-events) (list fhk-spawn fhk-start fhk-finish fhk-exit)))
(ok "task id is positive and parent is primordial"
    (and (> life-id 0) (equal? '() (filter (lambda (e) (not (= (caddr e) 0))) life-events))))
(ok "jolt future var path rides the same controlled lifecycle"
    (= 7 (jnum->exact (ev "(deref (future (+ 3 4)))"))))
(await-event (lambda (es) (<= 2 (length (filter (lambda (e) (eq? (car e) fhk-exit)) es)))))
(ok "task ids are unique and strictly increasing per spawn"
    (let ((spawn-ids (with-mutex event-mu
                       (map cadr (filter (lambda (e) (eq? (car e) fhk-spawn))
                                         (reverse events))))))
      (let loop ((xs spawn-ids))
        (or (null? (cdr xs))
            (and (> (cadr xs) (car xs)) (loop (cdr xs)))))))

;; Nested futures: child parent is the outer task id, and FFI descriptors
;; inside a task carry that task id.
(define nested-descriptor-tasks '())
(define nested-ffi-token
  (jolt-sim-install-controller!
   (controller-config
    record-event!
    (lambda (d proceed)
      (set! nested-descriptor-tasks
            (cons (mget d "task") nested-descriptor-tasks))
      64)
    native-clock)))
(define inner-spawn-parents '())
(define outer-f
  (jolt-sim-future-call
   (lambda ()
     (ffi-sizeof (kw "int"))
     (let ((inner (jolt-sim-future-call (lambda () (ffi-sizeof (kw "int")) 1))))
       (jolt-future-deref inner)))))
(define outer-id (jolt-hooked-future-task-id outer-f))
(jolt-future-deref outer-f)
(await-event (lambda (es)
               (<= 2 (length (filter (lambda (e) (eq? (car e) fhk-exit)) es)))))
(define spawn-events
  (with-mutex event-mu
    (filter (lambda (e) (and (eq? (car e) fhk-spawn) (> (cadr e) outer-id)))
            events)))
(ok "nested future reports the outer task id as parent"
    (and (pair? spawn-events)
         (for-all (lambda (e) (= (caddr e) outer-id)) spawn-events)))
(ok "FFI descriptors carry the actual current task id"
    (and (memq outer-id nested-descriptor-tasks)
         (for-all (lambda (t) (not (= 0 t))) nested-descriptor-tasks)))
(jolt-sim-restore-controller! nested-ffi-token)

;; :start gating: the controller parks a worker until released, then cancel
;; wins the terminal race; :exit still acknowledges after publication.
(define gate-mu (make-mutex))
(define gate-cv (make-condition))
(define gate-allowed '())
(define gate-events '())
(define (gate-record! event id parent)
  (with-mutex gate-mu
    (set! gate-events (cons (list event id parent) gate-events))
    (condition-broadcast gate-cv)))
(define (gate-hook event id parent)
  (gate-record! event id parent)
  (when (eq? event fhk-start)
    (with-mutex gate-mu
      (let ((deadline (ms->deadline 10000)))
        (let wait ()
          (unless (memv id gate-allowed)
            (unless (condition-wait gate-cv gate-mu deadline)
              (error 'gate-test "start permit deadline"))
            (wait))))))
  jolt-nil)
(define gate-token
  (jolt-sim-install-controller!
   (controller-config gate-hook native-ffi native-clock)))
(define gate-body-ran? #f)
(define gate-f (jolt-sim-future-call (lambda () (set! gate-body-ran? #t) 5)))
(define gate-id (jolt-hooked-future-task-id gate-f))
;; Observe the worker parked at :start before cancelling, so the recorded
;; lifecycle order is deterministic.
(with-mutex gate-mu
  (let ((deadline (ms->deadline 5000)))
    (let wait ()
      (unless (memq fhk-start (map car gate-events))
        (unless (condition-wait gate-cv gate-mu deadline)
          (error 'gate-test "start deadline"))
        (wait)))))
;; The worker is parked at :start: cancellation must win before the body runs.
(ok "future-cancel wins while the worker is gated at :start"
    (eq? #t (jolt-sim-future-cancel gate-f)))
(ok "cancelled controlled future raises from deref"
    (raises? (lambda () (jolt-future-deref gate-f))))
(ok "cancelled controlled future reports cancelled?"
    (jolt-native-future-cancelled? gate-f))
(with-mutex gate-mu
  (set! gate-allowed (cons gate-id gate-allowed))
  (condition-broadcast gate-cv))
(with-mutex gate-mu
  (let ((deadline (ms->deadline 5000)))
    (let wait ()
      (unless (memq fhk-exit (map car gate-events))
        (unless (condition-wait gate-cv gate-mu deadline)
          (error 'gate-test "exit deadline"))
        (wait)))))
(define gate-id-events
  (with-mutex gate-mu
    (reverse (filter (lambda (e) (= (cadr e) gate-id)) gate-events))))
(ok "gated task lifecycle is spawn,start,cancel,exit with cancel before exit"
    (equal? (map car gate-id-events)
            (list fhk-spawn fhk-start fhk-cancel fhk-exit)))
(ok "cancelled body still ran after release (worker is non-interruptible)"
    gate-body-ran?)
(jolt-sim-restore-controller! gate-token)

;; :start failure is captured as the future's failure; the body never runs,
;; deref raises, the error is latched, and :exit still acknowledges.
(jolt-future-hook-errors-clear!)
(define fail-body-ran? #f)
(define fail-token
  (jolt-sim-install-controller!
   (controller-config
    (lambda (event id parent)
      (record-event! event id parent)
      (when (eq? event fhk-start) (error 'start-test "start controller failure")))
    native-ffi native-clock)))
(define fail-f (jolt-sim-future-call (lambda () (set! fail-body-ran? #t) 1)))
(define fail-id (jolt-hooked-future-task-id fail-f))
(ok "start-hook failure reaches deref as an execution failure"
    (raises? (lambda () (jolt-future-deref fail-f))))
(ok "start-hook failure skips the body" (not fail-body-ran?))
(await-event (lambda (es)
               (memq fhk-exit (map car (filter (lambda (e) (= (cadr e) fail-id)) es)))))
(define fail-errors (jolt-sim-controller-errors))
(ok "start-hook failure is latched as a controller error"
    (and (= 1 (pvec-count fail-errors))
         (let ((e (pvec-nth-d fail-errors 0 jolt-nil)))
           (and (eq? (mget e "event") fhk-start)
                 (= fail-id (mget e "task"))
                 (= 0 (mget e "parent"))))))
(jolt-sim-restore-controller! fail-token)

;; Terminal-hook failure never replaces the published result; it is latched.
(jolt-future-hook-errors-clear!)
(define exit-fail-token
  (jolt-sim-install-controller!
   (controller-config
    (lambda (event id parent)
      (record-event! event id parent)
      (when (eq? event fhk-exit) (error 'exit-test "exit controller failure")))
    native-ffi native-clock)))
(define exit-f (jolt-sim-future-call (lambda () 42)))
(define exit-id (jolt-hooked-future-task-id exit-f))
(ok "exit-hook failure preserves the published body result"
    (equal? 42 (jolt-future-deref-timed exit-f 5000 life-timeout)))
(await-event (lambda (es)
               (memq fhk-exit (map car (filter (lambda (e) (= (cadr e) exit-id)) es)))))
(define exit-errors (jolt-sim-controller-errors))
(ok "exit-hook failure is latched with event, task, parent, and error"
    (and (= 1 (pvec-count exit-errors))
         (let ((e (pvec-nth-d exit-errors 0 jolt-nil)))
           (and (eq? (mget e "event") fhk-exit)
                (= exit-id (mget e "task"))
                (= 0 (mget e "parent"))
                (not (jolt-nil? (mget e "error")))))))
(jolt-sim-restore-controller! exit-fail-token)
((var-deref "jolt.internal.sim" "clear-controller-errors!"))
(ok "clear-controller-errors! empties the latch"
    (= 0 (pvec-count (jolt-sim-controller-errors))))

;; :spawn failure propagates synchronously; :abort balances the announced id
;; and no worker ever exists for it.
(define spawn-fail-events '())
(define spawn-fail-token
  (jolt-sim-install-controller!
   (controller-config
    (lambda (event id parent)
      (set! spawn-fail-events (cons (list event id parent) spawn-fail-events))
      (when (eq? event fhk-spawn) (error 'spawn-test "spawn controller failure")))
    native-ffi native-clock)))
(ok "spawn-hook failure propagates before any worker is forked"
    (raises? (lambda () (jolt-sim-future-call (lambda () 1)))))
(ok "failed spawn is balanced by exactly one abort and nothing else"
    (equal? (map car (reverse spawn-fail-events)) (list fhk-spawn fhk-abort)))
(jolt-sim-restore-controller! spawn-fail-token)
;; Return to no controller so each clock section below owns a fresh domain.
(jolt-sim-restore-controller! lifecycle-token)

;; --- F. clock: monotonicity, linearization, unhooked supervisor -----------------
(define clock-descriptors '())
(define clock-value (box 1000))
(define clock-token
  (install native-ffi
           (lambda (d proceed)
             (set! clock-descriptors (cons d clock-descriptors))
             (unbox clock-value))))
(ok "one install controls the central monotonic source"
    (= 1000 (jolt-mono-nanos)))
(ok "one install controls System/nanoTime"
    (= 1000 (jnum->exact (ev "(System/nanoTime)"))))
(ok "one install controls jolt.host monotonic source"
    (= 1000 ((var-deref "jolt.host" "mono-nanos"))))
(ok "clock controller receives the exact clock descriptor"
    (and (eq? (mget (car clock-descriptors) "kind") (kw "clock"))
         (eq? (mget (car clock-descriptors) "operation") (kw "mono-nanos"))))
(ok "supervisor monotonic bypass remains native and unhooked"
    (not (= 1000 (jnum->exact (jolt-sim-supervisor-mono-nanos)))))
(ok "equal samples are nondecreasing" (= 1000 (jolt-mono-nanos)))
(set-box! clock-value 999)
(ok "a backward controlled sample is rejected" (raises? jolt-mono-nanos))
(set-box! clock-value 1001.5)
(ok "a non-exact-integer controlled sample is rejected" (raises? jolt-mono-nanos))
(jolt-sim-restore-controller! clock-token)
(ok "restored clock is the real monotonic source"
    (let ((a (jolt-mono-nanos))) (and (integer? a) (exact? a))))

;; The active-owner check precedes the domain mutex: same-thread controlled
;; clock reentry fails immediately rather than self-deadlocking.
(define clock-reentry-rejected? #f)
(define clock-reentry-token
  (install native-ffi
           (lambda (_ __)
             (set! clock-reentry-rejected? (raises? jolt-mono-nanos))
             7)))
(ok "same-thread controlled clock reentry fails before domain locking"
    (and (= 7 (jolt-mono-nanos)) clock-reentry-rejected?))
(jolt-sim-restore-controller! clock-reentry-token)

;; Clock proceed is the unhooked supervisor source, one-shot, owner-thread,
;; dynamic-extent.
(define escaped-clock-proceed #f)
(define clock-proceed-twice-rejected? #f)
(define clock-proceed-value #f)
(define clock-proceed-token
  (install native-ffi
           (lambda (_ proceed)
             (set! escaped-clock-proceed proceed)
             (let ((v (jolt-invoke proceed)))
               (set! clock-proceed-twice-rejected?
                     (raises? (lambda () (jolt-invoke proceed))))
               (set! clock-proceed-value v)
               v))))
(ok "clock proceed answers the real unhooked supervisor source"
    (let ((v (jolt-mono-nanos)))
      (and (equal? v clock-proceed-value) (integer? v) (exact? v) (> v 0))))
(ok "clock proceed is one-shot" clock-proceed-twice-rejected?)
(ok "escaped clock proceed is rejected outside its dynamic extent"
    (raises? (lambda () (jolt-invoke escaped-clock-proceed))))
(jolt-sim-restore-controller! clock-proceed-token)

;; Nested installations share the outermost clock domain: an inner controller
;; that advanced the clock makes an older outer sample backward after restore.
(define domain-clock-value (box 1000))
(define domain-outer (install native-ffi (lambda (_ __) (unbox domain-clock-value))))
(ok "outer domain starts at its origin" (= 1000 (jolt-mono-nanos)))
(define domain-inner (install native-ffi (lambda (_ __) 2000)))
(ok "inner controller advances the shared domain" (= 2000 (jolt-mono-nanos)))
(jolt-sim-restore-controller! domain-inner)
(ok "an older outer sample is backward against the shared domain"
    (raises? jolt-mono-nanos))
(set-box! domain-clock-value 2500)
(ok "a newer outer sample is accepted by the shared domain"
    (= 2500 (jolt-mono-nanos)))
(jolt-sim-restore-controller! domain-outer)
(define domain-fresh-token (install native-ffi (lambda (_ __) 0)))
(ok "a fresh outermost scope owns a fresh clock domain" (= 0 (jolt-mono-nanos)))
(jolt-sim-restore-controller! domain-fresh-token)

;; Domain-mutex linearization discriminator, made DETERMINISTIC by the private
;; acquire-test rendezvous (jolt-sim-clock-acquire-test-hook, disabled by
;; default): it fires immediately before domain-lock acquisition in every
;; controlled clock call. A samples 1 and parks inside the controller — which
;; runs under the domain lock, so A holds it. B is forked only after A's park
;; is observed, fires the rendezvous at the acquisition boundary, and must
;; then block on the lock A holds. There is no timing assumption anywhere:
;; while A is parked and B has signaled the boundary, B provably cannot have
;; sampled or published (the controller has run only for A), because
;; obtain+validate+publish share the mutex. Every wait is deadline-bounded.
(define clock-race-seq (box 0))
(define clock-race-hook-count (box 0))
(define clock-race-mu (make-mutex))
(define clock-race-cv (make-condition))
(define clock-race-a-parked? #f)
(define clock-race-release? #f)
(define clock-race-b-at-boundary? #f)
(define clock-race-a-done? #f)
(define clock-race-b-done? #f)
(define clock-race-a-error #f)
(define clock-race-b-error #f)
(define clock-race-a-value #f)
(define clock-race-b-value #f)
(define (clock-race-next! cell)
  (with-mutex clock-race-mu
    (let ((n (+ 1 (unbox cell)))) (set-box! cell n) n)))
(define (clock-race-acquire-hook)
  (let ((n (clock-race-next! clock-race-hook-count)))
    ;; A's call is the first to reach acquisition; B's is the second.
    (when (= n 2)
      (with-mutex clock-race-mu
        (set! clock-race-b-at-boundary? #t)
        (condition-broadcast clock-race-cv)))))
(define (clock-race-controller descriptor proceed)
  (let ((n (clock-race-next! clock-race-seq)))
    (when (= n 1)
      (with-mutex clock-race-mu
        (set! clock-race-a-parked? #t)
        (condition-broadcast clock-race-cv)
        (let ((deadline (ms->deadline 5000)))
          (let wait ()
            (unless clock-race-release?
              (unless (condition-wait clock-race-cv clock-race-mu deadline)
                (error 'clock-race-test "thread A release deadline"))
              (wait))))))
    n))
(define (clock-race-await pred who)
  (with-mutex clock-race-mu
    (let ((deadline (ms->deadline 5000)))
      (let wait ()
        (unless (pred)
          (unless (condition-wait clock-race-cv clock-race-mu deadline)
            (error 'clock-race-test who))
          (wait))))))
(set! jolt-sim-clock-acquire-test-hook clock-race-acquire-hook)
(define clock-race-token (install native-ffi clock-race-controller))
(fork-thread
 (lambda ()
   (guard (e (#t (set! clock-race-a-error e)))
     (set! clock-race-a-value (jolt-mono-nanos)))
   (with-mutex clock-race-mu
     (set! clock-race-a-done? #t) (condition-broadcast clock-race-cv))))
(clock-race-await (lambda () clock-race-a-parked?) "thread A park deadline")
(fork-thread
 (lambda ()
   (guard (e (#t (set! clock-race-b-error e)))
     (set! clock-race-b-value (jolt-mono-nanos)))
   (with-mutex clock-race-mu
     (set! clock-race-b-done? #t) (condition-broadcast clock-race-cv))))
(clock-race-await (lambda () clock-race-b-at-boundary?) "thread B boundary deadline")
(ok "thread B reached the domain-lock acquisition boundary while A is parked"
    (and clock-race-a-parked? clock-race-b-at-boundary?))
(ok "parked A holds the domain lock: B has not sampled or published"
    (and (= 1 (unbox clock-race-seq)) (not clock-race-b-done?)))
(with-mutex clock-race-mu
  (set! clock-race-release? #t) (condition-broadcast clock-race-cv))
(clock-race-await (lambda () clock-race-a-done?) "thread A finish deadline")
(clock-race-await (lambda () clock-race-b-done?) "thread B finish deadline")
(set! jolt-sim-clock-acquire-test-hook #f)
(ok "thread A's genuinely-earlier sample is never rejected as backward"
    (not clock-race-a-error))
(ok "thread B's genuinely-later sample is never rejected as backward"
    (not clock-race-b-error))
(ok "both concurrent samples were accepted in obtain order"
    (and (equal? 1 clock-race-a-value) (equal? 2 clock-race-b-value)))
(jolt-sim-restore-controller! clock-race-token)

;; Buggy control: the pre-fix ordering sampled OUTSIDE the domain lock and
;; only validated/published inside it. Reproduce that exact ordering against
;; the same validator and a fresh domain — deterministically, again with no
;; timing: A obtains sample 1 outside the lock and parks; B then validates and
;; publishes 2; A, released, must falsely fail its genuinely-earlier sample as
;; backward. This is the failure the shared-mutex ordering above excludes.
(define buggy-domain (make-jolt-sim-clock-domain (make-mutex) #f))
(define buggy-mu (make-mutex))
(define buggy-cv (make-condition))
(define buggy-a-sampled? #f)
(define buggy-release? #f)
(define buggy-a-done? #f)
(define buggy-b-published? #f)
(define buggy-a-error #f)
(fork-thread
 (lambda ()
   ;; Old ordering: obtain first, WITHOUT the domain lock.
   (let ((sample 1))
     (with-mutex buggy-mu
       (set! buggy-a-sampled? #t)
       (condition-broadcast buggy-cv)
       (let ((deadline (ms->deadline 5000)))
         (let wait ()
           (unless buggy-release?
             (unless (condition-wait buggy-cv buggy-mu deadline)
               (error 'buggy-control "thread A release deadline"))
             (wait)))))
     (guard (e (#t (set! buggy-a-error e)))
       (with-mutex (jolt-sim-clock-domain-mu buggy-domain)
         (jolt-sim-clock-validate-locked! buggy-domain sample)))
     (with-mutex buggy-mu
       (set! buggy-a-done? #t) (condition-broadcast buggy-cv)))))
(with-mutex buggy-mu
  (let ((deadline (ms->deadline 5000)))
    (let wait ()
      (unless buggy-a-sampled?
        (unless (condition-wait buggy-cv buggy-mu deadline)
          (error 'buggy-control "thread A sample deadline"))
        (wait)))))
;; B validates+publishes its later sample while A's earlier sample is still
;; unvalidated outside the lock.
(with-mutex (jolt-sim-clock-domain-mu buggy-domain)
  (jolt-sim-clock-validate-locked! buggy-domain 2))
(set! buggy-b-published? #t)
(with-mutex buggy-mu
  (set! buggy-release? #t) (condition-broadcast buggy-cv))
(with-mutex buggy-mu
  (let ((deadline (ms->deadline 5000)))
    (let wait ()
      (unless buggy-a-done?
        (unless (condition-wait buggy-cv buggy-mu deadline)
          (error 'buggy-control "thread A finish deadline"))
        (wait)))))
(ok "buggy control: sample-outside-lock falsely rejects A's earlier sample"
    (and buggy-b-published? buggy-a-error))

;; --- G. FFI through the bridge: both kinds, arities, proceed lifetime ----------
(define seen '())
(define sweep-token
  (install
   (lambda (d proceed)
     (set! seen (cons d seen))
     (if (eq? (mget d "kind") (kw "native-operation"))
         (cond
           ((string=? (keyword-t-name (mget d "operation")) "alloc") 424242)
           ((string=? (keyword-t-name (mget d "operation")) "sizeof") 64)
           (else 0))
         999))
   native-clock))
(ok "modeled alloc bypasses native" (= 424242 (ffi-alloc 8)))
(ok "modeled sizeof bypasses native" (= 64 (ffi-sizeof (kw "int"))))
(set! seen '())
;; Drive every raw operation at every valid arity; all are modeled, so no fake
;; pointer ever reaches Chez.
(define sweep-ba (na-byte-array (jolt-vector 1 -1 3 4)))
(ffi-load-library)
(ffi-load-library "sweep-lib")
(ffi-loaded? "sweep-lib")
(ffi-alloc 8)
(ffi-free 424242)
(ffi-read 424242 (kw "int"))
(ffi-read 424242 (kw "int") 3)
(ffi-write 424242 (kw "int") 0 1)
(ffi-sizeof (kw "int"))
((var-deref "jolt.ffi" "null?") 0)
(ffi-read-bytes 424242 2)
(ffi-write-bytes 424242 "hi")
(ffi-read-array 424242 2)
(ffi-read-array! 424242 2 sweep-ba 1)
(ffi-write-array 424242 sweep-ba)
(ffi-write-array 424242 sweep-ba 1 2)
(ffi-ptr->string 424242)
(ffi-string->ptr "sweep")
(define swept-ops
  (map (lambda (d) (cons (keyword-t-name (mget d "operation"))
                         (pvec-count (mget d "arguments"))))
       (reverse (filter (lambda (d) (eq? (mget d "kind") (kw "native-operation")))
                        seen))))
(ok "every raw operation reaches the controller at every valid arity"
    (equal? swept-ops
            '(("load-library" . 0) ("load-library" . 1) ("loaded?" . 1)
              ("alloc" . 1) ("free" . 1)
              ("read" . 2) ("read" . 3) ("write" . 4) ("sizeof" . 1)
              ("null?" . 1) ("read-bytes" . 2) ("write-bytes" . 2)
              ("read-array" . 2) ("read-array!" . 4)
              ("write-array" . 2) ("write-array" . 4)
              ("ptr->string" . 1) ("string->ptr" . 1))))
(ok "read-array! descriptor carries the live destination array"
    (let ((d (find (lambda (d)
                     (and (eq? (mget d "kind") (kw "native-operation"))
                          (eq? (mget d "operation") (kw "read-array!"))))
                   seen)))
      (and d (eq? sweep-ba (pvec-nth-d (mget d "arguments") 2 jolt-nil)))))
(ok "declared foreign call projects the exact public descriptor"
    (begin
      (set! seen '())
      (= 999 (jnum->exact (ev "(c-bridge-ghost 7 8)")))))
(let ((d (car seen)))
  (ok "foreign descriptor kind, symbol, and task"
      (and (eq? (mget d "kind") (kw "foreign-function"))
           (string=? "definitely_not_a_real_c_symbol_bridge_zzz9" (mget d "symbol"))
           (= 0 (mget d "task"))))
  (ok "foreign descriptor types, flags, and nil variadic boundary"
      (and (equal? (vector->list (pvec-v (mget d "argument-types")))
                   (list (kw "int") (kw "int")))
           (eq? (mget d "return-type") (kw "int"))
           (eq? #t (mget d "blocking?"))
           (eq? #f (mget d "capture-native-error?"))
           (jolt-nil? (mget d "varargs-after"))))
  (ok "foreign descriptor live arguments in call order"
      (and (= 2 (pvec-count (mget d "arguments")))
           (= 7 (jnum->exact (pvec-nth-d (mget d "arguments") 0 jolt-nil)))
           (= 8 (jnum->exact (pvec-nth-d (mget d "arguments") 1 jolt-nil))))))
(ok "capture-declared substitution is returned unwrapped"
    (= 999 (jnum->exact (ev "(c-bridge-ghost-cap)"))))
(jolt-sim-restore-controller! sweep-token)

;; loaded? always publishes a Jolt Boolean, including when a modeled controller
;; naturally returns nil for a negative result.
(define public-loaded? (var-deref "jolt.ffi" "loaded?"))
(define modeled-loaded-result (box jolt-nil))
(define modeled-loaded-token
  (install
   (lambda (d proceed)
     (if (and (eq? (mget d "kind") (kw "native-operation"))
              (eq? (mget d "operation") (kw "loaded?")))
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

;; A controller that proceeds runs the exact original operation: real memory
;; roundtrip, capture result shape, and one-shot/escaped proceed rejection.
(define proceed-token (install native-ffi native-clock))
(ok "proceeded raw roundtrip uses the exact original operation"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 8)]
            (ffi/write p :int 0 -7)
            (let [v (ffi/read p :int)]
              (ffi/free p)
              (= v -7)))")))
(ok "proceeded capture call preserves the [result native-error] shape"
    (let ((r (ev "(c-bridge-cap-abs -9)")))
      (and (pvec? r)
           (= 2 (pvec-count r))
           (= 9 (jnum->exact (pvec-nth-d r 0 jolt-nil)))
           (integer? (pvec-nth-d r 1 jolt-nil)))))
(ok "proceeded declared call is the exact native binding"
    (= 9 (jnum->exact (ev "(c-bridge-abs -9)"))))
(jolt-sim-restore-controller! proceed-token)

(define escaped-proceed #f)
(define twice-rejected? #f)
(define nested-rejected? #f)
(define oneshot-token
  (install
   (lambda (d proceed)
     (set! escaped-proceed proceed)
     (set! nested-rejected? (raises? (lambda () (ffi-sizeof (kw "int")))))
     (let ((r (jolt-invoke proceed)))
       (set! twice-rejected? (raises? (lambda () (jolt-invoke proceed))))
       r))
   native-clock))
(define real-p (ffi-alloc 4))
(ok "controller-phase nested FFI fails against the canonical activation"
    nested-rejected?)
(ok "canonical proceed is one-shot through the bridge" twice-rejected?)
(ok "canonical proceed escapes its extent only to fail"
    (raises? (lambda () (jolt-invoke escaped-proceed))))
(jolt-sim-restore-controller! oneshot-token)
(ffi-free real-p)

;; --- H. installation-affine routing for controlled tasks ---------------------
;; A controlled future captures the effective composite at spawn; its worker's
;; nested futures, FFI bridge calls, and controlled clock calls keep routing
;; to that capture even while an inner token is current globally. Discriminator:
;; park an outer controlled future after start, install inner, release the
;; outer to perform FFI and clock (directly and inside a nested future), and
;; prove only the outer controller sees its task/effects. Clock constants are
;; chosen so the shared nested domain stays nondecreasing throughout.
(define aff-mu (make-mutex))
(define aff-cv (make-condition))
(define aff-release? #f)
(define aff-outer-events '())
(define aff-outer-ffi-calls '())
(define aff-outer-clock-calls 0)
(define aff-inner-events '())
(define aff-inner-ffi-calls 0)
(define aff-inner-clock-calls 0)
(define (aff-outer-future event id parent)
  (with-mutex aff-mu
    (set! aff-outer-events (cons (list event id parent) aff-outer-events))
    (condition-broadcast aff-cv))
  (when (eq? event fhk-start)
    (with-mutex aff-mu
      (let ((deadline (ms->deadline 10000)))
        (let wait ()
          (unless aff-release?
            (unless (condition-wait aff-cv aff-mu deadline)
              (error 'aff-test "outer start release deadline"))
            (wait))))))
  jolt-nil)
(define (aff-outer-ffi d proceed)
  (set! aff-outer-ffi-calls (cons (mget d "task") aff-outer-ffi-calls))
  314)
(define (aff-outer-clock d proceed)
  (set! aff-outer-clock-calls (+ aff-outer-clock-calls 1))
  5000)
(define (aff-inner-future event id parent)
  (set! aff-inner-events (cons event aff-inner-events))
  jolt-nil)
(define (aff-inner-ffi d proceed)
  (set! aff-inner-ffi-calls (+ aff-inner-ffi-calls 1))
  999)
(define (aff-inner-clock d proceed)
  (set! aff-inner-clock-calls (+ aff-inner-clock-calls 1))
  4000)
(define aff-outer-token
  (jolt-sim-install-controller!
   (controller-config aff-outer-future aff-outer-ffi aff-outer-clock)))
(define aff-f
  (jolt-sim-future-call
   (lambda ()
     (let ((a (ffi-alloc 4))
           (n (jolt-mono-nanos))
           (inner (jolt-sim-future-call
                   (lambda () (ffi-alloc 4) (jolt-mono-nanos) 1))))
       (jolt-future-deref inner)
       (list a n)))))
(define aff-outer-id (jolt-hooked-future-task-id aff-f))
;; Observe the outer worker parked at :start before installing the inner token.
(with-mutex aff-mu
  (let ((deadline (ms->deadline 5000)))
    (let wait ()
      (unless (memq fhk-start (map car aff-outer-events))
        (unless (condition-wait aff-cv aff-mu deadline)
          (error 'aff-test "outer start deadline"))
        (wait)))))
(define aff-inner-token
  (jolt-sim-install-controller!
   (controller-config aff-inner-future aff-inner-ffi aff-inner-clock)))
;; Global uncontrolled routing (this thread holds no task capture) selects inner.
(ok "inner token owns global uncontrolled FFI and clock routing"
    (and (= 999 (ffi-alloc 1)) (= 4000 (jolt-mono-nanos))))
(with-mutex aff-mu
  (set! aff-release? #t) (condition-broadcast aff-cv))
(ok "outer controlled body completes under the inner token's global scope"
    (equal? (list 314 5000)
            (jolt-future-deref-timed aff-f 5000 life-timeout)))
(with-mutex aff-mu
  (let ((deadline (ms->deadline 5000)))
    (let wait ()
      (unless (<= 2 (length (filter (lambda (e) (eq? (car e) fhk-exit))
                                    aff-outer-events)))
        (unless (condition-wait aff-cv aff-mu deadline)
          (error 'aff-test "exit deadline"))
        (wait)))))
(define aff-nested-id
  (let ((nested (filter (lambda (e) (and (eq? (car e) fhk-spawn)
                                         (= (caddr e) aff-outer-id)))
                        aff-outer-events)))
    (and (pair? nested) (cadar nested))))
(ok "outer task's nested future still reports the outer parent and controller"
    (and aff-nested-id
         (for-all (lambda (e)
                    (or (= (caddr e) 0) (= (caddr e) aff-outer-id)))
                  (filter (lambda (e) (eq? (car e) fhk-spawn)) aff-outer-events))))
(ok "outer controller alone saw the outer task's FFI calls"
    (and (= 2 (length aff-outer-ffi-calls))
         (memq aff-outer-id aff-outer-ffi-calls)
         (memq aff-nested-id aff-outer-ffi-calls)
         (= 1 aff-inner-ffi-calls)))
(ok "outer controller alone saw the outer task's clock calls"
    (and (= 2 aff-outer-clock-calls) (= 1 aff-inner-clock-calls)))
(ok "inner controller saw no lifecycle events from the outer task"
    (null? aff-inner-events))
(jolt-sim-restore-controller! aff-inner-token)
(jolt-sim-restore-controller! aff-outer-token)

;; --- I. host-internal canonical-hook override is temporary suspension ---------
;; Later host-internal installation ABOVE the persistent bridge suspends bridge
;; routing under the canonical token-cleared discipline; it is not public
;; controller behavior. Clearing it restores the bridge and the active
;; composite's routing.
(define suspend-seen 0)
(define suspend-token
  (install (lambda (d proceed) (set! suspend-seen (+ suspend-seen 1)) 555)
           native-clock))
(ok "bridge routing is live before the override"
    (and (= 555 (ffi-alloc 1)) (= 1 suspend-seen)))
(define sentinel-installation
  (jolt-ffi-install-declared-call-hook! (lambda (descriptor proceed) 777)))
(ok "host-internal override suspends bridge routing" (= 777 (ffi-alloc 1)))
(ok "override bypassed the active composite" (= 1 suspend-seen))
(ok "canonical top is the override during suspension"
    (eq? jolt-ffi-declared-call-hook-top sentinel-installation))
(ok "override's predecessor is the persistent bridge"
    (eq? (jolt-ffi-declared-call-hook-installation-previous sentinel-installation)
         jolt-sim-ffi-bridge-installation))
(jolt-ffi-clear-declared-call-hook! sentinel-installation)
(ok "clear restores the persistent bridge as canonical top"
    (eq? jolt-ffi-declared-call-hook-top jolt-sim-ffi-bridge-installation))
(ok "composite routing resumes after the override clears"
    (and (= 555 (ffi-alloc 1)) (= 2 suspend-seen)))
(jolt-sim-restore-controller! suspend-token)

;; --- J. raw fork of a controlled task: no captured installation, task/parent 0 --
;; An owner-tagged task context inherited by a different thread reads as no
;; context: a RAW fork made by an outer controlled task while an inner
;; installation is globally current routes to inner, with FFI :task 0, and its
;; nested future reports parent 0.
(define rf-mu (make-mutex))
(define rf-cv (make-condition))
(define rf-inner-installed? #f)
(define rf-done? #f)
(define rf-outer-events '())
(define rf-outer-ffi-calls 0)
(define rf-outer-clock-calls 0)
(define rf-inner-events '())
(define rf-inner-ffi-tasks '())
(define rf-inner-clock-calls 0)
(define rf-nested-id #f)
(define rf-error #f)
(define (rf-outer-future event id parent)
  (with-mutex rf-mu
    (set! rf-outer-events (cons (list event id parent) rf-outer-events))
    (condition-broadcast rf-cv))
  jolt-nil)
(define (rf-outer-ffi d proceed)
  (set! rf-outer-ffi-calls (+ rf-outer-ffi-calls 1))
  314)
(define (rf-outer-clock d proceed)
  (set! rf-outer-clock-calls (+ rf-outer-clock-calls 1))
  5000)
(define (rf-inner-future event id parent)
  (with-mutex rf-mu
    (set! rf-inner-events (cons (list event id parent) rf-inner-events))
    (condition-broadcast rf-cv))
  jolt-nil)
(define (rf-inner-ffi d proceed)
  (set! rf-inner-ffi-tasks (cons (mget d "task") rf-inner-ffi-tasks))
  999)
(define (rf-inner-clock d proceed)
  (set! rf-inner-clock-calls (+ rf-inner-clock-calls 1))
  4000)
(define rf-outer-token
  (jolt-sim-install-controller!
   (controller-config rf-outer-future rf-outer-ffi rf-outer-clock)))
(define rf-f
  (jolt-sim-future-call
   (lambda ()
     (fork-thread
      (lambda ()
        (guard (e (#t
                   (with-mutex rf-mu
                     (set! rf-error e)
                     (set! rf-done? #t)
                     (condition-broadcast rf-cv))))
          (with-mutex rf-mu
            (let ((deadline (ms->deadline 10000)))
              (let wait ()
                (unless rf-inner-installed?
                  (unless (condition-wait rf-cv rf-mu deadline)
                    (error 'rf-test "inner install deadline"))
                  (wait)))))
          ;; Raw thread: inherited context owner mismatch -> no capture, task 0.
          (ffi-alloc 4)
          (jolt-mono-nanos)
          (let ((nested (jolt-sim-future-call (lambda () 7))))
            (with-mutex rf-mu
              (set! rf-nested-id (jolt-hooked-future-task-id nested)))
            (jolt-future-deref nested)
            ;; Result publication precedes :exit. Do not let the raw owner
            ;; report done (or permit restoration) until the nested worker's
            ;; final lifecycle acknowledgement is recorded.
            (with-mutex rf-mu
              (let ((deadline (ms->deadline 10000)))
                (let wait ()
                  (unless (exists (lambda (e)
                                    (and (eq? (car e) fhk-exit)
                                         (= (cadr e) rf-nested-id)))
                                  rf-inner-events)
                    (unless (condition-wait rf-cv rf-mu deadline)
                      (error 'rf-test "nested exit deadline"))
                    (wait))))))
          (with-mutex rf-mu
            (set! rf-done? #t) (condition-broadcast rf-cv)))))
     (with-mutex rf-mu
       (let ((deadline (ms->deadline 10000)))
         (let wait ()
           (unless rf-done?
             (unless (condition-wait rf-cv rf-mu deadline)
               (error 'rf-test "raw fork deadline"))
             (wait)))))
     5)))
(define rf-outer-id (jolt-hooked-future-task-id rf-f))
(define rf-inner-token
  (jolt-sim-install-controller!
   (controller-config rf-inner-future rf-inner-ffi rf-inner-clock)))
(with-mutex rf-mu
  (set! rf-inner-installed? #t) (condition-broadcast rf-cv))
(ok "outer controlled task completes after its raw fork" 
    (equal? 5 (jolt-future-deref-timed rf-f 5000 life-timeout)))
;; Deref observes result publication, not the later :exit acknowledgement.
;; Await the outer exit explicitly before inspecting events or restoring either
;; captured installation.
(with-mutex rf-mu
  (let ((deadline (ms->deadline 5000)))
    (let wait ()
      (unless (exists (lambda (e)
                        (and (eq? (car e) fhk-exit)
                             (= (cadr e) rf-outer-id)))
                      rf-outer-events)
        (unless (condition-wait rf-cv rf-mu deadline)
          (error 'rf-test "outer exit deadline"))
        (wait)))))
;; The normal raw-thread path already waits for this. Repeat the bounded check
;; here so an error after nested-future creation cannot let cleanup restore its
;; installation while that worker is still acknowledging :exit.
(with-mutex rf-mu
  (when rf-nested-id
    (let ((deadline (ms->deadline 5000)))
      (let wait ()
        (unless (exists (lambda (e)
                          (and (eq? (car e) fhk-exit)
                               (= (cadr e) rf-nested-id)))
                        rf-inner-events)
          (unless (condition-wait rf-cv rf-mu deadline)
            (error 'rf-test "nested cleanup exit deadline"))
          (wait))))))
(ok "raw fork ran without error" (not rf-error))
(ok "raw fork FFI routed to the globally-current inner controller with task 0"
    (and (= 1 (length rf-inner-ffi-tasks))
         (for-all (lambda (t) (= 0 t)) rf-inner-ffi-tasks)))
(ok "raw fork clock routed to the inner controller"
    (= 1 rf-inner-clock-calls))
(ok "raw fork's nested future reports parent 0 to the inner controller"
    (let ((spawns (filter (lambda (e) (eq? (car e) fhk-spawn)) rf-inner-events)))
      (and (= 1 (length spawns))
           (= (cadr (car spawns)) rf-nested-id)
           (= 0 (caddr (car spawns))))))
(ok "raw fork's nested future completed its inner lifecycle"
    (let ((kinds (map car (filter (lambda (e) (= (cadr e) rf-nested-id))
                                  rf-inner-events))))
      (and (memq fhk-start kinds) (memq fhk-finish kinds) (memq fhk-exit kinds))))
(ok "outer controller saw none of the raw fork's operations"
    (and (= 0 rf-outer-ffi-calls) (= 0 rf-outer-clock-calls)))
(ok "outer controller saw only the outer task's own lifecycle"
    (for-all (lambda (e) (= (cadr e) rf-outer-id)) rf-outer-events))
(jolt-sim-restore-controller! rf-inner-token)
(jolt-sim-restore-controller! rf-outer-token)

;; --- K. cancel of an outer future while inner is globally current --------------
;; The :cancel observer runs under the TARGET future's captured installation,
;; retaining the cancelling thread's task id only when valid for that same
;; installation (an uncontrolled canceller routes task 0). The outer cancel
;; callback's own FFI and clock operations must stay outer.
(define cx-mu (make-mutex))
(define cx-cv (make-condition))
(define cx-release? #f)
(define cx-outer-events '())
(define cx-outer-ffi-tasks '())
(define cx-outer-clock-calls 0)
(define cx-inner-ffi-calls 0)
(define cx-inner-clock-calls 0)
(define cx-inner-events '())
(define (cx-outer-future event id parent)
  (with-mutex cx-mu
    (set! cx-outer-events (cons (list event id parent) cx-outer-events))
    (condition-broadcast cx-cv))
  (when (eq? event fhk-cancel)
    ;; Runs under the target's captured (outer) installation, routing task 0.
    (ffi-alloc 4)
    (jolt-mono-nanos))
  (when (eq? event fhk-start)
    (with-mutex cx-mu
      (let ((deadline (ms->deadline 10000)))
        (let wait ()
          (unless cx-release?
            (unless (condition-wait cx-cv cx-mu deadline)
              (error 'cx-test "start permit deadline"))
            (wait))))))
  jolt-nil)
(define (cx-outer-ffi d proceed)
  (set! cx-outer-ffi-tasks (cons (mget d "task") cx-outer-ffi-tasks))
  314)
(define (cx-outer-clock d proceed)
  (set! cx-outer-clock-calls (+ cx-outer-clock-calls 1))
  (jolt-invoke proceed))
(define (cx-inner-future event id parent)
  (set! cx-inner-events (cons event cx-inner-events))
  jolt-nil)
(define (cx-inner-ffi d proceed)
  (set! cx-inner-ffi-calls (+ cx-inner-ffi-calls 1))
  999)
(define (cx-inner-clock d proceed)
  (set! cx-inner-clock-calls (+ cx-inner-clock-calls 1))
  (jolt-invoke proceed))
(define cx-outer-token
  (jolt-sim-install-controller!
   (controller-config cx-outer-future cx-outer-ffi cx-outer-clock)))
(define cx-f (jolt-sim-future-call (lambda () 5)))
(define cx-id (jolt-hooked-future-task-id cx-f))
;; Observe the worker parked at :start before installing inner and cancelling.
(with-mutex cx-mu
  (let ((deadline (ms->deadline 5000)))
    (let wait ()
      (unless (memq fhk-start (map car cx-outer-events))
        (unless (condition-wait cx-cv cx-mu deadline)
          (error 'cx-test "start deadline"))
        (wait)))))
(define cx-inner-token
  (jolt-sim-install-controller!
   (controller-config cx-inner-future cx-inner-ffi cx-inner-clock)))
(ok "cancel of the outer future wins under the inner token's global scope"
    (eq? #t (jolt-sim-future-cancel cx-f)))
(ok "cancel callback's FFI stayed outer, stamped with routing task 0"
    (and (= 1 (length cx-outer-ffi-tasks))
         (for-all (lambda (t) (= 0 t)) cx-outer-ffi-tasks)
         (= 0 cx-inner-ffi-calls)))
(ok "cancel callback's clock call stayed outer"
    (and (= 1 cx-outer-clock-calls) (= 0 cx-inner-clock-calls)))
(ok "inner controller observed no lifecycle from the outer task"
    (null? cx-inner-events))
(ok "cancelled outer future raises from deref"
    (raises? (lambda () (jolt-future-deref cx-f))))
(with-mutex cx-mu
  (set! cx-release? #t) (condition-broadcast cx-cv))
(with-mutex cx-mu
  (let ((deadline (ms->deadline 5000)))
    (let wait ()
      (unless (memq fhk-exit (map car cx-outer-events))
        (unless (condition-wait cx-cv cx-mu deadline)
          (error 'cx-test "exit deadline"))
        (wait)))))
(ok "outer task lifecycle is spawn,start,cancel,exit all to the outer controller"
    (equal? (map car (reverse (filter (lambda (e) (= (cadr e) cx-id))
                                      cx-outer-events)))
            (list fhk-spawn fhk-start fhk-cancel fhk-exit)))
(jolt-sim-restore-controller! cx-inner-token)
(jolt-sim-restore-controller! cx-outer-token)

;; --- L. scoped byte-array view vars: the controller window into a loan -------
;; The two OPTIONAL vars advertised under :ffi-interception/:scoped-byte-array-view
;; are a controller's only byte-copying window into the runtime-owned temporary
;; behind an ACTIVE with-byte-array-pointer loan: inside a controller
;; invocation the canonical activation rejects a nested raw FFI operation on
;; the loaned pointer (section G), while the view vars read/write the tracked
;; locked temporary directly, carrying no descriptor of any kind.
(define view-read-var (var-deref "jolt.internal.sim" "read-active-byte-array-view"))
(define view-write-var (var-deref "jolt.internal.sim" "write-active-byte-array-view!"))
(ok "sim public ABI exposes the exact scoped byte-array view vars"
    (and (var-cell-lookup "jolt.internal.sim" "read-active-byte-array-view")
         (var-cell-lookup "jolt.internal.sim" "write-active-byte-array-view!")))
(ok "scoped byte-array view vars take exactly the advertised arities"
    (and (= 4 (procedure-arity-mask view-read-var))
         (= 4 (procedure-arity-mask view-write-var))))
(ok "view vars answer nil with no active loan"
    (and (jolt-nil? (view-read-var 424242 1))
         (jolt-nil? (view-write-var 424242 sweep-ba))))

;; A controller observing an intercepted write-array on a loaned pointer:
;; snapshot the temporary with the read view, proceed (the exact original
;; write-array mutates the same temporary), patch an interior span with the
;; write view, and let the loan's ordinary copy-back publish both effects.
(define view-snapshots '())
(define view-write-result #f)
(define view-captured-p #f)
(define view-nested-ffi-rejected? #f)
(define view-ba-patch (na-byte-array (jolt-vector 5 6)))
(define view-token
  (install
   (lambda (d proceed)
     (if (and (eq? (mget d "kind") (kw "native-operation"))
              (eq? (mget d "operation") (kw "write-array")))
         (let ((p (pvec-nth-d (mget d "arguments") 0 jolt-nil)))
           (set! view-captured-p p)
           ;; The canonical activation still rejects a nested raw FFI read on
           ;; the loaned pointer; the view is the supported window.
           (set! view-nested-ffi-rejected?
                 (raises? (lambda () (ffi-read p (kw "uint8")))))
           (set! view-snapshots (cons (view-read-var p 4) view-snapshots))
           (let ((r (jolt-invoke proceed)))
             (set! view-write-result (view-write-var (+ p 2) view-ba-patch))
             r))
         (jolt-invoke proceed)))
   native-clock))
(define view-roundtrip
  (jolt-truthy?
   (ev "(let [a (byte-array [1 2 3 4])]
          (jolt.ffi/with-byte-array-pointer a
            (fn [p n] (jolt.ffi/write-array p (byte-array [9 8 7 6]))))
          (= [9 8 5 6] (vec a)))")))
(jolt-sim-restore-controller! view-token)
(ok "controller-phase nested raw FFI on the loaned pointer still fails"
    view-nested-ffi-rejected?)
(ok "controller read view snapshots the temporary before the proceeded write"
    (and (= 1 (length view-snapshots))
         (equal? '(1 2 3 4)
                 (vector->list (jolt-array-vec (car view-snapshots))))))
(ok "controller write view patched the temporary and reported its exact count"
    (= 2 view-write-result))
(ok "proceeded write and view patch both copy back at loan exit"
    view-roundtrip)
(ok "the captured loan pointer is stale after the dynamic extent"
    (jolt-nil? (view-read-var view-captured-p 1)))

;; The public Clojure surface: nil outside a loan, a whole-span read, an
;; interior write re-read inside the extent, and copy-back at exit — all
;; through the exact jolt.internal.sim vars with no controller installed.
(ok "jolt code drives the view vars through the public var surface"
    (jolt-truthy?
     (ev "(let [a (byte-array [10 20 30 40])
                rv (deref (find-var 'jolt.internal.sim/read-active-byte-array-view))
                wv (deref (find-var 'jolt.internal.sim/write-active-byte-array-view!))]
            (and (nil? (rv 16 1))
                 (nil? (wv 16 (byte-array [0])))
                 (jolt.ffi/with-byte-array-pointer a
                   (fn [p n]
                     (and (= [10 20 30 40] (vec (rv p n)))
                          (= 2 (wv (inc p) (byte-array [1 2])))
                          (= [10 1 2 40] (vec (rv p n))))))
                 (= [10 1 2 40] (vec a))))")))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
