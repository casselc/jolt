;; Ordinary-image gate: host/chez/java/ffi.ss, loaded WITHOUT the
;; simulation-only overlay (host/chez/sim/runtime.ss), carries none of the FFI
;; call-interception seam — no hook global, no install/clear/invoke vars, no
;; descriptor makers, no native-op wrappers — and jolt.ffi still binds and
;; calls native code exactly like ordinary Jolt. Run:
;;   chez --script test/chez/ordinary-ffi-no-sim-hook-test.ss
;;
;; This is the base-image counterpart to ffi-sim-hook-test.ss and
;; ffi-native-sim-hook-test.ss, which load the overlay explicitly and exercise
;; the hook itself.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/ffi.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (ev s) (jolt-compile-eval s "user"))

;; --- the overlay's symbols must not exist in the ordinary image -------------
(for-each
 (lambda (sym)
   (ok (string-append "ordinary image has no " (symbol->string sym) " binding")
       (not (top-level-bound? sym))))
 '(jolt-ffi-sim-hook
   jolt-ffi-sim-hook-top
   jolt-ffi-sim-hook-mu
   jolt-ffi-sim-hook-active-owner
   jolt-ffi-sim-hook-installation?
   make-jolt-ffi-sim-hook-installation
   jolt-ffi-install-sim-hook!
   jolt-ffi-clear-sim-hook!
   jolt-ffi-make-sim-descriptor
   jolt-ffi-invoke-sim-hook
   jolt-ffi-make-native-sim-descriptor
   jolt-ffi-invoke-native-sim-op
   ffi-sim-load-library
   ffi-sim-loaded?
   ffi-sim-alloc
   ffi-sim-free
   ffi-sim-read
   ffi-sim-write
   ffi-sim-sizeof
   ffi-sim-read-bytes
   ffi-sim-write-bytes
   ffi-sim-read-array
   ffi-sim-write-array
   ffi-sim-ptr->string
   ffi-sim-string->ptr
   ;; the jolt.internal.sim FFI controller projection (host/chez/sim/
   ;; runtime.ss's "jolt.internal.sim/install-ffi-controller! +
   ;; restore-ffi-controller!" section) is layered over the hook above, so it
   ;; is equally absent from an ordinary image.
   jolt-ffi-sim-cfn-desc-keys
   jolt-ffi-sim-native-desc-keys
   jolt-sim-ffi-descriptor-keys
   jolt-sim-ffi-native-operation-names
   jolt-sim-ffi-project-descriptor
   jolt-sim-make-ffi-controller-wrapper
   jolt-sim-install-ffi-controller!
   jolt-sim-restore-ffi-controller!
   jolt-sim-kw-kind
   jolt-sim-kw-foreign-function
   jolt-sim-kw-native-operation
   jolt-sim-kw-symbol
   jolt-sim-kw-argument-types
   jolt-sim-kw-return-type
   jolt-sim-kw-blocking?
   jolt-sim-kw-operation
   jolt-sim-kw-ffi-interception
   jolt-sim-kw-descriptor-version
   jolt-sim-kw-kinds
   jolt-sim-kw-arguments
   jolt-sim-kw-live
   jolt-sim-kw-task-identity
   jolt-sim-kw-native-operations))

;; --- the jolt.internal.sim namespace itself carries no vars ------------------
(ok "ordinary image has registered no vars under jolt.internal.sim"
    (not (var-cell-lookup "jolt.internal.sim" "install-ffi-controller!")))

;; --- fully-qualified resolution from ordinary Jolt source fails closed too ---
(ok "ordinary Jolt source cannot resolve jolt.internal.sim/install-ffi-controller!"
    (guard (e (#t #t))
      (ev "(jolt.internal.sim/install-ffi-controller! (fn [d] d))")
      #f))

;; --- ordinary FFI binding/calling behavior is unaffected ---------------------
(ev "(jolt.ffi/load-library)")
(ev "(def c-strlen (jolt.ffi/__cfn \"strlen\" [:string] :size_t))")
(ok "ordinary defcfn call reaches native code with no overlay loaded"
    (= 5 (jnum->exact (ev "(c-strlen \"hello\")"))))

;; Exercise the raw primitives directly (jolt.ffi/… above already pins the
;; def-var! surface) to confirm the ordinary bodies run unchanged.
(let ((p (ffi-alloc 4)))
  (ffi-write p "int" 0 12345)
  (ok "ffi-write/ffi-read round-trip with no overlay loaded"
      (= 12345 (ffi-read p "int")))
  (ffi-free p))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
