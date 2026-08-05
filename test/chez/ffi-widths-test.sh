#!/bin/sh
# ffi-widths-test.sh — compiles the exact-width C helper and runs the jolt.ffi
# exact scalar-widths gate. Invoke from the repo root, like every other gate:
#   sh test/chez/ffi-widths-test.sh "$(CHEZ)"
# The helper .so is built in a temp dir (no tree pollution) and handed to the
# .ss runner as JOLT_FFI_WIDTHS_HELPER.

CHEZ="$1"
[ -n "$CHEZ" ] || { echo "usage: $0 <chez>" >&2; exit 2; }
C="test/chez/ffi-widths-helper.c"
[ -f "$C" ] || { echo "missing $C (run from repo root)" >&2; exit 2; }

SO_DIR="$(mktemp -d)"
case "$(uname -s)" in
  Darwin)              EXT=dylib ;;
  MINGW*|MSYS*|CYGWIN*) EXT=dll ;;
  *)                   EXT=so ;;
esac
SO="$SO_DIR/jolt-ffi-widths-helper.$EXT"
cleanup() {
  status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$SO"
    rmdir "$SO_DIR"
  else
    echo "retained ffi-widths artifacts: $SO_DIR" >&2
  fi
}
trap cleanup EXIT
CC_BIN="${CC:-cc}"

case "$(uname -s)" in
  Darwin)               "$CC_BIN" -dynamiclib -o "$SO" "$C" ;;
  MINGW*|MSYS*|CYGWIN*) "$CC_BIN" -shared -o "$SO" "$C" ;;
  *)                    "$CC_BIN" -shared -fPIC -o "$SO" "$C" ;;
esac || { echo "cc failed to build $C" >&2; exit 1; }

JOLT_FFI_WIDTHS_HELPER="$SO" \
  "$CHEZ" --script test/chez/ffi-widths-test.ss
