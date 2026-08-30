#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
chez=${JOLT_CHEZ:?JOLT_CHEZ must name the selected Chez executable}
work=$(mktemp -d "${TMPDIR:-/tmp}/jolt-spit-atomic.XXXXXX")
pids=""
cleanup () {
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

cd "$root"

"$chez" --script test/chez/spit-atomic-fault-test.ss "$work"

wait_file () {
  path=$1
  label=$2
  n=0
  while [ ! -f "$path" ]; do
    n=$((n + 1))
    if [ "$n" -ge 3000 ]; then
      echo "spit atomic: timed out waiting for $label" >&2
      exit 1
    fi
    sleep 0.01
  done
}

assert_uniform () {
  path=$1
  char=$2
  size=$(wc -c <"$path" | tr -d ' ')
  foreign=$(LC_ALL=C tr -d "$char" <"$path" | wc -c | tr -d ' ')
  [ "$size" -eq 1048576 ] && [ "$foreign" -eq 0 ] || {
    echo "spit atomic: $path is not a complete $char payload ($size bytes, $foreign foreign)" >&2
    exit 1
  }
}

run_pair () {
  scenario=$1
  pair="$work/$scenario"
  mkdir "$pair"

  "$chez" --script test/chez/spit-atomic-worker.ss A "$pair" "$scenario" \
    >"$pair/A.out" 2>&1 & a=$!; pids="$pids $a"
  wait_file "$pair/ready-A" "$scenario writer A"

  "$chez" --script test/chez/spit-atomic-worker.ss B "$pair" "$scenario" \
    >"$pair/B.out" 2>&1 & b=$!; pids="$pids $b"
  wait_file "$pair/ready-B" "$scenario writer B"

  temp_a=$(sed -n '1p' "$pair/ready-A")
  temp_b=$(sed -n '1p' "$pair/ready-B")
  [ "$temp_a" != "$temp_b" ] || {
    echo "spit atomic: writers share temporary path $temp_a" >&2
    exit 1
  }
  inode_a=$(ls -id "$temp_a" | awk '{print $1}')
  inode_b=$(ls -id "$temp_b" | awk '{print $1}')
  [ "$inode_a" != "$inode_b" ] || {
    echo "spit atomic: writers share inode $inode_a" >&2
    exit 1
  }
  grep -q 'spit-tmp-fixed-1 created' "$pair/attempts-A"
  grep -q 'spit-tmp-fixed-1 exists' "$pair/attempts-B"
  grep -q 'spit-tmp-fixed-2 created' "$pair/attempts-B"

  : >"$pair/allow-A"
  sa=0; wait "$a" || sa=$?
  pids=$(printf '%s\n' "$pids" | sed "s/ $a//")
  [ "$sa" -eq 0 ] || { cat "$pair/A.out" >&2; exit 1; }

  if [ "$scenario" = "publish-failure" ]; then
    rm -f "$temp_b"
  fi
  : >"$pair/allow-B"
  sb=0; wait "$b" || sb=$?
  pids=$(printf '%s\n' "$pids" | sed "s/ $b//")

  if [ "$scenario" = "both-success" ]; then
    [ "$sb" -eq 0 ] || { cat "$pair/B.out" >&2; exit 1; }
    assert_uniform "$pair/target.txt" B
  else
    [ "$sb" -eq 23 ] || { cat "$pair/B.out" >&2; exit 1; }
    grep -q '^RESULT B ERROR ' "$pair/B.out"
    grep -Eq 'native error [0-9]+' "$pair/B.out"
    assert_uniform "$pair/target.txt" A
  fi
}

# Positive: both writers publish, and the deliberately-last writer wins with a
# complete payload after colliding and retrying onto its own inode.
run_pair both-success

# Negative: B writes its own inode, then loses that pathname before publish.
# Its rename fails and cannot alter A's already-published result.
run_pair publish-failure

# A non-collision create error is reported immediately, is not retried, and
# leaves the pre-existing destination unchanged.
err="$work/create-error"
mkdir "$err"
printf '%s' sentinel >"$err/target.txt"
se=0
"$chez" --script test/chez/spit-atomic-worker.ss E "$err" create-error \
  >"$err/E.out" 2>&1 || se=$?
[ "$se" -eq 23 ] || { cat "$err/E.out" >&2; exit 1; }
[ "$(wc -l <"$err/attempts-E" | tr -d ' ')" -eq 1 ]
grep -q 'error 13' "$err/attempts-E"
grep -q 'native error 13' "$err/E.out"
[ "$(cat "$err/target.txt")" = sentinel ]

echo "SPIT-ATOMIC-TEST OK"
