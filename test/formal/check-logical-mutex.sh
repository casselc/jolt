#!/bin/sh
set -eu

if ! command -v z3 >/dev/null 2>&1; then
  echo "logical mutex formal gate requires z3" >&2
  exit 2
fi

spec=test/formal/logical-mutex-ownership.smt2
expected="unsat sat sat sat sat sat sat sat sat sat sat"
actual=$(z3 "$spec" | tr '\n' ' ' | sed 's/ $//')

if [ "$actual" != "$expected" ]; then
  echo "FAIL logical mutex ownership/progress ($spec): expected '$expected', got '$actual'" >&2
  exit 1
fi

for name in \
  double-owner-violation-definition \
  non-owner-release-violation-definition \
  reentrancy-depth-violation-definition \
  counted-wait-violation-definition \
  waiter-progress-violation-definition \
  publication-violation-definition \
  reference-counterexample-query \
  lost-wake-mutant-query \
  release-before-registration-mutant-query
do
  if ! grep -q ":named $name" "$spec"; then
    echo "FAIL logical mutex formal gate: missing named assertion $name" >&2
    exit 1
  fi
done

echo "PASS logical mutex bounded ownership, guarded wait, progress, publication, mutants, and boundaries: $actual"
