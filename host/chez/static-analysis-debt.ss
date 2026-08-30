;; Generic issue-tagged debt ledger for static-analysis gates.
;; Findings are: <file> <definition> <kind> <callee> <positive-count>.
;; Accepted debt appends issue=owner/repo#NN. A caller supplies accepted kinds
;; and the issue prefix, so each gate keeps its domain policy while sharing the
;; strict lifecycle: new, increased, decreased, dropped, malformed, duplicate,
;; and untagged rows all fail.

(define (analysis-words s)
  (let ((n (string-length s)))
    (let loop ((i 0) (start #f) (out '()))
      (cond
        ((= i n) (reverse (if start (cons (substring s start i) out) out)))
        ((char-whitespace? (string-ref s i))
         (loop (+ i 1) #f (if start (cons (substring s start i) out) out)))
        (else (loop (+ i 1) (or start i) out))))))

(define (analysis-join-with-space xs)
  (if (null? xs) ""
      (let loop ((rest (cdr xs)) (out (car xs)))
        (if (null? rest) out
            (loop (cdr rest) (string-append out " " (car rest)))))))

(define (analysis-last-space line)
  (let loop ((i (- (string-length line) 1)))
    (cond ((< i 0) #f)
          ((char=? #\space (string-ref line i)) i)
          (else (loop (- i 1))))))

(define (analysis-finding-key line)
  (let ((i (analysis-last-space line)))
    (if i (substring line 0 i) line)))

(define (analysis-finding-count line)
  (let ((i (analysis-last-space line)))
    (if i
        (or (string->number (substring line (+ i 1) (string-length line))) 0)
        0)))

(define (analysis-finding-kind line)
  (let ((ws (analysis-words line)))
    (if (>= (length ws) 3) (list-ref ws 2) "")))

(define (analysis-read-data-lines path)
  (if (file-exists? path)
      (let ((p (open-input-file path)))
        (let loop ((out '()))
          (let ((line (get-line p)))
            (cond ((eof-object? line) (close-port p) (reverse out))
                  ((or (string=? line "")
                       (and (> (string-length line) 0)
                            (char=? #\# (string-ref line 0))))
                   (loop out))
                  (else (loop (cons line out)))))))
      '()))

(define (analysis-issue-token? token issue-prefix)
  (let ((lp (string-length issue-prefix)) (lt (string-length token)))
    (and (> lt lp)
         (string=? issue-prefix (substring token 0 lp))
         (for-all char-numeric? (string->list (substring token lp lt)))
         (let ((n (string->number (substring token lp lt))))
           (and n (integer? n) (> n 0))))))

;; Parsed debt is (key count issue raw). The key is the first four fields.
(define (analysis-parse-debt-line line accepted-kinds issue-prefix)
  (let ((ws (analysis-words line)))
    (and (= (length ws) 6)
         (member (list-ref ws 2) accepted-kinds)
         (let ((count (string->number (list-ref ws 4))))
           (and count (integer? count) (> count 0)
                (analysis-issue-token? (list-ref ws 5) issue-prefix)
                (list (analysis-join-with-space (list-head ws 4)) count
                      (list-ref ws 5) line))))))

;; Returns (entries . errors), rejecting malformed rows and duplicate keys.
(define (analysis-validate-debt-lines lines accepted-kinds issue-prefix)
  (let ((seen (make-hashtable string-hash string=?)))
    (let loop ((ls lines) (entries '()) (errors '()))
      (if (null? ls)
          (cons (reverse entries) (reverse errors))
          (let ((entry (analysis-parse-debt-line
                         (car ls) accepted-kinds issue-prefix)))
            (cond
              ((not entry)
               (loop (cdr ls) entries
                     (cons (string-append "malformed debt entry: " (car ls)) errors)))
              ((hashtable-ref seen (car entry) #f)
               (loop (cdr ls) entries
                     (cons (string-append "duplicate debt key: " (car entry)) errors)))
              (else
               (hashtable-set! seen (car entry) #t)
               (loop (cdr ls) (cons entry entries) errors))))))))

(define (analysis-debt-problems got-lines validated)
  (let ((entries (car validated)) (errors (cdr validated))
        (by-key (make-hashtable string-hash string=?))
        (got-by-key (make-hashtable string-hash string=?)))
    (for-each (lambda (entry) (hashtable-set! by-key (car entry) entry)) entries)
    (for-each
      (lambda (finding)
        (hashtable-set! got-by-key (analysis-finding-key finding) finding))
      got-lines)
    (let ((problems errors))
      (for-each
        (lambda (finding)
          (let* ((key (analysis-finding-key finding))
                 (entry (hashtable-ref by-key key #f))
                 (count (analysis-finding-count finding)))
            (cond ((not entry)
                   (set! problems
                     (cons (string-append "untagged new finding: " finding) problems)))
                  ((> count (cadr entry))
                   (set! problems
                     (cons (string-append "increased debt: " finding " (was "
                                          (number->string (cadr entry)) ")") problems)))
                  ((< count (cadr entry))
                   (set! problems
                     (cons (string-append "decreased/stale debt: " (cadddr entry)
                                          " -> " (number->string count)) problems))))))
        got-lines)
      (for-each
        (lambda (entry)
          (unless (hashtable-ref got-by-key (car entry) #f)
            (set! problems
              (cons (string-append "dropped/stale debt: " (cadddr entry) " -> 0")
                    problems))))
        entries)
      (reverse problems))))

(define (analysis-debt-self-test accepted-kinds issue-prefix)
  (let* ((kind (if (null? accepted-kinds) "finding" (car accepted-kinds)))
         (base (string-append "synthetic f " kind " callback"))
         (g1 (string-append base " 1"))
         (g2 (string-append base " 2"))
         (good (string-append g1 " " issue-prefix "26"))
         (higher (string-append g2 " " issue-prefix "26"))
         (bad g1)
         (valid-good
           (analysis-validate-debt-lines (list good) accepted-kinds issue-prefix)))
    (and (pair? accepted-kinds)
         (null? (analysis-debt-problems (list g1) valid-good))
         (pair? (analysis-debt-problems
                  (list g1)
                  (analysis-validate-debt-lines '() accepted-kinds issue-prefix)))
         (pair? (analysis-debt-problems (list g2) valid-good))
         (pair? (analysis-debt-problems '() valid-good))
         (pair? (analysis-debt-problems
                  (list g1)
                  (analysis-validate-debt-lines
                    (list higher) accepted-kinds issue-prefix)))
         (pair? (cdr (analysis-validate-debt-lines
                       (list bad) accepted-kinds issue-prefix)))
         (pair? (cdr (analysis-validate-debt-lines
                       (list good good) accepted-kinds issue-prefix))))))
