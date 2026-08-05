;; target-descriptor-test.ss — jolt.host/target's exact fail-closed classifier,
;; and the System/Runtime surface that now projects from it.
;;
;; Scope:
;;   * target-facts-for-machine-name: every known machine name in
;;     target-machine-fact-names resolves to its exact (os arch abi) row, and an
;;     unrecognized name fails closed to :unknown for the machine tuple — no
;;     fuzzy fallback classification.
;;   * That table stays in lockstep with rt.ss's jolt-ffi-native-error-convention-
;;     case: for every known machine name, the OS the table assigns predicts
;;     which native-error convention (GetLastError vs errno) the macro selects
;;     for that same machine symbol.
;;   * The current host's public jolt.host/target descriptor, System properties
;;     (os.name/os.arch/line.separator/file.separator/path.separator,
;;     System/lineSeparator, System/getProperties), and java.lang.Runtime all
;;     agree with each other and with the target facts they are derived from.
;;
;; Deliberately NOT ported from any prior suite: the old jolt-windows-machine-
;; type? cases don't apply here — this codebase's native-error convention
;; selection is the exact jolt-ffi-native-error-convention-case macro (rt.ss),
;; not a fuzzy machine-type predicate, and the second case above already covers
;; the same ground precisely.
;;
;; Run:
;;   chez --script test/chez/target-descriptor-test.ss

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (kw s) (keyword #f s))

;; --- exact known-machine classification ---------------------------------------
;; Every row in target-machine-fact-names must resolve to ITS OWN (os arch abi),
;; not :unknown and not another row's — a copy/paste or table-drift bug would
;; otherwise silently misclassify one machine as a neighboring one.
(for-each
  (lambda (row)
    (let* ((name (car row))
           (want (list (kw (symbol->string (cadr row)))
                       (kw (symbol->string (caddr row)))
                       (kw (symbol->string (cadddr row)))))
           (got (target-facts-for-machine-name name)))
      (ok (string-append "known machine " name " classifies exactly")
          (equal? want got))))
  target-machine-fact-names)

;; --- fail-closed unknown classification ---------------------------------------
(ok "unrecognized machine name fails closed to an all-:unknown tuple"
    (equal? (list (kw "unknown") (kw "unknown") (kw "unknown"))
            (target-facts-for-machine-name "not-a-real-jolt-target")))
(ok "empty machine name fails closed to :unknown"
    (equal? target-unknown-facts (target-facts-for-machine-name "")))
(for-each
  (lambda (machine-name)
    (ok (string-append "adversarial near-match fails closed: " machine-name)
        (equal? target-unknown-facts
                (target-facts-for-machine-name machine-name))))
  '("tpb" "future-a6le" "internet" "aarch64le" "a6windows"
    "a6le-next" "TA6LE"))

