# Application Flow Model and Requested Runtime Seams

**Status:** v1 integration-ready research artifact for the v0.5.17 runtime lane.
Not an implementation, not a proof claim; every element is marked CONFIRMED
(exists today, cited), PROPOSED (new design), REQUESTED (new runtime/library
mechanism), or UNKNOWN (undetermined) — nothing here is `proved`.
**Baseline:** charter target upstream Jolt v0.5.17 (`da59e49d`); simulator facts
from jolt-sim `eb7bce4` (which still pins a private v0.5.12-derived image;
v0.5.17 upstream has **no** controller/lifecycle overlay — P10 (b)). Therefore
every v0.5.17 controller seam below is **REQUESTED**, even where jolt-sim
already contains an adapter expecting an older private hook.
**Authority:** `APPLICATION-CORE-SEMANTIC-CHARTER.md` (accepted, §1–§9 +
Appendix A), esp. §3 lanes/effects, §4 identity, §5 evidence, §7 controls, §8
consumption. Where this document and the charter differ, the charter governs.
**Provenance:** Part 1 drafted by `ecosystem-extension-engineer` (session
`ses_03cdc122dffeCRs1Ju1AUk96HM`); Part 2 by `jolt-sim-engineer` (session
`ses_03cdbd674ffeeOhnUsV1j0GibH`); Part 3 integration and edits by the primary
orchestrator. Read-only research; no code exists for this model.

---

# Part 1 — Whole-system application flow model

For the flow: **HTTP request → application command → SQLite transaction →
domain-state change → outbox/event publication → retry/cancel/crash →
externally observable response.**

## 1. Identity taxonomy

**PROPOSED.** No existing repo implements this taxonomy; it is derived from
the charter's §4 identity spine and §3.3 descriptor schema.

| Identity | Minted by | Scope | Uniqueness rule | Charter relation |
| --- | --- | --- | --- | --- |
| **request-id** | HTTP server on accepted connection | per inbound HTTP request | per-connection monotonic or crypto-random; never reused within a connection lifecycle | rides as trace-schema metadata (§4.4) |
| **operation-id** | application command dispatcher, per invocation | per command instance | per-instance unique (F7); distinct from the per-kind `operation` tag | §4.4/F7 exactly |
| **site-id** | compiler CSIR emission (§4.2) or `host-origin` class (F6) | per perform-site | digest of normalized expanded form + structural components; never line/column | §4.2/F2 |
| **entity-id** | domain layer, per aggregate root | per domain entity | unique within the application's identity namespace; immutable | application-defined; outside charter |
| **transaction-id** | transaction coordinator, per `BEGIN` | per SQLite transaction attempt | unique per attempt; a retried transaction gets a new id (attempt-of-request) | PROPOSED |
| **outbox-row-id** | domain-state writer, atomically with the domain change | per outbox row | unique, monotonic within the outbox table; never reassigned | PROPOSED |
| **attempt-id** | outbox publisher, per delivery try | per delivery attempt of one row | unique per attempt; scoped under the row | PROPOSED |

Scoping graph:

```text
request-id
  └── operation-id (1..1; request-of-operation)
        └── transaction-id (0..1; at-most-one active txn per operation)
              └── outbox-row-id* (0..n; inserted atomically with domain write)
                    └── attempt-id* (1..n per row; attempt-of-row)
```

- **attempt-of-request:** retry of the whole operation (new transaction-id,
  same request-id). **attempt-of-row:** retry of publishing one row (new
  attempt-id, same outbox-row-id).
- `site-id` is orthogonal: *where* in source an operation is performed, not
  which instance. An operation-id carries its site-id per C4.

Grounding: **CONFIRMED** — jolt-http creates one handler invocation per parsed
request (`jolt-http protocol.clj:39-52`; `server.clj:25-30`); no request-id is
minted (PROPOSED). `db.sqlite query` is atomic per prepared-statement lifecycle
(`db/sqlite.clj:246-288`) but does not wrap multi-statement transactions;
no transaction-id (PROPOSED). jolt-sim's SQLite model is plan-ordered, no
outbox concept (`jolt-sim sqlite.clj:284-317`; PROPOSED extension).
`db/sqlite.clj:6-9`: handles are single-owner — no cross-thread overlap.

## 2. Lifecycle state machines

### 2.1 HTTP request

