;; ffi-byte-array-pointer-test.ss — scoped directional byte-array pointer-loan gate
;; for jolt.ffi/with-byte-array-pointer.
;;
;; Specifies the whole-array (arr f) and ranged (arr off len f) pointer-loan
;; contract: preserve the legacy :in-out arities and validate exact byte-array
;; kind, direction, and subtraction-safe range BEFORE
;; temporary allocation, locking, or the callback; copy signed jolt bytes into a
;; private native-octet bytevector; lock it for a stable address only for the
;; callback's dynamic extent; copy native octets back as signed bytes on normal
;; return, jolt/host exception, and nonlocal exit; :in skips copy-back, :out
;; starts zeroed and skips copy-in; allow same-array nesting only for read-only
;; :in loans while allowing distinct-array nesting; treat an inherited
;; thread-parameter cell as empty for a different owner thread without claiming
;; that overlapping same-array cross-thread loans are supported; and reject a
;; captured continuation's re-entry after first exit before the callback resumes.
;;
;; The public pointer is an address into the private locked bytevector, NEVER the
;; signed vector backing the jolt byte-array. The portable C helper performs a
;; real write through that pointer; the jolt array changes only when the scope
;; copies native octets back at exit.
;;
;; Run via the wrapper, which compiles and preloads the C helper:
;;   sh test/chez/ffi-byte-array-pointer-test.sh "$(CHEZ)"
;; (from the repo root, like every other gate).

(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/ffi.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
;; eval one form (string) in `user`, like the loader does form-by-form, so a def
;; is visible to a later form.
(define (ev s) (jolt-compile-eval s "user"))
;; substring membership for the continuation-rejection message check.
(define (has? s sub)
  (let ((ns (string-length s)) (nsub (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i nsub) ns) #f)
            ((string=? (substring s i (+ i nsub)) sub) #t)
            (else (loop (+ i 1)))))))

(define helper-so (getenv "JOLT_FFI_BYTE_ARRAY_POINTER_HELPER"))
(unless helper-so
  (error #f "JOLT_FFI_BYTE_ARRAY_POINTER_HELPER must name the compiled helper library"))
(load-shared-object helper-so)

(ev "(jolt.ffi/load-library)")
;; The portable C write helper. Lazy symbol resolution means the def may precede
;; the load-shared-object above; both are present before any call.
(ev "(def c-fill-pointer
       (jolt.ffi/__cfn \"jolt_test_fill_bytes\" [:pointer :uint8 :size_t] :pointer))")

;; --- ranged + whole arities: copy-back and validated length ------------------
(ok "ranged pointer loan copies native octets back as signed bytes"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2 3 4])
                  result (jolt.ffi/with-byte-array-pointer
                           a 1 2
                           (fn [p n]
                             (c-fill-pointer p 200 n)
                             [:returned n]))]
              (and (= [:returned 2] result)
                   (= [1 -56 -56 4] (vec a))))")))
(ok "whole-array pointer loan supplies its validated length"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2 3])]
              (and (= 3 (jolt.ffi/with-byte-array-pointer
                          a (fn [p n] (c-fill-pointer p 255 n) n)))
                   (= [-1 -1 -1] (vec a))))")))

