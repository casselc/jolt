#!/bin/sh
# The launcher and child build compiler must retain the explicitly selected
# Chez rather than rediscovering an unrelated executable from PATH.
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

real_chez="${CHEZ:-${JOLT_CHEZ:-}}"
if [ -z "$real_chez" ]; then
  real_chez="$(command -v chez 2>/dev/null || command -v chezscheme 2>/dev/null ||
    command -v scheme 2>/dev/null || true)"
fi
if [ -z "$real_chez" ] || [ ! -x "$real_chez" ]; then
  echo "selected-chez: no Chez executable"
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
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/path with spaces and ' quote" "$work/probe temp with ' quote"
wrapper="$work/path with spaces and ' quote/selected-chez"
marker="$work/invocations"
probe_tmp="$work/probe temp with ' quote"

cat >"$wrapper" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$JOLT_TEST_MARKER"
if [ "${1:-}" = "--script" ] && [ "${2:-}" = "host/chez/bootstrap.ss" ]; then
  cp "$3" "$5"
  cp "$4" "$6"
  exit 0
fi
exec "$JOLT_TEST_REAL_CHEZ" "$@"
EOF
chmod +x "$wrapper"

got="$(
  JOLT_CHEZ="$wrapper" \
  JOLT_TEST_REAL_CHEZ="$real_chez" \
  JOLT_TEST_MARKER="$marker" \
  JOLT_AOT_CACHE=0 \
  bin/jolt -e '(+ 1 2)'
)"
[ "$got" = "3" ] || {
  echo "selected-chez: launcher returned '$got', expected 3"
  exit 1
}
grep -q -- '--script host/chez/' "$marker" || {
  echo "selected-chez: selected launcher executable was not observed"
  exit 1
}

# command -v is permitted to preserve an explicit relative spelling. The
# launcher must make it stable before changing to the jolt checkout.
relative_dir="$work/relative cwd"
mkdir -p "$relative_dir"
ln -s "$wrapper" "$relative_dir/selected-chez"
got="$(
  cd "$relative_dir"
  JOLT_CHEZ=./selected-chez \
  JOLT_TEST_REAL_CHEZ="$real_chez" \
  JOLT_TEST_MARKER="$marker" \
  JOLT_AOT_CACHE=0 \
  "$root/bin/jolt" -e '(+ 2 3)'
)"
[ "$got" = "5" ] || {
  echo "selected-chez: relative launcher returned '$got', expected 5"
  exit 1
}

if JOLT_CHEZ="$work/missing-chez" bin/jolt -e '(+ 1 2)' \
    >"$work/missing.out" 2>&1; then
  echo "selected-chez: missing explicit executable unexpectedly succeeded"
  exit 1
fi
grep -q 'JOLT_CHEZ does not name an executable' "$work/missing.out" || {
  echo "selected-chez: missing executable did not fail with the selection diagnostic"
  exit 1
}

# Direct build entry points enforce the same fail-closed selection even when
# they are not reached through bin/jolt.
if JOLT_CHEZ="$work/missing-chez" \
    JOLT_CHEZ_CSV="${JOLT_CHEZ_CSV:-$work/missing-csv}" \
    "$real_chez" --script host/chez/build-jolt.ss debug "$work/unused" \
    >"$work/missing-build.out" 2>&1; then
  echo "selected-chez: direct build accepted a missing selected compiler"
  exit 1
fi
grep -q 'selected child Chez is not executable' "$work/missing-build.out" || {
  echo "selected-chez: direct build did not fail with the selection diagnostic"
  cat "$work/missing-build.out"
  exit 1
}

# A selected executable is external input, not one of the repository paths
# covered by the old "no apostrophes" quoting assumption. This value would run
# touch under the old one-pair-of-single-quotes helper.
injected="$work/injected"
injection_selection="$work/missing'; touch '$injected'; echo 'fake"
if JOLT_CHEZ="$injection_selection" \
    JOLT_CHEZ_CSV="$work/missing-csv" \
    "$real_chez" --script host/chez/build-jolt.ss debug "$work/unused" \
    >"$work/injection.out" 2>&1; then
  echo "selected-chez: injection-shaped missing compiler unexpectedly succeeded"
  exit 1
