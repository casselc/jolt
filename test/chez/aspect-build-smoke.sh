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
audit-before :test/target-call
audit-args ["ok-woven"]
operation ok-woven-inner
audit-after ok-woven-inner!
advice-after ok-woven-inner!
entry-before :test/callback-entry
entry-args ["ok-woven-inner!"]
entry-audit-before :test/callback-entry
entry-audit-args ["ok-woven-inner!"]
callback ok-woven-inner!
entry-audit-after ok-woven-inner!?
entry-after ok-woven-inner!?
result ok-woven-inner!?'
  if [ "$output" != "$expected" ]; then
    echo "FAIL: $mode output" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

"$jolt" "$repo/test/chez/aspect-ir-test.clj"
run_build release
cp "$tmp/target/aspects.edn" "$tmp/target/release-aspects.edn"

# The actual CLI, not merely the source-loaded unit namespace, must expose a
# deterministic source-free plan and accept only a report for this exact build.
(cd "$tmp" && env JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
  "$jolt" aspects plan) >"$tmp/target/aspects-plan.edn"
(cd "$tmp" && env JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
  "$jolt" aspects plan) >"$tmp/target/aspects-plan-again.edn"
cmp "$tmp/target/aspects-plan.edn" "$tmp/target/aspects-plan-again.edn"
grep -q ':status :instrumented' "$tmp/target/aspects-plan.edn"
grep -q ':identity "v1-' "$tmp/target/aspects-plan.edn"
if grep -q ':report\|target/aspects.edn\|'"$tmp" "$tmp/target/aspects-plan.edn"; then
  echo "FAIL: aspect plan contains a report or machine-specific path" >&2
  exit 1
fi

(cd "$tmp" && env JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
  "$jolt" aspects explain target/aspects.edn) >"$tmp/target/aspects-explain.txt"
grep -q '^observed report: target/aspects.edn$' "$tmp/target/aspects-explain.txt"
grep -q '^  observed sites: 1$' "$tmp/target/aspects-explain.txt"

cp "$tmp/target/aspects.edn" "$tmp/target/aspects-stale.edn"
sed -i 's/:identity "[^"]*"/:identity "stale"/' "$tmp/target/aspects-stale.edn"
if (cd "$tmp" && env JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
    "$jolt" aspects explain target/aspects-stale.edn) \
    >"$tmp/target/aspects-stale.log" 2>&1; then
  echo "FAIL: stale aspect report was presented as an observation" >&2
  exit 1
fi
grep -q 'build report does not match the selected build' \
  "$tmp/target/aspects-stale.log"

if (cd "$tmp" && env JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
    "$jolt" aspects explain target/does-not-exist.edn) \
    >"$tmp/target/aspects-missing.log" 2>&1; then
  echo "FAIL: explicit missing aspect report was silently ignored" >&2
  exit 1
fi
grep -q 'aspect report not found: target/does-not-exist.edn' \
  "$tmp/target/aspects-missing.log"

# Planning resolves provider source but must not load unrelated native objects.
cp "$tmp/deps.edn" "$tmp/deps.before-native-plan.edn"
sed -i '/ :jolt\/build/i\ :jolt/native [{:name "must-not-load"\
  :linux ["libjolt_aspects_introspection_missing.so"]\
  :darwin ["libjolt_aspects_introspection_missing.dylib"]\
  :windows ["jolt_aspects_introspection_missing.dll"]}]' "$tmp/deps.edn"
(cd "$tmp" && env JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
  "$jolt" aspects plan) >"$tmp/target/aspects-native-free-plan.edn"
cmp "$tmp/target/aspects-plan.edn" "$tmp/target/aspects-native-free-plan.edn"
cp "$tmp/deps.before-native-plan.edn" "$tmp/deps.edn"

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
audit-before :test/target-call
audit-args ["entry-recur"]
operation entry-recur
audit-after entry-recur!
advice-after entry-recur!
entry-before :test/callback-entry
entry-args ["recur"]
entry-audit-before :test/callback-entry
entry-audit-args ["recur"]
callback recur
callback done
entry-audit-after done?
entry-after done?
result done?'
test "$entry_recur_output" = "$expected_entry_recur"
test "$(printf '%s\n' "$entry_recur_output" | grep -c '^entry-before ')" -eq 1
test "$(printf '%s\n' "$entry_recur_output" | grep -c '^entry-audit-before ')" -eq 1

