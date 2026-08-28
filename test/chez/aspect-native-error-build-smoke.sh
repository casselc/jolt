#!/bin/sh
# Standalone composition gate for compiler aspects and atomic native-error FFI.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
case ${JOLT_BIN:-} in
  /*) jolt=$JOLT_BIN ;;
  "") jolt=$repo/target/release/jolt ;;
  *) jolt=$repo/$JOLT_BIN ;;
esac
fixture=$repo/test/chez/aspect-native-error-build-app
tmp=${TMPDIR:-/tmp}/jolt-aspect-native-error-build-$$
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/app/native"
cp -R "$fixture/." "$tmp/app"

cc_bin=${CC:-cc}
ar_bin=${AR:-ar}
"$cc_bin" -c "$repo/test/chez/ffi-native-error-test.c" \
  -o "$tmp/app/native/native-error-helper.o"
"$ar_bin" rcs "$tmp/app/native/libnative-error-helper.a" \
  "$tmp/app/native/native-error-helper.o"

expected_results='results [[-1 41] [-1 42] [-1 43]]'

(cd "$tmp/app" && env JOLT_PWD="$tmp/app" JOLT_CACHE_DIR="$tmp/app/cache" \
  "$jolt" build -m app.core -o target/instrumented/app)
instrumented_output=$("$tmp/app/target/instrumented/app")
test "$(printf '%s\n' "$instrumented_output" | tail -n 1)" = "$expected_results"

# The third call leaves exactly the newest four events. This simultaneously
# proves bounded observation and that advice saw each exact capture vector.
expected_final_journal='journal [[:enter :test/native-error-call [1 42]] [:return :test/native-error-call [-1 42]] [:enter :test/native-error-call [1 43]] [:return :test/native-error-call [-1 43]]]'
test "$(printf '%s\n' "$instrumented_output" | grep '^journal ' | tail -n 1)" = \
  "$expected_final_journal"
test "$(printf '%s\n' "$instrumented_output" | grep -c '^journal ')" -eq 3

test -s "$tmp/app/target/native-error-aspects.edn"
grep -q ':id :test/native-error-call' "$tmp/app/target/native-error-aspects.edn"
grep -q ':contract :args-v1' "$tmp/app/target/native-error-aspects.edn"
grep -q ':call app.native-error/block-fail' "$tmp/app/target/native-error-aspects.edn"
grep -q ':ordinal 1' "$tmp/app/target/native-error-aspects.edn"

cp "$tmp/app/deps.plain.edn" "$tmp/app/deps.edn"
(cd "$tmp/app" && env JOLT_PWD="$tmp/app" JOLT_CACHE_DIR="$tmp/app/cache" \
  "$jolt" build -m app.core -o target/plain/app)
plain_output=$("$tmp/app/target/plain/app")
test "$plain_output" = "$expected_results"
if printf '%s\n' "$plain_output" | grep -q '^journal '; then
  echo "FAIL: plain native-error build unexpectedly ran aspect advice" >&2
  exit 1
fi

echo "PASS: standalone aspect/native-error composition"
