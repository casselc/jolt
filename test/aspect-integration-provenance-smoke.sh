#!/usr/bin/env bash
set -euo pipefail
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=

root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$root/config/aspect-integration.lock"
fail() { echo "aspect-integration-provenance: $*" >&2; exit 1; }

[ -f "$lock" ] || fail "missing $lock"

expected_keys='aspect_root_commit
canonical_branch
schema
upstream_base_commit
upstream_release
upstream_release_commit
upstream_repository
upstream_tree
verified_ancestor'
actual_keys="$(sed -n 's/^\([^=#][^=]*\)=.*$/\1/p' "$lock" | LC_ALL=C sort)"
[ "$actual_keys" = "$expected_keys" ] || fail "lock keys are missing, duplicated, or unknown"

value() {
  local key="$1" result
  result="$(sed -n "s/^${key}=//p" "$lock")"
  [ -n "$result" ] || fail "missing value for $key"
  printf '%s\n' "$result"
}

schema="$(value schema)"
canonical_branch="$(value canonical_branch)"
upstream_repository="$(value upstream_repository)"
upstream_release="$(value upstream_release)"
upstream_base_commit="$(value upstream_base_commit)"
upstream_release_commit="$(value upstream_release_commit)"
upstream_tree="$(value upstream_tree)"
aspect_root_commit="$(value aspect_root_commit)"
verified_ancestor="$(value verified_ancestor)"
revision="${ASPECT_INTEGRATION_REVISION:-HEAD}"
require_lineage="${ASPECT_INTEGRATION_REQUIRE:-0}"

[ "$schema" = 1 ] || fail "unsupported lock schema $schema"
[ "$canonical_branch" = integration/aspects ] || fail "unexpected canonical branch $canonical_branch"
[ "$require_lineage" = 0 ] || [ "$require_lineage" = 1 ] ||
  fail "ASPECT_INTEGRATION_REQUIRE must be 0 or 1"
[[ "$upstream_release" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid upstream release $upstream_release"
[[ "$upstream_repository" =~ ^https://github\.com/[^/]+/[^/]+\.git$ ]] || fail "invalid upstream repository"

for name in upstream_base_commit upstream_release_commit upstream_tree aspect_root_commit verified_ancestor; do
  candidate="${!name}"
  [[ "$candidate" =~ ^[0-9a-f]{40}$ ]] || fail "$name is not a full lowercase Git object id"
done

git -C "$root" cat-file -e "$revision^{commit}" 2>/dev/null ||
  fail "revision $revision is not a commit in this checkout"
if ! git -C "$root" cat-file -e "$aspect_root_commit^{commit}" 2>/dev/null ||
   ! git -C "$root" merge-base --is-ancestor "$aspect_root_commit" "$revision"; then
  if [ "$require_lineage" = 1 ]; then
    fail "$revision does not descend from the recorded aspect root"
  fi
  echo "aspect-integration-provenance: skipped ($revision is not on the aspect integration line)"
  exit 0
fi

git -C "$root" cat-file -e "$upstream_base_commit^{commit}" 2>/dev/null ||
  fail "historical upstream base is absent from this checkout"
git -C "$root" cat-file -e "$verified_ancestor^{commit}" 2>/dev/null ||
  fail "verified ancestor is absent from this checkout"

base_tree="$(git -C "$root" rev-parse --verify "$upstream_base_commit^{tree}")"
[ "$base_tree" = "$upstream_tree" ] ||
  fail "historical base tree $base_tree does not match lock $upstream_tree"

root_parent="$(git -C "$root" rev-parse --verify "$aspect_root_commit^1")"
[ "$root_parent" = "$upstream_base_commit" ] ||
  fail "aspect root parent $root_parent does not match historical base $upstream_base_commit"

git -C "$root" merge-base --is-ancestor "$aspect_root_commit" "$verified_ancestor" ||
  fail "verified canonical anchor does not descend from the aspect root"
git -C "$root" merge-base --is-ancestor "$verified_ancestor" "$revision" ||
  fail "$revision does not descend from the verified canonical anchor"

if [ "${1:-}" = --check-upstream ]; then
  [ "$#" -eq 1 ] || fail "usage: $0 [--check-upstream]"
  remote_refs="$(git ls-remote --tags "$upstream_repository" \
    "refs/tags/$upstream_release" "refs/tags/$upstream_release^{}")"
  live_commit="$(printf '%s\n' "$remote_refs" |
    awk -v tag="refs/tags/$upstream_release" \
      '$2 == tag "^{}" {peeled=$1} $2 == tag {direct=$1} END {print peeled ? peeled : direct}')"
  [ -n "$live_commit" ] || fail "upstream release $upstream_release is missing"
  [ "$live_commit" = "$upstream_release_commit" ] ||
    fail "upstream release moved: lock=$upstream_release_commit live=$live_commit"

  live_repo="$(mktemp -d)"
  trap 'rm -rf "$live_repo"' EXIT
  git init --quiet --bare "$live_repo"
  git -C "$live_repo" fetch --quiet --no-tags "$upstream_repository" \
    "refs/tags/$upstream_release:refs/tags/$upstream_release"
  fetched_commit="$(git -C "$live_repo" rev-parse --verify "refs/tags/$upstream_release^{}")"
  [ "$fetched_commit" = "$live_commit" ] ||
    fail "fetched release differs from advertised release: advertised=$live_commit fetched=$fetched_commit"
  live_tree="$(git -C "$live_repo" rev-parse --verify "$live_commit^{tree}")"
  [ "$live_tree" = "$upstream_tree" ] ||
    fail "upstream release tree moved: lock=$upstream_tree live=$live_tree"
elif [ "$#" -ne 0 ]; then
  fail "usage: $0 [--check-upstream]"
fi

echo "aspect-integration-provenance: ok ($canonical_branch; $upstream_release; $upstream_tree)"
