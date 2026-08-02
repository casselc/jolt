# P1 — Semantic Facts Register (v0.5.13 candidate)

**Provenance:** `jolt-runtime-engineer` subagent, session `ses_0400ee974ffeD2n1HmvHthHXhz`,
model `openai/gpt-5.6-sol` (high), 2026-08-01.
**Baseline:** `/home/chuck/ai-src/worktrees/jolt-upstream-rebase-v0.5.13-candidate`
at `021b0b729bdc11264864bc0033cb1b64b3cde5e3`.
**Status:** UNREVIEWED working report; facts carry source citations but have not yet
been independently re-verified by the primary orchestrator.
**Method:** read-only source audit. No build or test result is claimed.

---

# Semantic Facts Register

## 1. Evaluation order & special forms

- **Ordinary function calls are observably left-to-right:** analyzer stores callee and arguments in source order; IR preserves ordered `:args`; backend orders `[callee & args]` and emits `let*` temporaries whenever reordering could be observable. Chez application order itself is explicitly unspecified/right-to-left in practice. `jolt-core/jolt/analyzer.clj:1081-1088`; `jolt-core/jolt/ir.clj:42`; `jolt-core/jolt/backend_scheme.clj:429-473`; `jolt-core/jolt/backend_scheme.clj:909-930`
- The ordering optimization leaves operands inline only when moving them cannot affect observations: effectful operands and order-sensitive Var reads trigger the `let*`; constants, locals, Var objects, and quoted values are classified effect-free. `jolt-core/jolt/backend_scheme.clj:441-473`
- Vector, set, and map literal operands are likewise emitted through the ordered-call mechanism; map key/value nodes are flattened in source-pair order. `jolt-core/jolt/backend_scheme.clj:1315-1321`; `host/chez/host-contract.ss:126-138`
- **Host interop is not similarly fixed:** `:host-new` and `:host-call` splice target/arguments directly into Scheme applications without `ordered-call`; because the same backend says Chez application order is unspecified, side-effecting interop operand order is UNKNOWN/host-dependent from this source. `jolt-core/jolt/backend_scheme.clj:429-432`; `jolt-core/jolt/backend_scheme.clj:1302-1304`; `jolt-core/jolt/backend_scheme.clj:1344-1353`
- `if` requires two or three operands, evaluates its test once, then emits a Scheme `if`, selecting only one branch; absent else becomes `nil`. `jolt-core/jolt/analyzer.clj:530-538`; `jolt-core/jolt/backend_scheme.clj:1305-1310`
- `do` analyzes forms in order and emits Scheme `begin`; empty `do` is `nil`, and the final form supplies the result. `jolt-core/jolt/analyzer.clj:153-159`; `jolt-core/jolt/analyzer.clj:539`; `jolt-core/jolt/backend_scheme.clj:1311-1313`
- The compiler primitive is `let*`; each initializer is analyzed before its binding enters the environment, and runtime emission uses Scheme `let*`, giving sequential bindings. Surface `let` must reach this through macro expansion. `jolt-core/jolt/analyzer.clj:161-175`; `jolt-core/jolt/analyzer.clj:542-544`; `jolt-core/jolt/analyzer.clj:1012-1024`; `jolt-core/jolt/backend_scheme.clj:551-557`
- `loop*` initializers are sequential and evaluated outside the recursive frame; the body is a named Scheme `let`. `recur` requires an active loop/fn target, checks arity, evaluates arguments with ordered-call, and invokes that target. `jolt-core/jolt/analyzer.clj:545-559`; `jolt-core/jolt/backend_scheme.clj:559-570`; `jolt-core/jolt/backend_scheme.clj:644-648`
- `fn*` supports named/anonymous, fixed/variadic, and multi-arity forms; each arity gets a named-let recur target, while named functions use `letrec`/`letrec*` for self-reference. `jolt-core/jolt/analyzer.clj:215-244`; `jolt-core/jolt/analyzer.clj:263-277`; `jolt-core/jolt/backend_scheme.clj:650-765`
- `def` interns the Var during analysis; a declaration has no initializer, while initialized defs evaluate their initializer and metadata expression. Emission returns the Var object, not the root value. `jolt-core/jolt/analyzer.clj:434-473`; `jolt-core/jolt/backend_scheme.clj:1360-1389`
- A Var value reference dereferences its current dynamic binding/root at use time; `(var x)`/`#'x` emits the interned Var cell itself. `jolt-core/jolt/ir.clj:16-21`; `jolt-core/jolt/backend_scheme.clj:1258-1285`
- `quote` does not analyze/evaluate its contents; the backend recursively reconstructs literal runtime data. Quoted list source-position metadata is stripped, while user metadata is retained where distinguishable. `jolt-core/jolt/analyzer.clj:514-529`; `jolt-core/jolt/backend_scheme.clj:475-535`
- `set!` supports mutable deftype fields, static shim fields, and Vars. Var `set!` changes only the innermost thread binding and throws when none exists; it never establishes a root binding. `jolt-core/jolt/analyzer.clj:475-504`; `host/chez/dyn-binding.ss:131-143`
- `throw` evaluates one expression and passes the resulting Jolt value to `jolt-throw`; catch handling unwraps the host condition back to that value. `jolt-core/jolt/backend_scheme.clj:1155-1167`; `jolt-core/jolt/backend_scheme.clj:1322-1323`
- `try` enforces body-before-catches and a final, last-position `finally`. Catch clauses are tested in source order through `instance?` plus a broad-host-condition helper; unmatched values are rethrown. `jolt-core/jolt/analyzer.clj:283-355`
- `Throwable`, `java.lang.Throwable`, `Object`, `java.lang.Object`, and non-symbol catch selectors such as `:default` are unconditional catches. `jolt-core/jolt/analyzer.clj:279-281`; `jolt-core/jolt/analyzer.clj:331-345`
- `finally` is emitted as the after-thunk of `dynamic-wind`, so it runs after normal return, catch completion, or escaping throw; its value is discarded. `jolt-core/jolt/backend_scheme.clj:1155-1170`

