#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
sim="${JOLT_SIM:-target/sim/jolt}"
case "$sim" in /*) ;; *) sim="$root/$sim" ;; esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
retained="$work/retained"
dropped="$work/dropped"

JOLT_PWD="$root/test/chez/sim-runtime-eval-app" \
  "$sim" build -m runtime-eval.core -o "$retained" >"$work/retained.log" 2>&1
[ "$("$retained")" = "sim runtime eval: modeled missing symbol" ]

# Exactly one emitted call arms the retained compiler before app forms. The
# overlay's `(define (jolt-sim-arm-compiler!) ...)` is intentionally distinct.
[ "$(grep -c '^[(]jolt-sim-arm-compiler![)]$' "$retained.build/flat.ss")" -eq 1 ]

# A no-eval tree-shaken app drops the compiler and must neither reference nor
# execute the arm operation. It still carries the sim runtime overlay itself.
JOLT_PWD="$root/test/chez/sim-image-app" \
  "$sim" build -m app.core -o "$dropped" --tree-shake >"$work/dropped.log" 2>&1
[ "$("$dropped")" = "[42 42 true]" ]
if grep -q '^[(]jolt-sim-arm-compiler![)]$' "$dropped.build/flat.ss"; then
  echo "sim runtime eval: compiler-dropped app contains arm call" >&2
  exit 1
fi
grep -q 'dropping compiler image' "$work/dropped.log"

echo "sim runtime eval: retained compiler armed; compiler-dropped app clean"
