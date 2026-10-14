(ns byte-array-input-stream-view-test
  (:require [clojure.test :as t :refer [deftest is]]))

(deftest source-is-live-and-close-is-a-noop
  (let [a (byte-array [1 2 3]) input (java.io.ByteArrayInputStream. a)]
    (aset-byte a 0 9)
    (is (= 9 (.read input)))
    (aset-byte a 1 8)
    (is (= 8 (.read input)))
    (.close input)
    (.close input)
    (is (= 1 (.available input)))
    (is (= 3 (.read input)))
    (is (= -1 (.read input)))
    (.reset input)
    (is (= 9 (.read input)))))

(deftest bounded-view-mark-and-skip
  (let [a (byte-array [10 11 12 13 14])
        input (java.io.ByteArrayInputStream. a 1 3)]
    (is (= 3 (.available input)))
    (is (.markSupported input))
    (is (= 11 (.read input)))
    (.mark input 0)
    (aset-byte a 2 99)
    (is (= 99 (.read input)))
    (is (= 0 (.skip input -7)))
    (is (= 1 (.skip input 100)))
    (is (= 0 (.available input)))
    (is (= -1 (.read input)))
    (.reset input)
    (is (= 2 (.available input)))
    (is (= [99 13] (vec (.readAllBytes input))))))

(deftest range-is-clamped-and-empty-is-readable-after-close
  (let [input (java.io.ByteArrayInputStream. (byte-array [1 2 3]) 1 100)]
    (is (= [2 3] (vec (.readAllBytes input)))))
  (let [input (java.io.ByteArrayInputStream. (byte-array 0))]
    (.close input)
    (is (= 0 (.available input)))
    (is (= -1 (.read input)))
    (is (= [] (vec (.readNBytes input 10))))))

(deftest bulk-copies-only-the-requested-range
  (let [a (byte-array 131073) input (java.io.ByteArrayInputStream. a)
        out (byte-array 65538)]
    (aset-byte a 0 -1)
    (aset-byte a 65535 -128)
    (is (= 65536 (.read input out 1 65536)))
    (is (= 0 (aget out 0)))
    (is (= -1 (aget out 1)))
    (is (= -128 (aget out 65536)))
    (is (= 0 (aget out 65537)))
    (aset-byte a 65536 42)
    (is (= 42 (.read input)))
    (is (= 65536 (.available input)))))

(deftest decoded-reader-and-transfer-still-work
  (let [input (java.io.ByteArrayInputStream. (.getBytes "β😀" "UTF-8"))
        reader (java.io.InputStreamReader. input "UTF-8")]
    (is (= "β😀" (slurp reader))))
  (let [input (java.io.ByteArrayInputStream. (byte-array [1 -1 3]))
        output (java.io.ByteArrayOutputStream.)]
    (is (= 3 (.transferTo input output)))
    (is (= [1 -1 3] (vec (.toByteArray output))))))

(defn -main [& _]
  (let [r (t/run-tests 'byte-array-input-stream-view-test)]
    (System/exit (if (zero? (+ (:fail r) (:error r))) 0 1))))
