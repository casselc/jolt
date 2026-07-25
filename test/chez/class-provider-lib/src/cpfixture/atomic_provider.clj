(ns cpfixture.atomic-provider)

;; Registration maps are atomic even while a provider namespace is evaluating.
;; Catching the conflict must not preserve StagedPartial in the provider's
;; otherwise-successful registration stage.
(jolt.host/register-class-providers!
  {"fixture.StagedExisting" 'cpfixture.missing-provider})

(def caught-type
  (try
    (jolt.host/register-class-providers!
      (array-map
        "fixture.StagedPartial" 'cpfixture.missing-provider
        "fixture.StagedExisting" 'cpfixture.static-provider))
    nil
    (catch Throwable e
      (get-in (ex-data e) [:jolt/error :type]))))

(__register-class-statics!
  "fixture.StagedAtomicTrigger"
  {"VALUE" caught-type})
