;; Files/createDirectories must tolerate a concurrent creator only after the
;; atomic mkdir result reports EEXIST and the colliding name is a directory.
(import (chezscheme))
(load "host/chez/run-gate-harness.ss")
(load "host/chez/loader.ss")

(define failures '())
(define (check label pred)
  (unless pred (set! failures (cons label failures))))
(define (render-condition e)
  (if (condition? e)
      (let ((p (open-output-string)))
        (display-condition e p)
        (get-output-string p))
      (format "~s" e)))
(define (now-secs)
  (let ((t (current-time 'time-monotonic)))
    (+ (time-second t)
       (/ (exact->inexact (time-nanosecond t)) 1000000000.0))))
(define (pause-millis n)
  (sleep (make-time 'time-duration (* n 1000000) 0)))
(define (write-text path text)
  (let ((p (open-file-output-port path (file-options no-fail))))
    (put-bytevector p (string->utf8 text))
    (close-port p)))
(define (read-text path)
  (let ((p (open-file-input-port path)))
    (let ((text (utf8->string (get-bytevector-all p))))
      (close-port p)
      text)))

(define root
  (npath-string-of (nio-files-create-temp (list "jolt-nio-directories-test-") #t)))
(define phase (box "starting"))
(define outcome (box 'running))
(define (at! x) (set-box! phase x))
(define (print-worker-errors label errors)
  (let loop ((i 0))
    (when (< i (vector-length errors))
      (let ((e (vector-ref errors i)))
        (when e
          (printf "  ~a worker ~a raised: ~a\n" label i (render-condition e))))
      (loop (+ i 1)))))

;; Both creators pass their missing-chain scan before either may issue the first
;; mkdir.  The bounded rendezvous gives the strict-EEXIST mutation deterministic
;; teeth without allowing a broken scan to hang CI.
(define (run-same-chain-race name strict-mutation?)
  (let* ((base (string-append root "/" name))
         (leaf (string-append base "/one/two/three"))
         (first (string-append base "/one"))
         (barrier-mu (make-mutex))
         (arrivals 0)
         (errors (vector #f #f))
         (original-c-mkdir fs-c-mkdir)
         (original-step fs-create-directories-result))
    (define (barrier!)
      (let ((deadline (+ (now-secs) 10.0)))
        (with-mutex barrier-mu (set! arrivals (+ arrivals 1)))
        (let wait ()
          (cond ((with-mutex barrier-mu (= arrivals 2)) #t)
                ((> (now-secs) deadline)
                 (error 'nio-create-directories-test
                        "two-creator collision rendezvous timed out"))
                (else (pause-millis 1) (wait))))))
    (nio-mkdir-atomic! base #o700)
    (dynamic-wind
      (lambda ()
        (set! fs-c-mkdir
          (lambda args
            (when (string=? (car args) first) (barrier!))
            (apply original-c-mkdir args)))
        (when strict-mutation?
          (set! fs-create-directories-result
            (lambda (fp mode)
              (let-values (((status native-error) (original-step fp mode)))
                (if (eq? status 'exists)
                    (values 'error native-error)
                    (values status native-error)))))))
      (lambda ()
        (let ((threads
               (map (lambda (index)
                      (fork-thread
                        (lambda ()
                          (guard (e (#t (vector-set! errors index e)))
                            (nio-create-directories! leaf #o700)))))
                    '(0 1))))
          ;; The process watchdog bounds these joins if a worker wedges after
          ;; leaving the explicitly bounded rendezvous.
          (for-each thread-join threads)))
      (lambda ()
        (set! fs-c-mkdir original-c-mkdir)
        (set! fs-create-directories-result original-step)))
    (vector leaf arrivals errors)))

(define (test-same-chain-races!)
  (at! "same-chain race")
  (let* ((result (run-same-chain-race "shared" #f))
         (errors (vector-ref result 2)))
    (print-worker-errors "same-chain" errors)
    (check "two creators reached the controlled collision"
           (= (vector-ref result 1) 2))
    (check "two creators of one chain both succeed"
           (and (not (vector-ref errors 0)) (not (vector-ref errors 1))))
    (check "shared deep chain exists" (file-directory? (vector-ref result 0))))
  (at! "strict-EEXIST mutation")
  (let* ((result (run-same-chain-race "strict-mutation" #t))
         (errors (vector-ref result 2))
         (error-count (+ (if (vector-ref errors 0) 1 0)
                         (if (vector-ref errors 1) 1 0))))
    (unless (= error-count 1)
      (print-worker-errors "strict-EEXIST mutation" errors))
    (check "strict-EEXIST mutation is detected by the controlled race"
           (= error-count 1))))

(define (test-distinct-chains!)
  (at! "distinct concurrent chains")
  (let ((a (string-append root "/distinct/a/b/c/d/e"))
        (b (string-append root "/distinct/x/y/z/u/v"))
        (errors (vector #f #f)))
    (let ((threads
           (list (fork-thread
                   (lambda ()
                     (guard (e (#t (vector-set! errors 0 e)))
                       (nio-create-directories! a #o700))))
                 (fork-thread
                   (lambda ()
                     (guard (e (#t (vector-set! errors 1 e)))
                       (nio-create-directories! b #o700)))))))
      (for-each thread-join threads))
    (print-worker-errors "distinct-chain" errors)
    (check "distinct deep chains succeed concurrently"
           (and (not (vector-ref errors 0)) (not (vector-ref errors 1))
                (file-directory? a) (file-directory? b)))))

(define (test-existing-paths!)
  (at! "existing paths")
  (let ((dir (string-append root "/already-directory"))
        (file (string-append root "/already-file")))
    (nio-mkdir-atomic! dir #o700)
    (let ((raised? #f))
      (guard (e (#t (set! raised? #t)))
        (nio-create-directories! dir #o700))
      (check "already-existing directory succeeds" (not raised?)))
    (write-text file "sentinel")
    (let ((raised? #f))
      (guard (e (#t (set! raised? #t)))
        (nio-create-directories! file #o700))
      (check "existing non-directory fails" raised?))
    (check "existing non-directory sentinel is preserved"
           (string=? (read-text file) "sentinel"))))

(define (test-non-eexist-failure!)
  (at! "non-EEXIST failure")
  (let ((denied (string-append root "/denied"))
        (calls 0) (raised? #f) (original fs-c-mkdir))
    (nio-mkdir-atomic! denied #o700)
    (dynamic-wind
      (lambda ()
        (set! fs-c-mkdir
          (lambda _ (set! calls (+ calls 1)) (values -1 13))))
      (lambda ()
        (guard (e (#t (set! raised? #t)))
          (nio-create-directories! denied #o700)))
      (lambda () (set! fs-c-mkdir original)))
    (check "non-EEXIST native failure is not reclassified" raised?)
    (check "non-EEXIST native failure is not retried" (= calls 1))))

(define (test-eexist-replacement-races!)
  ;; EEXIST is provisionally tolerable only while its name denotes a directory.
  (at! "deleted EEXIST winner")
  (let ((path (string-append root "/vanished"))
        (raised? #f) (original fs-c-mkdir))
    (nio-mkdir-atomic! path #o700)
    (dynamic-wind
      (lambda ()
        (set! fs-c-mkdir
          (lambda args
            (let-values (((result native-error) (apply original args)))
              (when (and (not (= result 0)) (string=? (car args) path))
                (delete-directory path))
              (values result native-error)))))
      (lambda ()
        (guard (e (#t (set! raised? #t)))
          (nio-create-directories! path #o700)))
      (lambda () (set! fs-c-mkdir original)))
    (check "deleted EEXIST winner fails closed" raised?)
    (check "deleted EEXIST winner remains absent" (not (file-exists? path))))
  (at! "replaced EEXIST winner")
  (let ((path (string-append root "/replaced"))
        (raised? #f) (original fs-c-mkdir))
    (nio-mkdir-atomic! path #o700)
    (dynamic-wind
      (lambda ()
        (set! fs-c-mkdir
          (lambda args
            (let-values (((result native-error) (apply original args)))
              (when (and (not (= result 0)) (string=? (car args) path))
                (delete-directory path)
                (write-text path "replacement-sentinel"))
              (values result native-error)))))
      (lambda ()
        (guard (e (#t (set! raised? #t)))
          (nio-create-directories! path #o700)))
      (lambda () (set! fs-c-mkdir original)))
    (check "non-directory replacement after EEXIST fails closed" raised?)
    (check "replacement sentinel is preserved"
           (string=? (read-text path) "replacement-sentinel"))))

(define (test-symlink-paths!)
  ;; createDirectories follows links for its directory test.  Targets that lead
  ;; to a file or nowhere still fail.  Environments without an authorized native
  ;; symlink operation skip this target-specific evidence.
  (at! "symlink paths")
  (if (not c-symlink)
      (display "  symlink cases skipped: native symlink unavailable\n")
      (let ((backing-dir (string-append root "/symlink-backing-dir"))
            (dir-link (string-append root "/symlink-dir")))
        (nio-mkdir-atomic! backing-dir #o700)
        (if (not (= 0 (c-symlink backing-dir dir-link)))
            (display "  symlink cases skipped: symlink creation not permitted\n")
            (begin
              (let ((raised? #f))
                (guard (e (#t (set! raised? #t)))
                  (nio-create-directories! dir-link #o700))
                (check "target symlink to directory succeeds" (not raised?)))
              (let ((backing-file (string-append root "/symlink-backing-file"))
                    (file-link (string-append root "/symlink-file")))
                (write-text backing-file "symlink-file-sentinel")
                (check "file symlink fixture was created"
                       (= 0 (c-symlink backing-file file-link)))
                (let ((raised? #f))
                  (guard (e (#t (set! raised? #t)))
                    (nio-create-directories! file-link #o700))
                  (check "target symlink to file fails" raised?))
                (check "target symlink to file preserves its referent"
                       (string=? (read-text backing-file) "symlink-file-sentinel")))
              (let ((link (string-append root "/symlink-dangling"))
                    (target (string-append root "/missing-symlink-target")))
                (check "dangling symlink fixture was created"
                       (= 0 (c-symlink target link)))
                (let ((raised? #f))
                  (guard (e (#t (set! raised? #t)))
                    (nio-create-directories! link #o700))
                  (check "target dangling symlink fails" raised?))
                (check "dangling symlink target remains absent"
                       (not (file-exists? target))))
              (let ((backing (string-append root "/intermediate-backing"))
                    (link (string-append root "/intermediate-link")))
                (nio-mkdir-atomic! backing #o700)
                (check "intermediate directory symlink fixture was created"
                       (= 0 (c-symlink backing link)))
                (nio-create-directories! (string-append link "/child/grandchild") #o700)
                (check "intermediate symlink to directory is followed"
                       (file-directory? (string-append backing "/child/grandchild")))))))))

(define (workload)
  (test-same-chain-races!)
  (test-distinct-chains!)
  (test-existing-paths!)
  (test-non-eexist-failure!)
  (test-eexist-replacement-races!)
  (test-symlink-paths!)
  (if (null? failures) 'ok 'failed))

;; Publish the outcome only after the complete workload's finalizer has run.
;; The main thread does nothing but enforce the outer bound, so a wedged join or
;; native operation becomes a diagnostic failure instead of a stuck CI job.
(fork-thread
  (lambda ()
    (guard (e (#t (set-box! outcome (cons 'threw (render-condition e)))))
      (let ((result
             (dynamic-wind
               (lambda () (at! "workload"))
               workload
               (lambda ()
                 (at! "cleanup")
                 (aot-delete-tree root)))))
        (set-box! outcome result)))))

(let ((deadline (+ (now-secs) 60.0)))
  (let wait ()
    (pause-millis 10)
    (let ((o (unbox outcome)))
      (cond
        ((eq? o 'ok)
         (display "NIO-CREATE-DIRECTORIES-TEST OK\n")
         (exit 0))
        ((eq? o 'failed)
         (for-each (lambda (f) (printf "FAIL: ~a\n" f)) (reverse failures))
         (exit 1))
        ((and (pair? o) (eq? (car o) 'threw))
         (printf "NIO-CREATE-DIRECTORIES-TEST THREW in ~a: ~a\n"
                 (unbox phase) (cdr o))
         (exit 1))
        ((> (now-secs) deadline)
         (printf "NIO-CREATE-DIRECTORIES-TEST HUNG after 60s in ~a\n"
                 (unbox phase))
         (aot-delete-tree root)
         (exit 1))
        (else (wait))))))
