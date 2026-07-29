# Proposal-fork rebase onto Jolt v0.5.10 — 2026-07-28

This record describes the replay of the `casselc/jolt` proposal stack from
upstream v0.5.7 onto upstream v0.5.10. It is fork-local validation evidence,
not an upstream release claim or authorization to push to `jolt-lang/jolt`.

## Checkpoints

- old proposal tip: `8ce96a4e` (`codex/timed-deref-deadline`);
- upstream tag: `v0.5.10`, commit `38adcc0185e23f05e096d36d661065758a5432b4`;
- rebase branch: `codex/upstream-rebase-v0.5.10`;
- freshly reminted seed: `5e2b4304`;
- Git transaction correction: `e11adc8263c1d68235f5fb30a3295c49b22c4edc`;
- tested code revision: `c8de0879d336c59b4c93d6921184f7674f7f8297`.

The old proposal was a linear 70-commit series over v0.5.7. Sixty-nine
semantic, test, CI, and documentation commits were replayed. The old
`chore(seed): remint proposal on v0.5.7` artifact commit was deliberately not
replayed: generated Scheme from two different source bases cannot be merged
soundly. The combined v0.5.10 tree was reminted once with Chez 10.4.1 and
converged after three passes. `make selfhost` then reported a byte-identical
fixpoint.

## Upstream overlap decisions

### Git dependency transactions

v0.5.9 added a narrow staging-directory repair for interrupted clones. The
proposal already owns a stronger v3 protocol: fixed-size coordinate keys,
durable exact-coordinate ownership claims, per-entry locks, private staging,
full origin/HEAD/worktree/submodule validation, and fail-closed collision
handling.

The proposal protocol remains the production implementation. Upstream's new
smoke scenarios remain as independent integration coverage, reconciled to the
v3 contract:

- an obsolete sanitize/SHA leaf is ignored;
- a claimed but empty v3 checkout is repaired;
- a failed fetch is observed to fail;
- exactly one matching `.jolt-origin` claim may remain; and
- no checkout, lock, or staging payload remains publishable.

The reconciled smoke reports 54/54 checks. The deeper transactional suite
reports 183/183 on Linux and 185/185 on native Windows x86-64.

### Namespace artifact cache

v0.5.8 replaces Chez `equal-hash` sampling with full-content FNV-1a for cache
keys and runtime fingerprints. That repair is retained, along with its
10-check characterization gate.

It does not change the proposal's runtime decision. Per-namespace artifact
selection remains retired because a content-correct compiled namespace still
cannot replay arbitrary fresh-process top-level effects. The loader therefore
continues to call `load-jolt-file` at the namespace boundary, and
`namespaceeffectsmoke` remains the default correctness gate. The upstream
`aotcachesmoke` and `aotfingerprint` targets remain available as
characterization evidence but are not used to re-enable namespace cache hits.

### v0.5.10 runtime and optimizer changes

The upstream numeric-arm registry, BigDecimal changes, compatibility preamble
move, seqable shim relocation, stale native header repair, and `:throw`
purity/totality correction replay without proposal-specific source edits.
Numeric, inline, unit, corpus, CTS, and build gates exercise the combined tree.

## Parallel devboot finding

The first complete parallel gate exposed a separate test-orchestration defect.
`depstest` used `bin/jolt`, which may select `target/dev/flat.so`, while
`devbootsmoke` deliberately replaces that same developer image. The reduced
result was:

| Concurrent pair | Result |
| --- | --- |
| `depstest` + `devbootsmoke`, default mutable devboot image | reproducible nonrecoverable invalid-memory crash |
| `depstest` alone | 183/183 |
| `depstest` + `gateboot` compile pressure | 183/183 |
| `depstest` + `devbootsmoke`, forced source driver | 183/183 |

The dependency gate now uses the immutable `target/release/jolt` executable,
matching hosted Windows/release practice, and declares `testbin` as a
prerequisite. The exact reduced pair then passes with `depstest` 183/183 and
`devbootsmoke` 5/5.

This isolates the Git transaction gate; it does not prove that replacing a
fixed-path devboot image is safe for every arbitrary process that selects it
concurrently. Immutable generation-named devboot publication remains a
separate follow-up.

## Packaged Windows Git-transaction finding

