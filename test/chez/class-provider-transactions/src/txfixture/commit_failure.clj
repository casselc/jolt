(ns txfixture.commit-failure)

(tx.fixture.control/root-tick!)

(__register-class-ctor!
  "tx.RealCommitFailure.Host"
  (fn [] :must-not-leak))

;; A numeric static-member key is accepted as source data but rejected by the
;; runtime's string-keyed member table during this staged operation, forcing
;; rollback after the namespace loader itself returned successfully.
(__register-class-statics!
  "tx.RealCommitFailure.Host"
  {42 (fn [] :invalid-member-key)})
