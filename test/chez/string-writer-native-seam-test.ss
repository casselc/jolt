;; Compatibility of our private JSON setter with the 0.8.19+ builder layout.
(import (chezscheme))
(load "host/chez/run-gate-harness.ss")

(define writer (host-new "StringWriter"))
(define state (jhost-state writer))
(define owner (vector-ref state 2))
(define monitor (vector-ref state 4))
(gate-check "writer has synchronized owner" (and owner monitor #t) #t)
(sb-set! writer "before")
(define snapshot (sb-str* writer))
(gate-check "replacement visible through writer" snapshot "before")
(gate-check "replacement visible through getBuffer" (sb-str* owner) "before")
(sb-append*! owner "!")
(gate-check "buffer append visible through writer" (sb-str* writer) "before!")
(gate-check "old snapshot not modified" snapshot "before")
(sb-set! writer "")
(gate-check "clear resets length" (sb-length* writer) 0)
(gate-check "clear resets buffer text" (sb-str* owner) "")
(sb-set! writer "\x03bb;\x1f680;")
(gate-check "Unicode replacement" (sb-str* owner) "\x03bb;\x1f680;")
(gate-check "replacement preserves owner" (eq? owner (vector-ref state 2)) #t)
(gate-check "replacement preserves monitor" (eq? monitor (vector-ref state 4)) #t)
(gate-check "replacement preserves shared state" (eq? state (jhost-state owner)) #t)
(gate-check "compiled Appendable path and shared buffer"
  (jolt-final-str
    (jolt-compile-eval
      "(let [w (java.io.StringWriter.) b (.getBuffer w)] (.append ^Appendable w \"abc\") (.append b \"!\") [(str w) (identical? b (.getBuffer w))])"
      "user"))
  "[abc! true]")
(gate-summary "StringWriter native seam")
