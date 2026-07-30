#!/bin/sh
# End-to-end normal-versus-sim compiler-flavor witness over one unchanged app.
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

normal="${JOLT_NORMAL:-target/release/jolt}"
sim="${JOLT_SIM:-target/sim/jolt}"
case "$normal" in /*) normal_abs="$normal" ;; *) normal_abs="$root/$normal" ;; esac
case "$sim" in /*) sim_abs="$sim" ;; *) sim_abs="$root/$sim" ;; esac

[ -x "$normal_abs" ] || {
  echo "sim compiler profile smoke: missing normal Jolt: $normal_abs" >&2
  exit 1
}
[ -x "$sim_abs" ] || {
  echo "sim compiler profile smoke: missing sim Jolt: $sim_abs" >&2
  exit 1
}

app="$root/test/chez/sim-compiler-app"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out="$work/app"

build_one() {
  compiler="$1"
  label="$2"
  if ! JOLT_PWD="$app" "$compiler" build -m app.core -o "$out" \
       >"$work/$label.log" 2>&1; then
    echo "sim compiler profile smoke: $label build failed" >&2
    cat "$work/$label.log" >&2
    exit 1
  fi
  cp "$out" "$work/$label-app"
  cp "$out.build/flat.ss" "$work/$label-flat.ss"
}

# Use the exact same output path so emitted-source and fingerprint differences
# cannot be explained by path-dependent build text.
build_one "$normal_abs" normal
build_one "$sim_abs" sim

want='[40 2]'
normal_got="$("$work/normal-app")"
sim_got="$("$work/sim-app")"
[ "$normal_got" = "$want" ] || {
  echo "sim compiler profile smoke: normal output mismatch: $normal_got" >&2
  exit 1
}
[ "$sim_got" = "$want" ] || {
  echo "sim compiler profile smoke: sim output mismatch: $sim_got" >&2
  exit 1
}

find_definition() {
  label="$1"
  needle="$2"
  file="$3"
  line="$(grep -F -m 1 "$needle" "$file")" || {
    echo "sim compiler profile smoke: missing $label definition" >&2
    exit 1
  }
  [ -n "$line" ] || {
    echo "sim compiler profile smoke: empty $label definition" >&2
    exit 1
  }
  printf '%s\n' "$line"
}

require_text() {
  label="$1"
  line="$2"
  needle="$3"
  case "$line" in
    *"$needle"*) ;;
    *)
      echo "sim compiler profile smoke: $label omitted $needle" >&2
      exit 1
      ;;
  esac
}

reject_text() {
  label="$1"
  line="$2"
  needle="$3"
  case "$line" in
    *"$needle"*)
      echo "sim compiler profile smoke: $label unexpectedly contained $needle" >&2
      exit 1
      ;;
  esac
}

normal_cfn="$(find_definition "normal c-abs" 'define jv$app.core$c-abs ' "$work/normal-flat.ss")"
normal_blocking="$(find_definition "normal c-abs-blocking" 'define jv$app.core$c-abs-blocking ' "$work/normal-flat.ss")"
sim_cfn="$(find_definition "sim c-abs" 'define jv$app.core$c-abs ' "$work/sim-flat.ss")"
sim_blocking="$(find_definition "sim c-abs-blocking" 'define jv$app.core$c-abs-blocking ' "$work/sim-flat.ss")"

for line in "$normal_cfn" "$normal_blocking"; do
  reject_text "normal app definition" "$line" "jolt-ffi-sim-hook"
  reject_text "normal app definition" "$line" "jolt-ffi-make-sim-descriptor"
done
for line in "$sim_cfn" "$sim_blocking"; do
  require_text "sim app definition" "$line" "jolt-ffi-sim-hook"
  require_text "sim app definition" "$line" "jolt-ffi-make-sim-descriptor"
done

lazy_native='(or p (begin (set! p (foreign-procedure '
for line in "$normal_cfn" "$normal_blocking" "$sim_cfn" "$sim_blocking"; do
  require_text "emitted FFI definition" "$line" "$lazy_native"
done
require_text "normal blocking definition" "$normal_blocking" "__collect_safe"
require_text "sim blocking definition" "$sim_blocking" "__collect_safe"

find_fingerprint() {
  label="$1"
  file="$2"
  line="$(grep -F 'define jolt-baked-runtime-fingerprint ' "$file" | tail -1)"
  [ -n "$line" ] || {
    echo "sim compiler profile smoke: missing $label runtime fingerprint" >&2
    exit 1
  }
  printf '%s\n' "$line"
}

normal_fp="$(find_fingerprint normal "$work/normal-flat.ss")"
sim_fp="$(find_fingerprint sim "$work/sim-flat.ss")"
[ "$normal_fp" != "$sim_fp" ] || {
  echo "sim compiler profile smoke: normal and sim fingerprints did not diverge" >&2
  exit 1
}

echo "sim compiler profile smoke: passed (same app/output; distinct emission and fingerprint)"
