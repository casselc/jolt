:rfd: 0001
:authors: casselc; Jolt proposal contributors
:state: prediscussion
:discussion:
:labels: software, design, runtime, network, compatibility

# RFD 0001: Jolt native-library and Java-interop integration

## Synopsis

Integrate the proposal fork's host, FFI, networking, and Java-interop work into
one explicit Jolt architecture:

```text
          Jolt host/runtime primitives
             /                 \
        jolt.ffi          incubating jolt.bytes
             \                 /
                  jolt-net
                      |
                  jolt-tcp
                      |
                  jolt-http
```

`jolt-hegel` remains a separate library that consumes the reviewed FFI surface.
An optional Java compatibility facade maps the bounded NIO, concurrency,
buffer, stream, file, and time surface required by pinned Teensyp and Capra
sources onto these same Jolt facilities.

The existing hardened jolt-tcp and jolt-http ports remain the production
implementations and behavioral oracles while exact-source compatibility is
developed. Java compatibility is an additional route into the Jolt ecosystem,
not a replacement architecture and not a commitment to emulate the JVM.

The broader idea that this code may later become a cross-runtime
`clojure.platform` capability boundary motivated several separations in this
proposal. That extraction is inspiring context and a possible follow-on RFD; it
is not determined here.

## Motivation

### Jolt currently pays for native integration repeatedly

Jolt's Maven HTTP client, nREPL server, original TCP port, and Hegel adapter
each needed overlapping pieces of native integration:

- target and ABI selection;
- native library and symbol loading;
- integer widths and aggregate layouts;
- immediate native error capture;
- byte-array/native-memory transfer;
- monotonic deadlines;
- socket ownership and endpoint resolution; and
- platform-specific process and artifact acquisition.

Duplicating those pieces is dangerous. A wrong struct offset, stale error code,
pointer-width truncation, descriptor-reuse race, or cleanup ordering bug can
produce memory corruption or close an unrelated resource. The proposal should
make each primitive live at one owning layer and make consumers delete their
private copies.

### The library layering needs to remain unambiguous

`jolt-net` is the native socket substrate. It is not intended to replace
jolt-tcp.

- jolt-tcp uses jolt-net and, only when the substrate is genuinely missing a
  primitive, jolt.ffi;
- jolt-http uses jolt-tcp and should have little or no direct knowledge of
  jolt-net or FFI; and
- application libraries such as nREPL, Ring adapters, and Maven/HTTP tooling
  validate those layers as consumers.

This boundary lets socket ABI and lifecycle fixes land once while TCP
scheduling, backpressure, stream behavior, and HTTP framing remain in their
appropriate libraries.

### Jolt can reuse more existing Clojure source

Teensyp and Capra are already Clojure implementations, but their production
source refers to selected Java APIs: `ByteBuffer`, NIO channels and selectors,
queues and locks, executors, streams and files, charsets, and time formatters.
Jolt already has extensible host-class registration and many of those
behaviors.

A bounded compatibility facade could run the pinned sources with fewer forks
and unlock similar libraries. The right target is the exact class/member and
semantic surface the source uses, not the entire Java standard library.

### Existing port hardening must not be lost

The current ports contain behavior that is stronger than their upstream
starting points:

- jolt-tcp separates callback execution, preserves normal half-close, and
  maintains generation-aware readiness and close ownership;
- jolt-http rejects ambiguous request framing, validates chunk and response
  metadata, treats EOF as terminal in every parser state, and settles
  producers under failure; and
- jolt-hegel uses width-correct direct FFI and keeps the native upstream
  libhegel artifact outside Jolt core.

Source compatibility is valuable only if it passes those same lifecycle,
framing, capacity, and failure gates or the upstream source is corrected.

### Cross-runtime portability is the originating principle, not this RFD's scope

The work began from a larger observation: once byte, clock, I/O, storage, and
completion effects are represented narrowly, ordinary Clojure can implement
far more than TCP and HTTP—encoders, decoders, communication protocols,
in-memory structures, disk-backed indexes, storage engines, and distributed
algorithms.

That observation influences this Jolt design:

- native details stay below ordinary Clojure state machines;
- readiness is not leaked where a completion contract is more general;
- capability claims are versioned and fail closed; and
- fake/deterministic adapters are treated as first-class test tools.

This RFD does not name or freeze a multi-runtime public API. A later RFD can
extract one after the Jolt, JVM, and fake implementations reveal the smallest
honest contract.

## Goals

- Consolidate Jolt's reusable host and FFI primitives in core.
- Complete jolt-net as a cross-platform socket substrate, including real
  Windows runtime coverage.
- Reimplement jolt-tcp over jolt-net without losing its hardened semantics.
- Keep jolt-http layered over jolt-tcp and free of production FFI.
- Keep jolt-hegel separate while eliminating its private ABI workarounds.
- Add an explicit, lazy class-provider mechanism independent of namespace load
  order.
- Implement only the Java buffer, concurrency, NIO, stream, file, time, and
  exception behavior required by audited source.
- Run pinned Teensyp and Capra sources as a compatibility experiment and compare
  them against the hardened ports.
- Validate the integration through real consumers such as nREPL, Maven
  dependency resolution, Ring adapters, and representative ecosystem
  libraries.
- Preserve bounded proof records and real platform evidence alongside code.

## Non-goals

- Emulating Java bytecode, a JVM classloader, or the complete Java class
  library.
- Replacing jolt-tcp with jolt-net or letting jolt-http grow a second transport
  stack.
- Moving jolt-hegel or libhegel into core.
- Automatically downloading libhegel as an implicit core action; users or the
  jolt-hegel installer fetch the upstream artifact explicitly.
- Adopting untouched Teensyp or Capra defects as Jolt behavior.
- Claiming Windows socket support from ABI tables or namespace loading without
  real Winsock calls.
- Standardizing IOCP, `io_uring`, libdispatch, or a cross-runtime
  `clojure.platform` API in this RFD.
