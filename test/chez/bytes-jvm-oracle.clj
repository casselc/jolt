;; bytes-jvm-oracle.clj — generate the JVM-sourced expecteds for jolt.bytes.
;;
;; Run on the JVM, NOT on jolt:
;;   clojure -M test/chez/bytes-jvm-oracle.clj > test/chez/bytes-jvm-oracle.edn
;;
;; The fixture it prints is checked in, so the differential gate
;; (test/chez/bytes_differential_test.clj) runs on Chez with no JVM present. The
;; JVM side is the independent implementation: java.nio.ByteBuffer lays out the
;; integers, Double/doubleToRawLongBits and Float/floatToRawIntBits carry the
;; float bits, and System/arraycopy performs the overlapping moves.
;;
;; Everything here is deterministic — an LCG with fixed constants, fixed bands —
;; so regenerating on another machine reproduces the file byte for byte.

(import '[java.nio ByteBuffer ByteOrder])

(def ^:private lcg (atom 1))
(defn- lcg-next! []
  (swap! lcg (fn [s] (unchecked-add (unchecked-multiply s 6364136223846793005) 1442695040888963407))))
(defn- reset-lcg! [] (reset! lcg 1))

(defn- bands
  "Every power-of-two edge in `bits`, +/- 2, clamped to the signed domain."
  [bits]
  (let [lo (if (= bits 64) Long/MIN_VALUE (- (bit-shift-left 1 (dec bits))))
        hi (if (= bits 64) Long/MAX_VALUE (dec (bit-shift-left 1 (dec bits))))]
    (->> (concat [lo (inc lo) (+ lo 2) hi (dec hi) (- hi 2) 0 1 -1 2 -2]
                 (mapcat (fn [k]
                           (let [e (bit-shift-left 1 k)]
                             [(- e 2) (dec e) e (inc e) (+ e 2)
                              (- (- e 2)) (- (dec e)) (- e) (- (inc e)) (- (+ e 2))]))
                         (range 0 (dec bits))))
         (filter #(and (>= % lo) (<= % hi)))
         distinct
         sort
         vec)))

(defn- corpus
  "A deterministic sample of `n` values narrowed into `bits`."
  [bits n]
  (reset-lcg!)
  (vec (repeatedly n (fn []
                       (let [v (lcg-next!)]
                         (case bits
                           8 (unchecked-byte v)
                           16 (unchecked-short v)
                           32 (unchecked-int v)
                           64 v))))))

(defn- put-bytes
  "The bytes the JVM writes for `v` at `bits`/`order`, as 0..255."
  [bits order v]
  (let [n (quot bits 8)
        bb (doto (ByteBuffer/allocate n)
             (.order (if (= order :le) ByteOrder/LITTLE_ENDIAN ByteOrder/BIG_ENDIAN)))]
    (case bits
      8 (.put bb (byte v))
      16 (.putShort bb (short v))
      32 (.putInt bb (int v))
      64 (.putLong bb (long v)))
    (mapv #(bit-and % 0xFF) (.array bb))))

(defn- unsigned-str [bits v]
  (case bits
    8 (str (bit-and v 0xFF))
    16 (str (bit-and v 0xFFFF))
    32 (Integer/toUnsignedString (int v))
    64 (Long/toUnsignedString (long v))))

(defn- int-rows [bits]
  (let [vals (distinct (concat (bands bits) (corpus bits 128)))]
    (vec (for [v vals
               order (if (= bits 8) [:be] [:be :le])]
           {:width bits
            :endian order
            :signed (str v)
            :unsigned (unsigned-str bits v)
            :bytes (put-bytes bits order v)}))))

;; Float patterns: the structural cases plus a deterministic sample. Bits are
;; carried as unsigned decimal strings so no reader has to hold 0xFFFF… in a
;; signed long.
(def ^:private f64-bit-patterns
  (concat [0x0000000000000000 (unchecked-long 0x8000000000000000)
           0x3FF0000000000000 (unchecked-long 0xBFF0000000000000)
           0x7FF0000000000000 (unchecked-long 0xFFF0000000000000)
           0x7FF8000000000000 0x7FF8000ABCDEF123
           (unchecked-long 0xFFF8000ABCDEF123)
           0x7FF0000000000001
           0x0000000000000001 0x000FFFFFFFFFFFFF
           0x0010000000000000 0x7FEFFFFFFFFFFFFF]
          (corpus 64 128)))

(def ^:private f32-bit-patterns
  (concat [0x00000000 (unchecked-int 0x80000000)
           0x3F800000 (unchecked-int 0xBF800000)
           0x7F800000 (unchecked-int 0xFF800000)
           0x7FC00000 0x7FC00ABC (unchecked-int 0xFFC00ABC)
           0x7F800001 0x7FA00000
           0x00000001 0x007FFFFF 0x00800000 0x7F7FFFFF]
          (corpus 32 128)))

(defn- f64-rows []
  (vec (for [bits f64-bit-patterns]
         (let [d (Double/longBitsToDouble bits)]
           {:bits (Long/toUnsignedString bits)
            ;; The JVM's own bits -> double -> bits round trip. `raw` keeps a
            ;; signalling NaN intact; this is the reference the Chez f64 path is
            ;; expected to match exactly.
            :round-trip (Long/toUnsignedString (Double/doubleToRawLongBits d))
            :bytes-be (put-bytes 64 :be bits)
            :bytes-le (put-bytes 64 :le bits)}))))

(defn- f32-rows []
  (vec (for [bits f32-bit-patterns]
         (let [f (Float/intBitsToFloat bits)]
           {:bits (Integer/toUnsignedString bits)
            ;; Float/intBitsToFloat + floatToRawIntBits is a raw bit move on a
            ;; real 32-bit float type, so the JVM preserves a signalling NaN
            ;; here. A host whose only float type is binary64 cannot; the
            ;; differential records both and the checker states which it expects.
            :round-trip-raw (Integer/toUnsignedString (Float/floatToRawIntBits f))
            ;; floatToIntBits (non-raw) collapses every NaN to the canonical one.
            :round-trip-canonical (Integer/toUnsignedString (Float/floatToIntBits f))
            ;; The double the JVM gets by widening this float — the value a
            ;; binary64-only host must produce — and its bits.
            :widened-f64-bits (Long/toUnsignedString (Double/doubleToRawLongBits (double f)))
            :bytes-be (put-bytes 32 :be bits)
            :bytes-le (put-bytes 32 :le bits)}))))

;; Overlapping moves through System/arraycopy, which is memmove-correct. A
;; memcpy-shaped implementation disagrees on the forward-overlap rows.
(defn- copy-rows []
  (let [base (byte-array (map byte [1 2 3 4 5 6 7 8]))]
    (vec (for [s (range 0 9), d (range 0 9), n (range 0 (inc (min (- 8 s) (- 8 d))))]
           (let [a (java.util.Arrays/copyOf base 8)]
             (System/arraycopy a s a d n)
             {:before (mapv #(bit-and % 0xFF) base)
              :src s :dst d :size n
              :after (mapv #(bit-and % 0xFF) a)})))))

(defn -main []
  (binding [*print-length* nil *print-level* nil]
    (prn {:schema :jolt.bytes/jvm-differential-v1
          :generator {:tool "test/chez/bytes-jvm-oracle.clj"
                      :command "clojure -M test/chez/bytes-jvm-oracle.clj"
                      :java-version (System/getProperty "java.version")
                      :clojure-version (clojure-version)}
          :ints (vec (mapcat int-rows [8 16 32 64]))
          :f64 (f64-rows)
          :f32 (f32-rows)
          :copy (copy-rows)})))

(-main)
