(ns cpapp.acme-buffer
  (:require [cpapp.provider-protocol :as marker])
  (:import [com.acme ByteBuffer]))

(extend-protocol marker/ProviderMarker
  ByteBuffer
  (provider-marker [buffer]
    [:acme-protocol (.value buffer)]))

(defn provider-value []
  [ByteBuffer/KIND (.value (ByteBuffer. :payload))])

(defn protocol-value []
  (marker/provider-marker (ByteBuffer. :protocol-payload)))

(defn imported-instance? []
  (instance? ByteBuffer (ByteBuffer. :instance-payload)))
