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

Focused gates from this checkout, selecting the pinned Chez 10.4.1 executable:

```sh
make CHEZ=/path/to/chez-10.4.1 arraybacking durablewalnative
```

The ownership suite includes representation/copying-seam controls as well as
ordinary Clojure API mutation tests. The existing WAL suite pins exact framing,
escapes and Unicode. Product throughput requires separate matched measurement.
The existing `make arraybacking` target also runs the ownership suite after its
array-backing checks. It is listed in `CI-GATES`, which the normal `test`/`ci`
aggregate invokes, so CI retains these controls. In workspaces that require a
toolchain wrapper, invoke make through that wrapper rather than selecting an
arbitrary system Scheme executable.
