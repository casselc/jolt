(ns jolt.ffi
  "Foreign-function interface for jolt libraries. A library loads a shared object
  and declares typed foreign functions, then exposes a Clojure API over them — no
  jolt built-in required.

      (require '[jolt.ffi :as ffi])
      (ffi/load-library {:darwin \"libsqlite3.0.dylib\" :linux \"libsqlite3.so.0\"})
      (ffi/defcfn sqlite3-open \"sqlite3_open\" [:string :pointer] :int)
      (let [pp (ffi/alloc (ffi/sizeof :pointer))]
        (sqlite3-open \"x.db\" pp)
        (let [db (ffi/read pp :pointer)] ...)
        (ffi/free pp))

  Types (keywords): :int :uint :long :ulong :int64 :uint64 :size_t :ssize_t
  :iptr :uptr :double :float :pointer :string :void :uint8 :char, plus exact
  scalar widths :int8/:i8, :int16/:short, :uint16/:ushort, :int32, :uint32.
  Each exact width is a fixed-width native-byte-order memory type and signature
  type; the signed and unsigned widths at each size expose the same stored bits
  (a :uint16 read of a :int16 -1 write is 65535). Wire byte order stays an
  explicit conversion (htons/ntohs or a codec).

  The host byte-array buffer helpers are exposed here as vars from the runtime:
  read-array allocates a fresh byte-array, read-array! copies into an existing
  byte-array at an offset, and write-array has a whole-array form and a ranged
  (ptr src src-off len) form. Both ranged forms validate the byte-array kind,
  subtraction-safe bounds, and nonzero-length null pointers before any native
  access or mutation.

  with-byte-array-pointer is a scoped, synchronous in-out bridge, not a
  zero-copy view: (with-byte-array-pointer arr f) loans the whole signed byte
  array and (with-byte-array-pointer arr off len f) loans one validated range.
  Each calls f with [pointer validated-length]. It validates the byte-array
  kind and subtraction-safe range before any allocation or callback, copies the
  selected signed bytes into a temporary native-octet bytevector, locks it for a
  stable address only for f's dynamic extent, then copies its octets back as
  signed bytes on normal return, jolt/host exception, and nonlocal exit. Native
  code must not retain the pointer; the loaned range is owned by copy-back while
  f runs. A nested loan of the same array on one thread is rejected, while
  distinct-array nesting is allowed. Callers must prevent overlapping loan
  lifetimes or other access to the same array across threads, even for disjoint
  ranges; joining a child before an outer callback returns does not make two
  independent snapshot copy-backs safe. A captured continuation cannot re-enter
  a retired loan. It performs no native call itself, so it captures no errno.

  The memory/library primitives (alloc/free/read/write/sizeof/load-library/
  ptr->string/string->ptr/null/null?) are provided by the host. foreign-fn lowers
  a compile-time-typed signature to a real Chez foreign-procedure. Its optional
  trailing map accepts :blocking and :capture-native-error literal Booleans;
  capture returns [native-result error-code] atomically and requires a non-void
  result. It also accepts {:varargs-after n}, where n is the positive number of
  declared fixed C parameters before the "...": the declared argtypes list the
  fixed params followed by the already-promoted variadic ones, and the boundary
  lowers to Chez's __varargs_after convention (required where the variadic and
  fixed calling conventions differ). It composes with :blocking and
  :capture-native-error. foreign-callable is the inverse — it wraps a jolt fn as
  a C-callable function pointer so C can call back into jolt (e.g. GTK signal
  handlers); free-callable releases it.")

;; foreign-fn binds C symbol `csym` to a typed callable. Expands to the __cfn
;; special form (always fully-qualified, so an :as alias on jolt.ffi resolves):
;; the analyzer/back end turn it into a Chez foreign-procedure.
;; An optional trailing :blocking marks a call that may block (accept/recv/...),
;; so it's emitted collect-safe and won't pin the garbage collector.
;; An options map may instead combine :blocking with
;; :capture-native-error. Capture returns [native-result error-code] (result
;; first), with the error slot read in the foreign-call return path. The map may
;; also carry {:varargs-after n} to declare a variadic C function's fixed-
;; argument boundary, lowering to Chez's __varargs_after. The analyzer validates
;; the literal map and rejects capture on :void.
(defn- cfn-form [csym argtypes rettype args who]
  (let [n (count args)]
    (cond
      (zero? n)
      (list 'jolt.ffi/__cfn csym argtypes rettype)

      (and (= n 1) (= (first args) :blocking))
      (list 'jolt.ffi/__cfn csym argtypes rettype :blocking)

      (and (= n 1) (map? (first args)))
      (list 'jolt.ffi/__cfn csym argtypes rettype (first args))

      :else
      (throw (ex-info (str "jolt.ffi/" who ": trailing option must be "
                           ":blocking or an options map; got " (vec args))
                      {:jolt/ffi-option args})))))

(defmacro foreign-fn [csym argtypes rettype & args]
  (cfn-form csym argtypes rettype args "foreign-fn"))

;; (defcfn name "c_symbol" [argtypes] rettype [:blocking | {opts}]) — def a
;; foreign function. The trailing option matches foreign-fn.
(defmacro defcfn [name csym argtypes rettype & args]
  (list 'def name (cfn-form csym argtypes rettype args "defcfn")))

;; foreign-callable wraps a jolt fn `f` as a C-callable function pointer — the
;; inverse of foreign-fn, so C can call back INTO jolt (GTK signal handlers, a
;; qsort comparator, any C API that takes a callback). Returns the pointer; pass
;; it where C expects a function pointer. argtypes/rettype use the same keywords
;; as foreign-fn; the args C passes arrive as jolt values and the jolt return is
;; marshaled back. The callback stays live until free-callable is called on the
;; pointer. Pass a trailing :collect-safe when C invokes the callback from a
;; thread parked in a :blocking foreign call (e.g. a GTK main loop):
;;   (g-signal-connect button "clicked"
;;                     (ffi/foreign-callable on-click [:pointer :pointer] :void :collect-safe)
;;                     (ffi/null))
(defmacro foreign-callable [f argtypes rettype & [opt]]
  (if (= opt :collect-safe)
    (list 'jolt.ffi/__ccallable f argtypes rettype :collect-safe)
    (list 'jolt.ffi/__ccallable f argtypes rettype)))

;; (export! name f [argtypes] rettype [:collect-safe]) — publish `f` as a
;; C-callable entry point under `name`, for `jolt build --library`. An embedder
;; resolves it via jolt_lookup("name") after jolt_library_init. Expands to a
;; register-export of a foreign-callable (the __ccallable special form), so the
;; callable is built with compile-time-typed argtypes and registered by name:
;;   (export! "add" (fn [x y] (+ x y)) [:int :int] :int)
;; The argtypes/rettype keywords are the same as foreign-fn/foreign-callable.
(defmacro export! [name f argtypes rettype & [opt]]
  (let [addr (if (= opt :collect-safe)
               (list 'jolt.ffi/__ccallable f argtypes rettype :collect-safe)
               (list 'jolt.ffi/__ccallable f argtypes rettype))]
    (list 'jolt.ffi/register-export name addr)))
