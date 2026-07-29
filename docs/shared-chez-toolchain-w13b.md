# W13B: release-workflow Chez boundary

This note records the second shared-toolchain migration in the `casselc/jolt`
proposal fork. It distinguishes repeatable CI bootstrap from source builds that
are themselves release, ABI-floor, or cross-target evidence. It is not an
upstream acceptance claim.

## Selected boundary

A blanket replacement of every Chez source build would weaken the workflows.
The correct boundary is:

| Workflow path | Decision | Reason |
| --- | --- | --- |
| `release.yml`, Windows x86_64 | shared `windows-x86_64` toolchain | the published capability already builds and smokes a self-contained MinGW Jolt |
| `release.yml`, Linux | retain source build inside manylinux2014 | the build environment establishes the released binary's glibc 2.17 floor |
| `release.yml`, macOS ARM host | retain Homebrew Chez | `chez-ci-10.4.1.1` was produced on macOS 15 without a recorded deployment floor, so its kernel archive is not yet an honest macOS 14 release-link input |
| `release.yml`, macOS x86_64 target pack | retain cross source build | `bootquick`, `xpatch`, target boots, and the cross kernel are the artifact under test |
| `cross-smoke.yml` | retain host-plus-cross source build | the workflow proves target-pack construction and retargeting, not merely source-mode execution |
| `glibc-floor.yml` | retain one source build per old-glibc container | varying the build environment is the purpose of the experiment |

W13B first attempted to use the shared ARM archive as the host compiler for
both macOS release rows. The native build and smoke passed, but the linker
reported that every object in `libkernel.a` was built for macOS 15 while the
release was being linked for macOS 14. A passing build on the current runner is
not evidence that the artifact honors Jolt's documented macOS 14 floor.
The attempt was therefore rejected rather than recorded as a successful
migration.

Future toolchain recipes may publish independently versioned cross packs. A
manylinux release kit would also need to be produced inside the selected old
glibc environment. Neither capability exists in `chez-ci-10.4.1.1`, so W13B
does not infer it from `source-runtime` or `gnu-kernel-dev`.

The next macOS toolchain recipe must make the deployment target part of the
producer and consumer contract: compile the native ARM kernel with an explicit
macOS 14 minimum, compile the x86_64 kernel with the release's macOS 11
minimum, record those values in the descriptor, and link/smoke consumers at
those exact floors. Merely changing the runner label does not prove that
property.

## Windows release host

The Windows release row pins the shared action and complete archive digest:

```text
casselc/jolt-toolchains/setup-chez@095108ae32659757808064d004855092567d3ad3
release: chez-ci-10.4.1.1
```

| Release row | Target | Archive SHA-256 | Capability |
| --- | --- | --- | --- |
| Windows x86_64 | `windows-x86_64` | `360c60496eea2f8aab0e557eb77e9e18b315bb9181938158ae57655aa541b7f8` | `source-runtime,gnu-kernel-dev` |

The action validates the caller-pinned archive digest, internal inventory,
Chez version, machine type, and all four kernel-development files before the
release build starts. The workflow no longer knows where those files were
staged.

MSYS2 remains on Windows because it supplies the GNU linker, POSIX recipe
shell, and lz4/zlib import libraries. It no longer clones or builds Chez. As in
`tests.yml`, `CHEZ` and `JOLT_CHEZ` are translated to MSYS paths because the
release recipes resolve them through `sh`; `JOLT_CHEZ_CSV` stays a native path
because Chez calls `file-exists?` on it.

Homebrew remains the macOS release producer for `chezscheme` and `lz4`.
Replacing that mutable prerequisite is still desirable, but only after a
deployment-floor-aware immutable archive exists.

## Retained source builds are claims

The manylinux2014 build cannot consume the ordinary Linux archive. Doing so
would import the archive producer's newer glibc dependency into the release
and erase the floor the workflow exists to establish. Chez is therefore built
inside the same old-glibc container that links Jolt.

Likewise, a host-native archive does not contain the `bootquick` output,
`xpatch`, target boot files, or cross kernel required by
`tools/cross-compile/make-pack.sh`. The source builds in the macOS x86 target
row and `cross-smoke.yml` remain load-bearing cross-compilation evidence.

`glibc-floor.yml` deliberately builds Chez under each candidate image. Sharing
one prebuilt Chez across those rows would make the experiment answer a
different question.

## Action and permission hygiene

The three W13B workflows now:

- declare read-only contents permission where they do not publish;
- pin checkout, cache, artifact upload/download, and MSYS2 actions to full
  commit identities;
- use Node 24 artifact/cache majors; and
- retain `contents: write` only in the release workflow.

`softprops/action-gh-release` is pinned to the exact commit behind its `v2`
tag. That tagged action still uses Node 20; upstream has a Node 24 development
revision but no tagged Node 24 release. W13B records this remaining warning
rather than switching release publication to an untagged action revision.

## Hosted evidence

The delivery revisions are:

- `9b8bbcaa7a01ed5ef953153f446e4e496504f852`, the initial boundary; and
- `ad07cac1`, which rejects the macOS archive for release linking and anchors
  the packaged dependency test under the short runner temp root; and
