#!/bin/sh
set -eu

if ! command -v z3 >/dev/null 2>&1; then
  echo "lazy once-realization formal gate requires z3" >&2
  exit 2
fi

spec=test/formal/lazy-once-realization.smt2
expected="unsat sat sat sat sat sat sat sat sat sat"
actual=$(z3 "$spec" | tr '\n' ' ' | sed 's/ $//')

if [ "$actual" != "$expected" ]; then
  echo "FAIL lazy/tail once-realization ($spec): expected '$expected', got '$actual'" >&2
  exit 1
fi

echo "PASS lazy/tail gate ownership plus record outcome policies, mutants, and boundaries: $actual"
