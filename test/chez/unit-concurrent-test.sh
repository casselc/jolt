#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
chez=${JOLT_CHEZ:?JOLT_CHEZ must name the selected Chez executable}
work=$(mktemp -d "${TMPDIR:-/tmp}/jolt-unit-concurrent.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

run_dynamic () {
  out=$1
  shift
  home="$out.home"
  mkdir "$home"
  env HOME="$home" JOLT_UNIT_DYNAMIC_DEPS_ONLY=1 JOLT_UNIT_REPORT_TEMP_ROOT=1 "$@" \
    "$chez" --script host/chez/run-unit.ss >"$out" 2>&1
}

roots_are_distinct () {
  [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ]
}

cd "$root"

# Regression property: two real dynamic-dependency unit subsets overlap.  Both
# must finish and the same distinct-root oracle must show that they own different
# atomically-created roots, even though they share the system temp directory and
# execute the same fixture setup.
run_dynamic "$work/green-1.out" & p1=$!
run_dynamic "$work/green-2.out" & p2=$!
s1=0; wait "$p1" || s1=$?
s2=0; wait "$p2" || s2=$?
if [ "$s1" -ne 0 ] || [ "$s2" -ne 0 ]; then
  echo "unit concurrent: a private-root run failed ($s1, $s2)" >&2
  sed -n '1,160p' "$work/green-1.out" >&2
  sed -n '1,160p' "$work/green-2.out" >&2
  exit 1
fi
grep -q 'unit gate: 4/4 passed' "$work/green-1.out"
grep -q 'unit gate: 4/4 passed' "$work/green-2.out"
r1=$(sed -n 's/^unit temp root: //p' "$work/green-1.out")
r2=$(sed -n 's/^unit temp root: //p' "$work/green-2.out")
if ! roots_are_distinct "$r1" "$r2"; then
  echo "unit concurrent: roots are not private: '$r1' '$r2'" >&2
  exit 1
fi

# The failure reporter must retain the Jolt throwable's class and message.  The
# probe is deliberately failing; an exit zero or the old bare "raised" output is
# a test failure.
diag_status=0
mkdir "$work/diagnostic-home"
env HOME="$work/diagnostic-home" JOLT_UNIT_DIAGNOSTIC_PROBE=1 "$chez" --script host/chez/run-unit.ss \
  >"$work/diagnostic.out" 2>&1 || diag_status=$?
if [ "$diag_status" -eq 0 ]; then
  echo "unit concurrent: diagnostic failure probe unexpectedly passed" >&2
  exit 1
fi
grep -q 'raised clojure.lang.ExceptionInfo: unit diagnostic probe' "$work/diagnostic.out"

echo "UNIT-CONCURRENT-TEST OK"
