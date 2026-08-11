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
(define (ffi-load-library . args)
  (if (or (null? args) (jolt-nil? (car args)))
      (begin (sa-load-shared-object #f) jolt-nil)
      (begin (sa-load-shared-object (jolt-str-render-one (car args))) jolt-nil)))

(define (ffi-loaded? name)
  (guard (e (#t #f)) (sa-load-shared-object (jolt-str-render-one name)) #t))

;; --- foreign type keywords ---------------------------------------------------
;; The keyword type names jolt.ffi accepts (in foreign-fn signatures and the
;; memory accessors) map to Chez foreign types. Kept in one place so the backend
;; (compile-time, for foreign-procedure) and these accessors (runtime, for
;; foreign-ref/set!) agree — see ffi-types in jolt-core/jolt/backend_scheme.clj.
;; Exact scalar widths use native byte order. Signed and unsigned names at one
;; width expose the same stored bits; wire byte order remains an explicit codec
;; or htons/ntohs concern.
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
(define (ffi-alloc nbytes) (sa-foreign-alloc (jnum->exact nbytes)))
(define (ffi-free ptr) (sa-foreign-free (jnum->exact ptr)) jolt-nil)
(define (ffi-read ptr ty . off)
  (sa-foreign-ref (ffi-type->chez ty) (jnum->exact ptr) (if (pair? off) (jnum->exact (car off)) 0)))
(define (ffi-write ptr ty off val)
  (sa-foreign-set! (ffi-type->chez ty) (jnum->exact ptr) (jnum->exact off) val) jolt-nil)
;; sizeof a foreign type (for laying out structs / arrays).
(define (ffi-sizeof ty) (sa-foreign-sizeof (ffi-type->chez ty)))
(define (ffi-null? ptr) (and (number? ptr) (= (jnum->exact ptr) 0)))
(define ffi-null 0)

;; --- buffer I/O (known length) ----------------------------------------------
;; read n bytes at ptr as a string (UTF-8, falling back to latin1 for invalid
;; sequences) — for a socket recv buffer and similar fixed-length reads.
(define (ffi-read-bytes ptr n)
  (let* ((n (jnum->exact n)) (p (jnum->exact ptr)) (bv (make-bytevector n)))
    (do ((i 0 (+ i 1))) ((= i n)) (bytevector-u8-set! bv i (sa-foreign-ref 'unsigned-8 p i)))
    (guard (e (#t (list->string (map integer->char (bytevector->u8-list bv))))) (utf8->string bv))))
;; write a string's UTF-8 bytes into ptr (no NUL terminator); return the count.
(define (ffi-write-bytes ptr s)
  (let* ((bv (string->utf8 (jolt-str-render-one s))) (n (bytevector-length bv)) (p (jnum->exact ptr)))
    (do ((i 0 (+ i 1))) ((= i n)) (sa-foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)))
    n))
(def-var! "jolt.ffi" "read-bytes" ffi-read-bytes)
(def-var! "jolt.ffi" "write-bytes" ffi-write-bytes)

;; --- byte-array buffer I/O (binary-faithful) --------------------------------
;; Move raw bytes between a jolt byte-array (jolt-array kind 'byte) and foreign
;; memory, byte-exact (no UTF-8 / latin1 decode) — for socket recv/send and the
;; zlib / OpenSSL buffers an HTTP client passes through. read-array returns a
;; fresh byte-array of n bytes; write-array copies a byte-array's bytes into ptr
;; and returns the count. Foreign memory is unsigned octets and a byte-array element
;; is a signed byte, so the two directions fold and mask across that seam.
(define (ffi-byte-array-vector who arr)
  (if (and (jolt-array? arr) (eq? (jolt-array-kind arr) 'byte))
      (jolt-array-vec arr)
      (throw-jvm (quote IllegalArgumentException)
                 (string-append "jolt.ffi/" who ": expected byte-array"))))
(define (ffi-check-array-range who v off len)
  (let ((n (vector-length v)))
    (when (or (< off 0) (< len 0) (> off n) (> len (- n off)))
      (throw-jvm (quote IndexOutOfBoundsException)
                 (string-append "jolt.ffi/" who
                                ": byte-array range out of bounds")))))
(define (ffi-read-array ptr n)
  (let* ((n (jnum->exact n)) (p (jnum->exact ptr)) (v (make-vector n 0)))
    (do ((i 0 (+ i 1))) ((= i n)) (vector-set! v i (na-u8->byte (sa-foreign-ref 'unsigned-8 p i))))
    (make-jolt-array v 'byte)))
(define (ffi-write-array ptr arr)
  (let* ((v (jolt-array-vec arr)) (n (vector-length v)) (p (jnum->exact ptr)))
    (do ((i 0 (+ i 1))) ((= i n)) (sa-foreign-set! 'unsigned-8 p i (bitwise-and (exact (vector-ref v i)) #xff)))
    n))
(def-var! "jolt.ffi" "read-array" ffi-read-array)
(def-var! "jolt.ffi" "write-array" ffi-write-array)

;; --- scoped, in-out byte-array pointer loans --------------------------------
;; A jolt byte-array is a signed Scheme vector, not native memory. A pointer
;; loan therefore owns a private foreign block. It copies the selected signed
;; bytes in as octets, calls the synchronous callback with [pointer length],
;; then copies native changes back and frees the block on normal, exceptional,
;; and nonlocal exit. Native code must not retain or free the borrowed pointer.
;;
;; Foreign allocation rather than a pinned Scheme bytevector keeps this seam
;; inside the portable sa-foreign-* contract. The allocation is at least one
;; byte so an empty loan still receives a stable non-null address; its length is
;; zero and neither copy loop accesses it.
;;
;; Same-array nesting on one owner thread is rejected because independent
;; snapshots have order-dependent copy-back. Chez thread parameters are
;; inherited, so the cell carries its owner thread id and appears empty in a
;; child. This is not cross-thread exclusion: callers must prevent overlapping
;; loans or other access to the same array across threads.
(define ffi-byte-array-loan-cell (make-thread-parameter #f)) ; (owner-id . arrays)
(define (ffi-current-byte-array-loans)
  (let ((cell (ffi-byte-array-loan-cell)) (id (get-thread-id)))
    (if (and (pair? cell) (eqv? (car cell) id)) (cdr cell) '())))
(define (ffi-copy-vector-to-foreign! src start ptr cnt)
  (do ((i 0 (+ i 1))) ((= i cnt))
    (sa-foreign-set! 'unsigned-8 ptr i
                     (bitwise-and (exact (vector-ref src (+ start i))) #xff))))
(define (ffi-copy-foreign-to-vector! ptr dest start cnt)
  (do ((i 0 (+ i 1))) ((= i cnt))
    (vector-set! dest (+ start i)
                 (na-u8->byte (sa-foreign-ref 'unsigned-8 ptr i)))))
;; Exposed to the host gate so host exceptions and nonlocal exits can exercise
;; the cleanup wind directly. PROC receives (pointer validated-length).
(define (ffi-with-scoped-byte-array-pointer who arr off len proc)
  (let* ((v (ffi-byte-array-vector who arr))
         (start (jnum->exact off))
         (cnt (jnum->exact len))
         (owner-id (get-thread-id))
         (active-loans (ffi-current-byte-array-loans)))
    (ffi-check-array-range who v start cnt)
    (when (memq arr active-loans)
      (throw-jvm (quote IllegalStateException)
                 (string-append "jolt.ffi/" who
                                ": nested loan of the same byte-array")))
    ;; All validation precedes allocation and callback admission.
    (let ((ptr (sa-foreign-alloc (max 1 cnt))) (retired? #f))
      ;; If staging fails before the cleanup wind exists, release the native
      ;; block without attempting copy-back or admitting the callback.
      (guard (e (#t (sa-foreign-free ptr) (raise e)))
        (ffi-copy-vector-to-foreign! v start ptr cnt))
      (dynamic-wind
        (lambda ()
          (when retired?
            (error 'jolt.ffi
                   "scoped byte-array pointer continuation cannot be re-entered")))
        (lambda ()
          (parameterize ((ffi-byte-array-loan-cell
                          (cons owner-id (cons arr active-loans))))
            (proc ptr cnt)))
        (lambda ()
          ;; Retire before cleanup so a captured continuation cannot resume
          ;; with a freed address or trigger a second copy-back.
          (set! retired? #t)
          (dynamic-wind
            void
            (lambda () (ffi-copy-foreign-to-vector! ptr v start cnt))
            (lambda () (sa-foreign-free ptr))))))))
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

;; --- string / bytevector marshaling ------------------------------------------
;; A C string result already comes back as a jolt string (the `string` foreign
;; type). For a `void*` that points at a NUL-terminated C string, read it here.
(define (ffi-ptr->string ptr)
  (if (ffi-null? ptr) jolt-nil
      (let ((p (jnum->exact ptr)))
        (let loop ((i 0) (acc '()))
          (let ((b (sa-foreign-ref 'unsigned-8 p i)))
            (if (= b 0) (utf8->string (u8-list->bytevector (reverse acc)))
                (loop (+ i 1) (cons b acc))))))))
;; Copy a jolt string's UTF-8 bytes into a freshly alloc'd NUL-terminated buffer;
;; the caller frees it. Returns the pointer.
(define (ffi-string->ptr s)
  (let* ((bv (string->utf8 (jolt-str-render-one s))) (n (bytevector-length bv))
         (p (sa-foreign-alloc (+ n 1))))
    ;; free on a mid-copy throw — the caller only ever sees a whole buffer
    (guard (e (#t (guard (_ (#t #f)) (sa-foreign-free p)) (raise e)))
      (do ((i 0 (+ i 1))) ((= i n)) (sa-foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)))
      (sa-foreign-set! 'unsigned-8 p n 0)
      p)))

;; --- callbacks: receive calls FROM C ----------------------------------------
;; jolt.ffi/foreign-callable lowers to (jolt-ffi-register-callable! (foreign-callable …)).
;; A foreign-callable code object must be LOCKED (so the collector neither moves
;; nor reclaims it) and RETAINED while C may still call through its entry point.
;; Register it keyed by that entry-point address (a jolt pointer integer) — which
;; is what the caller hands to C; free-callable unlocks and drops it. A callback
;; left registered lives for the process (the GTK-signal-handler common case).
;; Both tables are written at RUN time — __ccallable mints a callback and
;; ffi-export registers a name — from whatever thread does it, so every mutation
;; takes this mutex. Single-key reads stay unlocked.
(define ffi-tbl-mu (make-mutex))
(define ffi-callable-table (make-eqv-hashtable))   ; entry-point addr -> code object
(define (jolt-ffi-register-callable! co)
  (sa-lock-object co)
  (let ((addr (sa-foreign-callable-entry-point co)))
    (jolt-with-mutex ffi-tbl-mu (hashtable-set! ffi-callable-table addr co))
    addr))
(define (ffi-free-callable addr)
  (let* ((a (jnum->exact addr))
         (co (jolt-with-mutex ffi-tbl-mu
               ;; take-and-remove as one step, so two frees of the same address
               ;; cannot both unlock the object
               (let ((c (hashtable-ref ffi-callable-table a #f)))
                 (when c (hashtable-delete! ffi-callable-table a))
                 c))))
    (when co (sa-unlock-object co))
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
  (jolt-with-mutex ffi-tbl-mu (hashtable-set! ffi-export-table name addr)) addr)
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
      (begin (sa-load-shared-object #f) #t)
      (let loop ((cs cands))
        (cond
          ((null? cs)
           (unless optional?
             (error 'jolt-build "required native library not found" cands))
           #f)
          ((guard (e (#t #f)) (sa-load-shared-object (car cs)) #t) #t)
          (else (loop (cdr cs)))))))

;; --- compatibility read of the current thread's native error slot -----------
;; New bindings should prefer {:capture-native-error true}: that pairs the
;; result and error inside Chez's foreign-call return path, so no intervening
;; native work can clobber the slot. errno remains for existing scalar bindings
;; and performs exactly one native accessor call followed by a direct memory
;; read on POSIX, or one WSAGetLastError call on Windows. Call it immediately.
(define ffi-errno-location
  (jolt-foreign-proc-safe "__errno_location" '() 'void*))
(define ffi-error-location
  (jolt-foreign-proc-safe "__error" '() 'void*))
(define ffi-wsa-get-last-error
  (jolt-foreign-proc-safe "WSAGetLastError" '() 'int))

(define (ffi-native-error)
  (case (sa-os-family)
    ((linux)
     (if ffi-errno-location
         (sa-foreign-ref 'int (ffi-errno-location) 0)
         (error 'jolt.ffi/errno "__errno_location is unavailable")))
    ((macos)
     (if ffi-error-location
         (sa-foreign-ref 'int (ffi-error-location) 0)
         (error 'jolt.ffi/errno "__error is unavailable")))
    ((windows)
     (if ffi-wsa-get-last-error
         (ffi-wsa-get-last-error)
         (error 'jolt.ffi/errno "WSAGetLastError is unavailable")))
    (else
     (error 'jolt.ffi/errno "unsupported target OS" (sa-os-family)))))

(define (ffi-native-error-source)
  (case (sa-os-family)
    ((linux) (keyword #f "errno-location"))
    ((macos) (keyword #f "error"))
    ((windows) (keyword #f "wsa-get-last-error"))
    (else (keyword #f "unsupported"))))

;; --- expose under jolt.ffi ---------------------------------------------------
(def-var! "jolt.ffi" "free-callable" ffi-free-callable)
(def-var! "jolt.ffi" "register-export" jolt-ffi-register-export!)
(def-var! "jolt.ffi" "load-library" ffi-load-library)
(def-var! "jolt.ffi" "loaded?" (lambda (n) (if (ffi-loaded? n) #t #f)))
(def-var! "jolt.ffi" "alloc" ffi-alloc)
(def-var! "jolt.ffi" "free" ffi-free)
(def-var! "jolt.ffi" "read" ffi-read)
(def-var! "jolt.ffi" "write" ffi-write)
(def-var! "jolt.ffi" "sizeof" ffi-sizeof)
(def-var! "jolt.ffi" "null?" (lambda (p) (if (ffi-null? p) #t #f)))
(def-var! "jolt.ffi" "null" ffi-null)
(def-var! "jolt.ffi" "ptr->string" ffi-ptr->string)
(def-var! "jolt.ffi" "string->ptr" ffi-string->ptr)
(def-var! "jolt.ffi" "errno" ffi-native-error)
(def-var! "jolt.ffi" "errno-source" ffi-native-error-source)