`accepted → parsed → dispatched → responding → responded | errored | rejected`
(`accepted → rejected` on malformed request, `error.clj:10-99`).
**Linearization point:** `dispatched → responding` — the handler's decision;
all prior states are transport-level. CONFIRMED (jolt-http FSM, above).

### 2.2 Command dispatch

`received → validated → authorized → executing → completed | failed | rejected`
**Durability point:** `executing → completed` (only after SQLite commit).
Invariant: **no response before commit**.

### 2.3 SQLite transaction

`begin → active → committing → committed | aborting → aborted` (with retry
`aborted → begin` under a new transaction-id).
**Commit point (linearization):** `committing → committed` — the single
transition making domain-state changes and outbox rows durable and visible.
CONFIRMED at statement level (`db/sqlite.clj:290-324`); multi-statement
transaction discipline is application-side (PROPOSED retry wrapper).

### 2.4 Domain-state transition

`pre-condition → mutating → post-condition` (guard failure → rejected).
**Atomicity point:** domain write and outbox-row insertion in the same
transaction — commit makes both or neither durable.

### 2.5 Outbox row

`pending → publishing → published | failed → retrying → dead-letter`
(poller claims; ack timeout/failure → failed; backoff → retrying with new
attempt-id; retries exhausted → dead-letter).
**Publication point:** `publishing → published` — external ack received.
PROPOSED (no outbox mechanism exists in any repo today).

### 2.6 Delivery attempt

`scheduled → in-flight → succeeded | failed | ambiguous`
**Ambiguity point:** `in-flight → ambiguous` — connection lost after sending,
before response. The caller MUST NOT assume success or failure.

## 3. Invariants

Evidence classes per charter §5; tracks per the two-track discipline
(cooperative-model explicit-state vs ordinary-runtime controlled execution).

| # | Invariant | Stage | Evidence class (eventual) | Track |
| --- | --- | --- | --- | --- |
| S1 | **Outbox-commits-with-domain-state atomicity** — both visible or neither at commit | 2.3/2.4 | `bounded-complete` (finite model of txn commit/abort) | cooperative-model |
| S2 | **No response before commit** — crash after commit but before response requires a retry-safe idempotent path | 2.1/2.3 | `sampled` (injected crash points) | ordinary-runtime |
| S3 | **At-most-once outbox claim** — a row is claimed by at most one poller txn at a time | 2.5 | `bounded-complete` (finite claim model) | cooperative-model |
| S4 | **Monotonic attempt counters** per outbox-row-id | 2.5/2.6 | `sampled` | ordinary-runtime |
| S5 | **Single-owner SQLite handle** — CONFIRMED (`db/sqlite.clj:6-9`) | 2.3 | `monitored` (thread-id crossing assertion) | ordinary-runtime |
| X1 | **No lost outbox rows after committed domain change** — every committed row reaches `published` or `dead-letter` | 2.3→2.5 | `sampled` (fault-injected replay) | cooperative-model |
| X2 | **Idempotency per request-id** — retry after committed original produces the same domain outcome (request-id/entity-version guard) | 2.2→2.4 | `sampled` | ordinary-runtime |
| X3 | **Outbox row identity stability** — id never reassigned; only status transitions | 2.4→2.5 | `monitored` | ordinary-runtime |
| L1 | **Eventual publication or dead-letter** — bounded-liveness only, within declared timeout/retry budget (never unbounded liveness, §5.3 rule 2) | — | `sampled` | ordinary-runtime |
| L2 | **No unbounded retry loops** — backoff + max-retry ensure termination | — | `bounded-complete` (finite retry-counter model) | cooperative-model |

## 4. Ambiguity semantics

**The ambiguity surfacing rule (PROPOSED):** an outcome whose
commit/acknowledgment state is unknown to the local node MUST be classified
**ambiguous** — never assumed failed or succeeded.

| Stage | Ambiguous trigger | Caller MUST conclude | MUST NOT conclude |
| --- | --- | --- | --- |
| SQLite txn | crash after `COMMIT` issued, before confirmation | outcome ambiguous until resolved by entity/request-id query | neither committed nor aborted |
| Outbox publish | connection drops after payload sent, before ack | delivery ambiguous | neither delivered nor lost |
| Delivery attempt | 5xx with no idempotency key in response | ack ambiguous | neither received nor rejected |

**Crash recovery map:** before `BEGIN` — no effects, safe retry. After
`BEGIN`, before `COMMIT` — definitive rollback on recovery. After `COMMIT`
issued, before confirmed — **ambiguous**, resolve via idempotency query.
After `COMMIT` confirmed, before response — durable; response retry is safe
(idempotent handler). After response — complete.

