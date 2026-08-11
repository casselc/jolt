;; Atomic native-error capture gate for the v0.7.1 jolt.ffi contract.
;; Requires a seed reminted from the source analyzer/backend in this tree.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/loader.ss")
(set-source-roots! ldr-install-roots)
(load "host/chez/java/ffi.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a\n" name)))
(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))
(define (ev s) (jolt-compile-eval s "user"))
(define (evb s) (guard (e (#t #f)) (jolt-truthy? (ev s))))
(define (evi s) (guard (e (#t #f)) (jnum->exact (ev s))))

(ev "(require '[jolt.ffi :as ffi])")

(define helper-so (getenv "JOLT_FFI_NATIVE_ERROR_HELPER"))
(unless helper-so
  (error #f "JOLT_FFI_NATIVE_ERROR_HELPER must name the compiled helper library"))

;; Lazy symbol resolution must survive defining the binding before dlopen.
(ev "(def c-fail-late (jolt.ffi/__cfn \"jolt_ne_fail\" [:int] :int {:capture-native-error true}))")
(load-shared-object helper-so)

(ev "(def c-fail-scalar (jolt.ffi/__cfn \"jolt_ne_fail\" [:int] :int))")
(ev "(def c-fail-err (jolt.ffi/__cfn \"jolt_ne_fail\" [:int] :int {:capture-native-error true}))")
(ok "capture off returns the scalar result"
    (= -1 (evi "(c-fail-scalar 42)")))
(ok "capture on returns a vector"
    (evb "(vector? (c-fail-err 42))"))
(ok "capture result has exactly two elements"
    (evb "(= 2 (count (c-fail-err 42)))"))
(ok "capture order is [result error-code]"
    (evb "(= [-1 42] (c-fail-err 42))"))
(ok "sequential calls retain independent error codes"
    (evb "(let [a (c-fail-err 42) b (c-fail-err 13)] (= [a b] [[-1 42] [-1 13]]))"))

;; The compiler target, not the build host, selects the convention.
(define (native-error-convention-for-target target)
  (parameterize ((#%$target-machine target))
    (cadr
      (syntax->datum
        (expand
          (list 'sa-native-error-convention-case
                (list 'quote '__get_last_error)
                (list 'quote '__errno)))))))
(ok "Windows compiler target selects GetLastError"
    (eq? '__get_last_error (native-error-convention-for-target 'ta6nt)))
(ok "Linux x64 compiler target selects errno"
    (eq? '__errno (native-error-convention-for-target 'ta6le)))
(ok "Linux arm64 compiler target selects errno"
    (eq? '__errno (native-error-convention-for-target 'tarm64le)))
(ok "macOS arm64 compiler target selects errno"
    (eq? '__errno (native-error-convention-for-target 'tarm64osx)))
(ok "unknown compiler target fails closed"
    (raises? (lambda ()
               (native-error-convention-for-target 'future-a6le))))

;; Direct, macro, and defmacro paths must all reach the same lowering.
(ev "(def c-fail-ff (ffi/foreign-fn \"jolt_ne_fail\" [:int] :int {:capture-native-error true}))")
(ev "(ffi/defcfn c-fail-dc \"jolt_ne_fail\" [:int] :int {:capture-native-error true})")
(ok "public foreign-fn captures atomically"
    (evb "(= [-1 43] (c-fail-ff 43))"))
(ok "public defcfn captures atomically"
    (evb "(= [-1 44] (c-fail-dc 44))"))
(ok "capture lowering cannot be shadowed by a local call-with-values"
    (evb "(let [call-with-values (fn [& _] :shadowed)] (= [-1 45] (c-fail-err 45)))"))

;; v0.7.1's :varargs boundary and atomic capture must compose.
(ev "(def c-variadic-err (jolt.ffi/__cfn \"jolt_ne_variadic\" [:int :varargs :int] :int {:capture-native-error true}))")
(ok "varargs capture preserves result and error convention"
    (evb "(= [12345 46] (c-variadic-err 46 12345))"))

;; Blocking capture must retain collect safety on the same binding.
(ev "(def c-fail-block-err (jolt.ffi/__cfn \"jolt_ne_fail\" [:int] :int {:blocking true :capture-native-error true}))")
(ok "blocking capture returns the exact pair"
    (evb "(= [-1 47] (c-fail-block-err 47))"))
(ev "(def c-block-fail-err
       (jolt.ffi/__cfn \"jolt_ne_block_fail\" [:uint32 :int] :int
         {:blocking true :capture-native-error true}))")
(let ((block-fn (var-deref "user" "c-block-fail-err"))
      (mu (make-mutex))
      (cv (make-condition))
      (done? #f)
      (worker-result #f))
  (block-fn 0 0)
  (fork-thread
    (lambda ()
      (let ((result (guard (e (#t #f)) (block-fn 1500 73))))
        (with-mutex mu
          (set! worker-result result)
          (set! done? #t)
          (condition-signal cv)))))
  (let loop ((i 0))
    (when (fx<? i 30000000) (loop (fx+ i 1))))
  (ok "blocking capture permits a concurrent collection"
      (guard (e (#t #f)) (collect) #t))
  (with-mutex mu
    (let wait ()
      (unless done?
        (condition-wait cv mu)
        (wait))))
  (ok "blocking worker returns the exact captured pair"
      (and (jolt-vector? worker-result)
           (= 2 (pvec-count worker-result))
           (= -1 (jnum->exact (pvec-nth-d worker-result 0 jolt-nil)))
           (= 73 (jnum->exact (pvec-nth-d worker-result 1 jolt-nil))))))

(ok "capture binding defined before dlopen resolves on first call"
    (evb "(= [-1 48] (c-fail-late 48))"))
(ev "(def c-clobber-scalar (jolt.ffi/__cfn \"jolt_ne_clobber\" [:int] :int))")
(ok "captured result survives a later slot overwrite"
    (evb "(let [a (c-fail-err 49) _ (c-clobber-scalar 7)] (= [-1 49] a))"))

;; Compatibility helper used by existing libraries until their bindings opt in.
(ok "errno-source reports the exact POSIX accessor on this gate host"
    (evb "(contains? #{:errno-location :error :wsa-get-last-error} (ffi/errno-source))"))
(ok "immediate compatibility errno read observes the failing scalar call"
    (evb "(let [result (c-fail-scalar 50)] (= [result (ffi/errno)] [-1 50]))"))

;; Scalar behavior is unchanged when capture is absent or false.
(ev "(def c-ok-omit (jolt.ffi/__cfn \"jolt_ne_ok\" [] :int))")
(ev "(def c-ok-empty (jolt.ffi/__cfn \"jolt_ne_ok\" [] :int {}))")
(ev "(def c-ok-false (jolt.ffi/__cfn \"jolt_ne_ok\" [] :int {:capture-native-error false}))")
(ev "(def c-ok-legacy (jolt.ffi/__cfn \"jolt_ne_ok\" [] :int :blocking))")
(ev "(def c-ok-capture (jolt.ffi/__cfn \"jolt_ne_ok\" [] :int {:capture-native-error true}))")
(ok "omitted options preserve scalar result" (= 7 (evi "(c-ok-omit)")))
(ok "empty options preserve scalar result" (= 7 (evi "(c-ok-empty)")))
(ok "false capture preserves scalar result" (= 7 (evi "(c-ok-false)")))
(ok "legacy blocking keyword preserves scalar result" (= 7 (evi "(c-ok-legacy)")))
(ok "successful capture includes cleared error slot"
    (evb "(= [7 0] (c-ok-capture))"))

;; Analyzer and public macros reject ambiguous or unsupported forms.
(ok "capture on void is rejected"
    (raises? (lambda () (ev "(jolt.ffi/__cfn \"jolt_ne_fail\" [:int] :void {:capture-native-error true})"))))
(ok "unknown option is rejected"
    (raises? (lambda () (ev "(jolt.ffi/__cfn \"jolt_ne_ok\" [] :int {:bogus true})"))))
(ok "namespaced option is rejected"
    (raises? (lambda () (ev "(jolt.ffi/__cfn \"jolt_ne_ok\" [] :int {::capture-native-error true})"))))
(ok "non-keyword option is rejected"
    (raises? (lambda () (ev "(jolt.ffi/__cfn \"jolt_ne_ok\" [] :int {\"blocking\" true})"))))
(ok "non-Boolean capture option is rejected"
    (raises? (lambda () (ev "(jolt.ffi/__cfn \"jolt_ne_ok\" [] :int {:capture-native-error \"yes\"})"))))
(ok "non-Boolean blocking option is rejected"
    (raises? (lambda () (ev "(jolt.ffi/__cfn \"jolt_ne_ok\" [] :int {:blocking 1})"))))
(ok "unknown trailing scalar option is rejected"
    (raises? (lambda () (ev "(jolt.ffi/__cfn \"jolt_ne_ok\" [] :int \"blocking\")"))))
(ok "extra trailing argument is rejected"
    (raises? (lambda () (ev "(jolt.ffi/__cfn \"jolt_ne_ok\" [] :int {:capture-native-error true} :extra)"))))
(ok "public foreign-fn extra option is rejected"
    (raises? (lambda ()
               (ev "(ffi/foreign-fn \"jolt_ne_ok\" [] :int {:capture-native-error true} :extra)"))))
(ok "public defcfn extra option is rejected"
    (raises? (lambda ()
               (ev "(ffi/defcfn bad-extra \"jolt_ne_ok\" [] :int {:capture-native-error true} :extra)"))))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