- Reopening the rejected selective-runtime AOT prototype. Production AOT
  correctness remains a closed-world build problem.

## Current evidence

### Core proposal

The proposal branch already contains or has validated:

- a fail-closed target descriptor;
- a real monotonic clock;
- direct POSIX `errno` and Winsock `WSAGetLastError` retrieval, plus the public
  `{:capture-native-error true}` FFI option that returns the native result and
  its matching error from one foreign-call transition;
- signed and unsigned 8- and 16-bit foreign scalars;
- overlap-safe array copy and scoped borrowed byte-array slices;
- by-value aggregate/struct support;
- variadic foreign-call boundaries;
- host-class/protocol identity corrections;
- Windows absolute-path and native environment handling; and
- transactional Git dependency acquisition.

The remaining Windows process layer is still POSIX-shaped. Genuine argv-safe
`ProcessBuilder` behavior requires a Win32 `CreateProcessW` backend with
retained process handles; it is separate from `jolt.host/sh`, whose contract is
explicitly a shell program.

Atomic error capture selects Chez's `__get_last_error` or `__errno` convention
from the compiler's `$target-machine`, not the build host's `(machine-type)`.
Deterministic `ta6nt` and `ta6le` expansion controls cover both cross-target
selection directions, Linux exercises the captured-pair ordering, and a native
Windows jolt-net gate observes exact Winsock `10061` and first-attempt `10048`
in one process. The latter was an ordinary `bind`, establishing that every
failure sentinel whose error is consumed needs the pair, not only collect-safe
calls. A full xpatch Windows cross-build remains a distinct validation lane.
The contract, bounded ordering argument, and cross-target evidence are recorded
in
[`ffi-native-error-capture.md`](../../ffi-native-error-capture.md).

Consumers must preserve that distinction in their own call surface. Ordinary
calls return scalars; captured calls return `[result native-error]`. An
operation-keyed wrapper that sometimes returns one shape and sometimes the
other is rejected because callers can silently forget the atomic contract.
Direct-return APIs such as `WSAStartup` remain scalar. A blocking API such as
POSIX `getaddrinfo`, whose `EAI_SYSTEM` result delegates detail to `errno`, must
use the pair and consult the captured code only for the delegated case.

### jolt-net

On verified POSIX targets, jolt-net provides endpoints, DNS, owned sockets,
numeric endpoint inspection, nonblocking byte I/O, connect initiation and
`SO_ERROR` completion, generation/revision-bearing readiness, wakeup, and
bounded close behavior.

Windows x86-64 constants, layouts, handle width, and signatures are probed. The
native implementation is sequenced as:

1. linearizable Winsock initialization and blocking sockets;
2. `ioctlsocket`, nonblocking byte I/O, and connect completion;
3. `WSAPoll`;
4. owner-independent wake and close lifecycle; and
5. native runtime CI promotion.

Each capability remains unadvertised until the corresponding real calls pass.
Windows W1 is accepted locally at jolt-net revision `11142a3`: the native
x86-64 suite passed 149/149 with no skips, the Linux dependency-free suite
passed 146 checks with only its not-applicable Winsock skip, and the complete
Hegel-required Linux suite passed 222/222 with no skips. Its forced-contention
test performs exactly one `WSAStartup`, failure paths terminalize one shared
outcome, and bounded watchdogs surround the process. Scalar dispatch owns only
error-independent close; every sentinel-returning operation whose error is
consumed uses the captured-pair surface. W2 may now implement Windows
nonblocking transitions and byte I/O without reopening W1.

### jolt-tcp and jolt-http

jolt-tcp is already the first meaningful consumer of jolt-net. Its outbound
path owns one monotonic deadline across address candidates, exact failed-socket
cleanup, partial-progress-safe I/O, FIFO operation gates, EOF caching,
half-close, and idempotent close.

jolt-http depends on jolt-tcp only in production. Its parser, framing,
serialization, body streaming, and producer-finalization tests are the oracle
for any Capra compatibility route.

### Java interop audit

Jolt already supports:

- constructor/static registration;
- tagged instance methods and pluggable `instance?`;
- honest host-class protocol tags;
- typed exceptions;
- strings and much of `ByteBuffer`;
- atomics, threads, fixed executors, and basic I/O classes; and
- all currently identified low-level FFI needed by Teensyp and Capra.

Important missing or incorrect semantics include:

- lazy provider loading and bounded retry;
- strict `ByteBuffer` state/bounds, signed-byte fidelity, and `compact`;
- `ArrayBlockingQueue`, concurrent key sets, conditions, and park/unpark;
- honest virtual-thread/executor behavior and `TimeUnit` conversion;
- NIO channels, selectors, keys, and socket options;
- file-channel reads, writer adapters, and streaming `clojure.java.io/copy`;
- selected charset/time constants and exact RFC-1123 `GMT` formatting; and
- sticky Java `Selector.wakeup` semantics above jolt-net's current wake
  contract.

## Determination

### Keep one Jolt-native dependency direction

```text
host/chez and Jolt core
  targets, clocks, arrays/copy/borrow, process, Java host shims
           /                                  \
        jolt.ffi                    incubating jolt.bytes
  calls, ABI, native memory       Window and provisional Cursor
           \                                  /
                         jolt-net
       addresses, owned sockets, native errors, byte I/O, readiness
                              |
                          jolt-tcp
       scheduling, backpressure, completion, streams, lifecycle
                              |
                          jolt-http
       HTTP parsing, framing, messages, bodies, Ring-shaped integration
```

Raw pointers, descriptors, native layouts, and error slots do not cross above
jolt-net. A missing primitive is added at its owning lower layer rather than
worked around independently in each consumer.

Hegel is adjacent:

```text
jolt.ffi <--- jolt-hegel ---> upstream libhegel artifact
```

It stays separately versioned and distributed.

### Add a bounded Java compatibility path beside the native APIs

```text
jolt-net + jolt-tcp behavior
             |
     optional jolt.compat.nio
             |
 selected Java/NIO/stream class registrations
             |
      pinned Teensyp source
             |
       pinned Capra source
```

