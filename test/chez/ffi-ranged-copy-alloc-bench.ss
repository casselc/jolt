;; ffi-ranged-copy-alloc-bench.ss — allocation and throughput evidence for the
;; ranged jolt.ffi byte transfers. Run:
;;   chez --script test/chez/ffi-ranged-copy-alloc-bench.ss
;;
;; The GATE here is allocation, not speed, and specifically the SHAPE of the
;; allocation as the transfer grows.
;;
;; The accepted implementation staged a ranged transfer through a temporary
;; bytevector: one make-bytevector of exactly `len` bytes per call, plus a
;; second pass over the bytes. That temporary is reimplemented verbatim in this
;; file as the comparator, so the two rows measured side by side are the two
;; real implementations rather than a claim about one of them.
;;
;; The new path locks the destination/source range and moves the bytes once,
;; between native memory and the interior pointer. What it costs per call is
;; Chez's own scope bookkeeping — the locked-object entry, the dynamic-wind
;; winder, and the two thunks — and that cost does not depend on `len`. The
;; breakdown section below measures each piece rather than asserting it.
;;
;; Four gates:
;;
;;   1. A ranged transfer allocates no more than a BARE scope over the same
;;      range with a receiver that copies nothing. That is the exact statement
;;      of "no temporary bytes for the transfer": whatever the scope costs, the
;;      transfer adds nothing on top of it.
;;   2. The per-op cost has zero slope in the transfer size — the same bytes at
;;      16 and at 65536.
;;   3. The comparator, on the same counter, allocates at least `len` bytes per
;;      op. Without this the first two gates would only say the counter is
;;      blind.
;;   4. Whole-array transfers, which pass the bytevector itself as u8* and take
;;      no lock, allocate exactly nothing.
;;
;; Honest trade-off, visible in the rows: the scope is a constant, so below
;; roughly 176 bytes a ranged transfer now allocates MORE than the staged one
;; it replaces (32 B/op at len 16), and above it allocates dramatically less
;; (65557 -> 176 B/op at 64 KiB). The transfer no longer produces GC pressure
;; proportional to the bytes moved, which is the property a codec and a socket
;; path need; a caller moving 16 bytes at a time is better served by the scalar
;; substrate than by an FFI transfer either way.
;;
;; Throughput is REPORTED across three trials and never gated. A single timing
;; on a shared machine is not evidence for a threshold.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/ffi.ss")

