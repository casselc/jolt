(require 'jolt.deps)
(import [fixture LazyStatics]
        [nested Deep])

(jolt.deps/add-deps
 {:jolt/class-providers
  {"fixture.LazyStatics" "cpfixture.static-provider"}
  :deps {'fixture/class-providers
         {:local/root "test/chez/class-provider-lib"}}})

;; Metadata and the state namespace both arrive only through add-deps. No catalog
;; namespace is required to establish the class-provider mapping.
(require 'cpfixture.state)

(let [before (cpfixture.state/load-count :static)
      value LazyStatics/VALUE
      nested Deep/VALUE
      after (cpfixture.state/load-count :static)]
  (println "class-provider add-deps before=" before "after=" after
           "value=" value "nested=" nested)
  (System/exit
    (if (and (= 0 before) (= 1 after)
             (= :lazy-static value)
             (= :transitive-provider nested))
      0
      1)))