This facade is allowed to reuse the native substrate and TCP state machines. It
does not become the implementation API for jolt-net, and it does not replace
the direct Jolt ports until differential evidence says it can.

### Providers are declarative, lazy, and bounded

Projects may declare which namespace provides a Java class:

```clojure
{:jolt/class-providers
 {"java.nio.channels.Selector"         jolt.compat.nio
  "java.nio.channels.SocketChannel"    jolt.compat.nio
  "teensyp.ProxyInputStream"           jolt.compat.teensyp
  "java.time.format.DateTimeFormatter" jolt.time}}
```

Constructor/static lookup may require exactly that provider and retry once.
Missing instance members on a known class receive the same bounded provider
retry where extension namespaces need it.

The registry must:

- accept repeated identical declarations;
- reject conflicting declarations;
- detect cycles and re-entrant loading;
- preserve honest class tags and protocol dispatch;
- report class, member, provider, and load state in structured failures; and
- behave the same in source mode and built applications.

It is not an arbitrary namespace search.

### Place mechanisms in core, common facilities in stdlib, and policy in libraries

The repository boundary follows three rules:

1. **Core owns mechanisms required to load or implement everything else.**
   Representations, compiler/runtime hooks, host calls, FFI ABI rules, class
   registration, provider resolution, and process lifecycle cannot depend on an
   optional library.
2. **Stdlib owns dependency-free, broadly shared Jolt facilities with a stable
   contract.** A facility belongs here when multiple core/ecosystem consumers
   would otherwise duplicate it and it needs no separately released artifact.
3. **Ecosystem libraries own policy, large compatibility surfaces, and
   independently versioned artifacts.** TCP scheduling, HTTP parsing, property
   generation, and optional Java NIO compatibility should not enlarge the
   language bootstrap or inherit Jolt's release cadence.

The selected placement and exposure are:

| Capability | Canonical implementation | Native Jolt exposure | Java-interop exposure | Destination |
| --- | --- | --- | --- | --- |
| Target, ABI, monotonic clock, and host errors | `host/chez` with `jolt-core` wrappers | `jolt.host/*` and narrow public helpers | `System/nanoTime` and host-class shims where already idiomatic | Core; **both** facades over one implementation |
| Byte arrays, indexed access, signed-byte fidelity, overlap-safe copy, and scoped FFI borrow | Existing core array/runtime support | Byte arrays and narrow bulk-copy/borrow primitives | Array and `ByteBuffer` adapters over the same storage rules | Core; **both** facades over one implementation |
| Validated byte views and traversal | Incubating dependency-free `jolt.bytes` | Stable immutable `Window`; provisional strict `Cursor` | A `ByteBuffer` adapter may use the same storage, but is not the native abstraction | Incubate outside networking, then consider stdlib; **native**, with a separate interop adapter |
| Foreign calls, native memory, callbacks, aggregates, borrowed slices, and atomic native-error capture | `jolt.ffi` | `jolt.ffi` is canonical | No JNA/JNI emulation | Core; **native only** |
| Child process lifecycle and argv spawning | POSIX/Win32 backends behind one process engine | Proposed argv-oriented host operation; `jolt.host/sh` remains shell-oriented | Bounded `ProcessBuilder`, `Process`, and `ProcessHandle` adapters | Core; **both** facades over one process engine |
| Class/member registration and provider loading | Host-class registry plus loader/build integration | Registration/provider functions for libraries and build tooling | Constructor/static/instance retry mechanism | Core; **both**, because this is the bridge |
| Fundamental concurrency needed by common Clojure libraries | Chez/Jolt concurrency engine | Futures, promises, and small Jolt-native primitives | Audited `java.util.concurrent` members | Core; **both** facades over one semantic implementation |
| File, stream, charset, and bulk-copy basics | Existing host I/O and dependency-free Clojure wrappers | `clojure.java.io`, byte arrays, and stream protocols remain Clojure APIs despite historical names | Selected File, stream, writer, channel, and charset adapters | Core/stdlib according to current ownership; **both** facades over shared representations |
| Addresses, DNS, owned sockets, native errors, byte-I/O attempts, readiness, and connect completion | `jolt.net` | `jolt.net` is canonical; readiness stays a substrate concern | None in this namespace | Incubate in jolt-net, then upstream to stdlib after runtime gates; **native only** |
| TCP scheduling, deadlines, backpressure, completion, cancellation, operation-length leases, and stream lifecycle | jolt-tcp over jolt.net | Existing Clojure/Teensyp-shaped API; a cleaner native facade may be additive | Consumed by the optional NIO facade, never reimplemented there | External ecosystem library; native API plus an adapter consumer |
| HTTP parsing, framing, streaming bodies, Ring integration | jolt-http over jolt-tcp | `jolt.http.*` and Ring/Capra-shaped Clojure APIs | No Java HTTP-client/server emulation; exact Capra may consume lower interop internally | External ecosystem library; **native/Clojure only** |
| Socket channels, selectors, keys, options, Teensyp proxy streams | Optional facade over jolt-net/jolt-tcp | No competing native transport API | Selected `java.nio.*`, `java.net.*`, and Teensyp helper classes | External `jolt.compat.*` library initially; **interop only** |
| Time implementation and Java time registrations | jolt-lang/time | `jolt.time` namespaces | Selected `java.time` classes, constants, and formatters | External ecosystem library; **both** facades |
| Property generation and shrinking | jolt-hegel over jolt.ffi and upstream libhegel | `hegel.*` and `clojure.test` integration | None | External ecosystem library; **native/Clojure only** |

“Both” never means two independent implementations. It means one owned state
and lifecycle with native Clojure and thin Java-shaped facades. A channel still
owns a jolt-net socket; a `ByteBuffer` uses the same byte storage and copy
rules; a `ProcessBuilder` child belongs to the same process backend.

Use these tests when placing a new facility:

