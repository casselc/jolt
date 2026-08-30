;; boot-probe.scm — `make gambitboot` includes the generated full-profile boot
;; and prints BOOT-OK. Every ##include'd chez file runs its top level here, so a
;; Chez-only name reaching a shared file fails in this gate instead of hanging
;; the shipped web REPL at boot (values.ss taking the keyword-table lock at the
;; first keyword intern did exactly that to jolt-web.js, and nothing caught it:
;; gambitcheck exercises the adapter, not the boot).
(##include "boot-full.ss")

;; Exercise the shared optimistic extension registry, not merely its top-level
;; definitions. This caught a Chez-only execution-context helper that ordinary
;; Gambit boot and adapter checks left latent.
(define (gambit-boot-kw s) (keyword #f s))
(define gambit-boot-extension-id (gambit-boot-kw "gambit-boot-probe"))
(define (gambit-boot-field name type)
  (jolt-hash-map (gambit-boot-kw name) (gambit-boot-kw type)))
(define (gambit-boot-default name value)
  (jolt-hash-map (gambit-boot-kw name) value))
(jolt-register-extension-point!
  gambit-boot-extension-id
  (jolt-hash-map
    (gambit-boot-kw "key") (gambit-boot-kw "string")
    (gambit-boot-kw "root") ""
    (gambit-boot-kw "fields") (gambit-boot-field "base" "string")
    (gambit-boot-kw "default") (gambit-boot-default "base" "root")
    (gambit-boot-kw "fallback") (gambit-boot-kw "strict")))
(jolt-refine-extension!
  gambit-boot-extension-id
  (jolt-hash-map
    (gambit-boot-kw "fields") (gambit-boot-field "extra" "long")
    (gambit-boot-kw "default") (gambit-boot-default "extra" 7)))
(jolt-register-extension!
  gambit-boot-extension-id "provider"
  (gambit-boot-default "base" "provided"))
(let ((v (jolt-extension-value gambit-boot-extension-id "provider")))
  (unless (and (string=?
                 "provided"
                 (jolt-get-dispatch v (gambit-boot-kw "base") jolt-nil))
               (= 7 (jolt-get-dispatch v (gambit-boot-kw "extra") jolt-nil)))
    (error 'gambit-boot-probe "extension registry mutation round trip failed")))
(display "BOOT-OK\n")
