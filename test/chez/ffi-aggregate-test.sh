#!/usr/bin/env sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_dir=${JOLT_FFI_AGGREGATE_BUILD_DIR:-"$repo_dir/target/ffi-aggregate-test"}
mkdir -p "$build_dir"

case "$(uname -s)" in
  Darwin)
    library="$build_dir/libjolt-ffi-aggregate-test.dylib"
    "${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -dynamiclib -fPIC \
      -o "$library" "$repo_dir/test/chez/ffi-aggregate-helper.c"
    ;;
  Linux)
    library="$build_dir/libjolt-ffi-aggregate-test.so"
    "${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -shared -fPIC \
      -o "$library" "$repo_dir/test/chez/ffi-aggregate-helper.c"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    library="$build_dir/jolt-ffi-aggregate-test.dll"
    "${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -shared -static-libgcc \
      -Wl,--no-undefined -o "$library" \
      "$repo_dir/test/chez/ffi-aggregate-helper.c" -lkernel32
    ;;
  *)
    echo "ffi aggregate runtime oracle is not configured for $(uname -s)" >&2
    exit 1
    ;;
esac

cd "$repo_dir"
JOLT_FFI_AGGREGATE_TEST_LIBRARY="$library" \
  CHEZ="${CHEZ:-$(command -v chez 2>/dev/null || command -v chezscheme 2>/dev/null || command -v scheme)}" \
  sh host/chez/transient-seed-gate.sh test/chez/ffi-aggregate-test.ss
