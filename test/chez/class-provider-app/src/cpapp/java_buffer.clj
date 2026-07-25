(ns cpapp.java-buffer
  (:import [java.nio ByteBuffer]))

(def ^ByteBuffer tagged-buffer nil)

(defn provider-value []
  (let [b (ByteBuffer/allocate 4)]
    (.position b 2)
    (let [[_ position] (.providerMarker b)]
      [:java-provider position])))

(defn canonical-import-forms []
  [(str (first `(ByteBuffer. 1)))
   (str (first `(ByteBuffer/allocate 1)))
   (str (second `(new ByteBuffer 1)))
   (str `ByteBuffer)
   (str (:tag (meta #'tagged-buffer)))])
