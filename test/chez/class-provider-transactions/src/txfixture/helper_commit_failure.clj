(ns txfixture.helper-commit-failure)

(tx.fixture.control/helper-commit-failure-tick!)

(__register-class-ctor!
  "tx.HelperCommitFailure.Host"
  (fn [] :must-not-leak))

(__register-class-statics!
  "tx.HelperCommitFailure.Host"
  {42 (fn [] :invalid-member-key)})