## 2. Values & equality

- `nil` emits as the runtime sentinel `jolt-nil`; booleans emit as Scheme `#t/#f`. Tests not proven to return Scheme booleans are passed through `jolt-truthy?`, whose precise implementation lies outside the allowed file list. `jolt-core/jolt/backend_scheme.clj:400-413`; `jolt-core/jolt/backend_scheme.clj:1305-1310`
- The documented numeric tower contains exact integers, bignums, exact ratios, doubles, and BigDecimal `M` literals; `(/ 1 2)` yields `1/2`. `README.md:114-123`; `README.md:310-316`
- All narrow integer results use one exact-integer box model rather than distinct Byte/Short/Integer classes. Checked casts truncate toward zero and enforce JVM-sized ranges; generic exact arithmetic may promote rather than overflow. `test/conformance/SPEC.md:130-150`; `host/chez/converters.ss:231-260`
- Proven/literal `:long` arithmetic uses Chez's 61-bit fixnum path: overflow can occur at 2^60, while a generic bignum path can produce an exact result where JVM primitive-long arithmetic throws. `test/conformance/known-divergences.edn:85-107`
- Ratios are Chez exact, non-integer rationals; `numerator`/`denominator` reject non-ratios. Doubles are Chez flonums, and Jolt has no distinct single-float representation. `host/chez/converters.ss:288-310`
- Strings are Chez strings indexed by Unicode codepoint, not UTF-16 units: an astral character has count one and cannot be split by `subs`. Emitted string literals escape non-ASCII by codepoint. `test/conformance/SPEC.md:156-166`; `jolt-core/jolt/backend_scheme.clj:384-398`
- String hashing nevertheless reproduces Java UTF-16-unit hashing by converting astral codepoints into surrogate pairs internally. `host/chez/hasheq.ss:184-204`; `test/conformance/SPEC.md:164-166`
- Keywords contain optional namespace/name and are interned; repeated keyword construction may be hoisted because interning makes sharing unobservable. Symbols contain namespace/name, are not interned, may carry metadata, and are intentionally not hoisted/shared. `jolt-core/jolt/backend_scheme.clj:414-421`; `jolt-core/jolt/backend_scheme.clj:225-230`; `host/chez/hasheq.ss:380-395`
- One-argument `keyword`/`symbol` split qualified strings at the first `/`; symbol construction with a nil namespace normalizes it to the no-namespace sentinel. `host/chez/converters.ss:98-123`; `host/chez/converters.ss:125-162`
- Lists/sequences are persistent eager lists or lazy sequences; vectors are persistent 32-way tries with tails and path-copying; maps/sets are persistent bitmap HAMTs. `test/conformance/SPEC.md:113-128`; `host/chez/collections.ss:34-51`; `host/chez/collections.ss:193-251`
- Vector `conj` shares the prior trie/root where possible and copies only changed paths/tails; `nth`/`assoc`/`pop` are documented as O(log32 n). `host/chez/collections.ss:34-42`; `host/chez/collections.ss:104-164`
- Small maps retain insertion iteration order, promoting to HAMT order past thresholds; sets are always hash-ordered. Equality and hashing are order-independent. `host/chez/collections.ss:293-317`; `host/chez/collections.ss:422-433`
- PersistentQueue is referenced as a supported dispatch class, but its representation, persistence, and sharing implementation are outside the allowed source list. `stdlib/clojure/pprint.clj:2066-2077`
- `=` call sites lower to `jolt=`/`jolt=2`; map keys and collection elements use that mechanism recursively. Same-kind vectors compare positionally, maps by equal key/value entries, and sets by membership. `jolt-core/jolt/op_registry.clj:64-65`; `host/chez/collections.ss:681-705`
- The canonical conformance material documents numeric-category-blind equality for `1` versus `1N`, despite README text claiming category awareness; this conflict is left unresolved. `test/conformance/SPEC.md:19-22`; `test/conformance/known-divergences.edn:77-84`; `README.md:322-323`
- `hasheq` uses signed 32-bit wrapping Murmur3-compatible algorithms. Nil hashes to 0; booleans to 1231/1237; characters to their codepoint; ordered sequentials use ordered hashing, maps/sets unordered hashing. `host/chez/hasheq.ss:1-16`; `host/chez/hasheq.ss:318-346`; `host/chez/hasheq.ss:419-488`
- Integer hashing distinguishes 64-bit-fit and larger exact integers; ratios hash numerator and denominator; doubles hash IEEE-754 bits with special handling for negative zero. `host/chez/hasheq.ss:250-304`; `host/chez/hasheq.ss:444-463`
- `compare` returns exact `-1/0/1`; nil sorts first, then same-category numbers, strings, keywords, symbols, booleans, characters, and equal-length vectors are supported. Unsupported pairs raise ClassCastException unless an extension arm handles them. `host/chez/converters.ss:180-223`
- Metadata is demonstrably supported on symbols, list/vector/map/set values, Vars, atoms, and agents; collection metadata is reattached with runtime `with-meta`, while atom/agent metadata is stored in an identity side table. `jolt-core/jolt/analyzer.clj:1104-1113`; `host/chez/atoms.ss:30-51`; `host/chez/java/concurrency.ss:183-203`
- Exhaustive metadata eligibility is UNKNOWN; the source explicitly states numbers cannot carry metadata. `test/conformance/known-divergences.edn:20-21`

