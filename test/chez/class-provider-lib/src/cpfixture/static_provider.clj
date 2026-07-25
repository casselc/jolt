(ns cpfixture.static-provider
  (:require [cpfixture.state :as state]))

(state/note-load! :static)

(__register-class-statics!
 "fixture.LazyStatics"
 {"VALUE" :lazy-static
  "loadCount" (fn [] (state/load-count :static))})
