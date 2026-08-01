;; host/chez/sim/runtime.ss — private simulation-only runtime overlay.
;;
;; Loaded only by the `sim` Jolt image and by applications that image builds.
;; This first slice establishes the packaging/cache boundary without exposing a
;; public or versioned controller surface. Future lifecycle, FFI, and clock
;; controller hooks land here in separate reviewed commits.

(define jolt-sim-runtime-image? #t)
