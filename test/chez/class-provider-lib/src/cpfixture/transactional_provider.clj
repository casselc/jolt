(ns cpfixture.transactional-provider
  (:require [cpfixture.state :as state]))

(state/note-load! :transactional)

;; The first attempt reaches commit with one valid mutation followed by an
;; invalid hierarchy mutation. Commit must roll the static back and leave the
;; namespace retryable. The second evaluation omits the invalid mutation and
;; installs the requested class.
(__register-class-statics!
 "fixture.TransactionalLeak"
 {"VALUE" :must-not-leak})

(when (= 1 (state/load-count :transactional))
  (jolt.host/register-class-supers! nil []))

(__register-class-statics!
 "fixture.TransactionalRetry"
 {"VALUE" :recovered})
