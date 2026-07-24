;; Cross-target classification tests for jolt.host/target. These exercise pure
;; Chez machine-name classifiers on one host, so unsupported targets fail
;; closed without requiring every CI runner architecture.

(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a\n" name)))

(define (kw name) (keyword #f name))
(define (classification machine-name)
  (let ((os (target-os-for-machine-name machine-name))
        (arch (target-arch-for-machine-name machine-name)))
    (list os arch (target-abi-for os arch))))

(ok "native Linux x86-64"
    (equal? (classification "a6le")
            (list (kw "linux") (kw "x86-64") (kw "sysv-amd64"))))
(ok "portable Linux x86-64"
    (equal? (classification "ta6le")
            (list (kw "linux") (kw "x86-64") (kw "sysv-amd64"))))
(ok "native Linux aarch64"
    (equal? (classification "arm64le")
            (list (kw "linux") (kw "aarch64") (kw "aapcs64"))))
(ok "portable Linux aarch64"
    (equal? (classification "tarm64le")
            (list (kw "linux") (kw "aarch64") (kw "aapcs64"))))
(ok "Darwin x86-64"
    (equal? (classification "a6osx")
            (list (kw "darwin") (kw "x86-64") (kw "sysv-amd64"))))
(ok "Darwin aarch64"
    (equal? (classification "arm64osx")
            (list (kw "darwin") (kw "aarch64") (kw "darwin-arm64"))))
(ok "Windows x86-64"
    (equal? (classification "ta6nt")
            (list (kw "windows") (kw "x86-64") (kw "win64"))))
(ok "Windows x86"
    (equal? (classification "ti3nt")
            (list (kw "windows") (kw "x86") (kw "cdecl-x86"))))
(ok "unverified Windows aarch64 ABI fails closed"
    (equal? (classification "tarm64nt")
            (list (kw "windows") (kw "aarch64") (kw "unknown"))))
(ok "Linux RISC-V architecture is known and ABI fails closed"
    (equal? (classification "trv64le")
            (list (kw "linux") (kw "riscv64") (kw "unknown"))))
(ok "Linux LoongArch architecture is known and ABI fails closed"
    (equal? (classification "tla64le")
            (list (kw "linux") (kw "loongarch64") (kw "unknown"))))
(ok "portable-bytecode target facts fail closed"
    (equal? (classification "tpb")
            (list (kw "unknown") (kw "unknown") (kw "unknown"))))
(ok "native Windows ARM64 defers optional FFI resolution"
    (jolt-windows-machine-type? 'arm64nt))
(ok "portable Windows ARM64 defers optional FFI resolution"
    (jolt-windows-machine-type? 'tarm64nt))
(ok "POSIX targets do not use the Windows FFI path"
    (not (jolt-windows-machine-type? 'ta6le)))

(printf "target-descriptor-test: ~a/~a passed\n" (- total fails) total)
(exit (if (> fails 0) 1 0))
