(ns cpfixture.ctor-provider
  (:require [cpfixture.catalog :as catalog]))

(catalog/note-load! :ctor)

(defn- lazy-ctor? [x]
  (and (jolt.host/table? x)
       (= :fixture/lazy-ctor (jolt.host/ref-get x :jolt/type))))

(__register-class-ctor!
 "fixture.LazyCtor"
 (fn [value]
   (let [x (jolt.host/tagged-table :fixture/lazy-ctor)]
     (jolt.host/ref-put! x :value value)
     x)))

(__register-class-methods!
 :fixture/lazy-ctor
 {"value" (fn [self] (jolt.host/ref-get self :value))})

(__register-instance-check!
 (fn [class-name value]
   (when (= class-name "fixture.LazyCtor")
     (lazy-ctor? value))))

(__register-class!
 lazy-ctor?
 (fn [_] "fixture.LazyCtor")
 (fn [_] ["fixture.LazyCtor" "LazyCtor" "java.lang.Object" "Object"]))
