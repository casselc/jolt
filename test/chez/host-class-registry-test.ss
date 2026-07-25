;; Central host-class registration coherence. Each table row checks that one
;; predicate/FQN registration drives class, instance?, and protocol dispatch.
;;
;;   chez --script test/chez/host-class-registry-test.ss

(import (chezscheme))
(load "host/chez/run-gate-harness.ss")

(define (ev source) (jolt-compile-eval source "user"))
(define (label row suffix) (string-append (car row) " " suffix))
(define (contains-string? strings wanted)
  (if (member wanted strings) #t #f))

;; label, value factory, registered class, representative super/interface,
;; protocol-dispatch expression, expected protocol result.
(define cases
  (list
    (list "File"
          "(java.io.File. \"/tmp/jolt-host-class-registry\")"
          "java.io.File"
          "java.lang.Comparable"
          "(do
             (defprotocol HostClassFileProtocol (host-class-file [_]))
             (extend-protocol HostClassFileProtocol
               java.lang.Comparable (host-class-file [_] :comparable)
               Object (host-class-file [_] :object))
             (host-class-file (java.io.File. \"/tmp/jolt-host-class-registry\")))"
          ":comparable")
    (list "InputStream"
          "(java.io.ByteArrayInputStream. (byte-array [1 2 3]))"
          "java.io.InputStream"
          "java.io.Closeable"
          "(do
             (defprotocol HostClassInputProtocol (host-class-input [_]))
             (extend-protocol HostClassInputProtocol
               java.io.InputStream (host-class-input [_] :input-stream)
               Object (host-class-input [_] :object))
             (host-class-input
               (java.io.ByteArrayInputStream. (byte-array [1 2 3]))))"
          ":input-stream")
    (list "PersistentQueue"
          "(conj clojure.lang.PersistentQueue/EMPTY 1)"
          "clojure.lang.PersistentQueue"
          "clojure.lang.IPersistentStack"
          "(do
             (defprotocol HostClassQueueProtocol (host-class-queue [_]))
             (extend-protocol HostClassQueueProtocol
               clojure.lang.IPersistentStack (host-class-queue [_] :stack)
               Object (host-class-queue [_] :object))
             (host-class-queue
               (conj clojure.lang.PersistentQueue/EMPTY 1)))"
          ":stack")))

(for-each
  (lambda (row)
    (let* ((value (ev (cadr row)))
           (fqn (caddr row))
           (super (cadddr row))
           (tags (value-host-tags value)))
      (gate-check (label row "registry FQN")
                  (registered-host-class-fqn value)
                  fqn)
      (gate-check (label row "class")
                  (jolt-class-name value)
                  fqn)
      (gate-check (label row "own protocol tag")
                  (contains-string? tags fqn)
                  #t)
      (gate-check (label row "super protocol tag")
                  (contains-string? tags super)
                  #t)
      (gate-check (label row "instance? own class")
                  (instance-check (jolt-symbol #f fqn) value)
                  #t)
      (gate-check (label row "instance? super")
                  (instance-check (jolt-symbol #f super) value)
                  #t)
      (gate-check (label row "protocol dispatch")
                  (jolt-final-str (ev (list-ref row 4)))
                  (list-ref row 5))))
  cases)

;; FileInputStream and ByteArrayInputStream share the same in-stream record, so
;; claiming either concrete constructor would be unsound. The honest common-base
;; mapping is deliberately narrower than the legacy alias list.
(gate-check "InputStream concrete constructor identity is erased"
            (instance-check
              (jolt-symbol #f "java.io.ByteArrayInputStream")
              (ev "(java.io.ByteArrayInputStream. (byte-array [1]))"))
            #f)

;; A provider may extend the class graph after all four derived caches have
;; answered a miss. The new row must become visible immediately and its simple
;; name must resolve to the newly registered canonical FQN.
(define dynamic-provider-class "fixture.ProviderAddedInterface")
(define dynamic-provider-simple "ProviderAddedInterface")
(gate-check "dynamic class initial known miss"
            (jch-known? dynamic-provider-class)
            #f)
(gate-check "dynamic class initial simple-name miss"
            (jch-fqn-of-simple dynamic-provider-simple)
            dynamic-provider-simple)
(gate-check "dynamic class initial tag miss"
            (contains-string?
              (jch-tags dynamic-provider-class)
              "java.lang.AutoCloseable")
            #f)
(jch-register-supers!
  dynamic-provider-class
  '("java.lang.AutoCloseable"))
(gate-check "dynamic class invalidates known cache"
            (jch-known? dynamic-provider-class)
            #t)
(gate-check "dynamic class invalidates simple-name cache"
            (jch-fqn-of-simple dynamic-provider-simple)
            dynamic-provider-class)
(gate-check "dynamic class invalidates closure/tag caches"
            (contains-string?
              (jch-tags dynamic-provider-class)
              "java.lang.AutoCloseable")
            #t)

(gate-summary "host-class-registry")
