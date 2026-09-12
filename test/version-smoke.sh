#!/usr/bin/env bash
# tools/version.sh is the one definition of a checkout's version: what
# `jolt --version` says when nothing bakes one in. Three things consume it
# (bin/jolt, build-jolt.ss, the release workflow's meta job), and the property
# that matters is lost by editing any one of them back to a bare `git describe`:
# the rolling `vnightly` tag the nightly workflow moves to main's head is the
# NEAREST tag from main, so a plain `git describe --tags` answers "vnightly" on
# every clone that has fetched it — and jolt.deps reads a version with no
# numeric part as one no :jolt/min-version floor applies to.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/tools/version.sh"
fail() { echo "version-smoke: $*" >&2; exit 1; }

[ -x "$script" ] || fail "tools/version.sh is missing or not executable"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo"
g() { git -C "$repo" -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
g init -q
echo one > "$repo/f"
g add f
g commit -q -m one
g tag v0.1.0
echo two > "$repo/f"
g commit -q -am two
sha="$(g rev-parse --short HEAD)"

# (a) the rolling tag at HEAD is not the version: release tags only
g tag vnightly
got="$("$script" "$repo")"
[ "$got" = "v0.1.0-1-g$sha" ] || fail "with vnightly at HEAD: got '$got', want 'v0.1.0-1-g$sha'"

# (b) edits in the tree say so (the AOT cache key rides on the version string)
echo three > "$repo/f"
got="$("$script" "$repo")"
[ "$got" = "v0.1.0-1-g$sha-dirty" ] || fail "dirty tree: got '$got', want 'v0.1.0-1-g$sha-dirty'"
g checkout -q -- f

# (c) on the release tag itself: the tag, nothing else
g checkout -q v0.1.0
got="$("$script" "$repo")"
[ "$got" = "v0.1.0" ] || fail "on the tag: got '$got', want 'v0.1.0'"
g checkout -q main

# (d) no release tag reachable (a shallow clone; a tree tagged only vnightly):
#     the sha, prefixed — a bare 0a1b2c3 would read as version 0 to every floor
g tag -d v0.1.0 >/dev/null
got="$("$script" "$repo")"
[ "$got" = "dev-g$sha" ] || fail "no release tag: got '$got', want 'dev-g$sha'"

# (e) not a git checkout at all. GIT_CEILING_DIRECTORIES is not decoration:
# make exports TMPDIR into the checkout (.cache/local/tmp, from makes'
# local.mk), so on a provisioned dev machine this mktemp directory is INSIDE
# the jolt repo — git discovery walks up out of it and version.sh answers the
# repo's own version, which is the right answer to a question this case did
# not mean to ask. The ceiling stops the walk at $tmp, so the case asks about
# no repo wherever mktemp puts it. CI never saw this: it runs `make CHEZ=...`,
# which skips provisioning and leaves TMPDIR alone.
mkdir -p "$tmp/plain"
got="$(GIT_CEILING_DIRECTORIES="$tmp" "$script" "$tmp/plain")"
[ "$got" = "dev" ] || fail "outside git: got '$got', want 'dev'"

# (f) the aspect line names itself from its provenance lock when a rewritten
#     upstream release tag is not reachable from the preserved history.
aspect_repo="$tmp/aspect-repo"
mkdir -p "$aspect_repo"
ag() { git -C "$aspect_repo" -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
ag init -q
echo foundation > "$aspect_repo/f"
ag add f
ag commit -q -m foundation
aspect_grandparent="$(ag rev-parse HEAD)"
echo base > "$aspect_repo/f"
ag commit -q -am base
aspect_base="$(ag rev-parse HEAD)"
ag tag v0.7.0
echo aspect > "$aspect_repo/f"
ag commit -q -am aspect-root
aspect_root="$(ag rev-parse HEAD)"
mkdir -p "$aspect_repo/config"
cat > "$aspect_repo/config/aspect-integration.lock" <<EOF
schema=1
upstream_release=v0.8.1
upstream_base_commit=$aspect_base
aspect_root_commit=$aspect_root
EOF
ag add config/aspect-integration.lock
ag commit -q -m lock
cp "$aspect_repo/config/aspect-integration.lock" "$tmp/valid-aspect.lock"
aspect_sha="$(ag rev-parse --short HEAD)"
got="$("$script" "$aspect_repo")"
[ "$got" = "v0.8.1-2-g$aspect_sha" ] ||
  fail "locked aspect line: got '$got', want 'v0.8.1-2-g$aspect_sha'"
echo dirty >> "$aspect_repo/f"
got="$("$script" "$aspect_repo")"
[ "$got" = "v0.8.1-2-g$aspect_sha-dirty" ] ||
  fail "dirty locked aspect line: got '$got', want 'v0.8.1-2-g$aspect_sha-dirty'"
ag checkout -q -- f
echo schema=1 >> "$aspect_repo/config/aspect-integration.lock"
if "$script" "$aspect_repo" >"$tmp/duplicate.out" 2>"$tmp/duplicate.err"; then
  fail "duplicate aspect lock key unexpectedly succeeded"
fi
grep -q 'invalid aspect integration lock key: schema' "$tmp/duplicate.err" ||
  fail "duplicate aspect lock key did not fail at the named key"
ag checkout -q -- config/aspect-integration.lock
sed -i "s/^upstream_base_commit=.*/upstream_base_commit=$aspect_grandparent/" \
  "$aspect_repo/config/aspect-integration.lock"
if "$script" "$aspect_repo" >"$tmp/parent.out" 2>"$tmp/parent.err"; then
  fail "non-parent aspect base unexpectedly succeeded"
fi
grep -q 'locked upstream base is not the aspect root parent' "$tmp/parent.err" ||
  fail "non-parent aspect base did not fail at the exact-parent check"
ag checkout -q -- config/aspect-integration.lock

# A checkout with the lock but outside the recorded lineage, including one
# whose historical root object is unavailable, retains generic tag behavior.
ag checkout -q -b outside "$aspect_base"
mkdir -p "$aspect_repo/config"
cp "$tmp/valid-aspect.lock" "$aspect_repo/config/aspect-integration.lock"
ag add config/aspect-integration.lock
ag commit -q -m outside-lock
outside_sha="$(ag rev-parse --short HEAD)"
got="$("$script" "$aspect_repo")"
[ "$got" = "v0.7.0-1-g$outside_sha" ] ||
  fail "off-lineage lock: got '$got', want 'v0.7.0-1-g$outside_sha'"
sed -i 's/^aspect_root_commit=.*/aspect_root_commit=0000000000000000000000000000000000000000/' \
  "$aspect_repo/config/aspect-integration.lock"
ag commit -q -am missing-root
missing_sha="$(ag rev-parse --short HEAD)"
got="$("$script" "$aspect_repo")"
[ "$got" = "v0.7.0-2-g$missing_sha" ] ||
  fail "missing-root lock: got '$got', want 'v0.7.0-2-g$missing_sha'"

# (g) a canonical epoch join may retain an unrelated historical line as its
#     first parent while joining the replay descended from the locked base as
#     its second parent. Only commits on an ancestry path from that base count
#     toward the release distance; merely reachable historical commits do not.
epoch_repo="$tmp/epoch-repo"
mkdir -p "$epoch_repo"
eg() { git -C "$epoch_repo" -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
eg init -q
echo historical > "$epoch_repo/f"
eg add f
eg commit -q -m historical-root
echo historical-2 > "$epoch_repo/f"
eg commit -q -am historical-2
echo historical-3 > "$epoch_repo/f"
eg commit -q -am historical-3
historical_tip="$(eg rev-parse HEAD)"
epoch_tree="$(eg rev-parse HEAD^{tree})"
epoch_base="$(printf 'current-base\n' | eg commit-tree "$epoch_tree")"
epoch_root="$(printf 'aspect-root\n' | eg commit-tree "$epoch_tree" -p "$epoch_base")"
replay_one="$(printf 'replay-one\n' | eg commit-tree "$epoch_tree" -p "$epoch_root")"
replay_tip="$(printf 'replay-tip\n' | eg commit-tree "$epoch_tree" -p "$replay_one")"
epoch_join="$(printf 'epoch-join\n' | eg commit-tree "$epoch_tree" \
  -p "$historical_tip" -p "$replay_tip")"
mkdir -p "$epoch_repo/config"
cat > "$epoch_repo/config/aspect-integration.lock" <<EOF
schema=1
upstream_release=v0.8.3
upstream_base_commit=$epoch_base
aspect_root_commit=$epoch_root
EOF

eg checkout -q --detach "$replay_tip"
replay_sha="$(eg rev-parse --short HEAD)"
got="$("$script" "$epoch_repo")"
[ "$got" = "v0.8.3-3-g$replay_sha" ] ||
  fail "replay distance: got '$got', want 'v0.8.3-3-g$replay_sha'"

eg checkout -q --detach "$epoch_join"
join_sha="$(eg rev-parse --short HEAD)"
reachable_distance="$(eg rev-list --count "$epoch_base..HEAD")"
[ "$reachable_distance" -gt 4 ] ||
  fail "epoch fixture control did not include historical reachable commits"
got="$("$script" "$epoch_repo")"
[ "$got" = "v0.8.3-4-g$join_sha" ] ||
  fail "epoch join distance: got '$got', want 'v0.8.3-4-g$join_sha' (all reachable: $reachable_distance)"

# Schema 3 retains the historical aspect-root base while anchoring a rewritten
# live release lineage at a tree-equivalent base. The version consumer must not
# accept that schema while ignoring its new lineage field.
live_base="$(printf 'live-base\n' | eg commit-tree "$epoch_tree" -p "$historical_tip")"
live_release="$(printf 'live-release\n' | eg commit-tree "$epoch_tree" -p "$live_base")"
schema3_join="$(printf 'schema3-join\n' | eg commit-tree "$epoch_tree" \
  -p "$epoch_join" -p "$live_release")"
eg checkout -q --detach "$schema3_join"
cat > "$epoch_repo/config/aspect-integration.lock" <<EOF
schema=3
upstream_release=v0.8.6
upstream_base_commit=$epoch_base
upstream_base_tree=$epoch_tree
upstream_release_base_commit=$live_base
upstream_release_commit=$live_release
aspect_root_commit=$epoch_root
EOF
eg add config/aspect-integration.lock
eg commit -q -m schema3-lock
schema3_sha="$(eg rev-parse --short HEAD)"
got="$("$script" "$epoch_repo")"
[ "$got" = "v0.8.6-2-g$schema3_sha" ] ||
  fail "schema 3 distance: got '$got', want 'v0.8.6-2-g$schema3_sha'"
sed -i '/^upstream_release_base_commit=/d' "$epoch_repo/config/aspect-integration.lock"
if "$script" "$epoch_repo" >"$tmp/schema3-missing.out" 2>"$tmp/schema3-missing.err"; then
  fail "schema 3 lock without its release-lineage base unexpectedly succeeded"
fi
grep -q 'invalid aspect integration lock key: upstream_release_base_commit' \
  "$tmp/schema3-missing.err" ||
  fail "schema 3 missing release-lineage base did not fail at the named key"

# (h) every consumer goes through the script; none re-derives it inline
for f in bin/jolt host/chez/build-jolt.ss tools/testbin-current.sh \
         .github/workflows/release.yml; do
  grep -q 'tools/version.sh' "$root/$f" || fail "$f does not use tools/version.sh"
  if grep -n 'describe --' "$root/$f"; then
    fail "$f runs git describe itself; use tools/version.sh"
  fi
done

echo "version-smoke: ok (release tags only; locked aspect ancestry names its release)"
