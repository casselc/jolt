# Fixed-storage string hash cache (candidate)

Jolt strings are Chez strings. Unlike a JVM String they have no hash field.
The runtime previously kept identity/hash pairs in a per-thread hash table,
clearing it after 2048 entries. Telemetry can repeatedly create equal-text keys
with different identities: the cache then allocates entries it rarely reuses.

This candidate uses 2048 fixed key/hash slots per native thread. A constant-time
selector uses length and boundary characters; an identity check authorizes a
hit. Colliding keys only overwrite a slot, never share a cached result. Misses
use the unchanged JVM-compatible hash calculation. Storage remains bounded,
not a global intern table. The existing virtual-register cache initialization
keeps caches private to threads; this native path has no fiber parking point.
As before, strings must not be mutated through raw Scheme after caching.

The selector's masked length and Unicode-scalar arithmetic fit the narrow
fixnum window. A bad/adversarial selector distribution can reduce hit rate,
but does not change hashes or make storage unbounded. The initial fixed vector
costs 32 KiB on 64-bit hosts and may retain up to 2048 strings, like the prior
entry-count bound; it is not a byte-size bound on retained string content.

`make hasheq` and `make narrowhash` include cache tests for exact values,
forced collisions, eviction, a 10k-key working set, GC, four native threads,
and per-miss allocation. `JOLT_TEST_OLD_STRING_CACHE=1` selects the old cache
inside the allocation test; it must fail the cache-entry allocation gate.
These gates do not qualify a rebuilt artifact, state-image serialization,
Durable tail throughput, S3, or whole-ecosystem lifecycle behavior.

The preceding process-local prototype preserved complete typed rows and exact
SQL, reducing connected allocation by about 7.7 MB per 10k wide rows. Independent
unchanged-compiler recovery passed. That prototype used an extra table lookup
not present here. Its single confirmed-write timing is not sustained throughput
evidence for this source implementation. Retain the parent compiler and all
JSON/interop/exporter/Durable patches until exact-artifact comparisons pass.
