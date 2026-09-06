#!/bin/sh
# Exit zero only when a runnable test binary embeds this build's commit identity.
# Watched-source freshness remains the Makefile's separate mtime check. Callers
# use nonzero to rebuild, never as an error.
set -eu

binary="${1:?usage: testbin-current.sh BINARY [CHECKOUT]}"
root="${2:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"

[ -x "$binary" ] || exit 1
if [ -n "${JOLT_VERSION:-}" ]; then
  expected="$JOLT_VERSION"
else
  expected="$("$root/tools/version.sh" "$root")"
fi
actual="$("$binary" --version 2>/dev/null)" || exit 1

# Dirty is a working-tree state, not a commit identity. Comparing it literally
# would rebuild for an unwatched docs/test edit, while the existing mtime gate
# catches ordinary edits whose watched source mtime advances past testbin.
case "$expected" in *-dirty) expected="${expected%-dirty}" ;; esac
case "$actual" in *-dirty) actual="${actual%-dirty}" ;; esac
[ "$actual" = "jolt $expected" ]
