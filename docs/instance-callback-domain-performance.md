# Explicit representation domains for instance callbacks

The OTel exporter asks whether normalized attributes are EmptyValue or Bytes
records before formatting them. In a loaded application, these negative checks
also ask each library's live instance callback. The java.time callback runs
`jt?` even for strings, Booleans and numbers it cannot represent.

An optional second `:host-table` argument to `__register-instance-check!` makes
that receiver restriction explicit. Outside the domain, the callback is not
invoked and the arm returns nil (fallthrough), not false. Inside the domain,
the original callable receives the same class-name string and receiver.
Its result, effects, exceptions and Var replacement stay live. Older callbacks
remain unrestricted; callback order stays oldest-first and the first non-nil
answer wins. No answer or predicate purity is inferred or cached.

java.time opts in because its values are opaque host tables. This also means
rebinding its helpers cannot claim non-table values through this registration.
That is an explicit contract change, consistent with its existing equality and
class domains, not an assertion of equivalence under arbitrary helper rebinding.

## Evidence, 2026-10-05

Selected compiler: `976dd9d15245b40d447c9ec920e15f119f297c02`, Chez 10.4.1,
AOT disabled. Untouched exporter `c451e7a`, OTel `19fc49d` override. The row
screen constructs 24,576 metric rows per arm and checks JSON byte parity before
timing. Two symmetric arms per variant are component screens, not tail or
collector-throughput qualification.

| Formatter | Original allocation | Domain source allocation |
| --- | ---: | ---: |
| Generic normalization/formatting | 373.14 MB | 266.17 MB |
| Normalize, then primitive formatting | 266.18 MB | 266.17 MB |
| Guarded scalar text helper | 253.60 MB | 253.59 MB |

Generic formatting time was 287–315 ms before and 177–196 ms with the source
patch. The guarded helper was 124–127 ms before and 115–117 ms after; this small
sequential difference is not an independently qualified extra improvement.
The main allocation savings overlap with the existing scalar helper. Keeping
the helper still avoids the remaining normalization result wrapper.

Individual predicate probes (100,000 scalar calls per arm) measured 56.4 MB
for each record check versus 2.0 MB for the loop/control and collection
predicates. Calling the time instance callback directly reproduced 56.4 MB;
the other registered callback used 2.0 MB. Eight record checks invoked `jt?`
eight times. This identifies the time callback as the allocation cause in this
fixture, rather than JSON encoding or the persistent result map alone.

Local receipts under `/home/chuck/ai-src/evidence/`:

- `exporter-scalar-attribution-original-20261005.edn`
- `exporter-predicate-callback-attribution-20261005.edn`
- `exporter-instance-domain-screen-20261005.edn` (temporary diagnostic wrapper)
- `exporter-instance-domain-source-screen-20261005.edn` (actual changed source)

The source screen loads the actual registration definition and time namespace
into the selected artifact. It is **not a rebuilt compiler qualification**.
No persistence, acknowledgement, encoder default or GC policy changed.

## Gates and next steps

From the worktree root, with the irregex submodule initialized:

```sh
/home/chuck/ai-src/tools/jolt-with-chez-10.4.1 /home/chuck/ai-src/tools/chez-10.4.1 --script test/chez/callback-domains-test.ss
/home/chuck/ai-src/tools/jolt-with-chez-10.4.1 /home/chuck/ai-src/tools/chez-10.4.1 --script test/chez/callback-bridges-test.ss
/home/chuck/ai-src/tools/jolt-with-chez-10.4.1 /home/chuck/ai-src/tools/chez-10.4.1 --script test/chez/equality-domain-concurrent-test.ss
```

Results: 96/96, 50/50 and 12/12 assertions passed. Controls include non-table
suppression, live same-kind true/false answers, nil fallthrough, definitive
false ordering, warmed-site registration invalidation, Object precedence,
exception identity, invalid-domain rejection, Var replacement and callable
prefix fallback.

## Rebuilt collector checkpoint

Release candidate built successfully from `2223c24a`, banner
`v0.8.17-24-g2223c24a`, SHA-256
`5b8167ae087ab1ac59585e6bbaece5a32ed4502aec8d13912d2ad1cf883d7889`.
Eight primitive record checks invoke the time predicate zero times in the
rebuilt executable, compared with eight times in the original executable.

Same exporter `1af91f3`, chDB key-cache consumer `7dcaec0`, data.json `993b906`,
OTel `19fc49d`, native package 26.7.3, AOT disabled. Actual local POSIX Durable
collector, ten batches of 5,000 items across five tables, per-physical-insert
commit boundary unchanged:

| Executable | Physical rows/s | Scheme heap allocated |
| --- | ---: | ---: |
| Original `976dd9d` | 17,348.69 | 9,365,633,952 B |
| Candidate `2223c24a` | 17,676.32 | 9,365,567,952 B |

Both writers and separate fresh snapshot readers reached terminal exit zero;
each reader confirmed 50,000 service rows in each table (250,000 total). Counts
do not prove full-row recovery equivalence. The ~1.9% sequential throughput
difference is not a causal win: allocation is effectively unchanged, as expected
because the existing scalar shortcut already bypasses these record predicates.
No additional collector improvement should be booked from this domain change.

Receipts: `exporter-instance-domain-{baseline,candidate}-durable-20261005.edn`
and their `.recovery.edn` companions. Driver:
`exporter-instance-domain-durable-driver-20261005.clj`. The baseline writer used
the package's default native resolution; subsequent runs explicitly selected
the cached 26.7.3 library with `JOLT_CHDB_LIB`.

The current benchmark's export timers include synthetic record generation.
Next attribution must separate that preparation from row construction,
encoding, and confirmed persistence before treating collector throughput as a
pure ingestion limit. Keep the original end-to-end measurement available.

Remaining: independent review, broader compiler gates and canonical
integration/aspects port. The collector target remains unmet; no S3, robust
tail, matched Rust or full-row recovery qualification is claimed.