entry_number_output=$("$tmp/target/release/app" entry-number)
expected_entry_number='numeric-entry-before :test/numeric-callback-entry
numeric-entry-args [40]
numeric-audit-before :test/numeric-callback-entry
numeric-audit-args [41]
numeric-callback 42
numeric-audit-after 43
numeric-entry-after 43
result 43'
test "$entry_number_output" = "$expected_entry_number"

entry_throw_output=$("$tmp/target/release/app" entry-throw)
printf '%s\n' "$entry_throw_output" | grep -q '^entry-before :test/callback-entry$'
printf '%s\n' "$entry_throw_output" | grep -q '^callback throw$'
printf '%s\n' "$entry_throw_output" | grep -q '^caught callback failure :callback$'
if printf '%s\n' "$entry_throw_output" | grep -q '^entry-after '; then
  echo "FAIL: entry advice observed a return after an application exception" >&2
  exit 1
fi
if printf '%s\n' "$entry_throw_output" | grep -q '^entry-audit-after '; then
  echo "FAIL: inner entry advice observed a return after an application exception" >&2
  exit 1
fi

throw_output=$("$tmp/target/release/app" throw)
printf '%s\n' "$throw_output" | grep -q '^caught application failure :application$'

test -s "$tmp/target/aspects.edn"
grep -q ':identity "v1-' "$tmp/target/aspects.edn"
grep -q ':provider instrumentation.provider/aspect-provider' "$tmp/target/aspects.edn"
grep -q ':provider instrumentation.audit-provider/aspect-provider' "$tmp/target/aspects.edn"
grep -q ':contract :replace-args-v1' "$tmp/target/aspects.edn"
grep -q ':entry app.target/callback' "$tmp/target/aspects.edn"
grep -q ':entry app.target/numeric-callback' "$tmp/target/aspects.edn"
grep -q ':contract :args-v1' "$tmp/target/aspects.edn"
grep -q ':ordinal 1' "$tmp/target/aspects.edn"
grep -q ':ordinal 2' "$tmp/target/aspects.edn"
if grep -q "$tmp" "$tmp/target/aspects.edn"; then
  echo "FAIL: aspect report contains the checkout path" >&2
  exit 1
fi

# Provider order is observable advice order and therefore part of identity.
cp "$tmp/deps.edn" "$tmp/deps.ordered.edn"
ordered_identity=$(sed -n 's/.*:identity "\([^"]*\)".*/\1/p' "$tmp/target/aspects.edn")
sed -i 's/instrumentation.provider instrumentation.audit-provider/instrumentation.audit-provider instrumentation.provider/' \
  "$tmp/deps.edn"
(cd "$tmp" && JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
  "$jolt" build -m app.core -o target/reversed/app)
reversed_identity=$(sed -n 's/.*:identity "\([^"]*\)".*/\1/p' "$tmp/target/aspects.edn")
test -n "$ordered_identity"
test -n "$reversed_identity"
test "$ordered_identity" != "$reversed_identity"
grep -q ':consumers \[{:advice instrumentation.audit-provider/' "$tmp/target/aspects.edn"
cp "$tmp/deps.ordered.edn" "$tmp/deps.edn"
cp "$tmp/target/release-aspects.edn" "$tmp/target/aspects.edn"

# A package-owned preset expands to the same join-point/provider selection,
# remains visible in plan/explain output, and contributes provenance to the
# artifact identity without changing application behavior.
cp "$tmp/deps.preset.edn" "$tmp/deps.edn"
run_build preset
(cd "$tmp" && env JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
  "$jolt" aspects plan) >"$tmp/target/aspects-preset-plan.edn"
grep -q ':presets \[{:id :test/standard, :resource "META-INF/jolt/instrumentation/test/standard.edn"}\]' \
  "$tmp/target/aspects-preset-plan.edn"
preset_identity=$(sed -n 's/.*:identity "\([^"]*\)".*/\1/p' \
  "$tmp/target/aspects.edn")
test -n "$preset_identity"
test "$preset_identity" != "$ordered_identity"

cp "$tmp/deps.ordered.edn" "$tmp/deps.edn"
cp "$tmp/target/release-aspects.edn" "$tmp/target/aspects.edn"