## 3. Error model

- Jolt can throw arbitrary Jolt values; backend conditions preserve the thrown value for catch binding, rethrow, `ex-data`, and cause handling. `jolt-core/jolt/backend_scheme.clj:1155-1167`
- `ex-info` is available in two- and three-argument forms. Analyzer diagnostics use it with structured `{:jolt/error …}` data, including source position where available. `jolt-core/jolt/op_registry.clj:151-154`; `jolt-core/jolt/analyzer.clj:877-896`
- Catch-by-type is ordered and uses runtime `instance?`; broad/untyped host conditions may match through `__catch-broad?`. No match rethrows the original unwrapped value. `jolt-core/jolt/analyzer.clj:316-350`
- Observed named exception classes include IllegalStateException, ClassCastException, IndexOutOfBoundsException, IllegalArgumentException, NullPointerException, UnsupportedOperationException, ExecutionException, RejectedExecutionException, RuntimeException, InterruptedException, and IllegalMonitorStateException; this is not an exhaustive hierarchy. `host/chez/atoms.ss:26-44`; `host/chez/collections.ss:125-152`; `host/chez/java/concurrency.ss:61-69`; `host/chez/java/concurrency.ss:317-325`; `host/chez/java/concurrency.ss:891-909`
- A failed future deref throws ExecutionException with the body failure as cause; cancellation deref instead throws an `ex-info` value with message `"Future cancelled"`. `host/chez/java/concurrency.ss:58-69`
- `future-done?` on a non-future and `deliver` on a non-promise throw `ex-info`; invoking a promise with the wrong arity throws ArityException. `host/chez/java/concurrency.ss:104-108`; `host/chez/java/concurrency.ss:126-136`; `host/chez/java/concurrency.ss:565-572`
- Agent sends after shutdown throw RejectedExecutionException; sends/awaits on failed agents throw RuntimeException; await inside a transaction/action throws IllegalStateException/Exception. `host/chez/java/concurrency.ss:317-344`; `host/chez/java/concurrency.ss:345-352`
- FFI bindings return native results and do not infer failure. Opted-in capture returns `[native-result error-code]`; the caller must interpret failure from the native API's result contract. `docs/ffi-native-error-capture.md:41-61`
- Known POSIX targets capture `errno`, known Windows targets capture `GetLastError`; unknown targets fail expansion rather than guessing. Capture on `:void` and malformed option maps fail at compile time. `docs/ffi-native-error-capture.md:49-59`; `docs/ffi-native-error-capture.md:63-79`