;; --- input conversion: signed bytes are exposed as exact native octets --------
(ok "pointer loan exposes signed input bytes as exact native octets"
    (jolt-truthy?
      (ev "(let [a (byte-array [-128 -1 0 127])]
              (and
                (jolt.ffi/with-byte-array-pointer
                  a
                  (fn [p n]
                    (= [128 255 0 127]
                       (mapv #(jolt.ffi/read p :uint8 %) (range n)))))
                (= [-128 -1 0 127] (vec a))))")))

;; --- directions: copy only the side each native contract requires ------------
(ok ":in exposes input and discards native writes"
    (jolt-truthy?
      (ev "(let [a (byte-array [-128 -1 0 127])]
              (and
                (jolt.ffi/with-byte-array-pointer
                  a :in
                  (fn [p n]
                    (let [before (mapv #(jolt.ffi/read p :uint8 %) (range n))]
                      (c-fill-pointer p 201 n)
                      (= [128 255 0 127] before))))
                (= [-128 -1 0 127] (vec a))))")))
(ok ":out starts zeroed and copies native output back"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2 3 4])]
              (and
                (jolt.ffi/with-byte-array-pointer
                  a 1 2 :out
                  (fn [p n]
                    (let [zeroed? (= [0 0] (mapv #(jolt.ffi/read p :uint8 %) (range n)))]
                      (c-fill-pointer p 202 n)
                      zeroed?)))
                (= [1 -54 -54 4] (vec a))))")))
(ok "explicit :in-out performs both copies"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2 3])]
              (and
                (= [1 2 3]
                   (jolt.ffi/with-byte-array-pointer
                     a :in-out
                     (fn [p n]
                       (let [before (mapv #(jolt.ffi/read p :uint8 %) (range n))]
                         (c-fill-pointer p 203 n)
                         before))))
                (= [-53 -53 -53] (vec a))))")))

;; --- empty ranges: exact-tail and whole --------------------------------------
(ok "exact-tail empty pointer loan is valid"
    (jolt-truthy?
      (ev "(jolt.ffi/with-byte-array-pointer
             (byte-array [1 2]) 2 0
             (fn [p n] (and (integer? p) (zero? n))))")))
(ok "whole empty pointer loan is valid"
    (jolt-truthy?
      (ev "(jolt.ffi/with-byte-array-pointer
             (byte-array 0)
             (fn [p n] (and (integer? p) (zero? n))))")))

;; --- validation BEFORE effects: invalid calls throw AND never invoke the callback
(ok "pointer loan rejects invalid kind and range before callback"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2]) calls (atom 0) f (fn [_ _] (swap! calls inc))]
              (and
                (try (jolt.ffi/with-byte-array-pointer (int-array [1]) f)
                     false (catch IllegalArgumentException _ true))
                (try (jolt.ffi/with-byte-array-pointer (char-array [\\a]) f)
                     false (catch IllegalArgumentException _ true))
                (try (jolt.ffi/with-byte-array-pointer a -1 1 f)
                     false (catch IndexOutOfBoundsException _ true))
                (try (jolt.ffi/with-byte-array-pointer a 0 -1 f)
                     false (catch IndexOutOfBoundsException _ true))
                (try (jolt.ffi/with-byte-array-pointer a 1 2 f)
                     false (catch IndexOutOfBoundsException _ true))
                (try (jolt.ffi/with-byte-array-pointer a 2 1 f)
                     false (catch IndexOutOfBoundsException _ true))
                (try (jolt.ffi/with-byte-array-pointer a 3 0 f)
                     false (catch IndexOutOfBoundsException _ true))
                (try (jolt.ffi/with-byte-array-pointer a 1 4611686018427387904 f)
                     false (catch IndexOutOfBoundsException _ true))
                (try (jolt.ffi/with-byte-array-pointer a :sideways f)
                     false (catch IllegalArgumentException _ true))
                (try (jolt.ffi/with-byte-array-pointer a :ffi/in f)
                     false (catch IllegalArgumentException _ true))
                (try (jolt.ffi/with-byte-array-pointer a 0 1 \"in\" f)
                     false (catch IllegalArgumentException _ true))
                (zero? @calls)))")))

;; --- private scope: host exception, nonlocal control, pointer stability -------
;; Exercised directly so a host (non-jolt) condition and a Scheme nonlocal exit
;; both run the copy-back wind. Each call gets a fresh array so the assertions
;; do not depend on prior test state.
(let* ((a (ev "(byte-array [1 2 3 4])")) (v (jolt-array-vec a))
       (tmp #f) (locked-inside? #f))
  (ok "temporary pointer stays stable through allocation and collection"
      (and (= 2 (ffi-with-scoped-byte-array-pointer "test"
                 a 1 2 (keyword #f "in-out")
                 (lambda (p n)
                   (set! tmp (reference-address->object p))
                   (set! locked-inside? (locked-object? tmp))
                   (make-bytevector 1048576 0)
                   (collect)
                   (foreign-set! 'unsigned-8 p 0 200)
                   n)))
           locked-inside?
           (bytevector? tmp)
           (not (locked-object? tmp))
           (equal? '#(1 -56 3 4) v))))
(let* ((a (ev "(byte-array [1 2 3 4])")) (v (jolt-array-vec a))
       (tmp #f) (locked-inside? #f))
  (ok "host exception copies back and preserves its primary exception"
      (and
       (guard (e (#t (and (string=? (condition-message e) "host loan boom") #t)))
         (ffi-with-scoped-byte-array-pointer "test"
          a 1 2 (keyword #f "in-out")
          (lambda (p n)
            (set! tmp (reference-address->object p))
            (set! locked-inside? (locked-object? tmp))
            (foreign-set! 'unsigned-8 p 0 201)
            (error 'loan "host loan boom")))
         #f)
       locked-inside?
       (bytevector? tmp)
       (not (locked-object? tmp))
       (= -55 (vector-ref v 1)))))
(let* ((a (ev "(byte-array [1 2 3 4])")) (v (jolt-array-vec a))
       (tmp #f) (locked-inside? #f))
  (ok "nonlocal exit copies back"
      (and
       (eq? 'escaped
            (call/cc
             (lambda (escape)
               (ffi-with-scoped-byte-array-pointer "test"
                a 2 1 (keyword #f "in-out")
                (lambda (p n)
                  (set! tmp (reference-address->object p))
                  (set! locked-inside? (locked-object? tmp))
                  (foreign-set! 'unsigned-8 p 0 202)
                  (escape 'escaped))))))
       locked-inside?
       (bytevector? tmp)
       (not (locked-object? tmp))
       (= -54 (vector-ref v 2)))))

;; --- jolt exception: native changes are copied back before propagating --------
(ok "Jolt exception copies native changes back before propagating"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2])]
              (and
                (try
                  (jolt.ffi/with-byte-array-pointer
                    a (fn [p n]
                        (c-fill-pointer p 203 n)
                        (throw (Exception. \"jolt loan boom\"))))
                  false
                  (catch Exception e (= \"jolt loan boom\" (.getMessage e))))
                (= [-53 -53] (vec a))))")))
(ok ":out copies partial output back on Jolt exception"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2])]
              (and
                (try
                  (jolt.ffi/with-byte-array-pointer
                    a :out (fn [p n]
                             (jolt.ffi/write p :uint8 0 204)
                             (throw (Exception. \"out loan boom\"))))
                  false
                  (catch Exception e (= \"out loan boom\" (.getMessage e))))
                (= [-52 0] (vec a))))")))
(ok ":in discards native changes on Jolt exception"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2])]
              (and
                (try
                  (jolt.ffi/with-byte-array-pointer
                    a :in (fn [p n]
                            (c-fill-pointer p 205 n)
                            (throw (Exception. \"in loan boom\"))))
                  false
                  (catch Exception e (= \"in loan boom\" (.getMessage e))))
                (= [1 2] (vec a))))")))

;; --- nesting: same-array read-only allowed, writable rejected -----------------
(ok "same-array read-only nesting is allowed"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2])]
              (jolt.ffi/with-byte-array-pointer a :in
                (fn [pa na]
                  (jolt.ffi/with-byte-array-pointer a 0 1 :in
                    (fn [pb nb]
                      (= [[1 2] [1]]
                         [(mapv #(jolt.ffi/read pa :uint8 %) (range na))
                          (mapv #(jolt.ffi/read pb :uint8 %) (range nb))]))))))")))
(ok "same-array writable nesting is rejected and cross-array nesting copies both back"
    (jolt-truthy?
      (ev "(let [a (byte-array [1 2]) b (byte-array [3 4])]
              (and
                (jolt.ffi/with-byte-array-pointer a
                  (fn [_ _]
                    (try (jolt.ffi/with-byte-array-pointer a (fn [_ _] false))
                         false (catch IllegalStateException _ true))))
                (jolt.ffi/with-byte-array-pointer a :in
                  (fn [_ _]
                    (try (jolt.ffi/with-byte-array-pointer a :out (fn [_ _] false))
                         false (catch IllegalStateException _ true))))
                (jolt.ffi/with-byte-array-pointer a :out
                  (fn [_ _]
                    (try (jolt.ffi/with-byte-array-pointer a :in (fn [_ _] false))
                         false (catch IllegalStateException _ true))))
                (jolt.ffi/with-byte-array-pointer a
                  (fn [pa na]
                    (jolt.ffi/with-byte-array-pointer b
                      (fn [pb nb]
                        (c-fill-pointer pa 204 na)
                        (c-fill-pointer pb 205 nb)
                        true))))
                (= [-52 -52] (vec a)) (= [-51 -51] (vec b))))")))

;; --- thread ownership: an inherited active-loan cell is owner-tagged ----------
;; A Chez thread parameter is inherited by a child thread. The cell carries the
;; owning thread id, so a real child reads its parent's inherited cell as empty.
;; This checks parameter ownership only: the public contract still forbids
;; overlapping loan lifetimes or same-array access across threads.
(ok "a forked child ignores its parent's inherited active-loan cell"
    (let* ((a (ev "(byte-array [1])"))
           (mu (make-mutex)) (cv (make-condition))
           (done? #f) (child-result #f)
           (deadline (ms->deadline 5000))
           (parent-id (get-thread-id))
           (cell (cons parent-id (list (cons a 'in-out)))))
      (parameterize ((ffi-byte-array-loan-cell cell))
        (fork-thread
         (lambda ()
           (let ((result
                  (guard (e (#t e))
                    (and (eq? (ffi-byte-array-loan-cell) cell)
                         (not (= parent-id (get-thread-id)))
                         (null? (ffi-current-byte-array-loans))))))
             (with-mutex mu
               (set! child-result result)
               (set! done? #t)
               (condition-signal cv)))))
        (with-mutex mu
          (let wait ()
            (cond (done? #t)
                  ((condition-wait cv mu deadline) (wait))
                  (else done?)))))
      ;; A lost child or signal is a bounded test failure, never a hung gate.
      (and done? (eq? child-result #t))))

;; --- continuation retirement: re-entry after first exit fails before callback --
;; Capturing a continuation in the callback is legal once. Calling it after the
;; first exit must fail from the scope's before thunk, before callback code runs
;; or a second copy-back can overwrite the caller's value.
(let* ((a (ev "(byte-array [1])")) (v (jolt-array-vec a))
       (saved #f) (visits 0) (phase 0) (tmp #f) (locked-inside? #f)
       (outcome
        (guard (e (#t (list 'raised (condition-message e) visits)))
          (let ((value
                 (ffi-with-scoped-byte-array-pointer "test"
                  a 0 1 (keyword #f "in-out")
                  (lambda (p n)
                    (set! tmp (reference-address->object p))
                    (set! locked-inside? (locked-object? tmp))
                    (call/cc (lambda (k) (unless saved (set! saved k)) 'first))
                    (set! visits (+ visits 1))
                    n))))
            (if (= phase 0)
                (begin
                  (set! phase 1)
                  ;; A second copy-back would overwrite this caller value.
                  (vector-set! v 0 77)
                  (saved 'again))
                (list 'returned value visits))))))
  (ok "retired loan rejects continuation re-entry before callback resumes"
      (and (eq? 'raised (car outcome))
           (has? (cadr outcome) "cannot be re-entered")
           (= 1 (caddr outcome))
           locked-inside?
           (bytevector? tmp)
           (not (locked-object? tmp))
           (= 77 (vector-ref v 0)))))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
