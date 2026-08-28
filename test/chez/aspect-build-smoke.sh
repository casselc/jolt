#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
case ${JOLT_BIN:-} in
  /*) jolt=$JOLT_BIN ;;
  "") jolt=$repo/target/release/jolt ;;
  *) jolt=$repo/$JOLT_BIN ;;
esac
fixture=$repo/test/chez/aspect-build-app
tmp=${TMPDIR:-/tmp}/jolt-aspect-build-$$
trap 'rm -rf "$tmp"' EXIT INT TERM
cp -R "$fixture" "$tmp"
cp "$tmp/deps.edn" "$tmp/deps.instrumented.edn"

run_build() {
  mode=$1
  shift
  extra_env=
  if [ "$mode" = release-nowp ]; then
    extra_env=JOLT_NO_WP_INFER=1
  fi
  (cd "$tmp" && env JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" $extra_env \
    "$jolt" build -m app.core -o "target/$mode/app" "$@")
  output=$("$tmp/target/$mode/app" ok)
  expected='argument
advice-before :test/target-call
operation ok
advice-after ok!
result ok!'
  if [ "$output" != "$expected" ]; then
    echo "FAIL: $mode output" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

"$jolt" "$repo/test/chez/aspect-ir-test.clj"
run_build release
cp "$tmp/target/aspects.edn" "$tmp/target/release-aspects.edn"
run_build dev --dev
cmp "$tmp/target/release-aspects.edn" "$tmp/target/aspects.edn"
run_build release-open --no-direct-link
cmp "$tmp/target/release-aspects.edn" "$tmp/target/aspects.edn"
run_build release-nowp
cmp "$tmp/target/release-aspects.edn" "$tmp/target/aspects.edn"
run_build optimized --opt --tree-shake
cmp "$tmp/target/release-aspects.edn" "$tmp/target/aspects.edn"

throw_output=$("$tmp/target/release/app" throw)
printf '%s\n' "$throw_output" | grep -q '^caught application failure :application$'

test -s "$tmp/target/aspects.edn"
grep -q ':identity "v1-' "$tmp/target/aspects.edn"
grep -q ':ordinal 1' "$tmp/target/aspects.edn"
if grep -q "$tmp" "$tmp/target/aspects.edn"; then
  echo "FAIL: aspect report contains the checkout path" >&2
  exit 1
fi

cp "$tmp/deps.plain.edn" "$tmp/deps.edn"
(cd "$tmp" && JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
  "$jolt" build -m app.core -o target/plain/app)
plain_output=$("$tmp/target/plain/app" ok)
expected_plain='argument
operation ok
result ok!'
test "$plain_output" = "$expected_plain"

# A stale exact selector fails before replacing an existing artifact.
cp "$tmp/deps.instrumented.edn" "$tmp/deps.edn"
cp "$tmp/target/aspects.edn" "$tmp/target/aspects-before-failure.edn"
sed -i 's#app.target/operation#app.target/missing#' \
  "$tmp/resources/META-INF/jolt/aspects/probe.edn"
if (cd "$tmp" && env JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
    "$jolt" build -m app.core -o target/release/app); then
  echo "FAIL: stale aspect selector unexpectedly built" >&2
  exit 1
fi
test "$("$tmp/target/release/app" ok)" = "$expected"
cmp "$tmp/target/aspects-before-failure.edn" "$tmp/target/aspects.edn"

echo "PASS: compiler-supported aspect build"