## 4. Reader & literals

- The reader implementation lives at `host/chez/reader.ss`, but that file is outside the enumerated file fence; the compile spine identifies it as the Chez data reader and consumes raw forms through `jolt-read-form-raw`. `README.md:104-109`; `host/chez/compile-eval.ss:1-25`
- Documented accepted syntax includes lists, vectors, maps, sets, anonymous `#()` functions, discard `#_`, reader conditionals `#?`, tagged literals, regex `#"…"`, syntax quote, characters, keywords, symbols, strings, and numeric literals. `README.md:310-321`
- Host-contract literal recognition covers nil, booleans, numbers, strings, keywords, and native characters; regex, set, inst, UUID, and BigDecimal forms have distinct tagged representations. `host/chez/host-contract.ss:43-71`
- Reader conditionals choose the matching branch by default, unlike the JVM requirement for `{:read-cond :allow}`. `test/conformance/known-divergences.edn:185-190`
- Unknown tags in core `read-string` become inert tagged-literal values; strict `clojure.edn` instead applies `:readers`, built-ins, then `:default`, and otherwise throws. `test/conformance/known-divergences.edn:161-166`; `stdlib/clojure/edn.clj:28-46`
- `#=` is documented by conformance as inert data that never evaluates, independent of `*read-eval*`; another runtime file says the reader has no `#=` form at all. Exact accepted shape is therefore an open source conflict. `test/conformance/SPEC.md:174-183`; `host/chez/dynamic-var-defaults.ss:53-59`
- Literal lowering uses host-neutral IR nodes: primitive literals become `:const`; vectors/maps/sets become ordered child nodes; regex/inst/UUID/BigDecimal become source-carrying leaf nodes. `jolt-core/jolt/analyzer.clj:1115-1146`; `jolt-core/jolt/ir.clj:62-67`
- The Chez backend then fixes concrete representations as `jolt-vector`, `jolt-hash-map`, `jolt-hash-set`, and tagged runtime constructors. No selectable compile-time literal representation profile appears in the inspected IR/backend. `jolt-core/jolt/backend_scheme.clj:1315-1341`
- Syntax quote is retained as a compiler special, lowered to construction code, and re-analyzed during compilation; the data-reader path may expand it earlier. `jolt-core/jolt/analyzer.clj:570-572`; `host/chez/host-contract.ss:388-485`; `test/conformance/known-divergences.edn:197-205`
- Reader-built list forms carry line/column/file metadata; macro expansion propagates the call-site position to an unpositioned list expansion. `host/chez/host-contract.ss:157-181`; `host/chez/host-contract.ss:229-253`

## 5. Vars, namespaces, eval

