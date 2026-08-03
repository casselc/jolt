;; natives-array.ss — Java-style mutable arrays for the Chez host.
;;
;; A jolt-array wraps a mutable Chez BACKING + a `kind` tag (for bytes?). The backing
;; is a bytevector for byte arrays, an flvector for double/float arrays, and a boxed
;; vector for every other kind — see THE BACKING SEAM below, which is the only place
;; that distinction is visible. The array CONSTRUCTORS are native (they build the
;; backing); the overlay's aget/aset/alength are pure over count / nth /
;; jolt.host/ref-put!, so we extend those dispatchers to see a jolt-array. Loaded
;; after host-table.ss (ref-put!), transients.ss, seq.ss (the dispatchers it chains).

(define-record-type jolt-array (fields (mutable vec) kind) (nongenerative jolt-array-v1))

;; JVM array class name per element kind ((class (int-array 3)) -> "[I", like the
;; JVM's Class.getName for arrays). Object arrays use the descriptor form.
(define (na-array-class-name arr)
  (case (jolt-array-kind arr)
    ((int) "[I") ((long) "[J") ((short) "[S") ((double) "[D")
    ((float) "[F") ((boolean) "[Z") ((byte) "[B") ((char) "[C")
    (else "[Ljava.lang.Object;")))

(define (na-idx i) (if (and (number? i) (not (exact? i))) (exact (floor i)) i))

;; numeric tower: array element defaults / masked bytes / count are
;; EXACT integers (= JVM byte/short/int), matching exact integer literals.
;; Defined ahead of the seam because ja-set!'s byte arm narrows through it.
(define (na-byte-of v) (bitwise-and (exact (floor v)) #xff))

;; --- THE BACKING SEAM -------------------------------------------------------
;; THREE backings, keyed off the element kind:
;;   byte          -> a Chez BYTEVECTOR   (1 byte/element, unboxed octets)
;;   double/float  -> a Chez FLVECTOR     (8 bytes/element, unboxed flonums)
;;   everything else -> a boxed Chez VECTOR
;; These helpers let the collection dispatchers (count/seq/nth/ref-put!/aset/aclone)
;; and java.util.Arrays work over any of them. Chez has bytevector? /
;; make-bytevector / bytevector-u8-ref / -set! / bytevector-length, and
;; flvector? / make-flvector / flvector-ref / -set! / -length.
;;
;; CONVENTION: every ja-* helper takes the BACKING (the result of jolt-array-vec),
;; NOT the jolt-array. Call sites read the backing out once — (let ((v (jolt-array-vec
;; a))) …) — and then go through ja-len / ja-ref / ja-set! / ja->list / ja-copy /
;; ja-equal? only. They must NOT call vector-length / vector-ref / vector-set! /
;; vector->list / vector? on it. That rule is what makes the backing representation
;; swappable in THIS FILE alone: adding a new backing kind means adding an arm to
;; each helper below (plus na-make-backing / na-list->backing for construction), and
;; nothing outside natives-array.ss has to change.
;;
;; BYTE SLOTS HOLD UNSIGNED OCTETS (0..255), which is what the vector backing
;; already stored and what every byte-array constructor already produced —
;; (aget (byte-array [-1]) 0) is 255 here and was 255 before. The JVM exposes
;; byte[] slots as SIGNED bytes; jolt.core's `unchecked-byte` / jolt-bytes'
;; `signed-byte-at` do that conversion on read. So the bytevector's u8 domain is
;; exactly the domain the byte backing already had — the representation narrowed,
;; the value domain did not move.
;;
;; Keep these small, non-recursive and closure-free — ja-ref/ja-set! are per-element
;; on array traversal, so cp0 must be able to inline them at every call site. The
;; bytevector arm is tested FIRST: byte scanning is the workload this backing exists
;; for, and the flonum arrays have their own unboxed bypass (jolt-flaget/jolt-flaset)
;; for their hot path.
(define (na-fl-kind? k) (or (eq? k 'double) (eq? k 'float)))
(define (ja-len v)
  (cond ((bytevector? v) (bytevector-length v))
        ((flvector? v)   (flvector-length v))
        (else            (vector-length v))))
(define (ja-ref v i)
  (cond ((bytevector? v) (bytevector-u8-ref v i))
        ((flvector? v)   (flvector-ref v i))
        (else            (vector-ref v i))))
;; ja-set! on a byte backing NARROWS to an octet rather than throwing.
;; bytevector-u8-set! errors outside 0..255 where vector-set! silently accepted
;; anything, so the byte arm has to choose. It masks, for two reasons: (a) it makes
;; the generic aset / jolt.host/ref-put! path agree with na-aset-byte (aset-byte),
;; which has always masked through na-byte-of, and (b) masking is what the JVM does
;; — `b[i] = (byte) v` narrows. This is the one deliberate BEHAVIOUR change of the
;; bytevector switch: (aset (byte-array 3) 0 -1) used to leave a raw -1 in the slot
;; (a value no JVM byte[] can hold, and one that `seq`/`Arrays/toString` then leaked
;; back out); it now leaves 255, the same octet aset-byte would have written.
(define (ja-set! v i x)
  (cond ((bytevector? v)
         (bytevector-u8-set! v i (if (and (fixnum? x) (fx>=? x 0) (fx<=? x 255)) x (na-byte-of x))))
        ((flvector? v) (flvector-set! v i (if (flonum? x) x (exact->inexact x))))
        (else (vector-set! v i x))))
(define (ja->list v)
  (cond ((bytevector? v) (bytevector->u8-list v))
        ((flvector? v)
         (let loop ((i (- (flvector-length v) 1)) (acc '()))
           (if (< i 0) acc (loop (- i 1) (cons (flvector-ref v i) acc)))))
        (else (vector->list v))))
(define (ja-copy v)
  (cond ((bytevector? v) (bytevector-copy v))
        ((flvector? v)
         (let* ((n (flvector-length v)) (r (make-flvector n 0.0)))
           (do ((i 0 (+ i 1))) ((= i n) r) (flvector-set! r i (flvector-ref v i)))))
        (else (vector-copy v))))
;; Element-wise equality of two backings (java.util.Arrays/equals).
;;
;; CROSS-KIND EQUALITY IS PRESERVED. `equal?` alone would now answer #f for
;; (Arrays/equals (byte-array [1 2]) (int-array [1 2])) — a bytevector is never
;; equal? to a vector — where it answered #t before the byte backing moved. That
;; comparison is a compile error on the JVM (there is no Arrays.equals(byte[],int[])
;; overload), so neither answer is "the JVM's"; #t is simply what jolt has always
;; said, and the representation change is not a reason to change it. So: same
;; backing shape -> one `equal?` (the fast path, and the only path byte/byte,
;; int/int and double/double take); different shapes -> walk elements. Element
;; comparison stays `equal?`, which keeps exact-vs-inexact distinct — a byte-array
;; and a double-array of the same numbers are still NOT equal, as before.
(define (ja-same-shape? a b)
  (or (and (bytevector? a) (bytevector? b))
      (and (flvector? a) (flvector? b))
      (and (vector? a) (vector? b))))
(define (ja-equal? a b)
  (if (ja-same-shape? a b)
      (equal? a b)
      (let ((n (ja-len a)))
        (and (= n (ja-len b))
             (let loop ((i 0))
               (or (= i n)
                   (and (equal? (ja-ref a i) (ja-ref b i)) (loop (+ i 1)))))))))
(define (na-make-backing n kind init)
  (cond ((eq? kind 'byte) (make-bytevector (exact n) (na-byte-of init)))
        ((na-fl-kind? kind)
         (make-flvector (exact n) (if (flonum? init) init (exact->inexact init))))
        (else (make-vector (exact n) init))))
(define (na-list->backing lst kind)
  (cond ((eq? kind 'byte)
         (let* ((n (length lst)) (bv (make-bytevector n)))
           (let loop ((i 0) (l lst))
             (if (null? l) bv
                 (begin (bytevector-u8-set! bv i (na-byte-of (car l))) (loop (+ i 1) (cdr l)))))))
        ((na-fl-kind? kind)
         (let* ((n (length lst)) (fv (make-flvector n 0.0)))
           (let loop ((i 0) (l lst))
             (if (null? l) fv (begin (flvector-set! fv i (exact->inexact (car l))) (loop (+ i 1) (cdr l)))))))
        (else (list->vector lst))))

(define (na-from-seq x kind) (make-jolt-array (na-list->backing (seq->list (jolt-seq x)) kind) kind))
;; (T-array size) | (T-array size init) | (T-array seq)
(define (na-num-array a rest init kind)
  (if (number? a)
      (make-jolt-array (na-make-backing (na-idx a) kind (if (pair? rest) (car rest) init)) kind)
      (na-from-seq a kind)))

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
;; carrier — a Chez bytevector (what a raw host read hands back) — and a string's
;; UTF-8 bytes, so bytevector and byte-array interconvert across interop seams.
;; The backing IS a bytevector now, so the bytevector/string/byte-array arms are
;; straight copies (string->utf8 already yields the exact backing we want) instead
;; of the u8-list round trips they needed when the backing was a boxed vector.
(define (na-byte-array a . rest)
  (cond
    ((number? a) (make-jolt-array (make-bytevector (exact (na-idx a)) (na-byte-of (if (pair? rest) (car rest) 0))) 'byte))
    ((bytevector? a) (make-jolt-array (bytevector-copy a) 'byte))
    ((string? a) (make-jolt-array (string->utf8 a) 'byte))
    ;; another byte-array: its backing is already a bytevector of octets, so the
    ;; per-element na-byte-of masking the seq path would do is a no-op. Copy it.
    ((and (jolt-array? a) (eq? (jolt-array-kind a) 'byte))
     (make-jolt-array (bytevector-copy (jolt-array-vec a)) 'byte))
    (else (make-jolt-array (na-list->backing (seq->list (jolt-seq a)) 'byte) 'byte))))
;; jolt byte-array -> Chez bytevector (for String decode / utf8->string). A fresh
;; copy: callers hand the result to decoders/ports that must not alias live storage.
(define (na-bytearray->bv arr)
  (let ((v (jolt-array-vec arr)))
    (if (bytevector? v)
        (bytevector-copy v)
        (let* ((n (ja-len v)) (bv (make-bytevector n)))
          (do ((i 0 (+ i 1))) ((= i n)) (bytevector-u8-set! bv i (bitwise-and (exact (ja-ref v i)) #xff)))
          bv))))
(define (na-make-array a . rest)    ; (make-array len) | (make-array type len ...)
  (make-jolt-array (make-vector (exact (na-idx (if (number? a) a (car rest)))) jolt-nil) 'object))
(define (na-into-array a . rest)    (na-from-seq (if (pair? rest) (car rest) a) 'object))
(define (na-to-array coll)          (na-from-seq coll 'object))
(define (na-aclone arr)
  (if (jolt-array? arr)
      (make-jolt-array (ja-copy (jolt-array-vec arr)) (jolt-array-kind arr))
      (na-from-seq arr 'object)))

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
;; REPRESENTATION DEPENDENCY (deliberate): these two bypass the ja-* seam on purpose
;; — the whole point is to skip the flvector? test the seam would re-do. They are
;; sound only because the numeric pass proved the ^doubles/^floats kind, so they are
;; pinned to the FLVECTOR backing specifically and are unaffected by any change to
;; the byte/object backing. If the flvector backing ever moves, fix these too.
(define (jolt-flaget a i) (flvector-ref (jolt-array-vec a) (exact (na-idx i))))
;; unboxed write target for (aset ^doubles a i v): direct flvector-set!, returning
;; the stored flonum (JVM aset returns the val).
(define (jolt-flaset a i v)
  (let ((fv (if (flonum? v) v (exact->inexact v))))
    (flvector-set! (jolt-array-vec a) (exact (na-idx i)) fv) fv))

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
