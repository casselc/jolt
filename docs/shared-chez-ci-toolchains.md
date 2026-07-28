# Shared Chez CI toolchains

## Status

Implemented in the public
[`casselc/jolt-toolchains`](https://github.com/casselc/jolt-toolchains)
repository. Immutable release
[`chez-ci-10.4.1.1`](https://github.com/casselc/jolt-toolchains/releases/tag/chez-ci-10.4.1.1)
contains the six target archives and their manifests/checksums. The composite
setup action is consumed by full commit rather than by a mutable branch or tag.

Hosted build
[`30387667337`](https://github.com/casselc/jolt-toolchains/actions/runs/30387667337)
passed six native producers and six clean consumers at
`1c3067ae6db81d412339cadc0f6d8261f29a91a6`. The immutable release tag resolves
to that exact commit. Its signed release attestation and all 19 individual asset
subjects were verified after publication.

This is a CI provisioning design, not a Jolt or Chez distribution claim. It
does not alter Jolt's compiler, packaging backends, supported targets, or the
separate evidence categories in
[`windows-toolchains-and-validation.md`](windows-toolchains-and-validation.md).

## Motivation

Before the shared release, the Jolt proposal stack built official Chez Scheme
10.4.1 from source independently in core, jolt-net, jolt-tcp, jolt-http,
jolt-hegel, and jolt-crypto. Those workflows had converged on materially the
same recipes:

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

The shared release supplies one durable, independently verifiable toolchain
build that every repository can consume on its first run. Migration remains
per-repository and evidence-driven; the old source recipe remains in a consumer
until that repository's shared-toolchain branch is green.

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

The selected repository is `casselc/jolt-toolchains`. Keeping the producer
separate from the Jolt fork preserves the ownership and future-transfer
boundaries above.

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
| Windows ARM64 / MSVC | `tarm64nt` | `source-runtime` |

`gnu-kernel-dev` means the staged tree has the `scheme.h`, boot files, and
`libkernel.a` contract the current Jolt packager consumes.
The Windows ARM64 archive deliberately makes no kernel-development claim:
native MSVC Chez is sufficient for source-mode Jolt, while the current
GNU-oriented `joltc` packager cannot consume its `.lib`/object contract.

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

Each archive contains a canonical JSON tree manifest containing:

- archive schema and recipe revision;
- Chez version, source tag, source commit, and submodule commits;
- target OS, architecture, machine type, compiler family, and build flags;
- the exact capability set;
- the expected extraction root and executable;
- a sorted path/size/SHA-256 inventory of the extracted tree;
- the producer repository, workflow, commit, and run;
- the semantic verification commands and their results.

Beside each archive, the release carries a small JSON descriptor binding the
archive bytes and internal-manifest digest to the producer repository, commit,
run ID, and attempt. Individual checksum files and `SHA256SUMS` cover the exact
18 archive/descriptor/checksum assets.

GitHub's immutable-release attestation covers the release tag, target commit,
and all 19 published asset digests. Producer identity is additionally recorded
and checked in the manifests; this first recipe does not claim a separate
GitHub-signed build-provenance attestation for each producer job. Consumers
always check their repository-pinned archive SHA-256 before extraction.

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
- uses: casselc/jolt-toolchains/setup-chez@1c3067ae6db81d412339cadc0f6d8261f29a91a6
  with:
    target: linux-x86_64
    release-tag: chez-ci-10.4.1.1
    sha256: 16476cd98fb5cb2e2c0285e88fcd6d57ade9392ca8d7cf603ca38432b4118526
    capabilities: source-runtime,gnu-kernel-dev
```

The action:

1. validates its inputs against a checked-in target table;
2. restores only the checksum-keyed release archive from the caller's ordinary
   Actions cache;
3. on a miss, downloads the immutable release archive;
4. verifies the pinned archive SHA-256 before extraction;
5. extracts into a fresh directory and validates its internal inventory,
   source identity, version, machine, and capabilities;
6. publishes `CHEZ`, `JOLT_CHEZ`, `JOLT_CHEZ_CSV`, and `PATH` consistently;
7. saves the caller-local archive cache only after validation.

There is no silent source-build fallback. Download, checksum, inventory,
machine, or capability failure fails the job. A consumer may retain its old
source recipe as an explicit separate workflow path during migration, but the
shared action never changes compiler family or weakens a requested capability.
For example, the MSVC ARM64 tree cannot satisfy `gnu-kernel-dev`.

The action never restores or distributes Jolt AOT output, Git dependency
caches, native application libraries, credentials, or user code. Those have
different ownership and invalidation rules.

## Hosted evidence

Build run `30387667337` produced and consumed all six target archives on their
native hosted runners:

| Target | Producer | Clean consumer |
| --- | --- | --- |
| Linux x86_64 | success | success |
| Linux aarch64 | success | success |
| macOS x86_64 | success | success |
| macOS arm64 | success | success |
| Windows x86_64 | success | success |
| Windows ARM64 | success | success |

Each producer checked exact Chez source/submodules, compiler target, native
runner architecture, Chez version and machine type, capability files, a pinned
Jolt source expression, relocation, and the internal inventory. Each clean
consumer downloaded the producer artifact, extracted it into a new directory
through the same composite action, repeated the semantic checks, and built a
self-contained Jolt executable where `gnu-kernel-dev` is declared.

The published asset set was independently downloaded after upload, compared
byte-for-byte with the verified producer set, checked through `SHA256SUMS`, and
revalidated as six release contracts before publication. After publication:

- `refs/tags/chez-ci-10.4.1.1` resolved exactly to `1c3067ae...`;
- GitHub reported the release immutable;
- the signed release attestation covered that commit and all 19 assets; and
- `gh release verify-asset` accepted each downloaded asset independently.

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

1. **Complete:** create the dedicated public toolchain repository.
2. **Complete:** move the six proven recipes into one producer matrix without
   changing compiler families or staged layouts.
3. **Complete:** add internal manifests, release descriptors, relocation
   checks, native Jolt smoke tests, and six clean consumers.
4. **Complete:** build all targets at one exact commit and publish the verified
   asset set as immutable release `chez-ci-10.4.1.1`.
5. **Complete:** provide the commit-pinned composite action with
   checksum-pinned archive caching and fresh extraction.
6. **In progress:** convert jolt-hegel as the first real six-target consumer,
   preserving its direct aggregate-FFI, checksum, and Git-dependency gates and
   comparing cold/warm timings.
7. Convert jolt-net, jolt-tcp, jolt-http, and jolt-crypto one at a time. Each
   repository's migration branch is its canary; do not merge a branch whose
   native matrix is weaker than the source-build baseline.
8. Convert core last because its Linux, macOS, and Windows x86_64 packaged-build
   jobs additionally consume `gnu-kernel-dev`.
9. Remove each duplicated recipe only after that repository has exact hosted
   evidence through the shared action.

## Future ownership

The repository is intentionally separable from the Jolt fork. If the Jolt
organization accepts this CI substrate, transfer the repository, preserve the
immutable recipe tag, and repin consumer action/release repository coordinates
in ordinary reviewed commits. The archives remain CI inputs, not Jolt product
releases.
