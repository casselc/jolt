#!/bin/sh
# self-host fixpoint gate: bootstrap.ss rebuilds the prelude + compiler image from
# source on pure Chez; the rebuild must equal the checked-in seed byte-for-byte. If
# it doesn't, a seed source changed without a re-mint — run `make remint`.
set -e

# Resolve the selected compiler before changing directories. Make exports
# JOLT_CHEZ even when its CHEZ variable is not present in recipe environments;
# ignoring it can silently check a seed with a different `scheme` found on PATH.
requested_chez="${JOLT_CHEZ:-${CHEZ:-}}"
if [ -n "$requested_chez" ]; then
  CHEZ="$(command -v "$requested_chez" 2>/dev/null || true)"
else
  CHEZ="$(command -v chez 2>/dev/null || command -v chezscheme 2>/dev/null ||
    command -v scheme 2>/dev/null || true)"
fi
if [ -z "$CHEZ" ] || [ ! -x "$CHEZ" ]; then
  echo "self-host: selected Chez is not executable: ${requested_chez:-<none>}" >&2
  exit 1
fi
case "$CHEZ" in
  /*|[A-Za-z]:[\\/]*|\\\\*) ;;
  *)
    chez_dir="$(CDPATH= cd -- "$(dirname -- "$CHEZ")" && pwd -P)"
    CHEZ="$chez_dir/$(basename -- "$CHEZ")"
    ;;
esac

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
tmp="$(mktemp -d)"
cleanup() {
  status=$?
  if [ "$status" -eq 0 ] && [ "${JOLT_PRESERVE_TEST_ARTIFACTS:-}" != "1" ]; then
    rm -rf "$tmp"
  else
    echo "self-host: preserved artifacts at $tmp" >&2
  fi
}
trap cleanup EXIT
"$CHEZ" --script host/chez/bootstrap.ss \
  host/chez/seed/prelude.ss host/chez/seed/image.ss "$tmp/p.ss" "$tmp/i.ss" >/dev/null
if diff -q host/chez/seed/prelude.ss "$tmp/p.ss" >/dev/null \
   && diff -q host/chez/seed/image.ss "$tmp/i.ss" >/dev/null; then
  echo "self-host fixpoint: rebuild == checked-in seed"
else
  echo "self-host FAILED: bootstrap rebuild != checked-in seed; run 'make remint'" >&2
  exit 1
fi
