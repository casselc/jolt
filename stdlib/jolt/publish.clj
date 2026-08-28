;; Atomic no-clobber publication — make a fully written file visible under a
;; target path without ever replacing an existing target. This is the primitive a
;; cache, a database snapshot, or a "latest stable build" pointer wants: the
;; writer populates a private temp file (same filesystem as the target), then
;; publishes it atomically, so no reader can observe a half-written target and no
;; two publishers can both claim the name.
;;
;; Mechanism (Linux only).  On the target proven by
;; test/chez/atomic-publish-abi-probe.{c,sh}, the libc declaration is:
;;
;;   int renameat2(int olddirfd, const char *oldpath,
;;                 int newdirfd, const char *newpath, unsigned int flags);
;;
;; This is the SysV x86-64 C ABI call: two signed 32-bit `int` arguments, one
;; unsigned 32-bit `unsigned int` flags argument, and two
;; 64-bit char* pointers.  It has no variadic boundary, no aggregate argument or
;; return, no callback, and returns its signed 32-bit status directly (0/-1).
;; The collect-safe bindings take :pointer rather than :string: each wrapper
;; owns two ffi/string->ptr NUL-terminated UTF-8 allocations for its lexical
;; call interval, C neither owns nor retains them, and with-c-string frees them
;; only after the status and (on failure) errno are captured.  :blocking makes
;; each filesystem call collect-safe: it may wait in the kernel, but there is no
;; callback and no borrowed Jolt object survives after it returns.  The errno
;; read follows a failed call immediately on the same carrier thread.
;;
;; renameat2(..., RENAME_NOREPLACE) moves tmp onto target in one atomic step and
;; fails with EEXIST if target already exists.  Where the target kernel or
;; filesystem does not support the flag (ENOSYS or EINVAL), it uses Linux's
;; link(2)/unlink(2) idiom instead: link(tmp, target) is atomic and exclusive,
;; then unlink(tmp) drops the temporary name.  This implementation intentionally
;; makes no non-Linux POSIX, Windows, ABI, libc-version, filesystem, durability,
;; or crash-recovery claim.  A non-Linux host answers :unsupported.
;;
;; Status-observable. publish! returns a keyword and never throws for the
;; publication races it exists to arbitrate:
;;   :published   — target now holds tmp's content; tmp's name is consumed.
;;   :exists      — target already existed (EEXIST); it was NOT touched, and tmp
;;                  is left intact for the caller to retry or delete.
;;   :unsupported — this host or filesystem cannot do a no-clobber publish here
;;                  (renameat2 unavailable AND hard links refused, or non-Linux).
;;                  Fails CLOSED: nothing was published, nothing was clobbered.
;;   :error       — some other filesystem error (permission, read-only, missing
;;                  tmp, cross-device). Fails closed the same way.
;;
;; errno is read IMMEDIATELY after a failing call, before the fallback link can
;; overwrite the per-thread slot and before any allocation or park re-enters the
;; runtime and might make a syscall of its own (jolt.ffi's rule, honored here so
;; the classification is about THIS call, not whichever one ran next).
;;
;; This is a LOW-LEVEL primitive for trusted callers — the runtime's own cache
;; and integration layers — not a general file-moving API. It assumes the caller
;; owns both paths, has already written and closed tmp (durability — fsync'ing
;; tmp before publishing — is the caller's job), and that tmp lives on the same
;; filesystem as target. The FFI bindings (renameat2/link/unlink) stay private to
;; this namespace; nothing generic is added to jolt.ffi.

(ns jolt.publish
  (:require [jolt.ffi :as ffi]
            [clojure.string :as str]))

(ffi/load-library)

;; -- platform + errno constants -----------------------------------------------
;; Linux-only: Linux constants and Linux errno classification below are never
;; interpreted on another OS.
(def ^:private linux?
  (str/includes? (str/lower-case (or (System/getProperty "os.name") "")) "linux"))

;; AT_FDCWD is (int) -100 on Linux and the hard-link path never uses it.
;; RENAME_NOREPLACE is the "fail with EEXIST rather than replace" flag.
(def ^:private AT-FDCWD -100)
(def ^:private RENAME-NOREPLACE 1)

;; errno values from the target Linux headers; only evaluated after a Linux call.
(def ^:private EEXIST 17)
(def ^:private EINVAL 22)      ; renameat2: filesystem rejects RENAME_NOREPLACE
(def ^:private ENOSYS 38)      ; renameat2: kernel predates it
(def ^:private EPERM 1)        ; hard link: not permitted (FAT, some network fs)
(def ^:private EOPNOTSUPP 95)  ; hard link: not supported (ENOTSUP aliases this)
(def ^:private EMLINK 31)      ; hard link: link count exhausted
(def ^:private EXDEV 18)       ; tmp and target on different filesystems

;; -- syscalls (private to this namespace — no generic FFI exposure) ------------
;; link/unlink are respectively int (const char *, const char *) and
;; int (const char *) on this same target ABI.  They likewise have no varargs,
;; aggregates, callbacks, retained pointers, or ownership transfer.  All three
;; calls are synchronous and collect-safe, so their path copies are valid only
;; until the particular call returns.
(ffi/defcfn c-renameat2 "renameat2" [:int :pointer :int :pointer :uint] :int :blocking)
(ffi/defcfn c-link "link" [:pointer :pointer] :int :blocking)
(ffi/defcfn c-unlink "unlink" [:pointer] :int :blocking)

(defn- errno [] (ffi/errno))

(defn- renameat2-result
  "[status errno?] from one collect-safe call. tmp*/target* are owned native
  C-string allocations, valid only inside the nested with-c-string scopes; C
  receives borrowed const char* values and has no cleanup responsibility."
  [tmp target]
  (ffi/with-c-string [tmp* tmp]
    (ffi/with-c-string [target* target]
      (let [r (c-renameat2 AT-FDCWD tmp* AT-FDCWD target* RENAME-NOREPLACE)]
        [r (when-not (zero? r) (errno))]))))

(defn- link-result
  "[status errno?] from one collect-safe link(2), with the same lexical native
  C-string ownership and no pointer escape as renameat2-result."
  [tmp target]
  (ffi/with-c-string [tmp* tmp]
    (ffi/with-c-string [target* target]
      (let [r (c-link tmp* target*)]
        [r (when-not (zero? r) (errno))]))))

(defn- unlink-temp! [tmp]
  ;; The target is already visible when this runs. Its result and errno are
  ;; intentionally irrelevant; the lexical C string is still freed exactly once.
  (ffi/with-c-string [tmp* tmp]
    (c-unlink tmp*)))

(defn- unsupported-atomic-rename? [e]
  ;; The renameat2 NOREPLACE flag is not available here: the kernel lacks the
  ;; syscall (ENOSYS) or the filesystem rejects the flag (EINVAL). The hard-link
  ;; idiom may still work, so these fall through to it rather than failing.
  (or (= e ENOSYS) (= e EINVAL)))

(defn- unsupported? [e]
  ;; Fail-closed classification: every mechanism refused. EPERM/EOPNOTSUPP/EMLINK
  ;; are hard-link refusals. EXDEV is a caller precondition failure (the paths
  ;; are not on one filesystem), so it remains :error rather than disguising a
  ;; bad input as a capability absence.
  (contains? #{EPERM EOPNOTSUPP EMLINK} e))

(defn- classify [e]
  (cond
    (= e EEXIST) :exists
    (unsupported? e) :unsupported
    :else :error))

(defn- link-publish [tmp target]
  ;; Linux atomic no-clobber fallback: link(tmp, target) is exclusive in the
  ;; kernel, so exactly one of any set of concurrent links wins and the rest get
  ;; EEXIST.  Drop the temporary name after a win so only target remains.
  (let [[r e] (link-result tmp target)]
    (if (zero? r)
      (do (unlink-temp! tmp)
          ;; the publication is already done; a failed unlink leaves a harmless
          ;; extra name for the caller and must not downgrade :published.
          :published)
      (classify e))))         ; errno captured immediately in link-result

(defn publish!
  "Atomically publish `tmp` onto `target` without replacing an existing target.
  `tmp` and `target` are path names (strings or `jolt.fs` Path values); `tmp`
  must already exist, hold the fully-written content, and live on the same
  filesystem as `target`. Returns :published, :exists, :unsupported, or :error
  (see the namespace doc). Never throws for the publication race: a target that
  already exists is an answer (:exists), not an exception."
  [tmp target]
  (let [tmp (str tmp) target (str target)]
    (cond
      (not linux?) :unsupported ; deliberately no non-Linux claim

      linux?
       (let [[r e] (renameat2-result tmp target)]
         (cond
           (zero? r) :published
          :else
          (cond
            (= e EEXIST) :exists
            (unsupported-atomic-rename? e) (link-publish tmp target)
            :else (classify e))))

      :else :unsupported)))
