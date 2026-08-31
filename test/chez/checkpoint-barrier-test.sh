#!/bin/sh
# Run every barrier history in a separate deadline-bounded process.
set -u

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
chez=${CHEZ:?CHEZ must name the pinned Chez 10.4.1 executable}
status=0
timeout_cmd=

if command -v timeout >/dev/null 2>&1; then
  timeout_cmd=$(command -v timeout)
elif command -v gtimeout >/dev/null 2>&1; then
  # Homebrew coreutils installs GNU timeout under this non-conflicting name.
  timeout_cmd=$(command -v gtimeout)
else
  echo "checkpoint barrier gate requires GNU timeout (timeout or gtimeout)" >&2
  exit 2
fi

for history in fiber threads membership unique-actor rounds controller-held fault reset reset-delayed-arrival reset-snapshot reset-overlap cancel-break; do
  echo "== checkpoint barrier history: $history =="
  if "$timeout_cmd" 10s "$chez" --script "$repo/test/chez/checkpoint-barrier-test.ss" "$history"; then
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
