(ns cpfixture.frozen-provider)

;; Source/REPL execution intentionally has an open provider registry. A
;; standalone program is closed around resolved deps.edn metadata before its
;; included provider forms run. Catch and publish the observed mode so the smoke
;; gate proves both sides of that boundary without making the positive binary
;; fail during startup.
(def registry-mode
  (try
    (jolt.host/register-class-providers!
      {"fixture.RuntimeUndeclared" 'cpfixture.missing-provider})
    :source-mutable
    (catch Throwable e
      (get-in (ex-data e) [:jolt/error :type]))))

(__register-class-statics!
  "fixture.FrozenProbe"
  {"REGISTRY_MODE" registry-mode})
