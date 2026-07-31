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
  :char. A C struct argument passed by value is described inline:

      [:by-value
       [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]

  The Jolt argument remains a native pointer to caller-owned storage holding
  that layout; the generated wrapper passes the pointed-to value by C value.
  Nested [:struct ...] field types are supported. Aggregate results and
  aggregate callbacks are deliberately rejected until their ownership and
  lifetime contracts are explicit.

  The memory/library primitives (alloc/free/read/write/sizeof/load-library/
  ptr->string/string->ptr/null/null?) are provided by the host. Binary data can
  be copied with read-array/write-array. For a scoped zero-copy loan,
  `(with-byte-array-pointer arr f)` pins the whole byte array and
  `(with-byte-array-pointer arr off len f)` pins one validated range; both call
  `f` with the pointer and validated length. The pointer is valid only during
  that callback and native code must not retain it.

  foreign-fn lowers a compile-time-typed signature to a real Chez
  foreign-procedure. Its optional final argument is the legacy :blocking keyword
  or a literal options map:

      {:blocking true :capture-native-error true :varargs-after 2}

  :blocking makes the call collect-safe. :capture-native-error atomically returns
  [native-result error-code], using errno on supported POSIX targets and
  GetLastError on supported Windows targets; the code is meaningful only when
  the result reports failure. Capture requires a non-:void return.
  :varargs-after is the positive number of fixed C parameters before `...`;
  it may not exceed the declared argument count. Types after that boundary
  must be their default-promoted C ABI types (for example, use :double for a
  promoted C float); Jolt does not infer those promotions.

  Aggregate argument descriptors compose with these options. The native pointer
  is dereferenced only on the native/proceed route; a simulation controller can
  model the call without touching caller memory or resolving the C symbol.

  foreign-callable is the inverse — it wraps a jolt fn as a C-callable function
  pointer so C can call back into jolt (e.g. GTK signal handlers);
  free-callable releases it.")

;; foreign-fn binds C symbol `csym` to a typed callable. Expands to the __cfn
;; special form (always fully-qualified, so an :as alias on jolt.ffi resolves):
;; the analyzer/back end turn it into a Chez foreign-procedure.
;; The optional final argument is the legacy :blocking keyword or a literal map
;; containing :blocking and :capture-native-error Boolean values and/or a
;; positive integer :varargs-after boundary. Aggregate arguments use the inline
;; descriptor documented above.
(defn- opt->cfn-arg [opts]
  (cond
    (empty? opts) nil
    (> (count opts) 1)
    (throw "jolt.ffi foreign-fn/defcfn accepts at most one options argument")
    (= (first opts) :blocking) :blocking
    (map? (first opts)) (first opts)
    :else
    (throw (str "jolt.ffi foreign-fn/defcfn options must be :blocking or a "
                "literal {:blocking bool :capture-native-error bool "
                ":varargs-after positive-int}; got: "
                (first opts)))))

(defmacro foreign-fn [csym argtypes rettype & opts]
  (let [opt (opt->cfn-arg opts)]
    (if (nil? opt)
      (list 'jolt.ffi/__cfn csym argtypes rettype)
      (list 'jolt.ffi/__cfn csym argtypes rettype opt))))

;; (defcfn name "c_symbol" [argtypes] rettype [:blocking | options-map])
(defmacro defcfn [name csym argtypes rettype & opts]
  (let [opt (opt->cfn-arg opts)]
    (list 'def name
          (if (nil? opt)
            (list 'jolt.ffi/__cfn csym argtypes rettype)
            (list 'jolt.ffi/__cfn csym argtypes rettype opt)))))

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
