;; Causal witness for interface-typed String/StringBuilder interop.
;;
;; Each cell performs identical work on the same concrete receiver; only the
;; helper's truthful portable hint changes.  Runs alternate A/B/B/A so drift
;; within a process is visible in the raw samples.  Build the same source with
;; the base and candidate compilers when qualifying a compiler change.
;;
;;   jolt build -m interface-interop -o /tmp/interface-interop --direct-link --opt
;;   /tmp/interface-interop
;;   clojure -Sdeps '{:paths ["bench"]}' -M -m interface-interop
(ns interface-interop)

(def payload
  (apply str (repeat 1024 "plain-\\\"-text-💡-")))

(defn scan-string [^String s]
  (let [n (.length s)]
    (loop [i 0 acc 0]
      (if (< i n)
        (recur (unchecked-inc i) (unchecked-add acc (int (.charAt s i))))
        acc))))

(defn scan-char-sequence [^CharSequence s]
  (let [n (.length s)]
    (loop [i 0 acc 0]
      (if (< i n)
        (recur (unchecked-inc i) (unchecked-add acc (int (.charAt s i))))
        acc))))

(defn append-builder [^StringBuilder out ^CharSequence s n]
  (dotimes [_ n] (.append out s))
  (.length out))

(defn append-appendable [^Appendable out ^CharSequence s n]
  (dotimes [_ n] (.append out s))
  (.length ^CharSequence out))

(defn append-range-builder [^StringBuilder out ^CharSequence s n]
  (dotimes [_ n] (.append out s 1 (dec (.length s))))
  (.length out))

(defn append-range-appendable [^Appendable out ^CharSequence s n]
  (dotimes [_ n] (.append out s 1 (dec (.length s))))
  (.length ^CharSequence out))

(defn timed [f]
  (let [t0 (System/nanoTime)
        answer (f)]
    [(- (System/nanoTime) t0) answer]))

(defn median [xs]
  (nth (vec (sort xs)) (quot (count xs) 2)))

(defn run-abba [a b rounds]
  (dotimes [_ 2] (a) (b))
  (loop [i 0 as [] bs [] digest 0]
    (if (= i rounds)
      {:a as :b bs :a-median-ns (median as) :b-median-ns (median bs)
       :digest digest}
      (let [[at0 av0] (timed a)
            [bt0 bv0] (timed b)
            [bt1 bv1] (timed b)
            [at1 av1] (timed a)]
        (recur (inc i) (conj as at0 at1) (conj bs bt0 bt1)
               (reduce unchecked-add digest [av0 bv0 bv1 av1]))))))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 10000)
        rounds 5
        scan (run-abba #(scan-string payload) #(scan-char-sequence payload) rounds)
        one (run-abba #(append-builder (StringBuilder.) "abcdefgh" n)
                      #(append-appendable (StringBuilder.) "abcdefgh" n) rounds)
        range (run-abba #(append-range-builder (StringBuilder.) "abcdefgh" n)
                        #(append-range-appendable (StringBuilder.) "abcdefgh" n) rounds)]
    (println {:operation :scan :concrete-vs-interface scan})
    (println {:operation :append-one :concrete-vs-interface one})
    (println {:operation :append-range :concrete-vs-interface range})))
