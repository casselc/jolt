# W13A: primary tests workflow on the shared immutable Chez toolchain

This note records why `.github/workflows/tests.yml` stopped building Chez
Scheme from source, and the hosted cold/warm evidence that the migration
preserved every gate. It describes the `casselc/jolt` proposal fork; it is not
an upstream acceptance or release claim.

## What changed

Before, each CI job built Chez 10.4.1 itself — `git clone cisco/ChezScheme`
plus `./configure && make && make install` on Linux and MSYS2, and
`build.bat tarm64nt /only` on Windows ARM64 — and memoized the result in a
hand-written `actions/cache` entry keyed by a string the workflow made up. Each
job also hand-staged an install layout: a `chez` wrapper next to `scheme`, a
`cc` shim, and a `csv` directory assembled by copying `libkernel.a`,
`scheme.h` and the boot files out of the build tree.

That put the same private layout knowledge in every consumer, and made the
cache key, not a digest, the thing CI trusted.

Now every job installs a published, digest-pinned archive:

    casselc/jolt-toolchains/setup-chez@095108ae32659757808064d004855092567d3ad3

from immutable release `chez-ci-10.4.1.1`. The action validates the archive
SHA-256 before extraction, then revalidates the internal inventory, the
required capability files, the reported Chez version and the machine type in a
fresh directory. Only then does it export `CHEZ`, `JOLT_CHEZ`,
`JOLT_CHEZ_CSV` and `PATH`.

| Job | Target | Archive SHA-256 | Capabilities |
| --- | --- | --- | --- |
| full gate (Linux x86_64) | `linux-x86_64` | `16476cd98fb5cb2e2c0285e88fcd6d57ade9392ca8d7cf603ca38432b4118526` | `source-runtime,gnu-kernel-dev` |
| full gate (Linux aarch64) | `linux-aarch64` | `b5b2306d3d6468b5fc7d5836721b09c704c7750f887a6232f1aeeb567d55f5d9` | `source-runtime,gnu-kernel-dev` |
| packaged Git deps (Windows x86_64) | `windows-x86_64` | `360c60496eea2f8aab0e557eb77e9e18b315bb9181938158ae57655aa541b7f8` | `source-runtime,gnu-kernel-dev` |
| source runtime (Windows aarch64 preview) | `windows-arm64` | `9bc28462823a1447de6d849e129758a6317cc9deafb8e87414817e7244f149c8` | `source-runtime` |

## Those four exports are the whole contract

Nothing in the workflow reconstructs the install layout, because Jolt already
reads exactly these variables:

- `Makefile` line 7 is `CHEZ ?= $(shell command -v chez …)`, so the exported
  `CHEZ` wins over discovery and the whole gate runs the pinned executable.
- `host/chez/build.ss` resolves the child compiler from `JOLT_CHEZ`
  (`bld-chez`) and the kernel-dev directory from `JOLT_CHEZ_CSV`
  (`bld-host-csv-dir`), falling back to path derivation only when unset.
- `host/chez/build-smoke.sh` and the other smoke scripts read `JOLT_CHEZ_CSV`
  first for the same reason.

The archives also ship the two names the build looks for — `bin/chez` (a
wrapper that execs the adjacent `scheme`, preserving argv0 so boot files
resolve) and, under `gnu-kernel-dev`, `bin/cc`. The workflow therefore creates
no wrapper and no shim of its own.

### The one remaining seam: POSIX path translation on Windows x86_64

MSYS2 stays in that job, but only where the boundary genuinely requires it: it
supplies the POSIX shell the recipes and `jolt.host` semantics assume, the
MinGW GNU compiler, and the lz4/zlib import libraries the packaged binary links
against. It no longer builds Chez.

The action exports native Windows paths. Two of the three are resolved through
a POSIX shell — `make` invokes `$(CHEZ)` from an MSYS2 recipe, and `build.ss`
runs `command -v "$JOLT_CHEZ"` under `sh` — so those two, and only those two,
are `cygpath -u`'d. `JOLT_CHEZ_CSV` stays native, because Chez itself calls
`file-exists?` on it. That is a shell-boundary translation, not a
reconstructed layout.

`JOLT_SH` behavior is unchanged: it is still set explicitly on the native
source-mode core gate and the packaged shell-boundary test, and PowerShell on
ARM64 is not routed through Bash.

## Fail-closed additions

Two gates could previously have gone quiet rather than red:

- **buildsmoke skip.** `host/chez/build-smoke.sh` deliberately exits 0 with
  `build smoke: skipped` when `libkernel.a`/`scheme.h`/`cc` are absent — the
  correct behavior on a distro Chez, but indistinguishable from a pass if the
  shared archive silently lacked `gnu-kernel-dev`. The gate output is now teed
  and a following step fails the job on `build smoke: skipped` and requires
  `build smoke: passed`. A pre-gate evidence step also asserts all four kernel
  files exist under `$JOLT_CHEZ_CSV`.
- **`tee` masking `make`.** The implicit runner shell is `bash -e`, which does
  *not* set `pipefail`, so piping the gate into `tee` would have discarded
  `make`'s exit status. The Gate step now declares `shell: bash` explicitly,
  which is `bash --noprofile --norc -eo pipefail`.

Windows ARM64 gained real target evidence: it previously inferred nativeness
from the `tarm64nt\bin\tarm64nt` build directory name. It now runs
`(machine-type)` through the installed Chez and throws unless the answer is
exactly `tarm64nt`.

## Hosted evidence

