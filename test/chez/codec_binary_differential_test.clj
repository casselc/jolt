;; codec_binary_differential_test.clj — jolt.codec.binary against JVM-sourced expecteds.
;;
;;   jolt run test/chez/codec_binary_differential_test.clj
;;
;; test/chez/codec-binary-jvm-oracle.edn is produced on the JVM by
;; test/chez/codec-binary-jvm-oracle.clj (java.nio.ByteBuffer, Double/doubleToRawLongBits,
;; Float/floatToRawIntBits, System/arraycopy) and checked in, so this gate needs
;; no JVM. The comparison is on BYTES and RAW BITS, never on decoded numeric
;; values alone: a NaN compares equal to nothing and -0.0 compares equal to 0.0,
;; so a numeric check would pass over exactly the cases worth testing.

(ns bytes-differential-test
  (:require [clojure.edn :as edn]
            [jolt.codec.binary :as b]))

(def ^:private state (atom {:checks 0 :failures []}))

(defn- check! [label pred]
  (swap! state (fn [s]
                 (-> s
                     (update :checks inc)
                     (cond-> (not pred) (update :failures conj label))))))

(defn- bytes-vec [a] (mapv #(bit-and % 0xFF) (seq a)))

(defn- num [s] (edn/read-string s))

(def ^:private fixture (edn/read-string (slurp "test/chez/codec-binary-jvm-oracle.edn")))

(assert (= :jolt.codec.binary/jvm-differential-v1 (:schema fixture)) "unexpected fixture schema")

;; --- integers ---------------------------------------------------------------
;; For every row: writing the JVM's signed value must produce the JVM's bytes,
;; and reading those bytes back must produce both the JVM's signed value and the
;; JVM's unsigned value (which above 2^63 the JVM itself can only name as a
;; string).

(def ^:private int-ops
  {[8 :be]  {:put-i b/put-i8!    :get-i b/get-i8    :get-u b/get-u8}
   [16 :be] {:put-i b/put-i16-be! :get-i b/get-i16-be :get-u b/get-u16-be :put-u b/put-u16-be!}
   [16 :le] {:put-i b/put-i16-le! :get-i b/get-i16-le :get-u b/get-u16-le :put-u b/put-u16-le!}
   [32 :be] {:put-i b/put-i32-be! :get-i b/get-i32-be :get-u b/get-u32-be :put-u b/put-u32-be!}
   [32 :le] {:put-i b/put-i32-le! :get-i b/get-i32-le :get-u b/get-u32-le :put-u b/put-u32-le!}
   [64 :be] {:put-i b/put-i64-be! :get-i b/get-i64-be :get-u b/get-u64-be :put-u b/put-u64-be!}
   [64 :le] {:put-i b/put-i64-le! :get-i b/get-i64-le :get-u b/get-u64-le :put-u b/put-u64-le!}})

(doseq [{:keys [width endian signed unsigned bytes]} (:ints fixture)]
  (let [ops (get int-ops [width endian])
        sv (num signed)
        uv (num unsigned)
        n (quot width 8)
        a (byte-array n)
        label (str "int u" width " " (name endian) " " signed)]
    ((:put-i ops) a 0 sv)
    (check! (str label " / signed write matches JVM bytes") (= bytes (bytes-vec a)))
    (check! (str label " / signed read-back") (= sv ((:get-i ops) a 0)))
    (check! (str label " / unsigned read-back") (= uv ((:get-u ops) a 0)))
    (when-let [put-u (:put-u ops)]
      (let [c (byte-array n)]
        (put-u c 0 uv)
        (check! (str label " / unsigned write matches JVM bytes") (= bytes (bytes-vec c)))))))

;; --- f64 --------------------------------------------------------------------
;; A Chez flonum IS the binary64 pattern, exactly as a JVM double is, so this
;; lane must agree on every pattern including signalling NaNs.

(doseq [{:keys [bits round-trip bytes-be bytes-le]} (:f64 fixture)]
  (let [bv (num bits)
        label (str "f64 bits " bits)
        x (b/bits->f64 bv)]
    (check! (str label " / raw round trip matches the JVM") (= (num round-trip) (b/f64-bits x)))
    (let [a (byte-array 8)]
      (b/put-f64-be! a 0 x)
      (check! (str label " / big-endian bytes match the JVM") (= bytes-be (bytes-vec a))))
    (let [a (byte-array 8)]
      (b/put-f64-le! a 0 x)
      (check! (str label " / little-endian bytes match the JVM") (= bytes-le (bytes-vec a))))
    ;; and reading the JVM's own byte layout back yields the same bits
    (let [a (byte-array 8)]
      (doseq [i (range 8)] (b/put-u8! a i (nth bytes-be i)))
      (check! (str label " / read back from JVM bytes") (= bv (b/f64-bits (b/get-f64-be a 0)))))))

;; --- f32 --------------------------------------------------------------------
;; The JVM has a native 32-bit float type, so Float/intBitsToFloat is a raw bit
;; move that preserves a signalling NaN. Jolt's only float type is binary64, so
;; there is no raw f32 pair to compare against; what jolt.codec.binary offers is
;; get-f32-*/put-f32-*!, which WIDEN on read and NARROW on write.
;;
;; The JVM's own widening of the same float is the reference for what a read must
;; produce — :widened-f64-bits — and it agrees on every pattern, signalling NaNs
;; included. The consequence is asserted rather than hidden: a read/write pair
;; through the numeric accessors reproduces the wire bytes for every pattern
;; except a signalling NaN, which comes back quieted on the JVM and on Chez
;; alike. A pattern that must survive verbatim travels as u32 instead, which the
;; last check in each row exercises over the whole corpus.

(defn- f32-signalling? [bits]
  (and (= (bit-and bits 0x7F800000) 0x7F800000)
       (not= (bit-and bits 0x007FFFFF) 0)
       (= (bit-and bits 0x00400000) 0)))

(doseq [{:keys [bits round-trip-raw widened-f64-bits bytes-be bytes-le]} (:f32 fixture)]
  (let [bv (num bits)
        label (str "f32 bits " bits)
        ;; the value the wire pattern denotes, obtained the only way the API now
        ;; allows: read the four bytes as a number, which widens exactly.
        a (byte-array 4)
        _ (b/put-u32-be! a 0 bv)
        x (b/get-f32-be a 0)
        ;; what the pattern becomes after a widen/narrow pair
        narrowed (if (f32-signalling? bv) (bit-or bv 0x00400000) bv)]
    (check! (str label " / widening matches the JVM's own widening")
            (= (num widened-f64-bits) (b/f64-bits x)))
    (check! (str label " / little-endian read widens identically")
            (let [c (byte-array 4)]
              (b/put-u32-le! c 0 bv)
              (= (num widened-f64-bits) (b/f64-bits (b/get-f32-le c 0)))))
    (check! (str label " / non-signalling patterns match the JVM raw round trip")
            (or (f32-signalling? bv)
                (let [c (byte-array 4)]
                  (b/put-f32-be! c 0 x)
                  (= (num round-trip-raw) (b/get-u32-be c 0)))))
    (let [expected-be (if (f32-signalling? bv)
                        (let [c (byte-array 4)] (b/put-u32-be! c 0 narrowed) (bytes-vec c))
                        bytes-be)
          c (byte-array 4)]
      (b/put-f32-be! c 0 x)
      (check! (str label " / big-endian bytes") (= expected-be (bytes-vec c))))
    (let [expected-le (if (f32-signalling? bv)
                        (let [c (byte-array 4)] (b/put-u32-le! c 0 narrowed) (bytes-vec c))
                        bytes-le)
          c (byte-array 4)]
      (b/put-f32-le! c 0 x)
      (check! (str label " / little-endian bytes") (= expected-le (bytes-vec c))))
    ;; the raw u32 path carries any pattern verbatim, signalling included
    (check! (str label " / u32 path preserves the pattern verbatim")
            (= bv (b/get-u32-be a 0)))))

;; The withdrawn names must be genuinely absent through the public require, not
;; merely undocumented — `resolve` returns the var only when it is defined.
(check! "jolt.codec.binary publishes no f32 raw-bit pair"
        (and (nil? (resolve 'b/f32-bits))
             (nil? (resolve 'b/bits->f32))))
(check! "the same probe still finds the retained f64 pair"
        (and (some? (resolve 'b/f64-bits))
             (some? (resolve 'b/bits->f64))))

;; --- overlapping copy -------------------------------------------------------
;; Replay every System/arraycopy row. The forward-overlap rows are the ones a
;; memcpy-shaped implementation gets wrong.

(doseq [{:keys [before src dst size after]} (:copy fixture)]
  (let [a (byte-array (count before))]
    (doseq [i (range (count before))] (b/put-u8! a i (nth before i)))
    (b/copy! a src a dst size)
    (check! (str "copy! src=" src " dst=" dst " size=" size " matches System/arraycopy")
            (= after (bytes-vec a)))))

;; ----------------------------------------------------------------------------

(let [{:keys [checks failures]} @state]
  (doseq [f (take 20 failures)] (println "FAIL:" f))
  (println (str "bytes differential vs JVM " (get-in fixture [:generator :java-version])
                " / Clojure " (get-in fixture [:generator :clojure-version])
                ": " checks " checks, " (count failures) " failures"))
  (System/exit (if (seq failures) 1 0)))