- Vars are interned cells with mutable roots; compiled Var reads consult the innermost dynamic binding first, then special handling for `*ns*`, then the root. Strict `var-get` throws on an unbound root, while compiled reads are lenient. `host/chez/dyn-binding.ss:170-209`
- Dynamic bindings are per-thread stacks of identity-keyed frames. Only Vars whose metadata contains truthy `:dynamic` may be pushed. `host/chez/dyn-binding.ss:1-22`; `host/chez/dyn-binding.ss:43-64`
- `var-set` updates the innermost binding when present, otherwise validates and changes the root; root changes notify Var watches. `host/chez/dyn-binding.ss:115-129`
- Futures explicitly snapshot and install the dynamic-binding stack; user Threads and executor submissions do likewise. Child transactions are cleared. `host/chez/java/concurrency.ss:37-55`; `host/chez/java/concurrency.ss:691-707`; `host/chez/java/concurrency.ss:843-854`
- Namespace resolution uses a global Var table, current compile namespace, aliases/refers, then `clojure.core`; qualified aliases are resolved before Var lookup. `host/chez/host-contract.ss:202-227`
- Documented namespace divergences are permissive: `clojure.core` still resolves despite `:refer-clojure :exclude/:only`, and cross-namespace Var privacy is not enforced. `test/conformance/known-divergences.edn:146-158`
- `eval` and `load-string` are runtime functions backed by the resident compiler. Code-like forms are analyze→passes→emit→Chez `eval`; opaque/non-code values evaluate to themselves. `host/chez/compile-eval.ss:304-311`; `host/chez/compile-eval.ss:351-389`; `host/chez/compile-eval.ss:433-439`
- `load-string` reads and evaluates every raw form in sequence and returns the last value, or nil for no form; compiler dynamic bindings are installed and popped with `dynamic-wind`. `host/chez/compile-eval.ss:396-431`
- Top-level `do` is unrolled into sequential compile/eval operations, so an earlier `def` or `defmacro` affects analysis of later subforms. `host/chez/compile-eval.ss:344-389`
- Macro expansion occurs before special-form/interop/invoke dispatch. Macro expanders run at analysis time with `&form` and lexical `&env` dynamically bound. `jolt-core/jolt/analyzer.clj:1012-1024`; `host/chez/host-contract.ss:267-295`
- IR carries optional source `:pos` only; the complete schema has no macro-expansion provenance, stable site ID, operation/resource ID, or assumption fields. Macro propagation preserves a call-site position, not an expansion lineage. `jolt-core/jolt/ir.clj:100-168`; `host/chez/host-contract.ss:229-253`
- Release/optimized direct-link builds are closed-world: ordinary defs may be frozen/direct-linked, while `^:redef` and `^:dynamic` remain Var-routed. `jolt-core/jolt/main.clj:334-345`; `jolt-core/jolt/backend_scheme.clj:1392-1405`

## 6. Concurrency primitives

