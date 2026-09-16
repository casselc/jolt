module fiber_handoff_test {
  import fiber_handoff.* from "./fiber_handoff"

  val readyQueuedFiberOwned = s.owner == Fiber and s.lifecycle == Ready and s.queued
  val earlyPending = s.owner == Fiber and s.wakePending and s.parkHandoff
  val publishedOnce = s.events.contains(Published) and s.publications == 1
  val pendingDiscarded = s.events.contains(Discarded) and s.cleaned and s.publications == 0
  val dequeued = s.events.contains(Dequeued)
  val dispatched = s.events.contains(Dispatched)
  val parkCommitted = s.events.contains(ParkCommitted)
  val returned = s.events.contains(Returned)
  val closed = s.events.contains(Closed)
  val lateWoken = s.events.contains(LateWake)
  val yielded = s.events.contains(Yielded)
  val preempted = s.events.contains(Preempted)
  val finished = s.events.contains(Finished)
  val cleaned = s.events.contains(Cleaned)
  val doneReached = s.lifecycle == Done
  val deadReached = s.lifecycle == Dead
  val capturedPark = s.parkedOnce and s.continuation == Captured
  val smPark = s.parkedOnce and s.continuation == SmStep

  run normalLifecycleTest = init.then(dequeue).then(dispatch)
    .expect(safety).then(finish(Done)).then(returnToScheduler)
    .then(terminalCleanup).expect(cleanupNoWake and doneReached)

  run validYieldWindowTest = init.then(dequeue).then(dispatch)
    .then(yieldEnqueue(Yielded)).expect(readyQueuedFiberOwned and safety)
    .expect(not(canDequeue(s))).then(returnToScheduler).then(dequeue)
    .then(dispatch).expect(safety)

  run earlyWakePublicationTest = init.then(dequeue).then(dispatch)
    .then(parkCommit(Captured)).then(pendingWake).expect(earlyPending and safety)
    .expect(not(canPublish(s))).then(returnToScheduler).then(publishPending)
    .expect(publishedOnce and safety and not(canPublish(s)) and not(canPendingWake(s)))
    .then(dequeue).then(dispatch)
    .then(finish(Done)).then(returnToScheduler).then(terminalCleanup).expect(safety)

  run terminalPendingDiscardTest = init.then(dequeue).then(dispatch)
    .then(parkCommit(SmStep)).then(pendingWake).then(finish(Dead))
    .expect(s.wakePending and safety).then(returnToScheduler)
    .expect(not(canPublish(s))).then(terminalCleanup)
    .expect(pendingDiscarded and cleanupNoWake and safety)
    .expect(not(canLateWake(s)) and not(canPendingWake(s)))
    .then(terminalCleanup.fail())

  run lateWakeTest = init.then(dequeue).then(dispatch).then(parkCommit(SmStep))
    .then(returnToScheduler).then(closeUnwokenHandoff).then(lateWake)
    .expect(lateWoken and safety and not(canLateWake(s))).then(dequeue).then(dispatch)
    .then(finish(Done)).then(returnToScheduler).then(terminalCleanup).expect(safety)

  // Negative mutation lives only here: the production step never includes it.
  // Replay the old early wake: enqueue while the original fiber still owns execution.
  action buggyEarlyEnqueue = all {
    canPendingWake(s),
    s' = { ...s, lifecycle: Ready, queued: true, head: TargetHead },
  }
  action buggyPreSwitchPark = all {
    s.owner == Fiber, s.queued, s.lifecycle == Ready,
    s' = { ...s, lifecycle: Parked },
  }
  action buggyStep = any { dequeue, dispatch, parkCommit(Captured), buggyEarlyEnqueue }
  run buggyEarlyEnqueueTest = init.then(dequeue).then(dispatch)
    .then(parkCommit(Captured)).then(buggyEarlyEnqueue)
    .expect(not(earlyWakePrivate) and not(safety))
    .then(buggyPreSwitchPark).expect(not(queuedReady) and not(readyHead))

  // Quint 0.32's fail() does not establish a subsequent state frame: use it
  // only at the end of rejection tests, not between further transitions.
  run noFiberOwnedDequeueTest = init.then(dequeue).then(dispatch)
    .then(yieldEnqueue(Preempted)).then(dequeue.fail())
  run noPrematurePublicationTest = init.then(dequeue).then(dispatch)
    .then(parkCommit(Captured)).then(pendingWake).then(publishPending.fail())
  run noSecondPublicationTest = init.then(dequeue).then(dispatch)
    .then(parkCommit(Captured)).then(pendingWake).then(returnToScheduler)
    .then(publishPending).then(publishPending.fail())
  run noTerminalWakeTest = init.then(dequeue).then(dispatch).then(parkCommit(SmStep))
    .then(pendingWake).then(finish(Dead)).then(returnToScheduler)
    .then(terminalCleanup).then(pendingWake.fail())
  run corruptHeadRejectedTest = init
    .then(s' = { ...s, lifecycle: Parked }).then(dequeue.fail())
  run offQueueLinkControlTest = init.then(dequeue)
    .then(s' = { ...s, link: SelfLink }).expect(not(offQueueClear))
}