Grounding: **CONFIRMED** — jolt-sim has a deterministic fault-plan director
(`fault.clj:270-356`: matching/activation/firing ordinals, data-driven) and the
SQLite model can inject per-plan errors on `sqlite3_step`
(`sqlite.clj:529-536`); the kernel's terminal classes are
`:completed/:failed/:deadlock/:step-limit` (`kernel.clj:310-341`) — no
"ambiguous" class exists (PROPOSED: ambiguity classification lives at the
application model layer, not the kernel).

---

# Part 2 — Requested runtime-seams register

**Runtime-lane item key:** 1 arraycopy; 2 executor admission; 3 exact-width
FFI; 4 atomic native-error capture; 5 ranged transfers; 6 scoped loans;
7 simulation image; 8 future lifecycle hooks; 9 unified simulator controller
on v0.5.17 + `jolt.host/mono-nanos`; 10 Linux CI + x64 Windows validation.

## 5. Adapter-point taxonomy

All controlled operations begin with a validated descriptor `{family,
operation, canonical-args, operation-id, resource-id, site-id, assumptions}`.
Domain identities (request/transaction/message/delivery/attempt) ride in
`resource-id` or the family's `canonical-args` — never in host object/thread
identity (non-goal 14).

| Operation | Seam must provide | Allowed outcome | Evidence emitted | Identity |
| --- | --- | --- | --- | --- |
| **observe** | descriptor before the boundary + paired post-terminal event; no admission/result alteration | exact original result/exception | `performed`, route/supplier, terminal observation; explicit loss mapping | same `operation-id` request/result; causal links |
| **delay** | descriptor before irreversible work + ownership-safe pending gate + deadline/cancel registration + release; adapter drainable while blocked | later release, modeled result, typed failure, cancellation, or timeout per family algebra | separate deterministic delay/release choice + blocked/start/result events; enabled set; virtual time | pending `operation-id`; owner; deadline ID |
| **fail** | descriptor before mutation + closed family-validated failure algebra | substitute declared error without invoking; abort run on malformed policy | fault activation, selected failure, no-pass-through confirmation, application observation | invocation `operation-id`; firing ordinal is policy evidence |
| **duplicate** | a logical message/delivery adapter before attempt creation (never blind FFI repetition) | ≥1 attempts with same message/delivery identity, each with own lifecycle | duplicate-count choice + per-attempt admit/start/result/ack | same message resource; distinct attempt/operation IDs |
| **reorder** | multiple admitted-not-started operations held safely; controller receives complete enabled set, releases one | each starts at most once in chosen order or reaches declared cancel/fail | deterministic enabled-set/choice records separate from racing observations | distinct IDs + common causal links |
| **pass-through** | validated descriptor + exact target mapping + scoped owner-thread single-use continuation; provenance checked before crossing | exact real result or native exception, application catch semantics preserved | route choice, supplying primitive/symbol, live result/error, provenance decision; live pointers stay live evidence | descriptor IDs, target tuple, supplier — never pointers/PIDs/thread-ids |

**Tier support (H3):** tier (a) modeled supports all six (per registered
model; duplicate only at a logical attempt adapter; pass-through only with an
explicit real target mapping). Tier (b) pass-through-only: observe and
pass-through only. Tier (c) opaque: at most an escape/widening record; any
host reach is an opaque escape, not semantic pass-through. Hermetic worlds
reject (b)/(c) at install and fail closed on unregistered/malformed/unhandled
families (§3.3).

## 6. Cross-cutting controller contract (S0)

**REQUESTED:** disabled-by-default sim-image API: single-parent family
registration, tier declaration + model validation, dynamically scoped
strict-LIFO handler installation, exact-token restoration, descriptor
validation, substitution-or-abort dispatch, explicit hermetic/observe/hybrid
routing. Handler resolution: nearest dynamic scope, then most-specific
family; equal specificity fails installation. **No continuation** beyond the
invocation-scoped native `proceed`.

