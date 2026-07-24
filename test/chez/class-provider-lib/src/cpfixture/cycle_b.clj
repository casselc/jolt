(ns cpfixture.cycle-b)

(def from-a fixture.CycleA/VALUE)

(__register-class-statics! "fixture.CycleB" {"VALUE" :b})
