;; run-unit.ss — host-specific unit gate.
;;
;; Loads the checked-in seed + spine, reads test/chez/unit.edn, and for each case
;; evaluates :expr (wrapped in (do ...), as `jolt -e` does) and compares its PRINTED
;; value (jolt-repl-str, the readable `-e` printer — an :expected string for a
;; string result therefore carries its quotes) to the literal :expected string.
;; :expected :throws asserts
;; the case raises. These cover host-specific behavior (dot-forms, java statics, io,
;; reader, walk, …) that isn't in the JVM-portable corpus. Global state is reset
;; between cases for per-case isolation.
;; :stderr-contains optionally captures stderr and requires the given stable
;; fragment. This makes reporting behavior falsifiable without coupling a row to
;; a complete platform-specific stack trace.
;;
;;   chez --script host/chez/run-unit.ss
(import (chezscheme))

(load "host/chez/run-gate-harness.ss")
;; The loader + install source roots, so a row's (require 'stdlib.ns) resolves the
;; .clj overlay from source exactly like jolt — without this, a require of a ns
;; whose NATIVE vars exist (e.g. clojure.core.async) silently no-ops via the
;; ns-has-vars? arm and the overlay fns are missing at analysis.
(load "host/chez/loader.ss")
(set-source-roots! ldr-install-roots)
;; The base java.time API (stdlib/jolt/time) autoloads on first java.time.* use at
;; runtime; here we load it once BEFORE the per-case snapshot below so its
;; value-semantics arms (impl/install-seams!) and class registrations are part of
;; the stable base world. Otherwise the first java.time case would install those
;; arms after the snapshot, and zj-reset! — which prunes vars but can't unregister
;; a Scheme-level arm — would leave them dangling and break later cases. (Cold
;; autoload is covered per-process by the smoke gate.)
(load-namespace "jolt.time.base")