**EXISTS (at eb7bce4):** jolt-sim expects exact ABI 5, six future events, FFI
descriptor v4, scoped proceed (`runtime.clj:50-73`); hermetic misses fail
before OS access (`runtime.clj:942-990`); hybrid proceed is
provenance-guarded (`runtime.clj:1006-1117`). Current FFI descriptors lack
charter operation/resource/site IDs (`runtime.clj:432-437,484-522`).
**Gap:** v0.5.17 supplies none of this; plausible items 7+9 (8 supplies task
lifecycle; 3–6 supply valid native descriptors/results).
**Non-goals:** no production jolt-sim dependency, no universal untyped
`perform`, no continuations, no implicit global composition, no prerelease
compat branches, no prohibition of deliberate real-OS calls.

## 7. Seam register (S1–S9)

| ID | Guarantee served + requested seam | EXISTS vs gap | Lane items |
| --- | --- | --- | --- |
| **S1 request lifecycle** | Family `:jolt.application/request` (derives `:jolt.effect/io`, tier (a) when modeled): `:accepted :handler-admit :handler-start :response-commit :handler-finish :handler-fail :cancel-request :cleanup`; `resource-id=request-id`; `:handler-admit` = delay/fail point; `:response-commit` = first irreversible response point | EXISTS only for futures (`:spawn/:start/:finish/:cancel/:exit/:abort`, `runtime.clj:230-302,372-382`); HTTP fixture runs unchanged code without request lifecycle (`README.md:728-757`) | 8+9; 2 if handlers on executors |
| **S2 transaction commit/abort** | Family `:jolt.application/transaction`: `:begin :commit-attempt :commit-result :abort-attempt :abort-result :close`; result algebra `:committed/:aborted/:failed/:ambiguous` — a crash or lost native result is never relabeled committed | SQLite is a FIFO statement-plan model (`sqlite.clj:284-317`), intentionally omits locking/durability (`README.md:722-724`); FFI routing cannot infer transaction semantics | 3–6+9; the transaction adapter/model is NEW library/jolt-sim work |
| **S3 outbox atomicity** | Family `:jolt.application/outbox`: `:stage` inside a named transaction, `:visible` only after committed result, `:claim`, `:retire`; payload digest in args | SQLite validates exact SQL/params and cleanup (`sqlite.clj:284-317,711-747`) but has no transaction membership/rollback/durability/visibility state | 9 with S2; 3–6 |
| **S4 delivery scheduling** | Family `:jolt.application/delivery` (derives `:jolt.effect/net`): `:enqueue :attempt-admit :attempt-start :attempt-result :ack :retry-scheduled :retire`; controller releases one enabled attempt, injects closed transport failure, duplicates via the ordinary path, or passes through | Fault plans exist (`fault.clj:270-356`); only frontend injects captured `EINTR` at modeled `poll` (`net/posix_fault.clj:1-20`); future scheduling is serial top-level admission (`future_schedule.clj:1-52`); Maelstrom history treats duplicates as violation, not injectable behavior (`maelstrom/history.clj:92-104`) | 2+8+9; 3–6 |
| **S5 cancellation/timeout** | Operations under `:jolt.effect/task` + `:jolt.effect/clock`: `:cancel-request :cancel-win :cancel-lost :deadline-register :timeout-fire :settle :worker-exit`; controller chooses winner at declared race points; settlement distinct from worker-exit | Lifecycle distinguishes settlement vs exit (`runtime.clj:263-299`); completion registry enforces first terminal publication (`completion.clj:244-280`); ordinary-future scheduler rejects cancellation (`future_schedule.clj:275-276`); raw executor tasks unowned (`runtime.clj:1379-1382`) | 8+9, 2 for executors |
| **S6 crash injection** | `:jolt.effect/process/:checkpoint` descriptors at named semantic boundaries + supervisor `crash-at(checkpoint-id, mode)`; child handshakes checkpoint, blocks, parent records deterministic crash choice, signals, reaps | Process exploration enforces deadlines, TERM→KILL escalation, observed reaping (`process_explorer.clj:162-189,207-252`); timeouts are deadline failures only (`:331-337`); no semantic-checkpoint crash injection | 7+9+10; checkpoint protocol is additional work |
| **S7 monotonic clock** | `:jolt.effect/clock`: `:read-monotonic :park-until :deadline-register :deadline-cancel :advance`; real reads map exactly to `jolt.host/mono-nanos`; virtual time advances only by explicit scheduler choice with deterministic equal-deadline ordering | Cooperative machines have forced earliest advance (`kernel.clj:545-560`) and distinct choice/time events (`trace.clj:470-490`); ordinary POSIX sim still uses real `System/nanoTime` (`net/posix_loopback.clj:656-704`); controller drainage uses real time (`runtime.clj:1145-1160`) | 9; 2/8 for timed-wait owners |
| **S8 wall clock** | `:read-wall` + explicit modeled `:wall-step`; real mapping `jolt.host/wall-nanos`; wall time dates observations, never controls durations/retries/deadlines/scheduling | v0.5.17 exposes both primitives (`rt.ss:441-458`); jolt-sim has no wall-clock descriptor | 9 |
| **S9 unified causal trace** | Closed versioned event envelope: lanes `:choice/:modeled-transition/:observed-lifecycle/:native-live/:cleanup`; logical ordinal; descriptor IDs; causal parent; canonical payload; coverage class `:required/:audit-only/:best-effort`; end-of-run controlledness summary (covered/rejected/escaped families, unmanaged tasks, restoration, poison, leaks, quiescence) | Cooperative trace validation closed/fail-closed (`trace.clj:591-693`); replay compares canonical traces (`kernel.clj:667-698`); monitors fold validated docs (`monitor.clj:100-146`); runtime lifecycle + FFI logs remain separate caller-correlated logs (`README.md:565-568`); FFI args are live mutable evidence (`runtime.clj:1398-1404`); cleanup poisoning/restoration explicit (`runtime.clj:1268-1292,1533-1544`) | 7–10; 3–6 |

