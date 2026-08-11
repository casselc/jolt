;; Scoped byte-array pointer loans: real native writes, exact signed-byte
;; copy-back, validation-before-callback, cleanup winds, and lifetime rules.
(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/ffi.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a~n" name)))
(define (ev s) (jolt-compile-eval s "user"))
(define (has? s sub)
  (let ((ns (string-length s)) (nsub (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i nsub) ns) #f)
            ((string=? (substring s i (+ i nsub)) sub) #t)
            (else (loop (+ i 1)))))))

(define helper-so (getenv "JOLT_FFI_BYTE_ARRAY_POINTER_HELPER"))
(unless helper-so
  (error #f "JOLT_FFI_BYTE_ARRAY_POINTER_HELPER is required"))
(load-shared-object helper-so)
(ev "(jolt.ffi/load-library)")
(ev "(def c-fill-pointer
       (jolt.ffi/__cfn \"jolt_test_fill_bytes\"
                       [:pointer :uint8 :size_t] :pointer))")

(ok "range copies real C mutation back as signed bytes"
    (jolt-truthy?
     (ev "(let [a (byte-array [1 2 3 4])
                 r (jolt.ffi/with-byte-array-pointer
                     a 1 2 (fn [p n] (c-fill-pointer p 200 n) [:ok n]))]
             (and (= [:ok 2] r) (= [1 -56 -56 4] (vec a))))")))
(ok "whole loan preserves exact input octets and length"
    (jolt-truthy?
     (ev "(let [a (byte-array [-128 -1 0 127])]
             (and
              (= [128 255 0 127]
                 (jolt.ffi/with-byte-array-pointer
                  a (fn [p n]
                      (mapv #(jolt.ffi/read p :uint8 %) (range n)))))
              (= [-128 -1 0 127] (vec a))))")))
(ok "empty whole and exact-tail ranges are admitted"
    (jolt-truthy?
     (ev "(and
            (jolt.ffi/with-byte-array-pointer
             (byte-array 0) (fn [p n] (and (integer? p) (zero? n))))
            (jolt.ffi/with-byte-array-pointer
             (byte-array [1 2]) 2 0
             (fn [p n] (and (integer? p) (zero? n)))))")))
(ok "kind and range failures precede callback"
    (jolt-truthy?
     (ev "(let [a (byte-array [1 2]) calls (atom 0)
                 f (fn [_ _] (swap! calls inc))]
             (and
              (try (jolt.ffi/with-byte-array-pointer (int-array [1]) f)
                   false (catch IllegalArgumentException _ true))
              (try (jolt.ffi/with-byte-array-pointer a -1 1 f)
                   false (catch IndexOutOfBoundsException _ true))
              (try (jolt.ffi/with-byte-array-pointer a 1 2 f)
                   false (catch IndexOutOfBoundsException _ true))
              (try (jolt.ffi/with-byte-array-pointer a 3 0 f)
                   false (catch IndexOutOfBoundsException _ true))
              (zero? @calls)))")))

(let* ((a (ev "(byte-array [1 2 3])")) (v (jolt-array-vec a)))
  (ok "foreign pointer remains stable across collection"
      (and (= 2 (ffi-with-scoped-byte-array-pointer
                 "test" a 1 2
                 (lambda (p n)
                   (make-bytevector 1048576 0)
                   (collect)
                   (sa-foreign-set! 'unsigned-8 p 0 201)
                   n)))
           (equal? '#(1 -55 3) v))))
(let* ((a (ev "(byte-array [1 2])")) (v (jolt-array-vec a)))
  (ok "host exception copies back and stays primary"
      (and
       (guard (e (#t (string=? (condition-message e) "loan boom")))
         (ffi-with-scoped-byte-array-pointer
          "test" a 0 1
          (lambda (p n)
            (sa-foreign-set! 'unsigned-8 p 0 202)
            (error 'loan "loan boom")))
         #f)
       (= -54 (vector-ref v 0)))))
(let* ((a (ev "(byte-array [1 2])")) (v (jolt-array-vec a)))
  (ok "nonlocal exit copies back"
      (and
       (eq? 'escaped
            (call/cc
             (lambda (escape)
               (ffi-with-scoped-byte-array-pointer
                "test" a 1 1
                (lambda (p n)
                  (sa-foreign-set! 'unsigned-8 p 0 203)
                  (escape 'escaped))))))
       (= -53 (vector-ref v 1)))))
(ok "Jolt exception copies back"
    (jolt-truthy?
     (ev "(let [a (byte-array [1 2])]
             (and
              (try
               (jolt.ffi/with-byte-array-pointer
                a (fn [p n]
                    (c-fill-pointer p 204 n)
                    (throw (Exception. \"jolt loan boom\"))))
               false
               (catch Exception e (= \"jolt loan boom\" (.getMessage e))))
              (= [-52 -52] (vec a))))")))
(ok "same-array nesting rejects while distinct arrays compose"
    (jolt-truthy?
     (ev "(let [a (byte-array [1]) b (byte-array [2])]
             (and
              (jolt.ffi/with-byte-array-pointer
               a (fn [_ _]
                   (try
                    (jolt.ffi/with-byte-array-pointer a (fn [_ _] false))
                    false (catch IllegalStateException _ true))))
              (jolt.ffi/with-byte-array-pointer
               a (fn [pa na]
                   (jolt.ffi/with-byte-array-pointer
                    b (fn [pb nb]
                        (c-fill-pointer pa 205 na)
                        (c-fill-pointer pb 206 nb)
                        true))))
              (= [-51] (vec a)) (= [-50] (vec b))))")))

(let* ((a (ev "(byte-array [1])")) (v (jolt-array-vec a))
       (saved #f) (visits 0) (phase 0)
       (outcome
        (guard (e (#t (list 'raised (condition-message e) visits)))
          (let ((value
                 (ffi-with-scoped-byte-array-pointer
                  "test" a 0 1
                  (lambda (p n)
                    (call/cc (lambda (k) (unless saved (set! saved k)) 'first))
                    (set! visits (+ visits 1))
                    n))))
            (if (= phase 0)
                (begin
                  (set! phase 1)
                  (vector-set! v 0 77)
                  (saved 'again))
                (list 'returned value visits))))))
  (ok "retired continuation cannot resume or copy back twice"
      (and (eq? 'raised (car outcome))
           (has? (cadr outcome) "cannot be re-entered")
           (= 1 (caddr outcome))
           (= 77 (vector-ref v 0)))))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
