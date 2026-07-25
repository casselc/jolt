# Declarative class providers

Status: implemented for source execution, `add-deps`, and closed standalone
builds.

## Purpose and boundary

Jolt libraries can already register Java-shaped constructors, statics, instance
methods, class identity, protocol tags, and `instance?` behavior. Class
providers solve the remaining bootstrap problem: source can name an optional
compatibility class before the namespace implementing it has been required.

A project or dependency declares exact class ownership in `deps.edn`:

```clojure
{:jolt/class-providers
 {"java.nio.charset.StandardCharsets" jolt.compat.charset
  "java.nio.channels.Selector"         jolt.compat.nio}}
```

`jolt.deps` collects these declarations from the complete dependency graph. It
keeps each declaration's project/dependency origin, deduplicates identical
declarations, and rejects different providers for one class before changing
source roots. Reconciliation sorts by class and provenance first, so conflict
diagnostics are identical regardless of dependency declaration/traversal order.
Project launch registers the reconciled map before native
libraries and source roots; `jolt.deps/add-deps` does the same before exposing
its added roots. No catalog namespace is required.

A constructor, static, `Class/forName`, or eligible instance-member miss loads
the one mapped namespace and repeats that exact lookup once. This is a source
reuse adapter over Jolt's platform implementation. It neither introduces a JVM
nor makes Java interop the canonical cross-platform API.

Providers use the existing registration hooks:

- `__register-class-statics!`
- `__register-class-ctor!`
- `__register-class-methods!`
- `__register-class-supers!`
- `__register-instance-check!`
- `__register-class!`
- the equality, hashing, comparison, and rendering registration hooks

The public `jolt.host/register-class-providers!` function remains useful for
REPL and test setup, but resolved `deps.edn` metadata is the authority for a
closed build.

## Exact class identity and imports

Provider keys must be canonical fully qualified class names. The runtime
provider table has no last-segment fallback. This is necessary for two
dependencies to model, for example, `java.nio.ByteBuffer` and
`com.acme.ByteBuffer` without sharing constructors or members.

`import` is now represented by a namespace-local table:

```text
(compiling namespace, simple name) -> canonical class name
```

The reader and analyzer use one resolver for constructor sugar, `new`, static
slash forms, static dot forms, class values, type hints, and syntax-quoted class
tokens. Interop IR therefore carries the canonical class name instead of a
process-global short alias. Two namespaces may import different classes with
the same simple name. Importing both under one simple name in one namespace
throws structured `:class-import-conflict` data. Import forms are preflighted as
one batch, so a rejected multi-import leaves no prefix of namespace mappings
behind and a corrected compilation can retry cleanly.

Core retains a bounded compatibility path for old built-in shims such as
`Files`, `Paths`, and `URLEncoder` that were historically registered only by a
short spelling and have no modeled hierarchy entry. That path preserves the
short token; it does not guess a package. Explicit imports and provider-owned
classes always resolve before it.

## Runtime coordination invariants

1. **One exact class, one provider.** Repeating an identical declaration is
   idempotent. A different provider for that canonical class fails with
   `:class-provider-conflict`. Whole-map registration preflights every entry, so
   a conflicting batch installs none of its new mappings, including when
   provider code catches the conflict and its surrounding namespace evaluation
   later succeeds.
2. **One active evaluation graph.** Provider namespace evaluation is
   process-wide serialized. Its owner may recursively load another provider;
   other threads wait at a stable-registry boundary. This intentionally favors
   deterministic startup over parallel provider initialization.
3. **Cycles fail explicitly.** Re-entry by the owner reports a bounded provider
   path:

   ```clojure
   {:jolt/error
    {:type :class-provider-cycle
     :provider "provider.a"
     :path ["provider.a" "provider.b" "provider.a"]}}
   ```

4. **Registrations publish after successful evaluation.** Provider-owned
   constructor, static, method, hierarchy, class, instance, and value-semantics
   mutations are staged while the namespace evaluates. A source exception
   discards the stage. Commit snapshots the registries reachable through those
   hooks and restores the snapshot if an operation throws, while class-provider
   lookup callers remain behind the stable-registry boundary. Arbitrary
   application side effects are not transactional; provider namespaces should
   keep top-level work limited to registration.
5. **Concurrent failure is shared.** A caller blocked behind an evaluation that
   attempted its provider receives that attempt's error. It does not
   immediately start a second attempt and replay provider top-level effects.
   A later independent lookup may retry a failed provider.