## 8. Evidence and replay rules

1. Every seam event is only an input to an evidence producer: monitor claims
   use §5.4 `{trace digest, coverage declaration}`; explicit-state claims use
   `{sim-config digest, transition-relation digest, bounds, witness-path?}`.
2. **UNKNOWN (requires charter/schema amendment):** no producer-typed
   coordinate exists for **ordinary-runtime controlled replay**. Before such
   replay is accepted, a schema amendment must define at least
   `{scenario/config digest, deterministic-choice document digest, canonical
   trace digest, target tuple, process-case/checkpoint data?}`. Until then,
   only the monitor coordinate supports a `monitored` claim. (Recorded as
   open request R1 in Part 3.)
3. Deterministic choices (admission, fault, duplicate count, reorder,
   timeout winner, time advance, crash point) persist separately from the
   observations they caused; racing observed arrival order is never promoted
   into replay-stable choice data.
4. Native descriptors, pointers, buffers, errno snapshots, PIDs, host thread
   IDs are **live evidence**; canonical replay/history stores only validated
   projections, digests, logical resource IDs, and target/supplier metadata.
5. Missing/malformed/unknown/sampled-away/ambiguously mapped **required**
   observations make the monitor `inconclusive`/`failed` per declared policy.
   Simulation evidence carries the `simulated` tag and never establishes
   host behavior (§5.3 rule 10).

## 9. Seam-specific non-goals

- **S1:** no production handler-API changes; raw threads/unhooked executors
  are outside the request lifecycle.
- **S2:** no SQL parser or replacement engine; no assertion of a real
  engine's internal commit linearization beyond available return/durability
  evidence.
- **S3:** no inference of business/outbox meaning from arbitrary SQL; outbox
  atomicity ≠ broker publication or exactly-once delivery.
- **S4:** no blind duplication of arbitrary native calls, no byte-stream
  reordering, no runtime-owned schedule search, no exactly-once claim.
- **S5:** no forced worker kill, no continuation capture, no
  timeout→deadlock inference, no wall time for deadlines.
- **S6:** exceptions are not crashes; poisoned controllers, hangs, native
  crashes, and signal behavior are never tested in-process; descendant
  cleanup only when explicitly owned and reaped.
- **S7/S8:** monotonic and wall clocks are never interchangeable; host
  timestamps are observations, never identity.
- **S9:** no merging of choices with observations, live native evidence with
  canonical history, or lossy telemetry with required-coverage evidence.
- **All seams:** adapters control existing boundaries and handler packs;
  they never reimplement production libraries or prohibit deliberate real-OS
  calls.

## 10. Required verification gates

- Deterministic repetition: identical config/choice documents produce
  byte-identical canonical choice evidence and equivalent terminal
  projections.
- Malformed/unknown family, descriptor, event, outcome, tier, replay, or
  coverage documents fail closed before controlled work or OS access.
- Exact replay validates enabled sets, choices, modeled projections,
  terminal outcomes, and observation mapping; drift fails rather than
  falling back.
- Every gate checks controller restoration/poisoning, worker ownership,
  callback drainage, transaction/attempt retirement, waiter removal,
  native-memory leaks, sockets/pipes, and process reaping.
