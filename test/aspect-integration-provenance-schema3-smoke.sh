#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$root/test/aspect-integration-provenance-smoke.sh"
source_lock="$root/config/aspect-integration.lock"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

expect_fail() {
  local name="$1" pattern="$2" lock="$3" output
  if output="$(ASPECT_INTEGRATION_LOCK="$lock" bash "$verifier" 2>&1)"; then
    echo "aspect-integration-schema3: $name unexpectedly passed" >&2
    exit 1
  fi
  case "$output" in
    *"$pattern"*) ;;
    *)
      echo "aspect-integration-schema3: $name failed for the wrong reason: $output" >&2
      exit 1
      ;;
  esac
}

# The checked-in schema 3 lock is the positive control.
ASPECT_INTEGRATION_LOCK="$source_lock" bash "$verifier" >/dev/null

# Schema 2 remains valid for an unrevised release lineage.
sed \
  -e 's/^schema=3$/schema=2/' \
  -e '/^upstream_release_base_commit=/d' \
  -e 's/^upstream_release_commit=.*/upstream_release_commit=f3041a0e32ba0db1b92bd69b8ecb7b40f8b2e115/' \
  "$source_lock" > "$tmp/schema2.lock"
ASPECT_INTEGRATION_LOCK="$tmp/schema2.lock" bash "$verifier" >/dev/null

# Equal content alone is insufficient: the tree-equivalent historical base is
# not an ancestor of the rewritten live release lineage.
sed \
  's/^upstream_release_base_commit=.*/upstream_release_base_commit=343f730922cf16fafe673b466cedcdcfe0596854/' \
  "$source_lock" > "$tmp/wrong-lineage.lock"
expect_fail wrong-lineage 'recorded release does not descend from its tree-equivalent base' \
  "$tmp/wrong-lineage.lock"

# An ancestor on the live lineage is insufficient if its content is not the
# recorded aspect-root base content.
sed \
  's/^upstream_release_base_commit=.*/upstream_release_base_commit=823ce3abe50797225107899bcaf5752a259e2cd1/' \
  "$source_lock" > "$tmp/wrong-tree.lock"
expect_fail wrong-tree 'does not match historical base tree' "$tmp/wrong-tree.lock"

sed '/^upstream_release_base_commit=/d' "$source_lock" > "$tmp/missing-key.lock"
expect_fail missing-key 'lock keys are missing, duplicated, or unknown' "$tmp/missing-key.lock"

echo "aspect-integration-schema3: positive and negative controls passed"
