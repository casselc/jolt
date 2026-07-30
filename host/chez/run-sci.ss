;; run-sci.ss — SCI conformance: load borkdude/sci's own source (vendor/sci) through
;; jolt and require its forms to compile+eval. A real-world Clojure-compatibility
;; stress test. Floor-gated like the corpus: a regression below
;; the floor (or the current count, 423/424) fails. The one bounded known gap is
;; SCI's JVM SciRecord deftype referring to Clojure's private imap-cons helper,
;; which Jolt does not currently provide.
;; Every other file must remain failure-free. Raise the floor when that gap closes.
;; Files in this bounded source lane are loaded after their in-lane dependencies;
;; omitted JVM host layers have explicit stubs below rather than relying on an
;; unresolved qualified symbol being misclassified as a host static.
;;
;;   chez --script host/chez/run-sci.ss
;;   JOLT_SCI_FLOOR=N    override the floor (default 423)
;;   SCI_VERBOSE=1       print each failing form's error
(import (chezscheme))

;; Skip cleanly when the submodule isn't checked out.
(unless (file-exists? "vendor/sci/src/sci/core.cljc")
  (display "skip: vendor/sci not checked out (git submodule update --init vendor/sci)\n")
  (exit 0))

(load "host/chez/run-gate-harness.ss")

;; SCI's .cljc selects host code via #?(:clj ...) with no :jolt branch — read clj.
(set! rdr-features (list "clj" "jolt" "default"))

(define (slurp path)
  (call-with-input-file path
    (lambda (p) (let loop ((cs '()) (c (read-char p)))
      (if (eof-object? c) (list->string (reverse cs)) (loop (cons c cs) (read-char p)))))))

;; Load every form in a file, evaluating each in the current ns (an (ns ...) form
;; switches it). Returns (ok . fail); failures are tolerated (lenient — SCI requires
;; host libs that don't exist here). Push thread bindings for *warn-on-reflection*
;; and *assert* so vendored SCI code that (set! *warn-on-reflection* true) finds a
;; thread-local slot instead of throwing "Can't change/establish root binding".
;;
;; A #_ discard or a reader conditional with no matching branch (SCI's .cljc has
;; plenty of `#?(:cljs …)`) reads as rdr-eof with the position ADVANCED — "no
;; form here", not end of input. Keying the loop on that marker alone stopped the
;; read at the first one, silently dropping the rest of the file: utils.cljc gave
;; up 13 forms in, so its allowed-loop/allowed-recur never got defined and every
;; later file referring to them failed. Branch on `j` like load-jolt-file and
;; ei-read-all do, and stop only when the position doesn't move.
(define (load-forms path verbose)
  (let ((src (slurp path)) (ok 0) (fail 0)
        (warn-cell (guard (_ (#t #f)) (jolt-var "clojure.core" "*warn-on-reflection*")))
        (assert-cell (guard (_ (#t #f)) (jolt-var "clojure.core" "*assert*"))))
    (let ((end (string-length src)))
      (let loop ((i 0))
        (when (< i end)
          (call-with-values (lambda () (rdr-read-form src i end))
            (lambda (form j)
              (when (> j i)
                (unless (rdr-eof? form)
                  (guard (e (#t (set! fail (+ fail 1))
                                (when verbose
                                  (printf "    ~a bytes ~a..~a\n" path i j)
                                  (printf "    FAIL: ~a\n" (call-with-string-output-port
                                    (lambda (p) (jolt-render-throwable e p)))))))
                    (when warn-cell
                      (jolt-push-thread-bindings
                        (jolt-hash-map warn-cell (var-cell-root warn-cell)
                                       assert-cell (var-cell-root assert-cell))))
                    (dynamic-wind
                      (lambda () #f)
                      (lambda ()
                        (jolt-compile-eval-form form (chez-current-ns))
                        (set! ok (+ ok 1)))
                      (lambda ()
                        (when warn-cell (jolt-pop-thread-bindings))))))
                (loop j)))))))
    (cons ok fail)))

(define verbose (and (getenv "SCI_VERBOSE") #t))

;; stubs first (host shims SCI's source expects)
(for-each (lambda (f) (load-forms (string-append "stdlib/clojure/sci/" f) verbose))
          '("lang_stubs.clj" "io_stubs.clj" "host_stubs.clj"))

(define sci-base "vendor/sci/src/sci/")
(define load-order
  '("impl/macros.cljc" "impl/types.cljc" "impl/unrestrict.cljc"
    "impl/vars.cljc" "lang.cljc" "impl/utils.cljc" "ctx_store.cljc"
    "impl/records.cljc" "impl/deftype.cljc" "impl/core_protocols.cljc"
    "impl/hierarchies.cljc" "impl/multimethods.cljc" "impl/protocols.cljc"
    "impl/destructure.cljc" "impl/doseq_macro.cljc" "impl/for_macro.cljc"
    "impl/fns.cljc" "impl/namespaces.cljc" "core.cljc"))

(define total-ok 0) (define total-fail 0)
(define unexpected-fail #f)
(define (known-failure-budget f)
  (if (string=? f "impl/records.cljc") 1 0))
(for-each
  (lambda (f)
    (let* ((r (load-forms (string-append sci-base f) verbose)) (ok (car r)) (fail (cdr r)))
      (set! total-ok (+ total-ok ok)) (set! total-fail (+ total-fail fail))
      (printf "  ~a: ~a ok, ~a fail\n" f ok fail)
      (when (> fail (known-failure-budget f))
        (set! unexpected-fail #t)
        (printf "REGRESSION: ~a has ~a failure(s), expected at most ~a\n"
                f fail (known-failure-budget f)))))
  load-order)

;; The copy-vars shim is exercised while namespaces.cljc constructs its
;; clojure.core map. Require representative copy-core-var, copy-var, macrofy,
;; and new-var entries to contain the explicit non-nil sentinel; a no-op macro
;; returning nil must not turn source evaluation into a false pass.
(define copy-stub (keyword "sci.impl.copy-vars" "stub"))
(define sci-core-map
  (guard (_ (#t #f))
    (var-cell-root (jolt-var "sci.impl.namespaces" "clojure-core"))))
(define (copied-stub? name)
  (and sci-core-map
       (equal? copy-stub
               (jolt-get sci-core-map (jolt-symbol #f name) jolt-nil))))
(unless (and (copied-stub? "println")
             (copied-stub? "pr")
             (copied-stub? "with-out-str")
             (copied-stub? "-reified-methods"))
  (set! unexpected-fail #t)
  (printf "REGRESSION: SCI copy-vars stubs did not populate clojure.core\n"))

(printf "\nSCI load: ~a/~a forms ok (~a fail)\n" total-ok (+ total-ok total-fail) total-fail)
(define floor (let ((s (getenv "JOLT_SCI_FLOOR"))) (if s (string->number s) 423)))
(when (< total-ok floor)
  (printf "REGRESSION: ~a forms loaded < floor ~a\n" total-ok floor))
(flush-output-port)
(exit (if (or unexpected-fail (< total-ok floor)) 1 0))
