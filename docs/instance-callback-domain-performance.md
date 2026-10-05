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

Remaining: independent review, rebuilt candidate and actual collector/Durable
measurements, followed by canonical integration/aspects port. Do not merge or
claim the throughput targets from these component results.
