#!/bin/sh
# Build a converged compiler seed in a temporary directory, then run a Scheme
# gate with that prelude/image pair. This validates compiler-source slices before
# the rebase's single checked-in seed remint without modifying host/chez/seed/.
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
if [ -z "$CHEZ" ] || [ ! -x "$CHEZ" ]; then
  echo "transient seed gate requires an executable Chez compiler" >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp host/chez/seed/prelude.ss "$tmp/cur-p.ss"
cp host/chez/seed/image.ss "$tmp/cur-i.ss"

i=0
while [ "$i" -lt 8 ]; do
  i=$((i + 1))
  if ! "$CHEZ" --script host/chez/bootstrap.ss \
      "$tmp/cur-p.ss" "$tmp/cur-i.ss" "$tmp/new-p.ss" "$tmp/new-i.ss" \
      >"$tmp/out" 2>"$tmp/err"; then
    cat "$tmp/err" >&2
    exit 1
  fi

  if diff -q "$tmp/cur-p.ss" "$tmp/new-p.ss" >/dev/null \
     && diff -q "$tmp/cur-i.ss" "$tmp/new-i.ss" >/dev/null; then
    skipped="$(sed -n 's/^mint: \([0-9][0-9]*\) form(s) skipped$/\1/p' "$tmp/err" | tail -1)"
    if [ -z "$skipped" ]; then
      echo "transient seed gate could not verify the converged skip count" >&2
      cat "$tmp/err" >&2
      exit 1
    fi
    if [ "$skipped" -ne 0 ]; then
      echo "transient seed gate: $skipped form(s) failed to compile:" >&2
      grep '^mint: skipped ' "$tmp/err" >&2 || true
      exit 1
    fi
    echo "transient seed gate: converged after $i pass(es)"
    "$CHEZ" --script "$runner" "$tmp/new-p.ss" "$tmp/new-i.ss" "$@"
    exit $?
  fi

  cp "$tmp/new-p.ss" "$tmp/cur-p.ss"
  cp "$tmp/new-i.ss" "$tmp/cur-i.ss"
done

echo "transient seed gate did not converge in 8 passes" >&2
exit 1
