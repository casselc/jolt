# Lazy backing-mutex publication

An uncontended monitor uses its owner word, not its backing mutex. This candidate
leaves that mutex absent until a slow path, Object.wait or query needs it.
Every consumer obtains it through monitor-backing-mutex!, not a direct slot read.

A cold caller constructs one candidate mutex, releases before CAS publication,
and returns it only if CAS installs it. A loser acquires and returns the published
winner. Weak CAS may fail spuriously with no winner; retry reuses the same local
candidate instead of allocating another mutex. Once installed, the slot is never
replaced or cleared.

Safety depends on the existing atomic pointer-CAS and release/acquire contracts.
All contenders must use the installed pointer before acquiring or waiting on it.
Losing candidates are never used as locks and are reclaimed normally. Progress
assumes weak CAS does not fail forever; no finite test proves that assumption.

The old owner-word model treats the backing mutex as one fixed lock and does not
model this publication mechanism. The source obligation is that initialization
refines that one-lock assumption: every returned pointer is the same installed
winner. Focused tests force spurious failure and losing publication, then race
four actual cold readers before anyone can publish. Existing ownership, real
contention, wait-depth and interrupt-cleanup gates remain necessary.

This is not a mechanized memory-order proof or complete cross-platform/Durable
qualification. Keep safe publication, cleanup and callbacks intact; select this
candidate only after compiled workload and persistence/recovery checks.