(define (slurp path)
  (call-with-input-file path
    (lambda (p)
      (let loop ((cs '()) (c (read-char p)))
        (if (eof-object? c) (list->string (reverse cs))
            (loop (cons c cs) (read-char p)))))))

(define cases
  (jolt-read-string
    (if (getenv "JOLT_UNIT_DIAGNOSTIC_PROBE")
        "[{:suite \"unit diagnostics\" :expected \"never\" :expr \"(throw (ex-info \\\"unit diagnostic probe\\\" {}))\"}]"
        (slurp "test/chez/unit.edn"))))
(define kw-suite    (keyword #f "suite"))
(define kw-expr     (keyword #f "expr"))
(define kw-expected (keyword #f "expected"))
(define kw-stderr-contains (keyword #f "stderr-contains"))
(define kw-throws   (keyword #f "throws"))

;; Every invocation owns one atomically-created private root.  Rows may create
;; and delete children beneath it, but never a process-global /tmp name.
(define unit-temp-root
  (npath-string-of (nio-files-create-temp (list "jolt-unit-") #t)))
(sys-set-property "jolt.test.unit.tmpdir" unit-temp-root)
(when (getenv "JOLT_UNIT_REPORT_TEMP_ROOT")
  (printf "unit temp root: ~a\n" unit-temp-root)
  (flush-output-port))

(define (string-contains? haystack needle)
  (let ((hn (string-length haystack)) (nn (string-length needle)))
    (let loop ((i 0))
      (cond
        ((fx>? (fx+ i nn) hn) #f)
        ((string=? (substring haystack i (fx+ i nn)) needle) #t)
        (else (loop (fx+ i 1)))))))

(load "host/chez/run-case-isolation.ss")

(define (unit-clean-line s)
  (list->string
    (map (lambda (c) (if (or (char=? c #\tab) (char=? c #\newline) (char=? c #\return)) #\space c))
         (string->list s))))
(define (unit-write->string v)
  (call-with-string-output-port (lambda (p) (write v p))))
(define (unit-raised-detail e)
  (let ((v (jolt-unwrap-throw e)))
    (unit-clean-line
      (cond
        ((jolt-ex-info-record? v)
         (string-append "raised " (jolt-ex-info-record-class-name v)
                        (let ((m (jolt-ex-info-record-message v)))
                          (if (string? m) (string-append ": " m) ""))))
        ((condition? v)
         (string-append "raised chez.condition: " (condition->message-string v)))
        ((string? v) (string-append "raised string: " v))
        (else (string-append "raised value: " (unit-write->string v)))))))

(define dynamic-deps-only? (getenv "JOLT_UNIT_DYNAMIC_DEPS_ONLY"))
(define (selected-suite? suite)
  (or (not dynamic-deps-only?)
      (string=? suite "require / as-alias")
      (string=? suite "add-deps")))

;; --- run ------------------------------------------------------------------------
(define pass 0)
(define selected-total 0)
(define fails '())              ; (suite expr msg)
(define suite-pass (make-hashtable string-hash string=?))
(define suite-total (make-hashtable string-hash string=?))
(define (bump! ht k) (hashtable-set! ht k (+ 1 (hashtable-ref ht k 0))))

(let loop ((i 0))
  (when (< i (pvec-count cases))
    (let* ((row (pvec-nth-d cases i jolt-nil))
           (suite (jolt-get row kw-suite))
           (expr (jolt-get row kw-expr))
           (expected (jolt-get row kw-expected))
           (stderr-contains (jolt-get row kw-stderr-contains))
           (throws? (eq? expected kw-throws))
           (sink (open-output-string))
           (error-sink (open-output-string))
           (error-port (if (jolt-nil? stderr-contains)
                           (current-error-port)
                           error-sink)))
      (when (selected-suite? suite)
        (set! selected-total (+ selected-total 1))
        (bump! suite-total suite)
        (guard (e (#t (if throws?
                          (begin (set! pass (+ pass 1)) (bump! suite-pass suite))
                          (set! fails (cons (list suite expr (unit-raised-detail e)) fails)))))
          (let* ((got (jolt-repl-str
                        (parameterize ((current-output-port sink)
                                       (current-error-port error-port))
                          (jolt-compile-eval (string-append "(do " expr ")") "user"))))
                 (stderr-got (get-output-string error-sink))
                 (stderr-ok? (or (jolt-nil? stderr-contains)
                                 (string-contains? stderr-got stderr-contains))))
            (cond
              (throws? (set! fails (cons (list suite expr (string-append "expected throw; got " got)) fails)))
              ((and (string=? got expected) stderr-ok?)
               (begin (set! pass (+ pass 1)) (bump! suite-pass suite)))
              ((not stderr-ok?)
               (set! fails (cons (list suite expr
                                 (string-append "stderr missing `" stderr-contains
                                                "`; got `" stderr-got "`")) fails)))
              (else (set! fails (cons (list suite expr
                      (string-append "want `" expected "` got `" got "`")) fails))))))
        (zj-reset!)))
    (loop (+ i 1))))

(printf "\nunit gate: ~a/~a passed\n" pass selected-total)
(let-values (((ks vs) (hashtable-entries suite-total)))
  (for-each (lambda (p)
              (printf "  ~a/~a  ~a\n" (hashtable-ref suite-pass (car p) 0) (cdr p) (car p)))
            (list-sort (lambda (a b) (string<? (car a) (car b)))
                       (vector->list (vector-map cons ks vs)))))
(when (> (length fails) 0)
  (printf "\n~a FAIL(s):\n" (length fails))
  (for-each (lambda (f) (printf "  [~a] ~a\n    ~a\n" (car f) (caddr f) (cadr f)))
            (list-head (reverse fails) (min 40 (length fails)))))
(flush-output-port)
(aot-delete-tree unit-temp-root)
(exit (if (> (length fails) 0) 1 0))
