#!/bin/sh
# park-lock-check.sh — wrapper for the park/lock discipline gate (POSIX sh).
#
# Runs host/chez/park-lock-check.ss under the build's Chez. The checker reads every
# handwritten host .ss file as data, closes "can park" and "can dispatch generic
# code" over the call graph, and checks both lexical and balanced manual counted
# lock regions. Checkpoint controller/recorder mutexes have the stronger
# terminal rule: no generic dispatch or secondary acquisition beneath them. It
# also fails if a switch point stops calling jolt-locks-assert-none!, which is
# the runtime half of the same rule.
#
#   --regen   rewrite host/chez/park-lock-allowlist.txt from reality
#   --self-test run the non-vacuous checker mutation controls
# Generic dispatch findings are tracked separately in park-lock-known-debt.txt;
# every row requires an exact chucklehead-dev/jolt-aspect-packs issue.
#
# Chez resolution mirrors host/chez/portability-check.sh: JOLT_CHEZ wins (the
# Makefile hands down the interpreter it selected), then a PATH search.
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root" || exit 1

if [ -z "${JOLT_CHEZ:-}" ]; then
  for c in chez chezscheme; do
    if command -v "$c" >/dev/null 2>&1; then
      JOLT_CHEZ="$c"
      break
    fi
  done
  if [ -z "${JOLT_CHEZ:-}" ]; then
    echo "park/lock check: no Chez Scheme executable found on PATH" >&2
    exit 1
  fi
fi

exec "$JOLT_CHEZ" --script host/chez/park-lock-check.ss "$@"