6. **Successful omission is terminal.** A provider that loads successfully but
   does not register the requested class/member is marked loaded. Later misses
   do not recurse or reload it.
7. **Instance calls are not replayed.** Instance dispatch retries only after
   every ordered method arm returns the explicit miss sentinel. It does not
   catch and replay an arbitrary user-method exception.
8. **Class identity remains honest.** A provider mapping alone does not make a
   value an instance of that class. The provider must register class tags and
   `instance?` behavior for its values.

The core-owned `java.time` autoload remains separate. Its once-only
`jolt.time.base` behavior still runs before the generic provider/missing-class
path.

## Closed builds without an artifact cache

Class providers are explicit `jolt build` inputs, alongside source roots and
native declarations:

1. `jolt.main` resolves the project and passes its reconciled provider map to
   the build host function.
2. The build discards ambient REPL/`add-deps` provider state and installs only
   that map.
3. It freezes the exact sorted map and registry generation before loading the
   entry namespace. A mapping change while the application loads aborts the
   build with an instruction to declare every provider in `deps.edn`.
4. Every declared provider namespace must exist. Its static require closure is
   included even when first class use occurs only inside `-main`.
5. The frozen map is emitted into the standalone program before application
   forms.

This design does not depend on the removed per-namespace AOT artifact cache.
The build's source graph and provider metadata form one closed transaction.

A flat standalone program initializes its included provider namespace forms
before `-main`. Consequently provider registration is lazy in source execution
but eager in a standalone binary. Provider namespaces must keep heavyweight or
native work behind callable functions rather than performing it at top level.
They also must not create undeclared provider mappings dynamically; those do
not define a reproducible closed graph.

## Source anchors

- Provider table, coordinator, staging, shared failures, and diagnostics:
  `host/chez/java/class-providers.ss`
- Namespace-local imports and canonical resolution: `host/chez/ns.ss`,
  `host/chez/reader.ss`, `host/chez/compile-eval.ss`
- Canonical analyzer IR: `jolt-core/jolt/analyzer.clj`
- Static/constructor/member retry and registration hooks:
  `host/chez/java/host-static.ss`,
  `host/chez/java/host-static-classes.ss`,
  `host/chez/java/host-static-methods.ss`
- Dependency traversal, provenance, reconciliation, and `add-deps`:
  `jolt-core/jolt/deps.clj`
- Project launch/build plumbing: `jolt-core/jolt/main.clj`
- Closed provider closure and frozen metadata: `host/chez/build.ss`

## Executable controls

`make classproviders` covers:

- source mode through a local dependency;
- transitive provider metadata with no catalog require;
- namespace-local same-simple-name imports;
- atomic import-conflict rollback followed by a successful corrected retry;
- canonical constructor, static, `new`, hint, and syntax-quote forms;
- a successful concurrent provider joined exactly once;
- a concurrent failed provider whose error is shared and whose staged static
  registration does not leak;
- a commit-time failure after a staged static, proving rollback of the published
  prefix and a clean later namespace retry;
- identical/conflicting declarations, atomic global and provider-local
  registration batches, a successful omission, no mapping, and a provider
  cycle;
- dependency-conflict provenance and stable diagnostics under reversed
  declaration order, before source-root mutation;
- `jolt.deps/add-deps` registration before new roots;
- a standalone build whose provider closure remains runnable after fixture
  source is removed.

Run with the selected Chez toolchain:

```sh
CHEZ=/path/to/chez \
JOLT_CHEZ_CSV=/path/to/lib/csv10.4.1/ta6le \
make classproviders

CHEZ=/path/to/chez make unit
CHEZ=/path/to/chez make corpus
```

The unit harness deliberately loads `host/chez/java/ffi.ss` after the loader
snapshot, matching `cli.ss`. Strict canonical resolution exposed that omission:
the old arbitrary-qualified-symbol fallback had allowed `ffi/load-library` to
compile as a fictitious Java static instead of resolving the real `jolt.ffi`
var.

## Deferred compatibility implementations

This mechanism does not itself implement TeensyP or Capra facades. Follow-on
work may provide selected Java-shaped classes over Jolt's native bytes, I/O, and
network facilities, but those providers remain adapters and differential-test
targets. `FileInputStream`, `ByteBuffer`, and other concrete compatibility
facades are intentionally outside this slice.