Branch `claude/core-shared-toolchain-v0.5.10`, workflow revision
`72d1aa01c82e9b58e7d3135b8117bcf3aa1231b3`. Both runs are that same revision;
the cold run is attempt 1 and the warm run attempt 2, so `tests.yml` is
byte-identical across them.

| | Cold | Warm |
| --- | --- | --- |
| Run | [`30420150498`](https://github.com/casselc/jolt/actions/runs/30420150498) attempt 1 | [`30420150498`](https://github.com/casselc/jolt/actions/runs/30420150498) attempt 2 |
| Result | success (4/4 jobs) | success (4/4 jobs) |
| Run wall clock | 7m20s | 7m10s |
| full gate (Linux x86_64) | success, 7m16s | success, 7m09s |
| full gate (Linux aarch64) | success, 5m09s | success, 4m50s |
| packaged Git deps (Windows x86_64) | success, 6m14s | success, 6m55s |
| source runtime (Windows aarch64) | success, 1m56s | success, 1m48s |
| Toolchain install (Linux x86_64) | 9s | 7s |
| Toolchain install (Linux aarch64) | 9s | 9s |
| Toolchain install (Windows x86_64) | 29s | 6s |
| Toolchain install (Windows arm64) | 13s | 7s |
| Cache | `Cache not found for input keys: …` then `Cache saved with key: …` on all four jobs | `Cache restored from key: …` and the action's `cache-hit` output is `true` on all four jobs |

Every job in both runs logged
`installed chez-ci-10.4.1.1/<target> …; archive sha256=<digest>` with a digest
equal to the pinned value in the table above.

Cache behavior is bound to the release tag and the archive digest, not to a
workflow-authored string — the keys are of the form
`jolt-chez-archive-chez-ci-10.4.1.1-<target>-<digest-prefix>`, so a different
release or a tampered archive cannot collide with an existing entry. No
unrelated caches were deleted for this task, and no cache namespace had to be
weakened to obtain a fresh key.

For comparison, the last pre-migration run of this workflow
([`30414843309`](https://github.com/casselc/jolt/actions/runs/30414843309),
base~1, with its hand-rolled Chez cache already warm) took 5m36s / 4m40s /
6m56s / 7m20s for the same four jobs. The shared toolchain is roughly neutral
on Linux and Windows x86_64 even against an already-warm hand cache, and
removes ~5.5 minutes from Windows ARM64, which previously rebuilt Chez with
`build.bat` on every single run because it had no cache at all.

### Gate results (identical on both runs)

Both Linux full gates ran `make test` to completion:

- self-host byte fixpoint: `self-host fixpoint: rebuild == checked-in seed`
- unit gate: 1129/1129 passed
- corpus parity: 3839/3858 evaluated cases pass
- SCI load: 211/218 forms ok
- certify oracle: 4031 corpus rows certified against JVM Clojure 1.12.5
- target-descriptor-test 33/33, build-output-test 5/5,
  timed-deref-deadline 4/4, `mvn-http-test: passed`
- transactional Git dependency cache: `deps-test: 183 checks passed`
- buildsmoke: `build smoke: passed (release + optimized + direct-link +
  tree-shake + …)`, followed by `buildsmoke consumed gnu-kernel-dev and linked
  a binary` — i.e. it linked a real binary and did not take the skip path
- `OK: CI gates passed` / `OK: all gates passed`

Windows x86_64 (`packaged Git deps`):

- target-descriptor-test: 33/33 passed
- build-output-test: 5/5 passed
- unit gate: 1129/1129 passed
- timed-deref-deadline gate: 4/4 passed
- `mvn_http_test.clj` passed in source mode
- `make jolt-release` linked the packaged compiler
  (`build-jolt: embedding boots + stub, linking`)
- packaged `windows_shell_test.clj` passed through
  `JOLT_SH=C:/Program Files/Git/bin/sh.exe`
- transactional Git dependency cache: `deps-test: 185 checks passed`

Windows ARM64 (`source runtime`, still `continue-on-error` preview, unchanged):

- `machine-type: tarm64nt`
- target-descriptor-test: 33/33 passed
- unit gate: 1129/1129 passed
- timed-deref-deadline gate: 4/4 passed
- `mvn-http-test: passed`, `windows_shell_test.clj` passed

No source-build fallback occurred on any job — there is no source-build path
left in this workflow — and no gate was weakened or removed to make the
migration green. `cc` on the Windows x86_64 job resolved to MSYS2's
`/mingw64/bin/cc`; the archive ships its own `bin/cc` as a fallback, and either
satisfies `bld-have-cc?` with the same MinGW compiler.

## Static checks

- `git diff --check` is clean.
- `actionlint` reports exactly one finding, unchanged from the base commit:
  `label "windows-11-vs2026-arm" is unknown`. That is actionlint catalogue lag
  — the label is the correct, currently-valid preview runner — so the label was
  not changed to silence it.
- `.github/workflows/tests.yml` contains no `cisco/ChezScheme` clone, no
  `configure`, no `build.bat`, and no Chez-specific hand-rolled cache.
- Only `.github/workflows/tests.yml` changed; all production/runtime source is
  byte-identical to the base.
- Third-party actions are pinned to full commit SHAs on Node 24 majors
  (`actions/checkout` v5.0.1, `msys2/setup-msys2` v2.32.0), and the workflow
  declares `permissions: contents: read`.

## Out of scope (W13B)

`cross-smoke.yml`, `glibc-floor.yml` and the release/publishing workflows still
build Chez themselves. They exercise different artifact and ABI contracts —
cross target packs, a glibc floor, and released binaries — so migrating them is
separate work and is deliberately not attempted here.
