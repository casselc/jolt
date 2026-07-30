#!/bin/sh
# Project-aware CLI and add-deps installation of :jolt/class-providers metadata.
set -u

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
jolt="${JOLT_BIN:-bin/jolt}"
pass=0
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export JOLT_NO_USER_DEPS=1

check() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  FAIL: $1" >&2
    echo "    expected: $2" >&2
    echo "    got:      $3" >&2
  fi
}

run_expr() {
  project="$1"
  expr="$2"
  JOLT_PWD="$project" JOLT_QUIET=1 "$jolt" -e "$expr" 2>&1 | tail -1
}

dep="$tmp/provider-lib"
app="$tmp/provider-app"
mkdir -p "$dep/src" "$app/src"
cat >"$dep/deps.edn" <<'EOF'
{:jolt/class-providers
 {"provider.install.Widget" provider.install.impl}}
EOF
cat >"$app/deps.edn" <<EOF
{:deps
 {provider.install/lib {:local/root "$dep"}}}
EOF

# The project-aware -e path resolves dependency metadata and installs it before
# evaluating the expression. An identical declaration is therefore idempotent.
check "dependency provider installed before project expression" \
  ":installed" \
  "$(run_expr "$app" \
      '(do (jolt.host/register-class-providers! {"provider.install.Widget" "provider.install.impl"}) :installed)')"

# A conflicting declaration must fail without replacing the installed provider.
# Re-registering the original value inside the catch discriminates rollback:
# it succeeds only when the rejected call left the registry unchanged.
check "conflicting registration is atomic and preserves the installed provider" \
  ":jolt.deps/class-provider-conflict" \
  "$(run_expr "$app" \
      '(try (jolt.host/register-class-providers! {"provider.install.Widget" "provider.install.other"}) :missing-conflict (catch Throwable e (let [t (:type (ex-data e))] (jolt.host/register-class-providers! {"provider.install.Widget" "provider.install.impl"}) t)))')"

check "add-deps installs inline provider metadata" \
  ":installed" \
  "$(run_expr "$app" \
      '(do (require (quote jolt.deps)) (jolt.deps/add-deps {:jolt/class-providers {"provider.add.Inline" "provider.add.inline"}}) (jolt.host/register-class-providers! {"provider.add.Inline" "provider.add.inline"}) :installed)')"

add_dep="$tmp/add-deps-lib"
mkdir -p "$add_dep/src/provideradd"
cat >"$add_dep/deps.edn" <<'EOF'
{:jolt/class-providers
 {"provider.add.Dependency" provider.add.dependency}}
EOF
cat >"$add_dep/src/provideradd/core.clj" <<'EOF'
(ns provideradd.core)
(defn ping [] :pong)
EOF
check "add-deps installs selected dependency provider metadata" \
  ":installed" \
  "$(run_expr "$app" \
      '(do (require (quote jolt.deps)) (jolt.deps/add-deps (quote {:deps {provider.add/lib {:local/root "../add-deps-lib"}}})) (jolt.host/register-class-providers! {"provider.add.Dependency" "provider.add.dependency"}) :installed)')"

atomic_dep="$tmp/atomic-lib"
mkdir -p "$atomic_dep/src/provideratomic"
cat >"$atomic_dep/deps.edn" <<'EOF'
{:jolt/class-providers
 {"provider.add.Atomic" provider.add.dependency}}
EOF
cat >"$atomic_dep/src/provideratomic/core.clj" <<'EOF'
(ns provideratomic.core)
(defn ping [] :pong)
EOF
check "add-deps provider conflict leaves dependency roots unpublished" \
  "[:jolt.deps/class-provider-conflict true]" \
  "$(run_expr "$app" \
      '(do (require (quote jolt.deps)) (let [t (try (jolt.deps/add-deps (quote {:jolt/class-providers {"provider.add.Atomic" provider.add.inline} :deps {provider.add/atomic {:local/root "../atomic-lib"}}})) :missing-conflict (catch Throwable e (:type (ex-data e)))) absent? (try (require (quote provideratomic.core)) false (catch Throwable _ true))] [t absent?]))')"

conflict_dep="$tmp/conflict-lib"
conflict_app="$tmp/conflict-app"
mkdir -p "$conflict_dep/src" "$conflict_app/src"
cat >"$conflict_dep/deps.edn" <<'EOF'
{:jolt/class-providers
 {"provider.install.Conflict" provider.install.dependency}}
EOF
cat >"$conflict_app/deps.edn" <<EOF
{:jolt/class-providers
 {"provider.install.Conflict" provider.install.project}
 :deps
 {provider.install/conflict {:local/root "$conflict_dep"}}}
EOF

# REPL's friendly missing-project fallback must not hide a deterministic
# provider-graph conflict.
conflict_out="$tmp/conflict.out"
if JOLT_PWD="$conflict_app" JOLT_QUIET=1 "$jolt" repl \
    </dev/null >"$conflict_out" 2>&1; then
  check "REPL fails closed on provider graph conflict" "nonzero" "zero"
else
  check "REPL fails closed on provider graph conflict" "nonzero" "nonzero"
fi
if grep -q "conflicting class providers" "$conflict_out"; then
  check "REPL reports the provider graph conflict" "reported" "reported"
else
  check "REPL reports the provider graph conflict" "reported" \
    "$(tail -1 "$conflict_out")"
fi

invalid="$tmp/invalid-project"
mkdir -p "$invalid"
cat >"$invalid/deps.edn" <<'EOF'
{:jolt/class-providers []}
EOF
invalid_out="$tmp/invalid.out"
if JOLT_PWD="$invalid" JOLT_QUIET=1 "$jolt" repl \
    </dev/null >"$invalid_out" 2>&1; then
  check "REPL fails closed on malformed provider metadata" "nonzero" "zero"
else
  check "REPL fails closed on malformed provider metadata" "nonzero" "nonzero"
fi
if grep -q "must be a map" "$invalid_out"; then
  check "REPL reports malformed provider metadata" "reported" "reported"
else
  check "REPL reports malformed provider metadata" "reported" \
    "$(tail -1 "$invalid_out")"
fi

# The pre-existing bare-project behavior remains friendly.
empty="$tmp/empty-project"
mkdir -p "$empty"
if JOLT_PWD="$empty" JOLT_QUIET=1 "$jolt" repl </dev/null >/dev/null 2>&1; then
  check "REPL still tolerates an absent project" "zero" "zero"
else
  check "REPL still tolerates an absent project" "zero" "nonzero"
fi

echo "class-provider install smoke: $pass passed, $fail failed"
test "$fail" -eq 0
