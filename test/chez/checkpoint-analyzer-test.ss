;; Literal checkpoint syntax through the real reader/macro/analyzer host seam.
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a\n" name)))

(define (checkpoint-analyze source)
  (let-values (((form next) (rdr-read-form source 0 (string-length source))))
    (jolt-ce-analyze (make-analyze-ctx "checkpoint.gate") form)))

(define (checkpoint-emit source)
  (let-values (((form next) (rdr-read-form source 0 (string-length source))))
    (let ((ctx (make-analyze-ctx "checkpoint.gate")))
      (jolt-ce-emit
        (jolt-ce-run-passes (jolt-ce-analyze ctx form) ctx)))))

(define (attempt thunk)
  (guard (e (#t (cons 'error e)))
    (cons 'ok (thunk))))

(define (error-result? result)
  (and (pair? result) (eq? 'error (car result))))

(define (contains-text? text needle)
  (let ((text-length (string-length text))
        (needle-length (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i needle-length) text-length) #f)
            ((string=? (substring text i (+ i needle-length)) needle) #t)
            (else (loop (+ i 1)))))))

(define expected-id (keyword "test.poller" "after-reserve-unlock"))
(define expected-op (keyword #f "checkpoint-decl"))
(define kw-plain (keyword #f "plain"))
(define kw-woven (keyword #f "woven"))
(define kw-optimized (keyword #f "optimized"))
(define kw-summaries (keyword #f "summaries"))
(define kw-direct (keyword #f "direct"))
(define kw-checkpoint-sites (keyword #f "checkpoint-sites"))

(define checkpoint-configure!
  (var-deref "jolt.checkpoints" "configure-unit!"))
(define checkpoint-lower
  (var-deref "jolt.checkpoints" "lower"))
(define checkpoint-new-unit
  (var-deref "jolt.passes.types" "new-unit"))
(define checkpoint-record-phase!
  (var-deref "jolt.passes" "record-effect-phase!"))
(define checkpoint-finalize-phase!
  (var-deref "jolt.passes.effects" "finalize-phase!"))
(define checkpoint-weave
  (var-deref "jolt.aspects" "weave"))

;; Direct private expansion: this is the compiler ABI the public macro targets.
(let ((node (checkpoint-analyze
              "(jolt.checkpoints/__checkpoint :test.poller/after-reserve-unlock #{:yield :continue})")))
  (ok "private expansion becomes checkpoint declaration"
      (eq? expected-op (jolt-get node (keyword #f "op"))))
  (ok "qualified checkpoint ID survives analysis"
      (jolt= expected-id (jolt-get node (keyword #f "id"))))
  (ok "literal dispositions survive analysis"
      (= 2 (jolt-count (jolt-get node (keyword #f "dispositions"))))))

;; Public macro expansion reaches the same private analyzer arm.
(let ((node (checkpoint-analyze
              "(jolt.checkpoints/checkpoint! :test.poller/after-reserve-unlock #{:continue})")))
  (ok "public checkpoint macro reaches declaration IR"
      (eq? expected-op (jolt-get node (keyword #f "op")))))

;; __checkpoint is intentionally not a Var. Only the exact macro expansion in
;; operator position is compiler syntax; aliases and higher-order values fail.
(for-each
  (lambda (case)
    (ok (car case) (error-result? (attempt (lambda () (checkpoint-analyze (cdr case)))))))
  '(("private marker cannot be read as a value" .
     "jolt.checkpoints/__checkpoint")
    ("private marker cannot be locally aliased" .
     "(let [cp jolt.checkpoints/__checkpoint] (cp :test/id #{:continue}))")
    ("private marker cannot be passed higher-order" .
     "(map jolt.checkpoints/__checkpoint [])")
    ("dynamic private-marker operands are rejected" .
     "((fn [id ds] (jolt.checkpoints/__checkpoint id ds)) :test/id #{:continue})")))

;; Whole-program caching must retain raw :plain provenance even with no aspects.
;; This recreates bld-wp-infer!'s cache path directly under :controlled.
(let* ((source
         "(jolt.checkpoints/checkpoint! :test.poller/after-reserve-unlock #{:continue})")
       (raw (checkpoint-analyze source))
       (ctx (make-analyze-ctx "checkpoint.gate"))
       (unit (checkpoint-new-unit)))
  (checkpoint-configure! unit (keyword #f "controlled"))
  (checkpoint-record-phase! unit kw-plain raw ctx)
  (let* ((lowered (checkpoint-lower unit raw))
         (woven (checkpoint-weave unit lowered))
         (cached (jolt-assoc woven (keyword #f "effect-plain-recorded") #t)))
    (ok "zero-aspect controlled cache is not stamped aspect-woven"
        (jolt-nil? (jolt-get woven (keyword #f "aspect-woven"))))
    (checkpoint-record-phase! unit kw-woven cached ctx)
    (jolt-ce-run-passes cached ctx unit)
    (let* ((plain-report (checkpoint-finalize-phase! unit kw-plain))
           (woven-report (checkpoint-finalize-phase! unit kw-woven))
           (optimized-report (checkpoint-finalize-phase! unit kw-optimized))
           (plain-summary (jolt-nth (jolt-get plain-report kw-summaries) 0))
           (woven-summary (jolt-nth (jolt-get woven-report kw-summaries) 0))
           (optimized-summary (jolt-nth (jolt-get optimized-report kw-summaries) 0)))
      (ok "cached controlled plain phase retains zero checkpoint sites"
          (= 0 (jolt-count
                 (jolt-get (jolt-get plain-summary kw-direct) kw-checkpoint-sites))))
      (ok "cached controlled woven phase retains checkpoint site"
          (= 1 (jolt-count
                 (jolt-get (jolt-get woven-summary kw-direct) kw-checkpoint-sites))))
      (ok "cached controlled optimized phase retains checkpoint site"
          (= 1 (jolt-count
                 (jolt-get (jolt-get optimized-summary kw-direct) kw-checkpoint-sites)))))))

;; The production path starts with the declaration above but must emit exactly
;; the same Scheme as source with that statement absent, not a no-op call.
(let ((with-checkpoint
        (checkpoint-emit
          "(do (jolt.checkpoints/checkpoint! :test.poller/after-reserve-unlock #{:continue}) :answer)"))
      (without-checkpoint (checkpoint-emit ":answer")))
  (ok "plain run-passes erases checkpoint byte-for-byte"
      (string=? with-checkpoint without-checkpoint))
  (ok "plain emitted Scheme contains no checkpoint runtime symbol"
      (not (contains-text? with-checkpoint "checkpoint"))))

(for-each
  (lambda (case)
    (ok (car case) (error-result? (attempt (lambda () (checkpoint-analyze (cdr case)))))))
  '(("unqualified ID rejected" .
     "(jolt.checkpoints/__checkpoint :unqualified #{:continue})")
    ("nonliteral ID rejected" .
     "(jolt.checkpoints/__checkpoint checkpoint-id #{:continue})")
    ("non-set dispositions rejected" .
     "(jolt.checkpoints/__checkpoint :test/id [:continue])")
    ("empty dispositions rejected" .
     "(jolt.checkpoints/__checkpoint :test/id #{})")
    ("continue is mandatory" .
     "(jolt.checkpoints/__checkpoint :test/id #{:yield})")
    ("unknown disposition rejected" .
     "(jolt.checkpoints/__checkpoint :test/id #{:continue :unknown})")))

(if (= fails 0)
    (printf "checkpoint analyzer: ~a checks passed\n" total)
    (begin
      (printf "checkpoint analyzer: ~a/~a checks FAILED\n" fails total)
      (exit 1)))
