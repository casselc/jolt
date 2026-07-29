# Jolt v0.5.11 proposal rebase: Phase 0 baseline

Date: 2026-07-29

This records the frozen upstream starting point for the proposal-fork rebase.
It contains no replayed fork source, generated-seed change, or claim about the
combined tree.

## Custody

- Canonical object store: `/home/chuck/ai-src/jolt-upstream`
- Worktree:
  `/home/chuck/ai-src/worktrees/jolt-upstream-rebase-v0.5.11`
- Branch: `codex/upstream-rebase-v0.5.11`
- Upstream remote: `origin`, `https://github.com/jolt-lang/jolt.git`
- Proposal remote: `fork`, `git@github.com:casselc/jolt.git`
- Fetched `origin/main`: `eecefc185d666f18d037e20e8f96ee2174bfad32`
- Fetched `fork/main`: `260a392a795089de3fb5ab700b386a334f01c051`
- v0.5.11 tag object:
  `dcf85cea3a9fa3d7ea359b413dd996bfe5f08bf8`
- Peeled v0.5.11 commit and branch starting point:
  `54a551c3fac88ed2ef331a99b8b54124e6cd4bcc`
- Consolidated proposal source:
  `1a65190311bdbf9421a55bf2a7a5810cc80be1b2`
- Creation-guarded local backup ref:
  `refs/backup/upstream-rebase-v0.5.11-source-1a651903`
- Backup ref value:
  `1a65190311bdbf9421a55bf2a7a5810cc80be1b2`

The backup was created with an all-zero expected old value, so the command
would have refused to move an existing ref:

```sh
git update-ref \
  refs/backup/upstream-rebase-v0.5.11-source-1a651903 \
  1a65190311bdbf9421a55bf2a7a5810cc80be1b2 \
  0000000000000000000000000000000000000000
```

Before creating the implementation worktree, the canonical checkout and the
v0.5.10 rebase, source-CI toolchain, binary/thread-state, ranged-FFI, native
UTF-8, cross/release toolchain, and v0.5.11 report worktrees were all checked
with `git status --short --branch` and had no tracked or untracked changes.
The existing feature branches were not moved.

Submodules were initialized recursively at:

| Path | Commit |
| --- | --- |
| `vendor/clojure-test-suite` | `489b6743e8421687ef96cec557830acf258d1886` |
| `vendor/fs` | `5b273b8a943a622593fbc85fca6761c5a39d6d66` |
| `vendor/irregex` | `c948a704fc732914a243c1643bfe359913d11c7b` |
| `vendor/process` | `43bdd65e189f2ccacc56662c53a21f5470ff1500` |
| `vendor/sci` | `32d62a5136ad3dc148588752f5bcc4cc30b14752` |

## Baseline environment

- Ubuntu 24.04.4 under WSL2, Linux x86-64
- Chez Scheme 10.4.1 (`ta6le`)
- Chez executable:
  `/home/chuck/.local/chez-10.4.1/bin/chez`
- Chez kernel directory:
  `/home/chuck/.local/chez-10.4.1/lib/csv10.4.1/ta6le`
- GCC 13.3.0
- OpenJDK 25.0.2
- Clojure CLI 1.12.2.1565, reporting Clojure 1.12.2 in certification

The final aggregate used task-specific writable state. This is load-bearing
when agents run gates concurrently: several upstream tests use fixed names
under `java.io.tmpdir`, and the default AOT cache is `$HOME/.jolt/aot-cache`.
The sandbox makes the latter read-only.

```sh
export PATH=/home/chuck/.local/chez-10.4.1/bin:$PATH
export CHEZ=/home/chuck/.local/chez-10.4.1/bin/chez
export JOLT_CHEZ=/home/chuck/.local/chez-10.4.1/bin/chez
export JOLT_CHEZ_CSV=/home/chuck/.local/chez-10.4.1/lib/csv10.4.1/ta6le
export TMPDIR=/tmp/jolt-v0.5.11-phase0/tmp
export JOLT_CACHE_DIR=/tmp/jolt-v0.5.11-phase0/aot-cache
export JOLT_GITLIBS=/tmp/jolt-v0.5.11-phase0/gitlibs
export JOLT_LOCAL_REPO=/tmp/jolt-v0.5.11-phase0/m2
timeout 900 make -j4 -Oline test
```

The command exited 0 and ended with both `OK: CI gates passed` and
`OK: all gates passed`.

## Results

| Gate | Baseline result |
| --- | --- |
| Self-host | rebuilt seed byte-identical to the checked-in seed |
| Value model | 37/37 |
| Corpus | 3,904/3,923 evaluated cases pass; 9 known failures tolerated; 0 new divergences |
| Host unit | 1,083/1,083 |
| Maven HTTP | passed |
| Dependency expansion | 31/31 |
| CLI smoke | 87/87 |
| Build smoke | passed, including release, optimized, direct-link, tree-shake, dependency, extension, vendored-library, and source-driver cases |
| Shared-library build smoke | clean environment skip: stock Chez `libkernel.a` is not position-independent |
| Static-native smoke | passed static link, dynamic load, and link-order checks |
| SCI | 416/424 forms loaded; 8 baseline failures accepted by the gate |
| Clojure test suite | 243 namespaces; 6,079 pass, 139 baseline failures, 2 baseline errors, 0 hung, 0 crashed; matched baseline |
| FFI | 10/10 |
| Transients | 17/17 |
| Inference | 45/45 |
| Whole-program inference | 9/9 |
| Protocol devirtualization | 12/12 |
| Field reads | 11/11 |
| Numeric whole-program | 8/8 |
| Numeric fields | 9/9 |
| Field joins | 12/12 |
| Numeric contagion | 20/20 |
| Protocol returns | 4/4 |
| Protocol inline cache | 22/22 |
| Nilable narrowing | 10/10 |
| Operation arity | 263/263 |
| Float math | 20/20 |
| Float arrays | 32/32 |
| Inline method body | 3/3 |
| DCE references | 27/27 |
| Manifest and IR validation | passed |
| Tree-shake comparison | passed for all fixtures with byte-identical behavior |
| Gate boot | 8/8 |
| Dev boot/cache | 5/5 |
| AOT fingerprint | 10/10 |
| AOT cache | 16/16 |
| Explicit compile path | 13/13 |
| Dependency CLI smoke | 50/50 |
| JVM certification | 4,098 rows; 3,885/3,918 certifiable rows agreed; all 33 divergences known; 0 new and 0 stale |

The static-native gate intentionally removes a dynamically loaded fixture and
requires that child to fail; its shell emitted `Aborted (core dumped)` while
the gate itself passed. This is the gate's non-vacuity control, not a baseline
crash.

## Discarded environment artifacts

Three earlier invocations were not used as product evidence:

1. Supplying `CHEZ` without putting its directory on `PATH` let direct Make
   recipes run but made `bin/jolt` report `No valid Chez Scheme executable
   found`.
2. Running without `JOLT_CACHE_DIR` made compiled children fail before their
   assertions when they tried to create the sandbox-read-only
   `$HOME/.jolt/aot-cache`.
3. Running with the shared `/tmp` namespace produced 1,082/1,083 unit rows and
   a bounded CLI-smoke timeout. The same public `add-deps` expression returned
   `:pong`, and rerunning with the task-specific `TMPDIR` produced 1,083/1,083
   and CLI smoke 87/87. These were cross-run fixture collisions, not upstream
   failures.

No fork source was applied and no seed was reminted during this phase. No
branch, commit, tag, or pull request was pushed or opened.
