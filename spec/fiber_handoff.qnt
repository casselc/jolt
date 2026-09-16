module fiber_handoff {
  // A single fiber and its pinned carrier share this record. Queue mutation
  // and park/wake decisions are atomic at the carrier mutex boundary, but
  // execution ownership does not transfer until returnToScheduler.
  type Lifecycle = Ready | Running | Parked | Done | Dead
  type Owner = Fiber | Carrier
  type Head = TargetHead | EmptyHead
  type Link = ClearLink | SuccessorLink | SelfLink
  type Continuation = NoContinuation | Captured | SmStep
  type Event = Dequeued | Dispatched | ParkCommitted | PendingWake | Returned |
    Published | LateWake | Yielded | Preempted | Finished | Cleaned | Discarded | Closed
  type State = {
    lifecycle: Lifecycle, owner: Owner, queued: bool, head: Head, link: Link,
    parkHandoff: bool, wakePending: bool, continuation: Continuation,
    publications: int, parkedOnce: bool, yieldedOnce: bool, cleaned: bool,
    events: Set[Event],
  }
  var s: State
  pure def terminal(x: State): bool = x.lifecycle == Done or x.lifecycle == Dead
  pure val initial: State = {
    lifecycle: Ready, owner: Carrier, queued: true, head: TargetHead,
    link: ClearLink, parkHandoff: false, wakePending: false,
    continuation: NoContinuation, publications: 0, parkedOnce: false,
    yieldedOnce: false, cleaned: false, events: Set(),
  }
  pure def canDequeue(x: State): bool =
    x.owner == Carrier and x.queued and x.head == TargetHead and x.lifecycle == Ready
  pure def afterDequeue(x: State): State = {
    ...x, queued: false, head: EmptyHead, link: ClearLink,
    events: x.events.union(Set(Dequeued)),
  }
  action init = s' = initial
  action dequeue = all { canDequeue(s), s' = afterDequeue(s) }
  pure def canDispatch(x: State): bool = x.owner == Carrier and
    not(x.queued) and x.lifecycle == Ready and not(x.parkHandoff)
  pure def afterDispatch(x: State): State = {
    ...x, owner: Fiber, lifecycle: Running,
    events: x.events.union(Set(Dispatched)),
  }
  action dispatch = all { canDispatch(s), s' = afterDispatch(s) }
  pure def canPark(x: State): bool = x.owner == Fiber and
    x.lifecycle == Running and not(x.queued) and not(x.parkedOnce)
  pure def afterPark(x: State, k: Continuation): State = {
    ...x, lifecycle: Parked, parkHandoff: true, parkedOnce: true,
    continuation: k, events: x.events.union(Set(ParkCommitted)),
  }
  action parkCommit(k: Continuation): bool = all {
    canPark(s), k == Captured or k == SmStep, s' = afterPark(s, k),
  }
  pure def canPendingWake(x: State): bool =
    x.lifecycle == Parked and x.parkHandoff and not(x.wakePending)
  pure def afterPendingWake(x: State): State = {
    ...x, wakePending: true, events: x.events.union(Set(PendingWake)),
  }
  action pendingWake = all { canPendingWake(s), s' = afterPendingWake(s) }
  pure def canReturn(x: State): bool = x.owner == Fiber and
    (x.lifecycle == Parked or x.lifecycle == Ready or terminal(x))
  pure def afterReturn(x: State): State = {
    ...x, owner: Carrier, events: x.events.union(Set(Returned)),
  }
  action returnToScheduler = all { canReturn(s), s' = afterReturn(s) }
  pure def canPublish(x: State): bool = x.owner == Carrier and
    x.lifecycle == Parked and x.parkHandoff and x.wakePending
  pure def afterPublish(x: State): State = {
    ...x, lifecycle: Ready, queued: true, head: TargetHead,
    parkHandoff: false, wakePending: false, publications: x.publications + 1,
    events: x.events.union(Set(Published)),
  }
  action publishPending = all { canPublish(s), s' = afterPublish(s) }
  pure def canClose(x: State): bool = x.owner == Carrier and
    x.lifecycle == Parked and x.parkHandoff and not(x.wakePending)
  pure def afterClose(x: State): State = {
    ...x, parkHandoff: false, events: x.events.union(Set(Closed)),
  }
  action closeUnwokenHandoff = all { canClose(s), s' = afterClose(s) }
  pure def canLateWake(x: State): bool = x.owner == Carrier and
    x.lifecycle == Parked and not(x.parkHandoff)
  pure def afterLateWake(x: State): State = {
    ...x, lifecycle: Ready, queued: true, head: TargetHead,
    events: x.events.union(Set(LateWake)),
  }
  action lateWake = all { canLateWake(s), s' = afterLateWake(s) }
  pure def canYield(x: State): bool = x.owner == Fiber and
    x.lifecycle == Running and not(x.queued) and not(x.yieldedOnce)
  pure def afterYield(x: State, e: Event): State = {
    ...x, lifecycle: Ready, queued: true, head: TargetHead,
    continuation: Captured, yieldedOnce: true, events: x.events.union(Set(e)),
  }
  action yieldEnqueue(e: Event): bool = all {
    canYield(s), e == Yielded or e == Preempted, s' = afterYield(s, e),
  }
  pure def canFinish(x: State): bool = x.owner == Fiber and not(x.queued) and
    (x.lifecycle == Running or x.lifecycle == Parked)
  pure def afterFinish(x: State, outcome: Lifecycle): State = {
    ...x, lifecycle: outcome, continuation: NoContinuation,
    events: x.events.union(Set(Finished)),
  }
  action finish(outcome: Lifecycle): bool = all {
    canFinish(s), outcome == Done or outcome == Dead, s' = afterFinish(s, outcome),
  }
  pure def canClean(x: State): bool =
    x.owner == Carrier and terminal(x) and not(x.cleaned)
  pure def afterClean(x: State): State = {
    ...x, parkHandoff: false, wakePending: false, cleaned: true,
    continuation: NoContinuation,
    events: x.events.union(if (x.wakePending) Set(Cleaned, Discarded) else Set(Cleaned)),
  }
  action terminalCleanup = all { canClean(s), s' = afterClean(s) }
  action step = any {
    dequeue, dispatch, parkCommit(Captured), parkCommit(SmStep), pendingWake,
    returnToScheduler, publishPending, closeUnwokenHandoff, lateWake,
    yieldEnqueue(Yielded), yieldEnqueue(Preempted), finish(Done), finish(Dead), terminalCleanup,
  }
  val queuedReady = s.queued implies s.lifecycle == Ready
  val offQueueClear = not(s.queued) implies s.link == ClearLink
  val earlyWakePrivate = s.parkHandoff implies not(s.queued)
  val atMostOncePublication = s.publications <= 1
  val readyHead = s.head == TargetHead implies s.queued and s.lifecycle == Ready
  val cleanupNoWake = s.cleaned implies
    terminal(s) and not(s.queued) and not(s.wakePending) and not(s.parkHandoff)
  val pendingNotPublished = s.wakePending implies
    s.parkHandoff and not(s.queued) and s.publications == 0
  val safety = queuedReady and offQueueClear and earlyWakePrivate and
    atMostOncePublication and readyHead and cleanupNoWake and pendingNotPublished
}
