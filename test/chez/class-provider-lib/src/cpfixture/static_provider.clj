(ns cpfixture.static-provider
  (:require [cpfixture.catalog :as catalog]))

(catalog/note-load! :static)

(__register-class-statics!
 "fixture.LazyStatics"
 {"VALUE" :lazy-static
  "loadCount" (fn [] (catalog/load-count :static))})
