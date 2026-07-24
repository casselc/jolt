# Upstream ecosystem audit — 2026-07-23

This is a versioned, read-only audit record for the Jolt ecosystem. It records
evidence from sibling `jolt-lang` repositories and local proposal-fork work. It
does **not** request edits to those repositories, claim upstream acceptance, or
recommend opening a pull request.

## Baseline and scope

- Jolt evidence baseline: v0.4.15 / `260a392a795089de3fb5ab700b386a334f01c051`.
- Proposal-fork package evidence: packages 2--5 checkpointed at
  `3105198aad6acb8da348d1ef90170673b9cc1ca3`; package-3 host-class follow-up
  at `287f9022`; packages 6--8 are recorded as local prerequisites by jolt-net.
- Ecosystem evidence: time, transit-jolt, xml, yaml, jolt-crypto, logging, and
  router. Socket-centric nrepl and ring-chez-adapter are intentionally left to
  the networking audit.

The audit distinguishes source facts from a portability claim. A green table
test or a successful Linux run is neither a Windows call nor proof that a
hard-coded ABI layout is correct.

## Package 1--8 status

| Package | Status | Meaning |
| --- | --- | --- |
| 1 — closed-world AOT | design/proof | Fresh-process whole-image identity is the production direction; selective runtime cache reuse remains research-only. |
| 2 — concurrent FFI / executors | evidence only | Reproducer work is separate from scheduler and API-fidelity design. |
| 3 — host type identity | local proposal implementation | Class, `instance?`, and protocol dispatch have a reviewed local mechanism; the host-class inventory remains incomplete. |
| 4 — byte copies/ranges | local proposal implementation | Correctness substrate exists; allocation/throughput acceptance remains open. |
| 5 — target descriptor | local proposal implementation | Native consumers need target facts beyond OS and architecture. |
| 6 — monotonic clock | local proposal prerequisite | Required for portable deadline semantics. |
| 7 — narrow FFI integers | local proposal prerequisite | Required for layout-correct native bindings. |
| 8 — errno capture | local proposal prerequisite | Required to preserve native failure information. |

“Local proposal implementation” is not an upstream release claim.

## Cross-ecosystem findings

| Priority | Evidence | Owner |
| --- | --- | --- |
| P0 | YAML embeds ARM64/macOS libyaml struct sizes and offsets, while its native declarations cover only Darwin/Linux. | Jolt FFI layout verification and native dependency capabilities; YAML adopts the result. |
| P0 | YAML discards false/nil mapping values, misses collection anchors, and treats a nil document as end-of-stream. | YAML library semantics. |
| P0 | Crypto returns 32 bytes for HmacSHA1 and accepts short AES-CBC IVs before native execution. | Crypto library validation/output semantics. |
| P0 | XML compatibility parsing can return before closing its native reader/buffer. | XML wrapper; Jolt scoped-resource support removes repeated lifetime boilerplate. |
| P1 | YAML lazy events need early-abandon cleanup and length-aware scalar decoding. | Jolt closeable producers/bytes API, then YAML adoption. |
| P1 | XML/YAML/Crypto native discovery is Darwin/Linux-only; time's system zone is UTC and libc fallback is POSIX-specific. | Jolt target/native/timezone capability. |
| P2 | Transit emulates large integers/chars/tagged values with private records; router/logging expose host-class and stream compatibility seams. | Jolt core/host contract after characterization. |

## Design direction

The portable boundary should be versioned capability maps, not a renamed Jolt
socket stack:

```text
clojure.platform.ffi -> clojure.platform.tcp -> clojure.platform.http
                                      -> clojure.raft / clojure.lsm
```

`ffi` owns ABI, library, lifetime, byte/text, and native-error facts. TCP is a
Teensyp-derived byte-stream contract. HTTP is a Capra-derived message/body
contract. Raft and LSM stay deterministic above effects and receive explicit
clock, transport, byte, store, and cancellation capabilities. Adapters for
Jolt, JVM, fake, and jank must advertise the same versioned semantics and pass
the same behavioural gate; an unavailable capability is reported, never
silently emulated as a false equivalent.

The canonical design record is maintained outside this evidence checkout at
`jolt-net/docs/CLOJURE-PLATFORM.md`. This note remains an audit snapshot, not
an implementation specification for upstream Jolt.

## Required evidence before a portability claim

1. ABI/header probes and runtime calls are reported separately on Linux x86_64,
   macOS arm64, and Windows x86_64.
2. Native resources prove exactly-once cleanup under EOF, error, and abandoned
   lazy consumption.
3. Byte contracts cover embedded NUL, UTF-8 boundaries, partial writes, and
   ownership after failure.
4. Time covers system zone, DST, missing tzdata, locale, and monotonic deadline
   behaviour.
5. The portable TCP/HTTP suite runs against Jolt, JVM, a deterministic fake,
   and jank as independent capability claimants.
