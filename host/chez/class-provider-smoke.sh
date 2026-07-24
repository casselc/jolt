#!/bin/sh
# Declarative lazy class providers: source mode, add-deps, and standalone AOT.
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

app="$root/test/chez/class-provider-app"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/jolt-class-provider.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM

echo "class-provider smoke: source mode"
source_out="$(
  JOLT_PWD="$app" JOLT_AOT_CACHE=0 JOLT_CACHE_DIR="$tmp/source-cache" \
    bin/joltc -M:test errors
)"
printf '%s\n' "$source_out"
printf '%s\n' "$source_out" |
  grep -Fq 'class-provider positive before= [0 0 0 0] after= [1 1 1 1]'
printf '%s\n' "$source_out" | grep -Fq 'class-provider errors checked'
printf '%s\n' "$source_out" | grep -Fq 'class-provider PASS'

echo "class-provider smoke: add-deps"
add_out="$(
  JOLT_PWD="$root" JOLT_AOT_CACHE=0 JOLT_CACHE_DIR="$tmp/add-cache" \
    bin/joltc run test/chez/class-provider-add-deps.clj
)"
printf '%s\n' "$add_out"
printf '%s\n' "$add_out" |
  grep -Fq 'class-provider add-deps before= 0 after= 1 value= :lazy-static'

# Match build-smoke's bounded preflight.  Source + add-deps remain mandatory on
# hosts whose packaged Chez omits libkernel.a/scheme.h.
csv="${JOLT_CHEZ_CSV:-}"
if [ -z "$csv" ]; then
  chez_bin="$(command -v chez || command -v chezscheme || command -v scheme || command -v petite || true)"
  if [ -n "$chez_bin" ]; then
    base="$(cd "$(dirname "$chez_bin")/.." 2>/dev/null && pwd)"
    for d in "$base"/lib/csv*/*/; do
      [ -f "${d}libkernel.a" ] && csv="${d%/}" && break
    done
  fi
fi
if ! command -v cc >/dev/null 2>&1 ||
   [ -z "$csv" ] ||
   [ ! -f "$csv/scheme.h" ] ||
   [ ! -f "$csv/libkernel.a" ]; then
  echo "class-provider smoke: AOT skipped (Chez kernel dev files or C compiler not available)"
  exit 0
fi

echo "class-provider smoke: standalone AOT"
cp -R test/chez/class-provider-app "$tmp/class-provider-app"
cp -R test/chez/class-provider-lib "$tmp/class-provider-lib"
out="$tmp/class-provider-bin"
JOLT_CHEZ_CSV="$csv" JOLT_PWD="$tmp/class-provider-app" JOLT_AOT_CACHE=0 \
  bin/joltc build -m cpapp.main -o "$out" >/dev/null

# The mapping is registered by the catalog, but the first uses live inside
# -main.  Presence in flat.ss proves the build graph included each provider
# rather than accidentally reading its source at runtime.
for provider in \
  cpfixture.static-provider \
  cpfixture.ctor-provider \
  cpfixture.buffer-provider \
  cpfixture.standard-charsets-provider
do
  grep -Fq "$provider" "$out.build/flat.ss"
done

rm -rf "$tmp/class-provider-app" "$tmp/class-provider-lib"
built_out="$(cd / && "$out")"
printf '%s\n' "$built_out"
printf '%s\n' "$built_out" |
  grep -Fq 'class-provider positive before= [1 1 1 1] after= [1 1 1 1]'
printf '%s\n' "$built_out" | grep -Fq 'class-provider PASS'

echo "class-provider smoke: passed"
