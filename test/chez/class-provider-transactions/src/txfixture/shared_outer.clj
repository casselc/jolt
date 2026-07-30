(ns txfixture.shared-outer
  (:require [txfixture.shared-helper]))

(let [attempt (tx.fixture.control/shared-outer-tick!)]
  (tx.fixture.control/load-shared-nested!)
  (__register-class-ctor!
    "tx.SharedOuter.Host"
    (fn [] :shared-outer))
  (when (= attempt 1)
    (__register-class-statics!
      "tx.SharedOuter.Host"
      {42 (fn [] :invalid-member-key)})))
