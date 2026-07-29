;; codec-binary-alloc-bench.ss — allocation and throughput evidence for jolt.codec.binary. Run:
;;   chez --script test/chez/codec-binary-alloc-bench.ss
;;
;; The GATE here is allocation, not speed. A scalar read or write must not build
;; a temporary array, bytevector or sequence — that is a hard invariant and it is
;; asserted. Throughput is REPORTED across three trials and never gated: a single
;; timing on a shared machine is not evidence for a threshold, and a gate built
;; on one would fail for reasons unrelated to this code.
;;
;; What "zero allocation" means precisely: Chez fixnums are 61-bit and immediate,
;; so every integer read whose VALUE lands in that range, every integer write,
;; every f64 write and every ranged copy allocate nothing at all. Those rows are
;; gated at zero.
;;
;; The remaining rows allocate whole objects, 16 bytes each, and are measured
;; rather than gated because the count belongs to the value or to the
;; environment, not to a staging buffer:
;;
;;   * a u64/i64 value above the fixnum range is a bignum — the result itself;
;;   * a float read is a boxed flonum — likewise;
;;   * a flonum crossing a call boundary in interpreted `chez --script` code is
;;     re-boxed, which the measurement-floor rows demonstrate directly;
;;   * Chez's bytevector-ieee-single-set! costs one object that the double
;;     setter does not, so the f32 write path is not free on this host.
;;
;; f64-bits/bits->f64 reuse a per-thread scratch bytevector allocated once per
;; thread, so no steady-state call builds a buffer. That scratch lives in a
;; non-inheriting thread slot (rt.ss), which is what makes "per-thread" true
;; after a fork; the reuse it preserves is exactly what these rows measure.
;;
;; The control is a byte-at-a-time reconstruction over the same array — what a
;; codec writes when it has no substrate — so the comparison is against a real
;; alternative rather than against nothing. Read its TIME column; its byte column
;; is dominated by the interpreter's handling of a deeply nested expression.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define iterations 200000)
(define warmup 20000)
(define trials 3)
(define copy-size 64)

(define failures 0)
(define (fail! msg) (set! failures (+ failures 1)) (printf "FAIL: ~a\n" msg))

(define arr (na-byte-array 256))
(define dst (na-byte-array 256))
(define scratch (make-bytevector 8 0))
(define sample-f64 1.5)
(let ((bv (jolt-array-vec arr)))
  (do ((i 0 (+ i 1))) ((= i 256))
    (bytevector-u8-set! bv i (bitwise-and (* i 37) 255))))

;; sstats-bytes is the CUMULATIVE allocation counter. (bytes-allocated) reports
;; what is live right now, so a collection inside the measurement window makes it
;; run backwards — it cannot answer "did this operation allocate".
(define (allocated) (sstats-bytes (statistics)))

