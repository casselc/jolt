(require '[jolt.host :as host])

;; Run alone, not alongside other allocating workers. These host counters are
;; separate snapshots; the wide margin is intentional. This is not a timer gate.
(defn allocated [] (+ (host/bytes-allocated) (host/gc-bytes)))
(let [n 1048576 input (byte-array n) encoder (java.util.Base64/getEncoder)]
  (.encodeToString encoder input)
  (System/gc)
  (let [before (allocated)
        output (.encodeToString encoder input)
        bytes (- (allocated) before)]
    (assert (= 1398104 (count output)))
    (assert (.endsWith output "AA=="))
    (assert (pos? bytes))
    ;; About 6.4 B/input byte on 64-bit Chez: input conversion plus UTF-32 text.
    ;; The old cons/reverse/filter path uses about 92 B/input byte.
    (assert (< bytes (* n 20)))
    (println :base64-allocation-check :passed :bytes-per-input-byte (/ (double bytes) n))))
