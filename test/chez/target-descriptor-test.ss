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
  (target-facts-for-machine-name machine-name))

(ok "nonthreaded Linux x86-64"
    (equal? (classification "a6le")
            (list (kw "linux") (kw "x86-64") (kw "sysv-amd64"))))
(ok "threaded Linux x86-64"
    (equal? (classification "ta6le")
            (list (kw "linux") (kw "x86-64") (kw "sysv-amd64"))))
(ok "nonthreaded Linux aarch64"
    (equal? (classification "arm64le")
            (list (kw "linux") (kw "aarch64") (kw "aapcs64"))))
(ok "threaded Linux aarch64"
    (equal? (classification "tarm64le")
            (list (kw "linux") (kw "aarch64") (kw "aapcs64"))))
(ok "Linux x86 aliases"
    (and (equal? (classification "i3le")
                 (list (kw "linux") (kw "x86") (kw "sysv-i386")))
         (equal? (classification "ti3le")
                 (list (kw "linux") (kw "x86") (kw "sysv-i386")))))
(ok "Linux ARM32 aliases keep unverified ABI unknown"
    (and (equal? (classification "arm32le")
                 (list (kw "linux") (kw "arm") (kw "unknown")))
         (equal? (classification "tarm32le")
                 (list (kw "linux") (kw "arm") (kw "unknown")))))
(ok "Linux PPC32 aliases keep unverified ABI unknown"
    (and (equal? (classification "ppc32le")
                 (list (kw "linux") (kw "ppc") (kw "unknown")))
         (equal? (classification "tppc32le")
                 (list (kw "linux") (kw "ppc") (kw "unknown")))))
(ok "nonthreaded Darwin x86-64"
    (equal? (classification "a6osx")
            (list (kw "darwin") (kw "x86-64") (kw "sysv-amd64"))))
(ok "threaded Darwin x86-64"
    (equal? (classification "ta6osx")
            (list (kw "darwin") (kw "x86-64") (kw "sysv-amd64"))))
(ok "nonthreaded Darwin aarch64"
    (equal? (classification "arm64osx")
            (list (kw "darwin") (kw "aarch64") (kw "darwin-arm64"))))
(ok "threaded Darwin aarch64"
    (equal? (classification "tarm64osx")
            (list (kw "darwin") (kw "aarch64") (kw "darwin-arm64"))))
(ok "Darwin x86 aliases keep unverified ABI unknown"
    (and (equal? (classification "i3osx")
                 (list (kw "darwin") (kw "x86") (kw "unknown")))
         (equal? (classification "ti3osx")
                 (list (kw "darwin") (kw "x86") (kw "unknown")))))
(ok "Darwin PPC32 aliases keep unverified ABI unknown"
    (and (equal? (classification "ppc32osx")
                 (list (kw "darwin") (kw "ppc") (kw "unknown")))
         (equal? (classification "tppc32osx")
                 (list (kw "darwin") (kw "ppc") (kw "unknown")))))
(ok "nonthreaded Windows x86-64"
    (equal? (classification "a6nt")
            (list (kw "windows") (kw "x86-64") (kw "win64"))))
(ok "threaded Windows x86-64"
    (equal? (classification "ta6nt")
            (list (kw "windows") (kw "x86-64") (kw "win64"))))
(ok "nonthreaded Windows x86"
    (equal? (classification "i3nt")
            (list (kw "windows") (kw "x86") (kw "cdecl-x86"))))
(ok "threaded Windows x86"
    (equal? (classification "ti3nt")
            (list (kw "windows") (kw "x86") (kw "cdecl-x86"))))
(ok "nonthreaded Windows aarch64 keeps unverified ABI unknown"
    (equal? (classification "arm64nt")
            (list (kw "windows") (kw "aarch64") (kw "unknown"))))
(ok "threaded Windows aarch64 keeps unverified ABI unknown"
    (equal? (classification "tarm64nt")
            (list (kw "windows") (kw "aarch64") (kw "unknown"))))
(ok "nonthreaded Linux RISC-V keeps unverified ABI unknown"
    (equal? (classification "rv64le")
            (list (kw "linux") (kw "riscv64") (kw "unknown"))))
(ok "threaded Linux RISC-V keeps unverified ABI unknown"
    (equal? (classification "trv64le")
            (list (kw "linux") (kw "riscv64") (kw "unknown"))))
(ok "nonthreaded Linux LoongArch keeps unverified ABI unknown"
    (equal? (classification "la64le")
            (list (kw "linux") (kw "loongarch64") (kw "unknown"))))
(ok "threaded Linux LoongArch keeps unverified ABI unknown"
    (equal? (classification "tla64le")
            (list (kw "linux") (kw "loongarch64") (kw "unknown"))))
(ok "portable-bytecode target facts fail closed"
    (equal? (classification "tpb")
            (list (kw "unknown") (kw "unknown") (kw "unknown"))))
(for-each
  (lambda (machine-name)
    (ok (string-append "unknown target fails closed: " machine-name)
        (equal? (classification machine-name)
                (list (kw "unknown") (kw "unknown") (kw "unknown")))))
  '("future-a6le" "internet" "aarch64le" "a6windows" "a6le-next" "TA6LE"))
(ok "nonthreaded Windows ARM64 defers optional FFI resolution"
    (jolt-windows-machine-type? 'arm64nt))
(ok "threaded Windows ARM64 defers optional FFI resolution"
    (jolt-windows-machine-type? 'tarm64nt))
(ok "POSIX targets do not use the Windows FFI path"
    (not (jolt-windows-machine-type? 'ta6le)))

(printf "target-descriptor-test: ~a/~a passed\n" (- total fails) total)
(exit (if (> fails 0) 1 0))
