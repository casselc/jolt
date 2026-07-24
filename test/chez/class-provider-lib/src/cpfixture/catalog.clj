(ns cpfixture.catalog)

(def loads (atom {}))

(defn note-load! [provider]
  (swap! loads update provider (fnil inc 0)))

(defn load-count [provider]
  (get @loads provider 0))

;; This catalog is the shape a dependency resolver will eventually synthesize
;; from :jolt/class-providers metadata.  Keeping it as ordinary source proves
;; that the runtime mechanism works before that project-plumbing lands.
(jolt.host/register-class-providers!
 {"fixture.LazyStatics" 'cpfixture.static-provider
  "fixture.LazyCtor" 'cpfixture.ctor-provider
  "java.nio.ByteBuffer" 'cpfixture.buffer-provider
  "java.nio.charset.StandardCharsets" 'cpfixture.standard-charsets-provider})

(defn register-error-providers! []
  (jolt.host/register-class-providers!
   {"fixture.MissingAfterLoad" 'cpfixture.missing-provider
    "fixture.CycleA" 'cpfixture.cycle-a
    "fixture.CycleB" 'cpfixture.cycle-b}))
