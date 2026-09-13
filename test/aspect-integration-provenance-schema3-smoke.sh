#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$root/test/aspect-integration-provenance-smoke.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
git init -q -b main "$repo"
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }

printf 'historical base\n' > "$repo/f"
g add f
g commit -q -m historical-base
historical_base="$(g rev-parse HEAD)"
base_tree="$(g rev-parse HEAD^{tree})"
aspect_root="$(printf 'aspect root\n' | g commit-tree "$base_tree" -p "$historical_base")"
verified_ancestor="$(printf 'verified ancestor\n' |
  g commit-tree "$base_tree" -p "$aspect_root")"

# The live release line starts elsewhere, reaches content identical to the
# historical base, and then publishes the release. This is the rewritten
# ancestry that schema 2 cannot represent without abandoning the aspect root.
printf 'live foundation\n' > "$repo/f"
g add f
live_foundation_tree="$(g write-tree)"
live_foundation="$(printf 'live foundation\n' | g commit-tree "$live_foundation_tree")"
live_base="$(printf 'tree-equivalent live base\n' |
  g commit-tree "$base_tree" -p "$live_foundation")"
live_release="$(printf 'live release\n' | g commit-tree "$base_tree" -p "$live_base")"
schema3_join="$(printf 'schema 3 join\n' |
  g commit-tree "$base_tree" -p "$verified_ancestor" -p "$live_release")"

# A legacy release genuinely descends from the historical base. Its separate
# join proves schema 2 remains supported rather than passing accidentally on
# the rewritten line.
legacy_release="$(printf 'legacy release\n' |
  g commit-tree "$base_tree" -p "$historical_base")"
legacy_join="$(printf 'legacy join\n' |
  g commit-tree "$base_tree" -p "$verified_ancestor" -p "$legacy_release")"

g checkout -q -B main "$schema3_join"
mkdir -p "$repo/config"
lock="$repo/config/aspect-integration.lock"
cat > "$lock" <<EOF
schema=3
canonical_branch=integration/aspects
upstream_repository=https://github.com/example/jolt.git
upstream_base_commit=$historical_base
upstream_base_tree=$base_tree
upstream_release=v0.8.6
upstream_release_base_commit=$live_base
upstream_release_commit=$live_release
upstream_tree=$base_tree
aspect_root_commit=$aspect_root
verified_ancestor=$verified_ancestor
EOF
g add config/aspect-integration.lock
g commit -q -m schema3-lock

run_verifier() {
  local candidate_lock="$1" revision="${2:-HEAD}"
  ASPECT_INTEGRATION_ROOT="$repo" \
    ASPECT_INTEGRATION_LOCK="$candidate_lock" \
    ASPECT_INTEGRATION_REVISION="$revision" \
    ASPECT_INTEGRATION_REQUIRE=1 \
    bash "$verifier"
}

expect_fail() {
  local name="$1" pattern="$2" candidate_lock="$3" revision="${4:-HEAD}" output
  if output="$(run_verifier "$candidate_lock" "$revision" 2>&1)"; then
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

# The synthetic schema 3 graph is the positive control.
run_verifier "$lock" >/dev/null

sed \
  -e 's/^schema=3$/schema=2/' \
  -e '/^upstream_release_base_commit=/d' \
  -e "s/^upstream_release_commit=.*/upstream_release_commit=$legacy_release/" \
  "$lock" > "$tmp/schema2.lock"
run_verifier "$tmp/schema2.lock" "$legacy_join" >/dev/null

# Equal content alone is insufficient: the historical base is not an ancestor
# of the rewritten live release lineage.
sed \
  "s/^upstream_release_base_commit=.*/upstream_release_base_commit=$historical_base/" \
  "$lock" > "$tmp/wrong-lineage.lock"
expect_fail wrong-lineage \
  'recorded release does not descend from its tree-equivalent base' \
  "$tmp/wrong-lineage.lock"

# Live ancestry alone is insufficient if the selected base has different
# content from the recorded historical aspect-root base.
sed \
  "s/^upstream_release_base_commit=.*/upstream_release_base_commit=$live_foundation/" \
  "$lock" > "$tmp/wrong-tree.lock"
expect_fail wrong-tree 'does not match historical base tree' "$tmp/wrong-tree.lock"

sed '/^upstream_release_base_commit=/d' "$lock" > "$tmp/missing-key.lock"
expect_fail missing-key 'lock keys are missing, duplicated, or unknown' \
  "$tmp/missing-key.lock"

# Causal shallow-checkout control: optional verification used to return success
# before reaching any mutated-lock assertion when the aspect history was
# unavailable. The negative corpus above instead runs against the complete
# synthetic graph with REQUIRE=1; the same flag makes the shallow case fail
# closed rather than claiming a checked lineage.
shallow="$tmp/shallow"
git clone -q --depth 1 "file://$repo" "$shallow"
shallow_output="$(ASPECT_INTEGRATION_ROOT="$shallow" bash "$verifier")"
case "$shallow_output" in
  *'skipped (HEAD is not on the aspect integration line)'*) ;;
  *)
    echo "aspect-integration-schema3: shallow control did not expose optional skip: $shallow_output" >&2
    exit 1
    ;;
esac
if shallow_output="$(ASPECT_INTEGRATION_ROOT="$shallow" \
  ASPECT_INTEGRATION_REQUIRE=1 bash "$verifier" 2>&1)"; then
  echo "aspect-integration-schema3: shallow required control unexpectedly passed" >&2
  exit 1
fi
case "$shallow_output" in
  *'does not descend from the recorded aspect root'*) ;;
  *)
    echo "aspect-integration-schema3: shallow required control failed for the wrong reason: $shallow_output" >&2
    exit 1
    ;;
esac

echo "aspect-integration-schema3: synthetic positive, negative, and shallow controls passed"
