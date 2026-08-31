#!/bin/sh
set -eu

if ! command -v z3 >/dev/null 2>&1; then
  echo "checkpoint action formal gate requires z3" >&2
  exit 2
fi

spec=test/formal/checkpoint-action-semantics.smt2
expected="unsat sat sat sat sat sat sat sat sat sat sat sat sat sat sat"
actual=$(z3 "$spec" | tr '\n' ' ' | sed 's/ $//')

if [ "$actual" != "$expected" ]; then
  echo "FAIL checkpoint action semantics ($spec): expected '$expected', got '$actual'" >&2
  exit 1
fi

for name in \
  eight-implementation-domain \
  eight-scenario-bound \
  bounded-plan-key-domain \
  four-action-domain \
  exact-actor-site-hit-selection \
  selection-by-exact-plan-key \
  selected-action-capability \
  capability-and-generation-admission \
  commit-event-dispatch-cardinality \
  event-before-terminal-dispatch \
  sticky-cancel-no-later-publication \
  sticky-cancel-actor-scope \
  reset-publishes-fresh-generation \
  reset-clears-sticky-cancel \
  shared-checkpoint-action-violation \
  reference-action-counterexample-query \
  global-cancel-mutant-query \
  ignore-hit-selector-mutant-query \
  capability-bypass-mutant-query \
  dispatch-before-event-mutant-query \
  nonsticky-cancel-mutant-query \
  reset-retains-cancel-mutant-query \
  stale-generation-mutation-mutant-query \
  continue-action-nonvacuity-query \
  yield-action-nonvacuity-query \
  fault-action-nonvacuity-query \
  cancel-action-nonvacuity-query \
  reset-clear-nonvacuity-query \
  capability-rejection-nonvacuity-query \
  stale-generation-rejection-nonvacuity-query
do
  if ! grep -q ":named $name" "$spec"; then
    echo "FAIL checkpoint action semantics gate: missing named assertion $name" >&2
    exit 1
  fi
done

echo "PASS checkpoint action semantics: $actual"
