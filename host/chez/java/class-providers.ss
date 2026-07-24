;; class-providers.ss — bounded lazy providers for modeled Java classes.
;;
;; A catalog namespace may declare:
;;
;;   (jolt.host/register-class-providers!
;;     {"java.nio.channels.Selector" 'jolt.compat.nio})
;;
;; A constructor/static/member miss for that class loads exactly the named
;; namespace and retries the lookup once.  This is deliberately a registry, not
;; a naming convention: dependencies can provide compatibility classes without
;; core knowing their namespace layout.
;;
;; This file is literally loaded by host-static.ss.  The build flattener only
;; follows literal top-level loads, so do not hide that load behind a conditional.

(define class-providers-tbl (make-hashtable string-hash string=?))
;; provider namespace -> loading thread | 'loaded
(define class-provider-states-tbl (make-hashtable string-hash string=?))
(define class-provider-mu (make-mutex 'class-providers))
(define class-provider-cv (make-condition))
(define class-provider-load-stack (make-thread-parameter '()))

(define (class-provider-error type message details)
  (jolt-throw
    (jolt-ex-info
      message
      (jolt-hash-map
        (keyword "jolt" "error")
        (jolt-assoc1 details (keyword #f "type") (keyword #f type))))))

(define (class-provider-name x what)
  (cond ((string? x) x)
        ((symbol-t? x) (symbol-t-name x))
        (else
          (class-provider-error
            "invalid-class-provider"
            (string-append what " must be a string or symbol")
            (jolt-hash-map (keyword #f "value") x)))))

(define (class-provider-register-one! class provider)
  (let* ((class (class-provider-name class "class-provider class"))
         (provider (class-provider-name provider "class-provider namespace"))
         (short (short-class-name class)))
    (when (= (string-length class) 0)
      (class-provider-error
        "invalid-class-provider" "class-provider class must not be empty"
        (jolt-hash-map (keyword #f "class") class)))
    (when (= (string-length provider) 0)
      (class-provider-error
        "invalid-class-provider" "class-provider namespace must not be empty"
        (jolt-hash-map (keyword #f "class") class
                       (keyword #f "provider") provider)))
    ;; Jolt's interop accepts both FQNs and imported/simple names.  Check every
    ;; spelling before changing the table, then reserve them together.  This
    ;; prevents a simple-name conflict from leaving a half-registered FQN.
    (let ((names (if (string=? class short) (list class) (list class short))))
      (with-mutex class-provider-mu
        (let find-conflict ((rest names))
          (unless (null? rest)
            (let* ((name (car rest))
                   (old (hashtable-ref class-providers-tbl name #f)))
              (if (and old (not (string=? old provider)))
                  (class-provider-error
                    "class-provider-conflict"
                    (string-append "Conflicting class providers for " name
                                   ": " old " and " provider)
                    (jolt-hash-map
                      (keyword #f "class") name
                      (keyword #f "existing-provider") old
                      (keyword #f "new-provider") provider))
                  (find-conflict (cdr rest))))))
        (for-each
          (lambda (name)
            (unless (hashtable-ref class-providers-tbl name #f)
              (hashtable-set! class-providers-tbl name provider)))
          names)))
    jolt-nil))

;; Deterministic, duplicate-free provider namespace list for the AOT build graph.
;; A mapped provider must be bundled even when the first class use is inside
;; -main and therefore has not occurred while the build driver loads the entry ns.
(define (class-provider-namespaces)
  (with-mutex class-provider-mu
    (let ((seen (make-hashtable string-hash string=?))
          (result '()))
      (vector-for-each
        (lambda (_ provider)
          (unless (hashtable-ref seen provider #f)
            (hashtable-set! seen provider #t)
            (set! result (cons provider result))))
        (hashtable-keys class-providers-tbl)
        (hashtable-values class-providers-tbl))
      (sort string<? result))))

(define (class-provider-for class)
  (with-mutex class-provider-mu
    (hashtable-ref class-providers-tbl class #f)))

(define (class-provider-cycle! provider)
  (let ((path (reverse (cons provider (class-provider-load-stack)))))
    (class-provider-error
      "class-provider-cycle"
      (string-append "Re-entrant class-provider load: "
                     (let loop ((xs path) (out ""))
                       (cond
                         ((null? xs) out)
                         ((string=? out "") (loop (cdr xs) (car xs)))
                         (else (loop (cdr xs)
                                     (string-append out " -> " (car xs)))))))
      (jolt-hash-map
        (keyword #f "provider") provider
        (keyword #f "path") (list->cseq path)))))

;; Claim PROVIDER for this thread.  A concurrent caller joins the in-flight load
;; and then retries its own lookup; a recursive caller reports the dependency
;; cycle rather than relying on load-namespace's dedup mark.
(define (class-provider-claim provider)
  (with-mutex class-provider-mu
    (let loop ((joined? #f))
      (let ((state (hashtable-ref class-provider-states-tbl provider #f)))
        (cond
          ((eq? state 'loaded) (if joined? 'joined 'already-loaded))
          ((not state)
           (hashtable-set! class-provider-states-tbl provider (get-thread-id))
           'load)
          ((eqv? state (get-thread-id)) 'cycle)
          (else
            (condition-wait class-provider-cv class-provider-mu)
            (loop #t)))))))

(define (class-provider-finish! provider)
  (with-mutex class-provider-mu
    (hashtable-set! class-provider-states-tbl provider 'loaded)
    (condition-broadcast class-provider-cv)))

(define (class-provider-abort! provider)
  (with-mutex class-provider-mu
    (hashtable-delete! class-provider-states-tbl provider)
    (condition-broadcast class-provider-cv)))

;; Returns #t only when the caller should retry its lookup once.  A provider
;; already known to be loaded returns #f, so a bad provider cannot create an
;; arbitrary miss/load/retry loop.
(define (class-provider-try-load! class)
  (let ((provider (class-provider-for class)))
    (and provider
         (case (class-provider-claim provider)
           ((already-loaded) #f)
           ((joined) #t)
           ((cycle) (class-provider-cycle! provider))
           ((load)
            (guard (e (else
                        (class-provider-abort! provider)
                        (raise e)))
              (parameterize
                ((class-provider-load-stack
                   (cons provider (class-provider-load-stack))))
                (load-namespace provider))
              (class-provider-finish! provider)
              #t))
           (else #f)))))

;; A value can carry canonical and simple host tags.  Pick the first declared
;; provider; registration reserves both spellings to the same namespace.
(define (class-provider-try-load-for-value! obj method-name)
  (let loop ((tags (value-host-tags obj)))
    (cond
      ((null? tags) #f)
      ((class-provider-for (car tags))
       (class-provider-try-load! (car tags)))
      (else (loop (cdr tags))))))
