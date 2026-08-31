#!/bin/sh
# Run every barrier history in a separate deadline-bounded process.  This gate
# is expected RED until exact-actor barriers are implemented.
set -u

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
chez=${CHEZ:?CHEZ must name the pinned Chez 10.4.1 executable}
status=0

for history in fiber threads membership duplicate rounds reset cancel-break; do
  echo "== checkpoint barrier RED history: $history =="
  if timeout 10s "$chez" --script "$repo/test/chez/checkpoint-barrier-red-test.ss" "$history"; then
    :
  else
    code=$?
    if [ "$code" -eq 124 ]; then
      echo "FAIL: checkpoint barrier $history exceeded the 10s watchdog" >&2
    fi
    status=1
  fi
done

exit "$status"