The first hosted rebase run
[`30409373239`](https://github.com/casselc/jolt/actions/runs/30409373239)
passed both Linux full gates and the Windows ARM64 source-runtime gate. The
packaged Windows x86-64 dependency job terminated with exit 139 after Git
reported a private `.s` stage as busy. This was a real native failure, not the
expected missing-origin diagnostic from the failed-clone fixture.

Native reduction isolated the six-writer same-process case. Serializing only
the shell call still reproduced the busy-stage termination on the fourth
fresh-process repetition. The durable per-entry directory lock coordinates
publication between processes, but it cannot restore a runtime that terminates
while concurrent threads are still inspecting or repairing cache state.

The complete same-process inspection/reuse/repair transaction is therefore
admitted through one recursive object monitor. The directory lock remains the
separate cross-process authority. This intentionally serializes Git cache
transactions inside one Jolt process, including different coordinates; ordinary
dependency expansion is sequential today, and the safer native boundary is
preferred over speculative parallel acquisition. The exact native Windows
suite then passed 185/185, including a 60-second stress-only ceiling derived
from the measured serialized six-writer path. Linux remains 183/183.

Hosted run
[`30413531965`](https://github.com/casselc/jolt/actions/runs/30413531965)
at the production correction passed all four jobs: Linux x86-64, Linux
aarch64, Windows ARM64 source runtime, and packaged Windows x86-64 Git
transactions. The packaged lane reached and passed the complete transactional
gate instead of terminating in native cleanup. Final-code run
[`30414843309`](https://github.com/casselc/jolt/actions/runs/30414843309)
repeated the same 4/4 result at `c8de0879`, including the measured
stress-watchdog adjustment.

## Proof revalidation

No modeled premise changed for timed deref:

- `host/chez/java/concurrency.ss` is byte-identical to the old proposal tip;
- the only loader delta is v0.5.8's full-content hash helper, below the retained
  runtime rule that bypasses per-namespace artifact selection.

`jolt-core/jolt/deps.clj` now has one deliberate post-replay delta: the
process-local transaction monitor described above. Its bounded model asks
whether two same-process transaction intervals can overlap. Omitting the
monitor is SAT; serial admission plus the overlap query is UNSAT with the
monitor/overlap/violation/query core; and useful sequential completion remains
SAT.

All 68 checked SMT files under `test/chez/formal/` match their declared
verdicts under standalone Z3: 46 SAT controls/witnesses/non-vacuity models and
22 UNSAT corrected queries.

The directly affected timed-deadline and Git-path-budget trios were also
linted and verified through Chiasmus:

| Family | Buggy control | Corrected query | Non-vacuity |
| --- | --- | --- | --- |
| timed deref deadline | SAT | UNSAT | SAT |
| Git cache path budget | SAT (`226`) | UNSAT | SAT (`219`) |
| Git same-process transaction | SAT (overlap) | UNSAT | SAT (both complete) |

The new trio was linted and verified through Chiasmus as well as standalone
Z3. The runtime companions pass: timed deref 4/4, dependency transactions
183/183 on Linux and 185/185 on native Windows, dependency smoke 54/54,
namespace-effect replay, and AOT fingerprint 10/10.

## Local verification

Using `/home/chuck/.local/chez-10.4.1/bin/chez`:

```sh
make CHEZ=/home/chuck/.local/chez-10.4.1/bin/chez remint
make CHEZ=/home/chuck/.local/chez-10.4.1/bin/chez selfhost
make -j4 CHEZ=/home/chuck/.local/chez-10.4.1/bin/chez ci
```

The final complete gate reports `OK: CI gates passed`. Selected evidence:

- corpus: 3839/3858 evaluated, zero new divergence, nine allowlisted failures;
- unit: 1129/1129;
- timed deref: 4/4;
- dependency expansion: 31/31;
- dependency transactions: 183/183;
- dependency CLI smoke: 54/54;
- FFI: 124/124 plus 6/6 aggregate checks;
- CTS: 6079 pass, 139 fail, 2 error, matching the checked baseline;
- class-provider, build, static-native, tree-shake, devboot, gateboot,
  namespace-effect, optimizer, and manifest gates passed.

The four-job hosted platform gate is green at both the production correction
and final tested code; downstream net/TCP/HTTP/Hegel repins remain follow-ons.
Nothing in this rebase was pushed to the upstream Jolt origin, and no pull
request was opened.