- **Atom ownership/state:** each atom owns value, watches, validator, and mutex; shared-heap threads access the same atom. `host/chez/atoms.ss:14-24`
- `swap!` computes outside the mutex, validates before publication, then retries an identity-CAS until successful. Its linearization point is the value store under the atom mutex; the user function may run repeatedly. `host/chez/atoms.ss:79-98`
- `reset!` validates first and linearizes at the store under the mutex. `compare-and-set!` validates first, compares with Jolt value equality—not identity—and linearizes at the conditional store under the mutex. `host/chez/atoms.ss:100-116`
- Watches run after publication in insertion order and outside the mutation lock. A watch throw is unguarded, so publication has already occurred. `host/chez/atoms.ss:65-69`; `host/chez/atoms.ss:87-105`
- Validators run before publication and reject falsey results with IllegalStateException. Installing a validator validates the current value immediately. `host/chez/atoms.ss:26-28`; `host/chez/atoms.ss:59-63`; `host/chez/atoms.ss:155-197`
- Concurrent add/remove-watch and validator replacement have no mutex in the inspected implementation; their race semantics are UNSPECIFIED. `host/chez/atoms.ss:159-197`
- **Future:** `future-call` immediately `fork-thread`s a native shared-heap worker. Worker result/failure and cancellation compete under the future mutex for the one `done?` terminal state. `host/chez/java/concurrency.ss:27-56`
- Cancellation linearizes when it sets `cancelled?` and `done?` under the mutex. It does not interrupt the worker; a late worker result is ignored, so application code may continue after the future is observably cancelled. `host/chez/java/concurrency.ss:49-55`; `host/chez/java/concurrency.ss:91-102`
- Future deref blocks on a condition until terminal; timed deref uses an absolute deadline and returns the supplied timeout value if still unsettled. `host/chez/java/concurrency.ss:71-89`
- **Promise:** delivery is one-shot and linearizes at value plus `delivered?` publication under the mutex. The winner returns the promise; later deliveries return nil. Deref blocks, with a timed form returning the timeout value. `host/chez/java/concurrency.ss:110-154`
- **Delay:** one thread realizes the thunk under a mutex; both successful values and failures are cached, and a cached failure is rethrown without rerunning the body. `host/chez/java/concurrency.ss:505-523`
- **Agent:** each agent has state, error, validator, FIFO queue, running flag, mutex/condition, error mode, and handler. One directly forked worker drains each agent's actions serially and in queue order. `host/chez/java/concurrency.ss:156-168`; `host/chez/java/concurrency.ss:218-257`
- Successful agent state publication occurs at the state store after validation, followed by watch notification. Nested sends are held until action completion and then released in order. `host/chez/java/concurrency.ss:259-310`
- In `:fail` mode an action failure stores the error and halts the queue; in `:continue` mode state remains unchanged and work continues. `restart-agent` may retain or clear queued actions. `host/chez/java/concurrency.ss:273-310`; `host/chez/java/concurrency.ss:398-419`
- `shutdown-agents` rejects future sends but lets already-running workers drain their queues. `send` and `send-off` are identical; executor-setting APIs are no-ops. `host/chez/java/concurrency.ss:170-175`; `host/chez/java/concurrency.ss:313-334`; `host/chez/java/concurrency.ss:575-597`
- Agent fairness is only per-agent FIFO serialization; no cross-agent scheduling or starvation guarantee is stated. `host/chez/java/concurrency.ss:156-163`; `host/chez/java/concurrency.ss:218-229`
- **core.async is present:** channels/go/thread are native OS-thread primitives; go parking operations are ordinary blocking operations. `alts!` uses per-channel locking, ordered priority mode, and a randomized starting port otherwise. `stdlib/clojure/core/async.clj:1-18`; `stdlib/clojure/core/async.clj:29-61`
- Native core.async channel close, buffer, pending operation, and fairness semantics are UNKNOWN because `host/chez/java/async.ss` is outside the enumerated fence. `stdlib/clojure/core/async.clj:1-10`
- **Monitors:** `locking`, `monitor-enter`, and `monitor-exit` share an identity-keyed recursive mutex. `locking` uses `dynamic-wind` to release on normal, exceptional, or continuation exit. `host/chez/java/concurrency.ss:605-638`
- **ReentrantLock:** ownership is by current thread identity with a hold count; non-owner unlock throws. `tryLock` is nonblocking; `lockInterruptibly` polls the thread's interrupt box. `host/chez/java/concurrency.ss:877-923`
- **Threads:** `Thread.start` forks an OS thread, conveys bindings, catches/reports uncaught failures, and signals completion for `join`; `setDaemon` is a no-op and the normal interrupt flag does not forcibly terminate execution. `host/chez/java/concurrency.ss:683-720`
- Executors use a FIFO queue with fixed workers; "cached", "virtual", and work-stealing constructors all map to a fixed 32-worker pool. Shutdown rejects new admission while workers drain the accepted queue; termination requires shutdown, empty queue, and zero workers. `host/chez/java/concurrency.ss:739-842`
- Refs/STM are advertised as present, but their implementation and exact opacity/retry/I/O semantics are outside the allowed file list. `README.md:310-320`

## 7. Simulation/controller hooks

- `host-contract.ss` is an analyzer/reader/namespace seam, not an FFI or scheduler controller: its installed contract contains form predicates, resolution, macro expansion, and compiler optimization registries, but no controller/simulation operations. `host/chez/host-contract.ss:568-632`
- FFI calls are recognized directly by the analyzer as `jolt.ffi/__cfn`/`__ccallable` IR and emitted directly as Chez `foreign-procedure`/`foreign-callable`; no generic interception/controller dispatch appears on this path. `jolt-core/jolt/analyzer.clj:657-746`; `jolt-core/jolt/backend_scheme.clj:572-642`
- Native-error capture is binding-local and explicitly adds no simulator ABI or ambient interception API. `docs/ffi-native-error-capture.md:60-61`; `docs/ffi-native-error-capture.md:81-87`
- A **private, disabled-from-ordinary-images** future lifecycle overlay is documented at `host/chez/sim/runtime.ss`. It exposes lifecycle evidence for external `jolt-sim` but deliberately no public controller ABI or restoration policy. `docs/proofs/sim-worker-exit.md:5-12`; `docs/proofs/sim-worker-exit.md:191-193`
- Documented private lifecycle events are `:spawn`, `:start`, `:finish`, `:exit`, and pre-fork `:abort`; cancellation may settle while the physical worker/body remains active, and successful `:exit` is the drainage acknowledgement. `docs/proofs/sim-worker-exit.md:14-28`; `docs/proofs/sim-worker-exit.md:38-55`
- The private overlay's implementation could not be inspected under the file fence; only its allowed proof record supports these facts. `docs/proofs/sim-worker-exit.md:36-51`
- Debug/lint controls are disabled by default but are not simulation schedulers: `JOLT_TRACE` adds frame-history instrumentation and `JOLT_CHECK` runs warning-only type linting. `host/chez/compile-eval.ss:165-196`; `host/chez/compile-eval.ss:252-271`
- Generic extension points support epoch-invalidated runtime data providers, not execution scheduling, search, faults, replay, or worlds. `host/chez/extensions.ss:1-27`; `host/chez/extensions.ss:269-274`

