#!/bin/sh
# Process-isolated gate for the v0.5.17 string/symbol hasheq-cache race.
#
# String and symbol modes run in separate child processes for attribution. A
# portable watchdog bounds each child. A failing run preserves every attempt,
# including earlier successful controls; KEEP=1 preserves an all-green run.
#
# Knobs:
#   JOLT_HASHEQ_CONCURRENCY_ATTEMPTS  attempts per mode (default 1)
#   JOLT_HASHEQ_CONCURRENCY_TIMEOUT   seconds per attempt (default 15)
#   JOLT_HASHEQ_CONCURRENCY_ITERS     iterations per worker (default 8000)
#   JOLT_HASHEQ_CONCURRENCY_KEEP      1 keeps an all-green run
#   JOLT_HASHEQ_CONCURRENCY_ROOT      artifact root

CHEZ="$1"
[ -n "$CHEZ" ] || { echo "usage: $0 <chez>" >&2; exit 2; }

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
test_ss="test/chez/hasheq-concurrency-test.ss"
[ -f "$test_ss" ] || { echo "missing $test_ss" >&2; exit 2; }

attempts="${JOLT_HASHEQ_CONCURRENCY_ATTEMPTS:-1}"
tsecs="${JOLT_HASHEQ_CONCURRENCY_TIMEOUT:-15}"
iters="${JOLT_HASHEQ_CONCURRENCY_ITERS:-8000}"
keep="${JOLT_HASHEQ_CONCURRENCY_KEEP:-0}"
runroot="${JOLT_HASHEQ_CONCURRENCY_ROOT:-target/test-artifacts/hasheq-concurrency}"

case "$attempts" in ''|*[!0-9]*|0) echo "attempts must be a positive integer" >&2; exit 2;; esac
case "$tsecs" in ''|*[!0-9]*|0) echo "timeout must be a positive integer" >&2; exit 2;; esac
case "$iters" in ''|*[!0-9]*|0) echo "iterations must be a positive integer" >&2; exit 2;; esac

runid="$(date +%Y%m%d-%H%M%S)-$$"
rundir="$runroot/$runid"
mkdir -p "$rundir"

pass=0
timedout=0
crashed=0
failed=0
total=0

for mode in string symbol; do
  n=1
  while [ "$n" -le "$attempts" ]; do
    total=$((total + 1))
    adir="$rundir/$mode-attempt-$n"
    mkdir -p "$adir"
    cat >"$adir/command.txt" <<EOF
chez: $CHEZ
script: $test_ss
mode: $mode
attempt: $n of $attempts
workers: 4
iterations per worker: $iters
timeout: ${tsecs}s
started: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

    (
      ulimit -c unlimited 2>/dev/null || :
      export JOLT_HASHEQ_CONCURRENCY_DIR="$adir"
      export JOLT_HASHEQ_CONCURRENCY_MODE="$mode"
      export JOLT_HASHEQ_CONCURRENCY_ITERS="$iters"
      exec "$CHEZ" --script "$test_ss"
    ) >"$adir/stdout.log" 2>"$adir/stderr.log" &
    cpid=$!
    marker="$adir/TIMED-OUT"
    (
      sleep "$tsecs"
      if kill -0 "$cpid" 2>/dev/null; then
        : >"$marker"
        kill -KILL "$cpid" 2>/dev/null || :
      fi
    ) &
    wpid=$!

    wait "$cpid" 2>/dev/null
    rc=$?
    kill "$wpid" 2>/dev/null || :
    wait "$wpid" 2>/dev/null || :
    echo "$rc" >"$adir/exit-code.txt"

    if [ -f "$marker" ]; then
      verdict="TIMEOUT (>${tsecs}s, killed)"
      timedout=$((timedout + 1))
    elif [ "$rc" -eq 0 ]; then
      verdict="PASS"
      pass=$((pass + 1))
    elif [ "$rc" -ge 129 ] && [ "$rc" -le 192 ]; then
      verdict="CRASH (signal $((rc - 128)), exit $rc)"
      crashed=$((crashed + 1))
    else
      verdict="FAIL (exit $rc)"
      failed=$((failed + 1))
    fi
    echo "$verdict" >"$adir/verdict.txt"
    echo "hasheq-concurrency: $mode attempt $n/$attempts: $verdict"
    n=$((n + 1))
  done
done

summary="hasheq-concurrency: $pass/$total passed, $timedout timeout(s), $crashed crash(es), $failed failure(s)"
echo "$summary"
echo "$summary" >"$rundir/summary.txt"

if [ "$pass" -eq "$total" ]; then
  if [ "$keep" != "1" ]; then
    rm -rf "$rundir"
  fi
  exit 0
fi

echo "hasheq-concurrency: FAILED; all attempt artifacts preserved under $rundir" >&2
exit 1
