# Proposal-fork rebase onto Jolt v0.5.10 — 2026-07-28

This record describes the replay of the `casselc/jolt` proposal stack from
upstream v0.5.7 onto upstream v0.5.10. It is fork-local validation evidence,
not an upstream release claim or authorization to push to `jolt-lang/jolt`.

## Checkpoints

- old proposal tip: `8ce96a4e` (`codex/timed-deref-deadline`);
- upstream tag: `v0.5.10`, commit `38adcc0185e23f05e096d36d661065758a5432b4`;
- rebase branch: `codex/upstream-rebase-v0.5.10`;
- freshly reminted seed: `5e2b4304`;
- tested source revision: `75080987`.

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
reports 183/183.

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

## Proof revalidation

No modeled premise changed for timed deref or the v3 Git cache:

- `host/chez/java/concurrency.ss` is byte-identical to the old proposal tip;
- `jolt-core/jolt/deps.clj` is byte-identical to the old proposal tip; and
- the only loader delta is v0.5.8's full-content hash helper, below the retained
  runtime rule that bypasses per-namespace artifact selection.

All 65 checked SMT files under `test/chez/formal/` match their declared
verdicts under standalone Z3: every `*-corrected.smt2` is UNSAT, and every
buggy, witness, control, or non-vacuity model is SAT.

The directly affected timed-deadline and Git-path-budget trios were also
linted and verified through Chiasmus:

| Family | Buggy control | Corrected query | Non-vacuity |
| --- | --- | --- | --- |
| timed deref deadline | SAT | UNSAT | SAT |
| Git cache path budget | SAT (`226`) | UNSAT | SAT (`219`) |

The runtime companions pass: timed deref 4/4, dependency transactions 183/183,
dependency smoke 54/54, namespace-effect replay, and AOT fingerprint 10/10.
No proof or model source needed revision merely to preserve its conclusion.

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

Hosted platform validation and downstream net/TCP/HTTP/Hegel repins remain
follow-ons. Nothing in this rebase was pushed to the upstream Jolt origin, and
no pull request was opened.