## 8. UNSPECIFIED / UNKNOWN

- **Reader implementation details:** token grammar, escapes, duplicate detection, dispatch precedence, and exact `#=` parsing cannot be settled without fenced-out `host/chez/reader.ss`; only its contract and documentation were inspected. `host/chez/host-contract.ss:9-14`; `README.md:104-109`
- **Ordinary host-new/method operand order:** emitted Scheme does not force ordering, while Chez application order is declared unspecified. `jolt-core/jolt/backend_scheme.clj:429-432`; `jolt-core/jolt/backend_scheme.clj:1302-1304`; `jolt-core/jolt/backend_scheme.clj:1344-1353`
- **Exact truthiness implementation:** emitted `if` calls `jolt-truthy?`, whose defining runtime file is outside the allowed list. `jolt-core/jolt/backend_scheme.clj:1305-1310`
- **Complete equality/equiv dispatch:** this register establishes the `jolt=` entry point and collection hooks, but the defining scalar/sequential equality code lies in fenced-out runtime files. `jolt-core/jolt/op_registry.clj:64-65`; `host/chez/collections.ss:681-705`
- **Complete exception hierarchy and ExceptionInfo representation:** available operations and observed class names are known, but the throwable/condition definitions are outside the selected files. `jolt-core/jolt/backend_scheme.clj:1155-1167`; `host/chez/java/concurrency.ss:61-69`
- **Queue semantics:** only API/class references were found; queue implementation, sharing, iteration, and empty/pop behavior were not available in the permitted files. `stdlib/clojure/pprint.clj:2066-2077`
- **Exhaustive metadata eligibility:** symbols, collections, Vars, atoms, and agents are evidenced, but function, record, host-object, and all scalar eligibility cannot be exhaustively classified. `jolt-core/jolt/analyzer.clj:1104-1113`; `host/chez/atoms.ss:30-51`
- **Core.async kernel details:** native channel linearization, close/drain, transducer failure, pending-op cancellation, and fairness require fenced-out `host/chez/java/async.ss`. `stdlib/clojure/core/async.clj:1-18`
- **STM details:** README advertises refs/STM, but the defining host files were not in the read fence. `README.md:310-320`
- **Scheduler fairness:** forked futures, agents, Threads, and executor workers rely on Chez/OS scheduling; no bounded-wait or starvation guarantee is stated. `host/chez/java/concurrency.ss:27-56`; `host/chez/java/concurrency.ss:739-842`
- **Concurrent watch/validator mutation:** add/remove/set operations lack an evident mutex in `atoms.ss`; no race contract is documented. `host/chez/atoms.ss:155-197`
- **Generic FFI failure behavior:** non-capturing bindings return native results, but missing-symbol, marshaling, callback-failure, and memory-access exception classes require fenced-out native FFI runtime files. `stdlib/jolt/ffi.clj:40-47`; `jolt-core/jolt/backend_scheme.clj:590-642`
- **Private simulation overlay internals:** answering beyond the proof document would require reading `host/chez/sim/runtime.ss`, which the enumerated fence did not permit. `docs/proofs/sim-worker-exit.md:36-51`

## Divergences from design intent

