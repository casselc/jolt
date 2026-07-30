;; class-provider REGISTRY CORE gate.
;;
;; Covers validation (invalid class/provider), conflict atomicity (no partial
;; prefix), idempotence, the freeze boundary (existing ok / new rejected),
;; exact lookup, deterministic sorted+deduplicated mappings and namespaces,
;; reset, and monotonic generation. Registry-only: no lazy loading or provider
;; evaluation is exercised here.
;;
;;   CHEZ=/path/to/chez make providerregistry
;;   CHEZ=... chez --script test/chez/class-provider-registry-test.ss

(import (chezscheme))
(load "host/chez/run-gate-harness.ss")

;; --- error-type extraction --------------------------------------------------
;; A class-provider failure is a jolt ex-info whose ex-data carries a :type
;; keyword naming the category. Unwrap the thrown condition and read it; return
;; the keyword (or jolt-nil for a non-structured exception), and 'no-error when
;; the thunk returns normally.
(define t-err-type-kw (keyword #f "type"))
(define t-invalid (keyword "jolt.deps" "invalid-class-provider"))
(define t-conflict (keyword "jolt.deps" "class-provider-conflict"))
(define t-frozen (keyword "jolt.deps" "class-provider-registry-frozen"))
(define t-class-kw (keyword #f "class"))
(define (t-condition-data e)
  (let ((v (jolt-unwrap-throw e)))
    (if (and (jolt-ex-info-record? v) (pmap? (jolt-ex-info-record-data v)))
        (jolt-ex-info-record-data v)
        jolt-nil)))
(define (t-condition-type e)
  (let ((data (t-condition-data e)))
    (if (pmap? data)
        (pmap-get data t-err-type-kw jolt-nil)
        jolt-nil)))
(define (t-error-type thunk)
  (guard (e (#t (t-condition-type e)))
    (thunk)
    'no-error))
(define (t-error-data thunk)
  (guard (e (#t (t-condition-data e)))
    (thunk)
    jolt-nil))

;; --- clean baseline ---------------------------------------------------------
(class-provider-reset-many! '())
(gate-check "baseline: empty mappings" (class-provider-mappings) '())
(gate-check "baseline: empty namespaces" (class-provider-namespaces) '())

;; --- invalid class / provider ----------------------------------------------
;; Canonical class: must contain a dot, no leading/trailing/double dot, no slash.
;; Provider: a nonblank token. All malformed inputs raise one structured
;; :jolt.deps/invalid-class-provider ex-info and mutate nothing.
(gate-check "invalid: no dot rejected"
  (t-error-type (lambda () (class-provider-register-many!
                             (list (cons "ByteBuffer" "p.x")))))
  t-invalid)
(gate-check "invalid: leading dot rejected"
  (t-error-type (lambda () (class-provider-register-many!
                             (list (cons ".foo.Bar" "p.x")))))
  t-invalid)
(gate-check "invalid: trailing dot rejected"
  (t-error-type (lambda () (class-provider-register-many!
                             (list (cons "foo.Bar." "p.x")))))
  t-invalid)
(gate-check "invalid: double dot rejected"
  (t-error-type (lambda () (class-provider-register-many!
                             (list (cons "foo..Bar" "p.x")))))
  t-invalid)
(gate-check "invalid: slash rejected"
  (t-error-type (lambda () (class-provider-register-many!
                             (list (cons "foo/Bar" "p.x")))))
  t-invalid)
(gate-check "invalid: blank provider rejected"
  (t-error-type (lambda () (class-provider-register-many!
                             (list (cons "foo.Bar" "   ")))))
  t-invalid)
(gate-check "invalid: empty provider rejected"
  (t-error-type (lambda () (class-provider-register-many!
                             (list (cons "foo.Bar" "")))))
  t-invalid)
(gate-check "invalid: non-string/symbol class rejected"
  (t-error-type (lambda () (class-provider-register-many!
                             (list (cons 42 "p.x")))))
  t-invalid)
(gate-check "invalid: failed attempts mutate nothing"
  (class-provider-mappings) '())

;; --- positive registration incl. string/symbol normalization ---------------
(class-provider-reset-many!
  (list (cons "java.nio.ByteBuffer" "cpfixture.buffer-provider")
        ;; a bare jolt symbol provider normalizes to its name string
        (cons "com.acme.Buffer" (jolt-symbol #f "cpfixture.acme-provider"))))
(gate-check "string mapping registered"
  (class-provider-for "java.nio.ByteBuffer") "cpfixture.buffer-provider")
(gate-check "symbol provider normalized to string"
  (class-provider-for "com.acme.Buffer") "cpfixture.acme-provider")

;; --- conflict atomicity -----------------------------------------------------
;; A batch with a conflict (against the table OR within the batch) raises and
;; leaves NO partial prefix of the would-be new mappings behind.
(class-provider-reset-many!
  (list (cons "a.b.C" "p.one") (cons "d.e.F" "p.two")))
(gate-check "conflict: existing-key conflict raises"
  (t-error-type
    (lambda ()
      (class-provider-register-many!
        (list (cons "a.b.C" "p.one")          ; idempotent
              (cons "g.h.K" "p.three")         ; new (would-be prefix)
              (cons "d.e.F" "p.conflict")))))  ; conflicts with existing p.two
  t-conflict)
(gate-check "conflict atomicity: new key in failed batch not registered"
  (jolt-nil? (class-provider-for "g.h.K")) #t)
(gate-check "conflict atomicity: existing mappings unchanged"
  (class-provider-mappings)
  (list (cons "a.b.C" "p.one") (cons "d.e.F" "p.two")))
(gate-check "conflict: intra-batch raises"
  (t-error-type
    (lambda ()
      (class-provider-register-many!
        (list (cons "x.y.Z" "p.a") (cons "x.y.Z" "p.b")))))
  t-conflict)
(gate-check "conflict atomicity: intra-batch inserted nothing"
  (jolt-nil? (class-provider-for "x.y.Z")) #t)

;; reset-many! is also an atomic whole-map operation: a bad replacement cannot
;; clear or partially replace the current registry.
(let ((before (class-provider-mappings))
      (generation (class-provider-generation)))
  (gate-check "reset conflict: intra-batch raises"
    (t-error-type
      (lambda ()
        (class-provider-reset-many!
          (list (cons "reset.atomic.A" "p.a")
                (cons "reset.atomic.A" "p.b")))))
    t-conflict)
  (gate-check "reset conflict: prior mappings unchanged"
    (class-provider-mappings) before)
  (gate-check "reset conflict: generation unchanged"
    (class-provider-generation) generation))

;; --- idempotence ------------------------------------------------------------
;; An identical re-declaration is a no-op: no error, no generation bump.
(let ((before (class-provider-generation)))
  (class-provider-register-many! (list (cons "a.b.C" "p.one")))
  (gate-check "idempotent: generation unchanged"
    (class-provider-generation) before)
  (gate-check "idempotent: lookup unchanged"
    (class-provider-for "a.b.C") "p.one"))

;; --- freeze boundary --------------------------------------------------------
;; Once frozen, an identical re-declaration stays harmless and a NEW class key is
;; rejected with :jolt.deps/class-provider-registry-frozen. reset-many! thaws.
(class-provider-freeze!)
(gate-check "freeze: existing identical declaration accepted"
  (t-error-type (lambda () (class-provider-register-many!
                             (list (cons "a.b.C" "p.one")))))
  'no-error)
(gate-check "freeze: new declaration rejected"
  (t-error-type (lambda () (class-provider-register-many!
                             (list (cons "brand.new.Class" "p.new")))))
  t-frozen)
(gate-check "freeze: rejected new key not registered"
  (jolt-nil? (class-provider-for "brand.new.Class")) #t)
(let ((data
        (t-error-data
          (lambda ()
            (class-provider-register-many!
              (list (cons "first.new.Class" "p.first")
                    (cons "second.new.Class" "p.second")))))))
  (gate-check "freeze: multi-key diagnostic reports first declaration"
    (pmap-get data t-class-kw jolt-nil) "first.new.Class")
  (gate-check "freeze: multi-key batch remains atomic"
    (and (jolt-nil? (class-provider-for "first.new.Class"))
         (jolt-nil? (class-provider-for "second.new.Class")))
    #t))
(class-provider-reset-many! '())
(gate-check "reset thaws: new registration works after reset"
  (t-error-type (lambda () (class-provider-register-many!
                             (list (cons "after.reset.Thing" "p.post")))))
  'no-error)
(gate-check "reset thaws: new key registered"
  (class-provider-for "after.reset.Thing") "p.post")

;; --- exact lookup -----------------------------------------------------------
(gate-check "exact lookup: hit returns provider"
  (class-provider-for "after.reset.Thing") "p.post")
(gate-check "exact lookup: miss returns nil"
  (jolt-nil? (class-provider-for "no.such.Class")) #t)

;; --- deterministic mappings / namespaces ------------------------------------
;; mappings: sorted by class. namespaces: sorted + deduplicated (a provider shared
;; by several classes appears once). Stable regardless of table iteration order.
(class-provider-reset-many!
  (list (cons "z.last.Z" "p.shared")
        (cons "a.first.A" "p.shared")
        (cons "m.mid.M" "p.other")))
(gate-check "mappings sorted by class"
  (class-provider-mappings)
  (list (cons "a.first.A" "p.shared")
        (cons "m.mid.M" "p.other")
        (cons "z.last.Z" "p.shared")))
(gate-check "namespaces sorted and deduplicated"
  (class-provider-namespaces) (list "p.other" "p.shared"))

;; --- reset replaces entirely ------------------------------------------------
(class-provider-reset-many! (list (cons "only.one.O" "p.solo")))
(gate-check "reset replaces mappings"
  (class-provider-mappings) (list (cons "only.one.O" "p.solo")))
(gate-check "reset removed prior keys"
  (jolt-nil? (class-provider-for "a.first.A")) #t)

;; --- monotonic generation ---------------------------------------------------
;; Generation never decreases; it increases on a register that adds keys and on a
;; reset (the clear), and is unchanged by an idempotent re-declaration.
(class-provider-reset-many! '())
(let ((g0 (class-provider-generation)))
  (class-provider-register-many! (list (cons "m1.a.A" "p1")))
  (let ((g1 (class-provider-generation)))
    (class-provider-register-many! (list (cons "m1.a.A" "p1")))  ; idempotent
    (let ((g2 (class-provider-generation)))
      (class-provider-register-many! (list (cons "m1.b.B" "p2")))  ; new
      (let ((g3 (class-provider-generation)))
        (gate-check "monotonic: new key increases generation" (> g1 g0) #t)
        (gate-check "monotonic: idempotent holds generation" (= g2 g1) #t)
        (gate-check "monotonic: second new key increases again" (> g3 g2) #t)))))
(let ((gb (class-provider-generation)))
  (class-provider-reset-many! '())
  (gate-check "monotonic: reset increases generation"
    (> (class-provider-generation) gb) #t))

(gate-summary "class-provider-registry")
