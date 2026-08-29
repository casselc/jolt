;; createTempDirectory/createTempFile/createFile must establish ownership by
;; atomic creation, not by a racy pre-create existence check or a truncating
;; output port.  Forced collisions give each regression mutation teeth.
(import (chezscheme))

(load "host/chez/run-gate-harness.ss")
(load "host/chez/loader.ss")

(define failures '())
(define (check label pred)
  (unless pred (set! failures (cons label failures))))

;; Header constants for every target family selected by the production helper.
;; Keeping this table executable prevents a nearby decimal/hex edit from
;; silently dropping O_EXCL or accepting the wrong collision code.
(check "Linux exclusive-open flags"
       (= (nio-open-exclusive-flags-for-family 'linux) #xC1))
(check "macOS exclusive-open flags"
       (= (nio-open-exclusive-flags-for-family 'macos) #xA01))
(check "Windows exclusive-open flags"
       (= (nio-open-exclusive-flags-for-family 'windows) #x8501))
(check "errno collision contract covers POSIX and Windows CRT APIs"
       (and (nio-native-exists-error-for-convention? '__errno 17)
            (not (nio-native-exists-error-for-convention? '__errno 80))
            (not (nio-native-exists-error-for-convention? '__errno 13))))
(check "GetLastError collision contract is distinct from CRT errno"
       (and (nio-native-exists-error-for-convention? '__get_last_error 80)
            (nio-native-exists-error-for-convention? '__get_last_error 183)
            (not (nio-native-exists-error-for-convention? '__get_last_error 17))
            (not (nio-native-exists-error-for-convention? '__get_last_error 5))))
(define (tree-contains? x needle)
  (cond ((pair? x) (or (tree-contains? (car x) needle)
                       (tree-contains? (cdr x) needle)))
        ((vector? x)
         (let loop ((i 0))
           (and (< i (vector-length x))
                (or (tree-contains? (vector-ref x i) needle)
                    (loop (+ i 1))))))
        (else (eq? x needle))))
(define crt-open-expansion
  (syntax->datum
    (expand
      '(jolt-foreign-proc-native-error-safe
         __errno ((__varargs_after 2)) "open" (quote (string int int)) (quote int)))))
(check "CRT exclusive-open binding explicitly captures errno on every OS arm"
       (and (tree-contains? crt-open-expansion '__errno)
            (not (tree-contains? crt-open-expansion '__get_last_error))))

;; nio-stat-mode currently has layouts for macOS and little-endian x86-64
;; Linux.  Exclusivity/collision tests run on every target; only permission
;; inspection is conditional on a target whose stat layout the shim knows.
(define permission-inspection? nio-stat-layout-known?)

(define root
  (npath-string-of (nio-files-create-temp (list "jolt-nio-temp-test-") #t)))
(define collision (string-append root "/already-exists"))
(nio-mkdir-atomic! collision #o700)

(let-values (((result native-error) (nio-mkdir-native-result collision #o700)))
  (check "mkdir collision returns failure" (not (= result 0)))
  (check "mkdir collision captures EEXIST at the call boundary"
         (nio-native-exists-error? native-error)))

(define original-temp-path nio-temp-path)
(define attempts 0)
(define result #f)
(dynamic-wind
  (lambda ()
    (set! nio-temp-path
      (lambda (dir prefix suffix)
        (set! attempts (+ attempts 1))
        (if (= attempts 1)
            collision
            (original-temp-path dir prefix suffix)))))
  (lambda ()
    (set! result
      (nio-files-create-temp
        (list (make-nio-path root) "child-") #t)))
  (lambda () (set! nio-temp-path original-temp-path)))

(let ((path (npath-string-of result)))
  (check "retried exactly once after the forced collision" (= attempts 2))
  (check "did not return the existing candidate" (not (string=? path collision)))
  (check "returned directory exists" (file-directory? path))
  (when permission-inspection?
    (check "temp directory has creation-time owner-only permissions"
           (= (bitwise-and (nio-stat-mode path) #o777) #o700))))

;; A temp-file collision retries without opening or truncating the existing
;; candidate.  The old `(file-options no-fail)` arm returns that candidate and
;; destroys the sentinel.
(define existing-file (string-append root "/existing-file"))
(let ((p (open-file-output-port existing-file (file-options no-fail))))
  (put-bytevector p (string->utf8 "sentinel"))
  (close-port p))
(let-values (((fd native-error) (nio-open-native-result existing-file #o600)))
  (when (>= fd 0) (nio-c-close fd))
  (check "exclusive open collision returns failure" (< fd 0))
  (check "exclusive open collision captures EEXIST at the call boundary"
         (nio-native-exists-error? native-error)))
(set! attempts 0)
(define temp-file-result #f)
(dynamic-wind
  (lambda ()
    (set! nio-temp-path
      (lambda (dir prefix suffix)
        (set! attempts (+ attempts 1))
        (if (= attempts 1)
            existing-file
            (original-temp-path dir prefix suffix)))))
  (lambda ()
    (set! temp-file-result
      (nio-files-create-temp
        (list (make-nio-path root) "child-" ".tmp") #f)))
  (lambda () (set! nio-temp-path original-temp-path)))

(define (read-text path)
  (let ((p (open-file-input-port path)))
    (let ((s (utf8->string (get-bytevector-all p))))
      (close-port p)
      s)))

(let ((path (npath-string-of temp-file-result)))
  (check "temp file retried exactly once after collision" (= attempts 2))
  (check "temp file did not return the existing candidate" (not (string=? path existing-file)))
  (check "temp file preserved colliding content" (string=? (read-text existing-file) "sentinel"))
  (when permission-inspection?
    (check "temp file has creation-time owner-only permissions"
           (= (bitwise-and (nio-stat-mode path) #o777) #o600))))

;; createFile is exclusive too: an existing file raises and remains unchanged.
(define create-file-raised? #f)
(guard (e (#t (set! create-file-raised? #t)))
  (nio-create-file-atomic! existing-file #o600))
(check "createFile rejects an existing path" create-file-raised?)
(check "createFile does not truncate an existing path"
       (string=? (read-text existing-file) "sentinel"))

(define new-file (string-append root "/created-file"))
(nio-create-file-atomic! new-file #o600)
(when permission-inspection?
  (check "createFile applies permissions at creation"
         (= (bitwise-and (nio-stat-mode new-file) #o777) #o600)))

;; A non-collision native failure must propagate immediately.  Inject EACCES
;; after path generation; the old post-failure existence classification could
;; retry or mislabel depending on a concurrent filesystem change.
(define original-c-open nio-c-open)
(define denied-attempts 0)
(define denied-raised? #f)
(dynamic-wind
  (lambda ()
    (set! nio-c-open (lambda _ (values -1 13))) ; POSIX EACCES control
    (set! nio-temp-path
      (lambda _
        (set! denied-attempts (+ denied-attempts 1))
        (string-append root "/denied-file"))))
  (lambda ()
    (guard (e (#t (set! denied-raised? #t)))
      (nio-files-create-temp
        (list (make-nio-path root) "denied-" ".tmp") #f)))
  (lambda ()
    (set! nio-c-open original-c-open)
    (set! nio-temp-path original-temp-path)))
(check "non-EEXIST file failure propagates" denied-raised?)
(check "non-EEXIST file failure is not retried" (= denied-attempts 1))

(define original-c-mkdir nio-c-mkdir)
(set! denied-attempts 0)
(set! denied-raised? #f)
(dynamic-wind
  (lambda ()
    (set! nio-c-mkdir (lambda _ (values -1 13)))
    (set! nio-temp-path
      (lambda _
        (set! denied-attempts (+ denied-attempts 1))
        (string-append root "/denied-directory"))))
  (lambda ()
    (guard (e (#t (set! denied-raised? #t)))
      (nio-files-create-temp
        (list (make-nio-path root) "denied-") #t)))
  (lambda ()
    (set! nio-c-mkdir original-c-mkdir)
    (set! nio-temp-path original-temp-path)))
(check "non-EEXIST directory failure propagates" denied-raised?)
(check "non-EEXIST directory failure is not retried" (= denied-attempts 1))

(aot-delete-tree root)

(if (null? failures)
    (begin (display "NIO-TEMP-DIRECTORY-TEST OK\n") (exit 0))
    (begin
      (for-each (lambda (f) (printf "FAIL: ~a\n" f)) (reverse failures))
      (exit 1)))
