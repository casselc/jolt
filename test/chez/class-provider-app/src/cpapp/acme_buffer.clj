(ns cpapp.acme-buffer
  (:import [com.acme ByteBuffer]))

(defn provider-value []
  [ByteBuffer/KIND (.value (ByteBuffer. :payload))])
