(ns txfixture.shared-nested
  (:require [txfixture.shared-helper]))

(tx.fixture.control/shared-nested-tick!)
(tx.fixture.control/observe-shared-helper!)

(__register-class-ctor!
  "tx.SharedNested.Host"
  (fn [] :shared-nested))
