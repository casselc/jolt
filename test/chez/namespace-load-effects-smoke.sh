#!/bin/sh
# A required namespace's top-level effects must run on every fresh process.
#
# The retired per-namespace AOT cache restored definitions without reliably
# reconstructing runtime registration effects. In particular, a cold process
# registered a deftest while a second process loading the cached namespace ran
# zero tests. Keep JOLT_AOT_CACHE=1 here as a compatibility/adversarial input:
# it must not re-enable namespace artifact reuse, and no cache files may appear.

set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
runner="${1:-}"
if [ -z "$runner" ]; then
  runner="$(command -v chez 2>/dev/null ||
            command -v chezscheme 2>/dev/null ||
            command -v scheme 2>/dev/null ||
            command -v petite 2>/dev/null ||
            true)"
fi
if [ -z "$runner" ]; then
  echo "No packaged jolt or valid Chez Scheme executable found."
  exit 1
fi
case "$runner" in
  *jolt|*jolt.exe|*joltc|*joltc.exe) packaged=1 ;;
  *)                              packaged=0 ;;
esac

tmp="$(mktemp -d)"
cache="$tmp/cache"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/src/fixture" "$tmp/test/fixture" "$cache"

cat > "$tmp/deps.edn" <<'EOF'
{:paths ["src"]
 :aliases {:test {:extra-paths ["test"]
                  :main-opts ["-m" "fixture.runner"]}}}
EOF

cat > "$tmp/test/fixture/sample_test.clj" <<'EOF'
(ns fixture.sample-test
  (:require [clojure.test :refer [deftest is]]))

(deftest registration-survives-a-fresh-process
  (is (= :registered :registered)))
EOF

cat > "$tmp/test/fixture/runner.clj" <<'EOF'
(ns fixture.runner
  (:require [clojure.test :as t]
            [fixture.sample-test]))

(defn -main [& _]
  ;; No explicit namespace: this deliberately exercises deftest's top-level
  ;; registry effect rather than ns-intern metadata as a fallback.
  (let [r (t/run-tests)]
    (println (str "summary="
                  (:test r) "/" (:pass r) "/" (:fail r) "/" (:error r)))))
EOF

run_fixture() {
  if [ "$packaged" = "1" ]; then
    JOLT_PWD="$tmp" \
    JOLT_AOT_CACHE=1 \
    JOLT_CACHE_DIR="$cache" \
    JOLT_QUIET=1 \
      "$runner" -M:test
  else
    JOLT_PWD="$tmp" \
    JOLT_AOT_CACHE=1 \
    JOLT_CACHE_DIR="$cache" \
    JOLT_QUIET=1 \
      "$runner" --script host/chez/cli.ss -M:test
  fi 2>/dev/null |
    sed -n 's/^summary=//p' |
    tail -1
}

cold="$(run_fixture)"
warm="$(run_fixture)"
cache_files="$(find "$cache" -type f 2>/dev/null | wc -l | tr -d ' ')"

if [ "$cold" != "1/1/0/0" ]; then
  echo "FAIL: cold process reported '$cold' (expected 1/1/0/0)"
  exit 1
fi
if [ "$warm" != "1/1/0/0" ]; then
  echo "FAIL: warm process reported '$warm' (expected 1/1/0/0)"
  exit 1
fi
if [ "$cache_files" != "0" ]; then
  echo "FAIL: JOLT_AOT_CACHE created $cache_files namespace cache files"
  exit 1
fi

echo "PASS: fresh processes both replayed namespace effects; namespace cache stayed absent"
