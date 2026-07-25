# Git dependency cache invariants

This note records the bounded ownership and path-length claims behind
`jolt.deps`' private Git cache. It complements the executable adversarial suite
in `test/deps_test.clj`; it does not replace native Git tests.

## Compact coordinate paths on Windows

Git itself rejects an explicit `GIT_DIR` when its string length is at least
`PATH_MAX - 40`. Git for Windows 2.48.1 reports this as:

```text
fatal: '$GIT_DIR' too big
```

`core.longpaths=true` cannot relax that check. Recursive submodule commands
export a `GIT_DIR` below the parent checkout's `.git/modules` tree, so the cache
leaf consumes part of the same finite budget.

The 2026-07-24 native Windows witness used:

| Component | Characters |
| --- | ---: |
| `%TEMP%\jolt-deps-test.XXXXXX\jolt-cache` | 66 |
| old `git-v2/url-<40>/<40>.s` stage | 95 |
| `.git/modules/...` recursive fixture suffix | 65 |
| total | 226 |

The observed rejection boundary is 220. The previous layout therefore failed
before it could validate the clean recursive checkout.

The `git-v3` layout hashes the complete literal `[URL, normalized SHA]`
coordinate into one fixed `dep-<40 hex>` component:

```text
<JOLT_GITLIBS>/git-v3/dep-<40 hex>.s
```

The portion after `JOLT_GITLIBS` is exactly 54 characters for the private
stage. Within the recorded domain:

```text
3 <= cache-root length <= 80
0 <= recursive metadata suffix <= 85
stage layout length = 54
Git rejection boundary = 220
```

the maximum exported path is `80 + 54 + 85 = 219`. The corrected
counterexample query is UNSAT within those bounds. This is not a claim about
arbitrarily deep submodule graphs or cache roots longer than 80 characters.

The executable companion check
`test-windows-git-dir-path-budget!` derives the 54-character overhead from the
production cache function and checks the real recursive fixture path. The
recursive submodule test remains the semantic oracle.

## Collision and ownership boundary

Shortening the path must not broaden deletion authority. The path key hashes an
unambiguous length-prefixed URL plus the normalized requested revision. A
SHA-256 `hash-object` result is truncated to 40 hex digits so the filesystem
budget does not vary with Git's object format.

The adjacent `.jolt-origin` marker independently stores the exact EDN value:

```clojure
{:url <literal-url> :sha <normalized-requested-sha>}
```

Every destructive repair re-reads that complete coordinate after taking the
stable lock. A missing or malformed marker does not grant ownership. A forced
key collision on either a different URL or a different revision produces
`::git-cache-origin-mismatch` and preserves the existing checkout, even if its
Git metadata is corrupt.

This claim is exercised by
`test-forced-coordinate-key-collision-is-nondestructive!`, not inferred from
the cryptographic hash alone.

## Solver records

| Model | Expected and verified result | Meaning |
| --- | --- | --- |
| [`git-cache-path-budget-buggy.smt2`](../test/chez/formal/git-cache-path-budget-buggy.smt2) | SAT, `git_dir_length = 226` | The measured v2 layout crosses the native Windows guard. |
| [`git-cache-path-budget-corrected.smt2`](../test/chez/formal/git-cache-path-budget-corrected.smt2) | UNSAT, 7-label core | No path in the recorded root/suffix domain crosses the guard with the 54-character v3 stage. |
| [`git-cache-path-budget-nonvacuity.smt2`](../test/chez/formal/git-cache-path-budget-nonvacuity.smt2) | SAT, `git_dir_length = 219`, `valid = true` | The inclusive maximum modeled safe path remains reachable. |

Reproduce the semantic oracle with:

```sh
make depstest CHEZ=/home/chuck/.local/chez-10.4.1/bin/chez
```

Run each `.smt2` file through Chiasmus `chiasmus_lint` and
`chiasmus_verify` with `solver=z3`; those tools supply the final solver commands
that are deliberately omitted from the checked-in models. The recorded sequence
is SAT, UNSAT, SAT.

The solver result is only a bounded arithmetic statement. Native Git remains
the authority for environment propagation, submodule behavior, and the exact
platform guard.
