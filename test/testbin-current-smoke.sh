#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
helper="$root/tools/testbin-current.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/checkout/tools"

printf '%s\n' '#!/bin/sh' \
  'printf '\''%s\n'\'' "$TEST_EXPECTED_VERSION"' \
  >"$tmp/checkout/tools/version.sh"
printf '%s\n' '#!/bin/sh' \
  '[ "${TEST_BINARY_STATUS:-0}" -eq 0 ] || exit "$TEST_BINARY_STATUS"' \
  'printf '\''jolt %s\n'\'' "$TEST_ACTUAL_VERSION"' \
  >"$tmp/jolt"
chmod +x "$tmp/checkout/tools/version.sh" "$tmp/jolt"

pass=0
fail=0
check() {
  label="$1"
  expected="$2"
  shift 2
  if "$@"; then actual=0; else actual=$?; fi
  if [ "$actual" -eq "$expected" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s (expected status %s, got %s)\n' "$label" "$expected" "$actual" >&2
  fi
}

export TEST_EXPECTED_VERSION=v0.8.3-1-g11111111
export TEST_ACTUAL_VERSION=v0.8.3-1-g11111111
unset TEST_BINARY_STATUS
unset JOLT_VERSION
check "exact embedded identity is current" 0 "$helper" "$tmp/jolt" "$tmp/checkout"

export TEST_EXPECTED_VERSION=v0.8.3-1-g11111111-dirty
export TEST_ACTUAL_VERSION=v0.8.3-1-g11111111
check "unwatched dirty state keeps the same commit current" 0 "$helper" "$tmp/jolt" "$tmp/checkout"

export TEST_EXPECTED_VERSION=v0.8.3-1-g11111111
export TEST_ACTUAL_VERSION=v0.8.3-1-g11111111-dirty
check "a dirty build retains the same commit identity" 0 "$helper" "$tmp/jolt" "$tmp/checkout"

export TEST_ACTUAL_VERSION=v0.8.3-0-g00000000
check "prior commit identity is stale" 1 "$helper" "$tmp/jolt" "$tmp/checkout"

export TEST_ACTUAL_VERSION=v0.8.3-0-g00000000-dirty
check "dirty prior commit identity is stale" 1 "$helper" "$tmp/jolt" "$tmp/checkout"

export JOLT_VERSION=ci-probe
export TEST_EXPECTED_VERSION=not-the-build-version
export TEST_ACTUAL_VERSION=ci-probe
check "explicit build version is authoritative" 0 "$helper" "$tmp/jolt" "$tmp/checkout"
unset JOLT_VERSION

export TEST_EXPECTED_VERSION=v0.8.3-1-g11111111
export TEST_ACTUAL_VERSION="$TEST_EXPECTED_VERSION"
export TEST_BINARY_STATUS=7
check "a failing binary is stale" 1 "$helper" "$tmp/jolt" "$tmp/checkout"
unset TEST_BINARY_STATUS

check "a missing binary is stale" 1 "$helper" "$tmp/missing" "$tmp/checkout"

if grep -Fq '! tools/testbin-current.sh target/release/jolt "$(CURDIR)"' "$root/Makefile"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: testbin does not call the exact identity predicate" >&2
fi

printf 'testbin-current smoke: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
