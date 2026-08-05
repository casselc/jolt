;; Internal raw-native-op interception gate.  The native-op seam rides the same
;; hook, installation stack, activation cell, and proceed contract as declared
;; calls (host/chez/java/ffi.ss), and this gate also drives declared calls
;; through that one hook, so run it against a fresh transient seed through
;; host/chez/transient-seed-gate.sh:
;;
;;   CHEZ=/path/to/chez sh host/chez/transient-seed-gate.sh \
;;     test/chez/ffi-native-sim-hook-test.ss
;;
;; The wrapper passes the fresh PRELUDE and IMAGE as the two script arguments.

(import (chezscheme))

(define seed-args (cdr (command-line)))
(unless (= (length seed-args) 2)
  (display "usage: ffi-native-sim-hook-test.ss PRELUDE IMAGE\n"
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

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a~n" name)))
(define (ev source) (jolt-compile-eval source "user"))
(define (dget descriptor key) (cdr (assq key descriptor)))
(define (throws? thunk)
  (guard (e (#t #t)) (thunk) #f))

;; One real declared binding, to prove declared calls and raw ops share the one
;; hook, plus the exposed alloc var for direct jolt-invoke probes.
(ev "(require '[jolt.ffi :as ffi])")
(ev "(ffi/load-library)")
(ev "(ffi/defcfn nhook-abs \"abs\" [:int] :int)")
(define alloc-fn (ev "ffi/alloc"))
(define free-fn (ev "ffi/free"))

;; --- A. disabled baseline: ordinary jolt code and the real OS are unchanged --
(ok "hook is disabled by default" (not jolt-ffi-declared-call-hook))
(ok "disabled alloc/write/read/free uses real memory"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 8)]
            (ffi/write p :int 0 -7)
            (let [v (ffi/read p :int)]
              (ffi/free p)
              (= v -7)))")))
(ok "disabled write and free return nil"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 8)]
            (and (nil? (ffi/write p :int 0 1)) (nil? (ffi/free p))))")))
(ok "disabled sizeof answers the real layout"
    (= 4 (jnum->exact (ev "(ffi/sizeof :int)"))))
(ok "disabled null?/null behave"
    (jolt-truthy?
     (ev "(and (ffi/null? ffi/null) (not (ffi/null? 16)))")))
(ok "disabled read-bytes/write-bytes roundtrip"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 8)]
            (try
              (and (= 2 (ffi/write-bytes p \"hi\"))
                   (= \"hi\" (ffi/read-bytes p 2)))
              (finally (ffi/free p))))")))
(ok "disabled array transfers roundtrip whole and ranged"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 4)]
            (try
              (and (= 4 (ffi/write-array p (byte-array [10 20 30 40])))
                   (= [10 20 30 40] (vec (ffi/read-array p 4)))
                   (= 2 (ffi/write-array p (byte-array [1 2 3 4]) 1 2))
                   (let [d (byte-array [0 0 0 0])]
                     (and (= 4 (ffi/read-array! p 4 d 0))
                          (= [2 3 30 40] (vec d)))))
              (finally (ffi/free p))))")))
(ok "disabled string->ptr/ptr->string roundtrip"
    (jolt-truthy?
     (ev "(let [p (ffi/string->ptr \"native-ok\")]
            (try (= \"native-ok\" (ffi/ptr->string p))
              (finally (ffi/free p))))")))
(ok "disabled load-library/loaded? reach the real OS loader"
    (jolt-truthy?
     (ev "(and (nil? (ffi/load-library))
               (not (ffi/loaded? \"definitely_not_a_real_lib_zzz9.so\")))")))

;; --- B. substitution: the model's answer is returned unwrapped ---------------
;; A recording controller answers every operation from a fake pointer model.
;; read-array! deliberately writes through the LIVE destination array carried
;; in the descriptor, and answers a count the real call would not produce.
(define native-descriptors '())
(define (substitute-native-hook descriptor proceed)
  (set! native-descriptors (append native-descriptors (list descriptor)))
  (let ((op (dget descriptor 'op)) (args (dget descriptor 'args)))
    (cond
      ((string=? op "alloc") 4096)
      ((string=? op "free") 555)
      ((string=? op "write") 556)
      ((string=? op "read") -77)
      ((string=? op "sizeof") 64)
      ((string=? op "null?") #t)
      ((string=? op "read-bytes") "simulated")
      ((string=? op "write-bytes") 123)
      ((string=? op "read-array") (make-jolt-array (vector 5 6 -7) 'byte))
      ((string=? op "read-array!")
       (vector-set! (jolt-array-vec (list-ref args 2))
                    (jnum->exact (list-ref args 3)) 66)
       3)
      ((string=? op "write-array") (if (= 2 (length args)) 201 202))
      ((string=? op "ptr->string") "modeled")
      ((string=? op "string->ptr") 8192)
      ((string=? op "load-library") 901)
      ((string=? op "loaded?") #t)
      (else (error 'substitute-native-hook "unexpected op" op)))))
(define substitution-token
  (jolt-ffi-install-declared-call-hook! substitute-native-hook))

(ok "alloc is substituted unwrapped"
    (= 4096 (jnum->exact (ev "(ffi/alloc 8)"))))
(ok "free substitution replaces the nil return unwrapped"
    (= 555 (jnum->exact (ev "(ffi/free 4096)"))))
(ok "write substitution replaces the nil return unwrapped"
    (= 556 (jnum->exact (ev "(ffi/write 4096 :int 0 1)"))))
(ok "two-arg read is substituted unwrapped"
    (= -77 (jnum->exact (ev "(ffi/read 4096 :int)"))))
(ok "three-arg read is substituted unwrapped"
    (= -77 (jnum->exact (ev "(ffi/read 4096 :int 4)"))))
(ok "sizeof is substituted unwrapped"
    (= 64 (jnum->exact (ev "(ffi/sizeof :int)"))))
(ok "null? substitution controls the answer for a nonzero pointer"
    (jolt-truthy? (ev "(ffi/null? 4096)")))
(ok "read-bytes is substituted unwrapped"
    (string=? "simulated" (ev "(ffi/read-bytes 4096 3)")))
(ok "write-bytes substitution replaces the count unwrapped"
    (= 123 (jnum->exact (ev "(ffi/write-bytes 4096 \"abc\")"))))
(ok "read-array substitution supplies the array"
    (jolt-truthy? (ev "(= [5 6 -7] (vec (ffi/read-array 4096 3)))")))
(define dest-arr (ev "(byte-array [0 0 0 0])"))
(define read-array!-fn (ev "ffi/read-array!"))
(ok "read-array! substitution returns the model's count unwrapped"
    (= 3 (jnum->exact (jolt-invoke read-array!-fn 4096 1 dest-arr 2))))
(ok "read-array! substitution sees and mutates the live destination"
    (= 66 (vector-ref (jolt-array-vec dest-arr) 2)))
(ok "whole-array write-array is substituted unwrapped"
    (= 201 (jnum->exact (ev "(ffi/write-array 4096 (byte-array [1 2 3]))"))))
(ok "ranged write-array is substituted unwrapped"
    (= 202 (jnum->exact (ev "(ffi/write-array 4096 (byte-array [1 2 3]) 1 2)"))))
(ok "ptr->string is substituted unwrapped"
    (string=? "modeled" (ev "(ffi/ptr->string 4096)")))
(ok "string->ptr is substituted unwrapped"
    (= 8192 (jnum->exact (ev "(ffi/string->ptr \"x\")"))))
(ok "load-library of a nonexistent library is substituted before the OS loader"
    (= 901 (jnum->exact (ev "(ffi/load-library \"not_a_real_lib_zzz9.so\")"))))
(ok "no-arg load-library is substituted unwrapped"
    (= 901 (jnum->exact (ev "(ffi/load-library)"))))
(ok "loaded? of a nonexistent library is substituted"
    (jolt-truthy? (ev "(ffi/loaded? \"not_a_real_lib_zzz9.so\")")))

(ok "eighteen calls produce eighteen descriptors"
    (= 18 (length native-descriptors)))
(let ((d (list-ref native-descriptors 0)))
  (ok "descriptor kind is native-op" (eq? 'native-op (dget d 'kind)))
  (ok "descriptor op name is exact" (string=? "alloc" (dget d 'op)))
  (ok "descriptor arguments are exact" (equal? '(8) (dget d 'args))))
(let ((args (dget (list-ref native-descriptors 3) 'args)))
  (ok "two-arg read descriptor carries pointer and live type keyword"
      (and (= 2 (length args)) (= 4096 (car args))
           (keyword-t? (cadr args))
           (string=? "int" (keyword-t-name (cadr args))))))
(let ((args (dget (list-ref native-descriptors 4) 'args)))
  (ok "three-arg read descriptor carries the offset"
      (and (= 3 (length args)) (= 4 (list-ref args 2)))))
(let ((args (dget (list-ref native-descriptors 2) 'args)))
  (ok "write descriptor carries pointer, type, offset, and value"
      (and (= 4 (length args)) (= 1 (list-ref args 3)))))
(let ((d (list-ref native-descriptors 10)))
  (ok "read-array! descriptor op name is exact"
      (string=? "read-array!" (dget d 'op)))
  (ok "read-array! descriptor carries live destination and range"
      (let ((args (dget d 'args)))
        (and (= 4 (length args))
             (= 4096 (list-ref args 0)) (= 1 (list-ref args 1))
             (eq? dest-arr (list-ref args 2)) (= 2 (list-ref args 3))))))
(ok "write-array descriptor argument count discriminates its arities"
    (let ((whole (dget (list-ref native-descriptors 11) 'args))
          (ranged (dget (list-ref native-descriptors 12) 'args)))
      (and (= 2 (length whole))
           (= 4 (length ranged))
           (= 1 (list-ref ranged 2)) (= 2 (list-ref ranged 3)))))
(ok "load-library descriptor carries the library name"
    (equal? '("not_a_real_lib_zzz9.so")
            (dget (list-ref native-descriptors 15) 'args)))
(ok "no-arg load-library descriptor arguments are empty"
    (null? (dget (list-ref native-descriptors 16) 'args)))

;; Metadata is a per-call snapshot.  Corrupt the first descriptor's op string,
;; then intercept the same operation again and require pristine metadata.
(string-set! (dget (list-ref native-descriptors 0) 'op) 0 #\X)
(ok "repeated alloc is still substituted"
    (= 4096 (jnum->exact (ev "(ffi/alloc 4)"))))
(let ((d (list-ref native-descriptors 18)))
  (ok "later op metadata is independent" (string=? "alloc" (dget d 'op)))
  (ok "later arguments are their own snapshot" (equal? '(4) (dget d 'args))))
(jolt-ffi-clear-declared-call-hook! substitution-token)

;; loaded? keeps its Boolean public contract under substitution: a hook's jolt
;; nil or #f answers "not loaded" — a Scheme `if` would misread nil as true.
(define loaded-nil-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed) jolt-nil)))
(ok "loaded? substitution of jolt nil becomes false, not true"
    (jolt-truthy? (ev "(false? (ffi/loaded? \"anything_zzz9.so\"))")))
(jolt-ffi-clear-declared-call-hook! loaded-nil-token)
(define loaded-false-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed) #f)))
(ok "loaded? substitution of scheme false becomes false"
    (jolt-truthy? (ev "(false? (ffi/loaded? \"anything_zzz9.so\"))")))
(jolt-ffi-clear-declared-call-hook! loaded-false-token)

;; --- C. proceed executes the exact original operation ------------------------
(define proceed-all-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed) (jolt-invoke0 proceed))))
(ok "proceeded alloc/write/read/free roundtrip uses real memory"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 8)]
            (ffi/write p :int 0 -7)
            (let [v (ffi/read p :int)]
              (ffi/free p)
              (= v -7)))")))
(ok "proceeded write and free preserve the nil returns"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 8)]
            (and (nil? (ffi/write p :int 0 1)) (nil? (ffi/free p))))")))
(ok "proceeded write-bytes preserves the byte count and content"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 8)]
            (try
              (and (= 2 (ffi/write-bytes p \"hi\"))
                   (= \"hi\" (ffi/read-bytes p 2)))
              (finally (ffi/free p))))")))
(ok "proceeded array transfers preserve whole and ranged semantics"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 4)]
            (try
              (and (= 4 (ffi/write-array p (byte-array [10 20 30 40])))
                   (= [10 20 30 40] (vec (ffi/read-array p 4)))
                   (= 2 (ffi/write-array p (byte-array [1 2 3 4]) 1 2))
                   (let [d (byte-array [0 0 0 0])]
                     (and (= 4 (ffi/read-array! p 4 d 0))
                          (= [2 3 30 40] (vec d)))))
              (finally (ffi/free p))))")))
(ok "proceeded transfers fold octets 0x80/0xff to signed -128/-1"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 2)]
            (try
              (do (ffi/write p :uint8 0 128)
                  (ffi/write p :uint8 1 255)
                  (and (= [-128 -1] (vec (ffi/read-array p 2)))
                       (= 128 (ffi/read p :uint8 0))
                       (= 255 (ffi/read p :uint8 1))
                       (let [d (byte-array 2)]
                         (and (= 2 (ffi/read-array! p 2 d 0))
                              (= [-128 -1] (vec d))))))
              (finally (ffi/free p))))")))
(ok "proceeded write-array masks signed bytes to octets"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 2)]
            (try
              (and (= 2 (ffi/write-array p (byte-array [-128 -1])))
                   (= 128 (ffi/read p :uint8 0))
                   (= 255 (ffi/read p :uint8 1)))
              (finally (ffi/free p))))")))
(ok "proceeded string->ptr/ptr->string roundtrip is real"
    (jolt-truthy?
     (ev "(let [p (ffi/string->ptr \"proceed-ok\")]
            (try (= \"proceed-ok\" (ffi/ptr->string p))
              (finally (ffi/free p))))")))
(ok "proceeded sizeof answers the real layout"
    (= 4 (jnum->exact (ev "(ffi/sizeof :int)"))))
(ok "proceeded null?/null behave"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 4)]
            (try
              (and (ffi/null? ffi/null) (not (ffi/null? p)))
              (finally (ffi/free p))))")))
(ok "proceeded load-library/loaded? reach the real OS loader"
    (jolt-truthy?
     (ev "(and (nil? (ffi/load-library))
               (not (ffi/loaded? \"definitely_not_a_real_lib_zzz9.so\")))")))
;; The same hook installation serves both descriptor kinds.
(ok "one hook proceeds a declared foreign call"
    (= 9 (jnum->exact (ev "(nhook-abs -9)"))))
(ok "the same hook proceeds a raw native operation"
    (= 4 (jnum->exact (ev "(ffi/sizeof :int)"))))

;; --- D. validation and exception behavior are the operation's own ------------
;; Under proceed, the exact original validation fires; disabled behaves the
;; same.  A substitution instead owns semantics entirely — an out-of-bounds
;; call is the model's to answer, with no destination mutation.
(ok "proceed preserves read-array! range validation"
    (jolt-truthy?
     (ev "(let [d (byte-array [9 9])]
            (try (ffi/read-array! ffi/null 99 d 0) false
              (catch IndexOutOfBoundsException _ (= [9 9] (vec d)))))")))
(ok "proceed preserves byte-array kind validation"
    (jolt-truthy?
     (ev "(try (ffi/read-array! ffi/null 1 [0 1 2] 0) false
            (catch IllegalArgumentException _ true))")))
(ok "proceed preserves null-pointer rejection for a non-empty transfer"
    (jolt-truthy?
     (ev "(try (ffi/read-array! ffi/null 1 (byte-array 2) 0) false
            (catch NullPointerException _ true))")))
(ok "proceed preserves ranged write-array bounds validation"
    (jolt-truthy?
     (ev "(try (ffi/write-array ffi/null (byte-array [1 2 3]) 2 2) false
            (catch IndexOutOfBoundsException _ true))")))
(ok "proceed preserves read-array! negative-offset rejection"
    (jolt-truthy?
     (ev "(let [d (byte-array [9 9])]
            (try (ffi/read-array! ffi/null 1 d -1) false
              (catch IndexOutOfBoundsException _ (= [9 9] (vec d)))))")))
(ok "proceed preserves read-array! negative-length rejection"
    (jolt-truthy?
     (ev "(let [d (byte-array [9 9])]
            (try (ffi/read-array! ffi/null -1 d 0) false
              (catch IndexOutOfBoundsException _ (= [9 9] (vec d)))))")))
(ok "proceed preserves the exact empty-tail read-array! range"
    (jolt-truthy?
     (ev "(let [d (byte-array [9 9])]
            (and (= 0 (ffi/read-array! ffi/null 0 d 2)) (= [9 9] (vec d))))")))
(ok "proceed preserves the exact empty-tail ranged write-array"
    (= 0 (jnum->exact
          (ev "(ffi/write-array ffi/null (byte-array [1 2]) 2 0)"))))
(ok "proceed preserves ranged write-array kind rejection"
    (jolt-truthy?
     (ev "(try (ffi/write-array ffi/null [0 1 2] 0 1) false
            (catch IllegalArgumentException _ true))")))
(ok "proceed preserves ranged write-array non-empty null rejection"
    (jolt-truthy?
     (ev "(try (ffi/write-array ffi/null (byte-array [1]) 0 1) false
            (catch NullPointerException _ true))")))
(jolt-ffi-clear-declared-call-hook! proceed-all-token)
(ok "disabled read-array! range validation matches the proceed path"
    (jolt-truthy?
     (ev "(let [d (byte-array [9 9])]
            (try (ffi/read-array! ffi/null 99 d 0) false
              (catch IndexOutOfBoundsException _ (= [9 9] (vec d)))))")))
(ok "disabled null-pointer rejection matches the proceed path"
    (jolt-truthy?
     (ev "(try (ffi/read-array! ffi/null 1 (byte-array 2) 0) false
            (catch NullPointerException _ true))")))
(define bypass-token
  (jolt-ffi-install-declared-call-hook! (lambda (descriptor proceed) 3)))
(ok "substitution owns semantics: out-of-bounds read-array! is the model's call"
    (jolt-truthy?
     (ev "(let [d (byte-array [0 0])]
            (and (= 3 (ffi/read-array! 4096 99 d 0)) (= [0 0] (vec d))))")))
(jolt-ffi-clear-declared-call-hook! bypass-token)

;; --- E. zero-length transfers and null pointers ------------------------------
;; Disabled and proceed return the real 0; a substituting controller sees the
;; null-pointer zero-length descriptor and answers for itself.
(ok "disabled zero-length read-array! at a null pointer returns 0"
    (= 0 (jnum->exact (ev "(ffi/read-array! ffi/null 0 (byte-array 1) 0)"))))
(ok "disabled zero-length ranged write-array at a null pointer returns 0"
    (= 0 (jnum->exact
          (ev "(ffi/write-array ffi/null (byte-array [1]) 1 0)"))))
(define zero-descriptors '())
(define zero-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (set! zero-descriptors (append zero-descriptors (list descriptor)))
     (let ((op (dget descriptor 'op)))
       (cond
         ((string=? op "read-array!") 71)
         ((string=? op "write-array") 72)
         (else (jolt-invoke0 proceed)))))))
(ok "zero-length read-array! is intercepted and substituted unwrapped"
    (= 71 (jnum->exact (ev "(ffi/read-array! ffi/null 0 (byte-array 1) 0)"))))
(ok "zero-length ranged write-array is intercepted and substituted unwrapped"
    (= 72 (jnum->exact
           (ev "(ffi/write-array ffi/null (byte-array [1]) 1 0)"))))
(ok "zero-length descriptors carry the exact null pointer and zero length"
    (let ((ra (dget (list-ref zero-descriptors 0) 'args))
          (wa (dget (list-ref zero-descriptors 1) 'args)))
      (and (= 0 (list-ref ra 0)) (= 0 (list-ref ra 1))
           (= 0 (list-ref wa 0)) (= 0 (list-ref wa 3)))))
(jolt-ffi-clear-declared-call-hook! zero-token)
(define zero-proceed-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed) (jolt-invoke0 proceed))))
(ok "proceeded zero-length read-array! returns the real 0"
    (= 0 (jnum->exact (ev "(ffi/read-array! ffi/null 0 (byte-array 1) 0)"))))
(ok "proceeded zero-length ranged write-array returns the real 0"
    (= 0 (jnum->exact
          (ev "(ffi/write-array ffi/null (byte-array [1]) 1 0)"))))
(jolt-ffi-clear-declared-call-hook! zero-proceed-token)

;; --- F. with-byte-array-pointer: enclosed ops, untouched lifecycle -----------
;; The loan scope itself is NOT an intercepted operation.  The jolt.ffi calls
;; its callback makes on the loaned pointer are intercepted normally, and
;; proceeding them operates on the real loaned memory, so copy-back still
;; lands in the original array.
(define loan-descriptors '())
(define loan-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (set! loan-descriptors (append loan-descriptors (list descriptor)))
     (jolt-invoke0 proceed))))
(ok "loaned callback's enclosed ops intercept and proceed against the real loan"
    (jolt-truthy?
     (ev "(let [arr (byte-array [10 20 30 40])]
            (let [seen (ffi/with-byte-array-pointer arr
                         (fn [p len]
                           (ffi/write p :uint8 1 99)
                           (ffi/read p :uint8 1)))]
              (and (= 99 seen) (= 99 (nth arr 1)))))")))
(ok "loan scope itself is not an intercepted operation"
    (not (exists (lambda (d)
                   (and (eq? 'native-op (dget d 'kind))
                        (string=? "with-byte-array-pointer" (dget d 'op))))
                 loan-descriptors)))
(ok "enclosed write and read were intercepted with the loaned pointer"
    (let ((write-d (find (lambda (d) (string=? "write" (dget d 'op)))
                         loan-descriptors))
          (read-d (find (lambda (d) (string=? "read" (dget d 'op)))
                        loan-descriptors)))
      (and write-d read-d
           (> (car (dget write-d 'args)) 0)
           (equal? (cddr (dget write-d 'args)) '(1 99))
           (> (car (dget read-d 'args)) 0))))
(jolt-ffi-clear-declared-call-hook! loan-token)

;; --- G. proceed and hook lifetimes -------------------------------------------
;; Proceed is synchronous, same-owner-thread, and at-most-once; a saved or
;; cross-thread proceed fails closed, direct nested interception from a
;; controller fails closed, and a synchronous callback reached through proceed
;; starts a fresh interception.
(define second-proceed-rejected? #f)
(define twice-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (let ((answer (jolt-invoke0 proceed)))
       (set! second-proceed-rejected?
             (throws? (lambda () (jolt-invoke0 proceed))))
       answer))))
(define real-pv (ev "(ffi/alloc 8)"))
(ok "first native proceed returns the real allocation"
    (> (jnum->exact real-pv) 0))
(ok "second native proceed call fails closed" second-proceed-rejected?)
(jolt-ffi-clear-declared-call-hook! twice-token)
(ok "cleared free of the proceeded allocation returns nil"
    (jolt-nil? (jolt-invoke free-fn real-pv)))

(define saved-proceed #f)
(define saved-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed) (set! saved-proceed proceed) 4096)))
(ok "controller may substitute while retaining a proceed reference"
    (= 4096 (jnum->exact (ev "(ffi/alloc 8)"))))
(ok "saved native proceed fails after its hook returns"
    (throws? (lambda () (jolt-invoke0 saved-proceed))))
(jolt-ffi-clear-declared-call-hook! saved-token)

(define nested-rejected? #f)
(define kw-int (ev ":int"))
(define nested-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (set! nested-rejected? (throws? (lambda () (ffi-sizeof kw-int))))
     64)))
(ok "controller survives its rejected nested native op"
    (= 64 (jnum->exact (ev "(ffi/sizeof :int)"))))
(ok "direct nested native op without exact proceed fails closed"
    nested-rejected?)
(jolt-ffi-clear-declared-call-hook! nested-token)

;; A synchronous callback reached through proceed starts with no active hook
;; invocation: the inner ffi-sizeof is freshly intercepted by the installed
;; hook instead of failing as same-thread controller nesting.
(define fresh-interceptions 0)
(define fresh-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (if (and (eq? 'native-op (dget descriptor 'kind))
              (string=? "sizeof" (dget descriptor 'op)))
         (begin (set! fresh-interceptions (+ fresh-interceptions 1)) 64)
         (jolt-invoke0 proceed)))))
(define probe-result
  (jolt-ffi-invoke-native-op-hook
   (lambda (descriptor proceed) (jolt-invoke0 proceed))
   "probe-outer" '()
   (lambda () (ffi-sizeof kw-int))))
(ok "proceed permits a synchronous callback to start fresh interception"
    (= 64 probe-result))
(ok "callback's native op is intercepted exactly once" (= 1 fresh-interceptions))
(ok "callback passthrough restores no owner activation after return"
    (not (jolt-ffi-current-declared-call-activation)))
(jolt-ffi-clear-declared-call-hook! fresh-token)

;; The descriptor list spine is the controller's own snapshot; proceed always
;; applies its untouched lexical arguments.  Mutating descriptor args before
;; proceed must not redirect the real operation — including the pointer offset.
;; Both mutations below stay inside the original allocation/library name, so a
;; regression fails the check without ever performing an unsafe read.
(define mutant-load-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (when (and (eq? 'native-op (dget descriptor 'kind))
                (string=? "load-library" (dget descriptor 'op))
                (pair? (dget descriptor 'args)))
       (set-car! (dget descriptor 'args) "not_a_real_lib_zzz9.so"))
     (jolt-invoke0 proceed))))
(ok "load-library proceed applies its untouched lexical arguments"
    (jolt-nil?
     (guard (e (#t 'threw))
       (ev "(ffi/load-library nil)"))))
(jolt-ffi-clear-declared-call-hook! mutant-load-token)

(define mutant-read-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (when (and (eq? 'native-op (dget descriptor 'kind))
                (string=? "read" (dget descriptor 'op))
                (pair? (cddr (dget descriptor 'args))))
       (set-car! (cddr (dget descriptor 'args)) 0))
     (jolt-invoke0 proceed))))
(ok "read proceed applies its untouched lexical offset"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 2)]
            (ffi/write p :uint8 0 11)
            (ffi/write p :uint8 1 22)
            (let [v (ffi/read p :uint8 1)]
              (ffi/free p)
              (= v 22)))")))
(jolt-ffi-clear-declared-call-hook! mutant-read-token)

;; A proceed invoked from a thread other than its owner fails closed while the
;; owning hook invocation is still in extent — discriminating the owner-tag
;; rejection from ordinary extent retirement.  The wait is bounded.
(define xt-mu (make-mutex))
(define xt-cv (make-condition))
(define xt-result #f)
(define xt-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (fork-thread
      (lambda ()
        (guard (e (#t (with-mutex xt-mu
                        (set! xt-result 'rejected)
                        (condition-broadcast xt-cv))))
          (jolt-invoke0 proceed)
          (with-mutex xt-mu
            (set! xt-result 'used)
            (condition-broadcast xt-cv)))))
     (let ((deadline (ms->deadline 5000)))
       (with-mutex xt-mu
         (let loop ()
           (unless xt-result
             (unless (condition-wait xt-cv xt-mu deadline)
               (error 'ffi-native-sim-hook-test
                      "timed out waiting for cross-thread proceed"))
             (loop)))))
     801)))
(ok "cross-thread proceed attempt completes inside the owner's extent"
    (= 801 (jnum->exact (ev "(ffi/alloc 8)"))))
(ok "cross-thread native proceed fails closed" (eq? 'rejected xt-result))
(jolt-ffi-clear-declared-call-hook! xt-token)

;; A child thread inherits its creator's parameter cell.  Owner tagging lets it
;; enter its own interception instead of being treated as controller nesting.
(define kid-mu (make-mutex))
(define kid-cv (make-condition))
(define kid-result #f)
(define kid-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (let ((args (dget descriptor 'args)))
       (cond
         ((equal? '(16) args)
          (fork-thread
           (lambda ()
             (let ((answer (jnum->exact (jolt-invoke alloc-fn 24))))
               (with-mutex kid-mu
                 (set! kid-result answer)
                 (condition-broadcast kid-cv)))))
          801)
         ((equal? '(24) args) 802)
         (else (jolt-invoke0 proceed)))))))
(ok "parent controller starts child probe"
    (= 801 (jnum->exact (ev "(ffi/alloc 16)"))))
(let ((deadline (ms->deadline 5000)))
  (with-mutex kid-mu
    (let loop ()
      (unless kid-result
        (unless (condition-wait kid-cv kid-mu deadline)
          (error 'ffi-native-sim-hook-test
                 "timed out waiting for inherited-owner child"))
        (loop)))))
(ok "inherited child owner enters an independent interception"
    (= 802 kid-result))
(jolt-ffi-clear-declared-call-hook! kid-token)

;; --- H. the one token stack, both kinds, and clean restoration ---------------
(define stack-outer-token
  (jolt-ffi-install-declared-call-hook! (lambda (descriptor proceed) 100)))
(define stack-inner-token
  (jolt-ffi-install-declared-call-hook! (lambda (descriptor proceed) 200)))
(ok "nested install selects the inner hook for native ops"
    (= 200 (jnum->exact (ev "(ffi/sizeof :int)"))))
(ok "out-of-order clear fails closed for native ops"
    (throws? (lambda () (jolt-ffi-clear-declared-call-hook! stack-outer-token))))
(ok "failed clear preserves the inner hook"
    (= 200 (jnum->exact (ev "(ffi/sizeof :int)"))))
(jolt-ffi-clear-declared-call-hook! stack-inner-token)
(ok "clearing the inner hook restores the outer hook"
    (= 100 (jnum->exact (ev "(ffi/sizeof :int)"))))
(jolt-ffi-clear-declared-call-hook! stack-outer-token)
(ok "repeated clear of a retired token fails closed"
    (throws? (lambda () (jolt-ffi-clear-declared-call-hook! stack-outer-token))))
(ok "stack clear restores the real sizeof"
    (= 4 (jnum->exact (ev "(ffi/sizeof :int)"))))

;; One installed hook receives both descriptor kinds; dispatch on kind.
(define mixed-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed)
     (if (eq? 'foreign-call (dget descriptor 'kind)) 999 64))))
(ok "one hook substitutes a declared foreign call"
    (= 999 (jnum->exact (ev "(nhook-abs -9)"))))
(ok "the same hook substitutes a raw native operation"
    (= 64 (jnum->exact (ev "(ffi/sizeof :int)"))))
(jolt-ffi-clear-declared-call-hook! mixed-token)
(ok "clear restores the real declared call"
    (= 9 (jnum->exact (ev "(nhook-abs -9)"))))

;; Hook exceptions are not translated or wrapped.
(define native-sentinel (list 'ffi-native-op-sentinel))
(define sentinel-token
  (jolt-ffi-install-declared-call-hook!
   (lambda (descriptor proceed) (raise native-sentinel))))
(ok "controller-thrown sentinel propagates unchanged from a native op"
    (guard (e (#t (eq? e native-sentinel))) (ev "(ffi/alloc 8)") #f))
(jolt-ffi-clear-declared-call-hook! sentinel-token)
(ok "sentinel cleanup restores real native execution"
    (jolt-truthy?
     (ev "(let [p (ffi/alloc 8)]
            (ffi/write p :int 0 -7)
            (let [v (ffi/read p :int)]
              (ffi/free p)
              (= v -7)))")))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
