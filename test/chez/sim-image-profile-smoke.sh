#!/bin/sh
# End-to-end ordinary-versus-sim runtime packaging and cache witness.
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

normal="${JOLT_NORMAL:-target/release/jolt}"
sim="${JOLT_SIM:-target/sim/jolt}"
case "$normal" in /*) normal_abs="$normal" ;; *) normal_abs="$root/$normal" ;; esac
case "$sim" in /*) sim_abs="$sim" ;; *) sim_abs="$root/$sim" ;; esac

if [ ! -x "$normal_abs" ] && [ -x "$normal_abs.exe" ]; then
  normal_abs="$normal_abs.exe"
fi
if [ ! -x "$sim_abs" ] && [ -x "$sim_abs.exe" ]; then
  sim_abs="$sim_abs.exe"
fi

[ -x "$normal_abs" ] || {
  echo "sim image smoke: missing ordinary Jolt: $normal_abs" >&2
  exit 1
}
[ -x "$sim_abs" ] || {
  echo "sim image smoke: missing sim Jolt: $sim_abs" >&2
  exit 1
}

compiler_build_dir() {
  compiler="$1"
  if [ -d "$compiler.build" ]; then
    printf '%s\n' "$compiler.build"
    return
  fi
  case "$compiler" in
    *.exe)
      unsuffixed="${compiler%.exe}"
      if [ -d "$unsuffixed.build" ]; then
        printf '%s\n' "$unsuffixed.build"
        return
      fi
      ;;
  esac
  echo "sim image smoke: missing compiler build directory for $compiler" >&2
  return 1
}

normal_compiler_build="$(compiler_build_dir "$normal_abs")"
sim_compiler_build="$(compiler_build_dir "$sim_abs")"

app="$root/test/chez/sim-image-app"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cache="$work/runtime-cache"
out="$work/app"
mkdir -p "$cache"

# This gate specifically proves the split runtime cache. Ambient developer
# overrides must not silently disable either half of the behavior under test.
unset JOLT_NO_FLAT_SPLIT

build_one() {
  compiler="$1"
  label="$2"
  if ! JOLT_PWD="$app" JOLT_AOT_CACHE=0 JOLT_RUNTIME_CACHE=1 \
       JOLT_RUNTIME_CACHE_DIR="$cache" JOLT_BUILD_PROFILE=1 \
       "$compiler" build -m app.core -o "$out" >"$work/$label.log" 2>&1; then
    echo "sim image smoke: $label build failed" >&2
    cat "$work/$label.log" >&2
    exit 1
  fi
  built_out="$out"
  if [ ! -f "$built_out" ] && [ -f "$built_out.exe" ]; then
    built_out="$built_out.exe"
  fi
  [ -f "$built_out" ] || {
    echo "sim image smoke: $label build produced no executable" >&2
    exit 1
  }
  cp "$built_out" "$work/$label-app"
  cp "$built_out.build/runtime.ss" "$work/$label-runtime.ss"
}

cache_count() {
  set -- "$cache"/runtime-*.so
  if [ ! -e "$1" ]; then
    echo 0
  else
    echo "$#"
  fi
}

line_count() {
  awk -v want="$1" '$0 == want { n += 1 } END { print n + 0 }' "$2"
}

# Use one exact output path and one shared empty cache, so profile and cache-key
# differences cannot be explained by app or path drift.
build_one "$normal_abs" normal
build_one "$sim_abs" sim

want='[42 42 true]'
normal_got="$("$work/normal-app")"
sim_got="$("$work/sim-app")"
[ "$normal_got" = "$want" ] || {
  echo "sim image smoke: ordinary output mismatch: $normal_got" >&2
  exit 1
}
[ "$sim_got" = "$want" ] || {
  echo "sim image smoke: sim output mismatch: $sim_got" >&2
  exit 1
}

definition='(define jolt-sim-runtime-image? #t)'

if grep -Fq "$definition" "$work/normal-runtime.ss"; then
  echo "sim image smoke: ordinary app runtime contains the sim marker" >&2
  exit 1
fi
if grep -Fq "$definition" "$normal_compiler_build/flat.ss"; then
  echo "sim image smoke: ordinary compiler contains the sim marker" >&2
  exit 1
fi

count="$(line_count "$definition" "$work/sim-runtime.ss")"
[ "$count" -eq 1 ] || {
  echo "sim image smoke: expected one executable sim marker in app runtime, found $count" >&2
  exit 1
}

# The sim compiler has one executable overlay definition plus one escaped copy
# inside its embedded source resource. Count exact source lines for the former,
# and the resource registration itself for the latter, rather than treating the
# intentionally embedded payload as a second executable definition.
count="$(line_count "$definition" "$sim_compiler_build/flat.ss")"
[ "$count" -eq 1 ] || {
  echo "sim image smoke: expected one executable sim marker in compiler, found $count" >&2
  exit 1
}
embedded_count="$(grep -F -c \
  '(register-embedded-resource! "host/chez/sim/runtime.ss"' \
  "$sim_compiler_build/flat.ss" || true)"
[ "$embedded_count" -eq 1 ] || {
  echo "sim image smoke: expected one embedded sim runtime resource, found $embedded_count" >&2
  exit 1
}

# runtime.ss has a generated kernel prologue and trailing fingerprint. Remove
# the fingerprint from ordinary and the overlay-plus-fingerprint from sim; the
# remaining ordinary runtime source must be byte-identical.
sed '/^;; === runtime fingerprint (AOT cache key) ===$/,$d' \
  "$work/normal-runtime.ss" >"$work/normal-runtime-base.ss"
sed '/^;; === simulation-only runtime overlay ===$/,$d' \
  "$work/sim-runtime.ss" >"$work/sim-runtime-base.ss"
cmp "$work/normal-runtime-base.ss" "$work/sim-runtime-base.ss"

normal_fp="$(grep -F 'define jolt-baked-runtime-fingerprint ' "$work/normal-runtime.ss" | tail -1)"
sim_fp="$(grep -F 'define jolt-baked-runtime-fingerprint ' "$work/sim-runtime.ss" | tail -1)"
[ -n "$normal_fp" ] && [ -n "$sim_fp" ] && [ "$normal_fp" != "$sim_fp" ] || {
  echo "sim image smoke: ordinary and sim runtime fingerprints did not diverge" >&2
  exit 1
}

[ "$(cache_count)" -eq 2 ] || {
  echo "sim image smoke: expected two cold runtime-cache entries" >&2
  exit 1
}
set -- "$cache"/runtime-*.so
if cmp -s "$1" "$2"; then
  echo "sim image smoke: ordinary and sim runtime cache artifacts are identical" >&2
  exit 1
fi

# Warm rebuilds must reuse, rather than proliferate, the same two flavor keys.
build_one "$normal_abs" normal-warm
build_one "$sim_abs" sim-warm
[ "$(cache_count)" -eq 2 ] || {
  echo "sim image smoke: warm builds changed the two-entry flavor cache" >&2
  exit 1
}
for log in "$work/normal-warm.log" "$work/sim-warm.log"; do
  grep -Fq "runtime fasl (cached)" "$log" || {
    echo "sim image smoke: warm build did not report a runtime-cache hit: $log" >&2
    exit 1
  }
done

[ "$("$work/normal-warm-app")" = "$want" ]
[ "$("$work/sim-warm-app")" = "$want" ]

echo "sim image smoke: passed (isolated overlay + distinct stable runtime-cache keys)"