;; --- lockstep with rt.ss's native-error convention macro -----------------------
;; Expand the actual production selector under each known machine symbol (the
;; same xpatch-safe technique ffi-native-error-test.ss uses) and check it agrees
;; with the OS the target-facts table assigns that same name: windows rows select
;; GetLastError, every other row selects errno.
(define (native-error-convention-for-target target)
  (parameterize ((#%$target-machine (string->symbol target)))
    (cadr
      (syntax->datum
        (expand
          (list 'jolt-ffi-native-error-convention-case
                (list 'quote '__get_last_error)
                (list 'quote '__errno)))))))
(for-each
  (lambda (row)
    (let* ((name (car row))
           (os (cadr row))
           (facts (target-facts-for-machine-name name))
           (want-conv (if (eq? os 'windows) '__get_last_error '__errno))
           (got-conv (native-error-convention-for-target name)))
      (ok (string-append name ": target-facts os and native-error convention agree")
          (and (eq? (car facts) (kw (symbol->string os)))
               (eq? want-conv got-conv)))))
  target-machine-fact-names)

;; jolt-foreign-proc-safe must choose the deferred eval form from the COMPILER
;; target.  That prevents a Linux build host from baking a missing POSIX symbol
;; relocation into a Windows cross-image, and covers Chez's Windows ARM64 names.
(define (datum-contains-symbol? needle x)
  (cond ((symbol? x) (eq? needle x))
        ((pair? x) (or (datum-contains-symbol? needle (car x))
                       (datum-contains-symbol? needle (cdr x))))
        ((vector? x)
         (let loop ((i 0))
           (and (< i (vector-length x))
                (or (datum-contains-symbol? needle (vector-ref x i))
                    (loop (+ i 1))))))
        (else #f)))
(define (safe-foreign-proc-deferred-for-target? target)
  (parameterize ((#%$target-machine target))
    (datum-contains-symbol?
      'eval
      (syntax->datum
        (expand '(jolt-foreign-proc-safe "jolt_optional_probe" '() 'int))))))
(for-each
  (lambda (target)
    (ok (string-append (symbol->string target)
                       ": optional FFI resolution is deferred")
        (safe-foreign-proc-deferred-for-target? target)))
  '(i3nt ti3nt a6nt ta6nt arm64nt tarm64nt))
(for-each
  (lambda (target)
    (ok (string-append (symbol->string target)
                       ": optional FFI resolution stays compiled")
        (not (safe-foreign-proc-deferred-for-target? target))))
  '(ta6le tarm64le ta6osx tarm64osx))

;; --- current-host public descriptor coherence -----------------------------------
;; jolt.host/target, System's individual properties, System/getProperties, and
;; Runtime/availableProcessors must all describe the SAME host — none of them a
;; second, independently-derived authority.
(define (ev s) (jolt-compile-eval s "user"))
(define target-map (jolt-host-target))
(define (tget k) (jolt-get-dispatch target-map (kw k) jolt-nil))

(ok "jolt.host/target has exactly the nine documented facts"
    (= 9 (jolt-count target-map)))
(ok "jolt.host/target :os is the module-level target-os this file classified"
    (eq? (tget "os") target-os))
(ok "jolt.host/target :arch is the module-level target-arch this file classified"
    (eq? (tget "arch") target-arch))
(ok "target-os-name is one of the exact JVM-style target strings"
    (and (member target-os-name (list "Linux" "Mac OS X" "Windows" "Unknown")) #t))
(ok "a recognized target-os implies a recognized (non-:unknown) target-arch"
    (or (eq? target-os (kw "unknown")) (not (eq? (tget "arch") (kw "unknown")))))
(ok "jolt.host/target :file-separator matches System/getProperty file.separator"
    (string=? (tget "file-separator") (sys-get-property "file.separator")))
(ok "jolt.host/target :path-separator matches System/getProperty path.separator"
    (string=? (tget "path-separator") (sys-get-property "path.separator")))
(ok "jolt.host/target :processors matches jolt-available-processors"
    (= (jnum->exact (tget "processors")) (jolt-available-processors)))

;; Native path classification is target-dependent. Exercise both policies here
;; so Linux CI still proves the Windows form that source-runtime jobs consume.
(ok "POSIX absolute paths accept only a leading slash"
    (and (jolt-native-path-absolute-for? #f "/tmp/project")
         (not (jolt-native-path-absolute-for? #f "C:/project"))
         (not (jolt-native-path-absolute-for? #f "relative/project"))))
(ok "Windows absolute paths accept drive and UNC forms but not drive-relative"
    (and (jolt-native-path-absolute-for? #t "C:/project")
         (jolt-native-path-absolute-for? #t "C:\\project")
         (jolt-native-path-absolute-for? #t "\\\\server\\share")
         (jolt-native-path-absolute-for? #t "//server/share")
         (not (jolt-native-path-absolute-for? #t "C:project"))
         (not (jolt-native-path-absolute-for? #t "relative/project"))))
(ok "project-relative preserves a native absolute JOLT_PWD-derived path"
    (let ((p (if (eq? target-os (kw "windows"))
                 "C:\\project/deps.edn"
                 "/project/deps.edn")))
      (string=? p (project-relative p))))

(ok "System/getProperty os.name is the exact target-derived string"
    (string=? target-os-name (sys-get-property "os.name")))
(ok "System/getProperty os.arch is the exact target-derived string"
    (string=? target-arch-name (sys-get-property "os.arch")))
(ok "System/getProperty line.separator matches System/lineSeparator"
    (string=? (sys-get-property "line.separator")
              (jolt-str-render-one (ev "(System/lineSeparator)"))))
(ok "line.separator is LF unless the target is windows"
    (if (eq? target-os (kw "windows"))
        (string=? "\r\n" (sys-get-property "line.separator"))
        (string=? "\n" (sys-get-property "line.separator"))))
(ok "System/getProperty file.separator matches the target's own separator"
    (string=? target-file-separator (sys-get-property "file.separator")))
(ok "System/getProperty path.separator matches the target's own separator"
    (string=? target-path-separator (sys-get-property "path.separator")))
(let ((saved-provider sys-class-path-provider))
  (set-class-path-provider! (lambda () '("first-root" "second-root")))
  (ok "java.class.path joins roots with the advertised target separator"
      (string=? (string-append "first-root" target-path-separator "second-root")
                (sys-get-property "java.class.path")))
  (set-class-path-provider! saved-provider))

;; System/getProperties (a full map) must answer each of the above identically to
;; the single-property getProperty calls — one source, read two ways.
(let ((props (sys-properties-map)))
  (define (pget k) (jolt-get-dispatch props k jolt-nil))
  (ok "System/getProperties os.name matches System/getProperty os.name"
      (string=? (pget "os.name") (sys-get-property "os.name")))
  (ok "System/getProperties os.arch matches System/getProperty os.arch"
      (string=? (pget "os.arch") (sys-get-property "os.arch")))
  (ok "System/getProperties line.separator matches System/getProperty line.separator"
      (string=? (pget "line.separator") (sys-get-property "line.separator")))
  (ok "System/getProperties file.separator matches System/getProperty file.separator"
      (string=? (pget "file.separator") (sys-get-property "file.separator")))
  (ok "System/getProperties path.separator matches System/getProperty path.separator"
      (string=? (pget "path.separator") (sys-get-property "path.separator"))))

;; java.lang.Runtime.availableProcessors and jolt.host/target :processors are the
;; same one already-tested source of truth (jolt-available-processors), read
;; through two different public surfaces.
(ok "Runtime/getRuntime availableProcessors matches jolt.host/target :processors"
    (= (jnum->exact (ev "(.availableProcessors (java.lang.Runtime/getRuntime))"))
       (jnum->exact (tget "processors"))))

(printf "\ntarget-descriptor gate: ~a/~a passed\n" (- total fails) total)
(exit (if (zero? fails) 0 1))
