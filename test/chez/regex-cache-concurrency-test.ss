;; regex-cache-concurrency-test.ss -- logical serialization of regex cache work.
;;
;; The translator and engine builder are not leaf transitions: either can reach
;; procedure-valued dispatch.  This test substitutes the translator seam to make
;; parking and reentry deterministic, then proves the cache operation retains
;; logical ownership without carrying a counted Chez mutex across the park.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n" name)))

(define (string-has? s needle)
  (and (string? s)
       (let ((n (string-length s)) (m (string-length needle)))
         (let loop ((i 0))
           (and (<= (+ i m) n)
                (or (string=? (substring s i (+ i m)) needle)
                    (loop (+ i 1))))))))

(define (run-until-terminal f)
  (let loop ((n 0))
    (when (and (< n 20) (not (memq (jolt-fiber-state f) '(done dead))))
      (sa-fiber-run-all)
      (loop (+ n 1)))))

(printf "== regex cache: parking dispatch retains logical exclusion ==\n")
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)

(define original-sre-count-submatches sre-count-submatches)
(define outer-source "jolt-regex-cache-family-a-outer")
(define inner-source "jolt-regex-cache-family-a-inner")
(define contender-source "jolt-regex-cache-family-a-contender")
(define outer-dispatch? #f)
(define inner-reentered? #f)
(set! sre-count-submatches
  (lambda (sre)
    (when (not outer-dispatch?)
      (set! outer-dispatch? #t)
      (ok "translator dispatch runs with zero counted locks"
          (= 0 (jolt-locks-held)))
      (jolt-fiber-park!)
      (regex-parsed-entry inner-source)
      (set! inner-reentered? #t))
    (original-sre-count-submatches sre)))

(define owner
  (sa-fiber-spawn (lambda () (regex-parsed-entry outer-source))))
(sa-fiber-run-all)
(ok "translator may park while retaining logical cache ownership"
    (and outer-dispatch?
         (eq? 'parked (jolt-fiber-state owner))
         (jolt-logical-mutex-locked? regex-cache-mutex)))
(ok "parked preparation publishes no partial outer cache entry"
    (not (hashtable-ref regex-cache outer-source #f)))

(define contender
  (sa-fiber-spawn (lambda () (regex-parsed-entry contender-source))))
(sa-fiber-run-all)
(ok "a concurrent cache mutation waits behind the parked owner"
    (and (eq? 'parked (jolt-fiber-state contender))
         (not (hashtable-ref regex-cache contender-source #f))))

(sa-fiber-resume owner)
(run-until-terminal owner)
(run-until-terminal contender)
(set! sre-count-submatches original-sre-count-submatches)
(ok "owner resumes and reenters cache on the same logical context"
    (and inner-reentered? (eq? 'done (jolt-fiber-state owner))))
(ok "waiting contender completes only after owner publication"
    (and (eq? 'done (jolt-fiber-state contender))
         (hashtable-ref regex-cache outer-source #f)
         (hashtable-ref regex-cache inner-source #f)
         (hashtable-ref regex-cache contender-source #f)
         (not (jolt-logical-mutex-locked? regex-cache-mutex))))

(printf "\n== regex cache: same-key reentry keeps the nested winner ==\n")
(define same-source "jolt-regex-cache-family-a-same-key")
(define same-triggered? #f)
(define nested-entry #f)
(set! sre-count-submatches
  (lambda (sre)
    (when (not same-triggered?)
      (set! same-triggered? #t)
      (set! nested-entry (regex-parsed-entry same-source)))
    (original-sre-count-submatches sre)))
(define outer-entry (regex-parsed-entry same-source))
(set! sre-count-submatches original-sre-count-submatches)
(ok "same-owner same-key parse reenters exactly once" same-triggered?)
(ok "stale outer preparation does not overwrite the nested winner"
    (and (eq? nested-entry outer-entry)
         (eq? nested-entry (hashtable-ref regex-cache same-source #f))))

(printf "\n== regex cache: same-key engine reentry keeps one published engine ==\n")
(define engine-source "jolt-regex-cache-family-a-same-engine")
(define original-irregex irregex)
(define engine-triggered? #f)
(define nested-irx #f)
;; Establish the parsed stage before wrapping the engine constructor, so the
;; recursive call exercises only parsed -> irx publication.
(regex-parsed-entry engine-source)
(set! irregex
  (lambda args
    (when (not engine-triggered?)
      (set! engine-triggered? #t)
      (set! nested-irx (regex-compiled-irx engine-source)))
    (apply original-irregex args)))
(define outer-irx (regex-compiled-irx engine-source))
(set! irregex original-irregex)
(ok "same-owner engine construction reenters exactly once" engine-triggered?)
(ok "stale outer engine does not overwrite the nested winner"
    (and (eq? nested-irx outer-irx)
         (eq? nested-irx
              (vector-ref (hashtable-ref regex-cache engine-source #f) 1))))

(printf "\n== mutation control: counted cache lock rejects the same dispatch ==\n")
(define control-triggered? #f)
(define control-error #f)
(define control-mutex (make-mutex 'regex-cache-counted-control))
(set! sre-count-submatches
  (lambda (sre)
    (when (not control-triggered?)
      (set! control-triggered? #t)
      (jolt-locks-assert-none! 'regex-cache-counted-control))
    (original-sre-count-submatches sre)))
(guard (e (#t (set! control-error e)))
  (jolt-with-mutex control-mutex
    (sre-count-submatches '(seq #\x))))
(set! sre-count-submatches original-sre-count-submatches)
(ok "counted-lock control reaches the same translator dispatch" control-triggered?)
(ok "old counted-lock shape fails at the guarded switch boundary"
    (and control-error
         (string-has? (condition-message control-error) "counted lock")))
(ok "mutation-control unwind releases its counted lock"
    (and (= 0 (jolt-locks-held))
         (mutex-acquire control-mutex #f)))
(when (mutex? control-mutex)
  (guard (e (#t (void))) (mutex-release control-mutex)))

(jolt-fiber-pool-reset!)
(printf "\nregex-cache-concurrency-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "regex-cache-concurrency-test: PASS\n") (exit 0))
    (exit 1))
