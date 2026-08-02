# P3 — First Proof Target Design

**Provenance:** `formal-methods` subagent, session `ses_03ffb4ccbffeEMPcSVPkOGLMRK`,
model `openai/gpt-5.6-terra` (high), 2026-08-01 (post-restart).
**Inputs:** P1 register, research plan, gradual-formalism vision, jolt-sim
architecture review, `jolt-sim` kernel/trace/monitor source, P4 matrix,
`prove-code-invariants` discipline.
**Status:** UNREVIEWED working report; no solver, explorer, build, or test was
executed — every element is labeled accordingly.

---

# First Proof Target Design

**Research status:** read-only design; no builds, tests, solver runs, or git operations performed.  
**Evidence labels:** `[assumed]` = source/design premise not executed here; `[failed]` = expected known-bug control; `[bounded-complete]` only after an uncapped-by-result BFS exhausts the declared finite graph; `[monitored]` only for a validated trace fold; `[sampled]` for Hegel/corpus runs.

## 1. Target selection

### Recommended: capacity-one mailbox — send, receive, close `[assumed]`

Use a pure two-task cooperative mailbox model with capacity one, fixed messages `[:a :b]`, and no timeout.

Why this first:

- It is the smallest target that uses kernel state identity, enabled-action branching, blocked-versus-completed classification, replay, and a trace monitor without trusting an ordinary-runtime adapter.
- `kernel/machine`, `machine-actions`, `machine-apply`, canonical budget-bearing projections, and deterministic BFS already exist; BFS branches all actions and reports `:completed`, `:state-limit`, or shortest witnesses. (`kernel.clj:445-621`; `explore_states.clj:1-26`) `[assumed]`
- It is a pure model only: P1 says native `core.async` channel semantics and scheduler fairness are unknown, and ordinary runtime hooks do not provide a general controller seam. (`P1 §§6–8`) `[assumed]`
- It establishes capacity, blocked send/receive, drain-after-close, and close behavior before timer/cancellation races.

**No timeout initially.** Timeout adds virtual-time ownership, deadline semantics, and same-tick tie policy. Those are valuable follow-on obligations, but not necessary for the smallest send/receive/close claim. The existing timer/reply/cancel cleanup fixture demonstrates that the kernel can support that later shape, but it is not an implementation claim about Jolt channels. (`explore_states_test.clj:273-414`) `[assumed]`

**Maelstrom tension.** The supplied architecture review recommends this mailbox shape before broadening hooks, while also calls Maelstrom expansion scope drift. (`architecture review:233-250`) The alleged separate Maelstrom-plan deprioritization is outside the read fence: **UNKNOWN**. Reconciliation: this is a test-only cooperative-kernel proof target, not a Maelstrom feature, protocol commitment, or runtime-hook priority.

### Alternative: bounded canonical equality/hash consistency `[assumed]`

Enumerate a small canonical value domain and check `x = y ⇒ hash(x) = hash(y)`. It is pure and adapter-free, but is not first because it does not naturally exercise blocked/deadlock/quiescence distinctions or scheduling replay/monitor semantics. Further, P1 records unresolved scalar equality coverage and a conflict over numeric equality. (`P1 §2, lines 50-53, 140, 161`) `[assumed]`

## 2. Recommended target: finite relation and controls

### Exact bounded claim `[assumed]`

For every reachable state of the declared mailbox transition system, starting empty and open:

1. the slot contains zero or one message;
2. delivered messages are a prefix of accepted messages;
3. once closed, no send transition is enabled;
4. every completed run has `accepted = delivered = [:a :b]`, an empty slot, and `open? = false`;
5. a blocked task with another runnable task is nonterminal, while all-blocked/no-timer is `:deadlock`, and all-completed is successful quiescence (`:completed`).

**State variables**

```clojure
{:tasks {0 producer-control 1 consumer-control}
 :world {:open? boolean
         :slot nil|:a|:b
         :accepted [prefix of [:a :b]]
         :delivered [prefix of [:a :b]]}
 :now 0
 :steps 0..7
 :max-steps 7}
```

Task 0 executes `send :a`, `send :b`, then `close`.  
Task 1 receives `:a`, receives `:b`, then observes closed-and-empty.  
A full slot blocks the producer; an empty open slot blocks the consumer; send/take/close explicitly wake the counterpart where applicable.

**Transition relation**