- expose it as **native Jolt** when it defines Jolt's own portable semantics,
  owns a native resource, or is useful without reference to a Java API;
- expose it as **interop only** when its purpose is to satisfy a Java-shaped
  source contract and a second native public vocabulary would add no
  capability;
- expose it as **both** only when the underlying facility is broadly useful
  and one implementation can support both facades without weakening either
  contract;
- place the mechanism in **core** only when libraries cannot implement or load
  without it;
- place a dependency-free shared facility in **stdlib** after its contract and
  platform gates are stable; and
- keep policy-rich, optional, or independently released behavior in the
  **ecosystem**.

Java names are therefore not the abstraction boundary. They are source
compatibility entry points. Native APIs remain free to express Jolt ownership,
deadline, byte-window, and lifecycle rules directly, while adapters translate
the bounded Java contract into those operations.

### Bytes are not networking

The fact that byte windows were first needed by sockets does not make them a
networking abstraction. Core owns the representations and unsafe mechanisms:
arrays, indexed access, signed-byte fidelity, overlap-safe copy, and a scoped
borrow that cannot escape an FFI call. An incubating, dependency-free
`jolt.bytes` namespace may build the first safe view over those mechanisms:

```clojure
(bytes/window array)
(bytes/window array start end)
(bytes/slice window start)
(bytes/slice window start end)
```

`Window` is an immutable descriptor over mutable, aliased storage. Its bounds
do not change; its contents are neither a snapshot nor value-equal by default.
The relative `start` and `end` arguments to `slice` are strict half-open bounds.
A valid slice is O(1), shares the same backing storage, and cannot escape its
parent window.

`Window` implements `Seqable`, `Counted`, `Indexed`, `IReduce`, and
`IReduceInit`, with signed byte values matching Clojure/JVM byte-array
semantics. It does not claim `Sequential`, persistent-collection operations, or
content equality. Core `drop` and `take` remain useful sequence projections,
but they produce lazy sequences, may traverse to find their first result, and
discard backing-store and lease identity. They are not the
ownership-preserving slice operation. This RFD therefore does not define a
public `drop-prefix`.

`Cursor` is provisionally an immutable `{window, position}` pair with strict
bounds and no collection protocols. Its public shape is not frozen until
allocation and throughput evidence shows that a cursor abstraction is better
than explicit offsets.

Java `ByteBuffer` remains an interop type with Java cursor semantics; making it
`Seqable` would create behavior absent on the JVM and is rejected. It may share
the same underlying byte representation and copy implementation without
becoming the canonical native view.

Before `Window` can claim idiomatic collection behavior, core must correct four
generic protocol-dispatch gaps:

- `seqable?`, `counted?`, and `indexed?` must recognize custom protocol
  implementations just as `seq`, `count`, and `nth` already do;
- two-argument `reduce` must honor custom `IReduce`;
- timed `deref` must honor custom `IBlockingDeref`; and
- `realized?` must honor custom `IPending`.

Those are general Clojure compatibility fixes, not byte-window special cases.
Their dispatch invariant is canonical namespace-qualified interface identity
**and** exact method arity. Selecting by method shape alone, or first collapsing
interface ids to simple names, lets an unrelated local protocol impersonate a
core interface. A declared interface whose selected method is absent is a
distinct `AbstractMethodError`, not an absent-interface cast failure. The
checked buggy/corrected/non-vacuity models and JVM/runtime collision controls
are recorded in the supplementary byte/I/O invariant note.

This is a runtime-wide protocol rule, not only a core-adapter rule. A `reify`
may use a compact method-name table internally, but an instance-local method is
eligible only when the reify declared the exact requested canonical protocol.
Otherwise dispatch proceeds to that protocol's host/default extension or fails
missing. A second checked model trio and JVM/runtime control pin the
same-method-name cross-protocol collision.

### Completions are future-shaped, not native-I/O Futures

A native I/O operation may retain access to a submitted byte window after a
caller requests cancellation. Jolt's current Future cancellation can mark a
Future done even when its worker cannot be interrupted. Consequently,
`future-cancel`, `future-done?`, or an observation timeout cannot be treated as
permission to reuse leased storage.

The initial completion abstraction therefore belongs with the operation and
lease policy in jolt-tcp, not jolt-net. A completion implements `IDeref`, timed
`IBlockingDeref`, and `IPending`, and exposes an explicit nonblocking
`outcome`. Its terminal data is:

```clojure
{:status :succeeded :value value}
{:status :failed :exception ex}
{:status :cancelled :exception cancellation-ex}
```

Untimed or timed deref returns the success value and throws the stored failure
or cancellation exception. A timed deref timeout ends only that observation:
it does not cancel the operation or release the window. `cancel!` is a
two-phase request. `realized?` stays false, `outcome` stays nil, and the window
stays unavailable to the caller until native access has ended and exactly one
terminal outcome has been published.

This contract deliberately does not implement Jolt Future or promise
cancellation. Exact Future compatibility would require copying submitted
bytes, blocking until cancellation is acknowledged, or a backend guarantee
that cancellation has synchronously ended every native access.

The abstraction should remain local, for example `teensyp.completion`, until a
second independent consumer demonstrates a generic home such as
`jolt.io.completion`. Likewise, exact/all/copy loops may be explored as pure
`jolt.io.transfer` functions over private handler maps, but this RFD does not
freeze public `TryByteSource` or `TryByteSink` protocols. jolt-net readiness is
a legitimate native substrate API; it remains private beneath any later
portable TCP operation/completion API.

Completion vocabulary must stay exact. “Bytes accepted” means that the owning
layer accepted or queued bytes under its documented ownership contract; it
does not prove peer delivery. “Flushed” means that the documented in-process
or OS buffer boundary was crossed; it does not imply remote observation,
filesystem visibility, or durable storage unless a separate capability says
so. Operation deadline, observer timeout, cancellation request, terminal
cancellation, EOF, reset, and close are distinct outcomes.

### jolt-net should graduate to stdlib; TCP and HTTP should not move with it

