# Dynamic vector construction allocation

The compiler emits dynamic vector literals through `jolt-vector`. Its previous
rest-argument implementation allocated a temporary Scheme list, then copied
that into a vector backing. Fixed arities 0–32 construct that backing directly;
larger calls retain the original path. No telemetry-specific type, encoding,
ownership or durability API is introduced.

Each result is still fresh, elements retain their identity, and arguments are
evaluated once by the caller before construction. `make-pvec` continues to
choose the same tail/trie representation, kind and metadata. This does not
change public array borrowing or introduce shared mutable backing storage.

The native gate is included in `make values`. A local red control is available
by setting `JOLT_TEST_OLD_VECTOR_CONSTRUCTOR=1` while running
`test/chez/vector-constructor-test.ss`: all value checks still pass, but the
final allocation check must fail after the old constructor is restored.

On pinned Chez 10.4.1, the 100k two-element gate measured 12,800,928 bytes for
the old constructor and 9,600,928 for the candidate. A process-local diagnostic
on actual 10k wide typed telemetry rows measured about 47.18 → 42.69 MB of row
construction allocation. Time results overlapped; no confirmed Durable
throughput improvement, S3 qualification, compiler-wide or AOT qualification
is claimed. The production-source candidate still needs a rebuilt compiler,
JSON/OTel tests, real confirmed writes and fresh recovery, then review.
