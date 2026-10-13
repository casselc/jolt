(import (chezscheme))
(load "host/chez/run-gate-harness.ss")
(define writer (host-new "StringWriter"))
(define buffer (vector-ref (jhost-state writer) 2))
(define attached (vector-ref (jhost-state buffer) 4))
(gate-check "buffer lookup returns attached monitor" (eq? attached (object-monitor buffer)) #t)
(gate-check "buffer not inserted into weak monitor table"
            (hashtable-ref monitor-table buffer #f) #f)
(gate-check "writer object monitor differs from its buffer"
            (eq? (object-monitor writer) attached) #f)
(gate-check "writer object monitor identity stable"
            (eq? (object-monitor writer) (object-monitor writer)) #t)
(jolt-call-with-monitor (object-monitor buffer)
  (lambda ()
    (gate-check "direct buffer lock owns writer method monitor"
                (monitor-held-by-self? attached) #t)
    (sb-append*! writer "before")
    (monitor-object-wait! attached 1)
    (gate-check "wait restores buffer monitor ownership"
                (monitor-held-by-self? (object-monitor buffer)) #t)
    (gate-check "wait restores direct lock depth" (monitor-self-count attached) 1)))
(gate-check "writer and buffer share text" (sb-str* buffer) "before")
(sb-set! writer "after")
(gate-check "replacement preserves monitor identity"
            (eq? attached (object-monitor buffer)) #t)
(gate-check "replacement visible through buffer" (sb-str* buffer) "after")
(define builder (host-new "StringBuilder"))
(gate-check "plain builder retains ordinary table monitor"
            (eq? (object-monitor builder) (hashtable-ref monitor-table builder #f)) #t)
(gate-check "plain builder stays unsynchronized internally"
            (vector-ref (jhost-state builder) 4) #f)
(define unknown (make-jhost 'unknown-kind #f))
(gate-check "unknown native host retains generic Object locking"
            (eq? (object-monitor unknown) (object-monitor unknown)) #t)
(define short-buffer (make-jhost "string-buffer" (vector #f)))
(gate-check "non-owned buffer shape retains generic Object locking"
            (eq? (object-monitor short-buffer)
                 (hashtable-ref monitor-table short-buffer #f)) #t)

;; Real contention: public buffer locking must exclude writer method appends.
(define mu (make-mutex))
(define done #f)
(define child-error #f)
(monitor-enter! (object-monitor buffer))
(fork-thread
  (lambda ()
    (guard (e (#t (with-mutex mu (set! child-error e))))
      (sb-append*! writer "-child"))
    (with-mutex mu (set! done #t))))
(define (await label ready?)
  (let ((start (current-time 'time-monotonic)))
    (let loop ()
      (unless (ready?)
        (when (> (time-second (time-difference (current-time 'time-monotonic) start)) 5)
          (error 'attached-monitor label))
        (sleep (make-time 'time-duration 1000000 0))
        (loop)))))
(await "writer append did not contend on buffer monitor"
       (lambda () (jolt-with-mutex (monitor-backing-mutex! attached)
                    (and (vector-ref attached monitor-i-cv) #t))))
(gate-check "writer append blocked before buffer unlock" (with-mutex mu done) #f)
(monitor-exit! (object-monitor buffer))
(await "writer append lost release wake" (lambda () (with-mutex mu done)))
(gate-check "writer append completed without exception" child-error #f)
(gate-check "writer append completed once after release" (sb-str* buffer) "after-child")
(gate-summary "attached StringBuffer monitor")
