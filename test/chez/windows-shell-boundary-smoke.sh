#!/bin/sh
# Native-Windows smoke for jolt.host's POSIX-shell boundary and the cold Git
# dependency path that consumes it. Run from MSYS2 with a packaged jolt.exe.
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
JOLT_BIN="${JOLT_BIN:-target/release/jolt.exe}"
case "$JOLT_BIN" in
  /*) ;;
  *) JOLT_BIN="$root/$JOLT_BIN" ;;
esac

scratch="$root/target/windows-shell-boundary-${GITHUB_RUN_ID:-local}-$$"
mkdir -p "$scratch/temp scripts" "$scratch/shell path with spaces"
cleanup() {
  rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -rf "$scratch"
  else
    echo "windows shell boundary evidence preserved at: $scratch" >&2
  fi
  return "$rc"
}
trap cleanup EXIT

# A .cmd indirection gives JOLT_SH a native executable path containing spaces
# while leaving the actual MSYS2 sh installation untouched. Jolt must quote this
# path at the cmd.exe boundary; the POSIX command itself is passed in a script.
real_sh="$(cygpath -w "$(command -v sh)")"
selected_sh="$scratch/shell path with spaces/selected sh.cmd"
printf '@"%s" %%*\r\n' "$real_sh" > "$selected_sh"
export JOLT_SH="$(cygpath -w "$selected_sh")"
export TEMP="$(cygpath -w "$scratch/temp scripts")"
export TMP="$TEMP"
export JOLT_NO_USER_DEPS=1

"$JOLT_BIN" run test/chez/windows-shell-boundary-test.clj

# Exercise dependency resolution from a genuinely empty Jolt Git cache. This
# runs mkdir, clone, checkout, submodule, touch, mv, and cleanup through
# jolt.host/sh rather than merely testing the host primitive in isolation.
dep="$scratch/cold dep"
app="$scratch/cold app"
cache="$scratch/cold cache"
mkdir -p "$dep/src/cold" "$app"
printf '%s\n' '{:paths ["src"]}' > "$dep/deps.edn"
printf '%s\n' '(ns cold.boundary) (defn -main [& _] (println "cold-dep-ok"))' \
  > "$dep/src/cold/boundary.clj"
git -C "$dep" init -q
git -C "$dep" -c user.name=jolt-test -c user.email=jolt@example.invalid \
  add deps.edn src/cold/boundary.clj
git -C "$dep" -c user.name=jolt-test -c user.email=jolt@example.invalid \
  commit -q -m fixture
sha="$(git -C "$dep" rev-parse HEAD)"
url="$(cygpath -m "$dep")"
printf '{:deps {fixture/cold {:git/url %s :git/sha %s}}\n' \
  "$(printf '%s' "$url" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')" \
  "\"$sha\"" > "$app/deps.edn"
printf ' :aliases {:run {:main-opts ["-m" "cold.boundary"]}}}\n' >> "$app/deps.edn"

export JOLT_GITLIBS="$(cygpath -m "$cache")"
out="$(cd "$app" && "$JOLT_BIN" -M:run)"
[ "$out" = "cold-dep-ok" ] || {
  echo "FAIL: cold Windows Git dependency through selected JOLT_SH" >&2
  echo "  expected: cold-dep-ok" >&2
  echo "  actual:   $out" >&2
  exit 1
}

# Successful calls remove their private scripts; residue means one boundary
# leaked or two concurrent calls collided during cleanup.
if find "$scratch/temp scripts" -name 'jolt-runtime-sh-*.sh' -print | grep -q .; then
  echo "FAIL: successful shell calls left temporary scripts" >&2
  exit 1
fi
echo "windows shell boundary: cold dependency passed"
