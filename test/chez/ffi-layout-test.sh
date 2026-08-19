#!/bin/sh
set -u

CHEZ=${1-}
[ -n "$CHEZ" ] || { echo "usage: $0 <chez>" >&2; exit 2; }
C=test/chez/ffi-layout-helper.c
OUT=$(mktemp -d) || exit 1
case "$(uname -s)" in
  Darwin) EXT=dylib ;;
  MINGW*|MSYS*|CYGWIN*) EXT=dll ;;
  *) EXT=so ;;
esac
SO=$OUT/jolt-ffi-layout-helper.$EXT
cleanup() {
  status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$SO"
    rmdir "$OUT"
  else
    echo "retained ffi-layout artifacts: $OUT" >&2
  fi
}
trap cleanup EXIT
CC_BIN=${CC:-cc}
case "$(uname -s)" in
  Darwin) "$CC_BIN" -std=c11 -dynamiclib -o "$SO" "$C" ;;
  MINGW*|MSYS*|CYGWIN*) "$CC_BIN" -std=c11 -shared -o "$SO" "$C" ;;
  *) "$CC_BIN" -std=c11 -shared -fPIC -o "$SO" "$C" ;;
esac || exit 1
JOLT_FFI_LAYOUT_HELPER=$SO "$CHEZ" --script test/chez/ffi-layout-test.ss