jolt-net was intentionally given `jolt.net.*` namespaces and no production
third-party dependency so it can become the shared stdlib substrate. Graduation
requires:

- complete Linux and macOS runtime gates;
- real Windows blocking, nonblocking, readiness, wake, and close gates;
- stable ownership, error, endpoint, and byte-I/O contracts;
- adoption by at least two existing Jolt consumers; and
- no dependency on jolt-tcp, HTTP, Hegel, or an optional compatibility facade.

Until those gates pass and the proposal is accepted, the public jolt-net repo
remains the incubator and downstream projects pin a reviewed commit. Once
graduated, Maven HTTP, nREPL, and ecosystem libraries can import the same stdlib
namespace instead of maintaining private socket stacks.

jolt-tcp stays external because executor choice, handler scheduling,
backpressure, queue capacity, connection state machines, and stream adapters
are policy-rich and independently useful. jolt-http stays external because HTTP
versioning, parser/security behavior, Ring integration, and body abstractions
should not enter the language runtime release train.

### The compatibility facade should be external and demand-loaded

Core contains the registry and small, universally useful host shims.
Networking-specific Java classes belong in an optional `jolt.compat.*`
distribution. The selected mechanism is:

1. Dependency resolution reads provider declarations and registers
   class-name-to-namespace mappings with provenance.
2. Normal constructor, static, or selected instance lookup proceeds without
   loading an adapter.
3. On a miss, the runtime resolves the one declared provider, marks it loading,
   requires it, and retries once.
4. Registration success is cached. A missing member, cycle, provider conflict,
   or second miss fails with structured data.
5. A closed-world build includes every declared provider reachable from its
   resolved graph and seals the mapping into the build manifest. It does not
   discover providers from the filesystem at runtime.

The runtime registry can land before `deps.edn` plumbing. Tests may register
providers explicitly; project metadata follows after the registry contract is
stable and reconciled with dependency/AOT resolution.

### Exact-source experiments belong beside the native ports

The jolt-tcp repository should carry an opt-in exact-Teensyp profile that
depends on the compatibility facade. jolt-http should do the same for Capra and
Ring. This keeps the pinned source revision, exact API manifest, native port,
differential tests, and any minimal compatibility patch in one review context.

If an exact-source path becomes independently useful and stable, it can later
be packaged without displacing the native port.

### Exact compatibility is defined by a manifest and semantics

The compatibility target is a pinned source revision plus an exact manifest of
the constructors, members, constants, interfaces, exceptions, and behavioral
contracts it uses.

Important contracts include:

- `ByteBuffer` duplicates share backing and not cursor state;
- selected-key removal consumes readiness;
- channel close invalidates its key;
- selector wake affects the current or next select as required by Java;
- conditions release and restore a reentrant lock correctly;
- unpark-before-park retains one permit;
- zero-length reads, EOF, closed-stream writes, and typed exceptions match the
  source's expectations; and
- executor scheduling cannot deadlock callbacks behind blocking handlers.

A namespace loading successfully does not establish compatibility.

## Alternatives considered

### Continue only with direct Jolt ports

This minimizes core compatibility work and preserves full control over
hardening, but repeats adaptations for other JVM-oriented libraries. The ports
remain necessary; using them as the only strategy leaves useful source
compatibility unexplored.

### Make Java NIO the internal Jolt networking API

This could maximize source reuse, but it would force jolt-net and future native
backends through Java object/readiness semantics and make a large compatibility
surface load-bearing. It also risks inheriting source defects. Rejected.

### Put byte windows and cursors in jolt-net

Sockets were the first consumer, but codecs, files, FFI calls, in-memory
structures, and disk formats need the same bounds and traversal semantics.
Networking ownership would either force those users to depend on an unrelated
transport library or invite duplicate view types. Core byte mechanisms plus an
incubating dependency-free `jolt.bytes` view are selected. Rejected.

### Use `drop` as the byte-window slice operation

`drop` is idiomatic when a sequence projection is wanted, and `Window`
deliberately supports it through `Seqable`. It is not an O(1),
structure-preserving operation: the result is a lazy sequence without the
window's backing-store, bounds, or lease identity. `slice` is selected for
window-preserving views; a public `drop-prefix` synonym is unnecessary.
Rejected.

### Make Java `ByteBuffer` Seqable

This would make some native-looking Clojure expressions convenient but would
invent behavior that Java `ByteBuffer` does not have on the JVM. It also
confuses a mutable Java cursor with the immutable native `Window` descriptor.
The interop facade keeps Java semantics. Rejected.

### Expose readiness or would-block through a portable I/O API

Readiness is a valid jolt-net substrate contract and a useful implementation
tool for POSIX pollers. It is not shared naturally by completion-oriented
backends such as IOCP or `io_uring`, and it exposes retry policy to otherwise
pure Clojure state machines. A future portable API should expose operations,
completion, deadlines, and cancellation while keeping readiness beneath its
backend. Rejected.

### Treat Future cancellation as terminal native-I/O cancellation

Jolt may report a Future cancelled even when its worker cannot be interrupted.
Publishing that state as permission to reuse a zero-copy byte window creates a
use-after-release race. Explicit two-phase `cancel!` with terminal
acknowledgement is selected. Exact Future compatibility requires copying,
synchronous native cancellation, or a stronger backend guarantee. Rejected.

### Replace jolt-tcp with jolt-net

jolt-net deliberately owns the native substrate, not TCP scheduling,
backpressure, handler execution, or Teensyp-compatible streams. Collapsing them
would make the substrate policy-heavy and make reuse by nREPL, Maven HTTP, and
other transports harder. Rejected.

### Put Hegel and libhegel into core

This removes one setup step but couples a property-testing library and native
artifact release cadence to the language runtime. The reviewed FFI already
supports the required calls. Rejected.

### Generate executable Hegel properties directly from Ansatz

