#!/bin/sh
# sim image smoke: the `sim` compiler image (make jolt-sim -> target/sim/jolt)
# carries the simulation runtime overlay (host/chez/sim/runtime.ss,
# jolt.internal.sim composite ABI 6), and a vanilla app built by that compiler
# carries the same overlay automatically — while ordinary release/debug/source
# jolt and the apps they build stay free of simulation source and state.
#
#   CHEZ=/path/to/chez sh test/chez/sim-image-smoke.sh
#
# Uses an existing target/sim/jolt when present (the jolt-sim make target builds
# it and `make simimagesmoke` chains the two); builds it first when missing, so
# the script also runs standalone. Serial throughout — nothing backgrounds.
#
# Artifact policy: the private mktemp tree (app fixture, build logs, built apps)
# is removed ONLY after a fully successful run. Any failure retains it and
# prints the path; nothing here ever removes the target/sim build tree.
set -u

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "  FAIL: $1"; exit 1; }
now() { date +%s; }

# Count the inlined overlay copies in a built image's flat source. An app build
# may split its runtime half into runtime.ss, so look at both; the embedded
# resource copy of the overlay is a one-line string literal, so an anchored
# grep counts only the true inlined code.
overlay_count() {
  total=0
  for f in "$1.build/flat.ss" "$1.build/runtime.ss"; do
    [ -f "$f" ] || continue
    c="$(grep -c '^(define jolt-sim-runtime-image?' "$f")"
    total=$((total + c))
  done
  echo "$total"
}

sim="${JOLT_SIM_BIN:-$root/target/sim/jolt}"

# Chez discovery (transient-seed-gate.sh convention): needed only on the
# standalone path that builds the sim compiler itself. `make simimagesmoke`
# hands CHEZ down and the jolt-sim prerequisite has already built the binary.
CHEZ="${CHEZ:-$(command -v chez 2>/dev/null || command -v chezscheme 2>/dev/null || command -v scheme 2>/dev/null || true)}"
case "$CHEZ" in
  */*) ;;
  *) CHEZ="$(command -v "$CHEZ" 2>/dev/null || true)" ;;
esac

tmp="$(mktemp -d "${TMPDIR:-/tmp}/jolt-sim-image-smoke.XXXXXX")"
cleanup() {
  status=$?
  trap - 0
  if [ "$status" -eq 0 ]; then
    rm -rf -- "$tmp"
  else
    echo "sim image smoke: retained artifacts: $tmp" >&2
  fi
  exit "$status"
}
trap cleanup 0

# --- 0. the sim compiler itself ------------------------------------------------
t0="$(now)"
if [ ! -x "$sim" ]; then
  [ -n "$CHEZ" ] && [ -x "$CHEZ" ] || \
    fail "no sim compiler at $sim and no executable Chez to build one (run 'make jolt-sim')"
  echo "sim image smoke: building $sim (sim profile)"
  if ! "$CHEZ" --script host/chez/build-jolt.ss sim "$sim" >"$tmp/build-jolt-sim.log" 2>&1; then
    tail -20 "$tmp/build-jolt-sim.log" >&2 || true
    fail "build-jolt.ss sim exited non-zero (full log: $tmp/build-jolt-sim.log)"
  fi
  echo "sim image smoke: sim compiler built in $(( $(now) - t0 ))s"
else
  echo "sim image smoke: using existing $sim"
fi
[ -x "$sim" ] || fail "no sim compiler executable at $sim"

# --- 1. the sim compiler reports jolt.internal.sim/capabilities ABI 6 ----------
abi="$("$sim" -e '(:abi-version ((deref (find-var (quote jolt.internal.sim/capabilities)))))' 2>"$tmp/sim-e.err")" \
  || fail "sim compiler -e exited non-zero (see $tmp/sim-e.err)"
[ "$abi" = "6" ] || fail "sim compiler jolt.internal.sim/capabilities :abi-version is '$abi', want 6"
ok

# --- 2. ordinary source jolt lacks the var --------------------------------------
plain="$(bin/jolt -e '(if (find-var (quote jolt.internal.sim/capabilities)) :present :absent)' 2>"$tmp/plain-e.err")" \
  || fail "bin/jolt -e exited non-zero (see $tmp/plain-e.err)"
[ "$plain" = ":absent" ] || fail "ordinary source jolt has jolt.internal.sim/capabilities ('$plain'), want :absent"
ok

# --- 3. exactly one overlay copy in the sim compiler's flat runtime -------------
[ -f "$sim.build/flat.ss" ] || fail "no flat source at $sim.build/flat.ss"
n="$(overlay_count "$sim")"
[ "$n" = "1" ] || fail "sim compiler flat runtime has $n inlined overlay copies, want exactly 1"
ok

# --- 4. the overlay lands after host/chez/java/ffi.ss ----------------------------
ffi_line="$(grep -n '^(define (jolt-ffi-install-declared-call-hook!' "$sim.build/flat.ss" | head -1 | cut -d: -f1)"
sim_line="$(grep -n '^(define jolt-sim-runtime-image?' "$sim.build/flat.ss" | head -1 | cut -d: -f1)"
[ -n "$ffi_line" ] || fail "sim compiler flat.ss is missing the java/ffi.ss declared-call seam"
[ -n "$sim_line" ] || fail "sim compiler flat.ss is missing the overlay marker"
[ "$sim_line" -gt "$ffi_line" ] || \
  fail "overlay (flat.ss line $sim_line) does not follow java/ffi.ss (line $ffi_line)"
ok

# --- 4b. no overlay leaks into any ordinary image flat source present -----------
for f in target/release/jolt.build/flat.ss target/debug/jolt.build/flat.ss; do
  if [ -f "$f" ]; then
    n="$(grep -c 'jolt-sim-runtime-image?' "$f" || true)"
    [ "$n" = "0" ] || fail "ordinary image flat source $f mentions the sim overlay $n time(s)"
    ok
  fi
done

# --- 5. one vanilla app, built by each compiler ----------------------------------
app="$tmp/simapp"
mkdir -p "$app/src/app"
cat >"$app/deps.edn" <<'EOF'
{:paths ["src"]}
EOF
cat >"$app/src/app/core.clj" <<'EOF'
;; Deliberately vanilla: no simulation code of its own. Which compiler built
;; this binary decides what -main prints — the overlay is either spliced in by
;; the build (sim compiler) or the var does not exist at all (ordinary).
(ns app.core)
(defn -main [& _args]
  (println (if-let [v (find-var 'jolt.internal.sim/capabilities)]
             (:abi-version (@v))
             :absent)))
EOF

t0="$(now)"
simapp="$tmp/sim-app-bin"
echo "sim image smoke: compiling vanilla app with the sim compiler"
if ! JOLT_PWD="$app" "$sim" build -m app.core -o "$simapp" >"$tmp/sim-app-build.log" 2>&1; then
  tail -20 "$tmp/sim-app-build.log" >&2 || true
  fail "sim compiler app build exited non-zero (full log: $tmp/sim-app-build.log)"
fi
echo "sim image smoke: sim app built in $(( $(now) - t0 ))s"
[ -x "$simapp" ] || fail "sim compiler produced no app executable"

got="$(cd / && "$simapp" 2>&1)" || fail "sim-built app exited non-zero: $got"
[ "$got" = "6" ] || fail "sim-built app reports jolt.internal.sim ABI '$got', want 6"
ok

n="$(overlay_count "$simapp")"
[ "$n" = "1" ] || fail "sim-built app image has $n inlined overlay copies, want exactly 1"
ok

# The ordinary source-mode build needs Chez kernel dev files + a C compiler
# (build-smoke.sh preflight); skip just this leg where they are absent.
csv="${JOLT_CHEZ_CSV:-}"
if [ -z "$csv" ] && [ -n "$CHEZ" ]; then
  base="$(cd "$(dirname "$CHEZ")/.." 2>/dev/null && pwd)"
  for d in "$base"/lib/csv*/*/; do
    [ -f "${d}libkernel.a" ] && csv="${d%/}" && break
  done
