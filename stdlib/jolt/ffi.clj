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

  Types (keywords): :int :uint :int32 :uint32 :long :ulong :int64 :uint64
  :size_t :ssize_t :iptr :uptr :double :float :pointer :string :void :uint8
  :char. An outbound, non-:blocking call may also use :byte-array for a C u8*
  argument. The array's bytevector storage is borrowed without a native copy
  only for the duration of that call; C must not retain the pointer. Because a
  :blocking call deactivates the Scheme thread for collection, :byte-array is
  rejected there.

  A C struct argument passed by value is described inline:

      [:by-value
       [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]

  The Jolt argument remains a native pointer to caller-owned storage holding
  that layout; the generated wrapper passes the pointed-to value by C value.
  Nested [:struct ...] field types are supported. Aggregate results and
  aggregate callbacks are deliberately rejected until their ownership contract
  is defined.

  The memory/library primitives (alloc/free/read/write/sizeof/load-library/
  ptr->string/string->ptr/null/null?) are provided by the host. Binary buffers
  can be copied as `(read-array ptr len)`, into an existing byte-array as
  `(read-array! ptr len dest dest-off)`, or out with
  `(write-array ptr src [src-off len])`. A null pointer is allowed only for a
  zero-length transfer. `(with-byte-array-pointer arr off len f)` validates and
  pins an array slice, then calls `f` with its interior pointer and validated
  length. The pointer is valid only until `f` returns and must not be retained.

  foreign-fn lowers a compile-time-typed signature to a real Chez
  foreign-procedure. Its optional final argument is either the legacy
  :blocking keyword or an options map:

      {:blocking true
       :varargs-after 2
       :capture-native-error true}

  :varargs-after is the positive number of fixed C arguments before `...`.
  Declaring that boundary is required even when every argument has a known
  Jolt type: Apple arm64 uses a different ABI location for variadic arguments.
  The boundary may not exceed the declared argument count. Types after the
  boundary must name the C ABI types after default argument promotion (for
  example, use :double for a promoted C float); Jolt does not infer promotions.

  :capture-native-error asks Chez to capture the calling thread's native error
  slot in the foreign-call return path, before collect-safe thread reactivation
  or any later native work can overwrite it. On POSIX this is errno; on Windows
  it is GetLastError (the slot reported by WSAGetLastError for Winsock calls).
  An opted-in binding returns `[native-result error-code]`; a binding without
  the option keeps returning its original scalar result. The error code is
  meaningful only when the API's native result indicates failure and must be
  ignored on success. This option composes with :blocking and :varargs-after and
  requires a non-:void return type.

  foreign-callable is the inverse — it wraps a jolt fn as a C-callable function
  pointer so C can call back into jolt (e.g. GTK signal handlers);
  free-callable releases it.")

;; foreign-fn binds C symbol `csym` to a typed callable. Expands to the __cfn
;; special form (always fully-qualified, so an :as alias on jolt.ffi resolves):
;; the analyzer/back end turn it into a Chez foreign-procedure.
;; An optional trailing :blocking marks a call that may block (accept/recv/...),
;; so it's emitted collect-safe and won't pin the garbage collector. An options
;; map can instead carry :blocking, :varargs-after, and/or
;; :capture-native-error. Aggregate arguments use the inline descriptor
;; documented above.
(defmacro foreign-fn [csym argtypes rettype & [opt]]
  (if (nil? opt)
    (list 'jolt.ffi/__cfn csym argtypes rettype)
    (list 'jolt.ffi/__cfn csym argtypes rettype opt)))

;; (defcfn name "c_symbol" [argtypes] rettype [:blocking-or-options])
;; defines a foreign function. See foreign-fn above for the options contract.
(defmacro defcfn [name csym argtypes rettype & [opt]]
  (list 'def name
        (if (nil? opt)
          (list 'jolt.ffi/__cfn csym argtypes rettype)
          (list 'jolt.ffi/__cfn csym argtypes rettype opt))))

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
