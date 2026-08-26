#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/jolt-install-smoke.XXXXXX")
trap 'rm -rf "$work"' EXIT

version=9.9.9
tag="v${version}"
target=x86_64-macos
archive="jolt-${tag}-${target}.tar.gz"
fixture="$work/fixture"
payload="$fixture/jolt-${tag}-${target}"
mkdir -p "$payload" "$work/bin" "$work/download" "$work/install"

printf '%s\n' \
  '#!/bin/sh' \
  'test "${1:-}" = --version && echo "jolt v9.9.9"' \
  > "$payload/jolt"
chmod +x "$payload/jolt"
tar -C "$fixture" -czf "$fixture/$archive" "jolt-${tag}-${target}"
if command -v sha256sum >/dev/null 2>&1; then
  checksum=$(sha256sum "$fixture/$archive" | cut -d' ' -f1)
else
  checksum=$(shasum -a 256 "$fixture/$archive" | cut -d' ' -f1)
fi
printf '%s  %s\n' "$checksum" "$archive" > "$fixture/$archive.sha256"

printf '%s\n' \
  '#!/bin/sh' \
  'case "${1:-}" in' \
  '  -s) echo Darwin ;;' \
  '  -m) echo x86_64 ;;' \
  '  *) exit 2 ;;' \
  'esac' > "$work/bin/uname"
chmod +x "$work/bin/uname"

printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'url=' \
  'outfile=' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in' \
  '    -o) outfile=$2; shift 2 ;;' \
  '    -*) shift ;;' \
  '    *) url=$1; shift ;;' \
  '  esac' \
  'done' \
  'printf "%s\\n" "$url" >> "$JOLT_INSTALL_URL_LOG"' \
  'source_file="$JOLT_INSTALL_FIXTURE_DIR/${url##*/}"' \
  'if [ -n "$outfile" ]; then' \
  '  cp "$source_file" "$outfile"' \
  'else' \
  '  cat "$source_file"' \
  'fi' \
  > "$work/bin/curl"
chmod +x "$work/bin/curl"

PATH="$work/bin:$PATH" \
JOLT_INSTALL_FIXTURE_DIR="$fixture" \
JOLT_INSTALL_URL_LOG="$work/urls" \
  bash "$repo_root/install" \
    --dir "$work/install" \
    --download-dir "$work/download" \
    --version "$version"

test -x "$work/install/jolt"
test "$("$work/install/jolt" --version)" = "jolt v${version}"
base_url="https://github.com/jolt-lang/jolt/releases/download/${tag}/${archive}"
grep -Fxq "$base_url" "$work/urls"
grep -Fxq "${base_url}.sha256" "$work/urls"

echo "install-smoke: Intel macOS selects and verifies the published release asset"
