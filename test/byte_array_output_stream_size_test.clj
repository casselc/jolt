(ns byte-array-output-stream-size-test
  (:require [clojure.test :as t :refer [deftest is]]
            [jolt.scheme :as scheme]))

(deftest size-tracks-buffered-writes-and-extracted-prefix
  (let [out (java.io.ByteArrayOutputStream.)]
    (is (= 0 (.size out)))
    (.write out (byte-array [1 2 3]))
    (is (= 3 (.size out)))
    (is (= [1 2 3] (vec (.toByteArray out))))
    (.write out 255)
    (is (= 4 (.size out)))
    (is (= 4 (.size out)))
    (is (= [1 2 3 -1] (vec (.toByteArray out))))
    (.reset out)
    (is (= 0 (.size out)))
    (.write out 7)
    (.close out)
    (is (= 1 (.size out)))
    (.write out 8)
    (is (= 2 (.size out)))
    (is (= [7 8] (vec (.toByteArray out))))))

(deftest size-does-not-extract-or-replace-accumulator
  ;; Deterministic mechanism control, not a timing threshold. The previous
  ;; implementation calls extract and replaces acc when more bytes are pending.
  (let [check
        (scheme/eval-string
         "(lambda ()
            (let* ((out (host-new \"ByteArrayOutputStream\"))
                   (st (jhost-state out)) (original (vector-ref st 1))
                   (calls 0))
              (vector-set! st 1 (lambda () (set! calls (+ calls 1)) (original)))
              (put-u8 (out-stream-port out) 1)
              (baos-bytes out)
              (set! calls 0)
              (let ((acc (vector-ref st 2)))
                (do ((i 0 (+ i 1))) ((= i 512))
                  (put-u8 (out-stream-port out) 2)
                  (unless (= (+ i 2)
                             (jnum->exact (record-method-dispatch out \"size\" jolt-nil)))
                    (error 'size \"wrong size\")))
                (and (= calls 0) (eq? acc (vector-ref st 2))))))")]
    (is (true? (check)))))

(deftest output-stream-writer-flush-and-size-preserve-utf8
  (let [bytes (java.io.ByteArrayOutputStream.)
        writer (java.io.OutputStreamWriter. bytes "UTF-8")]
    (.append writer "β😀")
    (.flush writer)
    (is (= 6 (.size bytes)))
    (let [snapshot (.toByteArray bytes)]
      (.append writer "x")
      (.flush writer)
      (is (= 7 (.size bytes)))
      (is (= "β😀" (String. snapshot "UTF-8"))))
    (.close writer)
    (is (= "β😀x" (.toString bytes "UTF-8")))
    (is (= 7 (.size bytes)))))

(deftest stock-writer-borrows-blocks-but-overrides-stay-live
  (let [check
        (scheme/eval-string
         "(lambda (override?)
            (let* ((table (hashtable-ref host-methods-tbl \"out-stream\" #f))
                   (original (hashtable-ref table \"write\" #f))
                   (old-array na-byte-array) (arrays 0) (writes 0)
                   (out (host-new \"ByteArrayOutputStream\"))
                   (writer (host-new \"OutputStreamWriter\" out)))
              (dynamic-wind
                (lambda ()
                  (set! na-byte-array
                    (lambda (x . rest) (set! arrays (+ arrays 1)) (apply old-array x rest)))
                  (when override?
                    (register-host-methods! \"out-stream\"
                      (list (cons \"write\"
                        (lambda (self x . rest)
                          (set! writes (+ writes 1)) (apply original self x rest)))))))
                (lambda ()
                  (put-string (char-writer-port writer) \"β😀x\")
                  (flush-output-port (char-writer-port writer))
                  (and (bytevector=? (baos-bytes out) (string->utf8 \"β😀x\"))
                       (if override? (and (= arrays 1) (= writes 1))
                         (and (= arrays 0) (= writes 0)))))
                (lambda ()
                  (set! na-byte-array old-array)
                  (hashtable-set! table \"write\" original)))))")]
    (is (true? (check false)))
    (is (true? (check true)))))

(defn -main [& _]
  (let [{:keys [fail error]} (t/run-tests 'byte-array-output-stream-size-test)]
    (System/exit (if (zero? (+ fail error)) 0 1))))