- Every modeled seam with a real implementation has a scoped real/sim parity
  fixture; parity is result/protocol evidence, never proof the model is the
  host.
- Hangs, permanent controller installation, restoration failure, native
  crashes, and signal behavior run only through process-isolated gates with
  bounded TERM/KILL and observed reaping.

---

# Part 3 — Integration (primary orchestrator)

## 11. Invariants × seams cross-map

| Invariant (Part 1) | Serving seams (Part 2) | First executable evidence step |
| --- | --- | --- |
| S1 outbox/domain atomicity | S2, S3 | cooperative-model fixture: modeled txn commit/abort over declared table schemas |
| S2 no-response-before-commit | S1, S2, S6 | Hegel-sampled sequences with injected crash points at named checkpoints |
| S3 at-most-once claim | S3, S4 | cooperative-model: concurrent claim attempts, bounded |
| S4 monotonic attempts | S4, S9 | monitor fold over delivery trace |
| S5 single-owner handle (CONFIRMED) | S1, S9 | runtime assertion + monitor (thread-id crossing) |
| X1 no lost outbox rows | S3, S4, S6, S9 | fault-injected replay with the fault director |
| X2 idempotency per request-id | S1, S2 | Hegel stateful model with request-id guard |
| X3 row identity stability | S3, S9 | schema constraint + monitor over write patterns |
| L1/L2 bounded liveness | S4, S5, S7 | finite retry-counter explorer model (bounded-complete candidate) |

## 12. Witness → evidence path (per charter §8.5)

Every Part-1 invariant starts as a **model declaration** (Jolt data):
literal examples (`sampled`) → Hegel stateful rules (`sampled`) → finite
explorer input where the relation is finite (`bounded-complete` iff finished
uncapped) → offline monitor folds (`monitored`, per coverage) → permanent
replay records (§5.4 producer-typed coordinates). Buggy controls follow the
§7 pattern: a deliberately faulty variant per invariant (e.g., outbox staged
outside the transaction for S1; claim-without-lock for S3) with an expected
shortest witness, plus a corrected control that must terminate clean.
**Ambiguity (§4) is a first-class model outcome**, not a kernel terminal
class: the application model labels outcomes `:committed/:aborted/ambiguous`;
never relabel ambiguous as either.

## 13. Deterministic scenario inputs

Scenario documents for the controlled-execution track carry
`{workload, faults, cluster, timing, schedule}` per the landed jolt-sim
scenario-input protocol v2, extended with the Part-2 choice kinds (duplicate
count, reorder choice, timeout winner, crash checkpoint, time advance).
Fault policy stays transport-neutral in the fault director; message-delivery
and byte-stream models consume the same policy rather than one model
pretending both abstractions (Flow-plan rule).

## 14. Open requests to the v0.5.17 runtime lane

- **R1 (schema amendment needed):** producer-typed replay coordinates for
  **ordinary-runtime controlled replay** (Part 2 §8.2). Until defined, only
  monitor coordinates support `monitored` claims on that track.
- **R2:** transaction-aware SQLite/DB model (S2/S3): transaction membership,
  commit/rollback visibility, durability states, outbox visibility —
  explicitly beyond any single runtime-lane item; new library/jolt-sim work.
- **R3:** request-lifecycle family (S1) as an HTTP/application adapter with
  causal mapping, built on the item-8 future lifecycle events.
- **R4:** ordinary-future cancellation and raw-executor-task ownership
  (S5 gaps) — currently rejected/unowned in jolt-sim; needed before any
  cancellation-race claim.
- **R5:** checkpoint crash-injection protocol (S6) with supervisor-side
  deterministic choice + process isolation.
- **R6:** unified controller on v0.5.17 (item 9) carrying charter descriptor
  fields (operation-id/resource-id/site-id) — current ABI-5-era descriptors
  lack them (Part 2 S0 EXISTS row).

## 15. Nonclaims (document-wide)

- No claim that any invariant holds in any existing implementation — all are
  PROPOSED targets with named evidence classes, not results.
- No claim that the requested seams exist or are scheduled; items map to
  Codex's published runtime-lane list only where marked.
- Nothing here is `proved`; eventual levels are ceilings per §5, not
  commitments.
- Ambiguity semantics are model-layer semantics; they assert nothing about a
  specific SQLite/jolt-http/db implementation today.
