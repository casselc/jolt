#!/bin/sh
# External compile passes must use the explicitly selected Chez, and must reject
# a child whose identity cannot be proved to match the running host compiler.
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

real_chez="${CHEZ:-${JOLT_CHEZ:-}}"
if [ -z "$real_chez" ]; then
  real_chez="$(command -v chez 2>/dev/null || command -v chezscheme 2>/dev/null ||
    command -v scheme 2>/dev/null || true)"
fi
if [ -z "$real_chez" ] || [ ! -x "$real_chez" ]; then
  echo "selected-chez: no Chez executable" >&2
  exit 1
fi
case "$real_chez" in
  /*|[A-Za-z]:[\\/]*|\\\\*) ;;
  *)
    real_dir="$(CDPATH= cd -- "$(dirname -- "$real_chez")" && pwd -P)"
    real_chez="$real_dir/$(basename -- "$real_chez")"
    ;;
esac

work="$(mktemp -d)"
passed=0
complete=false
finish() {
  if [ "$complete" = true ]; then
    rm -rf "$work"
  else
    echo "selected-chez: preserved failure evidence at $work" >&2
  fi
}
trap finish EXIT

probe_tmp="$work/probe temp with ' quote"
mkdir -p "$probe_tmp"

machine_probe="$work/host-machine.ss"
cat >"$machine_probe" <<'EOF'
(import (chezscheme))
(display (machine-type))
(newline)
EOF
host_machine="$("$real_chez" --script "$machine_probe")"
host_version="$("$real_chez" --version 2>&1 | sed -n 's/.* //p' | tail -n 1)"
csv="${JOLT_CHEZ_CSV:-$(dirname -- "$real_chez")/../lib/csv$host_version/$host_machine}"

build_expect_failure() {
  name="$1"
  selected="$2"
  diagnostic="$3"
  out="$work/$name.out"
  if JOLT_CHEZ="$selected" \
      JOLT_CHEZ_CSV="$csv" \
      JOLT_TEST_REAL_CHEZ="$real_chez" \
      TMPDIR="$probe_tmp" \
      "$real_chez" --script host/chez/build-jolt.ss debug "$work/$name-jolt" \
      >"$out" 2>&1; then
    echo "selected-chez: $name unexpectedly succeeded" >&2
    return 1
  fi
  if ! grep -Fq "$diagnostic" "$out"; then
    echo "selected-chez: $name lacked expected diagnostic: $diagnostic" >&2
    cat "$out" >&2
    return 1
  fi
  passed=$((passed + 1))
}

build_expect_failure \
  missing-child \
  "$work/missing-chez" \
  "selected child Chez is not executable"

# This string broke the old one-pair-of-single-quotes helper. It must remain a
# literal executable name and must not execute the injected command.
injected="$work/injected"
injection_selection="$work/missing'; touch '$injected'; echo 'fake"
build_expect_failure \
  apostrophe-injection \
  "$injection_selection" \
  "selected child Chez is not executable"
if [ -e "$injected" ]; then
  echo "selected-chez: selected compiler text escaped shell quoting" >&2
  exit 1
fi
passed=$((passed + 1))

empty_version="$work/empty-version"
cat >"$empty_version" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  exit 0
fi
exec "$JOLT_TEST_REAL_CHEZ" "$@"
EOF
chmod +x "$empty_version"
build_expect_failure \
  empty-version \
  "$empty_version" \
  "selected child Chez did not report a parseable version"

failed_version="$work/failed-version"
cat >"$failed_version" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  "$JOLT_TEST_REAL_CHEZ" --version
  exit 7
fi
exec "$JOLT_TEST_REAL_CHEZ" "$@"
EOF
chmod +x "$failed_version"
build_expect_failure \
  failed-version \
  "$failed_version" \
  "selected child Chez version probe failed"

mismatched_version="$work/mismatched-version"
cat >"$mismatched_version" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  echo "Chez Scheme Version 0.0-mismatch"
  exit 0
fi
exec "$JOLT_TEST_REAL_CHEZ" "$@"
EOF
chmod +x "$mismatched_version"
build_expect_failure \
  mismatched-version \
  "$mismatched_version" \
  "reports 0.0-mismatch"

machine_mismatch="$work/machine-mismatch"
cat >"$machine_mismatch" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--script" ]; then
  case "${2:-}" in
    *-machine.ss)
      echo "t-jolt-mismatched-machine"
      exit 0
      ;;
  esac
fi
exec "$JOLT_TEST_REAL_CHEZ" "$@"
EOF
chmod +x "$machine_mismatch"
build_expect_failure \
  mismatched-machine \
  "$machine_mismatch" \
  "reports machine t-jolt-mismatched-machine"

failed_machine="$work/failed-machine"
cat >"$failed_machine" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--script" ]; then
  case "${2:-}" in
    *-machine.ss)
      echo "machine probe failed deliberately"
      exit 8
      ;;
  esac
fi
exec "$JOLT_TEST_REAL_CHEZ" "$@"
EOF
chmod +x "$failed_machine"
build_expect_failure \
  failed-machine \
  "$failed_machine" \
  "selected child Chez machine probe failed"

empty_machine="$work/empty-machine"
cat >"$empty_machine" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--script" ]; then
  case "${2:-}" in
    *-machine.ss)
      exit 0
      ;;
  esac
fi
exec "$JOLT_TEST_REAL_CHEZ" "$@"
EOF
chmod +x "$empty_machine"
build_expect_failure \
  empty-machine \
  "$empty_machine" \
  "selected child Chez did not report a machine type"

# Put a deliberately wrong `chez` first on PATH while selecting a real wrapper
# whose path contains spaces and an apostrophe. The successful fresh compile is
# the regression witness for both exact selection and shell-safe invocation.
wrong_path="$work/wrong-path"
selected_dir="$work/path with spaces and ' quote"
marker="$work/selected-invocations"
wrong_marker="$work/wrong-path-invocations"
mkdir -p "$wrong_path" "$selected_dir" "$work/fresh-output"

cat >"$wrong_path/chez" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$JOLT_TEST_WRONG_MARKER"
echo "wrong PATH Chez must not run" >&2
exit 97
EOF
chmod +x "$wrong_path/chez"

selected="$selected_dir/selected-chez"
cat >"$selected" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$JOLT_TEST_MARKER"
exec "$JOLT_TEST_REAL_CHEZ" "$@"
EOF
chmod +x "$selected"

fresh_jolt="$work/fresh-output/jolt"
if ! PATH="$wrong_path:$PATH" \
    JOLT_CHEZ="$selected" \
    JOLT_CHEZ_CSV="$csv" \
    JOLT_TEST_REAL_CHEZ="$real_chez" \
    JOLT_TEST_MARKER="$marker" \
    JOLT_TEST_WRONG_MARKER="$wrong_marker" \
    TMPDIR="$probe_tmp" \
    "$real_chez" --script host/chez/build-jolt.ss debug "$fresh_jolt" \
    >"$work/fresh-build.out" 2>&1; then
  echo "selected-chez: fresh build through selected compiler failed" >&2
  cat "$work/fresh-build.out" >&2
  exit 1
fi
if [ ! -x "$fresh_jolt" ]; then
  echo "selected-chez: fresh build produced no executable" >&2
  exit 1
fi
if [ -e "$wrong_marker" ]; then
  echo "selected-chez: build rediscovered the wrong PATH compiler" >&2
  cat "$wrong_marker" >&2
  exit 1
fi
if ! grep -q -- '--version' "$marker" ||
   ! grep -q -- '--script .*compile.ss' "$marker"; then
  echo "selected-chez: selected compiler did not perform identity and compile passes" >&2
  cat "$marker" >&2
  exit 1
fi
passed=$((passed + 1))

got="$("$fresh_jolt" -e '(+ 20 22)')"
if [ "$got" != 42 ]; then
  echo "selected-chez: fresh executable returned '$got', expected 42" >&2
  exit 1
fi
passed=$((passed + 1))

complete=true
echo "selected-chez: $passed/11 passed"
