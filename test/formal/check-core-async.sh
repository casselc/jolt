#!/bin/sh
set -eu

if ! command -v z3 >/dev/null 2>&1; then
  echo "core.async formal gate requires z3" >&2
  exit 2
fi

check_spec() {
  spec=$1
  expected=$2
  claim=$3
  actual=$(z3 "$spec" | tr '\n' ' ' | sed 's/ $//')
  if [ "$actual" != "$expected" ]; then
    echo "FAIL $claim ($spec): expected '$expected', got '$actual'" >&2
    exit 1
  fi
  echo "PASS $claim: $actual"
}

check_spec test/formal/core-async-pair-ownership.smt2 \
  "unsat sat sat" \
  "P1 atomic ownership / sequential-interleaving control / boundary"

check_spec test/formal/core-async-compatible-pair.smt2 \
  "unsat sat sat" \
  "P3 compatible scan / head-only control / boundary"

check_spec test/formal/core-async-close-drain.smt2 \
  "unsat sat sat sat" \
  "P2 close drain / drop control / duplicate-completion control / boundary"

check_spec test/formal/core-async-reducer-reservation.smt2 \
  "unsat sat sat sat sat sat sat sat sat sat sat sat sat sat sat sat" \
  "P4a fixed reducer reservation / close / completion histories and progress controls"

check_spec test/formal/core-async-reducer-publication.smt2 \
  "unsat sat sat sat sat sat sat sat sat sat sat sat sat sat sat sat" \
  "P4b batched publication / ex-handler / close-vs-EOF controls and boundaries"