- **Evaluation order:** intent requires strict deterministic evaluation order; ordinary invocations satisfy it, but host constructor/method emissions use bare Scheme applications even though the backend declares Chez operand order unspecified. This contradiction is reported, not resolved. `JOLT-FORMALIZABLE-APPLICATION-CORE-RESEARCH-PLAN-2026-08-01.md:53`; `jolt-core/jolt/backend_scheme.clj:429-432`; `jolt-core/jolt/backend_scheme.clj:1302-1304`; `jolt-core/jolt/backend_scheme.clj:1344-1353`
- **CSIR/provenance:** intent requires a semantic IR distinct from optimization IR, retaining spans, macro provenance, site/resource IDs, and assumptions. Live code uses one IR annotated by optimization passes and lists only optional `:pos`; no expansion provenance or requested IDs appear in its complete schema. `JOLT-FORMALIZABLE-APPLICATION-CORE-RESEARCH-PLAN-2026-08-01.md:51-55`; `jolt-core/jolt/ir.clj:100-168`
- **Literal representation profiles:** intent calls for abstract literal constructors plus a declared selectable representation profile. Live IR has abstract collection nodes, but the Chez backend directly fixes them to the current persistent constructors and exposes no profile selector. `JOLT-FORMALIZABLE-APPLICATION-CORE-RESEARCH-PLAN-2026-08-01.md:85-95`; `jolt-core/jolt/ir.clj:62-64`; `jolt-core/jolt/backend_scheme.clj:1315-1321`
- **Agents:** intent says agents lower to the replay/simulation task/mailbox kernel rather than unmanaged executors. Live agents directly `fork-thread` one worker per active agent, with no controller seam on that path. `JOLT-FORMALIZABLE-APPLICATION-CORE-RESEARCH-PLAN-2026-08-01.md:109-111`; `host/chez/java/concurrency.ss:248-257`; `host/chez/java/concurrency.ss:278-311`
- **Future lifecycle:** intent requires explicit spawn/start/terminal/ownership/cleanup states. The ordinary future record has only done/cancelled/ok/payload plus synchronization; cancellation can publish terminal while its worker continues, and ownership/cleanup state exists only in the private simulation overlay. `JOLT-FORMALIZABLE-APPLICATION-CORE-RESEARCH-PLAN-2026-08-01.md:109-111`; `host/chez/java/concurrency.ss:27-56`; `host/chez/java/concurrency.ss:91-102`; `docs/proofs/sim-worker-exit.md:5-12`

### Open questions

- Which source is authoritative for numeric `=`: README's category-aware claim or the canonical conformance register's documented category-blind behavior? `README.md:322-323`; `test/conformance/SPEC.md:19-22`; `test/conformance/known-divergences.edn:77-84`
- Does the live reader accept `#=` as inert syntax, or reject it because it has "no `#=`"? The permitted sources state both. `test/conformance/SPEC.md:174-183`; `host/chez/dynamic-var-defaults.ss:53-59`
- Should the charter's "function-call evaluation order" include constructor/static/method interop forms? Their backend behavior differs from ordinary `:invoke`. `jolt-core/jolt/backend_scheme.clj:909-930`; `jolt-core/jolt/backend_scheme.clj:1302-1353`

### Register confidence

- **Section 1 — fully-cited:** ordinary semantics and the interop ordering gap are fixed by analyzer/IR/backend source. `jolt-core/jolt/backend_scheme.clj:429-473`
- **Section 2 — partially-cited:** major representations are grounded; complete scalar equality, queues, and metadata eligibility remain unavailable. `host/chez/collections.ss:34-51`; `host/chez/hasheq.ss:419-488`
- **Section 3 — partially-cited:** throw/catch/finally and major runtime errors are grounded; the full throwable hierarchy is not. `jolt-core/jolt/backend_scheme.clj:1155-1170`
- **Section 4 — partially-cited:** public reader behavior and lowering are grounded, but the fenced-out reader implementation leaves conflicts unresolved. `README.md:310-321`; `host/chez/compile-eval.ss:21-25`
- **Section 5 — fully-cited:** Var bindings, namespace resolution, eval, macro phase, and available IR provenance are directly sourced. `host/chez/dyn-binding.ss:1-22`; `host/chez/compile-eval.ss:304-389`
- **Section 6 — partially-cited:** atoms/futures/promises/delays/agents/locks are direct; core.async kernel and STM internals are unavailable. `host/chez/atoms.ss:79-132`; `host/chez/java/concurrency.ss:27-168`
- **Section 7 — partially-cited:** ordinary FFI routing and absence of public control are direct; private overlay facts rely on its proof document. `docs/proofs/sim-worker-exit.md:36-55`
- **Section 8 — fully-cited as unknown inventory:** each unknown names the inspected boundary or excluded implementation needed. `host/chez/host-contract.ss:9-14`
- **Divergences — fully-cited:** each reports both design intent and conflicting/missing live behavior without proposing resolution. `JOLT-FORMALIZABLE-APPLICATION-CORE-RESEARCH-PLAN-2026-08-01.md:51-57`
- **Overall — partially-cited:** compiler and ordinary concurrency semantics are strong; reader internals, scalar equiv, async kernel, STM, and private simulation internals remain intentionally unspecified. `jolt-core/jolt/ir.clj:100-168`; `README.md:291-308`
