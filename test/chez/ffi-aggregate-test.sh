#!/usr/bin/env sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_dir="$repo_dir/target/ffi-aggregate-test"
mkdir -p "$build_dir"

case "$(uname -s)" in
  Darwin)
    library="$build_dir/libjolt-ffi-aggregate-test.dylib"
    "${CC:-cc}" -dynamiclib -fPIC -O2 \
      -o "$library" "$repo_dir/test/chez/ffi-aggregate-helper.c"
    ;;
  Linux)
    library="$build_dir/libjolt-ffi-aggregate-test.so"
    "${CC:-cc}" -shared -fPIC -O2 \
      -o "$library" "$repo_dir/test/chez/ffi-aggregate-helper.c"
    ;;
  *)
    echo "ffi aggregate runtime oracle is not configured for $(uname -s)" >&2
    exit 1
    ;;
esac

cd "$repo_dir"
JOLT_FFI_AGGREGATE_TEST_LIBRARY="$library" \
  "${CHEZ:-$(command -v chez 2>/dev/null || command -v chezscheme 2>/dev/null || command -v scheme)}" \
  --script test/chez/ffi-aggregate-test.ss