fi
[ ! -e "$injected" ] || {
  echo "selected-chez: selected compiler text escaped shell quoting"
  exit 1
}
grep -q 'selected child Chez is not executable' "$work/injection.out" || {
  echo "selected-chez: injection-shaped compiler lacked the missing-tool diagnostic"
  cat "$work/injection.out"
  exit 1
}

empty_version="$work/empty-version"
cat >"$empty_version" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  exit 0
fi
exec "$JOLT_TEST_REAL_CHEZ" "$@"
EOF
chmod +x "$empty_version"
if JOLT_CHEZ="$empty_version" \
    JOLT_CHEZ_CSV="$work/missing-csv" \
    JOLT_TEST_REAL_CHEZ="$real_chez" \
    TMPDIR="$probe_tmp" \
    "$real_chez" --script host/chez/build-jolt.ss debug "$work/unused" \
    >"$work/empty-version.out" 2>&1; then
  echo "selected-chez: empty child version unexpectedly succeeded"
  exit 1
fi
grep -q 'did not report a parseable version' "$work/empty-version.out" || {
  echo "selected-chez: empty child version did not fail closed"
  cat "$work/empty-version.out"
  exit 1
}

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
if JOLT_CHEZ="$failed_version" \
    JOLT_CHEZ_CSV="$work/missing-csv" \
    JOLT_TEST_REAL_CHEZ="$real_chez" \
    TMPDIR="$probe_tmp" \
    "$real_chez" --script host/chez/build-jolt.ss debug "$work/unused" \
    >"$work/failed-version.out" 2>&1; then
  echo "selected-chez: nonzero child version probe unexpectedly succeeded"
  exit 1
fi
grep -q 'selected child Chez version probe failed' "$work/failed-version.out" || {
  echo "selected-chez: nonzero child version probe did not fail closed"
  cat "$work/failed-version.out"
  exit 1
}

mismatch="$work/mismatched-chez"
cat >"$mismatch" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  echo "Chez Scheme Version 0.0-mismatch"
  exit 0
fi
exec "$JOLT_TEST_REAL_CHEZ" "$@"
EOF
chmod +x "$mismatch"

if JOLT_CHEZ="$mismatch" \
    JOLT_TEST_REAL_CHEZ="$real_chez" \
    TMPDIR="$probe_tmp" \
    "$real_chez" --script host/chez/build-jolt.ss debug "$work/jolt" \
    >"$work/mismatch.out" 2>&1; then
  echo "selected-chez: mismatched child compiler unexpectedly succeeded"
  exit 1
fi
grep -q 'selected child Chez .* reports 0.0-mismatch' "$work/mismatch.out" || {
  echo "selected-chez: mismatched compiler did not fail with the version diagnostic"
  cat "$work/mismatch.out"
  exit 1
}
[ ! -e "$work/jolt" ] || {
  echo "selected-chez: mismatched compiler produced an output"
  exit 1
}

if JOLT_CHEZ="$mismatch" \
    JOLT_TEST_REAL_CHEZ="$real_chez" \
    TMPDIR="$probe_tmp" \
    "$real_chez" --script host/chez/make-gateboot.ss \
    >"$work/gateboot-mismatch.out" 2>&1; then
  echo "selected-chez: gate boot accepted a mismatched child compiler"
  exit 1
fi
grep -q 'selected child Chez .* reports 0.0-mismatch' "$work/gateboot-mismatch.out" || {
  echo "selected-chez: gate boot did not fail with the version diagnostic"
  cat "$work/gateboot-mismatch.out"
  exit 1
}

if JOLT_CHEZ="$mismatch" \
    JOLT_TEST_REAL_CHEZ="$real_chez" \
    TMPDIR="$probe_tmp" \
    "$real_chez" --script host/chez/make-devboot.ss \
    >"$work/devboot-mismatch.out" 2>&1; then
  echo "selected-chez: dev boot accepted a mismatched child compiler"
  exit 1
fi
grep -q 'selected child Chez .* reports 0.0-mismatch' "$work/devboot-mismatch.out" || {
  echo "selected-chez: dev boot did not fail with the version diagnostic"
  cat "$work/devboot-mismatch.out"
  exit 1
}

