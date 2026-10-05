# Incremental byte-writer performance

This candidate fixes two runtime primitives; it does not change JSON formats,
Durable acknowledgement, replay, ownership, or application dependency pins.

## Quadratic byte-budget checks

`ByteArrayOutputStream.size()` previously called `baos-bytes`, extracting pending
bytes and concatenating them with the accumulated prefix. A caller checking size
after every row repeatedly copied the growing batch: O(rows × output bytes).
The new size operation reads the memory-port position plus the length already
extracted. It neither extracts bytes nor changes stream state.

Snapshots remain copying operations; returned arrays remain independently owned.
Reset, flush, and close behavior is unchanged. This does not add a concurrent
stream-use guarantee.

## Stock OutputStreamWriter blocks

The encoder callback previously copied every encoded block into a temporary
bytevector, copied that into a Java-shaped mutable array, then dispatched to the
stream which copied those bytes into its port.

For concrete Jolt streams with the stock write method still selected, it now
borrows the encoder block for the synchronous `put-bytevector` operation. No
encoder storage is retained or adopted. Closed-stream checks and piped-stream
flush behavior are retained. Proxies and later method overrides keep the original
three-argument array/range dispatch, including user effects. The method guard is
checked when the encoder callback runs, not just at writer construction.

## Red/green controls

`test/byte_array_output_stream_size_test.clj` tests size across buffered writes,
snapshots, reset, close and further writes; UTF-8 writer flush/readback; and two
mechanism controls:

- 512 size checks must perform zero extractions and retain the same accumulator.
- Stock encoded blocks create no temporary arrays; a live write override must
  still receive one normal array/range call.
- Compressed streams must stay outside the raw-block domain, and a real
  deflate/inflate roundtrip must preserve UTF-8.

Against the existing compiler artifact, baseline has **16 passing assertions,
two failures**; an overlay of the exact candidate definitions has **18 passing
assertions, zero failures**. This is a source-overlay gate, **not a rebuilt
compiler or full CI qualification**. `make bytestreamsize` is wired into the CI
gate for the rebuilt artifact.

The first rebuilt artifact exposed a startup distinction absent from the
overlay: compression installs an internal write wrapper after io-streams loads.
Its method identity made the raw-block guard decline (correct bytes, no fast
path). The follow-up `97d93c8f` recognizes only that wrapper's plain-stream
domain. Compressed streams still use compression, and subsequent user overrides
still invalidate the guard. The rebuilt artifact now passes **five tests,
20 assertions, zero failures** without runtime definition overlays.

Artifact: `evidence/jolt-baos-size-release-20261005/jolt` in the workspace;
banner `v0.8.17-28-g97d93c8f`, SHA-256
`1f0c78fc2fbbbb1728c12941fbe0bd18417e72abcfcad09312996001aac64ca6`.
This focused rebuilt gate is not full compiler CI or canonical-aspects port
qualification.

The unchanged actual five-table collector on this artifact completed at
**17,326 physical rows/s**, 14.429 seconds and 9.365 GB allocated. A separate
fresh snapshot reader confirmed 50,000 rows in each table (250,000 total).
Receipts: `exporter-baos-runtime-20261005.edn` and `.edn.recovery.edn` under
workspace evidence. That remains within the previous diagnostic screen range,
not a new throughput win or p99/S3 qualification. The product still uses its
original string encoder; no experimental byte-oriented sink was applied.

The same artifact also passed the exporter's `:typed-log-socket-test` alias:
real loopback OTLP transport, direct/socket row equivalence, exact Int64 typed
status/native readback, capability-removal control, typed string/Boolean/Int64
filters, historical coverage, and stale binding rejection before SQL. The first
manual namespace invocation omitted the alias's jolt-http dependency and failed
at require; using the declared alias resolved it. This is ordinary native typed
ingestion, not a combined typed-Durable or Langfuse qualification.

## Same-encoder byte-oriented experiment

Workspace evidence lives under `/home/chuck/ai-src/evidence/`:
`json-utf8-writer-screen-20261005.clj`, and the baseline, `size-fixed`, and
`block-fixed` `.edn` receipts. Same physical metric rows, 24,576 rows per sample,
public data.json dispatch/guards, UTF-8 flush and size check after each row,
exact payload parity. Compiler base: `2223c24a`, Chez 10.4.1; encoder source
`993b906`, chDB `7dcaec0`, exporter `1af91f3`.

| Byte-writer configuration | Sample times | Allocated per sample |
| --- | --- | --- |
| Existing runtime | 992/955 ms | 6.915 GB |
| Constant-time size | 592/600 ms | 408.0 MB |
| Size plus guarded stock blocks | 581/614 ms | 344.2 MB |

The same-run StringWriter baseline for the final screen took 597/583 ms and
403.7 MB. Thus the combined runtime changes remove the quadratic pathology and
reduce byte-path allocation by about 16%, but **do not demonstrate faster overall
encoding than the existing string path**. Do not promote this different sink as
an application default on this evidence. It uses one explicit OutputStreamWriter
instead of the row encoder's fresh per-row StringWriter; custom-writer/sink,
lazy-limit, shutdown, native-artifact and application gates remain separate.

The other screens ruled out a large win from safe Chez compilation settings,
moving only the bounded loop into Scheme, and ordinary decimal layout. Retain
these runtime fixes as supporting work; do not claim they close the Durable or
collector throughput gap.
