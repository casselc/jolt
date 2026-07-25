(ns cpapp.java-buffer
  (:require [cpapp.provider-protocol :as marker])
  (:import [java.nio ByteBuffer]))

(def ^ByteBuffer tagged-buffer nil)

(extend-protocol marker/ProviderMarker
  ByteBuffer
  (provider-marker [buffer]
    [:java-protocol (.position buffer)]))

(defn provider-value []
  (let [b (ByteBuffer/allocate 4)]
    (.position b 2)
    (let [[_ position] (.providerMarker b)]
      [:java-provider position])))

(defn protocol-value []
  (let [b (ByteBuffer/allocate 4)]
    (.position b 3)
    (marker/provider-marker b)))

(defn imported-instance? []
  (instance? ByteBuffer (ByteBuffer/allocate 1)))

(defn canonical-import-forms []
  [(str (first `(ByteBuffer. 1)))
   (str (first `(ByteBuffer/allocate 1)))
   (str (second `(new ByteBuffer 1)))
   (str `ByteBuffer)
   (str (:tag (meta #'tagged-buffer)))])