- `send m`: enabled iff `open?` and `slot=nil`; installs `m`, appends `m` to `accepted`.
- `receive`: enabled iff `slot` is nonempty; removes it, appends it to `delivered`.
- `close`: changes only `open?` from true to false; it preserves a buffered item.
- `receive` on closed-and-empty completes the consumer.
- Kernel actions are every `[:run task-id]` enabled by `machine-actions`; no timer action exists.
- A path has at most seven task transitions; there are no host effects, entropy, clocks, closed-over mutation, I/O, or raw threads.

**State identity/canonicalization.** Identity is exactly `kernel/machine-projection`: canonicalized `{:tasks :world :now :steps :steps :max-steps}`, excluding trace and step function. Budget is retained because it affects enabled actions/status. (`kernel.clj:513-528`) `[assumed]`

**Bounds and quantification.** Quantify over all BFS-reachable canonical states under messages `[:a :b]`, two tasks, capacity one, and `max-steps=7`. No partial-order reduction or symmetry reduction is permitted. This is not a claim about arbitrary Jolt code, native channels, or unbounded mailbox behavior.

### Negated property / violation query `[assumed]`

The explorer invariant returns canonical evidence iff any of:

```text
slot not in {nil :a :b}
or count(slot) > 1
or delivered is not a prefix of accepted
or closed and a send transition is enabled
or status = :completed and
   (accepted != [:a :b] or delivered != [:a :b]
    or slot != nil or open? != false)
or status = :step-limit
or status = :deadlock
```

The state-cap outcome is not a violation witness and is never a pass.

### Buggy known-SAT control `[failed — expected]`

Fault only `close`: if the slot is full, set it to `nil` while closing.

Expected shortest witness:

```text
[:run producer-send-a
 :run consumer-receive-a
 :run producer-send-b
 :run producer-close-buggy
 :run consumer-receive-b]
```

At the final action, the consumer observes closed-and-empty after `accepted=[:a :b]` and `delivered=[:a]`; the prefix/completed-state invariant fires. It must occur within five transitions, hence within the seven-transition bound. The same invariant schema—not a special test—is used for this control.

### Corrected control `[bounded-complete after execution; currently assumed]`

Correct `close` preserves `:b` in the slot. Explore with the same invariant and finite relation. Required result:

```clojure
{:status :completed ...} ; no :witness
```

`:state-limit` is inconclusive/failed evidence, not a successful result. A completed BFS is bounded-complete only for this finite relation and stated assumptions.

### Non-vacuity control `[bounded-complete after execution; currently assumed]`

Require all of the following from the corrected exploration:

- status `:completed`, never `:state-limit`;
- at least one reachable blocked-consumer state with runnable producer;
- at least one reachable blocked-producer/full-slot state;
- a path where close precedes receipt of `:b`, proving close drains rather than discards;
- a path where receipt of `:b` precedes close;
- one completed terminal projection with both messages delivered;
- separately, a direct all-blocked/no-timer fixture classified `:deadlock`, distinct from the completed mailbox run.

Record exact `:visited`, terminal counts, and edge/action count in the proof record. The current explorer reports visited-state and terminal counts but not considered-edge count; add that count before claiming the non-vacuity metric. **Exact counts are UNKNOWN**: source tests for the existing different timer/cancel model assert only `4 < visited < 500` and three completed terminals, and no execution was permitted here. (`explore_states_test.clj:366-385`) `[assumed]`

### Replay, monitor, and permanent regression `[sampled/monitored after execution]`

For each named valid path and the buggy witness:

1. run the pure kernel with `strategy/scripted` task choices;
2. persist the canonical trace, model version, bounds, and action path;
3. require `kernel/replay` to reproduce the exact event trace;
4. require `monitor/check-trace-grammar` over `monitor/document(trace)` to return `:pass`;
5. make the buggy path a literal regression: assert the corrected model delivers `[:a :b]`, while a test-local faulty close produces the named loss evidence.

`kernel/replay` validates choice enabled sets and all projected events; monitor validation is a fold over a structurally validated trace. (`kernel.clj:667-698`; `monitor.clj:100-146,279-295`) A monitor pass is **monitored**, not proof of liveness.

### Assumptions, progress, and omissions `[assumed]`

