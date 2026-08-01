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
  :iptr :uptr :double :float :pointer :string :void :uint8 :char. Exact-width,
  native-byte-order scalars for C layouts and signatures (unlike modeling a
  short as an :int): :int8/:i8 (signed 8-bit), :int16/:short (signed 16-bit),
  :uint16/:ushort (unsigned 16-bit), :int32 (signed 32-bit), :uint32 (unsigned
  32-bit). :uint8/:u8/:byte stay unsigned C octets, distinct from jolt's signed
  byte-array element type. The host byte-array buffer helpers (read-array,
  read-array!, and write-array, exposed here as vars from the runtime) move raw
  octets across that seam: read-array allocates a fresh byte-array, read-array!
  copies into an existing byte-array at an offset, and write-array has a
  whole-array form and a ranged (ptr src src-off len) form. Protocol
  wire order remains the caller's responsibility (for example via htons/ntohs
  or an explicit codec).

  `with-byte-array-pointer` is a scoped, in-out bridge, not a zero-copy view:
  `(with-byte-array-pointer arr f)` loans the whole signed byte array and
  `(with-byte-array-pointer arr off len f)` loans one validated range. Each
  calls f with [pointer validated-length]. It copies the selected signed bytes
  to a temporary native-octet bytevector before f, keeps that temporary address
  stable only for f's dynamic extent, then copies its octets back as signed
  bytes on normal and exceptional exits. Native code must not retain pointer;
  Jolt code must not access the loaned range concurrently because copy-back owns
  it. A nested loan of the same array on one thread is rejected; nested loans of
  distinct arrays are supported. A captured continuation cannot re-enter a
  retired loan.

  The memory/library primitives (alloc/free/read/write/sizeof/load-library/
  ptr->string/string->ptr/null/null?) are provided by the host. foreign-fn lowers
  a compile-time-typed signature to a real Chez foreign-procedure. Its optional
  trailing map accepts :blocking and :capture-native-error literal Booleans;
  capture returns [native-result error-code] atomically and requires a non-void
  result. foreign-callable is the inverse — it wraps a jolt fn as a C-callable
  function pointer so C can call back into jolt (e.g. GTK signal handlers);
  free-callable releases it.")

;; foreign-fn binds C symbol `csym` to a typed callable. Expands to the __cfn
;; special form (always fully-qualified, so an :as alias on jolt.ffi resolves):
;; the analyzer/back end turn it into a Chez foreign-procedure.
;; An optional trailing :blocking marks a call that may block (accept/recv/...),
;; so it's emitted collect-safe and won't pin the garbage collector.
;; The trailing option is one of:
;;   :blocking                                   ; legacy shorthand (scalar result)
;;   {:blocking Boolean :capture-native-error Boolean}   ; literal options map
;; With :capture-native-error true the call returns [native-result error-code]
;; (result first), capturing the thread's native error slot (POSIX errno / Win32
;; GetLastError) atomically in the foreign-call return path. The map's keys and
;; values are validated in jolt.analyzer/analyze-ffi-fn (the single choke point a
;; direct jolt.ffi/__cfn form also passes through), so an unknown key, a
;; non-literal-Boolean value, an extra trailing form, or capture on :void all
;; fail closed at compile time. Omitting the option, :blocking, or an explicit
;; {:capture-native-error false} all preserve the existing scalar result.
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
      (throw (ex-info (str "jolt.ffi/" who ": the trailing option must be "
                           ":blocking or an options map; got " (vec args))
                      {:jolt/ffi-option args})))))

(defmacro foreign-fn [csym argtypes rettype & args]
  (cfn-form csym argtypes rettype args "foreign-fn"))

;; (defcfn name "c_symbol" [argtypes] rettype [:blocking | {opts}]) — def a foreign function.
;; The trailing option matches foreign-fn (:blocking or an options map); the
;; options map is documented above foreign-fn.
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
