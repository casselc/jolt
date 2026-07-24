(ns cpfixture.missing-provider
  (:require [cpfixture.catalog :as catalog]))

;; Deliberately loads successfully without registering fixture.MissingAfterLoad.
;; Repeated misses must not reload this namespace or recurse.
(catalog/note-load! :missing)
