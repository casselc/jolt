#!/bin/sh
# Build a converged compiler seed in an isolated temporary directory, then run
# one Scheme gate with that prelude/image pair. Compiler-source features can be
# tested before the checked-in seed is reminted, without modifying seed files.
#
# Successful runs remove the temporary tree. Any bootstrap, convergence, or
# gate failure retains every per-pass stream plus the last seed pair and prints
# the exact directory for forensic inspection. A process/host crash also leaves
# the mktemp tree behind because cleanup has not observed a successful exit.
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

if [ "$#" -lt 1 ]; then
  echo "usage: transient-seed-gate.sh RUNNER [RUNNER-ARG ...]" >&2
  exit 2
fi

runner="$1"
shift
case "$runner" in
  /*) ;;
  *) runner="$root/$runner" ;;
esac
if [ ! -f "$runner" ]; then
  echo "transient seed gate runner not found: $runner" >&2
  exit 2
fi

CHEZ="${CHEZ:-$(command -v chez 2>/dev/null || command -v chezscheme 2>/dev/null || command -v scheme 2>/dev/null || true)}"
case "$CHEZ" in
  */*) ;;
  *) CHEZ="$(command -v "$CHEZ" 2>/dev/null || true)" ;;
esac
if [ -z "$CHEZ" ] || [ ! -x "$CHEZ" ]; then
  echo "transient seed gate requires an executable Chez compiler" >&2
  exit 2
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/jolt-transient-seed.XXXXXX")"
cleanup() {
  status=$?
  trap - 0
  if [ "$status" -eq 0 ]; then
    rm -rf -- "$tmp"
  else
    echo "retained transient seed artifacts: $tmp" >&2
  fi
  exit "$status"
}
trap cleanup 0

cp host/chez/seed/prelude.ss "$tmp/cur-p.ss"
cp host/chez/seed/image.ss "$tmp/cur-i.ss"

i=0
while [ "$i" -lt 8 ]; do
  i=$((i + 1))
  if "$CHEZ" --script host/chez/bootstrap.ss \
      "$tmp/cur-p.ss" "$tmp/cur-i.ss" \
      "$tmp/new-p.ss" "$tmp/new-i.ss" \
      >"$tmp/pass-$i.out" 2>"$tmp/pass-$i.err"; then
    :
  else
    status=$?
    cat "$tmp/pass-$i.out"
    cat "$tmp/pass-$i.err" >&2
    echo "transient seed bootstrap failed on pass $i with status $status" >&2
    exit "$status"
  fi

  if diff -q "$tmp/cur-p.ss" "$tmp/new-p.ss" >/dev/null \
     && diff -q "$tmp/cur-i.ss" "$tmp/new-i.ss" >/dev/null; then
    # Native Chez writes this record to stderr on POSIX and stdout on Windows.
    # Require one unambiguous record across the two captured streams.
    sed -n 's/^mint: \([0-9][0-9]*\) form(s) skipped$/\1/p' \
      "$tmp/pass-$i.out" "$tmp/pass-$i.err" >"$tmp/skip-counts"
    records="$(wc -l <"$tmp/skip-counts" | tr -d '[:space:]')"
    if [ "$records" -ne 1 ]; then
      echo "transient seed gate expected exactly one converged skip count" >&2
      cat "$tmp/pass-$i.out"
      cat "$tmp/pass-$i.err" >&2
      exit 1
    fi
    skipped="$(sed -n '1p' "$tmp/skip-counts")"
    if [ "$skipped" -ne 0 ]; then
      echo "transient seed gate: $skipped form(s) failed to compile" >&2
      grep '^mint: skipped ' "$tmp/pass-$i.out" "$tmp/pass-$i.err" >&2 || true
      exit 1
    fi

    echo "transient seed gate: converged after $i pass(es)"
    if "$CHEZ" --script "$runner" "$tmp/new-p.ss" "$tmp/new-i.ss" "$@" \
        >"$tmp/gate.out" 2>"$tmp/gate.err"; then
      cat "$tmp/gate.out"
      cat "$tmp/gate.err" >&2
      exit 0
    else
      status=$?
      cat "$tmp/gate.out"
      cat "$tmp/gate.err" >&2
      echo "transient seed runner failed with status $status" >&2
      exit "$status"
    fi
  fi

  cp "$tmp/new-p.ss" "$tmp/cur-p.ss"
  cp "$tmp/new-i.ss" "$tmp/cur-i.ss"
done

echo "transient seed gate did not converge in 8 passes" >&2
exit 1
