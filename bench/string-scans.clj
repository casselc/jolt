;; Non-gating causal benchmark for the String.indexOf hot paths. Compare exact
;; A/B compiler builds; do not turn wall-clock values into
;; CI thresholds. Each operation returns a consumed numeric value so the work
;; cannot disappear as a dead expression.

(defn now-ns [] (System/nanoTime))

(defn measure [label chars iterations f]
  (dotimes [_ 200] (f))
  (let [started (now-ns)
        checksum (loop [i 0, acc 0]
                   (if (= i iterations)
                     acc
                     (recur (inc i) (+ acc (long (f))))))
        elapsed (- (now-ns) started)
        rate (/ (* (double chars) iterations 1000000000.0) elapsed)]
    (printf "%-30s %10.1f Mchars/s  %8.2f ms  checksum=%d%n"
            label (/ rate 1000000.0) (/ elapsed 1000000.0) checksum)))

(def payload
  (apply str (repeat 1024 "{\"trace_id\":\"0123456789abcdef\",\"name\":\"span\",\"ok\":true}\n")))

(def iterations 2000)

(measure "indexOf char absent" (count payload) iterations
         #(.indexOf ^String payload (int \~)))
(measure "indexOf 1-char string absent" (count payload) iterations
         #(.indexOf ^String payload "~"))
(measure "indexOf multi-string absent" (count payload) iterations
         #(.indexOf ^String payload "~missing~"))
