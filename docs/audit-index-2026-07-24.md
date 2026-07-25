# Jolt proposal-fork audit index — 2026-07-24

This is the durable map of the audits, design reviews, bounded proofs, and
consumer validations that informed the `casselc/jolt` proposal fork. It keeps
different kinds of evidence separate:

- an **audit** records source findings and ownership;
- a **design spike** records alternatives and decisions;
- a **proof record** states bounded invariants, assumptions, controls, and
  checked models;
- a **consumer validation** demonstrates composition against a concrete local
  branch and test suite; and
- a draft pull request is a review and landing boundary, not an audit by
  itself.

Nothing here claims acceptance by `jolt-lang`, authorizes a push to the
upstream Jolt origin, or requests an upstream pull request.

## Audit map

| Workstream | Canonical records | Scope and current disposition |
| --- | --- | --- |
| Jolt native-library and Java-interop integration | [`RFD 0001`](rfd/0001/README.md) | Jolt core/stdlib/ecosystem ownership, native-versus-interop exposure, provider and adapter mechanisms, rejected architectures, repository landing order, conformance/proof obligations, and future graduation questions. The RFD is in prediscussion; cross-runtime extraction is motivating context rather than a determination here. |
| Core AOT correctness | [`aot-cache-provenance-invariants.md`](aot-cache-provenance-invariants.md) and the AOT-prefixed [checked models](../test/chez/formal) | Compiler inputs, caller context, cache selection/publication races, bug controls, and the fresh-process closed-world conclusion. The selective-runtime prototype remains research-only. |
| Core runtime/platform behavior | [`executor-shutdown-invariants.md`](executor-shutdown-invariants.md), [`windows-path-invariants.md`](windows-path-invariants.md), [`windows-toolchains-and-validation.md`](windows-toolchains-and-validation.md), and draft [PR #4](https://github.com/casselc/jolt/pull/4) | Executor admission/drain, rejected execution, cache-off source tests, absolute caller paths, Windows host-shim behavior, inherited MinGW packaging history, the future MSVC backend boundary, and source/runtime/package evidence lanes. |
| Core FFI/ABI surface | [`ffi-native-error-capture.md`](ffi-native-error-capture.md), draft [PR #2](https://github.com/casselc/jolt/pull/2), [PR #3](https://github.com/casselc/jolt/pull/3), and [PR #5](https://github.com/casselc/jolt/pull/5), with requirements traced from TCP, HTTP, and Hegel below | Monotonic time, width-correct integers, direct and atomic native-error retrieval, fixed scalar-versus-captured result shapes, compiler-target selection, overlap-safe copy, borrowed ranges, aggregates/struct-by-value, variadic calls, and target descriptors. The record is split by reviewable landing boundary rather than duplicated into a synthetic narrative. |
| Byte/IO layering, protocol dispatch, and completion safety | [`bytes-io-completion-invariants.md`](bytes-io-completion-invariants.md), [RFD 0001](rfd/0001/README.md), and the byte-window/protocol-dispatch/completion [checked models](../test/chez/formal) | Separates core byte mechanisms, an incubating `jolt.bytes/Window`, jolt-net attempts/readiness, and jolt-tcp completion/lease policy. Records idiomatic collection behavior, exact interface-plus-arity dispatch, exact reify protocol membership, provisional cursor status, future-shaped observation without `Future` cancellation, explicit two-phase cancellation, bounded slice-containment and terminal-publication controls, and the proposed Ansatz-to-EDN-to-Hegel proof-derived property lane with its trust boundaries. |
| Network architecture/design | [`JOLT-NET-DESIGN-SPIKE.md`](https://github.com/casselc/jolt-tcp/blob/0c3e085f43b90b346be9843e43448c890f8b701d/docs/JOLT-NET-DESIGN-SPIKE.md), [`UPSTREAM-NOTES.md`](https://github.com/casselc/jolt-net/blob/4e7dc435319c5c65d4248fda31e5bc217945c2ab/docs/UPSTREAM-NOTES.md), [`PLATFORM-COVERAGE.md`](https://github.com/casselc/jolt-net/blob/4e7dc435319c5c65d4248fda31e5bc217945c2ab/docs/PLATFORM-COVERAGE.md), and [`CLOJURE-PLATFORM.md`](https://github.com/casselc/jolt-net/blob/4e7dc435319c5c65d4248fda31e5bc217945c2ab/docs/CLOJURE-PLATFORM.md) | Original TCP/FFI extraction audit, independent Claude worktree reconciliation, accepted decisions, runtime support versus ABI-probe evidence, readiness versus completion, and the generalized capability/SPI follow-on. |
| Socket and TCP lifecycle | [`socket-invariants.md`](https://github.com/casselc/jolt-net/blob/4e7dc435319c5c65d4248fda31e5bc217945c2ab/docs/proofs/socket-invariants.md), [`reactor-lifecycle-invariants.md`](https://github.com/casselc/jolt-tcp/blob/0c3e085f43b90b346be9843e43448c890f8b701d/docs/proofs/reactor-lifecycle-invariants.md), and [`client-connection-invariants.md`](https://github.com/casselc/jolt-tcp/blob/0c3e085f43b90b346be9843e43448c890f8b701d/docs/proofs/client-connection-invariants.md) | Descriptor generations, close/lease ownership, wakeups, connect completion, handler admission, shutdown/drain, EOF visibility, outbound deadlines, and cleanup. |
| HTTP protocol and capacity | [`UPSTREAM-IMPROVEMENTS.md`](https://github.com/casselc/jolt-http/blob/3046a249e95876c53abb522b567e751d4f4a1634/docs/UPSTREAM-IMPROVEMENTS.md), [`http-fail-closed.md`](https://github.com/casselc/jolt-http/blob/3046a249e95876c53abb522b567e751d4f4a1634/docs/proofs/http-fail-closed.md), and [`inline-resume-capacity.md`](https://github.com/casselc/jolt-http/blob/3046a249e95876c53abb522b567e751d4f4a1634/docs/proofs/inline-resume-capacity.md) | Parser/framing boundaries, terminal EOF, response canonicalization, exactly-once sink finalization, causal write failure, and queue capacity. The deterministic Hegel harness follow-up is still awaiting its final commit. |
| Hegel/core/FFI integration | [`UPSTREAM-IMPROVEMENTS.md`](https://github.com/chucklehead-dev/jolt-hegel/blob/e03127174bcaea4ffa1c0cef11bde0efa009e9dc/docs/UPSTREAM-IMPROVEMENTS.md), [`CORE-JOLT-INTEGRATION-SPIKE.md`](https://github.com/chucklehead-dev/jolt-hegel/blob/e03127174bcaea4ffa1c0cef11bde0efa009e9dc/docs/CORE-JOLT-INTEGRATION-SPIKE.md), and [`ARCHITECTURE.md`](https://github.com/chucklehead-dev/jolt-hegel/blob/e03127174bcaea4ffa1c0cef11bde0efa009e9dc/docs/ARCHITECTURE.md) | Struct-by-value FFI, AOT identity, `clojure.test` reporting, static-link rejection, external upstream libhegel acquisition, and versioned native-cache ownership. Hegel remains a separate external library. |
| Non-network sibling ecosystem | [`upstream-ecosystem-audit-2026-07-23.md`](upstream-ecosystem-audit-2026-07-23.md) | Read-only review of time, Transit, XML, YAML, Crypto, logging, and router, split into core-owned substrate and library-owned behavior. This is what the shorter phrase “ecosystem audit” means in older prose. |
| Git dependency acquisition | Draft [PR #6](https://github.com/casselc/jolt/pull/6), [`git-dependency-cache-invariants.md`](git-dependency-cache-invariants.md), `jolt.deps`, and `test/deps_test.clj` | Failed/partial clones, collisions, literal and relative coordinates, linked tools.gitlibs worktrees, replacement refs, sparse/index/submodule states, locking, non-destructive publication, and the recursive Windows `GIT_DIR` path budget. The packaged Windows gate now reaches native Git; the old v2 cache layout crossed Git's 220-character guard. The compact v3 candidate and its forced-collision controls pass 171 Linux checks and still require the native Windows rerun before promotion. |
| Consumer composition/dogfood | Local branches listed below | Tests whether the new layers replace private socket stacks in nREPL, http-client, and Ring. This is implementation evidence, not a claim that those upstream-owned projects accepted the changes. |

The Git publication claim has one explicit filesystem boundary. Compliant Jolt
writers are no-clobber because every transactional version contends on the same
adjacent `.jolt-lock`; the checkout is staged beside the final leaf and renamed
only while that lock is held. The current no-replace `Files/move` implementation
still checks destination absence before calling the platform rename primitive.
On POSIX, an independent non-Jolt creator that appears between those operations
can be replaced by `rename(2)`. The existing regression proves preservation when
the destination is already present, not against that check/rename race. A native
no-clobber directory move (`renameat2(RENAME_NOREPLACE)`, `renamex_np`, and the
Windows equivalent) is a separate host-filesystem slice; it is not silently
assumed by the cache proof.

## Consumer-validation snapshot

These branches are intentionally local and have not been pushed or proposed
upstream:

| Consumer | Local branch/evidence | Result on 2026-07-24 |
| --- | --- | --- |
| nREPL | `codex/platform-tcp-validation` at `145458b` over `dbd8e4a` | Portable client transport through `jolt-tcp`; 30 tests / 75 assertions passed. |
| http-client | dirty `codex/platform-tcp-validation` worktree | Plain TCP and TLS-over-memory-BIO migration is under final review. Host-compatible unbounded and request-wide timeout semantics are still an active gate, so this audit is not complete. |
| ring-chez-adapter | `codex/jolt-http-validation` at `eebfefa` | Delegates to `jolt-http`; seven checks passed against the then-current HTTP proposal SHA. It must be repinned after the final HTTP harness commit. |

## Scope corrections

The network audit was never part of the non-network sibling survey. Its primary
design record is the Jolt TCP design spike; implementation and lifecycle
evidence then moved to `jolt-net`, `jolt-tcp`, and `jolt-http` so each invariant
stays beside the layer that owns it.

Likewise, the add-deps and consumer work should not be described as formal
architecture audits. The former is an adversarial implementation/test review;
the latter is dogfood evidence. This index records both without inflating their
evidentiary status.
