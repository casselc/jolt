(require 'jolt.deps)

(jolt.deps/add-deps
 {:deps {'fixture/class-providers
         {:local/root "test/chez/class-provider-lib"}}})

;; The provider catalog arrives only through add-deps.  Its namespace registration
;; must affect the same runtime registries as an ordinary project dependency.
(require 'cpfixture.catalog)

(let [before (cpfixture.catalog/load-count :static)
      value fixture.LazyStatics/VALUE
      after (cpfixture.catalog/load-count :static)]
  (println "class-provider add-deps before=" before "after=" after "value=" value)
  (System/exit (if (and (= 0 before) (= 1 after) (= :lazy-static value)) 0 1)))
