# StringBuffer monitor identity

The concrete runtime StringBuffer already owns its state and monitor. Creating
that monitor directly avoids a global weak-table insertion and lock acquisition
for every StringWriter backing buffer. It does not remove synchronization.

The constructor creates fresh state, stores its buffer owner and monitor before
returning the object, and never changes those ownership fields through public
content methods. Object monitor lookup recognizes only the concrete buffer tag,
eight-slot state and matching owner. Other objects and unrecognized shapes keep
the ordinary weak-table path.

StringWriter is intentionally different: its methods synchronize on its backing
buffer, but locking the writer object itself uses the writer's separate Object
monitor. Object.wait/notify on a buffer resolve its attached monitor, so they
compose with buffer locking and writer method calls.

Ownership fields are private runtime representation, not a supported mutation
API. Content changes and the private JSON replacement seam preserve them. This
optimization does not authorize replacing native ownership fields after an
object is published or sharing a serial JSON factory concurrently.

The existing owner-word model starts with a monitor and does not prove mapping
from objects to monitors. The additional source obligation is one stable monitor
per published buffer, with public lookup and method synchronization resolving
the same pointer. Focused gates check that identity, writer/buffer separation,
replacement and Object.wait restoration, generic fallback, and a real writer
append blocked until another thread releases the buffer monitor. Source review
and these gates are not complete cross-platform or Durable qualification.
