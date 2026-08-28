#!/bin/sh
# Compile and run the Linux target-header/runtime witness for jolt.publish.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
bin=$(mktemp "${TMPDIR:-/tmp}/jolt-publish-abi.XXXXXX")
trap 'rm -f "$bin"' EXIT HUP INT TERM

"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -O2 \
  "$root/test/chez/atomic-publish-abi-probe.c" -o "$bin"
"$bin"
