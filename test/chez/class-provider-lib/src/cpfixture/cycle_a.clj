(ns cpfixture.cycle-a)

;; A -> B -> A.  The registry must report the provider path before the namespace
;; loader's ordinary require dedup can turn the recursion into a vague class miss.
(def from-b fixture.CycleB/VALUE)

(__register-class-statics! "fixture.CycleA" {"VALUE" :a})
