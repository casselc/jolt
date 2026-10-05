# Small integral double formatting candidate

This isolated cumulative compiler branch adds a runtime-owned fast path, not
a custom exporter/JSON encoder. Nonzero exact integral doubles with magnitude
below 10,000,000 have plain decimal `Double.toString` text. The existing fixnum
formatter supplies the digits and the wrapper appends `.0`. The guard excludes
both zero signs, fractions, scientific notation, subnormals and nonfinite values;
they retain the existing general formatter. No rendered values are cached.

## Evidence boundary

Diagnostic replacement over compiler `97d93c8f` passed 20,026 text comparisons
against the original formatter. A focused 100k-call alternating screen measured
64.5 / 68.6 ms and 114.2 MB allocation for the original versus 9.8 / 9.6 ms and
9.4 MB for the candidate. This is formatter-only evidence.

The actual confirmed local POSIX five-table exporter screen, same compiler and
Git-pinned dependencies, measured:

| Screen | Stored rows/s | Scheme allocation |
| --- | ---: | ---: |
| Candidate formatter overlay | 18,550.73 | 8,342,007,712 bytes |
| Baseline, run afterwards | 17,918.78 | 8,691,210,480 bytes |

This single ordered pair suggests about 3.5% throughput and 4.0% allocation
improvement; it does not establish repeatable latency/tail, S3 or Rust parity.
Both writers store 50k rows per signal/table (250k total). Separate fresh readers
confirm those counts for both stores.
Full-value equivalence is not established by table counts.

The source-level suite checks admitted text, declined boundaries, public
`str`/`pr-str`/`Double.toString` and a nonvacuous mechanism control. A general-only
mutant must fail that mechanism control while keeping text equivalence green.
Rebuilt artifact `v0.8.17-32-gbff1e47c` (SHA256
`c559f82eaf3092c385096e9cab899ff80ccee5b1e74e6ea6fade28e6e0afcba2`)
passes the four-test / 20,030-assertion formatter suite, retained byte-stream
suite (five / 20), and existing data.json native suite (23 / 500). Source-mode
tests use Chez 10.4.1. No formatter replacement is installed for these gates.

Actual exporter with that rebuilt artifact and no diagnostic replacement:
18,133.91 rows/s, 8,342,326,896 allocated bytes. Against the preceding baseline,
this retains the ~4% allocation reduction but only ~1.2% observed throughput
gain. Neither run proves a repeatable speedup; allocation is the more consistent
signal. Full compiler CI, independent review and canonical `integration/aspects`
integration remain separate gates.

## Related pipeline attribution

A separate coarse instrumented exporter run measured 14.21 seconds overall:
5.82 seconds in confirmed execution/publication, 4.48 in generic encoding and
1.00 in metric materialization. The log whole-export phase overlaps encoding
and execution and must not be added to these totals. Phase probes include warmup,
but benchmark ingest excludes warmup; these are diagnostic approximate shares,
not an additive accounting proof. Fresh reader confirmed all 250k measured rows.

Thus faster formatting helps, but row encoding is not the entire gap. Remaining
encoding dispatch/string work and physical publication/native execution merit
measurement; changing acknowledgement boundaries to admission-only would not
be an equivalent performance improvement.
