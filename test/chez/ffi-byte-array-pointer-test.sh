#!/bin/sh
# ffi-byte-array-pointer-test.sh — compiles the scoped-pointer C helper and runs
# the jolt.ffi byte-array pointer-loan gate. Invoke from the repo root, like
# every other gate:
#   sh test/chez/ffi-byte-array-pointer-test.sh "$(CHEZ)"
# The helper shared object is built in a temp dir (no tree pollution) and
# passed to the .ss runner via JOLT_FFI_BYTE_ARRAY_POINTER_HELPER.
#
# Mirrors test/chez/ffi-widths-test.sh and ffi-native-error-test.sh one-for-one
# (same platform dispatch, temp dir, failure-artifact-preserving trap, CC
# override) so the three FFI helper gates stay uniform.

CHEZ="$1"
[ -n "$CHEZ" ] || { echo "usage: $0 <chez>" >&2; exit 2; }
C="test/chez/ffi-byte-array-pointer-helper.c"
[ -f "$C" ] || { echo "missing $C (run from repo root)" >&2; exit 2; }

SO_DIR="$(mktemp -d)"
case "$(uname -s)" in
  Darwin)              EXT=dylib ;;
  MINGW*|MSYS*|CYGWIN*) EXT=dll ;;
  *)                   EXT=so ;;
esac
SO="$SO_DIR/jolt-ffi-byte-array-pointer-helper.$EXT"
cleanup() {
  status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$SO"
    rmdir "$SO_DIR"
  else
    echo "retained ffi-byte-array-pointer artifacts: $SO_DIR" >&2
  fi
}
trap cleanup EXIT
CC_BIN="${CC:-cc}"

case "$(uname -s)" in
  Darwin)               "$CC_BIN" -dynamiclib -o "$SO" "$C" ;;
  MINGW*|MSYS*|CYGWIN*) "$CC_BIN" -shared -o "$SO" "$C" ;;
  *)                    "$CC_BIN" -shared -fPIC -o "$SO" "$C" ;;
esac || { echo "cc failed to build $C" >&2; exit 1; }

JOLT_FFI_BYTE_ARRAY_POINTER_HELPER="$SO" \
  "$CHEZ" --script test/chez/ffi-byte-array-pointer-test.ss
