#!/bin/sh
set -eu

chez_bin=${1:-chez}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/jolt-ffi-binding.XXXXXX")

cleanup() {
  rm -rf "$test_tmp"
}
trap cleanup EXIT HUP INT TERM

ffi_cc=${CC:-cc}
case $(uname -s) in
  Darwin)
    helper_lib="$test_tmp/libjolt-ffi-scalar-test.dylib"
    "$ffi_cc" -std=c99 -O2 -Wall -Wextra -dynamiclib \
      "$script_dir/ffi-scalar-helper.c" -o "$helper_lib"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    helper_lib="$test_tmp/jolt-ffi-scalar-test.dll"
    "$ffi_cc" -std=c99 -O2 -Wall -Wextra -shared \
      "$script_dir/ffi-scalar-helper.c" -o "$helper_lib"
    ;;
  *)
    helper_lib="$test_tmp/libjolt-ffi-scalar-test.so"
    "$ffi_cc" -std=c99 -O2 -Wall -Wextra -shared -fPIC \
      "$script_dir/ffi-scalar-helper.c" -o "$helper_lib"
    ;;
esac

cd "$repo_root"
JOLT_FFI_SCALAR_HELPER="$helper_lib" "$chez_bin" --script \
  test/chez/ffi-binding-test.ss