A checked theorem does not determine the runtime representation of naturals,
allocation bounds, exception and invalid-input policy, effect handling, or a
shrink strategy. Ansatz's current elaboration and Clojure generation are
additional trusted boundaries, and foreign declarations are assumptions about
their implementations. The safe near-term bridge is a reviewed provenance
manifest, a deterministic bounded oracle, and hand-written Hegel properties
whose generators and assertions explicitly map theorem hypotheses and
conclusions onto Jolt values. Direct generation is rejected for this proposal.

### Extract the cross-runtime platform API first

The larger portability idea is compelling, but freezing it from Jolt alone
would encode assumptions that a JVM, Node, CLR, Jank, or deterministic fake
prototype might disprove. Complete the Jolt layering and preserve narrow
handler seams; extract the multi-runtime API in a follow-on determination.

### Put every Java compatibility shim in core

This would make optional NIO, Teensyp, Capra, and future library-specific
surfaces part of the language bootstrap and Jolt release cadence. It would
also make an audited compatibility experiment look like a general JVM promise.
Core gets the registration/provider mechanism and only shims that are broadly
useful to ordinary Clojure code. Networking-specific and source-specific
providers remain external. Rejected.

### Keep the provider and host-extension mechanisms entirely external

An external library cannot reliably intercept an unknown constructor, static
member, or instance-member lookup before its own namespace has loaded.
Requiring users to preload adapters restores namespace-order coupling, and
closed-world builds would have no authoritative provider graph to include.
The bounded provider mechanism therefore belongs in core even though most
providers do not. Rejected.

### Eagerly preload every compatibility namespace

Eager loading avoids a lookup retry, but it increases startup and build roots,
makes unrelated optional native libraries load together, and turns dependency
order into application behavior. It also obscures provider conflicts. Lazy,
declarative, exact-provider loading with one retry is selected instead.
Rejected.

### Maintain independent native and Java-shaped implementations

Two process engines, byte-buffer stores, concurrency engines, or socket state
machines would drift in failure, cancellation, and ownership semantics. It
would double the proof and platform matrix while giving differential results
no clear oracle. Thin Java-shaped adapters over the canonical native facility
are selected wherever both exposures exist. Rejected.

### Freeze generic byte source and sink protocols now

The operation shapes required by jolt-net, JVM streams, files, deterministic
fakes, and completion-oriented backends have not yet been shown equivalent.
Freezing `TryByteSource` or `TryByteSink` from the first socket use case would
make readiness and would-block semantics unnecessarily public. Private handler
maps and experimental pure `jolt.io.transfer` algorithms are sufficient until
at least Jolt, JVM, and fake implementations pass one conformance corpus.
Rejected.

## Implementation plan

Each slice is independently reviewable. Existing working implementations stay
available until the replacement passes its gates.

### Phase 1: finish core proposal foundations

- Land the reviewed host/FFI stack in dependency order.
- Add atomic native-error capture to the FFI declaration surface and verify
  that callers receive the return value and matching error from one foreign
  transition.
- Correct custom `Seqable`/`Counted`/`Indexed` predicates, two-argument
  `IReduce`, timed `IBlockingDeref`, and `IPending` dispatch before higher
  layers depend on them.
- Complete transactional Git dependency behavior on native Windows.
- Add a genuine argv-oriented Windows process backend while retaining
  `jolt.host/sh` for actual shell programs.
- Keep source, packaged, x86-64, ARM64, Linux, macOS, and Windows evidence
  distinct.
- Do not merge the selective AOT research branch into the proposal.

### Phase 2: class-provider bootstrap and universal shims

- Implement provider registration, identical/conflict rules, cycle detection,
  and exact-one-retry behavior.
- Prove source mode, add-deps, load-order, and built-application behavior.
- Complete strict `ByteBuffer`, charsets, `ThreadLocal`, null input stream,
  `TimeUnit`, and streaming bulk copy.
- Incubate signed-byte `Window` and structure-preserving `slice`; keep `Cursor`
  provisional and do not add collection semantics to `ByteBuffer`.
- Add an exact Teensyp/Capra API manifest test.

The runtime registry can land before project/deps metadata plumbing if the
latter would entangle unrelated dependency work.

### Phase 3: concurrency semantics

- Implement and model the jolt-tcp-local completion outcome and two-phase
  cancellation contract before any submitted window is reused.
- Implement the required bounded queue and concurrent set subset.
- Add reentrant conditions with exact hold-count restoration.
- Add one-permit park/unpark.
- Make executor constructor names and scheduling behavior honest; a fixed pool
  must not advertise virtual-thread-per-task semantics.
- Check capacity, FIFO, lost-signal, permit, shutdown, rejection, and exact
  pool-size deadlock controls.

### Phase 4: complete jolt-net on Windows

- Land the blocking, nonblocking, `WSAPoll`, wake/close, and CI tasks in order.
- Resolve missing primitives in jolt.ffi or jolt-net rather than in jolt-tcp.
- Keep IOCP as an alternate follow-on backend after the portable Winsock path
  provides a behavioral oracle.
- Preserve descriptor generations, registration revisions, immediate error
  capture, partial progress, EOF, half-close, and close completion.

### Phase 5: optional NIO/stream compatibility facade

- Implement `InetSocketAddress`, socket-option tokens, channels, selectors, and
  selection keys over the reviewed jolt-net/TCP behavior.
- Preserve stable `SelectionKey` identity over monotonic internal token
  revisions.
- Map native terminal failures to typed `IOException` behavior.
- Add Teensyp proxy stream constructors and honest class/interface tags.
- Implement file/channel and writer adapters needed by Capra and Ring.
- Correct the RFC-1123 UTC formatting behavior in the time library.

### Phase 6: exact-source and differential validation

- Pin the audited Teensyp and Capra revisions.
- Run untouched pure buffer, stream, parser, and server source where supported.
- Replace JVM-only client test harnesses with Jolt loopback clients while
  preserving assertions and fixtures.
- Compare exact-source behavior with the hardened jolt-tcp/jolt-http oracles:
  half-close, reset, callback failure, pool saturation, pipelining, malformed
  framing, header injection, chunk delimiters, body finalization, and queue
  capacity.
