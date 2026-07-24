;; byte-buffer.ss — java.nio.ByteBuffer over a jolt byte-array. A buffer is a
;; jhost tagged "byte-buffer" with mutable #(backing-array position limit); the
;; backing is a jolt byte-array (bytevector of 0..255). Covers the slice of the API
;; portable code reaches for — wrap / get(byte[]) / array / remaining / position /
;; limit / duplicate / flip / rewind — e.g. cognitect aws-api wrapping blob bytes.

(define (make-byte-buffer backing pos limit) (make-jhost "byte-buffer" (vector backing pos limit)))
(define (bb? x) (and (jhost? x) (string=? (jhost-tag x) "byte-buffer")))
(define (bb-backing b) (vector-ref (jhost-state b) 0))
(define (bb-pos b) (vector-ref (jhost-state b) 1))
(define (bb-limit b) (vector-ref (jhost-state b) 2))
(define (bb-pos! b n) (vector-set! (jhost-state b) 1 n))
(define (bb-limit! b n) (vector-set! (jhost-state b) 2 n))
(define (bb-capacity b) (ja-len (jolt-array-vec (bb-backing b))))

;; (ByteBuffer/wrap ba) | (ByteBuffer/wrap ba off len) | (ByteBuffer/allocate n)
(register-class-statics! "ByteBuffer"
  (list
    (cons "wrap" (lambda (ba . rest)
                   (let ((cap (ja-len (jolt-array-vec ba))))
                     (if (pair? rest)
                         (let ((off (jnum->exact (car rest))) (len (jnum->exact (cadr rest))))
                           (make-byte-buffer ba off (+ off len)))
                         (make-byte-buffer ba 0 cap)))))
    (cons "allocate" (lambda (n)
                       (let ((cap (jnum->exact n)))
                         (make-byte-buffer (na-byte-array cap) 0 cap))))
    ;; jolt has one heap; a direct buffer is just a buffer here.
    (cons "allocateDirect" (lambda (n)
                             (let ((cap (jnum->exact n)))
                               (make-byte-buffer (na-byte-array cap) 0 cap))))))

(register-host-methods! "byte-buffer"
  (list
    (cons "remaining" (lambda (self) (->num (- (bb-limit self) (bb-pos self)))))
    (cons "hasRemaining" (lambda (self) (> (bb-limit self) (bb-pos self))))
    ;; position / limit are getters with no arg, setters (returning the buffer) with one
    (cons "position" (lambda (self . a)
                       (if (pair? a) (begin (bb-pos! self (jnum->exact (car a))) self) (->num (bb-pos self)))))
    (cons "limit" (lambda (self . a)
                    (if (pair? a) (begin (bb-limit! self (jnum->exact (car a))) self) (->num (bb-limit self)))))
    (cons "capacity" (lambda (self) (->num (bb-capacity self))))
    (cons "hasArray" (lambda (self) #t))
    (cons "array" (lambda (self) (bb-backing self)))
    (cons "duplicate" (lambda (self) (make-byte-buffer (bb-backing self) (bb-pos self) (bb-limit self))))
    (cons "asReadOnlyBuffer" (lambda (self) (make-byte-buffer (bb-backing self) (bb-pos self) (bb-limit self))))
    ;; slice(): a 0-based buffer over the remaining bytes [position, limit). The
    ;; JVM shares the backing; here it is a copy, so writes don't propagate back
    ;; (read paths — hexdumps, decoders — are unaffected).
    (cons "slice" (lambda (self)
                    (let* ((p (bb-pos self))
                           (n (- (bb-limit self) p))
                           (dst (na-byte-array n)))
                      (na-system-arraycopy (bb-backing self) p dst 0 n)
                      (make-byte-buffer dst 0 n))))
    (cons "rewind" (lambda (self) (bb-pos! self 0) self))
    (cons "flip" (lambda (self) (bb-limit! self (bb-pos self)) (bb-pos! self 0) self))
    (cons "clear" (lambda (self) (bb-pos! self 0) (bb-limit! self (bb-capacity self)) self))
    ;; (.get dst) | (.get dst off len): bulk copy from position into a byte-array,
    ;; advancing position. Returns the buffer like the JVM.
    ;; (.put src): copy bytes into the buffer at position, advancing it. src is
    ;; another ByteBuffer (its remaining bytes), a byte-array, or a single byte.
    (cons "put" (lambda (self src . rest)
                  (let ((dv (jolt-array-vec (bb-backing self))) (dp (bb-pos self)))
                    (cond
                      ((bb? src)
                       (let* ((sp (bb-pos src))
                              (n (- (bb-limit src) sp)))
                         (na-system-arraycopy (bb-backing src) sp (bb-backing self) dp n)
                         (bb-pos! src (bb-limit src)) (bb-pos! self (+ dp n))))
                      ((jolt-array? src)
                       (let ((n (ja-len (jolt-array-vec src))))
                         (na-system-arraycopy src 0 (bb-backing self) dp n)
                         (bb-pos! self (+ dp n))))
                      (else (ja-set! dv dp (jnum->exact src)) (bb-pos! self (+ dp 1))))
                    self)))
    ;; get(): relative single byte at position, advancing it.
    ;; get(int i): absolute single byte at index i (position unchanged).
    ;; get(byte[] dst [off len]): bulk copy from position, advancing it.
    (cons "get" (lambda (self . args)
                  (let ((src (jolt-array-vec (bb-backing self))))
                    (cond
                      ((null? args)
                       (let ((p (bb-pos self))) (bb-pos! self (+ p 1)) (->num (ja-ref src p))))
                      ((number? (car args))
                       (->num (ja-ref src (jnum->exact (car args)))))
                      (else
                       (let* ((dst (car args)) (rest (cdr args)) (dv (jolt-array-vec dst))
                              (off (if (pair? rest) (jnum->exact (car rest)) 0))
                              (len (if (and (pair? rest) (pair? (cdr rest))) (jnum->exact (cadr rest)) (ja-len dv)))
                              (p (bb-pos self)))
                         (na-system-arraycopy (bb-backing self) p dst off len)
                         (bb-pos! self (+ p len))
                         self))))))))

(register-class-arm! bb? (lambda (x) "java.nio.ByteBuffer"))
(register-instance-check-arm!
  (lambda (type-sym val)
    (if (and (symbol-t? type-sym) (bb? val)
             (member (last-dot (symbol-t-name type-sym)) '("ByteBuffer")))
        #t 'pass)))
