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
  JOLT_PWD="$app" JOLT_CACHE_DIR="$tmp/source-cache" \
    bin/joltc -M:test errors
)"
printf '%s\n' "$source_out"
printf '%s\n' "$source_out" |
  grep -Fq 'class-provider positive before= [0 0 0 0 0] after= [1 1 1 1 1]'
printf '%s\n' "$source_out" | grep -Fq 'class-provider errors checked'
printf '%s\n' "$source_out" | grep -Fq 'class-provider PASS'

echo "class-provider smoke: add-deps"
add_out="$(
  JOLT_PWD="$root" JOLT_CACHE_DIR="$tmp/add-cache" \
    bin/joltc run test/chez/class-provider-add-deps.clj
)"
printf '%s\n' "$add_out"
printf '%s\n' "$add_out" |
  grep -Fq 'class-provider add-deps before= 0 after= 1 value= :lazy-static nested= :transitive-provider'

echo "class-provider smoke: dependency conflict provenance"
conflict_out="$(
  JOLT_PWD="$root" JOLT_CACHE_DIR="$tmp/conflict-cache" \
    bin/joltc run test/chez/class-provider-deps-conflict.clj
)"
printf '%s\n' "$conflict_out"
printf '%s\n' "$conflict_out" |
  grep -Fq 'class-provider dependency conflict provenance= true'

# Match build-smoke's bounded preflight.  Source + add-deps remain mandatory on
# hosts whose packaged Chez omits libkernel.a/scheme.h.
csv="${JOLT_CHEZ_CSV:-}"
if [ -z "$csv" ]; then
  if [ -n "${JOLT_CHEZ:-}" ]; then
    chez_bin="$(command -v "$JOLT_CHEZ" 2>/dev/null || true)"
  else
    chez_bin="$(command -v chez || command -v chezscheme || command -v scheme || command -v petite || true)"
  fi
  if [ -n "$chez_bin" ]; then
    chez_dir="$(cd "$(dirname "$chez_bin")" 2>/dev/null && pwd)"
    if [ -f "$chez_dir/libkernel.a" ] && [ -f "$chez_dir/scheme.h" ]; then
      csv="$chez_dir"
    else
      base="$(cd "$chez_dir/.." 2>/dev/null && pwd)"
      for d in "$base"/lib/csv*/*/; do
        [ -f "${d}libkernel.a" ] && csv="${d%/}" && break
      done
    fi
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
cp -R test/chez/class-provider-nested "$tmp/class-provider-nested"
out="$tmp/class-provider-bin"
JOLT_CHEZ_CSV="$csv" JOLT_PWD="$tmp/class-provider-app" \
  bin/joltc build -m cpapp.main -o "$out" >/dev/null

# The mapping comes only from resolved deps.edn metadata and first use lives
# inside -main. Presence in flat.ss proves the closed build froze the metadata
# and included every transitive provider namespace.
for provider in \
  cpfixture.static-provider \
  cpfixture.ctor-provider \
  cpfixture.concurrent-provider \
  cpfixture.buffer-provider \
  cpfixture.standard-charsets-provider \
  cpfixture.acme-buffer-provider \
  nestedfixture.deep-provider
do
  grep -Fq "$provider" "$out.build/flat.ss"
done

rm -rf "$tmp/class-provider-app" "$tmp/class-provider-lib" \
       "$tmp/class-provider-nested"
built_out="$(cd / && "$out")"
printf '%s\n' "$built_out"
printf '%s\n' "$built_out" |
  grep -Fq 'class-provider positive before= [1 1 1 1 1] after= [1 1 1 1 1]'
printf '%s\n' "$built_out" | grep -Fq 'class-provider PASS'

echo "class-provider smoke: passed"
