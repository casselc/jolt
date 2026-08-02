#!/bin/sh
# Prove that the fresh compile phase keeps the explicitly selected Chez even
# when PATH advertises a different executable first.
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

selected="${CHEZ:-${JOLT_CHEZ:-}}"
[ -n "$selected" ] || {
  echo "selected-chez: no selected Chez executable" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/path" "$work/selected path with ' quote"

cat >"$work/path/chez" <<'EOF'
#!/bin/sh
: >"$JOLT_SELECTED_CHEZ_POISON_MARKER"
exit 97
EOF
chmod +x "$work/path/chez"

real_selected="$selected"
selected="$work/selected path with ' quote/selected-chez"
cat >"$selected" <<'EOF'
#!/bin/sh
exec "$JOLT_SELECTED_CHEZ_REAL" "$@"
EOF
chmod +x "$selected"

marker="$work/path-compiler-was-used"
out="$work/jolt"
PATH="$work/path:$PATH" \
JOLT_CHEZ="$selected" \
JOLT_SELECTED_CHEZ_REAL="$real_selected" \
JOLT_SELECTED_CHEZ_POISON_MARKER="$marker" \
  "$selected" --script host/chez/build-jolt.ss debug "$out" >/dev/null

[ ! -e "$marker" ] || {
  echo "selected-chez: fresh compile rediscovered Chez from PATH" >&2
  exit 1
}

got="$($out -e '(+ 40 2)')"
[ "$got" = "42" ] || {
  echo "selected-chez: rebuilt binary returned '$got', expected 42" >&2
  exit 1
}

echo "selected-chez: 2/2 passed"
