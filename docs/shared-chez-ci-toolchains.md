# Shared Chez CI toolchains

## Status

Proposed for the `casselc/jolt` fork. The Linux x86_64 archive shape has been
prototyped locally; no toolchain asset, tag, release, or public setup action has
been created.

This is a CI provisioning design, not a Jolt or Chez distribution claim. It
does not alter Jolt's compiler, packaging backends, supported targets, or the
separate evidence categories in
[`windows-toolchains-and-validation.md`](windows-toolchains-and-validation.md).

## Motivation

The Jolt proposal stack currently builds official Chez Scheme 10.4.1 from
source in core, jolt-net, jolt-tcp, jolt-http, jolt-hegel, and jolt-crypto.
Those workflows have converged on materially the same recipes:

- Linux and macOS install to `~/chez` with threads enabled and X11 disabled;
- Windows x86_64 builds `ta6nt` under MSYS2/MINGW64 and stages executables,
  boot files, `scheme.h`, and `libkernel.a`; and
- Windows ARM64 builds native `tarm64nt` with the MSVC-supported
  `build.bat tarm64nt /only` path.

Per-repository caching is effective after the first run. For example,
jolt-crypto run
[`30377886592`](https://github.com/casselc/jolt-crypto/actions/runs/30377886592)
cold-built all six targets in roughly 3–9 minutes per job. Its immediate
follow-up,
[`30380719100`](https://github.com/casselc/jolt-crypto/actions/runs/30380719100),
restored all six caches, skipped every Chez build, and completed each job in
roughly 24–85 seconds.

That does not remove cross-repository duplication. GitHub's cache lookup is
scoped to branches in the same repository, caches can be evicted, and GitHub
describes caches as regenerable optimization rather than durable build output:

- <https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching>
- <https://docs.github.com/en/actions/concepts/workflows-and-actions/dependency-caching>

The missing layer is one durable, independently verifiable toolchain build
that every repository can consume on its first run while retaining an exact
source-build fallback.

## Decision

Produce relocatable, checksum-pinned Chez CI toolchain archives in a dedicated
public repository and consume them through one commit-pinned composite setup
action.

A separate repository is preferred over attaching third-party toolchains to a
Jolt fork release:

- it does not mix CI substrate tags with Jolt product releases;
- its release and workflow permissions form a smaller trust boundary;
- it can be transferred to the Jolt organization independently; and
- downstream consumers name exactly the toolchain producer they trust.

The provisional name is `casselc/jolt-toolchains`. Creating that repository or
publishing a release requires an explicit owner decision; this proposal does
neither.

Workflow artifacts are not the durable distribution mechanism. They are tied
to workflow-run retention and deletion. Public immutable release assets are
stable download targets, can be fetched without a repository token, and can
carry release and build-provenance attestations:

- <https://docs.github.com/en/actions/concepts/workflows-and-actions/workflow-artifacts>
- <https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases>
- <https://docs.github.com/en/actions/concepts/security/artifact-attestations>

## Artifact contract

Each archive has one target and one declared capability set. A consumer must
not infer packaging support merely because `scheme` starts.

| Target | Chez machine | Required capability |
| --- | --- | --- |
| Linux x86_64 | `ta6le` | `source-runtime`, `gnu-kernel-dev` |
| Linux aarch64 | `tarm64le` | `source-runtime`, `gnu-kernel-dev` |
| macOS x86_64 | `ta6osx` | `source-runtime`, `gnu-kernel-dev` |
| macOS arm64 | `tarm64osx` | `source-runtime`, `gnu-kernel-dev` |
| Windows x86_64 / MinGW | `ta6nt` | `source-runtime`, `gnu-kernel-dev` |
| Windows ARM64 / MSVC | `tarm64nt` | `source-runtime`, `msvc-kernel-dev` |

`gnu-kernel-dev` means the staged tree has the `scheme.h`, boot files, and
`libkernel.a` contract the current Jolt packager consumes.
`msvc-kernel-dev` records Chez's native `.lib`/object contract and does **not**
claim that the current GNU-oriented `joltc` packager can use it.

Archive names are versioned independently of their payload:

```text
chez-ci-10.4.1.1-linux-x86_64-ta6le.tar.zst
chez-ci-10.4.1.1-linux-aarch64-tarm64le.tar.zst
chez-ci-10.4.1.1-macos-x86_64-ta6osx.tar.zst
chez-ci-10.4.1.1-macos-arm64-tarm64osx.tar.zst
chez-ci-10.4.1.1-windows-x86_64-ta6nt.zip
chez-ci-10.4.1.1-windows-arm64-tarm64nt.zip
```

The final numeric component is the archive/recipe revision. Changing build
flags, staged files, wrappers, compiler family, or manifest semantics requires
a new revision even when Chez stays at 10.4.1.

Every archive is accompanied by a canonical EDN or JSON manifest containing:

- archive schema and recipe revision;
- Chez version, source tag, source commit, and submodule commits;
- target OS, architecture, machine type, compiler family, and build flags;
- the exact capability set;
- the expected extraction root and executable;
- a sorted path/size/SHA-256 inventory of the extracted tree;
- the producer repository, workflow, commit, and run;
- the archive SHA-256; and
- the semantic verification commands and their results.

The release carries one checksum manifest covering all release assets. The
producer also generates a build-provenance attestation. Consumers always check
the repository-pinned SHA-256 before extraction; attestation verification is an
additional provenance check, not a substitute for the pinned digest.

## Producer invariants

The producer workflow must fail closed unless all of these hold:

1. Chez source is the exact 10.4.1 tag and the recorded commit/submodules match.
2. The native compiler and runner architecture match the declared target.
3. The extracted executable reports exactly `10.4.1`.
4. `(machine-type)` equals the artifact's declared Chez machine.
5. The declared capability files exist and have nonzero length.
6. A source-mode Jolt target-descriptor gate passes on the native target.
7. The archive can be extracted outside its build directory and repeats 3–6.
8. The manifest inventory matches the extracted archive byte-for-byte.
9. No cache, credentials, temporary source tree, or unrelated runner state is
   present in the archive.
10. The release aggregation job receives exactly one verified asset per
    declared target before it can publish.

Publishing should follow GitHub's immutable-release sequence: create a draft,
attach the complete asset set, then publish. The release tag is never reused or
force-moved.

## Consumer contract

Downstream workflows call an action pinned to a full producer commit:

```yaml
- uses: casselc/jolt-toolchains/setup-chez@<full-commit>
  with:
    version: 10.4.1
    target: linux-x86_64
    capabilities: source-runtime,gnu-kernel-dev
```

The action:

1. validates its inputs against a checked-in target table;
2. restores the caller repository's ordinary extracted-tree cache;
3. on a miss, downloads the immutable release asset and manifest;
4. verifies the pinned archive SHA-256 before extraction;
5. validates the extracted inventory, version, machine, and capabilities;
6. publishes `CHEZ`, `JOLT_CHEZ`, `JOLT_CHEZ_CSV`, and `PATH` consistently;
7. saves the caller-local cache only after validation; and
8. optionally performs the exact source build when the release is unavailable.

The source fallback is explicit in logs and uses the same producer recipe. It
must pass the same postconditions. A fallback does not silently weaken a
requested capability; for example, an MSVC ARM64 tree cannot satisfy
`gnu-kernel-dev`.

The action never restores or distributes Jolt AOT output, Git dependency
caches, native application libraries, credentials, or user code. Those have
different ownership and invalidation rules.

## Local archive prototype

The installed Linux x86_64 Chez 10.4.1 tree was copied to a new temporary root
and exercised from that root:

```text
installed tree: 6.0 MiB
tar.zst archive: 3,522,653 bytes
relocated `chez --version`: 10.4.1
relocated `(machine-type)`: ta6le
relocated Jolt target descriptor: 33/33 passed
```

This establishes that the selected POSIX install-tree shape is relocatable
enough for the source-runtime consumer. It does not establish reproducible
archive bytes, the other five targets, the producer trust chain, or a published
asset. Those remain gates, not assumptions.

## Rejected approaches

### Keep only per-repository caches

This is already effective for warm runs but makes every repository pay the
same cold source build and leaves the recipe duplicated in every workflow.

### Weaken or broaden cache keys

The existing keys are not the problem. Removing target or recipe identity
would risk restoring an ABI-incompatible executable. A cache is also not a
durable cross-repository release channel.

### Download workflow artifacts by run ID

Workflow artifacts are appropriate between jobs in one build, but retention,
run deletion, API discovery, and expiring redirect URLs make them a poor
long-lived downstream toolchain contract.

### Use an operating-system Chez package everywhere

The platform packages are not one uniform contract. Some omit the kernel
development files required by `joltc build`; Windows x86_64's official MSVC
package does not satisfy the current GNU `libkernel.a` packager; and exact
versions vary by image.

### Treat the official Windows installer as deficient

It is a valid MSVC Chez distribution. The mismatch is with Jolt's current
GNU-oriented packager, not with source-runtime execution or Chez. Capability
labels preserve that distinction.

### Put toolchains in the Jolt source repository or Git history

Vendored binaries bloat clones and blur source review with generated assets.
Immutable, attested release assets keep the generated boundary explicit.

### Use a container image

A container could help Linux but cannot validate native macOS, Winsock, or
Windows ARM64 behavior. It would fragment rather than unify the six-target
contract.

## Implementation sequence

1. Create the dedicated public toolchain repository after owner approval.
2. Move the already-proven six recipes into one producer matrix without
   changing their compiler families or staged layouts.
3. Add manifest generation, relocation checks, native Jolt smoke tests, and
   build-provenance attestations.
4. Publish a draft `chez-ci-10.4.1.1` release, verify every asset from a clean
   consumer job, then publish it immutably.
5. Implement the commit-pinned composite consumer action with a source fallback.
6. Convert jolt-crypto first as the six-target canary. Require the same 26/26
   provider gate and compare cold/warm timings.
7. Convert jolt-net, jolt-tcp, jolt-http, and jolt-hegel one at a time, retaining
   their existing source-build path until each repository has a green public
   run with the shared asset.
8. Convert core last because its Linux and Windows x86_64 jobs additionally
   consume `gnu-kernel-dev` for packaged-build gates.
9. Remove duplicated recipes only after the source fallback and exact
   capability checks are proven in every consumer.

## Open owner decision

Before publication, choose whether to create `casselc/jolt-toolchains` and
enable immutable releases there. The dedicated repository is recommended.
Keeping the producer inside `casselc/jolt` is mechanically possible but mixes
third-party CI assets with Jolt's release namespace and makes later ownership
transfer less clean.
