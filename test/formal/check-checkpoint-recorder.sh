#!/bin/sh
set -eu

if ! command -v z3 >/dev/null 2>&1; then
  echo "checkpoint recorder formal gate requires z3" >&2
  exit 2
fi

control_spec=test/formal/checkpoint-controller-control-plane.smt2
control_expected="unsat sat sat sat sat sat"
control_actual=$(z3 "$control_spec" | tr '\n' ' ' | sed 's/ $//')

if [ "$control_actual" != "$control_expected" ]; then
  echo "FAIL checkpoint controller control-plane ($control_spec): expected '$control_expected', got '$control_actual'" >&2
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
  if ! grep -q ":named $name" "$control_spec"; then
    echo "FAIL checkpoint controller control-plane gate: missing named assertion $name" >&2
    exit 1
  fi
done

machine_spec=test/formal/checkpoint-recorder-reservation-publication.smt2
machine_expected="unsat sat sat sat sat sat sat sat"
machine_actual=$(z3 "$machine_spec" | tr '\n' ' ' | sed 's/ $//')

if [ "$machine_actual" != "$machine_expected" ]; then
  echo "FAIL checkpoint recorder reservation/publication ($machine_spec): expected '$machine_expected', got '$machine_actual'" >&2
  exit 1
fi

for name in \
  exact-binding-instance-and-epoch \
  six-step-machine-bound \
  two-context-domain \
  two-actor-domain \
  reserve-token-phase \
  designated-driver \
  reset-generation-and-recorder \
  allocation-cas-observes-open-generation \
  reset-closes-old-generation-before-publish \
  generation-clock-cas-ordering \
  cas-allocation-pair \
  commit-time-hit-action-and-append \
  append-publication-under-recorder-ownership \
  snapshot-current-open-generation-cas \
  snapshot-cut-cas-return-and-advance \
  snapshot-recorder-capture-lock \
  snapshot-cut-and-per-recorder-capture \
  shared-recorder-machine-violation \
  reference-machine-counterexample-query \
  missing-binding-instance-mutant-query \
  double-commit-mutant-query \
  split-allocate-append-snapshot-mutant-query \
  caller-only-reset-mutant-query \
  reference-commit-nonvacuity-query \
  reference-reset-nonvacuity-query \
  reference-winner-before-reset-nonvacuity-query
do
  if ! grep -q ":named $name" "$machine_spec"; then
    echo "FAIL checkpoint recorder machine gate: missing named assertion $name" >&2
    exit 1
  fi
done

echo "PASS checkpoint controller control-plane model: $control_actual"
echo "PASS checkpoint recorder reservation/publication machine: $machine_actual"
