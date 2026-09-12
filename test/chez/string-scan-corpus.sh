#!/bin/sh
set -eu

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/jolt-string-scan-corpus.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

clj_out="$tmp_dir/jvm.edn"
jolt_out="$tmp_dir/jolt.edn"

clojure -Srepro -M test/chez/string-scan-corpus.clj >"$clj_out"
bin/jolt -Srepro test/chez/string-scan-corpus.clj >"$jolt_out"

if ! cmp -s "$clj_out" "$jolt_out"; then
  diff -u "$clj_out" "$jolt_out"
  exit 1
fi

printf 'string scan corpus: JVM and jolt agree (named cases + 1024 generated rows)\n'
