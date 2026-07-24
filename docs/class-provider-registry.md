# Declarative lazy class providers

Status: runtime registry implemented; project-metadata collection is
deliberately deferred.

## Purpose and boundary

Jolt already lets a library register Java-shaped constructors, statics,
instance methods, class identity, protocol tags, and `instance?` behavior. The
missing piece was bootstrap order: source such as
`StandardCharsets/US_ASCII` or `Selector/open` can name a compatibility class
before the namespace implementing it has been required.

The runtime now accepts one declarative mapping:

```clojure
(jolt.host/register-class-providers!
 {"java.nio.charset.StandardCharsets" 'jolt.compat.charset
  "java.nio.channels.Selector"         'jolt.compat.nio})
```

A constructor, static, `Class/forName`, or eligible instance-member miss loads
the one mapped namespace and retries the same lookup once. This is a source
reuse adapter over Jolt's platform implementation; it does not make Java or the
JVM the canonical platform API.

Only the mapping function is new public surface. A provider implements its
classes with the existing registration hooks:

- `__register-class-statics!`
- `__register-class-ctor!`
- `__register-class-methods!`
- `__register-instance-check!`
- `__register-class!`

`__register-class-methods!` now also accepts a class-name string. Such methods
are resolved against `value-host-tags`, the same canonical/simple tag source
used by protocol dispatch and `instance?`. Existing built-in methods win; a
class extension fills a member that the built-in type arm declined.

## Runtime invariants

1. **One class, one provider.** Registering the same class/provider pair is
   idempotent. Registering another provider for that class throws structured
   `:class-provider-conflict` data.
2. **Canonical and imported names agree.** A fully qualified declaration
   atomically reserves its simple last segment for the same provider. A
   conflicting simple-name provider fails closed instead of making behavior
   depend on registration order.
3. **One load and one retry.** A lookup that claims an unloaded provider invokes
   `load-namespace` once, then performs one non-recursive retry. A provider that
   loads successfully without registering the requested class/member is marked
   loaded and cannot cause a later retry loop.
4. **No side-effect replay for instance calls.** Instance dispatch does not
   catch arbitrary method exceptions. It retries only when every ordered method
   arm and the base dispatcher return the explicit `pass` miss sentinel.
5. **Cycles are errors, not partial success.** Provider loads track a
   per-thread stack. Re-entry reports:

   ```clojure
   {:jolt/error
    {:type :class-provider-cycle
     :provider "provider.a"
     :path ["provider.a" "provider.b" "provider.a"]}}
   ```

6. **Concurrent callers join.** One thread owns a provider load. Other threads
   wait for its completion and retry their own lookup; they do not run the
   provider body concurrently.
7. **A failed namespace load remains recoverable.** Failure clears the in-flight
   state and wakes waiters. The failing lookup propagates its original error; a
   later independent lookup may try again after source or dependency state is
   repaired.
8. **Class identity remains honest.** Provider mapping alone does not claim a
   value has a Java class. Providers must still register `class`, protocol-tag,
   and `instance?` behavior using the existing hooks.

The existing core-owned `java.time` autoload remains separate and unchanged.
Its RFC 0008 dependency hint and once-only `jolt.time.base` behavior still run
before a generic missing-class diagnostic. This slice does not migrate it onto
the provider registry.

## Source and AOT loading

The implementation is a literal top-level load:

```scheme
(load "host/chez/java/class-providers.ss")
```

in `host/chez/java/host-static.ss`. This is intentional. Jolt's runtime
flattener and self-contained `joltc` resource collector follow literal
top-level loads; a conditional or computed load would leave built programs
dependent on checkout source files.

`host/chez/build.ss` adds every provider namespace registered while the entry
namespace loads to the application require closure. This covers a common lazy
shape:

```clojure
(ns app.main (:require [compat.catalog]))

(defn -main [& _]
  ;; First use occurs after the build driver has finished loading app.main.
  (println OptionalJavaClass/VALUE))
```

