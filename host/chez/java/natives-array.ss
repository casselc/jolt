;; natives-array.ss — Java-style mutable arrays for the Chez host.
;;
;; A jolt-array wraps a Chez mutable backing + a `kind` tag. Byte arrays use
;; bytevectors, float/double arrays use flvectors, and other kinds use vectors. The array
;; CONSTRUCTORS are native (they build the backing); the overlay's aget/aset/alength
;; are pure over count / nth / jolt.host/ref-put!, so we extend those dispatchers
;; to see a jolt-array. Loaded after host-table.ss (ref-put!),
;; transients.ss, seq.ss (the dispatchers it chains).

(define-record-type jolt-array (fields (mutable vec) kind) (nongenerative jolt-array-v1))

;; JVM array class name per element kind ((class (int-array 3)) -> "[I", like the
;; JVM's Class.getName for arrays). Object arrays use the descriptor form.
(define (na-array-class-name arr)
  (case (jolt-array-kind arr)
    ((int) "[I") ((long) "[J") ((short) "[S") ((double) "[D")
    ((float) "[F") ((boolean) "[Z") ((byte) "[B") ((char) "[C")
    (else "[Ljava.lang.Object;")))

(define (na-idx i) (if (and (number? i) (not (exact? i))) (exact (floor i)) i))

;; A double/float jolt-array is backed by a Chez FLVECTOR (unboxed flonums), and
;; a byte-array by a BYTEVECTOR (unboxed octets). Every other kind keeps a boxed
;; Chez vector. These helpers let the collection
;; dispatchers (count/seq/nth/ref-put!/aset/aclone) and java.util.Arrays work over
;; either backing. Chez has flvector? / make-flvector / flvector-ref / -set! / -length.
(define (na-fl-kind? k) (or (eq? k 'double) (eq? k 'float)))
(define (ja-len v)
  (cond ((flvector? v) (flvector-length v))
        ((bytevector? v) (bytevector-length v))
        (else (vector-length v))))
;; An out-of-range index on the generic aget/aset path throws the typed JVM
;; exception with the JVM message. The proven ^doubles fast path (jolt-flaget/
;; jolt-flaset below) skips this pre-check — it relies on flvector-ref's own
;; range check and its condition classifies at inspection time instead.
(define (na-oob-throw i n)
  (jolt-throw (jolt-host-throwable "java.lang.ArrayIndexOutOfBoundsException"
                                   (format "Index ~a out of bounds for length ~a" i n))))
(define (ja-check v i)
  (unless (and (fixnum? i) (fx>=? i 0) (fx<? i (ja-len v)))
    (if (jolt-nil? i)
        (throw-jvm 'NullPointerException "array index is nil")
        (na-oob-throw i (ja-len v)))))
(define (ja-ref v i)
  (ja-check v i)
  (cond ((flvector? v) (flvector-ref v i))
        ((bytevector? v) (bytevector-u8-ref v i))
        (else (vector-ref v i))))
(define (ja-set! v i x)
  (ja-check v i)
  (cond
    ((flvector? v) (flvector-set! v i (if (flonum? x) x (exact->inexact x))))
    ((bytevector? v) (bytevector-u8-set! v i (bitwise-and (exact (floor x)) #xff)))
    (else (vector-set! v i x))))
(define (ja->list v)
  (cond
    ((flvector? v)
     (let loop ((i (- (flvector-length v) 1)) (acc '()))
       (if (< i 0) acc (loop (- i 1) (cons (flvector-ref v i) acc)))))
    ((bytevector? v) (bytevector->u8-list v))
    (else (vector->list v))))
(define (ja-copy v)
  (cond
    ((flvector? v)
     (let* ((n (flvector-length v)) (r (make-flvector n 0.0)))
       (do ((i 0 (+ i 1))) ((= i n) r) (flvector-set! r i (flvector-ref v i)))))
    ((bytevector? v) (bytevector-copy v))
    (else (vector-copy v))))
(define (na-make-backing n kind init)
  (cond
    ((na-fl-kind? kind)
     (make-flvector (exact n) (if (flonum? init) init (exact->inexact init))))
    ((eq? kind 'byte)
     (make-bytevector (exact n) (bitwise-and (exact (floor init)) #xff)))
    (else (make-vector (exact n) init))))
(define (na-list->backing lst kind)
  (cond
    ((na-fl-kind? kind)
     (let* ((n (length lst)) (fv (make-flvector n 0.0)))
       (let loop ((i 0) (l lst))
         (if (null? l) fv (begin (flvector-set! fv i (exact->inexact (car l))) (loop (+ i 1) (cdr l)))))))
    ((eq? kind 'byte)
     (u8-list->bytevector (map (lambda (x) (bitwise-and (exact (floor x)) #xff)) lst)))
    (else (list->vector lst))))

(define (na-from-seq x kind) (make-jolt-array (na-list->backing (seq->list (jolt-seq x)) kind) kind))
;; (T-array size) | (T-array size init) | (T-array seq)
(define (na-num-array a rest init kind)
  (if (number? a)
      (make-jolt-array (na-make-backing (na-idx a) kind (if (pair? rest) (car rest) init)) kind)
      (na-from-seq a kind)))

;; numeric tower: array element defaults / masked bytes / count are
;; EXACT integers (= JVM byte/short/int), matching exact integer literals.
(define (na-byte-of v) (bitwise-and (exact (floor v)) #xff))

;; --- constructors -----------------------------------------------------------
(define (na-object-array a . rest)  (na-num-array a rest jolt-nil 'object))
;; integer kinds default to exact 0 (JVM int/long/short 0 -> "0", not "0.0").
(define (na-int-array a . rest)     (na-num-array a rest 0 'int))
(define (na-long-array a . rest)    (na-num-array a rest 0 'long))
(define (na-short-array a . rest)   (na-num-array a rest 0 'short))
(define (na-double-array a . rest)  (na-num-array a rest 0.0 'double))
(define (na-float-array a . rest)   (na-num-array a rest 0.0 'float))
(define (na-boolean-array a . rest) (na-num-array a rest #f 'boolean))
;; char-array is a real 'char array (instance? "[C"), seqing as chars via the
;; dispatchers below — io/reader (extended here) and str/slurp consume the seq.
(define (na-char-array a . rest)
  (cond
    ((string? a) (make-jolt-array (list->vector (string->list a)) 'char))
    ((number? a) (make-jolt-array (make-vector (exact (na-idx a)) #\nul) 'char))
    (else (make-jolt-array
           (list->vector (map (lambda (c) (if (char? c) c (integer->char (exact (truncate c)))))
                              (seq->list (jolt-seq a)))) 'char))))
;; (byte-array n [init]) | (byte-array coll). Also coerces the host's OTHER byte
;; carrier — a Chez bytevector (what String/.getBytes produce) — and a string's
;; UTF-8 bytes, so bytevector and byte-array interconvert across interop seams.
(define (na-byte-array a . rest)
  (cond
    ((number? a) (make-jolt-array
                   (make-bytevector (exact (na-idx a)) (na-byte-of (if (pair? rest) (car rest) 0)))
                   'byte))
    ((bytevector? a) (make-jolt-array (bytevector-copy a) 'byte))
    ((string? a) (make-jolt-array (string->utf8 a) 'byte))
    (else (make-jolt-array
           (u8-list->bytevector (map na-byte-of (seq->list (jolt-seq a))))
           'byte))))
;; jolt byte-array -> Chez bytevector (for String decode / utf8->string).
;; Return a snapshot as before; native bulk transfer paths use the backing
;; bytevector directly and avoid this compatibility copy.
(define (na-bytearray->bv arr)
  (bytevector-copy (jolt-array-vec arr)))
(define (na-make-array a . rest)    ; (make-array len) | (make-array type len ...)
  (make-jolt-array (make-vector (exact (na-idx (if (number? a) a (car rest)))) jolt-nil) 'object))
(define (na-into-array a . rest)    (na-from-seq (if (pair? rest) (car rest) a) 'object))
(define (na-to-array coll)          (na-from-seq coll 'object))
(define (na-aclone arr)
  (if (jolt-array? arr)
      (make-jolt-array (ja-copy (jolt-array-vec arr)) (jolt-array-kind arr))
      (na-from-seq arr 'object)))

;; System/arraycopy: copy one array range into another with JVM memmove
;; semantics. Validate the complete operation before mutating either array, then
;; delegate to Chez's overlap-safe bulk vector primitive. Primitive array kinds
;; must agree; jolt has a single Object[] kind, so that is the only
;; reference-array compatibility question its value model needs to answer.
(define na-vector-copy-proc
  (and (top-level-bound? 'vector-copy!)
       (top-level-value 'vector-copy!)))       ; Chez 10.3+
(define na-flvector-copy-proc
  (and (top-level-bound? 'flvector-copy!)
       (top-level-value 'flvector-copy!)))     ; Chez 10.2+
(define na-bytevector-copy-proc
  (and (top-level-bound? 'bytevector-copy!)
       (top-level-value 'bytevector-copy!)))
(define (na-arraycopy-fallback! sv s dv d n)
  ;; Chez 10.0/10.1 have the flvector substrate Jolt requires, but not both bulk
  ;; copy procedures. Preserve the same snapshot semantics on those releases.
  (if (and (eq? sv dv) (> d s) (< d (+ s n)))
      (let loop ((i (- n 1)))
        (when (>= i 0)
          (ja-set! dv (+ d i) (ja-ref sv (+ s i)))
          (loop (- i 1))))
      (let loop ((i 0))
        (when (< i n)
          (ja-set! dv (+ d i) (ja-ref sv (+ s i)))
          (loop (+ i 1))))))
(define (na-system-arraycopy src src-off dst dst-off len)
  (when (or (jolt-nil? src) (jolt-nil? dst))
    (throw-jvm (quote NullPointerException) "System/arraycopy: null array"))
  (unless (and (jolt-array? src) (jolt-array? dst)
               (eq? (jolt-array-kind src) (jolt-array-kind dst)))
    (throw-jvm (quote ArrayStoreException)
               "System/arraycopy: source and destination must have compatible array types"))
  (let* ((s (jnum->exact src-off))
         (d (jnum->exact dst-off))
         (n (jnum->exact len))
         (sv (jolt-array-vec src))
         (dv (jolt-array-vec dst))
         (slen (ja-len sv))
         (dlen (ja-len dv)))
    ;; The subtraction form avoids overflowing an offset+length sum.
    (when (or (< s 0) (< d 0) (< n 0) (> s slen) (> d dlen)
              (> n (- slen s)) (> n (- dlen d)))
      (throw-jvm (quote ArrayIndexOutOfBoundsException)
                 "System/arraycopy: range outside array bounds"))
    (cond
      ((and (flvector? sv) na-flvector-copy-proc)
       (na-flvector-copy-proc sv s dv d n))
      ((and (bytevector? sv) na-bytevector-copy-proc)
       (na-bytevector-copy-proc sv s dv d n))
      ((and (vector? sv) na-vector-copy-proc)
       (na-vector-copy-proc sv s dv d n))
      (else (na-arraycopy-fallback! sv s dv d n)))
    jolt-nil))
(register-class-statics! "System"
  (list (cons "arraycopy" na-system-arraycopy)))

;; --- typed aset (return the stored value) -----------------------------------
(define (na-aset! arr i v) (ja-set! (jolt-array-vec arr) (exact (na-idx i)) v) v)
(define (na-aset-int arr i v)     (na-aset! arr i v))
(define (na-aset-long arr i v)    (na-aset! arr i v))
(define (na-aset-short arr i v)   (na-aset! arr i v))
(define (na-aset-double arr i v)  (na-aset! arr i v))
(define (na-aset-float arr i v)   (na-aset! arr i v))
(define (na-aset-char arr i v)    (na-aset! arr i v))
(define (na-aset-boolean arr i v) (na-aset! arr i v))
(define (na-aset-byte arr i v)
  (ja-set! (jolt-array-vec arr) (exact (na-idx i)) (na-byte-of v)) v)

;; --- coercions (identity on arrays; byte/short are masked scalar casts) ------
(define (na-bytes x) (if (and (jolt-array? x) (eq? (jolt-array-kind x) 'byte)) x (na-byte-array x)))
(define (na-bytes? x) (and (jolt-array? x) (eq? (jolt-array-kind x) 'byte)))
(define (na-identity x) x)
(define (na-byte x) (jolt-byte-cast x))
(define (na-short x) (jolt-short-cast x))

;; --- chunked seqs -----------------------------------------------------------
;; The chunked-seq accessors (chunked-seq? / chunk-first / chunk-rest / chunk-next)
;; live in seq.ss with the cseq core they read; here we only bind them plus the
;; chunk-builder API (clojure.lang.ChunkBuffer + chunk-cons). chunk-buffer collects
;; appended items, chunk seals them into a pvec chunk, and chunk-cons prepends that
;; chunk onto a rest seq as a real ChunkedCons (cseq-chunked) — empty chunk == just
;; the rest, like clojure.core/chunk-cons.
(define-record-type jolt-chunkbuf (fields (mutable items)) (nongenerative jolt-chunkbuf-v1))
(define (na-chunk-buffer cap) (make-jolt-chunkbuf '()))
(define (na-chunk-append b x) (jolt-chunkbuf-items-set! b (append (jolt-chunkbuf-items b) (list x))) b)
(define (na-chunk b) (make-pvec (list->vector (jolt-chunkbuf-items b))))
(define (na-chunk-cons chunk rest)
  (if (fx=? 0 (pvec-count chunk)) rest (cseq-chunked chunk 0 rest)))

;; --- extend the collection dispatchers to see a jolt-array ------------------
(register-count-arm! jolt-array? (lambda (c) (ja-len (jolt-array-vec c))))
(register-seq-arm! jolt-array? (lambda (c) (list->cseq (ja->list (jolt-array-vec c)))))
(define %na-nth jolt-nth)
(set! jolt-nth
  (case-lambda
    ((c i)   (if (jolt-array? c) (ja-ref (jolt-array-vec c) (exact (na-idx i))) (%na-nth c i)))
    ((c i d) (if (jolt-array? c)
                 (let ((v (jolt-array-vec c)) (j (exact (na-idx i))))
                   (if (and (>= j 0) (< j (ja-len v))) (ja-ref v j) d))
                 (%na-nth c i d)))))
(def-var! "jolt.host" "array-value?" (lambda (x) (if (jolt-array? x) #t jolt-nil)))
;; jolt-get on arrays stays as a set!-wrap rather than register-get-arm! because
;; the arm dispatch (collections.ss jolt-get-dispatch) already handles the common
;; pmap/pvec/pset cases BEFORE it reaches the arm loop — and jolt-array? extends
;; jolt-nth (not jolt-get directly). The set!-wrap here REUSES jolt-nth (which
;; itself has a count-arm registry) so arrays get the same nth semantics without
;; re-entering the get arm loop. This is the documented fast-path exception.
(define %na-get jolt-get)
(set! jolt-get
  (case-lambda
    ((c k)   (if (jolt-array? c) (jolt-nth c k jolt-nil) (%na-get c k)))
    ((c k d) (if (jolt-array? c) (jolt-nth c k d) (%na-get c k d)))))
;; aset (overlay) writes through jolt.host/ref-put! — mutate the slot, return arr.
;; count/nth/seq/get above are NATIVE-OPS (inlined at call sites), so aget/alength/
;; array-seq/vec already use the set!-extended globals; ref-put! is a host var
;; (var-deref'd), so re-assert its cell to the array-aware closure.
(define %na-ref-put! jolt-ref-put!)
(set! jolt-ref-put!
  (lambda (t k v)
    (if (jolt-array? t) (begin (ja-set! (jolt-array-vec t) (exact (na-idx k)) v) t)
        (%na-ref-put! t k v))))
(def-var! "jolt.host" "ref-put!" jolt-ref-put!)
;; native-op target for the 1-dim (aset arr i v): write through the array-aware
;; ref-put! and return the stored value (JVM aset returns the val, not the array).
(define (jolt-aset3 a i v) (jolt-ref-put! a i v) v)
;; unboxed read target for (aget ^doubles a i): direct flvector-ref on the backing,
;; skipping jolt-nth's case-lambda + jolt-array?/flvector? dispatch. Emitted only
;; when jolt.passes.numeric proved the array is a ^doubles/^floats (flvector) param.
;; The index takes a fixnum?-first fast path: a proven-:long loop counter is always
;; a fixnum, and the (exact (na-idx i)) coercion (two procedure calls) was the
;; dominant per-access cost in the hot loop. Non-fixnum indices (flonum/bignum/
;; ratio) keep the coercing path unchanged; out-of-range still raises via
;; flvector-ref's range check (the array bounds contract).
(define (jolt-flaget a i)
  (flvector-ref (jolt-array-vec a) (if (fixnum? i) i (exact (na-idx i)))))
;; unboxed write target for (aset ^doubles a i v): direct flvector-set!, returning
;; the stored flonum (JVM aset returns the val). Same fixnum-first index path.
(define (jolt-flaset a i v)
  (let ((fv (if (flonum? v) v (exact->inexact v))))
    (flvector-set! (jolt-array-vec a) (if (fixnum? i) i (exact (na-idx i))) fv) fv))

;; A range condition escaping jolt-flaget/jolt-flaset IS the array bounds error
;; on the proven ^doubles path (a typed pre-check there costs ~1ns/access, ~11%
;; on an array-walking loop; wrapping in guard costs ~30ns/call). Classify the
;; raw Chez condition at inspection time instead: (class e) and instance? report
;; java.lang.ArrayIndexOutOfBoundsException, so a typed catch dispatches
;; precisely through the exception hierarchy and an unrelated class does not
;; broad-match. flvector-ref/-set! appear nowhere else in the runtime (the
;; generic ja-ref/ja-set! path pre-checks and throws typed before reaching
;; them), so the condition's who field is a precise key.
(define (na-flv-oob-condition? c)
  (and (condition? c) (who-condition? c)
       (memq (condition-who c) '(flvector-ref flvector-set!))))
(register-class-arm! na-flv-oob-condition?
  (lambda (c) "java.lang.ArrayIndexOutOfBoundsException"))
(register-instance-check-arm!
  (lambda (type-sym val)
    (if (na-flv-oob-condition? val)
        (exception-isa? "ArrayIndexOutOfBoundsException"
                        (last-dot (if (string? type-sym) type-sym (symbol-t-name type-sym))))
        'pass)))

;; --- array identity: type / class / instance? recognize arrays ---------------
;; (type arr) / (class arr) -> the JVM array class name; (class …) delegates to
;; (jolt-type …) for arrays, so extending jolt-type covers both.
(register-type-arm! jolt-array? (lambda (x) (na-array-class-name x)))

;; instance? over an array class token ([I, [C, …). An array token reaches us as
;; a string ("[C", from (Class/forName "[C")) — the dispatcher leaves it a string
;; (non-array string tokens are already normalized to symbols there); decide it
;; here, deferring everything else.
(register-instance-check-arm!
  (lambda (type-sym val)
    (let ((tname (cond ((string? type-sym) type-sym)
                       ((symbol-t? type-sym) (symbol-t-name type-sym))
                       (else #f))))
      (if (and tname (> (string-length tname) 0) (char=? (string-ref tname 0) #\[))
          (and (jolt-array? val) (string=? (na-array-class-name val) tname))
          'pass))))

;; clojure.java.io/reader over a char-array reads its chars (the JVM char[] branch).
(def-var! "clojure.java.io" "reader"
  (lambda (x)
    (if (jolt-array? x)
        (host-new "StringReader"
                  (apply string-append (map jolt-str-render-one (seq->list (jolt-seq x)))))
        (jolt-io-reader x))))

;; --- bind into clojure.core -------------------------------------------------
(for-each (lambda (p) (def-var! "clojure.core" (car p) (cdr p)))
  (list
    (cons "object-array" na-object-array) (cons "int-array" na-int-array)
    (cons "long-array" na-long-array) (cons "short-array" na-short-array)
    (cons "double-array" na-double-array) (cons "float-array" na-float-array)
    (cons "boolean-array" na-boolean-array)
    (cons "byte-array" na-byte-array) (cons "char-array" na-char-array)
    (cons "array?" (lambda (x) (jolt-array? x)))
    (cons "make-array" na-make-array)
    (cons "into-array" na-into-array) (cons "to-array" na-to-array) (cons "aclone" na-aclone)
    (cons "aset-int" na-aset-int) (cons "aset-long" na-aset-long)
    (cons "aset-short" na-aset-short) (cons "aset-double" na-aset-double)
    (cons "aset-float" na-aset-float) (cons "aset-char" na-aset-char)
    (cons "aset-boolean" na-aset-boolean) (cons "aset-byte" na-aset-byte)
    (cons "bytes" na-bytes) (cons "bytes?" na-bytes?)
    (cons "booleans" na-identity) (cons "ints" na-identity) (cons "longs" na-identity)
    (cons "shorts" na-identity) (cons "doubles" na-identity) (cons "floats" na-identity)
    (cons "chars" na-identity) (cons "byte" na-byte) (cons "short" na-short)
    (cons "chunk-buffer" na-chunk-buffer) (cons "chunk-append" na-chunk-append)
    (cons "chunk" na-chunk) (cons "chunk-cons" na-chunk-cons)
    (cons "chunk-first" na-chunk-first) (cons "chunk-rest" na-chunk-rest)
    (cons "chunk-next" na-chunk-next) (cons "chunked-seq?" na-chunked-seq?)))

;; --- clojure.java.io/copy ---------------------------------------------------
;; Copy src -> dst, JVM-style. Raw bytes (byte-array / bytevector / string) and a
;; jhost reader write in one shot; any other source (a stream shim with a .read
;; method, e.g. jolt-lang/http-client's ByteArrayInputStream) drains via .read
;; into a byte-array buffer and .write to dst — both reached through method
;; dispatch, so a library's tagged-table streams work without the host knowing
;; their layout. Lives here (not io.ss) because io.ss loads before byte-array.
(define (jolt-io-copy src dst . _opts)
  (define (write-all! bytes)
    (record-method-dispatch dst "write" (list->cseq (list bytes 0 (ja-len (jolt-array-vec bytes))))))
  (cond
    ((or (bytevector? src) (string? src)
         (and (jolt-array? src) (eq? (jolt-array-kind src) 'byte)))
     (write-all! (na-byte-array src)))
    ((and (jhost? src) (member (jhost-tag src) '("string-reader" "pushback-reader")))
     (write-all! (na-byte-array (drain-reader src))))
    (else
     (let ((buf (na-byte-array 8192)))
       (let loop ()
         (let ((n (record-method-dispatch src "read" (list->cseq (list buf 0 8192)))))
           (when (and (number? n) (> (jnum->exact n) 0))
             (record-method-dispatch dst "write" (list->cseq (list buf 0 n)))
             (loop)))))))
  jolt-nil)
(def-var! "clojure.java.io" "copy" jolt-io-copy)

;; java.lang.reflect.Field over the modeled class registry: getDeclaredFields on
;; a Class naming a deftype/defrecord returns its declared fields, each
;; answering getName / setAccessible / get — the reflective field walk
;; (fireworks' datatype->map) works because the model already holds the field
;; list in the type's descriptor.
(define (reflect-field-name self) (vector-ref (jhost-state self) 0))
(register-host-methods! "reflect-field"
  (list (cons "getName" (lambda (self) (let ((k (reflect-field-name self)))
                                         (if (keyword? k) (keyword-t-name k) (jolt-str-render-one k)))))
        (cons "setAccessible" (lambda (self v) jolt-nil))
        (cons "get" (lambda (self obj)
                      (jolt-get obj (reflect-field-name self) jolt-nil)))
        (cons "toString" (lambda (self) (jolt-str-render-one (reflect-field-name self))))))
(register-host-methods! "class"
  (list (cons "getDeclaredFields"
              (lambda (self)
                (let ((desc (hashtable-ref chez-tag-desc (jclass-name self) #f)))
                  (make-jolt-array
                   (if desc
                       (vector-map (lambda (k) (make-jhost "reflect-field" (vector k)))
                                   (jrdesc-fkeys desc))
                       (vector))
                   'objects))))))
