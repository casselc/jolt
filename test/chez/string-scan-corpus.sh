#!/bin/sh
set -eu

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/jolt-string-scan-corpus.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

clj_out="$tmp_dir/jvm.edn"
jolt_out="$tmp_dir/jolt.edn"
jvm_version=$(sed -n 's/^ :clojure-version "\([^"]*\)".*/\1/p' \
  test/conformance/profile.edn)
test -n "$jvm_version"
jvm_deps="{:deps {org.clojure/clojure {:mvn/version \"$jvm_version\"}}}"

clojure -Srepro -Sdeps "$jvm_deps" -M test/chez/string-scan-corpus.clj >"$clj_out"
bin/jolt -Srepro test/chez/string-scan-corpus.clj >"$jolt_out"

if ! cmp -s "$clj_out" "$jolt_out"; then
  diff -u "$clj_out" "$jolt_out"
  exit 1
fi

"${JOLT_CHEZ:?JOLT_CHEZ must name the selected Chez}" --script \
  test/chez/string-indexof-internal-test.ss

printf 'string scan corpus: JVM and jolt agree (named cases + 1024 generated rows)\n'
