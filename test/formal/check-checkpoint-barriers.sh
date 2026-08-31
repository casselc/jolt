#!/bin/sh
set -eu

if ! command -v z3 >/dev/null 2>&1; then
  echo "checkpoint barrier formal gate requires z3" >&2
  exit 2
fi

spec=test/formal/checkpoint-barrier-semantics.smt2
expected="unsat sat sat sat sat sat sat sat sat sat sat sat sat sat sat sat sat sat sat sat"
actual=$(z3 "$spec" | tr '\n' ' ' | sed 's/ $//')

if [ "$actual" != "$expected" ]; then
  echo "FAIL checkpoint barrier semantics ($spec): expected '$expected', got '$actual'" >&2
  exit 1
fi

for name in \
  twelve-implementation-domain \
  ten-scenario-bound \
  two-actor-arrival-mask-domain \
  two-preallocated-generation-owned-rounds \
  event-before-arrival \
  unique-actor-arrival-and-idempotent-retake \
  final-unique-arrival-releases-once \
  pending-only-terminal-transitions \
  release-and-break-mutually-exclusive \
  reset-breaks-every-pending-round-and-wakes \
  cancel-breaks-every-affected-pending-round-and-wakes \
  fault-has-no-barrier-effect \
  old-decision-retains-old-round-and-cannot-mutate-fresh-generation \
  closed-clock-arrival-breaks-before-release \
  shared-checkpoint-barrier-violation \
  reference-checkpoint-barrier-counterexample-query \
  generation-ownership-mutant-query \
  arrival-before-event-mutant-query \
  duplicate-arrival-mutant-query \
  multiple-release-mutant-query \
  terminal-rewrite-mutant-query \
  release-and-break-mutant-query \
  incomplete-reset-mutant-query \
  incomplete-cancel-mutant-query \
  fault-effects-mutant-query \
  stale-fresh-mutation-mutant-query \
  closed-clock-release-mutant-query \
  idempotent-retake-nonvacuity-query \
  round0-release-nonvacuity-query \
  round1-isolation-nonvacuity-query \
  reset-break-nonvacuity-query \
  cancel-break-nonvacuity-query \
  fault-no-effect-nonvacuity-query \
  stale-old-round-nonvacuity-query \
  closed-clock-arrival-nonvacuity-query
do
  if ! grep -q ":named $name" "$spec"; then
    echo "FAIL checkpoint barrier semantics gate: missing named assertion $name" >&2
    exit 1
  fi
done

echo "PASS checkpoint barrier semantics: $actual"
