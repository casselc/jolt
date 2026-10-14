(import (chezscheme))
(load "host/chez/gate-boot.ss")
(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a~n" name)))
(define (ev s) (jolt-final-str (jolt-compile-eval s "user")))
(define (is name s expected)
  (printf "CHECK: ~a~n" name)
  (flush-output-port (current-output-port))
  (ok name (string=? (ev s) expected)))
(is "live array and close"
    "(let [a (byte-array [1 2 3]) in (java.io.ByteArrayInputStream. a)] (aset-byte a 0 9) (let [x (.read in)] (aset-byte a 1 8) (let [y (.read in)] (.close in) [x y (.read in)])))"
    "[9 8 3]")
(is "slice initial mark, clamp and available"
    "(let [in (java.io.ByteArrayInputStream. (byte-array [1 2 3]) 1 100)] (.read in) (.reset in) [(.available in) (vec (.readAllBytes in))])"
    "[2 [2 3]]")
(is "negative and bounded skip"
    "(let [in (java.io.ByteArrayInputStream. (byte-array [1 2 3]))] [(.skip in -1) (.skip in 100) (.available in) (.read in)])"
    "[0 3 0 -1]")
(is "with-open leaves memory stream usable"
    "(let [in (java.io.ByteArrayInputStream. (byte-array [1 2]))] (with-open [x in] (.read x)) (.read in))" "2")
;; The constructor must not invoke the full-array copying seam.
(let ((original na-bytearray->bv) (calls 0))
  (dynamic-wind
    (lambda () (set! na-bytearray->bv
                 (lambda (a) (set! calls (+ calls 1)) (original a))))
    (lambda ()
      (host-new "ByteArrayInputStream" (make-jolt-array (make-bytevector 65536) 'byte))
      (ok "constructor never snapshots source" (= calls 0)))
    (lambda () (set! na-bytearray->bv original))))
;; Retain the array, not a stale backing or an eager boxed-to-primitive copy.
(let* ((a (make-jolt-array (vector 1 2 3) 'byte))
       (in (host-new "ByteArrayInputStream" a)))
  (ja-set! a 0 9)
  (ok "boxed backing remains live"
      (= 9 (jnum->exact (record-method-dispatch in "read" jolt-nil))))
  (jolt-array-vec-set! a (bytevector 7 8 9))
  (ok "replaced backing remains live"
      (= 8 (jnum->exact (record-method-dispatch in "read" jolt-nil)))))
(printf "byte-array-input-view-test: ~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
