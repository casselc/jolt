# Primitive-string map constructor screen

This is a retained **diagnostic candidate**, not a runtime default or product
repin. It is separate from the byte-stream fixes on this branch.

Wide String-keyed map literals currently reach `hash-from-kvs`, which inserts
each pair into a new persistent HAMT. The candidate scans for nonempty, entirely
primitive-String keys, then builds one caller-owned transient hash map with
runtime-owned helpers and freezes it. Every other shape uses the original
builder. Empty construction keeps the original singleton identity. Values are
stored unchanged; no user values are inspected or normalized.

Exact candidate source is in workspace evidence
`string-map-bulk-builder-20261005.ss`, SHA-256
`d45d9f130fbcba85be74e5a17ddc29788b1172663714a630a08a511f8e191da6`:

```scheme
(let ((original hash-from-kvs))
  (lambda (kvs)
    (if (and (pair? kvs)
             (let check ((xs kvs))
               (or (null? xs)
                   (and (pair? xs) (pair? (cdr xs)) (string? (car xs))
                        (check (cddr xs))))))
        (let ((t (jolt-transient-new empty-pmap-hash)))
          (let loop ((xs kvs))
            (unless (null? xs)
              (thash-put! t (car xs) (cadr xs))
              (loop (cddr xs))))
          (jolt-persistent! t))
        (original kvs))))
```

## Measurements

Runtime artifact `97d93c8f` is the rebuilt byte-stream candidate described in
[byte-stream-performance.md](byte-stream-performance.md). Sources remain
exporter `1af91f3`, chDB `7dcaec0`, data.json `993b906`, libchdb 26.7.3.
The helper is a temporary process-local overlay restored in `finally`.

The metric-row construction component (24,576 rows per sample) preserved exact
row values and JSON bytes. Persistent builder: 123/118 ms, 253.60 MB allocated;
bulk prototype: 120/134 ms, 169.45 MB. Allocation dropped about one third; time
did not clearly improve. The initial component prototype did not yet include
the empty-identity guard; the actual collector candidate above does.

The actual five-table collector completed at **17,514 physical rows/s**,
14.274 seconds, **8.693 GB allocated** versus the preceding unchanged run at
17,326 rows/s, 14.429 seconds, 9.365 GB. This is roughly **7.2% less allocation**,
not a statistically qualified throughput gain. Independent fresh readback
confirmed 50,000 rows per table, 250,000 total. Neither run establishes p99,
S3 or Rust equivalence.

Workspace receipts/drivers: `exporter-string-map-builder-screen-20261005.*`,
`exporter-string-map-durable-driver-20261005.clj`,
`exporter-string-map-bulk-durable-20261005.edn` and its `.edn.recovery.edn`.

## Correctness controls and an invalid oracle

`string-map-builder-controls-20261005.clj` passed **275 controls**: values,
count, iteration order, duplicate keys, Unicode field names, mixed/non-string
fallback and actual colliding strings such as `Aa`/`BB` (their hashes are
checked before use). Sizes cover 0 through 128 fields and larger collision
cases. The empty singleton is checked separately.

An initial forced-collision control replaced only `key-hash`. Inline String
lookups use another fast hashing path, so that mutation made even the baseline
map invalid. Its equality failure was not a candidate implementation defect.
The corrected control uses real colliding inputs and no hashing mutations.
General lesson: a partial internal-entry-point mutation is not automatically a
valid semantic oracle; authenticate it against every lookup path it exercises.

Remaining gates before any production change: key/value identity and independent
snapshot controls, fuller constructor/collection suites, source integration and
rebuilt artifact, independent review, and repeated actual workload/tail measures.
Retain the allocation result for cumulative work, but do not promote it as the
missing large throughput win.
