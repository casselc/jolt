(ns base64-encoder-test
  (:require [clojure.test :refer [deftest is run-tests]]
            [clojure.string :as str]))

(deftest rfc4648-known-vectors
  (doseq [[text encoded] [["" ""] ["f" "Zg=="] ["fo" "Zm8="] ["foo" "Zm9v"]
                          ["foob" "Zm9vYg=="] ["fooba" "Zm9vYmE="] ["foobar" "Zm9vYmFy"]]
          enc [(java.util.Base64/getEncoder) (java.util.Base64/getUrlEncoder)
               (java.util.Base64/getMimeEncoder)]]
    (let [input (.getBytes text "UTF-8")]
      (is (= encoded (.encodeToString enc input)))
      (is (= encoded (String. (.encode enc input) "UTF-8")))
      (is (= (str/replace encoded #"=+$" "") (.encodeToString (.withoutPadding enc) input)))
      (is (= text (String. input "UTF-8"))))))

(deftest alphabets-and-mime-wrapping
  (let [input (byte-array [-1 -2 -3])]
    (is (= "//79" (.encodeToString (java.util.Base64/getEncoder) input)))
    (is (= "__79" (.encodeToString (java.util.Base64/getUrlEncoder) input))))
  (let [input (.getBytes "foobar" "UTF-8")
        enc (java.util.Base64/getMimeEncoder 4 (byte-array [13 10]))]
    (is (= "Zm9v\r\nYmFy" (.encodeToString enc input)))
    (is (= "Zm9v\r\nYmFy" (.encodeToString (.withoutPadding enc) input)))))

(deftest bulk-lengths-cover-each-tail-and-input-isolation
  (doseq [n [0 1 2 3 4 5 31 32 33 65535 65536 65537]
          :let [input (byte-array n)
                complete (* 4 (quot n 3))
                tail (mod n 3)
                significant (+ complete (if (zero? tail) 0 (inc tail)))
                plain (apply str (repeat significant "A"))
                padded (str plain (apply str (repeat (if (zero? tail) 0 (- 3 tail)) "=")))]
          enc [(java.util.Base64/getEncoder) (java.util.Base64/getUrlEncoder)]]
    (is (= padded (.encodeToString enc input)))
    (is (= plain (.encodeToString (.withoutPadding enc) input)))
    (is (= padded (String. (.encode enc input) "UTF-8")))
    (is (every? zero? input))))

(let [result (run-tests 'base64-encoder-test)]
  (System/exit (if (zero? (+ (:fail result) (:error result))) 0 1)))
