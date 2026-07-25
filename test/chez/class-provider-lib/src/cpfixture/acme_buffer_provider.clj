(ns cpfixture.acme-buffer-provider
  (:require [cpfixture.state :as state]))

(state/note-load! :acme-buffer)

(defn- acme-buffer? [x]
  (and (jolt.host/table? x)
       (= :fixture/acme-buffer (jolt.host/ref-get x :jolt/type))))

(__register-class-statics!
 "com.acme.ByteBuffer"
 {"KIND" :acme})

(__register-class-ctor!
 "com.acme.ByteBuffer"
 (fn [value]
   (let [x (jolt.host/tagged-table :fixture/acme-buffer)]
     (jolt.host/ref-put! x :value value)
     x)))

(__register-class-methods!
 :fixture/acme-buffer
 {"value" (fn [self] (jolt.host/ref-get self :value))})

(__register-class!
 acme-buffer?
 (fn [_] "com.acme.ByteBuffer")
 (fn [_] ["com.acme.ByteBuffer" "java.lang.Object"]))