Without the provider-closure step, source mode would work but the standalone
binary would contain the mapping and omit the namespace body. Provider closure
is dependency ordered and deterministic. Catalog namespaces required by the
application are emitted before the providers they name. In a closed AOT binary,
provider top-level forms are consequently initialized before `-main`; this is
why the smoke fixture observes counts `[0 ...]` in source mode and `[1 ...]` in
the built binary, with both remaining exactly one after use.

A catalog must register mappings at namespace top level so the build driver can
see them. Registration hidden inside `-main` is too late to define a closed
build graph.

## Source anchors

- Registry, conflict handling, load state, concurrency join, and cycle data:
  `host/chez/java/class-providers.ss`
- Constructor/static bounded retry and preserved `java.time` autoload:
  `host/chez/java/host-static.ss`
- `Class/forName` bounded retry:
  `host/chez/java/host-static-methods.ss`
- Clojure registration surface and class-tagged extension methods:
  `host/chez/java/host-static-classes.ss`
- Instance miss sentinel and exactly-one redispatch:
  `host/chez/records.ss`
- Provider namespace inclusion and dependency order for standalone builds:
  `host/chez/build.ss`

## Executable controls

`make classproviders` runs three bounded lanes:

1. Source mode through a local dependency:
   - static and constructor providers;
   - a missing member added to built-in `ByteBuffer`;
   - `Class/forName` plus `StandardCharsets/US_ASCII`;
   - identical/conflicting declarations;
   - no mapping;
   - a provider that loads but omits the class;
   - an A -> B -> A provider cycle.
2. `jolt.deps/add-deps` adds the provider library to a live process, after which
   the same catalog and lazy static lookup work.
3. When Chez development files and a C compiler are available, a standalone
   build proves all mapped provider namespaces appear in `flat.ss`, deletes the
   source fixture, and runs the binary from `/`.

The representative compatibility manifest is
`test/chez/class-provider-lib/src/cpfixture/catalog.clj`. It deliberately
contains the real `java.nio.charset.StandardCharsets` and
`java.nio.ByteBuffer` spellings alongside synthetic classes that make load and
failure counts observable.

Reproduction:

```sh
make classproviders

JOLT_PWD=test/chez/class-provider-app \
  JOLT_AOT_CACHE=0 \
  bin/joltc -M:test errors

JOLT_PWD="$PWD" \
  JOLT_AOT_CACHE=0 \
  bin/joltc run test/chez/class-provider-add-deps.clj
```

## Deferred project plumbing

The intended project-level spelling remains:

```clojure
:jolt/class-providers
{"java.nio.channels.Selector"      jolt.compat.nio
 "java.nio.channels.SocketChannel" jolt.compat.nio}
```

Dependency resolution should collect those maps across the resolved graph and
call `jolt.host/register-class-providers!` before application namespaces are
compiled. It must use the runtime's identical-or-conflict rule and add provider
namespaces to the build closure. This slice does not edit `jolt.deps`, because
the Git cache and Windows process work are active in another worktree. Until
that plumbing lands, a small required catalog namespace provides the same
runtime and AOT semantics.

## Deferred Teensyp and Capra surface

This registry solves load order, not the compatibility implementations. The
next independent core slices remain:

- `ByteBuffer.compact` plus strict position/limit/capacity and bulk bounds;
- a production `StandardCharsets` provider (the test provider is only a
  mechanism fixture);
- `ThreadLocal`, `TimeUnit`, bounded queues/sets, condition variables, and
  park/unpark contracts;
- streaming IO and file-channel members needed by Ring;
- an optional NIO channel/selector provider backed by `jolt-net`.

Original Teensyp and Capra also retain transport-lifecycle and HTTP-framing
differences documented by the ecosystem audit. The compatibility path should
remain an adapter and differential test target until those upstream behaviors
match the hardened `jolt-tcp` and `jolt-http` invariants.
