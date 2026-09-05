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

# (e) not a git checkout at all
mkdir -p "$tmp/plain"
got="$("$script" "$tmp/plain")"
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

# (g) every consumer goes through the script; none re-derives it inline
for f in bin/jolt host/chez/build-jolt.ss .github/workflows/release.yml; do
  grep -q 'tools/version.sh' "$root/$f" || fail "$f does not use tools/version.sh"
  if grep -n 'describe --' "$root/$f"; then
    fail "$f runs git describe itself; use tools/version.sh"
  fi
done

echo "version-smoke: ok (release tags only; locked aspect ancestry names its release)"
