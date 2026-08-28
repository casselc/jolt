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
advice-args ["ok"]
operation ok-woven
advice-after ok-woven!
entry-before :test/callback-entry
entry-args ["ok-woven!"]
callback ok-woven!
entry-after ok-woven!?
result ok-woven!?'
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

entry_recur_output=$("$tmp/target/release/app" entry-recur)
expected_entry_recur='argument
advice-before :test/target-call
advice-args ["entry-recur"]
operation entry-recur
advice-after entry-recur!
entry-before :test/callback-entry
entry-args ["recur"]
callback recur
callback done
entry-after done?
result done?'
test "$entry_recur_output" = "$expected_entry_recur"
test "$(printf '%s\n' "$entry_recur_output" | grep -c '^entry-before ')" -eq 1

entry_number_output=$("$tmp/target/release/app" entry-number)
expected_entry_number='numeric-entry-before :test/numeric-callback-entry
numeric-entry-args [40]
numeric-callback 41
numeric-entry-after 42
result 42'
test "$entry_number_output" = "$expected_entry_number"

entry_throw_output=$("$tmp/target/release/app" entry-throw)
printf '%s\n' "$entry_throw_output" | grep -q '^entry-before :test/callback-entry$'
printf '%s\n' "$entry_throw_output" | grep -q '^callback throw$'
printf '%s\n' "$entry_throw_output" | grep -q '^caught callback failure :callback$'
if printf '%s\n' "$entry_throw_output" | grep -q '^entry-after '; then
  echo "FAIL: entry advice observed a return after an application exception" >&2
  exit 1
fi

throw_output=$("$tmp/target/release/app" throw)
printf '%s\n' "$throw_output" | grep -q '^caught application failure :application$'

test -s "$tmp/target/aspects.edn"
grep -q ':identity "v1-' "$tmp/target/aspects.edn"
grep -q ':contract :replace-args-v1' "$tmp/target/aspects.edn"
grep -q ':entry app.target/callback' "$tmp/target/aspects.edn"
grep -q ':entry app.target/numeric-callback' "$tmp/target/aspects.edn"
grep -q ':contract :args-v1' "$tmp/target/aspects.edn"
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
callback ok!
result ok!?'
test "$plain_output" = "$expected_plain"
plain_recur_output=$("$tmp/target/plain/app" entry-recur)
expected_plain_recur='argument
operation entry-recur
callback recur
callback done
result done?'
test "$plain_recur_output" = "$expected_plain_recur"
plain_throw_output=$("$tmp/target/plain/app" entry-throw)
printf '%s\n' "$plain_throw_output" | grep -q '^caught callback failure :callback$'
plain_number_output=$("$tmp/target/plain/app" entry-number)
expected_plain_number='numeric-callback 40
result 41'
test "$plain_number_output" = "$expected_plain_number"

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
