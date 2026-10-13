(ns base64-direct-output-test
  (:require [clojure.test :refer [deftest is]] [clojure.string :as str])
  (:import [java.util Base64]))

(defn- unsigned [b] (bit-and 255 b))
(defn- fixture-bytes [n]
  (byte-array (map #(let [b (mod (+ 11 (* 37 %)) 256)]
                     (byte (if (> b 127) (- b 256) b))) (range n))))
(defn- reference-encode [input alphabet pad?]
  ;; Independent small-test oracle. Allocation here is intentionally not the
  ;; implementation under test; production uses one directly filled String.
  (apply str
    (mapcat
      (fn [chunk]
        (let [[a b c] chunk]
          (cond-> [(nth alphabet (bit-shift-right a 2))
                   (nth alphabet (bit-or (bit-shift-left (bit-and a 3) 4)
                                        (bit-shift-right (or b 0) 4)))]
            b (conj (nth alphabet (bit-or (bit-shift-left (bit-and b 15) 2)
                                         (bit-shift-right (or c 0) 6))))
            (and (nil? b) pad?) (conj \=)
            c (conj (nth alphabet (bit-and c 63)))
            (and (nil? c) pad?) (conj \=))))
      (partition-all 3 (map unsigned input)))))

(deftest known-rfc4648-vectors
  (doseq [[input expected] [["" ""] ["f" "Zg=="] ["fo" "Zm8="] ["foo" "Zm9v"]
                            ["foob" "Zm9vYg=="] ["fooba" "Zm9vYmE="] ["foobar" "Zm9vYmFy"]]]
    (is (= expected (.encodeToString (Base64/getEncoder) (.getBytes input "UTF-8"))))))

(deftest basic-url-padding-and-byte-result-parity
  (doseq [n [0 1 2 3 4 5 55 56 57 58 59 76 77 255 256 257 1024 4097]
          url? [false true] pad? [false true]]
    (let [input (fixture-bytes n)
          alphabet (if url? "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
                           "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
          expected (reference-encode input alphabet pad?)
          encoder (if url? (Base64/getUrlEncoder) (Base64/getEncoder))
          encoder (if pad? encoder (.withoutPadding encoder))]
      (is (= expected (.encodeToString encoder input)))
      (is (= expected (String. (.encode encoder input) "UTF-8"))))))

(deftest mime-line-boundaries
  (doseq [n [0 1 57 58 114 115 256] width [0 4 8 76]]
    (let [input (fixture-bytes n)
          expected (reference-encode input "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" true)
          wrapped (if (zero? width) expected
                    (str/join "~" (map #(apply str %) (partition-all width expected))))]
      (is (= wrapped (.encodeToString (Base64/getMimeEncoder width (.getBytes "~" "UTF-8")) input))))))

(let [result (clojure.test/run-tests 'base64-direct-output-test)]
  (System/exit (if (zero? (+ (:fail result) (:error result))) 0 1)))