;; Taking the two readings itself allocates the statistics records; measure that
;; floor once and subtract it, so a genuinely allocation-free operation reports
;; zero rather than a rounding artefact.
(define measurement-overhead
  (let ((a0 (allocated)))
    (do ((i 0 (+ i 1))) ((= i iterations)) #f)
    (- (allocated) a0)))

;; A per-op measurement: warm up (so no first-call scratch or code-path cost is
;; attributed to the steady state), then measure allocated bytes and elapsed
;; milliseconds over `iterations` calls.
(define (measure thunk)
  (do ((i 0 (+ i 1))) ((= i warmup)) (thunk))
  (let* ((a0 (allocated))
         (t0 (real-time)))
    (do ((i 0 (+ i 1))) ((= i iterations)) (thunk))
    (let ((bytes (max 0 (- (allocated) a0 measurement-overhead)))
          (ms (- (real-time) t0)))
      (cons bytes ms))))

(define results '())

;; Two kinds of row.
;;
;; `bench!` GATES: the operation must allocate nothing, and a failure means a
;; temporary array, bytevector or sequence appeared in a scalar path. That is the
;; invariant this file exists to protect.
;;
;; `report!` MEASURES without gating, for rows whose byte count is a property of
;; the measurement environment rather than of the operation. Two such properties
;; show up here, both worth 16 bytes — one Chez object — each:
;;
;;   * a result that cannot be immediate: a u64 above the 61-bit fixnum range is
;;     a bignum, and any float read is a boxed flonum;
;;   * a flonum crossing a call boundary in INTERPRETED script code, which this
;;     file measures directly in the "measurement floor" section below rather
;;     than asserting on faith.
;;
;; Gating those would pin an artifact of `chez --script` into CI.
(define (run-row label thunk gate?)
  (let loop ((n 0) (rows '()))
    (if (= n trials)
        (let* ((rows (reverse rows))
               (per-op (map (lambda (r) (exact->inexact (/ (car r) iterations))) rows))
               (worst (apply max per-op)))
          (set! results (cons (list label gate? rows) results))
          (printf "  ~26a ~a | " label (if gate? "gated 0 B/op" "  measured  "))
          (for-each (lambda (r)
                      (printf "~6,2f B/op ~5a ms  "
                              (exact->inexact (/ (car r) iterations)) (cdr r)))
                    rows)
          (newline)
          ;; 0.01 absorbs the residue of the overhead subtraction, which is four
          ;; orders of magnitude below one object.
          (when (and gate? (> worst 0.01))
            (fail! (format "~a allocated ~a B/op; a scalar path must allocate nothing"
                           label worst))))
        (loop (+ n 1) (cons (measure thunk) rows)))))

(define (bench! label thunk) (run-row label thunk #t))
(define (report! label thunk) (run-row label thunk #f))

(printf "jolt.codec.binary allocation and throughput\n")
(printf "  chez ~a, ~a iterations/trial, ~a warmup, ~a trials\n"
        (call-with-values (lambda () (scheme-version)) (lambda (v) v))
        iterations warmup trials)
(printf "  command: chez --script test/chez/codec-binary-alloc-bench.ss\n\n")

(printf "scalar reads (gated: must allocate nothing)\n")
(bench! "get-u8" (lambda () (jb-get-u8 arr 7)))
(bench! "get-u16-le" (lambda () (jb-get-u16-le arr 7)))
(bench! "get-u16-be" (lambda () (jb-get-u16-be arr 7)))
(bench! "get-u32-le" (lambda () (jb-get-u32-le arr 7)))
(bench! "get-i32-be" (lambda () (jb-get-i32-be arr 7)))
;; A 64-bit read whose VALUE is in fixnum range allocates nothing: the width of
;; the field does not decide this, the magnitude of the result does.
(jb-put-u64-le! arr 0 123456789)
(bench! "get-u64-le (fixnum value)" (lambda () (jb-get-u64-le arr 0)))

(printf "\nscalar writes (gated: must allocate nothing)\n")
(bench! "put-u8!" (lambda () (jb-put-u8! arr 7 200)))
(bench! "put-u16-le!" (lambda () (jb-put-u16-le! arr 7 40000)))
(bench! "put-u32-be!" (lambda () (jb-put-u32-be! arr 7 4000000000)))
(bench! "put-i32-le!" (lambda () (jb-put-i32-le! arr 7 -123456789)))
(bench! "put-i64-le! (fixnum)" (lambda () (jb-put-i64-le! arr 7 123456789)))
;; A float write consumes an existing flonum and stores eight unboxed bytes.
(bench! "put-f64-le!" (lambda () (jb-put-f64-le! arr 0 sample-f64)))

(printf "\nranged copy (gated: must allocate nothing)\n")
(bench! (format "copy! ~a bytes" copy-size)
        (lambda () (jb-copy! arr 0 dst 0 copy-size)))
(bench! (format "copy! ~a self-overlap" copy-size)
        (lambda () (jb-copy! arr 0 arr 8 copy-size)))

(printf "\nmeasurement floor (not the substrate: what this environment costs)\n")
;; A flonum handed to a primitive from interpreted script code. Nothing in
;; jolt.codec.binary is involved; this is the 16 bytes every flonum-carrying row below
;; also pays.
(report! "flonum -> primitive" (lambda () (bytevector-ieee-double-set! scratch 0 sample-f64 (endianness big))))
;; A bignum built by arithmetic, for the same reason.
(report! "bignum from arithmetic" (lambda () (* 1152921504606846976 3)))

(printf "\nresults that are objects by necessity (measured, not gated)\n")
;; A u64 above the 61-bit fixnum range: the bignum IS the result.
(jb-put-u64-le! arr 0 18446744073709551615)
(report! "get-u64-le (bignum value)" (lambda () (jb-get-u64-le arr 0)))
(report! "get-f64-le (flonum)" (lambda () (jb-get-f64-le arr 0)))
;; The scratch bytevector behind these two is allocated once per thread, so what
;; is measured is the result object plus the interpreted-call flonum boxing, and
;; never a per-call buffer.
(report! "f64-bits" (lambda () (jb-f64-bits sample-f64)))
(report! "bits->f64" (lambda () (jb-bits->f64 5)))
;; put-f32-be! costs one object more than put-f64-le! on this host: narrowing a
;; binary64 flonum to binary32 goes through an intermediate that the double
;; setter does not need. It is a property of the Chez primitive, not of a staging
;; buffer here, so it is recorded rather than gated — but it is not zero, and a
;; float-heavy codec should know that the f32 write path is the one that costs.
(report! "put-f32-be!" (lambda () (jb-put-f32-be! arr 0 sample-f64)))

(printf "\ncontrol: byte-at-a-time reconstruction (measured, not gated)\n")
;; What a codec writes without a substrate: four checked byte reads and a
;; shift/add chain. The interesting column here is TIME — the interpreter's own
;; cost for a deeply nested expression makes its byte column an artifact, which
;; is exactly why this row is not gated.
(report! "control u32-be by byte"
         (lambda ()
           (+ (* (jb-get-u8 arr 7) 16777216)
              (* (jb-get-u8 arr 8) 65536)
              (* (jb-get-u8 arr 9) 256)
              (jb-get-u8 arr 10))))
;; And the shape this substrate exists to make unnecessary: staging the same
;; four bytes through a list first.
(report! "control u32-be via list"
         (lambda ()
           (let ((bs (list (jb-get-u8 arr 7) (jb-get-u8 arr 8)
                           (jb-get-u8 arr 9) (jb-get-u8 arr 10))))
             (+ (* (car bs) 16777216) (* (cadr bs) 65536)
                (* (caddr bs) 256) (cadddr bs)))))

(printf "\n")
(printf "allocation gate: ~a rows measured, ~a gated failures\n" (length results) failures)
(printf "throughput is reported, never gated; no threshold is derived from these runs\n")
(exit (if (> failures 0) 1 0))
