;; Pure normalization for stdout captured by the build subsystem.
;;
;; Chez get-line removes LF but preserves the CR from a Windows CRLF line
;; ending. Normalize that terminator on every line before joining, then honor
;; bld-sh-capture's existing contract by trimming only the outside of the
;; complete result. Internal newlines and whitespace remain significant.

(define (bld-trim-outer-whitespace s)
  (let ((n (string-length s)))
    (let find-start ((start 0))
      (if (and (< start n) (char-whitespace? (string-ref s start)))
          (find-start (+ start 1))
          (let find-end ((end n))
            (if (and (> end start)
                     (char-whitespace? (string-ref s (- end 1))))
                (find-end (- end 1))
                (substring s start end)))))))

(define (bld-strip-line-return s)
  (let ((n (string-length s)))
    (if (and (> n 0) (char=? (string-ref s (- n 1)) #\return))
        (substring s 0 (- n 1))
        s)))

(define (bld-captured-lines->string lines)
  (bld-trim-outer-whitespace
    (if (null? lines)
        ""
        (let ((normalized (map bld-strip-line-return lines)))
          (fold-left
            (lambda (s line) (string-append s "\n" line))
            (car normalized)
            (cdr normalized))))))
