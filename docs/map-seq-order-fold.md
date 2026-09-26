# Internal persistent-map seq-order fold

`(pmap-fold-seq-order m proc seed)` is a raw Chez runtime helper in
`host/chez/collections.ss`, not a new Clojure collection API. `m` must be a
persistent Jolt `pmap`; `proc` is a Scheme procedure taking `(key value acc)`
and returning the next accumulator. Keys and values cross unchanged.

Each entry invokes `proc` once, in exactly the current `(seq m)` order. An
empty map returns the identical seed without calling `proc`. Exceptions
propagate immediately: no later callback runs. The helper does not interpret
`reduced` and accepts neither transient maps nor arbitrary map-like records.

Array maps follow their slot/insertion order. HAMT children are visited from
the first slot to the last, recursively; a full-hash collision bucket is
visited from the end of its stored list to the beginning. These are the
inverse of `pmap-fold`'s visits because `pmap-view-seq` fills its entry vector
backward. This is an agreement with the actual sequence, not a new promise
that hash-map order stays stable between runtime versions.

Callbacks execute in sequence order; the helper does not call them backward
and reverse their results afterward. It creates no full-map entry sequence,
entry vector or replacement entry pairs. Traversal takes O(entry count), with
stack space proportional to HAMT depth plus the largest collision bucket;
this is not a claim of zero allocation or constant stack for adversarial
full-hash collisions. Existing `pmap-fold` and `pmap-fold-fwd` are unchanged.

Consumers using `jolt.scheme/proc` must capability-check the helper name on
older runtimes and retain a portable fallback. It is a runtime representation
boundary: consumers should not copy HAMT/node/bucket traversal into libraries.
It adds no JSON grammar, writer semantics, compiler lowering or packaging rule.

The focused `mapseqfold` gate compares against the actual seq view, checks
callback effects and accumulator order, uses real Aa/BB-family hash collisions
through a verified 64-entry bucket, tests exception-prefix order (including a
stop partway through that bucket), and traps entry-view materialization without
adding an instrumented call seam to the production loop. This bounded collision
test does not turn the linear-stack tradeoff into a constant-stack guarantee.
The target is explicitly phony and is included in `CI-GATES`. Run through the
workspace's pinned Chez wrapper:

```sh
/home/chuck/ai-src/tools/jolt-with-chez-10.4.1 \
  chez --script test/chez/map-seq-fold-test.ss
```
