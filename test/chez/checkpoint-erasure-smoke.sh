#!/bin/sh
# Optimized whole-program differential proof for production checkpoint erasure.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fixture="$repo/test/chez/checkpoint-erasure-app"
jolt="$repo/bin/jolt"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

project="$tmp/project"
mkdir -p "$project/src/app" "$tmp/snapshots"
cp "$fixture/deps.edn" "$project/deps.edn"

# Self-contained builds embed the compiler, so generic schema/backend strings
# such as "checkpoint-decl" and "jolt-checkpoint!" are expected compiler data.
# Application residue is identified by its stable site ID or positive report
# evidence; both are impossible in a correctly erased plain application.
checkpoint_pattern='test\.erasure/site|:jolt\.effect/checkpoint|:checkpoint-sites \[\{'

# Fixture teeth: an accidental edit must not turn the differential into two
# checkpoint-free sources before the compiler is even exercised.
with_sites=$(grep -c ':test.erasure/site' "$fixture/with-checkpoint.clj" || true)
without_sites=$(grep -c ':test.erasure/site' "$fixture/without-checkpoint.clj" || true)
if [ "$with_sites" -ne 1 ] || [ "$without_sites" -ne 0 ]; then
  echo "FAIL: checkpoint erasure fixture must contain exactly one/zero sites" >&2
  exit 1
fi

contains_checkpoint_evidence() {
  grep -a -E -R -q "$checkpoint_pattern" "$1"
}

run_variant() {
  source_file=$1
  label=$2
  cp "$source_file" "$project/src/app/core.clj"
  (cd "$project" && env JOLT_PWD="$project" JOLT_CACHE_DIR="$tmp/cache-$label" \
    "$jolt" build -m app.core -o target/optimized/app --opt)

  output=$($project/target/optimized/app)
  if [ "$output" != "ok" ]; then
    echo "FAIL: optimized checkpoint erasure $label behavior: $output" >&2
    exit 1
  fi

  build_dir="$project/target/optimized/app.build"
  test -s "$build_dir/flat.ss"
  test -s "$build_dir/effects.edn"
  test -s "$build_dir/regions.edn"
  if contains_checkpoint_evidence "$project/target/optimized"; then
    echo "FAIL: optimized $label artifact retained checkpoint evidence" >&2
    grep -a -E -R -n "$checkpoint_pattern" "$project/target/optimized" >&2 || true
    exit 1
  fi

  cp "$build_dir/flat.ss" "$tmp/snapshots/$label-flat.ss"
  cp "$build_dir/effects.edn" "$tmp/snapshots/$label-effects.edn"
  cp "$build_dir/regions.edn" "$tmp/snapshots/$label-regions.edn"
}

run_variant "$fixture/with-checkpoint.clj" with
run_variant "$fixture/without-checkpoint.clj" without

# Same namespace, source path, output path, mode, and line layout: checkpoint
# erasure must leave canonical emitted application/evidence artifacts identical.
cmp "$tmp/snapshots/with-flat.ss" "$tmp/snapshots/without-flat.ss"
cmp "$tmp/snapshots/with-effects.edn" "$tmp/snapshots/without-effects.edn"
cmp "$tmp/snapshots/with-regions.edn" "$tmp/snapshots/without-regions.edn"

# Mutation teeth: prove both executable-artifact and report scanners reject the
# precise residues this gate exists to catch.
mkdir -p "$tmp/mutant-artifact" "$tmp/mutant-report"
cp "$tmp/snapshots/with-flat.ss" "$tmp/mutant-artifact/flat.ss"
printf '\n(jolt-checkpoint! "test.erasure/site" (quote (continue)))\n' \
  >> "$tmp/mutant-artifact/flat.ss"
if ! contains_checkpoint_evidence "$tmp/mutant-artifact"; then
  echo "FAIL: artifact mutation did not trip checkpoint erasure scanner" >&2
  exit 1
fi

cp "$tmp/snapshots/with-effects.edn" "$tmp/mutant-report/effects.edn"
printf '\n{:checkpoint-sites [{:id :test.erasure/site}]}\n' \
  >> "$tmp/mutant-report/effects.edn"
if ! contains_checkpoint_evidence "$tmp/mutant-report"; then
  echo "FAIL: report mutation did not trip checkpoint erasure scanner" >&2
  exit 1
fi

echo "checkpoint optimized erasure: artifacts identical, scans clean, mutations caught"