- No fairness assumption is used: BFS enumerates all enabled finite actions.
- No liveness/unbounded progress claim is made.
- `:completed` is model quiescence; `:deadlock` is a distinct terminal classification.
- Omitted: timeout/timer ties, cancellation, dynamic values, multiple producers/consumers, unbounded queues, host scheduling, `core.async`, FFI, and runtime refinement.
- The proof target can execute today using existing `jolt-sim` cooperative kernel and `explore-states`; it needs only a new pure fixture, record, and regression tests—not compiler or runtime-adapter work. (`README.md:100-127`) `[assumed]`

### TCB `[assumed]`

| Trusted component | Required independent control |
|---|---|
| Mailbox model encoding and abstraction | Buggy SAT control, corrected control, literal path tests |
| Kernel transition/classification | machine/kernel agreement fixtures; blocked/deadlock/completed cases |
| BFS explorer | shortest-witness, state-limit, and complete-graph fixtures already present |
| Canonical projection | canonical round-trip and projection-includes-budget tests |
| Trace validator/replay | exact-trace replay and malformed-trace rejection |
| Monitor implementation | grammar golden traces and malformed-order rejection |

No component above is "proved"; all are in the TCB. P1 itself is an unreviewed source register, so its facts remain `[assumed]`.

**Solver record:** no solver was invoked; therefore no actual SAT/UNSAT result exists. The buggy/corrected labels above are required expected outcomes, not completed evidence.

## 3. Differential-validation loop

```text
ordinary Jolt source
  -> expanded CSIR
  -> executable reference evaluator
  -> compiled Jolt
  -> compare terminal observable
```

### Corpus and comparison `[sampled after implementation; currently assumed]`

- **Conformance corpus:** selected pure cases from the candidate's conformance material, each with a declared expected result or known divergence classification.
- **Generated corpus:** bounded AST/program generators; Hegel samples and shrinks programs but is never exhaustive.
- **Comparison:** same source/expanded CSIR must terminate as the same canonical value, or the same declared exception class. Any unmatched value/class mismatch is a differential failure.
- **Known-divergence register:** records approved, version-pinned differences with source rationale; it is a filter/reporting artifact, never an implicit ignore-list.

Failure handling:

1. retain minimized source, expanded CSIR, reference result, compiled result, Jolt/CSIR/schema versions, and divergence status;
2. retain Hegel's public `:seed`, test name/database key, and pinned Hegel dependency revision;
3. retain the concrete minimized source because Hegel's portable replay coordinate is seed, while stateful traces do not persist generated arguments independently. (`P4:15-18, 56-61, 71-88`) `[assumed]`
4. promote the minimized program to a named ordinary regression corpus entry.

### Scope limits `[assumed]`

Pure fragment only from P1 §§1–5: literals, lexical bindings, ordinary ordered invocation, closures/recursion, `if`, `do`, and selected throw/catch behavior. Exclude concurrency, FFI, host interop, eval/load-string, dynamic resolution, raw host values, and unresolved reader/equality behaviors. Ordinary invoke order is sourced; host interop ordering is explicitly unknown. (`P1 §1`) `[assumed]`

### Missing implementation and first milestone `[assumed]`

Neither CSIR nor an executable reference evaluator exists in the inspected candidate: current IR has optional `:pos` but lacks the required CSIR provenance/site/resource/assumption fields. (`P1:94-95, 153-155`) The first honest milestone is therefore **not** a differential conformance claim: define a versioned minimal CSIR plus evaluator for one agreed pure subfragment, run one fixed corpus case through both paths, and label the result `sampled`. Only then add generated Hegel cases.

## 4. Evidence summary

- Pure mailbox model source/design: **assumed**
- Buggy known-SAT control before execution: **failed (expected)**
- Corrected completed BFS with no state cap: **bounded-complete**
- Hegel-generated differential programs: **sampled**
- Validated trace-monitor pass: **monitored**
- CSIR/reference evaluator absent: **opaque / UNKNOWN**
- Any state-cap result, unmatched divergence, or failed replay: **failed**, never pass
- No checked certificate exists: nothing is **proved**

## Decisions that are user-level

- Approve the no-timeout, two-message capacity-one mailbox as the first bounded target.
- Treat timeout/cancel as the next mailbox extension, not part of the first claim.
- Require exact non-vacuity counts in the future proof record; current counts are UNKNOWN.
- Fund minimal CSIR plus a reference evaluator before claiming differential conformance.
- Keep Maelstrom work independent of this test-only cooperative proof target.
