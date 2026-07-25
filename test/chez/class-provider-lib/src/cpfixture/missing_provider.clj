(ns cpfixture.missing-provider
  (:require [cpfixture.state :as state]))

;; Deliberately loads successfully without registering fixture.MissingAfterLoad.
;; Repeated misses must not reload this namespace or recurse.
(state/note-load! :missing)
