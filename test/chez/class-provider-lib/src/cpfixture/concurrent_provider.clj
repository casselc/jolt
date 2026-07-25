(ns cpfixture.concurrent-provider
  (:require [cpfixture.state :as state]))

(state/note-load! :concurrent)

;; Keep the attempt open long enough for the smoke test to join it through the
;; stable-provider boundary.  The registration itself remains staged until this
;; namespace returns successfully.
(Thread/sleep 200)

(__register-class-statics!
 "fixture.Concurrent"
 {"VALUE" :concurrent})
