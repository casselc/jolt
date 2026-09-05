# Aspect compiler integration line

The maintained compiler for Jolt aspects lives on the fork-only
`casselc/jolt:integration/aspects` branch. This is the only aspect integration
branch permitted to advance. Aspect packs, instrumentation libraries, and
demos should treat it as the moving integration line. Consumers still pin an
exact verified commit; the branch name is a coordination point, not a
reproducible dependency version.

## Current provenance epoch

The current line was built on the source tree released as Jolt v0.8.1.
Upstream later rewrote the release history and moved the tag without changing
that tree:

| Fact | Revision |
| --- | --- |
| Historical v0.8.1 base in this line | `9b7683953b444ece2a2e783e8fa46d31177bb476` |
| Live rewritten v0.8.1 release commit | `51f10a0239096f804a6017f850b7b235ebe40168` |
| Tree shared by both commits | `1179a2730c7098b1cc65ec6becdc36309d87d55e` |
| First aspect compiler commit | `b89f801aed85d572225474504011a340d0e39a2b` |
| Initial canonical verified ancestor | `88821cf18b32a11b9b9c934b909ff187bf56e043` |

`config/aspect-integration.lock` is the machine-readable copy of these facts.
The verifier proves that the historical base has the recorded tree, that the
first aspect commit is its direct child, and that the checked revision retains
the aspect root and verified anchor in its ancestry. Its online mode separately
proves that the live upstream release tag still resolves to the recorded commit
and tree. A tag move therefore fails visibly even when its files happen to be
unchanged.

`tools/version.sh` also consumes the lock when `HEAD` descends from the recorded
aspect root. It reports the locked upstream release plus the commit distance
and current SHA, producing the same identity that restoring the historical tag
would produce without moving any local ref. This keeps local builds,
`jolt --version`, dependency minimum-version checks, and hosted builds aligned
even after an upstream tag rewrite. Revisions outside the aspect lineage retain
the ordinary nearest-release-tag behavior. A shallow checkout which cannot
resolve the recorded aspect root also falls back to that generic behavior; the
dedicated canonical workflow remains full-history and fails closed through the
provenance verifier.

`ASPECT_INTEGRATION_REVISION` selects the commit to check and defaults to
`HEAD`. `ASPECT_INTEGRATION_REQUIRE` defaults to `0`, which lets repository-wide
CI skip a revision outside the aspect lineage; the dedicated canonical workflow
sets it to `1` and fails closed instead.

The immutable record for this epoch is
[`docs/aspect-compiler-epochs/v0.8.1-2026-09.md`](aspect-compiler-epochs/v0.8.1-2026-09.md).
Every later epoch adds another file under `docs/aspect-compiler-epochs/`; a
history rewrite includes its old-to-new commit map there. The active lock
always describes only the current epoch.

## Evidence ledger

Cross-repository correctness and provenance are owned by
[`chucklehead-dev/jolt-aspect-packs` issue #1](https://github.com/chucklehead-dev/jolt-aspect-packs/issues/1).
The consolidated execution roadmap is
[issue #69](https://github.com/chucklehead-dev/jolt-aspect-packs/issues/69), and
consumer compiler pins live in that repository's `targets.edn`. Each canonical
compiler merge records its source SHA, upstream base commit and tree, Chez
version, focused and full gates, reviewer result, and affected consumer pins in
that ledger and links the entry from the roadmap. Epoch maps are committed in
this repository and linked from the same ledger entry.

## Branch workflow

1. Fetch `fork/integration/aspects` and branch from its exact tip.
2. Keep one concern per pull request. Compiler behavior changes include a
   focused regression test and, where relevant, a stock-upstream reproducer.
3. Run the focused tests first. Run heavy compiler builds serially with Chez
   Scheme 10.4.1, and retain the exact source and binary identities in the
   evidence.
4. Run the offline provenance verifier. Before merge, run its online upstream
   check or use the corresponding hosted CI result.
5. Obtain independent code and pull-request prose review, then merge into
   `integration/aspects` without rebasing or force-pushing it.
6. Advance consumer pins only to the reviewed merge result and update the
   evidence ledger above with source SHA, upstream base commit and tree,
   toolchain, passed gates, and affected consumer pins.

## Existing branch classification and cleanup

| Ref family | Status |
| --- | --- |
| `integration/aspects` | Canonical; the only aspect integration ref permitted to advance |
| `integration/aspects-v081-flow`, `integration/aspects-v081-flow-pre-effects`, `fix/effect-summary-closure-index` | Merged ancestors; remove after this policy lands and the pin/ledger audit remains clean |
| `prep/aspects-*` | Frozen construction and review evidence; preserve until each unique stage is reconciled with pins and the ledger |
| `integration/aspects-v08-current`, `codex/aspects-current-main`, `codex/aspects-current-ffi-main` | Quarantined divergent research snapshots; never use as current or as consumer pins |
| `codex/aspect-manifest-build-hook`, `codex/v0728-aspects-ffi-loans` | Quarantined snapshots with work ahead of canonical; recover wanted patches through a fresh PR based on `integration/aspects`, never by merging or fast-forwarding the snapshot |
| `canary/aspects-upstream-main` | Reserved name for a resettable advisory canary; no such canary is currently designated |

Any other persistent ref matching `*aspect*` is unclassified and must not be
treated as current until it is added to this table. A transient pull-request
head based on the canonical branch is work in progress, never another current
line.

For every cleanup candidate, inspect its local worktree cleanliness, ancestry,
patch equivalence, exact consumer pins, and evidence-ledger references. If its
tip is an ancestor of `integration/aspects` and no pin or unique ledger stage
needs the ref, removing the ref loses no commit. If its tip is not reachable,
first preserve it under a dated `archive/*` ref and record that mapping in the
ledger. Never delete an exact consumer pin.

## Upstream updates

Production pins follow upstream releases rather than the moving upstream
`main`. A current-main canary may report compatibility early, but it is signal
only and never silently advances consumers.

Prepare each release update on a temporary versioned sync branch. If upstream
ancestry is stable, merge the release into the canonical line and resolve the
aspect delta there. If upstream rewrites history, preserve the existing line,
replay the delta once onto the recorded release commit, publish an old-to-new
commit and tree map in a new `docs/aspect-compiler-epochs/` record, and join the
new provenance epoch without force-updating the canonical branch. Update the
active lock and evidence ledger in the same reviewed change. Changing the
canonical branch name requires an explicit lock and verifier update as part of
that epoch transition.

Never rely on a tag name alone. Record both its peeled commit and tree, and
compare both during the update.

## CI bootstrap

For a same-repository pull request, GitHub evaluates the workflow from the
synthetic merge commit. The pull request which first installs the dedicated
workflow therefore receives the same strict, full-history gate as later pull
requests targeting `integration/aspects`; the resulting branch push runs it
again after merge.