- Correct issues at the owning Jolt layer or upstream source; do not weaken the
  oracle.

### Phase 7: migrate Jolt libraries and consumers

- Reimplement jolt-tcp over reviewed jolt-net primitives in bounded slices.
- Reimplement jolt-http over that jolt-tcp revision.
- Move jolt-hegel to the reviewed core FFI surface while keeping it external.
- Update nREPL, Maven/HTTP tooling, Ring adapters, and other ecosystem
  consumers to validate the resulting dependency graph.
- Run real functional tests across every platform where the underlying runtime
  capability exists; run portable namespace/ABI gates separately where it does
  not.

### Repository landing order

The phases produce the following review and release order. A later repository
may develop against a pinned proposal commit, but it does not declare the
capability complete before its prerequisite gate passes.

| Order | Repository or proposal slice | Delivers | May depend on | Exit gate |
| --- | --- | --- | --- | --- |
| 1 | `casselc/jolt`: target, clock, byte mechanisms, generic protocol dispatch, FFI, host identity, and dependency slices | Universal mechanisms and reviewed ABI surface | Upstream Jolt baseline | Existing unit/AOT/FFI suites plus native target gates |
| 2 | `casselc/jolt`: provider registry, universal host shims, and incubating byte views | Demand-loaded external providers, shared semantic fixes, stable `Window`, and provisional `Cursor` | Order 1 | Conflict, cycle, exact-one-retry, source, add-deps, built-application, and byte-view conformance tests |
| 3 | `jolt-net` | Canonical socket substrate on Linux, macOS, and Windows | Pinned orders 1-2 | Real blocking, nonblocking, readiness, wake, close, and lifecycle suites on each claimed platform |
| 4 | `jolt-tcp` | Scheduling, backpressure, completion/cancellation, streams, and connection lifecycle over jolt-net | Pinned order 3 | Existing TCP and completion-lease proofs, deterministic failure controls, and real loopback suites |
| 5 | `jolt-http` | Hardened HTTP and Ring-shaped integration over jolt-tcp | Pinned order 4 | Parser/framing proofs, body/producer lifecycle, pipelining, and cross-platform functional tests |
| 6 | `jolt-hegel` | Direct use of the upstreamed FFI surface while remaining separately released | Pinned order 1 | Native libhegel matrix, AOT identity, shrinking, stateful, and `clojure.test` integration |
| 7 | `jolt-time` and core I/O/concurrency follow-ups | Exact broadly useful semantics needed by audited source | Pinned order 2 | Focused semantic models and regression tests |
| 8 | External `jolt.compat.*` experiment | Bounded NIO/stream adapters and exact Teensyp/Capra loading | Orders 2-4 and 7 | Exact API manifest plus source, lifecycle, and differential gates |
| 9 | nREPL, Maven/HTTP, Ring, and other ecosystem consumers | Composition evidence and removal of private substrate copies | Relevant released or pinned orders above | Each consumer's native tests on every supported runtime |

Upstream incorporation should preserve these review boundaries. Core proposal
slices can be presented as stacked changes; independent libraries transfer
only after their dependency is available in an accepted Jolt revision or an
explicitly pinned incubation release. A compatibility experiment does not
block native-library adoption.

### Follow-on: cross-runtime extraction

After the Jolt, JVM, and deterministic fake implementations exist, write a
separate RFD for a versioned `clojure.platform` API/SPI. Candidate principles
carried forward from this work are:

- data-only capability descriptors plus small handler maps;
- operation/completion semantics above readiness;
- explicit byte-window ownership, generations, cancellation, and deadlines;
- honest storage visibility/durability levels; and
- pure Clojure state machines above the platform seam.

This follow-on should prove generality with networking, codecs/protocols, an
in-memory structure, and a disk-backed log or index. Raft and LSM may be later
examples, but neither should define the base API.

## Conformance and proof obligations

### Proof-derived runtime properties

Proof-derived testing uses four distinct evidence lanes:

1. a bounded solver model with a deliberately buggy witness and a non-vacuity
   control;
2. an unbounded pure theorem where the proof tool and representation permit it;
3. a deterministic bounded EDN oracle checked exhaustively; and
4. hand-written jolt-hegel properties against the actual runtime.

Theorem hypotheses guide constructive dependent generators; theorem conclusions
identify runtime assertions. Positive-domain cases are generated valid by
construction rather than filtered with assumptions, so shrinking must preserve
the hypotheses. The proposed first byte-window slice pins an Ansatz environment,
enumerates all 969 valid parents and 20,349 valid slices at capacities `0..16`,
then uses Hegel to explore larger descriptors, signed contents, nesting,
invalid inputs, and backing aliasing.

A versioned manifest records theorem and environment hashes, named
obligations, oracle digest and count, hypothesis-to-generator mappings,
conclusion-to-assertion mappings, the runtime property var, runtime-only
obligations, and known omissions. It provides provenance, not executable
certification. Automation may validate that schema, its pins, fixture digests,
and named tests; it must not yet synthesize Hegel generators or assertions.

Neither generated examples nor a proved pure model certify representation
mapping, mutation, resource ownership, concurrency, native effects, exception
behavior, fairness, or durability. jolt-hegel remains an external test
dependency. The detailed byte-window mapping and first property skeleton live
in [`bytes-io-completion-invariants.md`](../../bytes-io-completion-invariants.md).

### Provider and host interop

- Unknown class/member fails before arbitrary namespace loading.
- One provider load causes no more than one retry.
- Identical declarations compose; conflicts fail closed.
- Cycles and re-entrant loads terminate with structured diagnostics.
- Host class, `instance?`, protocol extension, and invocation agree.
- A same-shaped or same-short-name user protocol cannot drive a core operation:
  canonical identity and exact method arity must both match.
- A reify-local method is selected only for an exact canonical protocol that
  the reify declared; an equal method name from another protocol is irrelevant.
- Source and built behavior match.

