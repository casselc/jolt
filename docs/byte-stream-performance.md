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

Against the existing compiler artifact, baseline has **16 passing assertions,
two failures**; an overlay of the exact candidate definitions has **18 passing
assertions, zero failures**. This is a source-overlay gate, **not a rebuilt
compiler or full CI qualification**. `make bytestreamsize` is wired into the CI
gate for the rebuilt artifact.

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
