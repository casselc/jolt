;; ffi.ss — the runtime side of jolt's foreign-function interface (jolt.ffi).
;;
;; A jolt LIBRARY binds native code itself: it loads a shared object and declares
;; typed foreign functions, then exposes a Clojure API. The TYPED CALL is lowered
;; at compile time to a Chez `foreign-procedure` by the backend (the
;; `jolt.ffi/foreign-fn` special form) — this file provides everything that does
;; NOT need compile-time types: loading libraries, allocating/reading/writing
;; foreign memory, and string/pointer marshaling. All exposed under `jolt.ffi`.
;;
;; A foreign pointer is a Chez machine address (an exact integer / uptr), the same
;; representation `void*` arguments and results use, so pointers flow between
;; foreign-fn calls and these helpers transparently.

;; --- loading shared objects --------------------------------------------------
;; (jolt.ffi/load-library name) loads a .so/.dylib by name (resolved by the OS
;; loader against the standard search paths). A library typically calls this once
;; at load with a platform-specific name. (load-library) with no name (or #f)
;; loads the running process's own symbols (libc, sockets).
;; Every operation exposed under jolt.ffi below reads the internal interception
;; hook once per call (see the "declared foreign-call interception" section at
;; the bottom — the same seam covers these raw operations).  #f runs the
;; original body directly: one variable read and one branch, with no descriptor
;; or proceed allocation.  Each original body appears twice, once as the
;; proceed thunk and once as the disabled branch, mirroring the compiler's
;; emitted shape for declared calls, so proceed executes exactly the original
;; operation — same results, same validation, same exceptions.
(define (ffi-load-library . args)
  (let ((h jolt-ffi-declared-call-hook))
    (if h
        (jolt-ffi-invoke-native-op-hook
         ;; The descriptor list spine is a per-call snapshot of the lexical
         ;; rest list: a hook mutating descriptor args must not redirect the
         ;; real operation, which always applies the untouched lexical args.
         h "load-library" (list-copy args)
         (lambda ()
           (if (or (null? args) (jolt-nil? (car args)))
               (begin (load-shared-object #f) jolt-nil)
               (begin (load-shared-object (jolt-str-render-one (car args)))
                      jolt-nil))))
        (if (or (null? args) (jolt-nil? (car args)))
            (begin (load-shared-object #f) jolt-nil)
            (begin (load-shared-object (jolt-str-render-one (car args)))
                   jolt-nil)))))

(define (ffi-loaded? name)
  (let ((h jolt-ffi-declared-call-hook))
    (if h
        (jolt-ffi-invoke-native-op-hook
         h "loaded?" (list name)
         (lambda ()
           (guard (e (#t #f)) (load-shared-object (jolt-str-render-one name)) #t)))
        (guard (e (#t #f)) (load-shared-object (jolt-str-render-one name)) #t))))

;; --- foreign type keywords ---------------------------------------------------
;; The keyword type names jolt.ffi accepts (in foreign-fn signatures and the
;; memory accessors) map to Chez foreign types. Kept in one place so the backend
;; (compile-time, for foreign-procedure) and these accessors (runtime, for
;; foreign-ref/set!) agree — see ffi-types in jolt-core/jolt/backend_scheme.clj
;; (baked into the checked-in seed, so a newly added signature type rides the
;; next seed remint).
;; The exact scalar widths (int8/16/32, uint8/16/32) are fixed-width, native
;; byte order: the signed and unsigned widths at each size expose the SAME
;; stored bits (a :uint16 read of a :int16 -1 write is 65535), so a memory
;; access and a typed foreign call agree on layout. Wire byte order stays an
;; explicit conversion (htons/ntohs or a codec).
(define (ffi-type->chez kw)
  (let ((n (if (keyword-t? kw) (keyword-t-name kw) (jolt-str-render-one kw))))
    (cond
      ((string=? n "int") 'int)
      ((string=? n "uint") 'unsigned-int)
      ((or (string=? n "int8") (string=? n "i8")) 'integer-8)
      ((or (string=? n "int16") (string=? n "short")) 'integer-16)
      ((or (string=? n "uint16") (string=? n "ushort")) 'unsigned-16)
      ((string=? n "int32") 'integer-32)
      ((string=? n "uint32") 'unsigned-32)
      ((string=? n "long") 'long)
      ((string=? n "ulong") 'unsigned-long)
      ((string=? n "int64") 'integer-64)
      ((string=? n "uint64") 'unsigned-64)
      ((string=? n "size_t") 'size_t)
      ((string=? n "ssize_t") 'ssize_t)
      ((string=? n "iptr") 'iptr)
      ((string=? n "uptr") 'uptr)
      ((string=? n "double") 'double)
      ((string=? n "float") 'float)
      ((or (string=? n "pointer") (string=? n "void*")) 'void*)
      ((string=? n "string") 'string)
      ((string=? n "void") 'void)
      ((or (string=? n "uint8") (string=? n "u8") (string=? n "byte")) 'unsigned-8)
      ((string=? n "char") 'char)
      (else (error #f (string-append "jolt.ffi: unknown foreign type :" n))))))

;; --- foreign memory ----------------------------------------------------------
;; alloc returns a pointer (integer address). The caller frees it. read/write take
;; a type keyword and an optional byte offset.
(define (ffi-alloc nbytes)
  (let ((h jolt-ffi-declared-call-hook))
    (if h
        (jolt-ffi-invoke-native-op-hook
         h "alloc" (list nbytes)
         (lambda () (foreign-alloc (jnum->exact nbytes))))
        (foreign-alloc (jnum->exact nbytes)))))
(define (ffi-free ptr)
  (let ((h jolt-ffi-declared-call-hook))
    (if h
        (jolt-ffi-invoke-native-op-hook
         h "free" (list ptr)
         (lambda () (foreign-free (jnum->exact ptr)) jolt-nil))
        (begin (foreign-free (jnum->exact ptr)) jolt-nil))))
(define (ffi-read ptr ty . off)
  (let ((h jolt-ffi-declared-call-hook))
    (if h
        (jolt-ffi-invoke-native-op-hook
         ;; As with load-library, the descriptor tail spine-copies the lexical
         ;; offset list, so hook mutation of descriptor args cannot move the
         ;; real read's pointer offset.
         h "read" (cons ptr (cons ty (list-copy off)))
         (lambda ()
           (foreign-ref (ffi-type->chez ty) (jnum->exact ptr)
                        (if (pair? off) (jnum->exact (car off)) 0))))
        (foreign-ref (ffi-type->chez ty) (jnum->exact ptr)
                     (if (pair? off) (jnum->exact (car off)) 0)))))
(define (ffi-write ptr ty off val)
  (let ((h jolt-ffi-declared-call-hook))
    (if h
        (jolt-ffi-invoke-native-op-hook
         h "write" (list ptr ty off val)
         (lambda ()
           (foreign-set! (ffi-type->chez ty) (jnum->exact ptr)
                         (jnum->exact off) val)
           jolt-nil))
        (begin
          (foreign-set! (ffi-type->chez ty) (jnum->exact ptr)
                        (jnum->exact off) val)
          jolt-nil))))
;; sizeof a foreign type (for laying out structs / arrays).
(define (ffi-sizeof ty)
  (let ((h jolt-ffi-declared-call-hook))
    (if h
        (jolt-ffi-invoke-native-op-hook
         h "sizeof" (list ty)
         (lambda () (foreign-sizeof (ffi-type->chez ty))))
        (foreign-sizeof (ffi-type->chez ty)))))
(define (ffi-null? ptr) (and (number? ptr) (= (jnum->exact ptr) 0)))
(define ffi-null 0)

;; --- buffer I/O (known length) ----------------------------------------------
;; read n bytes at ptr as a string (UTF-8, falling back to latin1 for invalid
;; sequences) — for a socket recv buffer and similar fixed-length reads.
(define (ffi-read-bytes ptr n)
  (let ((h jolt-ffi-declared-call-hook))
    (if h
        (jolt-ffi-invoke-native-op-hook
         h "read-bytes" (list ptr n)
         (lambda ()
           (let* ((n (jnum->exact n)) (p (jnum->exact ptr))
                  (bv (make-bytevector n)))
             (do ((i 0 (+ i 1))) ((= i n))
               (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 p i)))
             (guard
               (e (#t (list->string (map integer->char (bytevector->u8-list bv)))))
               (utf8->string bv)))))
        (let* ((n (jnum->exact n)) (p (jnum->exact ptr)) (bv (make-bytevector n)))
          (do ((i 0 (+ i 1))) ((= i n))
            (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 p i)))
          (guard
            (e (#t (list->string (map integer->char (bytevector->u8-list bv)))))
            (utf8->string bv))))))
;; write a string's UTF-8 bytes into ptr (no NUL terminator); return the count.
(define (ffi-write-bytes ptr s)
  (let ((h jolt-ffi-declared-call-hook))
    (if h
        (jolt-ffi-invoke-native-op-hook
         h "write-bytes" (list ptr s)
         (lambda ()
           (let* ((bv (string->utf8 (jolt-str-render-one s)))
                  (n (bytevector-length bv)) (p (jnum->exact ptr)))
             (do ((i 0 (+ i 1))) ((= i n))
               (foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)))
             n)))
        (let* ((bv (string->utf8 (jolt-str-render-one s)))
               (n (bytevector-length bv)) (p (jnum->exact ptr)))
          (do ((i 0 (+ i 1))) ((= i n))
            (foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)))
          n))))
(def-var! "jolt.ffi" "read-bytes" ffi-read-bytes)
(def-var! "jolt.ffi" "write-bytes" ffi-write-bytes)

;; --- byte-array buffer I/O (binary-faithful) --------------------------------
;; Move raw bytes between a jolt byte-array (jolt-array kind 'byte) and foreign
;; memory, byte-exact (no UTF-8 / latin1 decode) — for socket recv/send and the
;; zlib / OpenSSL buffers an HTTP client passes through. read-array returns a
;; fresh byte-array of n bytes; read-array! copies n native octets INTO an
;; existing byte-array at an offset (mutating only that range); write-array
;; copies a byte-array's bytes into ptr. The ranged write-array form
;; (write-array ptr src src-off len) copies a source sub-range; the original
;; whole-array (write-array ptr src) form is unchanged. Foreign memory is
;; unsigned octets and a byte-array element is a signed byte, so the two
;; directions fold (na-u8->byte) and mask (#xff) across that seam.
;;
;; read-array! and the ranged write-array VALIDATE the exact byte-array kind,
;; the complete range (subtraction-form bounds len <= length - offset, which an
;; offset-beyond-length or too-large len fails without an offset+len overflow),
;; and that a null pointer appears only for a zero-length transfer — all BEFORE
;; any native access or destination/source mutation, so a rejected call is a
;; no-op. One side of a transfer is always foreign memory and the other a
;; Scheme-held vector, so source and destination can never alias. Both return
;; the copied length.
(define (ffi-byte-array-vector who arr)
  (if (and (jolt-array? arr) (eq? (jolt-array-kind arr) 'byte))
      (jolt-array-vec arr)
      (throw-jvm (quote IllegalArgumentException)
                 (string-append "jolt.ffi/" who ": expected byte-array"))))
(define (ffi-check-array-range who v off len)
  (let ((n (vector-length v)))
    ;; Keep the final check in subtraction form. Besides admitting the exact
    ;; empty tail, it never constructs the potentially huge sum off+len.
    (when (or (< off 0) (< len 0) (> off n) (> len (- n off)))
      (throw-jvm (quote IndexOutOfBoundsException)
                 (string-append "jolt.ffi/" who ": byte-array range out of bounds")))))
(define (ffi-check-transfer-pointer who ptr len)
  ;; No native address is dereferenced for an empty transfer, so zero is valid
  ;; exactly in that case. Reject every non-empty null before foreign-ref/set!.
  (when (and (> len 0) (= ptr 0))
    (throw-jvm (quote NullPointerException)
               (string-append "jolt.ffi/" who ": null pointer"))))
(define (ffi-read-array ptr n)
  (let ((h jolt-ffi-declared-call-hook))
    (if h
        (jolt-ffi-invoke-native-op-hook
         h "read-array" (list ptr n)
         (lambda ()
           (let* ((n (jnum->exact n)) (p (jnum->exact ptr))
                  (v (make-vector n 0)))
             (do ((i 0 (+ i 1))) ((= i n))
               (vector-set! v i (na-u8->byte (foreign-ref 'unsigned-8 p i))))
             (make-jolt-array v 'byte))))
        (let* ((n (jnum->exact n)) (p (jnum->exact ptr)) (v (make-vector n 0)))
          (do ((i 0 (+ i 1))) ((= i n))
            (vector-set! v i (na-u8->byte (foreign-ref 'unsigned-8 p i))))
          (make-jolt-array v 'byte)))))
(define (ffi-read-array! ptr len dest dest-off)
  (let ((h jolt-ffi-declared-call-hook))
    (if h
        (jolt-ffi-invoke-native-op-hook
         h "read-array!" (list ptr len dest dest-off)
         (lambda ()
           (let* ((v (ffi-byte-array-vector "read-array!" dest))
                  (n (jnum->exact len))
                  (off (jnum->exact dest-off)))
             (ffi-check-array-range "read-array!" v off n)
             (let ((p (jnum->exact ptr)))
               (ffi-check-transfer-pointer "read-array!" p n)
               (do ((i 0 (+ i 1))) ((= i n))
                 (vector-set! v (+ off i)
                              (na-u8->byte (foreign-ref 'unsigned-8 p i))))
               n))))
        (let* ((v (ffi-byte-array-vector "read-array!" dest))
               (n (jnum->exact len))
               (off (jnum->exact dest-off)))
          (ffi-check-array-range "read-array!" v off n)
          (let ((p (jnum->exact ptr)))
            (ffi-check-transfer-pointer "read-array!" p n)
            (do ((i 0 (+ i 1))) ((= i n))
              (vector-set! v (+ off i)
                           (na-u8->byte (foreign-ref 'unsigned-8 p i))))
            n)))))
;; Each write-array arity intercepts independently, so the descriptor's
;; argument count — two for the whole-array form, four for the ranged form —
;; tells a controller which shape was called.
(define ffi-write-array
  (case-lambda
    ((ptr arr)                          ; whole-array form (unchanged)
     (let ((h jolt-ffi-declared-call-hook))
       (if h
           (jolt-ffi-invoke-native-op-hook
            h "write-array" (list ptr arr)
            (lambda ()
              (let* ((v (jolt-array-vec arr)) (n (vector-length v))
                     (p (jnum->exact ptr)))
                (do ((i 0 (+ i 1))) ((= i n))
                  (foreign-set! 'unsigned-8 p i
                                (bitwise-and (exact (vector-ref v i)) #xff)))
                n)))
           (let* ((v (jolt-array-vec arr)) (n (vector-length v))
                  (p (jnum->exact ptr)))
             (do ((i 0 (+ i 1))) ((= i n))
               (foreign-set! 'unsigned-8 p i
                             (bitwise-and (exact (vector-ref v i)) #xff)))
             n))))
    ((ptr src src-off len)              ; source sub-range form
     (let ((h jolt-ffi-declared-call-hook))
       (if h
           (jolt-ffi-invoke-native-op-hook
            h "write-array" (list ptr src src-off len)
            (lambda ()
              (let* ((v (ffi-byte-array-vector "write-array" src))
                     (off (jnum->exact src-off))
                     (n (jnum->exact len)))
                (ffi-check-array-range "write-array" v off n)
                (let ((p (jnum->exact ptr)))
                  (ffi-check-transfer-pointer "write-array" p n)
                  (do ((i 0 (+ i 1))) ((= i n))
                    (foreign-set! 'unsigned-8 p i
                                  (bitwise-and (exact (vector-ref v (+ off i)))
                                               #xff)))
                  n))))
           (let* ((v (ffi-byte-array-vector "write-array" src))
                  (off (jnum->exact src-off))
                  (n (jnum->exact len)))
             (ffi-check-array-range "write-array" v off n)
             (let ((p (jnum->exact ptr)))
               (ffi-check-transfer-pointer "write-array" p n)
               (do ((i 0 (+ i 1))) ((= i n))
                 (foreign-set! 'unsigned-8 p i
                               (bitwise-and (exact (vector-ref v (+ off i)))
                                            #xff)))
               n)))))))
(def-var! "jolt.ffi" "read-array" ffi-read-array)
(def-var! "jolt.ffi" "read-array!" ffi-read-array!)
(def-var! "jolt.ffi" "write-array" ffi-write-array)

;; --- scoped, in-out byte-array pointer loans ---------------------------------
;; A jolt byte-array is currently a SIGNED vector (jolt-array kind 'byte), not a
;; native bytevector — see ffi-byte-array-vector above, and do NOT change that
;; representation here. A pointer loan therefore owns a PRIVATE bytevector
;; snapshot: copying in masks each signed element to a native octet (byte & 0xff),
;; and copying out folds each native octet back to a signed element (na-u8->byte),
;; the same seam read-array!/write-array cross.
;;
;; Ownership/lifetime: the caller owns `arr`; this scope owns `tmp` from
;; allocation through its FIRST exit, and native code holds a borrowed pointer to
;; `tmp` only while the callback runs. Native code must not retain, free, or use
;; that pointer after the callback exits. Copy-back owns arr[start,start+cnt) for
;; the callback's duration, so jolt code must not mutate that range concurrently.
;; Other ranges and other arrays are not aliased by this temporary.
;;
;; Validation precedes allocation, locking, and the callback: kind
;; (ffi-byte-array-vector) and subtraction-safe range (ffi-check-array-range, the
;; same complete-range check read-array!/write-array use) run first. `tmp` is
;; locked only for the callback extent, keeping its first-byte address stable
;; across collection; object->reference-address is valid only while locked.
;; dynamic-wind runs copy-back on normal return, jolt/host exceptions, AND
;; nonlocal exits. Retiring before copy-back makes the address permanently dead
;; on that first exit; the before thunk then rejects a captured continuation
;; before its callback can resume or a second copy-back can run.
;;
;; A thread parameter tracks same-owner-thread nested loans of the SAME array:
;; two independent snapshots would give an order-dependent, lossy copy-back, so
;; that case is rejected. Loans of DISTINCT arrays may nest. Chez thread
;; parameters are INHERITED (a forked thread starts with the creator's value),
;; so the cell carries the owning thread id and an inherited cell is treated as
;; empty for a different thread — the same owner-tag pattern as
;; thread-interrupt-cell in host-static-methods.ss and thread-handle-cell in io.ss.
;; The owner tag is not a cross-thread exclusion mechanism. Callers must prevent
;; overlapping loan lifetimes or other access to the same array across threads.
;; Overlapping private snapshots can copy back in an order that loses updates;
;; even disjoint ranges remain outside the supported contract because this API
;; neither synchronizes access nor enforces array ownership across threads.
;;
;; Each active loan entry tracks the loaned byte-array, the LOCKED temporary
;; bytevector behind the public pointer, the temporary's base address (stable
;; exactly while locked, i.e. for the callback's dynamic extent), and the
;; validated length. Entries are internal to this file: beyond the nesting
;; check their only readers are the scoped byte-array view operations below,
;; so a simulation controller can copy bytes to and from the active temporary
;; WITHOUT any acquire/release or borrow/release lifecycle descriptor.
(define-record-type jolt-ffi-byte-array-loan
  (fields arr tmp base length)
  (nongenerative jolt-ffi-byte-array-loan-v1))
(define ffi-byte-array-loan-cell (make-thread-parameter #f))   ; (owner-id . loans)
(define (ffi-current-byte-array-loans)
  (let ((cell (ffi-byte-array-loan-cell)) (id (get-thread-id)))
    (if (and (pair? cell) (eqv? (car cell) id)) (cdr cell) '())))
(define (ffi-copy-vector-to-bytevector! src start tmp cnt)
  (do ((i 0 (+ i 1))) ((= i cnt))
    (bytevector-u8-set! tmp i
                        (bitwise-and (exact (vector-ref src (+ start i))) #xff))))
(define (ffi-copy-bytevector-to-vector! tmp dest start cnt)
  (do ((i 0 (+ i 1))) ((= i cnt))
    (vector-set! dest (+ start i) (na-u8->byte (bytevector-u8-ref tmp i)))))
;; who names the public entry for error messages; `proc` is a Scheme callback
;; receiving (pointer validated-length) — distinct from the jolt fn the public
;; form wraps via jolt-invoke2. Exposed so the gate can exercise host exceptions
;; and nonlocal exits directly.
(define (ffi-with-scoped-byte-array-pointer who arr off len proc)
  (let* ((v (ffi-byte-array-vector who arr))
         (start (jnum->exact off))
         (cnt (jnum->exact len))
         (owner-id (get-thread-id))
         (active-loans (ffi-current-byte-array-loans)))
    (ffi-check-array-range who v start cnt)
    (when (exists (lambda (loan) (eq? arr (jolt-ffi-byte-array-loan-arr loan)))
                  active-loans)
      (throw-jvm (quote IllegalStateException)
                 (string-append "jolt.ffi/" who
                                ": nested loan of the same byte-array")))
    ;; All validation precedes the temporary allocation and lock.
    (let ((tmp (make-bytevector cnt 0)) (retired? #f) (loan #f))
      (ffi-copy-vector-to-bytevector! v start tmp cnt)
      (lock-object tmp)
      (dynamic-wind
        (lambda ()
          (when retired?
            (error 'jolt.ffi
                   "scoped byte-array pointer continuation cannot be re-entered")))
        (lambda ()
          ;; Capture the address and construct the record only after cleanup is
          ;; installed. If either operation raises, the after thunk still
          ;; retires, copies back, and unlocks the temporary exactly once.
          (set! loan
                (make-jolt-ffi-byte-array-loan
                 arr tmp (object->reference-address tmp) cnt))
          (parameterize ((ffi-byte-array-loan-cell
                          (cons owner-id (cons loan active-loans))))
            (proc (jolt-ffi-byte-array-loan-base loan) cnt)))
        (lambda ()
          ;; Retire before cleanup so a continuation can never resume with the
          ;; old address. The nested wind still unlocks tmp if copy-back exposes
          ;; an internal invariant failure; do not silently turn such corruption
          ;; into a successful callback result.
          (set! retired? #t)
          (dynamic-wind
            void
            (lambda () (ffi-copy-bytevector-to-vector! tmp v start cnt))
            (lambda () (unlock-object tmp))))))))
(define (ffi-with-byte-array-pointer-range arr off len f)
  (ffi-with-scoped-byte-array-pointer
   "with-byte-array-pointer" arr off len
   (lambda (p cnt) (jolt-invoke2 f p cnt))))
(define ffi-with-byte-array-pointer
  (case-lambda
    ((arr f)
     (let ((v (ffi-byte-array-vector "with-byte-array-pointer" arr)))
       (ffi-with-byte-array-pointer-range arr 0 (vector-length v) f)))
    ((arr off len f)
     (ffi-with-byte-array-pointer-range arr off len f))))
(def-var! "jolt.ffi" "with-byte-array-pointer" ffi-with-byte-array-pointer)

;; --- scoped byte-array views over the ACTIVE loan (simulation seam) ----------
;; A controller's safe window into the runtime-owned temporary behind an
;; ACTIVE with-byte-array-pointer loan. The simulation overlay
;; (host/chez/sim/runtime.ss) publishes these as the OPTIONAL
;; jolt.internal.sim/read-active-byte-array-view and
;; jolt.internal.sim/write-active-byte-array-view! vars; ordinary images keep
;; them as unexposed Scheme entries. They are deliberately NOT intercepted
;; native operations: both copy through the tracked locked bytevector, never
;; through a raw foreign address, so they carry no descriptor of any kind —
;; and no acquire/release or borrow/release lifecycle operation exists for
;; them. The loan contract above (validation, same-owner-thread nesting
;; rejection, dynamic-extent locking, continuation retirement, and copy-back)
;; is unchanged and owns the temporary's whole lifetime: a view never extends
;; it, and copy-back on exit remains the only publisher of temporary writes.
;;
;; Matching is owner-thread exact. The lookup walks only the current thread's
;; OWN active loan cell (ffi-current-byte-array-loans collapses an inherited
;; cell to empty), so a stale or post-extent address, another thread's loan,
;; and a never-loaned address all miss and return jolt-nil — for any length
;; and any source. A matched address with an out-of-range span instead fails
;; CLOSED with IndexOutOfBoundsException, in the same subtraction form as
;; ffi-check-array-range, BEFORE any temporary access. The span covers the
;; loan's whole [base, base+length] range including the exact tail, so an
;; empty view at base+length is in-range (mirroring the exact-tail empty
;; loan), while a non-empty span there is out of bounds.
;; read-active-byte-array-view(ptr len) returns a FRESH jolt byte-array of the
;; in-range span, folding native octets to signed bytes (na-u8->byte);
;; write-active-byte-array-view!(ptr src) validates the exact byte-array kind
;; only after the address matches, masks signed bytes to native octets, and
;; returns the exact count copied.
(define (ffi-active-byte-array-loan-for p)
  (let loop ((loans (ffi-current-byte-array-loans)))
    (cond
      ((null? loans) #f)
      ((let ((loan (car loans)))
         (and (>= p (jolt-ffi-byte-array-loan-base loan))
              (<= (- p (jolt-ffi-byte-array-loan-base loan))
                  (jolt-ffi-byte-array-loan-length loan))))
       (car loans))
      (else (loop (cdr loans))))))
(define (ffi-read-active-byte-array-view ptr len)
  (if (not (number? ptr))
      jolt-nil
      (let* ((p (jnum->exact ptr))
             (loan (ffi-active-byte-array-loan-for p)))
        (if (not loan)
            jolt-nil
            (let* ((base (jolt-ffi-byte-array-loan-base loan))
                   (remaining
                    (- (jolt-ffi-byte-array-loan-length loan) (- p base)))
                   (n (and (number? len) (jnum->exact len))))
              ;; A matched address fails closed on ANY out-of-range span —
              ;; a non-numeric or negative length included — before access.
              (when (or (not n) (< n 0) (> n remaining))
                (throw-jvm (quote IndexOutOfBoundsException)
                           (string-append
                            "jolt.internal.sim/read-active-byte-array-view"
                            ": view span out of bounds")))
              (let ((tmp (jolt-ffi-byte-array-loan-tmp loan))
                    (off (- p base))
                    (v (make-vector n 0)))
                (do ((i 0 (+ i 1))) ((= i n))
                  (vector-set! v i (na-u8->byte (bytevector-u8-ref tmp (+ off i)))))
                (make-jolt-array v 'byte)))))))
(define (ffi-write-active-byte-array-view! ptr src)
  (if (not (number? ptr))
      jolt-nil
      (let* ((p (jnum->exact ptr))
             (loan (ffi-active-byte-array-loan-for p)))
        (if (not loan)
            jolt-nil
            ;; The exact byte-array kind is validated only after the address
            ;; matches, so an unmatched pointer is exactly nil for any source.
            (let* ((v (ffi-byte-array-vector "write-active-byte-array-view!" src))
                   (n (vector-length v))
                   (base (jolt-ffi-byte-array-loan-base loan))
                   (remaining
                    (- (jolt-ffi-byte-array-loan-length loan) (- p base))))
              (when (> n remaining)
                (throw-jvm (quote IndexOutOfBoundsException)
                           (string-append
                            "jolt.internal.sim/write-active-byte-array-view!"
                            ": view span out of bounds")))
              (let ((tmp (jolt-ffi-byte-array-loan-tmp loan))
                    (off (- p base)))
                (do ((i 0 (+ i 1))) ((= i n))
                  (bytevector-u8-set! tmp (+ off i)
                                      (bitwise-and (exact (vector-ref v i)) #xff)))
                n))))))

;; --- string / bytevector marshaling ------------------------------------------
;; A C string result already comes back as a jolt string (the `string` foreign
;; type). For a `void*` that points at a NUL-terminated C string, read it here.
(define (ffi-ptr->string ptr)
  (let ((h jolt-ffi-declared-call-hook))
    (if h
        (jolt-ffi-invoke-native-op-hook
         h "ptr->string" (list ptr)
         (lambda ()
           (if (ffi-null? ptr) jolt-nil
               (let ((p (jnum->exact ptr)))
                 (let loop ((i 0) (acc '()))
                   (let ((b (foreign-ref 'unsigned-8 p i)))
                     (if (= b 0)
                         (utf8->string (u8-list->bytevector (reverse acc)))
                         (loop (+ i 1) (cons b acc)))))))))
        (if (ffi-null? ptr) jolt-nil
            (let ((p (jnum->exact ptr)))
              (let loop ((i 0) (acc '()))
                (let ((b (foreign-ref 'unsigned-8 p i)))
                  (if (= b 0)
                      (utf8->string (u8-list->bytevector (reverse acc)))
                      (loop (+ i 1) (cons b acc))))))))))
;; Copy a jolt string's UTF-8 bytes into a freshly alloc'd NUL-terminated buffer;
;; the caller frees it. Returns the pointer.
(define (ffi-string->ptr s)
  (let ((h jolt-ffi-declared-call-hook))
    (if h
        (jolt-ffi-invoke-native-op-hook
         h "string->ptr" (list s)
         (lambda ()
           (let* ((bv (string->utf8 (jolt-str-render-one s)))
                  (n (bytevector-length bv))
                  (p (foreign-alloc (+ n 1))))
             ;; free on a mid-copy throw — the caller only ever sees a whole buffer
             (guard (e (#t (guard (_ (#t #f)) (foreign-free p)) (raise e)))
               (do ((i 0 (+ i 1))) ((= i n))
                 (foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)))
               (foreign-set! 'unsigned-8 p n 0)
               p))))
        (let* ((bv (string->utf8 (jolt-str-render-one s)))
               (n (bytevector-length bv))
               (p (foreign-alloc (+ n 1))))
          ;; free on a mid-copy throw — the caller only ever sees a whole buffer
          (guard (e (#t (guard (_ (#t #f)) (foreign-free p)) (raise e)))
            (do ((i 0 (+ i 1))) ((= i n))
              (foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)))
            (foreign-set! 'unsigned-8 p n 0)
            p)))))

;; --- callbacks: receive calls FROM C ----------------------------------------
;; jolt.ffi/foreign-callable lowers to (jolt-ffi-register-callable! (foreign-callable …)).
;; A foreign-callable code object must be LOCKED (so the collector neither moves
;; nor reclaims it) and RETAINED while C may still call through its entry point.
;; Register it keyed by that entry-point address (a jolt pointer integer) — which
;; is what the caller hands to C; free-callable unlocks and drops it. A callback
;; left registered lives for the process (the GTK-signal-handler common case).
(define ffi-callable-table (make-eqv-hashtable))   ; entry-point addr -> code object
(define (jolt-ffi-register-callable! co)
  (lock-object co)
  (let ((addr (foreign-callable-entry-point co)))
    (hashtable-set! ffi-callable-table addr co)
    addr))
(define (ffi-free-callable addr)
  (let* ((a (jnum->exact addr)) (co (hashtable-ref ffi-callable-table a #f)))
    (when co (unlock-object co) (hashtable-delete! ffi-callable-table a))
    jolt-nil))

;; --- library exports: name -> entry-point address ---------------------------
;; `jolt build --library` publishes C-callable entry points under names so an
;; embedder resolves them via the stub's jolt_lookup(name). export! wraps a jolt
;; fn as a foreign-callable (locked + retained as above) and records name->addr
;; here. The built library's scheme-start handler wraps THIS lookup as a single
;; C-callable and hands its address to the stub (jolt_set_lookup_addr), so
;; jolt_lookup(name) reads this table. export! only touches Scheme state, so it
;; also runs harmlessly during the build's app load (the table is discarded).
;; NOTE: keyed with equal? (make-hashtable) not eq? — keys are strings, and the
;; app's "add" and the lookup's C-string-derived "add" are different objects, so
;; eq?-hashtable would always miss. (ffi-callable-table above is eq?-keyed but
;; keyed by integer addresses, where eq? is correct.)
(define ffi-export-table (make-hashtable string-hash equal?))  ; name(string) -> addr(integer)
(define (jolt-ffi-register-export! name addr)
  (hashtable-set! ffi-export-table name addr) addr)
;; lookup for the C stub: name (a Scheme string) -> addr, or 0 if unknown.
(define (jolt-ffi-lookup-export name)
  (let ((a (hashtable-ref ffi-export-table name #f))) (if a a 0)))
;; export! is a MACRO in stdlib/jolt/ffi.clj (it needs compile-time-typed
;; argtypes to build the foreign-callable, like foreign-callable). It expands to
;; (jolt.ffi/register-export name (jolt.ffi/__ccallable f [argtypes] rettype)),
;; so the callable is built with literal types and register-export records
;; name -> its entry-point address here.

;; --- native libraries for a standalone binary -------------------------------
;; `jolt build` bakes a project's deps.edn :jolt/native declarations into the
;; launcher, which loads them at startup (load-shared-object isn't part of the
;; saved heap, so it must run in the built process, not at heap build). process?
;; loads the running binary's own symbols (libc sockets); otherwise try each
;; platform candidate in turn and fail unless the spec is optional.
(define (jolt-build-load-native cands optional? process?)
  (if process?
      (begin (load-shared-object #f) #t)
      (let loop ((cs cands))
        (cond
          ((null? cs)
           (unless optional?
             (error 'jolt-build "required native library not found" cands))
           #f)
          ((guard (e (#t #f)) (load-shared-object (car cs)) #t) #t)
          (else (loop (cdr cs)))))))

;; --- declared foreign-call interception (internal simulation seam) ----------
;; The compiler reads jolt-ffi-declared-call-hook once at the start of every
;; generated defcfn invocation.  #f keeps the ordinary lazily cached native
;; call; a hook receives (descriptor proceed), before symbol resolution.  The
;; raw jolt.ffi operations above read the same cell once per call and ride the
;; same machinery with native-op descriptors — see the native-operation
;; subsection below.  This is intentionally host-internal for now: no jolt.ffi
;; var exposes it.
;;
;; Installations are process-global and form a strict token-cleared stack.  An
;; out-of-order or repeated clear fails closed instead of disabling a newer
;; controller.  Install/clear linearize future hook selection under the mutex,
;; but clear is deliberately not a quiescence barrier: a call that snapshotted
;; the prior hook may begin invoking it after clear returns.  A controller must
;; prevent new calls and drain its in-flight invocations before restoring its
;; token.  Invocation ownership is separate and thread-tagged because Chez thread
;; parameters are inherited: a child must not inherit its parent's "inside hook"
;; state, while nested FFI on the same owner thread must fail.
(define-record-type jolt-ffi-declared-call-hook-installation
  (fields hook previous)
  (nongenerative jolt-ffi-declared-call-hook-installation-v1))
(define-record-type jolt-ffi-declared-call-activation
  (fields owner-id)
  (nongenerative jolt-ffi-declared-call-activation-v1))
(define jolt-ffi-declared-call-hook #f) ; separate hot-path cell
(define jolt-ffi-declared-call-hook-top #f)
(define jolt-ffi-declared-call-hook-mu (make-mutex))
(define jolt-ffi-declared-call-activation-cell (make-thread-parameter #f))

(define (jolt-ffi-install-declared-call-hook! hook)
  (unless hook
    (error 'jolt-ffi-install-declared-call-hook! "hook must be non-false"))
  (with-mutex jolt-ffi-declared-call-hook-mu
    (let ((installation
           (make-jolt-ffi-declared-call-hook-installation
            hook jolt-ffi-declared-call-hook-top)))
      (set! jolt-ffi-declared-call-hook-top installation)
      (set! jolt-ffi-declared-call-hook hook)
      installation)))

(define (jolt-ffi-clear-declared-call-hook! installation)
  (with-mutex jolt-ffi-declared-call-hook-mu
    (unless (eq? installation jolt-ffi-declared-call-hook-top)
      (error 'jolt-ffi-clear-declared-call-hook!
             "declared-call hooks must be cleared by their current token"))
    (let ((previous
           (jolt-ffi-declared-call-hook-installation-previous installation)))
      (set! jolt-ffi-declared-call-hook-top previous)
      (set! jolt-ffi-declared-call-hook
            (and previous
                 (jolt-ffi-declared-call-hook-installation-hook previous)))))
  jolt-nil)

(define (jolt-ffi-current-declared-call-activation)
  (let ((activation (jolt-ffi-declared-call-activation-cell))
        (owner-id (get-thread-id)))
    (and activation
         (eqv? owner-id
               (jolt-ffi-declared-call-activation-owner-id activation))
         activation)))

;; The descriptor is an ordinary, inspectable alist.  Its metadata is copied on
;; every intercepted call, so mutation by one controller cannot corrupt compiler
;; literals or a later descriptor.  Arguments remain the exact live Jolt values:
;; a substitute may need to model writes through an array or pointer.
(define (jolt-ffi-make-declared-call-descriptor
         csym argtypes rettype blocking capture-native-error args)
  (list (cons 'kind 'foreign-call)
        (cons 'csym (string-copy csym))
        (cons 'argtypes (map string-copy argtypes))
        (cons 'rettype (string-copy rettype))
        (cons 'blocking blocking)
        (cons 'capture-native-error capture-native-error)
        (cons 'args args)))

;; Invoke one hook under a continuation-safe lifetime.  `proceed` is the only
;; bypass: it calls the exact generated native path, including lazy caching and
;; native-error capture, but only synchronously, on this owner thread, and at
;; most once.  Both the hook extent and proceed use dynamic-wind retirement so a
;; captured continuation fails before either body can resume after first exit.
(define (jolt-ffi-invoke-declared-call-hook hook descriptor real-call)
  (when (jolt-ffi-current-declared-call-activation)
    (error 'jolt-ffi-invoke-declared-call-hook
           "nested FFI from a declared-call hook requires its exact proceed"))
  (let* ((owner-id (get-thread-id))
         (activation (make-jolt-ffi-declared-call-activation owner-id))
         (hook-retired? #f)
         (proceed-used? #f)
         (proceed-retired? #f))
    (define (proceed)
      (unless (and (not hook-retired?)
                   (eq? activation
                        (jolt-ffi-current-declared-call-activation)))
        (error 'jolt-ffi-declared-call-proceed
               "proceed is valid only during its declared-call hook invocation"))
      (when proceed-used?
        (error 'jolt-ffi-declared-call-proceed
               "proceed may be called at most once"))
      (set! proceed-used? #t)
      (dynamic-wind
        (lambda ()
          (when proceed-retired?
            (error 'jolt-ffi-declared-call-proceed
                   "proceed continuation cannot be re-entered")))
        ;; `proceed` authorizes this exact real call, not a blanket bypass.  A
        ;; synchronous native callback into Jolt therefore starts with no active
        ;; hook invocation and may make its own freshly intercepted declared
        ;; FFI call.  On return (or any nonlocal exit), parameterize restores the
        ;; outer activation before the proceed extent retires.
        (lambda ()
          (parameterize ((jolt-ffi-declared-call-activation-cell #f))
            (real-call)))
        (lambda () (set! proceed-retired? #t))))
    (dynamic-wind
      (lambda ()
        (when hook-retired?
          (error 'jolt-ffi-invoke-declared-call-hook
                 "hook continuation cannot be re-entered")))
      (lambda ()
        (parameterize ((jolt-ffi-declared-call-activation-cell activation))
          (jolt-invoke2 hook descriptor proceed)))
      (lambda () (set! hook-retired? #t)))))

;; --- raw native-operation interception (the same seam) -----------------------
;; The one hook also covers the raw operations this file exposes under
;; jolt.ffi: load-library, loaded?, alloc, free, read, write, sizeof, null?,
;; read-bytes, write-bytes, read-array, read-array!, both write-array arities,
;; ptr->string, and string->ptr.  Each operation reads
;; jolt-ffi-declared-call-hook once per call; #f runs the original body
;; directly — one variable read and one branch, with no descriptor or proceed
;; allocation.  An installed hook receives a native-op descriptor plus the same
;; scoped, same-thread, at-most-once proceed as a declared call, so both kinds
;; share the token-cleared installation stack, the owner-tagged activation
;; cell, and every lifetime rejection above.  Substitution returns the hook's
;; value unwrapped; proceed runs the exact original body, so its results,
;; jolt-nil returns, validation errors (byte-array kind, subtraction-safe
;; range, null-for-nonzero-length pointer), and exceptions are the operation's
;; own, and a synchronous callback reached through it starts a fresh
;; interception.
;;
;; The descriptor is the same plain-alist shape with kind `native-op`, a copied
;; `op` name string, and `args` — the exact
;; live call arguments in call order: the optional read offset when supplied,
;; the destination byte-array for read-array! (a controller may model writes
;; through it), both or all four write-array arguments (the count tells the
;; arities apart), and zero or one load-library arguments.  Argument VALUES are
;; the exact live objects, but the descriptor list spine is a per-call snapshot
;; (lexical rest and offset lists are spine-copied), so a controller mutating
;; descriptor structure cannot redirect the operation its proceed runs — that
;; proceed always applies its untouched lexical arguments.
;;
;; Deliberate exclusions:
;;  * jolt.ffi/null is a constant value var (0), not an operation — there is no
;;    call to intercept.  Models use and answer 0 for null pointers; null? IS
;;    intercepted, so a controller owns the predicate's answers.
;;  * with-byte-array-pointer keeps its scoped loan lifecycle un-reimplemented:
;;    it performs no foreign-memory operation of its own (its temporary is a
;;    locked Scheme bytevector, not foreign-alloc'd memory), and the jolt.ffi
;;    operations its callback makes on the loaned pointer are intercepted
;;    normally.  The scoped byte-array view helpers share that exclusion: they
;;    copy between a controller and the tracked locked temporary directly, so
;;    they carry no descriptor and the simulation overlay publishes them only
;;    as optional jolt.internal.sim vars, never as native operations.
;;  * free-callable / register-export (and the internal callable/export
;;    tables) are jolt-side registries, not raw native operations.
;; Declared foreign calls remain kind `foreign-call`; a controller installs
;; exactly one hook and dispatches on descriptor kind.
(define (jolt-ffi-make-native-op-descriptor op args)
  (list (cons 'kind 'native-op)
        (cons 'op (string-copy op))
        (cons 'args args)))

(define (jolt-ffi-invoke-native-op-hook hook op args real-op)
  (jolt-ffi-invoke-declared-call-hook
   hook (jolt-ffi-make-native-op-descriptor op args) real-op))

;; --- expose under jolt.ffi ---------------------------------------------------
(def-var! "jolt.ffi" "free-callable" ffi-free-callable)
(def-var! "jolt.ffi" "register-export" jolt-ffi-register-export!)
(def-var! "jolt.ffi" "load-library" ffi-load-library)
;; loaded? keeps its Boolean public contract even under a hook: a substituted
;; jolt nil or #f means "not loaded" (#f), anything else #t.  Booleanize with
;; jolt-truthy? — Scheme `if` would read a substituted jolt-nil as true.
(def-var! "jolt.ffi" "loaded?" (lambda (n) (if (jolt-truthy? (ffi-loaded? n)) #t #f)))
(def-var! "jolt.ffi" "alloc" ffi-alloc)
(def-var! "jolt.ffi" "free" ffi-free)
(def-var! "jolt.ffi" "read" ffi-read)
(def-var! "jolt.ffi" "write" ffi-write)
(def-var! "jolt.ffi" "sizeof" ffi-sizeof)
;; null? intercepts at the var rather than inside ffi-null?, so ptr->string's
;; internal null check above never surfaces to a controller as a separate op.
(def-var! "jolt.ffi" "null?"
  (lambda (p)
    (let ((h jolt-ffi-declared-call-hook))
      (if h
          (jolt-ffi-invoke-native-op-hook
           h "null?" (list p) (lambda () (if (ffi-null? p) #t #f)))
          (if (ffi-null? p) #t #f)))))
(def-var! "jolt.ffi" "null" ffi-null)
(def-var! "jolt.ffi" "ptr->string" ffi-ptr->string)
(def-var! "jolt.ffi" "string->ptr" ffi-string->ptr)