### Buffers and concurrency

- Every valid `Window` slice stays within both the parent bounds and backing
  capacity, including empty and full-window boundaries.
- `Window` sequence, indexed, and reduced traversals yield the same signed
  byte sequence without changing its descriptor.
- A provisional cursor never advances before zero or beyond its window.
- `0 <= position <= limit <= capacity` always holds.
- Duplicate buffers share bytes but not cursor state.
- `compact` preserves the exact remaining sequence.
- Queue admission is bounded and FIFO where promised.
- Condition wait releases and restores the full reentrant hold count.
- Unpark-before-park retains one permit.
- Handler and callback scheduling cannot deadlock at exactly pool size.

### Native I/O and lifecycle

- A native return value and its matching error are captured atomically before
  allocation, cleanup, callback, or another foreign call can overwrite it.
- Scalar and captured foreign-call dispatch have invariant, distinct result
  shapes; every sentinel-returning call whose error is consumed uses the pair
  and never falls back to a later error accessor.
- Every owned native handle closes once.
- Old descriptor generations and registration revisions cannot produce current
  events.
- Partial reads/writes do not duplicate or lose bytes.
- EOF, half-close, reset, cancellation, timeout, and close remain distinct.
- Wake and close retire active waits and wake resources within bounded time.
- Submitted byte windows remain owned until their operation completes.
- A completion publishes exactly one terminal outcome using a linearizable
  transition.
- Native access and the lease end before terminal notification; terminal
  observation is the first point at which the caller may reuse the window.
- A cancel request and an observer timeout cannot publish terminal
  cancellation or release a window by themselves.
- Close, cancellation, and native completion races preserve one terminal
  publication and one release.

### TCP and HTTP

- Blocking and streaming producers receive exactly one terminal outcome.
- Normal peer EOF does not discard pending responses.
- Ambiguous request framing and unsafe response metadata fail closed.
- Terminal EOF cannot strand a parser.
- Pipelining and capacity remain bounded under inline completion.
- Exact-source behavior is differentially checked against the hardened ports.

Every solver proof records source anchors, assumptions, a corrected model, a
buggy control with a witness, a non-vacuity control, and reproduction commands.
The byte-window containment, exact interface-dispatch, exact reify-dispatch,
and completion-lease models are recorded with the RFD's supplementary
invariant note. Models complement real native and concurrency tests; they do
not substitute for them or prove behavior through a retained raw-array alias.
Proof-derived property manifests add traceability and reproducible runtime
oracles; they do not close those trust boundaries.

## Performance considerations

- Core buffer and FFI paths must avoid byte-at-a-time copies and per-operation
  temporary arrays where the current primitive supports a borrowed slice.
- Contiguous byte windows are the required baseline; vectored I/O is an
  optional follow-on using `readv`/`writev` or `WSARecv`/`WSASend`.
- Windows IOCP, Linux `io_uring`, and Darwin kqueue/libdispatch may implement
  alternate jolt-net backends after they pass the same black-box suite.
- Java compatibility must not silently turn asynchronous operations into an
  unbounded OS-thread-per-operation design.
- Each migration slice records allocation, throughput, latency, or fairness
  evidence appropriate to its hot path and watches for regressions.

## Security and failure considerations

- Raw pointers, ABI layouts, native handles, and last-error slots remain in
  core FFI or jolt-net.
- Target selection and absent features fail closed.
- Provider loading is declarative and bounded, not arbitrary namespace search.
- Buffer and handle lifetimes are explicit.
- HTTP request-smuggling and response-injection defenses remain in force.
- Dependency and native-artifact caches retain origin, version, ownership, and
  cleanup boundaries.
- A probe or compiled artifact never promotes a capability without real runtime
  evidence at the claimed layer.

## Compatibility and landing policy

- The proposal is maintained in the `casselc/jolt` fork on dedicated branches.
- Nothing is pushed to `jolt-lang/jolt`, and no upstream pull request is opened,
  without separate authorization.
- Core changes land in dependency order and remain reviewable as stacked
  proposals.
- jolt-net, jolt-tcp, jolt-http, and jolt-hegel retain independent repositories
  and release histories.
- Compatibility manifests pin exact source revisions and must be revised when
  upstream source changes.

## Open questions

- Should class-provider declarations ultimately live in `deps.edn`, a separate
  manifest, or both?
- Which provider and compatibility namespaces belong in core versus a
  `jolt.compat.*` library?
- Should exact-source compatibility track corrected upstream Teensyp/Capra
  revisions or carry a minimal Jolt patch set?
- Which sticky wake semantics must be implemented in the Java Selector facade
  rather than changing jolt-net's native wake contract?
- When can the compatibility path replace duplicated port logic without losing
  differential-oracle value?
- Which Jolt-specific handler seams are mature enough to inform the later
  cross-runtime RFD?

None of these questions blocks the class-provider registry, the current
Windows jolt-net sequence, or migration of existing Jolt libraries onto the
already reviewed lower layers.

## References

- Oxide Computer Company, [RFD 1: Requests for Discussion](https://rfd.shared.oxide.computer/rfd/0001).
- `jolt-net/docs/CLOJURE-PLATFORM.md`.
- `jolt-net/docs/PLATFORM-COVERAGE.md`.
- `jolt-net/docs/proofs/socket-invariants.md`.
- `jolt-net/docs/WINDOWS-RUNTIME-SEQUENCE.md`.
- `jolt-tcp/docs/JOLT-NET-DESIGN-SPIKE.md`.
- `jolt-tcp/docs/proofs/reactor-lifecycle-invariants.md`.
- `jolt-http/docs/proofs/http-fail-closed.md`.
- `jolt-http/docs/proofs/inline-resume-capacity.md`.
- `jolt-hegel/docs/CORE-JOLT-INTEGRATION-SPIKE.md`.
- `docs/bytes-io-completion-invariants.md`.
- `docs/aot-cache-provenance-invariants.md`.
- `docs/audit-index-2026-07-24.md`.
