# Fresh byte results without redundant copies

Chez byte arrays can internally adopt fresh exclusive bytevector storage.
This is an ownership transfer, not a general zero-copy public constructor:
the producer must relinquish all mutable aliases. Only String.getBytes charset
output and the private WAL encoder's one-shot extraction use this helper.

Normal Clojure `.getBytes` calls still return independently mutable arrays.
Public byte-array/raw conversion keeps copying retained input storage.
ByteArrayOutputStream.toByteArray still copies stream-owned bytes once, so
later writes, reset and caller mutation cannot change earlier snapshots.
Range writes and borrowed backing are unchanged.

Source accounting (not measured throughput): getBytes and WAL output remove
one full-result copy each; toByteArray removes one of two explicit snapshot
copies. Charset encoding, WAL generation, stream accumulation and native-memory
copying retain their existing work and ownership.

Focused gates, run under the workspace Chez 10.4.1 wrapper from this checkout:

```sh
/home/chuck/ai-src/tools/jolt-with-chez-10.4.1 chez --script test/chez/owned-byte-results-test.ss
/home/chuck/ai-src/tools/jolt-with-chez-10.4.1 chez --script test/chez/durable-wal-native-test.ss
/home/chuck/ai-src/tools/jolt-with-chez-10.4.1 chez --script test/chez/array-backing-test.ss
```

The ownership suite includes representation/copying-seam controls as well as
ordinary Clojure API mutation tests. The existing WAL suite pins exact framing,
escapes and Unicode. Product throughput requires separate matched measurement.
The existing `make arraybacking` target also runs the ownership suite after its
array-backing checks, so normal CI retains these controls. Invoke local make
through the same Chez 10.4.1 wrapper.