# Same version is not enough on hosts capable of running another architecture
# under emulation (notably Windows ARM64 running x64). Intercept only the
# private machine probe; a version-only check would accept this wrapper.
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
if JOLT_CHEZ="$machine_mismatch" \
    JOLT_CHEZ_CSV="$work/missing-csv" \
    JOLT_TEST_REAL_CHEZ="$real_chez" \
    TMPDIR="$probe_tmp" \
    "$real_chez" --script host/chez/build-jolt.ss debug "$work/unused" \
    >"$work/machine-mismatch.out" 2>&1; then
  echo "selected-chez: mismatched child machine unexpectedly succeeded"
  exit 1
fi
grep -q 'reports machine t-jolt-mismatched-machine' "$work/machine-mismatch.out" || {
  echo "selected-chez: mismatched child machine did not fail closed"
  cat "$work/machine-mismatch.out"
  exit 1
}

# Observe a successful fresh compiler invocation, not merely discovery and
# --version. The private build-dir seam keeps this gate away from target/dev,
# so it cannot race another make process or make an unrelated cache look fresh.
gate_build="$work/isolated gate build"
: >"$marker"
if ! JOLT_CHEZ="$wrapper" \
    JOLT_TEST_REAL_CHEZ="$real_chez" \
    JOLT_TEST_MARKER="$marker" \
    JOLT_GATEBOOT_BUILD_DIR="$gate_build" \
    TMPDIR="$probe_tmp" \
    "$real_chez" --script host/chez/make-gateboot.ss \
    >"$work/gateboot-success.out" 2>&1; then
  echo "selected-chez: isolated gate boot failed"
  cat "$work/gateboot-success.out"
  exit 1
fi
[ -f "$gate_build/gate.so" ] || {
  echo "selected-chez: isolated gate boot produced no compiled image"
  exit 1
}
grep -q -- '--version' "$marker" || {
  echo "selected-chez: successful build did not query the selected compiler"
  exit 1
}
grep -Fq -- "--script $gate_build/gate-compile.ss" "$marker" || {
  echo "selected-chez: isolated compile did not use the selected compiler"
  cat "$marker"
  exit 1
}

# Make exports JOLT_CHEZ but does not necessarily export its internal CHEZ
# variable. Exercise the real remint/selfcheck scripts in a disposable minimal
# checkout, using the wrapper's bootstrap copy control to avoid compiling or
# touching the repository seed.
seed_root="$work/seed script root"
mkdir -p "$seed_root/host/chez/seed"
cp host/chez/remint.sh host/chez/selfcheck.sh "$seed_root/host/chez/"
printf '%s\n' seed-prelude >"$seed_root/host/chez/seed/prelude.ss"
printf '%s\n' seed-image >"$seed_root/host/chez/seed/image.ss"

: >"$marker"
(
  cd "$relative_dir"
  JOLT_CHEZ=./selected-chez \
  CHEZ="$work/missing-chez" \
  JOLT_TEST_REAL_CHEZ="$real_chez" \
  JOLT_TEST_MARKER="$marker" \
  TMPDIR="$probe_tmp" \
  "$seed_root/host/chez/selfcheck.sh"
) >"$work/selfcheck-selection.out" 2>&1 || {
  echo "selected-chez: selfcheck did not retain JOLT_CHEZ"
  cat "$work/selfcheck-selection.out"
  exit 1
}
grep -q -- '--script host/chez/bootstrap.ss' "$marker" || {
  echo "selected-chez: selfcheck did not invoke the selected compiler"
  cat "$marker"
  exit 1
}

: >"$marker"
(
  cd "$relative_dir"
  JOLT_CHEZ=./selected-chez \
  CHEZ="$work/missing-chez" \
  JOLT_TEST_REAL_CHEZ="$real_chez" \
  JOLT_TEST_MARKER="$marker" \
  TMPDIR="$probe_tmp" \
  "$seed_root/host/chez/remint.sh"
) >"$work/remint-selection.out" 2>&1 || {
  echo "selected-chez: remint did not retain JOLT_CHEZ"
  cat "$work/remint-selection.out"
  exit 1
}
grep -q -- '--script host/chez/bootstrap.ss' "$marker" || {
  echo "selected-chez: remint did not invoke the selected compiler"
  cat "$marker"
  exit 1
}

echo "selected-chez: 14/14 passed"