- `a2efd8dd`, which returns manylinux container outputs to the hosted-runner
  user before packaged-runtime fixtures write below `target/`; and
- `b2dfd80a`, which teaches the legacy dynamic-manylinux probe its declared
  `libncurses.so.5` runtime dependency without changing the static release
  candidate.

The fork's default branch does not register `release.yml`, so GitHub refuses a
manual dispatch of that path even when a branch ref is supplied. Validation
therefore used a separate branch,
`codex/core-shared-toolchain-w13b-ci`, whose only extra commit adds that branch
as a temporary push trigger. The build logic is byte-identical to the delivery
revision.

Run
[`30423123801`](https://github.com/casselc/jolt/actions/runs/30423123801)
is the deliberate first-contact run. Windows completed the entire release job
on the shared archive. All three POSIX jobs built and smoked their binaries,
then failed the same path-budget assertion because the release workflow had
allowed the runner's long randomized `TMPDIR` to become the dependency-test
cache root. The corrected workflow supplies `${{ runner.temp }}` to that test;
it does not weaken the 80-character production contract.

That run also supplied the macOS deployment-target counterexample described
above. It is why the final boundary is Windows-only even though the shared
macOS runtime itself executed successfully.

Run
[`30459783288`](https://github.com/casselc/jolt/actions/runs/30459783288)
confirmed the short-root correction: macOS ARM completed the entire release
job and Windows passed the same dependency gate. Linux then reached a later
fixture and failed because the root-running manylinux producer had left
`target/` unwritable by the hosted-runner user. W13B fixes the ownership
boundary after the container exits rather than relocating or skipping the
fixture.

At validation revision `61ec97bad304bd33a2945b5ab91e1d88ee9b23c2`,
the ordinary tests
([`30460640872`](https://github.com/casselc/jolt/actions/runs/30460640872)),
release
([`30460640928`](https://github.com/casselc/jolt/actions/runs/30460640928)),
and cross-smoke
([`30460641595`](https://github.com/casselc/jolt/actions/runs/30460641595))
all passed. Release completed all four rows; the Windows row used the shared
archive while Linux and macOS exercised the retained floor-producing paths.

The same revision's glibc-floor run
([`30460640953`](https://github.com/casselc/jolt/actions/runs/30460640953))
built all four artifacts and passed seven of eight runtime/self-contained
jobs. The known non-release dynamic manylinux2014 artifact requires
`libncurses.so.5`, but the Debian retry and build-smoke package lists installed
only `libtinfo6`; its build smoke therefore failed before Jolt could start.
Installing Ubuntu 20.04's `libncurses5` package made the exact downloaded
artifact compile and run the self-contained fixture locally. `b2dfd80a`
applies that observed dependency to both the compatibility retry and the
build-smoke fixture.

Final validation revision
`b3662c311d5c5f2edf5e156ded8e7ab99e0dbd4a` is the delivery tree plus
validation-only push triggers. All four workflows passed:

| Workflow | Run | Result |
| --- | --- | --- |
| ordinary core tests | [`30461678703`](https://github.com/casselc/jolt/actions/runs/30461678703) | 4/4 jobs; Linux x86_64/aarch64, packaged Windows x86_64 Git deps, and Windows ARM64 source runtime |
| release | [`30461679802`](https://github.com/casselc/jolt/actions/runs/30461679802) | 4/4 build/package rows; publication and tap update correctly skipped off-tag |
| cross-smoke | [`30461678761`](https://github.com/casselc/jolt/actions/runs/30461678761) | host baseline, target-pack assembly, cross build, and qemu verification passed |
| glibc-floor | [`30461678441`](https://github.com/casselc/jolt/actions/runs/30461678441) | 4/4 producers and 4/4 runtime/self-contained smoke jobs |

The final Windows release row restored
`chez-ci-10.4.1.1/windows-x86_64` from cache, revalidated archive digest
`360c60496eea2f8aab0e557eb77e9e18b315bb9181938158ae57655aa541b7f8`,
passed the packaged dependency transaction gate with 185 checks, built and
ran a self-contained app, and contained no Chez source-build fallback.
Linux and macOS retained their load-bearing floor/cross producers and passed
the same packaged dependency, self-contained build, runtime-require, and
package stages.

## Static evidence

- The diff from W13A touches only
  `.github/workflows/{cross-smoke,glibc-floor,release}.yml`,
  `ci/glibc-floor-smoke.sh`, and this note.
- Runtime/compiler source, tests, and the W13A workflow are byte-identical.
- `git diff --check` is clean.
- `actionlint` has one finding, unchanged from W13A: its runner catalogue does
  not yet know the valid `windows-11-vs2026-arm` preview label in `tests.yml`.
- The shared toolchain's macOS deployment nonclaim is also recorded publicly
  on `casselc/jolt-toolchains` branch `codex/macos-deployment-contract` at
  `4f5a0901263bdce8a58772782069b2483684eba8`.
- No pull request was opened and no core-Jolt upstream remote was pushed.
