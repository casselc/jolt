# Lazy monitor waiting machinery

Uncontended StringWriter/StringBuffer synchronization needs the monitor's owner
word, not two native condition variables. This candidate leaves the owner word,
backing mutex, reentrant count and fiber wake protocol unchanged. It creates
the entry condition only when a native thread waits to enter, and the separate
Object.wait condition before publishing an Object.wait waiter.

Both installations happen while holding the same backing mutex used by every
corresponding enqueue, release and notification. An installed condition is never
replaced. A release with no entry condition has no native entry waiter to wake;
fiber contenders still use their existing list and resume path.

The important implementation obligations are:

- A native entry waiter installs its condition before atomically releasing the
  backing mutex in condition-wait.
- Object.wait installs its separate condition before adding a waiter or giving
  up monitor ownership, under the notifier's backing mutex.
- Broadcast skips an absent entry condition only; it does not skip fiber wakes
  or an existing Object.wait notification.
- The two wait sets retain distinct condition identities.

The existing Prolog model checks owner-word exclusion, waiter coverage and
progress, and rejects its fast-exit mutant. It does not model lazy allocation
or the complete Object.wait implementation. Treat initialization as an internal
step preserving its owner-word state only under the source obligations above;
this is a source-level abstraction argument, not a mechanized refinement proof.

The focused source gate exercises absent conditions on fresh/uncontended
monitors, stable identity, actual Object.wait timeout/depth restoration and a
blocked native contender awakened by release. Existing monitor/fiber and
interrupt-escape gates remain necessary. Passing these is not complete
cross-platform or end-to-end Durable qualification.

Constructor-only measurements suggest less allocation, but do not qualify
throughput. Promote only after a compiled-runtime comparison of the actual
projection/encoding and persistence workload, with unchanged output and
recovery checks. Do not remove synchronization to recover performance.