(define iterations 20000)
(define warmup 2000)
(define trials 3)
(define lengths '(16 64 256 4096 65536))
(define ceiling-bytes 256.0)

(define failures 0)
(define (fail! msg) (set! failures (+ failures 1)) (printf "FAIL: ~a\n" msg))

;; The accepted HK0A.1 ranged implementation, kept here as the comparator.
(define memcpy-from-pointer! (foreign-procedure "memcpy" (u8* uptr uptr) void*))
(define memcpy-to-pointer! (foreign-procedure "memcpy" (uptr u8* uptr) void*))
(define (staged-copy-from-pointer! p bv start cnt)
  (when (> cnt 0)
    (if (and (= start 0) (= cnt (bytevector-length bv)))
        (memcpy-from-pointer! bv p cnt)
        (let ((tmp (make-bytevector cnt)))
          (memcpy-from-pointer! tmp p cnt)
          (bytevector-copy! tmp 0 bv start cnt)))))
(define (staged-copy-to-pointer! p bv start cnt)
  (when (> cnt 0)
    (if (and (= start 0) (= cnt (bytevector-length bv)))
        (memcpy-to-pointer! p bv cnt)
        (let ((tmp (make-bytevector cnt)))
          (bytevector-copy! bv start tmp 0 cnt)
          (memcpy-to-pointer! p tmp cnt)))))

;; sstats-bytes is the CUMULATIVE allocation counter. (bytes-allocated) reports
;; what is live right now, so a collection inside the measurement window makes
;; it run backwards — it cannot answer "did this operation allocate".
(define (allocated) (sstats-bytes (statistics)))

(define measurement-overhead
  (begin
    (collect)
    (let ((a0 (allocated)))
      (do ((i 0 (+ i 1))) ((= i iterations)) #f)
      (- (allocated) a0))))

;; Collect before opening the window. Without it a collection triggered inside
;; the window by an EARLIER row's garbage adds its own bookkeeping to this row,
;; which shows up as a sporadic one-object (16 B/op) inflation on rows that
;; allocate nothing of the kind. With it, every row here reads the same value on
;; every trial.
(define (measure thunk)
  (do ((i 0 (+ i 1))) ((= i warmup)) (thunk))
  (collect)
  (let* ((a0 (allocated))
         (t0 (real-time)))
    (do ((i 0 (+ i 1))) ((= i iterations)) (thunk))
    (let ((bytes (max 0 (- (allocated) a0 measurement-overhead)))
          (ms (- (real-time) t0)))
      (cons bytes ms))))

(define (per-op-worst label thunk kind)
  (let loop ((n 0) (rows '()))
    (if (= n trials)
        (let* ((rows (reverse rows))
               (per-op (map (lambda (r) (exact->inexact (/ (car r) iterations))) rows))
               (worst (apply max per-op))
               (best-ms (apply min (map cdr rows))))
          (printf "  ~34a ~12a | " label kind)
          (for-each (lambda (r)
                      (printf "~8,2f B/op ~5a ms  "
                              (exact->inexact (/ (car r) iterations)) (cdr r)))
                    rows)
          (newline)
          (cons worst best-ms))
        (loop (+ n 1) (cons (measure thunk) rows)))))

;; Fixtures. The array is two bytes longer than the transfer so the ranged rows
;; are genuinely ranged (offset 1), which is the path that used to stage.
(define (fixtures len)
  (let* ((arr (make-jolt-array (make-bytevector (+ len 2) 7) 'byte))
         (bv (jolt-array-vec arr))
         (p (foreign-alloc (+ len 2))))
    (do ((i 0 (+ i 1))) ((= i (+ len 2)))
      (foreign-set! 'unsigned-8 p i (bitwise-and (* i 37) 255)))
    (list arr bv p)))

(printf "jolt.ffi ranged transfer allocation and throughput\n")
(printf "  chez ~a, ~a iterations/trial, ~a warmup, ~a trials\n"
        (scheme-version) iterations warmup trials)
(printf "  command: chez --script test/chez/ffi-ranged-copy-alloc-bench.ss\n\n")

(define scoped-results '())
(define staged-results '())
(define whole-results '())
(define bare-scope-results '())
(define (receive-nothing p cnt arg) cnt)

(printf "ranged read-array! / write-array, offset 1 (gated: no more than a bare scope, constant in len, under ~a B/op)\n"
        ceiling-bytes)
(for-each
  (lambda (len)
    (let* ((f (fixtures len))
           (arr (car f)) (bv (cadr f)) (p (caddr f)))
      (set! scoped-results
            (cons (cons len (per-op-worst (format "read-array! ~a ranged" len)
                                          (lambda () (ffi-read-array! p len arr 1))
                                          "scoped"))
                  scoped-results))
      (set! scoped-results
            (cons (cons len (per-op-worst (format "write-array ~a ranged" len)
                                          (lambda () (ffi-write-array p arr 1 len))
                                          "scoped"))
                  scoped-results))
      (set! staged-results
            (cons (cons len (per-op-worst (format "read-array! ~a staged (accepted)" len)
                                          (lambda () (staged-copy-from-pointer! p bv 1 len))
                                          "comparator"))
                  staged-results))
      (set! staged-results
            (cons (cons len (per-op-worst (format "write-array ~a staged (accepted)" len)
                                          (lambda () (staged-copy-to-pointer! p bv 1 len))
                                          "comparator"))
                  staged-results))
      (set! bare-scope-results
            (cons (cons len (per-op-worst (format "bare scope ~a (copies nothing)" len)
                                          (lambda ()
                                            (ffi-with-locked-byte-range
                                              "bench" bv 1 len receive-nothing 0))
                                          "scope only"))
                  bare-scope-results))
      (foreign-free p)))
  lengths)

(printf "\nwhole-array transfers (gated: must allocate nothing)\n")
(for-each
  (lambda (len)
    (let* ((arr (make-jolt-array (make-bytevector len 7) 'byte))
           (p (foreign-alloc len)))
      (set! whole-results
            (cons (cons len (per-op-worst (format "read-array! ~a whole" len)
                                          (lambda () (ffi-read-array! p len arr 0))
                                          "scoped"))
                  whole-results))
      (set! whole-results
            (cons (cons len (per-op-worst (format "write-array ~a whole" len)
                                          (lambda () (ffi-write-array p arr))
                                          "scoped"))
                  whole-results))
      (foreign-free p)))
  lengths)

;; What the constant is made of, so the gates below are read against a measured
;; breakdown rather than a claim. Reported, not gated.
(printf "\nscope cost breakdown (reported: what the constant per-op cost is)\n")
(let* ((arr (make-jolt-array (make-bytevector 2048 7) 'byte))
       (bv (jolt-array-vec arr)))
  (per-op-worst "lock-object + unlock-object"
                (lambda () (lock-object bv) (unlock-object bv)) "component")
  (per-op-worst "dynamic-wind alone"
                (lambda () (dynamic-wind void (lambda () 1) (lambda () 2))) "component")
  (per-op-worst "object->reference-address alone"
                (lambda () (object->reference-address bv)) "component"))

(printf "\n")

;; Gate 1: a ranged transfer costs no more than a bare scope over the same
;; range. This is the zero-temporary-bytes statement: the memmove itself, and
;; everything needed to reach the pointer, add nothing to the scope.
(let ((bare (map (lambda (r) (cons (car r) (cadr r))) bare-scope-results)))
  (for-each
    (lambda (r)
      (let* ((len (car r))
             (worst (cadr r))
             (base (cdr (assv len bare))))
        (when (> (- worst base) 0.01)
          (fail! (format "ranged transfer at len ~a allocated ~,2f B/op over a bare scope's ~,2f B/op; the transfer is building something"
                         len worst base)))))
    scoped-results))

;; Gate 2: the per-op allocation does not grow with the transfer.
(let* ((worsts (map (lambda (r) (cadr r)) scoped-results))
       (lo (apply min worsts))
       (hi (apply max worsts)))
  (printf "ranged per-op allocation across ~a..~a bytes: min ~,2f, max ~,2f B/op\n"
          (apply min lengths) (apply max lengths) lo hi)
  ;; One object of tolerance. A per-call temporary would move this by `len`,
  ;; which at 65536 is three orders of magnitude outside it.
  (when (> (- hi lo) 0.01)
    (fail! (format "ranged allocation varies with length (~,2f..~,2f B/op); a per-call temporary would do that"
                   lo hi)))
  (when (> hi ceiling-bytes)
    (fail! (format "ranged allocation ~,2f B/op exceeds the ~,2f B/op scope ceiling" hi ceiling-bytes))))

;; Gate 3: the counter can see a per-call temporary — the comparator's cost
;; tracks the transfer size, at least one byte per transferred byte.
(for-each
  (lambda (r)
    (let ((len (car r)) (worst (cadr r)))
      (when (< worst (exact->inexact len))
        (fail! (format "comparator at len ~a allocated only ~,2f B/op; the counter cannot see the staged buffer, so the ranged gates prove nothing"
                       len worst)))))
  (filter (lambda (r) (>= (car r) 256)) staged-results))

;; Gate 4: whole-array transfers allocate nothing at all.
(for-each
  (lambda (r)
    (when (> (cadr r) 0.01)
      (fail! (format "whole-array transfer at len ~a allocated ~,2f B/op" (car r) (cadr r)))))
  whole-results)

;; Throughput, reported only.
(printf "\nthroughput (reported, never gated) — best of ~a trials, MB/s\n" trials)
(for-each
  (lambda (pair)
    (let ((label (car pair)))
      (for-each
        (lambda (r)
          (let ((len (car r)) (ms (cddr r)))
            (printf "  ~12a len ~6a  ~a\n"
                    label len
                    (if (= ms 0)
                        "(too fast to time)"
                        (format "~,1f MB/s"
                                (/ (* 1.0 len iterations) (* 1024.0 1024.0 (/ ms 1000.0))))))))
        (reverse (cdr pair)))))
  (list (cons "scoped" scoped-results)
        (cons "comparator" staged-results)
        (cons "whole" whole-results)))

(printf "\nranged-transfer allocation gate: ~a scoped rows, ~a bare-scope rows, ~a comparator rows, ~a whole-array rows, ~a gated failures\n"
        (length scoped-results) (length bare-scope-results)
        (length staged-results) (length whole-results) failures)
(printf "throughput is reported, never gated; no threshold is derived from these runs\n")
(exit (if (> failures 0) 1 0))