fi
if ! command -v cc >/dev/null 2>&1 || [ -z "$csv" ] || [ ! -f "$csv/scheme.h" ] || [ ! -f "$csv/libkernel.a" ]; then
  echo "sim image smoke: ordinary-app leg skipped (Chez kernel dev files or C compiler not available)"
else
  export JOLT_CHEZ_CSV="$csv"
  t0="$(now)"
  plainapp="$tmp/plain-app-bin"
  echo "sim image smoke: compiling the same app with ordinary source jolt"
  if ! JOLT_PWD="$app" bin/jolt build -m app.core -o "$plainapp" >"$tmp/plain-app-build.log" 2>&1; then
    tail -20 "$tmp/plain-app-build.log" >&2 || true
    fail "ordinary bin/jolt app build exited non-zero (full log: $tmp/plain-app-build.log)"
  fi
  echo "sim image smoke: ordinary app built in $(( $(now) - t0 ))s"
  [ -x "$plainapp" ] || fail "ordinary build produced no app executable"

  got="$(cd / && "$plainapp" 2>&1)" || fail "ordinary-built app exited non-zero: $got"
  [ "$got" = ":absent" ] || fail "ordinary-built app reports '$got', want :absent (no sim overlay)"
  ok

  n="$(overlay_count "$plainapp")"
  [ "$n" = "0" ] || fail "ordinary-built app image inlines the sim overlay $n time(s), want 0"
  ok
fi

echo "sim image smoke: passed ($checks checks: sim compiler ABI 6 + overlay exactly-once-after-ffi, ordinary source jolt :absent, sim-built app ABI 6 + exactly-once, ordinary-built app :absent + no overlay)"
