(ns txfixture.shared-helper)

(tx.fixture.control/shared-helper-tick!)

(__register-class-ctor!
  "tx.SharedHelper.Host"
  (fn [] :shared-helper))
