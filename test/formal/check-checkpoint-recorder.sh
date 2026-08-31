#!/bin/sh
set -eu

if ! command -v z3 >/dev/null 2>&1; then
  echo "checkpoint recorder formal gate requires z3" >&2
  exit 2
fi

spec=test/formal/checkpoint-recorder-generation.smt2
expected="unsat sat sat sat sat sat"
actual=$(z3 "$spec" | tr '\n' ' ' | sed 's/ $//')

if [ "$actual" != "$expected" ]; then
  echo "FAIL checkpoint recorder generation/snapshot ($spec): expected '$expected', got '$actual'" >&2
  exit 1
fi

for name in \
  finite-operation-domain \
  six-operation-bound \
  generation-transition \
  binding0-transition \
  binding1-transition \
  snapshot-copy-transition \
  state-violation-definition \
  operation-violation-definition \
  recorder-violation-definition \
  reference-counterexample-query \
  caller-only-reset-mutant-query \
  split-snapshot-mutant-query
do
  if ! grep -q ":named $name" "$spec"; then
    echo "FAIL checkpoint recorder formal gate: missing named assertion $name" >&2
    exit 1
  fi
done

echo "PASS checkpoint recorder bounded generations, bindings, snapshots, mutants, and boundaries: $actual"