# Test-only control advice is inert unless the application explicitly opts in.
cp "$tmp/deps.control.edn" "$tmp/deps.edn"
sed -i 's/:allow-control-aspects true/:allow-control-aspects false/' "$tmp/deps.edn"
mkdir -p "$tmp/target/control-disabled"
if (cd "$tmp" && JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
  "$jolt" build -m app.core -o target/control-disabled/app) \
  >"$tmp/target/control-disabled.log" 2>&1; then
  echo "FAIL: control advice built without explicit opt-in" >&2
  exit 1
fi
grep -q 'control advice requires :jolt/build :allow-control-aspects true' \
  "$tmp/target/control-disabled.log"

cp "$tmp/deps.control.edn" "$tmp/deps.edn"
(cd "$tmp" && JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
  "$jolt" build -m app.core -o target/control/app)
test "$("$tmp/target/control/app" control-return)" = 'argument
callback injected
result injected?'
test "$("$tmp/target/control/app" control-replace)" = 'argument
operation replaced
callback replaced!
result replaced!?'
test "$("$tmp/target/control/app" control-throw)" = 'argument
caught injected failure :injected'
grep -q ':control-enabled? true' "$tmp/target/aspects.edn"
grep -q ':contract :control-v1' "$tmp/target/aspects.edn"

cp "$tmp/deps.ordered.edn" "$tmp/deps.edn"
cp "$tmp/target/release-aspects.edn" "$tmp/target/aspects.edn"

# Every consumer must implement every role in the selected manifest. A valid
# first provider cannot mask an incomplete later provider.
sed -i 's/instrumentation.audit-provider/instrumentation.incomplete-provider/' \
  "$tmp/deps.edn"
if (cd "$tmp" && JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
  "$jolt" build -m app.core -o target/incomplete/app) \
  >"$tmp/target/incomplete.log" 2>&1; then
  echo "FAIL: incomplete second provider unexpectedly built" >&2
  exit 1
fi
grep -q 'provider does not implement selected advice role' \
  "$tmp/target/incomplete.log"
grep -q 'instrumentation.incomplete-provider/aspect-provider' \
  "$tmp/target/incomplete.log"
cp "$tmp/deps.ordered.edn" "$tmp/deps.edn"
cmp "$tmp/target/release-aspects.edn" "$tmp/target/aspects.edn"

# Explicit consumer filters let an independent consumer select only semantic
# roles it actually observes. The complete provider remains outermost at every
# site; the audit provider participates only in the call role.
cp "$tmp/deps.filtered.edn" "$tmp/deps.edn"
(cd "$tmp" && JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
  "$jolt" build -m app.core -o target/filtered/app)
filtered_output=$("$tmp/target/filtered/app" ok)
expected_filtered='argument
advice-before :test/target-call
advice-args ["ok"]
audit-before :test/target-call
audit-args ["ok-woven"]
operation ok-woven-inner
audit-after ok-woven-inner!
advice-after ok-woven-inner!
entry-before :test/callback-entry
entry-args ["ok-woven-inner!"]
callback ok-woven-inner!
entry-after ok-woven-inner!?
result ok-woven-inner!?'
test "$filtered_output" = "$expected_filtered"
filtered_identity=$(sed -n 's/.*:identity "\([^"]*\)".*/\1/p' "$tmp/target/aspects.edn")
test -n "$filtered_identity"
test "$(grep -o 'instrumentation.audit-provider/aspect-provider' \
  "$tmp/target/aspects.edn" | wc -l)" -eq 1
grep -q ':roles \[:test/around\]' "$tmp/target/aspects.edn"
grep -q ':selection-ordinal 2' "$tmp/target/aspects.edn"

# Expanding a filter changes the artifact identity and report even though the
# same provider source and order remain selected.
cp "$tmp/deps.filtered-more.edn" "$tmp/deps.edn"
(cd "$tmp" && JOLT_PWD="$tmp" JOLT_CACHE_DIR="$tmp/cache" \
  "$jolt" build -m app.core -o target/filtered-more/app)
filtered_more_identity=$(sed -n 's/.*:identity "\([^"]*\)".*/\1/p' "$tmp/target/aspects.edn")
test -n "$filtered_more_identity"
test "$filtered_identity" != "$filtered_more_identity"
test "$(grep -o 'instrumentation.audit-provider/aspect-provider' \
  "$tmp/target/aspects.edn" | wc -l)" -eq 2
grep -q ':roles \[:test/around :test/entry-around\]' "$tmp/target/aspects.edn"

cp "$tmp/deps.ordered.edn" "$tmp/deps.edn"
cp "$tmp/target/release-aspects.edn" "$tmp/target/aspects.edn"

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
