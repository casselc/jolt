(ns jolt.deps
  "Resolve a deps.edn into an ordered list of source roots. A reduced
  tools.deps: :paths, :deps (`:git/url`+`:git/sha` / `:local/root` /
  `:mvn/version`), :aliases, :tasks. Alias maps combine with the reference
  tools.deps semantics (jolt.deps.edn, lifted from clojure.tools.deps.edn):
  :extra-deps / :override-deps / :default-deps / :replace-deps (legacy :deps),
  :extra-paths / :replace-paths (legacy :paths), :main-opts.

  The deps walk is breadth-first so a top-level coordinate registers before any
  transitive one (a top-level pin wins). Git deps reuse an existing
  tools.gitlibs checkout ($GITLIBS / ~/.gitlibs) when the JVM toolchain already
  fetched them, else clone into a sha-immutable cache ($JOLT_GITLIBS, else
  ~/.jolt/gitlibs, or a jolt/ subdir of $GITLIBS) shared across projects.
  Maven jars live in the standard local repository (~/.m2/repository;
  :mvn/local-repo in deps.edn relocates it like tools.deps, JOLT_LOCAL_REPO
  overrides from the environment) shared with the JVM toolchain in both
  directions. Maven jars are fetched by jolt itself over HTTPS (jolt.mvn-http);
  git and unzip still shell out through jolt.host/sh (nothing here touches the JVM)."
  (:require [clojure.edn :as edn]
            [clojure.set :as set]
            [clojure.string :as str]
            [jolt.deps.edn :as dedn]
            [jolt.deps.ext :as ext]
            [jolt.mvn-http :as http]))

;; --- small host seams -------------------------------------------------------
;; An env var set to the empty string reads as UNSET — `FOO= cmd` is the usual
;; way to clear a variable for one command, and treating "" as a value would
;; turn that into "set to nothing".
(defn- getenv [n] (let [v (jolt.host/getenv n)] (when-not (str/blank? v) v)))
(defn- file-exists? [p] (jolt.host/file-exists? p))
(defn- sh [cmd] (jolt.host/sh cmd))           ; exit code, inherits stdout/stderr
(defn- sh-out
  "Run a shell command, returning its trimmed stdout, or nil on a non-zero
  exit. Captures through a temp file (jolt.host/sh inherits stdio)."
  [cmd]
  (let [tmp (str "/tmp/jolt-deps-" (System/currentTimeMillis) "-" (rand-int 100000) ".out")
        code (sh (str cmd " > " (pr-str tmp) " 2>/dev/null"))
        out (when (file-exists? tmp) (str/trim (slurp tmp)))]
    (sh (str "rm -f " (pr-str tmp)))
    (when (zero? code) out)))
(defn- warn [& xs] (binding [*out* *err*] (println (str "[jolt.deps] " (apply str xs)))))
;; Progress / informational lines (fetching, using-cache, skipping, added-natives)
;; print only when JOLT_DEBUG is set — otherwise a routine run (e.g. a ys-generated
;; program pulling a native-declaring lib) barfs them on every invocation. Genuine
;; warnings (an unresolvable dep, a malformed deps.edn) always print via `warn`.
(defn- info [& xs] (when (getenv "JOLT_DEBUG") (apply warn xs)))

(defn- read-edn [path]
  (when (file-exists? path)
    (try (edn/read-string (slurp path))
         (catch :default e
           (throw (ex-info (str path ": " (ex-message e)) {:path path :error e}))))))

(defn- abspath [dir p]
  (if (jolt.host/absolute-path? p) p (str dir "/" p)))

;; --- git cache --------------------------------------------------------------
;; jolt's own clone cache. $GITLIBS (the tools.gitlibs location knob) is
;; respected for WHERE the cache lives — under a jolt/ subdir so tools.gitlibs'
;; own _repos/ and libs/ namespaces are never written to. JOLT_GITLIBS pins an
;; exact directory.
(defn- gitlibs-dir []
  (or (getenv "JOLT_GITLIBS")
      (when-let [g (getenv "GITLIBS")] (str g "/jolt"))
      (str (or (getenv "HOME") ".") "/.jolt/gitlibs")))

(defn- alnum? [c]
  (let [n (int c)]
    (or (and (>= n 48) (<= n 57))     ; 0-9
        (and (>= n 65) (<= n 90))     ; A-Z
        (and (>= n 97) (<= n 122))))) ; a-z
(defn- sanitize [s]
  (str/join (map (fn [c] (if (or (alnum? c) (= c \.) (= c \-)) c \_)) (seq s))))

(defn- shell-quote
  "Quote one string as one POSIX-shell argument. `pr-str` is not sufficient:
  its double quotes still allow command substitution in a path or URL."
  [s]
  (str "'" (str/replace (str s) "'" "'\"'\"'") "'"))

(def ^:private git-command-prefix
  ;; Git for Windows otherwise retains the legacy MAX_PATH boundary for worktree
  ;; and submodule internals. Keep this per invocation: dependency resolution
  ;; must not require or mutate a user's global Git configuration. Git propagates
  ;; command-scope config to the child processes spawned by `submodule update`;
  ;; the setting is benign on POSIX Git.
  "git -c core.longpaths=true --no-optional-locks --no-replace-objects")

(def ^:private command-exit-marker "__JOLT_COMMAND_EXIT__")

(defn- shell-result
  "Run one POSIX-shell command and return its exit status plus stdout.

  jolt.host/sh-out intentionally exposes only stdout. Append an exit marker
  after the command so validation never mistakes a failed Git query for clean,
  empty output. The final marker wins even when an adversarial filename happens
  to contain the same text."
  [cmd]
  (let [raw (jolt.host/sh-out
              (str cmd " 2>/dev/null; rc=$?; printf '\\n"
                   command-exit-marker "%s\\n' \"$rc\""))
        marker (str "\n" command-exit-marker)
        i (str/last-index-of raw marker)]
    (if (nil? i)
      {:exit 255 :out raw}
      (let [status (str/trim (subs raw (+ i (count marker))))]
        {:exit (or (parse-long status) 255)
         :out (subs raw 0 i)}))))

(defn- git-result
  "Run Git with replacement objects disabled. `args` are quoted independently,
  so dependency URLs and cache paths never become shell syntax."
  [dir args]
  (shell-result
    (str git-command-prefix
         (when dir (str " -C " (shell-quote dir)))
         (when (seq args)
           (str " " (str/join " " (map shell-quote args)))))))

(defn- result-ok? [result] (zero? (:exit result)))

(defn- result-lines [result]
  (if (str/blank? (:out result)) [] (vec (str/split-lines (:out result)))))

(defn- git-sha?
  "Accept a hexadecimal commit-object prefix, never a ref or path. Seven
  characters preserves the tools.deps ecosystem convention (including Jolt's
  vendored test-runner aliases); validation resolves it and compares full object
  ids. The upper bound covers Git's 64-character SHA-256 object format."
  [sha]
  (and (string? sha)
       (<= 7 (count sha) 64)
       (every? (fn [c]
                 (let [n (int c)]
                   (or (and (>= n 48) (<= n 57))
                       (and (>= n 65) (<= n 70))
                       (and (>= n 97) (<= n 102)))))
               (seq sha))))

(defn- git-url-cache-key
  "A fixed-size, path-safe key for a Git URL.

  `sanitize` is deliberately not used: it maps distinct URLs such as `a/b` and
  `a_b` to one directory, allowing repair of one origin to delete the other's
  checkout at a shared SHA. Git is already required for Git deps, and
  `hash-object --stdin` gives its stable collision-resistant blob object ID
  without writing an object or repository. The validated 40/64 hex result keeps
  one filesystem component short on both current SHA-1 and SHA-256 Git builds.
  Legacy sanitize-keyed URL leaves are deliberately ignored: because they are
  ambiguous, automatically migrating or deleting one could corrupt another
  origin's cache."
  [url]
  (let [result (shell-result
                 (str "printf '%s' " (shell-quote url)
                      " | " git-command-prefix " hash-object --stdin"))
        digest (str/trim (:out result))]
    (if (and (result-ok? result) (git-sha? digest))
      (str "url-" (str/lower-case digest))
      (throw (ex-info (str "could not derive git cache key for " url)
                      {:url url :digest digest :exit (:exit result)})))))

(defn- git-cache-entry-dir
  "Versioned layout keeps collision-resistant URL keys disjoint from every
  ambiguous sanitize-keyed cache leaf written by older Jolt versions. Literal
  origin validation supplies the independent fail-closed collision check."
  [url sha]
  (str (gitlibs-dir) "/git-v2/" (git-url-cache-key url) "/" sha))

(defn- git-cache-origin-marker [dir]
  (str dir ".jolt-origin"))

(defn- git-cache-origin-claim
  "Read the ownership claim adjacent to one url@sha leaf. It remains available
  even if the checkout's .git metadata is later damaged, so a forced URL-key
  collision can never turn corruption into permission to delete another
  origin's cache entry."
  [dir url]
  (let [marker (git-cache-origin-marker dir)]
    (if-not (file-exists? marker)
      {:claimed? false :matches? false :marker marker}
      (let [actual (try (slurp marker) (catch :default _ nil))]
        {:claimed? true :matches? (= url actual) :marker marker
         :expected-url url :actual-url actual}))))

(defn- unsafe-index-line?
  "git ls-files -v prefixes skip-worktree with S and assume-unchanged with
  lower-case status letters. Either can hide missing or modified source from
  porcelain status."
  [line]
  (when (seq line)
    (let [c (first line)
          n (int c)]
      (or (= c \S) (and (>= n 97) (<= n 122))))))

(defn- inspect-worktree-state
  "Inspect mutable worktree/index state at one repository boundary."
  [dir]
  (let [status (git-result dir ["status" "--porcelain=v1"
                                "--untracked-files=all" "--ignored=matching"
                                "--ignore-submodules=none"])]
    (cond
      (not (result-ok? status))
      {:valid? false :reason :git-error :operation :status :path dir
       :exit (:exit status)}

      (not (str/blank? (:out status)))
      {:valid? false :reason :dirty :path dir :status (:out status)}

      :else
      (let [index (git-result dir ["ls-files" "-v"])]
        (cond
          (not (result-ok? index))
          {:valid? false :reason :git-error :operation :ls-files :path dir
           :exit (:exit index)}

          (some unsafe-index-line? (result-lines index))
          {:valid? false :reason :unsafe-index :path dir}

          :else {:valid? true})))))

(defn- git-checkout-inspection
  "Return a structured, fail-closed inspection of `dir` at exactly `sha`.

  `expected-url`, when non-nil, is compared with the literal remote.origin.url;
  unlike `git remote get-url`, this does not expand a user's url.*.insteadOf
  mirror or transport rules. Origin mismatch is distinct because it may mean a
  URL-key collision and must never enter destructive repair."
  [dir sha expected-url]
  (if-not (file-exists? dir)
    {:valid? false :reason :missing :path dir}
    (let [inside (git-result dir ["rev-parse" "--is-inside-work-tree"])]
      (cond
        (or (not (result-ok? inside))
            (not= "true" (str/trim (:out inside))))
        {:valid? false :reason :not-worktree :path dir}

        :else
        ;; Check literal ownership before inspecting content. Even a malformed
        ;; or dirty wrong-origin checkout may be evidence of a URL-key collision;
        ;; never classify it as ordinary repairable residue first.
        (let [origins (when expected-url
                        (git-result dir ["config" "--local" "--get-all"
                                         "remote.origin.url"]))]
          (if (and expected-url
                   (or (not (result-ok? origins))
                       (not= [expected-url] (result-lines origins))))
            {:valid? false :reason :origin-mismatch :path dir
             :expected-url expected-url
             :actual-urls (if origins (result-lines origins) [])}
            (let [kind (git-result dir ["cat-file" "-t" sha])
                  head (git-result dir ["rev-parse" "--verify"
                                        "HEAD^{commit}"])
                  wanted (git-result dir ["rev-parse" "--verify"
                                          (str sha "^{commit}")])]
              (cond
                (or (not (result-ok? kind))
                    (not= "commit" (str/trim (:out kind))))
                {:valid? false :reason :wrong-object :path dir :sha sha
                 :object-type (str/trim (:out kind))}

                (or (not (result-ok? head)) (not (result-ok? wanted)))
                {:valid? false :reason :unresolved-head :path dir :sha sha}

                (not= (str/trim (:out head)) (str/trim (:out wanted)))
                {:valid? false :reason :wrong-head :path dir :sha sha
                 :head (str/trim (:out head))
                 :wanted (str/trim (:out wanted))}

                :else
                (let [state (inspect-worktree-state dir)]
                  (if-not (:valid? state)
                    state
                    (let [sub-status
                          (git-result dir ["submodule" "status" "--recursive"])]
                      (cond
                        (not (result-ok? sub-status))
                        {:valid? false :reason :git-error
                         :operation :submodule-status :path dir
                         :exit (:exit sub-status)}

                        (some (fn [line]
                                (and (seq line)
                                     (not= \space (first line))))
                              (result-lines sub-status))
                        {:valid? false :reason :incomplete-submodule :path dir
                         :status (:out sub-status)}

                        :else
                        (let [sub-paths
                              (git-result
                                dir ["submodule" "foreach" "--quiet"
                                     "--recursive"
                                     "printf '%s\\n' \"$displaypath\""])]
                          (if-not (result-ok? sub-paths)
                            {:valid? false :reason :git-error
                             :operation :submodule-foreach :path dir
                             :exit (:exit sub-paths)}
                            (or
                              (some
                                (fn [subpath]
                                  (let [subdir (str dir "/" subpath)
                                        inspection (inspect-worktree-state subdir)]
                                    (when-not (:valid? inspection)
                                      (assoc inspection
                                             :submodule? true
                                             :checkout-path dir))))
                                (result-lines sub-paths))
                              {:valid? true :reason :valid :path dir
                               :head (str/trim (:out head))})))))))))))))))

(defn- git-checkout-valid? [dir sha expected-url]
  (:valid? (git-checkout-inspection dir sha expected-url)))

(defn- gitlibs-shared-checkout
  "An existing tools.gitlibs checkout for lib@sha ($GITLIBS or ~/.gitlibs,
  layout libs/<group>/<name>/<sha>) — reused read-only when the JVM toolchain
  already fetched this dep. jolt never writes there: tools.gitlibs keeps its
  own bookkeeping (_repos bare clones + worktrees) that a foreign writer could
  corrupt, so jolt's own fetches go to its cache below."
  [lib sha]
  (when (and lib (namespace lib))
    (let [base (or (getenv "GITLIBS") (str (or (getenv "HOME") ".") "/.gitlibs"))
          dir (str base "/libs/" (namespace lib) "/" (name lib) "/" sha)]
      (when (git-checkout-valid? dir sha nil) dir))))

(def ^:private git-lock-wait-attempts 6000)
(def ^:private git-lock-wait-ms 50)

(defn- git-cache-lock-dir
  "The stable per-entry ownership path. This name is part of the cache's
  cross-version synchronization protocol: transactional Jolt versions must
  contend on the same lock even if their private staging layout differs."
  [dir]
  (str dir ".jolt-lock"))

(defn- git-cache-stage-dir
  "The private checkout staged beside its final url@sha leaf.

  A sibling preserves same-filesystem publication while adding only two
  characters to Git's worktree path. The former `.jolt-lock/checkout` nesting
  consumed 19 characters and pushed recursive Windows submodules past Git's
  legacy path boundary."
  [dir]
  (str dir ".s"))

(defn- remove-own-cache-path!
  "Remove only the final url@sha leaf or that leaf's private lock/stage paths.
  Refuse every broader or unrelated target even if a caller regresses."
  [dir path]
  (when-not (or (= path dir)
                (= path (git-cache-lock-dir dir))
                (= path (git-cache-stage-dir dir)))
    (throw (ex-info (str "refusing unsafe git cache removal " path)
                    {:cache-entry dir :path path})))
  (when (file-exists? path)
    (when-not (zero? (sh (str "rm -rf -- " (shell-quote path))))
      (throw (ex-info (str "could not remove incomplete git cache entry " path)
                      {:path path}))))
  nil)

(defn- release-git-cache-ownership!
  "Remove private stage residue before releasing the stable ownership lock.
  Never release the lock while the stage still exists: a later caller must not
  observe transaction-private state without its coordinating owner."
  [dir lock]
  (let [stage (git-cache-stage-dir dir)]
    (remove-own-cache-path! dir stage)
    (when (file-exists? stage)
      (throw
        (ex-info (str "git cache stage remains after cleanup " stage)
                 {:type ::git-cache-stage-cleanup-failed
                  :path dir :lock lock :stage stage})))
    (remove-own-cache-path! dir lock)))

(defn- git-cache-cleanup-failed!
  "Preserve the operation failure when transaction cleanup also fails."
  [dir lock primary cleanup]
  (throw
    (ex-info (str "git cache cleanup failed while handling an earlier failure "
                  dir)
             {:type ::git-cache-cleanup-failed
              :path dir :lock lock :stage (git-cache-stage-dir dir)
              :primary-error primary :cleanup-error cleanup}
             primary)))

(defn- cache-origin-mismatch!
  [inspection url sha dir]
  (throw
    (ex-info
      (str "git cache entry has a different literal origin; refusing to "
           "replace it because this may be a URL-key collision: " dir)
      {:type ::git-cache-origin-mismatch
       :url url :sha sha :path dir :inspection inspection})))

(defn- unowned-cache-entry!
  [inspection url sha dir]
  (throw
    (ex-info
      (str "git cache entry has no durable origin claim and is not an "
           "inspectable checkout; refusing to replace it: " dir)
      {:type ::git-cache-unowned-entry
       :url url :sha sha :path dir :inspection inspection})))

(defn- claim-cache-origin!
  "Record literal ownership while holding this leaf's publication lock. The
  marker precedes publication and survives checkout corruption or failed
  retries. Publish the marker by same-filesystem rename so a killed writer
  cannot leave a truncated claim. A caller must re-read it before relying on
  the claim."
  [dir lock url sha]
  (let [marker (git-cache-origin-marker dir)
        stage (str lock "/origin-claim")]
    (when-not (file-exists? marker)
      (spit stage url)
      (try
        (java.nio.file.Files/move
          (.toPath (java.io.File. stage))
          (.toPath (java.io.File. marker))
          (into-array java.nio.file.CopyOption []))
        (catch :default _
          ;; Another actor may have published between the existence check and
          ;; rename. The mandatory re-read below decides whether that is benign.
          nil)))
    (let [claim (git-cache-origin-claim dir url)]
      (when-not (and (:claimed? claim) (:matches? claim))
        (cache-origin-mismatch! claim url sha dir)))
    marker))

(defn- publish-git-checkout!
  "Publish `stage` without replacement/nesting, then validate the final path
  while ownership is still held."
  [stage dir url sha]
  (when (file-exists? dir)
    (throw (ex-info (str "git cache destination appeared during publication " dir)
                    {:type ::git-cache-publish-conflict
                     :url url :sha sha :path dir})))
  (try
    (java.nio.file.Files/move
      (.toPath (java.io.File. stage))
      (.toPath (java.io.File. dir))
      (into-array java.nio.file.CopyOption []))
    (catch :default cause
      (throw (ex-info (str "could not publish git checkout " dir)
                      {:type ::git-cache-publish-failed
                       :url url :sha sha :path dir :error cause}))))
  (let [inspection (git-checkout-inspection dir sha url)]
    (cond
      (:valid? inspection) dir
      (= :origin-mismatch (:reason inspection))
      (cache-origin-mismatch! inspection url sha dir)
      :else
      (do
        (remove-own-cache-path! dir dir)
        (throw (ex-info (str "published git checkout failed final validation "
                             dir)
                        {:type ::git-cache-final-validation-failed
                         :url url :sha sha :path dir
                         :inspection inspection}))))))

(defn- fetch-git-while-locked!
  "The caller owns `lock`. Clone into the short sibling stage, then publish with
  a same-filesystem rename only after checkout and recursive submodule
  initialisation succeed."
  [url sha dir lock]
  (let [stage (git-cache-stage-dir dir)
        outcome
        (try
          ;; A killed older owner can leave its private staging payload behind
          ;; if a user elects to remove/recover the lock. Never clone over that
          ;; residue.
          (remove-own-cache-path! dir stage)
          ;; The final target may be an empty/partial checkout from the pre-lock
          ;; implementation. It is safe to repair only this exact url@sha leaf.
          (remove-own-cache-path! dir dir)
          (info "fetching " url " @ " (subs sha 0 (min 12 (count sha))))
          (when-not (zero? (sh (str git-command-prefix
                                    " clone --quiet --origin origin -- "
                                    (shell-quote url)
                                    " " (shell-quote stage))))
            (throw (ex-info (str "git clone failed: " url)
                            {:url url :sha sha})))
          ;; Git canonicalizes a relative/local clone source before storing it in
          ;; remote.origin.url. Cache identity is the dependency's literal URL,
          ;; so restore that exact spelling before strict origin validation.
          (when-not
            (zero?
              (sh (str git-command-prefix " -C " (shell-quote stage)
                       " config --local --replace-all remote.origin.url "
                       (shell-quote url))))
            (throw
              (ex-info (str "could not record literal git origin: " url)
                       {:url url :sha sha :path stage})))
          (when-not
            (zero? (sh (str git-command-prefix " -C " (shell-quote stage)
                            " checkout --quiet " (shell-quote sha))))
            (throw (ex-info (str "git checkout failed: " sha " in " url)
                            {:url url :sha sha})))
          ;; Submodules are part of the pinned checkout and therefore part of
          ;; the transaction: a failure must not publish the parent repository.
          (when-not
            (zero? (sh (str git-command-prefix " -C " (shell-quote stage)
                            " submodule update --init --recursive --quiet")))
            (throw (ex-info (str "git submodule update failed for " url)
                            {:url url :sha sha})))
          (when-not (git-checkout-valid? stage sha url)
            (let [inspection (git-checkout-inspection stage sha url)]
              (throw
                (ex-info (str "git checkout validation failed: " url " @ " sha)
                         {:url url :sha sha :path stage
                          :inspection inspection}))))
          {:ok? true
           :value (publish-git-checkout! stage dir url sha)}
          (catch :default cause
            {:ok? false :error cause}))]
    (if (:ok? outcome)
      (do
        (release-git-cache-ownership! dir lock)
        (:value outcome))
      (let [cause (:error outcome)]
        (try
          (release-git-cache-ownership! dir lock)
          (catch :default cleanup
            (git-cache-cleanup-failed! dir lock cause cleanup)))
        (throw cause)))))

(defn- ensure-own-git
  "Return jolt's verified checkout for url@sha. An atomic mkdir is the bounded
  ownership protocol: one writer stages under the lock while losers wait for a
  verified publication. A crashed owner leaves a visible lock and produces a
  bounded, actionable error instead of allowing a second writer to consume or
  overwrite its partial state."
  [url sha dir]
  (let [parent (subs dir 0 (.lastIndexOf dir "/"))
        lock (git-cache-lock-dir dir)
        stage (git-cache-stage-dir dir)]
    (when-not (.mkdirs (java.io.File. parent))
      (when-not (.isDirectory (java.io.File. parent))
        (throw (ex-info (str "could not create git cache directory " parent)
                        {:path parent}))))
    (loop [attempt 0]
      (let [claim (git-cache-origin-claim dir url)
            inspection (git-checkout-inspection dir sha url)]
        (cond
          (and (:claimed? claim) (not (:matches? claim)))
          (cache-origin-mismatch! claim url sha dir)

          (= :origin-mismatch (:reason inspection))
          (cache-origin-mismatch! inspection url sha dir)

          (and (:valid? inspection) (:matches? claim)) dir

          (and (not (:claimed? claim))
               (file-exists? dir)
               (= :not-worktree (:reason inspection)))
          (unowned-cache-entry! inspection url sha dir)

          ;; mkdir is atomic: success grants exclusive ownership of this one
          ;; url@sha publication without serialising unrelated dependencies.
          (.mkdir (java.io.File. lock))
          (try
            (spit (str lock "/owner.edn")
                  (pr-str {:started-ms (System/currentTimeMillis)
                           :sha sha
                           :jolt-version (jolt.host/jolt-version)}))
            ;; Re-read durable identity and final state after acquiring the lock
            ;; and before touching an orphan stage. Manual stale-lock recovery
            ;; or a forced key collision must never turn a pre-lock observation
            ;; into permission to delete another origin's transaction state.
            (let [owned-claim (git-cache-origin-claim dir url)
                  owned-inspection (git-checkout-inspection dir sha url)]
              (cond
                (and (:claimed? owned-claim) (not (:matches? owned-claim)))
                (do
                  (remove-own-cache-path! dir lock)
                  (cache-origin-mismatch! owned-claim url sha dir))

                (= :origin-mismatch (:reason owned-inspection))
                (do
                  (remove-own-cache-path! dir lock)
                  (cache-origin-mismatch! owned-inspection url sha dir))

                (and (not (:claimed? owned-claim))
                     (file-exists? dir)
                     (= :not-worktree (:reason owned-inspection)))
                (do
                  (remove-own-cache-path! dir lock)
                  (unowned-cache-entry! owned-inspection url sha dir))

                (and (:valid? owned-inspection) (:matches? owned-claim))
                (do
                  (release-git-cache-ownership! dir lock)
                  dir)

                (:valid? owned-inspection)
                (do
                  (claim-cache-origin! dir lock url sha)
                  (release-git-cache-ownership! dir lock)
                  dir)

                :else
                (do
                  (when-not (:claimed? owned-claim)
                    (claim-cache-origin! dir lock url sha))
                  (fetch-git-while-locked! url sha dir lock))))
            (catch :default cause
              ;; A fetch cleans stage before lock. Errors before that transaction
              ;; may safely release only when no private stage remains. Preserve
              ;; both failures if this final cleanup attempt also fails.
              (when (and (file-exists? lock)
                         (not (file-exists? stage)))
                (try
                  (remove-own-cache-path! dir lock)
                  (catch :default cleanup
                    (git-cache-cleanup-failed! dir lock cause cleanup))))
              (throw cause)))

          (< attempt git-lock-wait-attempts)
          (do (Thread/sleep git-lock-wait-ms)
              (recur (inc attempt)))

          :else
          (let [owner-file (str lock "/owner.edn")
                owner (when (file-exists? owner-file)
                        (try (slurp owner-file)
                             (catch :default _ nil)))]
            (throw
              (ex-info
                (str "timed out waiting for git cache owner at " lock
                     "; if no jolt process is fetching this dependency, remove "
                     "that single stale lock directory and retry")
                {:url url :sha sha :path dir :lock lock
                 :owner owner
                 :wait-ms (* git-lock-wait-attempts
                             git-lock-wait-ms)}))))))))

(defn- full-sha? [s] (and (string? s) (= 40 (count s)) (re-matches #"[0-9a-f]+" s)))

(defn- resolve-git-tag
  "Resolve a tag to its commit sha via git ls-remote, preferring the peeled
  ^{} ref (an annotated tag's target commit). Cached under the gitlibs dir —
  a tag+sha coordinate is reproducible via the sha, the tag resolution is only
  consulted to verify/complete it, so a cached answer is fine."
  [url tag]
  (let [cache (str (gitlibs-dir) "/tags/" (sanitize url) "/" (sanitize tag))]
    (if (file-exists? cache)
      (str/trim (slurp cache))
      (when-let [out (sh-out (str "git ls-remote " (pr-str url) " "
                                  (pr-str (str "refs/tags/" tag)) " "
                                  (pr-str (str "refs/tags/" tag "^{}"))))]
        (let [lines (str/split-lines out)
              parse (fn [suffix]
                      (some (fn [l] (let [[sha ref] (str/split l #"\s+")]
                                      (when (and ref (str/ends-with? ref suffix)) sha)))
                            lines))
              sha (or (parse "^{}") (parse (str "refs/tags/" tag)))]
          (when sha
            (sh (str "mkdir -p " (pr-str (str (gitlibs-dir) "/tags/" (sanitize url)))))
            (spit cache sha)
            sha))))))

(defn- resolve-git-sha
  "The full commit sha a git coordinate pins: a full :git/sha as-is; with a
  :git/tag, a short (prefix) sha is completed from the tag's commit and a full
  sha is verified against it — like tools.deps, a tag alone doesn't pin."
  [coord url {:git/keys [sha tag] :as spec}]
  (cond
    (and sha (full-sha? sha) (not tag)) sha
    (and tag sha)
    (let [tag-sha (or (resolve-git-tag url tag)
                      (throw (ex-info (str "git dep " coord ": tag " tag " not found in " url)
                                      {:coord coord :spec spec})))]
      (if (str/starts-with? tag-sha sha)
        tag-sha
        (throw (ex-info (str "git dep " coord ": :git/sha " sha " does not match tag "
                             tag " (" tag-sha ")")
                        {:coord coord :spec spec :tag-sha tag-sha}))))
    (full-sha? sha) sha
    :else
    (throw (ex-info
             (str "git dep " coord " needs :git/sha — the full commit sha, or a "
                  "prefix of it alongside :git/tag"
                  (when (and tag (not sha)) " (a :git/tag alone doesn't pin a commit)") ".")
             {:coord coord :spec spec}))))

(defn- ensure-git
  "Return a checkout dir for url@sha: an existing tools.gitlibs checkout for
  `lib` when present, else transactionally clone into jolt's cache (once)."
  [lib url sha]
  (when-not (git-sha? sha)
    (throw (ex-info
             (str "git dep " lib " needs a hexadecimal :git/sha commit prefix "
                  "of 7 to 64 characters, got " (pr-str sha))
             {:lib lib :url url :sha sha})))
  (let [sha (str/lower-case sha)
        dir (git-cache-entry-dir url sha)
        claim (git-cache-origin-claim dir url)
        inspection (git-checkout-inspection dir sha url)]
    (cond
      (and (:claimed? claim) (not (:matches? claim)))
      (cache-origin-mismatch! claim url sha dir)

      (= :origin-mismatch (:reason inspection))
      (cache-origin-mismatch! inspection url sha dir)

      (and (:valid? inspection) (:matches? claim)) dir

      :else
      ;; Reuse is read-only. Validation shells out to git but never touches the
      ;; tools.gitlibs bookkeeping/worktree.
      (if-let [shared (gitlibs-shared-checkout lib sha)]
        shared
        (ensure-own-git url sha dir)))))

;; --- maven cache ------------------------------------------------------------
;; jolt has no JVM, but a Clojure library's Maven JAR carries its .clj/.cljc/.cljs
;; SOURCE (Clojure ships source, not just bytecode). So a :mvn/version coordinate
;; resolves by fetching the JAR (Clojars, then Central), extracting it, and using
;; the extraction as a source root — its pom.xml supplies the transitive deps.
;; A JAR of pure Java classes has no source to run and simply contributes nothing.
;;
;; JARs live at their standard path in the local Maven repository
;; (~/.m2/repository), so they are shared with JVM Clojure/tools.deps in both
;; directions: an artifact clj already fetched is reused without a download, and
;; one jolt fetches is there for clj. The jolt-only source extraction sits in a
;; "<artifact>-<version>.jar.jolt/" directory beside the jar. The repository
;; location is configured the way tools.deps configures it — the :mvn/local-repo
;; top key of deps.edn (also accepted in an add-deps map); anyone already using
;; it gets the same behavior for free. JOLT_LOCAL_REPO overrides it from the
;; environment as a jolt-specific convenience. Setting JOLT_MVNLIBS opts out of
;; sharing entirely: the legacy self-contained layout under it, jar not kept.

(def ^:private ^:dynamic *mvn-local-repo*
  "The :mvn/local-repo of the resolution in progress (bound by resolve-project /
  add-deps from their deps.edn / deps map), nil for the default." nil)

(defn- m2-repo-dir
  "The local Maven repository dir, resolved like tools.deps: JOLT_LOCAL_REPO
  (env, jolt-specific convenience) wins, then :mvn/local-repo, then
  ~/.m2/repository."
  ([] (m2-repo-dir (getenv "JOLT_LOCAL_REPO") *mvn-local-repo* (getenv "HOME")))
  ([env-override cfg home]
   (or env-override cfg (str (or home ".") "/.m2/repository"))))

(def ^:private default-mvn-repos
  ["https://repo.clojars.org" "https://repo1.maven.org/maven2"])

(def ^:private ^:dynamic *mvn-repos*
  "Repository base URLs consulted in order, bound by resolve-project from the
  merged deps.edn's :mvn/repos ({\"name\" {:url \"…\"}}, the tools.deps key) —
  defaults first, then custom repos sorted by name for a deterministic order."
  default-mvn-repos)

(defn- mvn-repo-urls [edn]
  (into default-mvn-repos
        (keep (fn [[_name m]] (let [u (:url m)]
                                (when (and u (not-any? #(= % u) default-mvn-repos))
                                  (str/replace u #"/+$" ""))))
              (sort-by key (:mvn/repos edn)))))

(defn- mvn-group [coord] (or (namespace coord) (name coord)))

(defn- cache-fresh?
  "Is the extraction at `dir` still valid for `jar`? The `.jolt-ok` marker is
  written after a successful unzip; it is stale once the jar is rebuilt/refetched
  (a SNAPSHOT, or the same coord re-installed into ~/.m2). A POSIX `test -nt`
  re-extracts when the jar is newer than the marker. The legacy JOLT_MVNLIBS
  layout keeps no jar, so its extraction is the only copy — trust it. A jar that
  has since vanished (m2 pruned) also leaves the extraction as the last good copy."
  [dir jar legacy]
  (let [ok (str dir "/.jolt-ok")]
    (and (file-exists? ok)
         (or legacy
             (not (file-exists? jar))
             (not (zero? (sh (str "test " (pr-str jar) " -nt " (pr-str ok)))))))))

(defn- extract-jar!
  "Unzip `jar` into `dir` (overwriting), marking `.jolt-ok` only on success so a
  failed/partial unzip is never trusted as a complete extraction. A stale
  `.jolt-ok` from a prior extraction is cleared first, so a failed re-extract
  isn't left looking valid. Returns dir on success, nil on failure (a non-fatal
  skip). The jar may live inside `dir` (the legacy JOLT_MVNLIBS layout), so `dir`
  is not wiped."
  [jar dir]
  (sh (str "mkdir -p " (pr-str dir)))
  (sh (str "rm -f " (pr-str (str dir "/.jolt-ok"))))
  (if (zero? (sh (str "unzip -o -q " (pr-str jar) " -d " (pr-str dir))))
    (do (sh (str "touch " (pr-str (str dir "/.jolt-ok")))) dir)
    (do (warn "failed to extract " jar) nil)))

(defn- ensure-maven
  "Ensure coord@version's JAR is in the local Maven repository (reusing one the
  JVM toolchain already fetched; downloading from Clojars then Central when
  absent) and extract its source beside it. Re-extracts when the jar is newer
  than the last extraction. Returns the extraction dir, or nil if no repo has the
  artifact / extraction failed (a non-fatal skip)."
  [coord version]
  (let [group (mvn-group coord) artifact (name coord)
        vdir-rel (str (str/replace group "." "/") "/" artifact "/" version)
        jar-name (str artifact "-" version ".jar")
        legacy (getenv "JOLT_MVNLIBS")
        dir (if legacy
              (str legacy "/" (sanitize (str coord)) "/" (sanitize version))
              (str (m2-repo-dir) "/" vdir-rel "/" jar-name ".jolt"))
        jar (if legacy
              (str dir "/dep.jar")
              (str (m2-repo-dir) "/" vdir-rel "/" jar-name))]
    (if (cache-fresh? dir jar legacy)
      dir
      (if (and (not legacy) (file-exists? jar))
        (do (info "using " jar-name " from the local Maven repository")
            (extract-jar! jar dir))
        (loop [repos *mvn-repos*]
          (if (empty? repos)
            (do (warn "maven dep " coord " " version " not found (tried " (str/join ", " *mvn-repos*) ")") nil)
            (if (do (sh (str "mkdir -p " (pr-str (if legacy dir (str (m2-repo-dir) "/" vdir-rel)))))
                    (http/fetch (str (first repos) "/" vdir-rel "/" jar-name) jar))
              (do (info "fetching " coord " " version)
                  (let [d (extract-jar! jar dir)]
                    ;; legacy layout never keeps the jar; the m2 layout does —
                    ;; that IS the sharing.
                    (when legacy (sh (str "rm -f " (pr-str jar))))
                    d))
              (recur (rest repos)))))))))

(defn- pom-deps-from
  "Transitive deps read from a pom.xml — as a deps map so the expansion walks
  them like any other. Skips test/provided/system scope, org.clojure/clojure
  (intrinsic), and non-literal versions (ranges / ${properties})."
  [pom]
  (do
    (when (file-exists? pom)
      (let [xml (slurp pom)
            grab (fn [tag block] (second (re-find (re-pattern (str "<" tag ">(.*?)</" tag ">")) block)))]
        (into {}
          (for [[_ block] (re-seq #"(?s)<dependency>(.*?)</dependency>" xml)
                :let [g (grab "groupId" block) a (grab "artifactId" block)
                      v (grab "version" block) scope (grab "scope" block)
                      optional (grab "optional" block)]
                ;; Maven does not inherit optional deps or test/provided/system
                ;; scope transitively — so a cljc lib's optional ClojureScript
                ;; toolchain (clojurescript, closure-compiler) stays out.
                :when (and g a v
                           (not (#{"test" "provided" "system"} scope))
                           (not= "true" optional)
                           (not (and (= g "org.clojure") (= a "clojure")))
                           (re-matches #"[0-9A-Za-z.\-]+" v))]
            [(symbol g a) {:mvn/version v}]))))))

;; --- git URL inference ------------------------------------------------------
;; tools.deps lets a git coordinate omit :git/url when the lib name encodes a
;; known host: `io.github.OWNER/REPO` resolves to https://github.com/OWNER/REPO.git,
;; and similarly for GitLab, Bitbucket, and Sourcehut. jolt honors the same
;; convention so a deps.edn copied from a tools.deps project resolves unchanged.
;; See https://clojure.org/reference/deps_edn#deps_git.
(def ^:private git-url-hosts
  ;; [namespace-prefix  url-prefix  url-suffix] — the URL is
  ;; url-prefix + OWNER + "/" + REPO + url-suffix, where OWNER is the coordinate
  ;; namespace with its host prefix stripped and REPO is the coordinate name.
  [["io.github."    "https://github.com/"    ".git"]
   ["com.github."   "https://github.com/"    ".git"]
   ["io.gitlab."    "https://gitlab.com/"    ".git"]
   ["com.gitlab."   "https://gitlab.com/"    ".git"]
   ["io.bitbucket."  "https://bitbucket.org/" ".git"]
   ["org.bitbucket." "https://bitbucket.org/" ".git"]
   ;; Sourcehut lib names carry the leading ~ in the owner, e.g. ht.sr.~owner/repo,
   ;; so stripping "ht.sr." leaves "~owner" and no .git suffix is used.
   ["ht.sr."        "https://git.sr.ht/"     ""]])

(defn- infer-git-url
  "The git clone URL a coordinate's lib name implies via the tools.deps host
  convention (io.github.OWNER/REPO -> https://github.com/OWNER/REPO.git), or nil
  when the namespace names no known host."
  [coord]
  (when-let [ns (namespace coord)]
    (some (fn [[prefix url-prefix url-suffix]]
            (when (str/starts-with? ns prefix)
              (str url-prefix (subs ns (count prefix)) "/" (name coord) url-suffix)))
          git-url-hosts)))

(defn- has-clj-source?
  "Does the tree hold any jolt-loadable source (.clj/.cljc)? A Maven JAR that is
  pure-Java (closure-compiler) or ClojureScript-only (cljs.java-time) has none —
  it contributes nothing to run and its transitive deps are the cljs/JVM toolchain,
  so the walk skips it rather than dragging in that whole subtree."
  [root]
  (zero? (sh (str "find " (pr-str root)
                  " \\( -name '*.clj' -o -name '*.cljc' \\) -print -quit 2>/dev/null | grep -q ."))))

;; --- coordinate skips + normalization ----------------------------------------
;; jolt IS Clojure, so org.clojure/clojure is intrinsic; jolt has no
;; ClojureScript compiler, so clojurescript (and the closure/rhino toolchain it
;; drags in) is dead weight a cljc library declares only for its :cljs branch.
(defn- intrinsic-dep? [lib]
  (or (= lib 'org.clojure/clojure) (= lib 'org.clojure/clojurescript)))

(defn- absolutize-local [spec base-dir]
  (if (and (map? spec) (:local/root spec))
    (update spec :local/root #(abspath base-dir %))
    spec))

(defn- filter-deps
  "Normalize a raw child/top deps map into expansion entries: drop intrinsics
  and obsolete :jolt/module coords, absolutize :local/root against the
  declaring project's dir. A nil coordinate survives (an alias's :default-deps
  may fill it during expansion)."
  [deps base-dir]
  (into []
        (keep (fn [[lib spec]]
                (cond
                  (intrinsic-dep? lib) nil
                  (:jolt/module spec)
                  (do (info "skipping janet dependency " lib " (:jolt/module is obsolete on Chez)") nil)
                  :else [lib (absolutize-local spec base-dir)])))
        deps))

(defn- known-coord? [coord]
  (try (some? (ext/coord-type coord)) (catch :default _ false)))

(defn- warn-unsupported [lib coord]
  (warn "skipping unsupported coordinate " lib " " (pr-str coord)
        "\n  a dependency needs one of:"
        "\n    {:mvn/version \"1.2.3\"}                              a Maven artifact"
        "\n    {:git/url \"https://…\" :git/sha \"<full-sha>\"}       an explicit git repo"
        "\n    {:git/sha \"<full-sha>\"} on io.github.OWNER/REPO     a git repo by host-prefixed name"
        "\n    {:git/tag \"v1.2\" :git/sha \"<short-sha>\"}           a git repo pinned by tag + sha prefix"
        "\n    {:local/root \"../path\"}                             a directory (or jar) on disk"))

;; --- coordinate extensions ----------------------------------------------------
;; The :mvn / :git / :local coordinate types implement the jolt.deps.ext SPI
;; over jolt's procurement (ensure-maven / ensure-git / local dirs). Procurement
;; is memoized per resolution (*procure-memo*).

(def ^:private ^:dynamic *procure-memo* nil)
(defn- memoized [k f]
  (if *procure-memo*
    (if-let [e (find @*procure-memo* k)]
      (val e)
      (let [v (f)] (swap! *procure-memo* assoc k v) v))
    (f)))

(defn- manifest-info
  "Manifest detection for a git/local directory root: its deps.edn, else a bare
  source tree. A directory with no deps.edn contributes its default `src` path
  and no transitive deps — a pom.xml is only consulted for an EXTRACTED artifact
  (a Maven dep or a jar local root), where it is the only source of children."
  [root]
  (if (file-exists? (str root "/deps.edn"))
    (let [edn (try (some-> (read-edn (str root "/deps.edn")) dedn/canonicalize)
                   (catch :default e (warn (ex-message e)) nil))]
      (when (and edn (:deps edn) (not (map? (:deps edn))))
        (throw (ex-info (str "malformed :deps in " root "/deps.edn: expected a map")
                        {:path root :given (class (:deps edn))})))
      {:root root :manifest :deps-edn :edn edn})
    {:root root :manifest :deps-edn :edn nil}))

(defmethod ext/coord-type-keys :mvn [_] #{:mvn/version})
(defmethod ext/coord-type-keys :git [_] #{:git/url :git/sha :git/tag})
(defmethod ext/coord-type-keys :local [_] #{:local/root})

(defmethod ext/dep-id :mvn [_ coord] (select-keys coord [:mvn/version]))
(defmethod ext/dep-id :git [_ coord] (select-keys coord [:git/url :git/sha :git/tag]))
(defmethod ext/dep-id :local [_ coord] (select-keys coord [:local/root]))

(defn- mvn-info [lib coord]
  (memoized [:info lib (ext/dep-id lib coord)]
    (fn []
      (let [root (ensure-maven lib (:mvn/version coord))]
        (cond
          (nil? root) {:root nil :manifest :none}
          ;; a Maven dep with no jolt-loadable source contributes nothing and
          ;; its transitive deps are cljs/JVM tooling — don't walk them.
          (not (has-clj-source? root)) {:root nil :manifest :none}
          :else {:root root :manifest :mvn
                 :pom (str root "/META-INF/maven/" (mvn-group lib) "/" (name lib) "/pom.xml")})))))

(defn- git-info [lib coord]
  (memoized [:info lib (ext/dep-id lib coord)]
    (fn []
      (let [url (or (:git/url coord) (infer-git-url lib)
                    (throw (ex-info
                             (str "git dep " lib " has no :git/url and none could be inferred "
                                  "from its lib name. Add :git/url, or name the coordinate after "
                                  "its host, e.g. io.github.OWNER/REPO for a GitHub repo.")
                             {:lib lib :coord coord})))
            sha (resolve-git-sha lib url coord)
            checkout (ensure-git lib url sha)
            root (if-let [r (:deps/root coord)] (str checkout "/" r) checkout)]
        (assoc (manifest-info root) :sha sha :url url :checkout checkout)))))

(defn- jar-extraction-dir [jar]
  (str (or (getenv "JOLT_JARLIBS")
           (str (or (getenv "HOME") ".") "/.jolt/jarlibs"))
       "/" (sanitize jar)))

(defn- local-info [lib coord]
  (memoized [:info lib (ext/dep-id lib coord)]
    (fn []
      (let [path (:local/root coord)]
        (if (str/ends-with? path ".jar")
          ;; a jar local root extracts into a cache keyed by the jar path (the
          ;; jar's directory may not be writable) and is re-extracted when the
          ;; jar is newer than the extraction, like a Maven jar.
          (let [dir (jar-extraction-dir path)]
            (if (or (cache-fresh? dir path false)
                    (extract-jar! path dir))
              (let [pom (sh-out (str "find " (pr-str dir) "/META-INF -name pom.xml -print -quit 2>/dev/null"))]
                {:root dir :manifest :mvn :pom (when (and pom (not (str/blank? pom))) pom)})
              {:root nil :manifest :none}))
          (manifest-info path))))))

(defmethod ext/coord-info :mvn [lib coord] (mvn-info lib coord))
(defmethod ext/coord-info :git [lib coord] (git-info lib coord))
(defmethod ext/coord-info :local [lib coord] (local-info lib coord))

(defn- children-of [{:keys [root manifest edn pom]}]
  (cond
    (nil? root) []
    (= manifest :deps-edn) (filter-deps (:deps edn) root)
    (and (= manifest :mvn) pom (file-exists? pom)) (filter-deps (pom-deps-from pom) root)
    :else []))

(defmethod ext/coord-deps :mvn [lib coord] (children-of (mvn-info lib coord)))
(defmethod ext/coord-deps :git [lib coord] (children-of (git-info lib coord)))
(defmethod ext/coord-deps :local [lib coord] (children-of (local-info lib coord)))

;; version comparison: Maven versions order by ComparableVersion semantics;
;; git shas by commit ancestry when determinable from an existing clone. Any
;; other pairing has no order — the expansion warns and keeps the already-
;; selected coordinate (tools.deps throws instead; jolt prefers resolving with
;; the first-seen version over failing the whole resolution).
(defmethod ext/compare-versions [:mvn :mvn] [_ x y]
  (ext/compare-mvn-versions (:mvn/version x) (:mvn/version y)))

(defn- git-ancestor? [dir a b]
  (zero? (sh (str "git -C " (pr-str dir) " merge-base --is-ancestor " a " " b " 2>/dev/null"))))

(defmethod ext/compare-versions [:git :git] [lib x y]
  (let [xi (git-info lib x) yi (git-info lib y)
        xs (:sha xi) ys (:sha yi)]
    (cond
      (= xs ys) 0
      :else
      (let [in (fn [dir] (cond (git-ancestor? dir xs ys) -1
                               (git-ancestor? dir ys xs) 1))]
        (or (in (:checkout xi)) (in (:checkout yi))
            (throw (ex-info (str "No known ancestor relationship between git versions for " lib)
                            {:lib lib :x x :y y})))))))

;; --- dependency expansion -----------------------------------------------------
;; The tree expansion, exclusion handling, and version selection are taken
;; directly from clojure.tools.deps (expand-deps and friends), run serially:
;; a version map tracks every seen version of each lib and the selected one
;; (top dep wins; else newest by compare-versions), exclusions scope by the
;; dependency path, and orphaned children of deselected versions are cut.

(defn- excluded?
  [exclusions path lib]
  (let [lib-name (first (str/split (name lib) #"\$"))
        base-lib (symbol (namespace lib) lib-name)]
    (loop [search path]
      (when (seq search)
        (if (get-in exclusions [search base-lib])
          true
          (recur (pop search)))))))

(defn- update-excl
  "Update exclusions and cut based on whether this is a new lib/version,
  a new instance of an existing lib/version, or not including."
  [lib use-coord coord-id use-path include reason exclusions cut]
  (let [coord-excl (when-let [e (:exclusions use-coord)] (set e))]
    (cond
      ;; if adding new lib/version, include all non-excluded children
      include
      (if (nil? coord-excl)
        {:exclusions' exclusions, :cut' cut, :child-pred (constantly true)}
        {:exclusions' (assoc exclusions use-path coord-excl)
         :cut' (assoc cut [lib coord-id] coord-excl)
         :child-pred (fn [lib] (not (contains? coord-excl lib)))})

      ;; if seeing same lib/ver again, narrow exclusions to intersection of prior and new,
      ;; must reconsider previously included children as prev parent may get omitted
      (= reason :same-version)
      (let [exclusions' (if (seq coord-excl) (assoc exclusions use-path coord-excl) exclusions)
            cut-coord (get cut [lib coord-id]) ;; previously cut from this lib, so were not enqueued
            new-cut (set/intersection coord-excl cut-coord)
            enq-only (set/difference cut-coord new-cut)]
        {:exclusions' exclusions'
         :cut' (assoc cut [lib coord-id] new-cut)
         :child-pred (set enq-only)})

      :else ;; otherwise, no change
      {:exclusions' exclusions, :cut' cut})))

(defn- add-version
  "Add a new version of a lib to the version map"
  [vmap lib coord path coord-id]
  (-> (or vmap {})
    (assoc-in [lib :versions coord-id] coord)
    (update-in [lib :paths]
      (fn [coord-paths]
        (merge-with into {coord-id #{path}} coord-paths)))))

(defn- select-version
  "Mark a particular coord as selected in version map"
  [vmap lib coord-id top?]
  (update-in vmap [lib] merge (cond-> {:select coord-id}
                                top? (assoc :top true))))

(defn- selected-version [vmap lib] (get-in vmap [lib :select]))
(defn- selected-coord [vmap lib] (get-in vmap [lib :versions (selected-version vmap lib)]))
(defn- selected-paths [vmap lib] (get-in vmap [lib :paths (selected-version vmap lib)]))

(defn- parent-missing?
  "Is any part of the parent path missing from the selected lib/versions?
  This can happen if a newer version was found, orphaning previously selected children."
  [vmap parent-path]
  (loop [path parent-path
         more-paths nil]
    (if (seq path)
      (let [lib (last path)
            check-path (vec (butlast path))
            {:keys [paths select]} (get vmap lib)
            paths-to-selected (get paths select)]
        (if (contains? paths-to-selected check-path)
          ;; add alternative paths to root that include the selected lib
          (recur check-path (concat more-paths (remove #(= % check-path) paths-to-selected)))
          (if (seq more-paths)
            ;; consider alternative paths before considering lib to be omitted
            (recur (first more-paths) (rest more-paths))
            true)))
      false)))

(defn- deselect-orphans
  "For the given paths, deselect any libs whose only selected version paths are in omitted-paths"
  [vmap omitted-paths]
  (reduce-kv
    (fn [ret lib {:keys [select paths]}]
      (let [lib-paths (get paths select)]
        ;; if every selected path for this lib has omitted paths as prefixes, deselect
        (if (every? (fn [p] (some #(= % (take (count %) p)) omitted-paths)) lib-paths)
          (update-in ret [lib] dissoc :select)
          ret)))
    vmap
    vmap))

(defn- dominates?
  "Is new-coord newer than old-coord? A pairing with no defined order (git vs
  maven, unrelated git commits) warns and keeps the selected coordinate."
  [lib new-coord old-coord]
  (try (pos? (ext/compare-versions lib new-coord old-coord))
       (catch :default e
         (warn "version conflict for " lib ": keeping " (pr-str old-coord)
               " over " (pr-str new-coord) " (" (ex-message e) ")")
         false)))

(defn- include-coord?
  "This is the key decision-making function when considering a lib/coord node in
  the traversal graph. It returns :include (whether to include this lib/coord), a
  :reason why it was included or not, and an updated :vmap (may have new version added
  and/or new selected version for a lib)"
  [vmap lib coord coord-id path exclusions]
  (cond
    ;; lib is a top dep and this is it => select
    (empty? path)
    {:include true, :reason :new-top-dep,
     :vmap (-> vmap
             (add-version lib coord path coord-id)
             (select-version lib coord-id true))}

    ;; lib is excluded in this path => omit
    (excluded? exclusions path lib)
    {:include false, :reason :excluded, :vmap vmap}

    ;; lib is a top dep and this isn't it => omit
    (get-in vmap [lib :top])
    {:include false, :reason :use-top, :vmap vmap}

    ;; lib's parent path is not included => omit
    (parent-missing? vmap path)
    {:include false, :reason :parent-omitted, :vmap vmap}

    ;; new lib or no selection => select
    (not (selected-version vmap lib))
    {:include true, :reason :new-dep,
     :vmap (-> vmap
             (add-version lib coord path coord-id)
             (select-version lib coord-id false))}

    ;; existing lib, same version => omit (but update vmap, may need to enqueue newly unexcluded children)
    (= coord-id (selected-version vmap lib))
    {:include false, :reason :same-version, :vmap (add-version vmap lib coord path coord-id)}

    ;; existing lib, newer version => select
    (dominates? lib coord (selected-coord vmap lib))
    {:include true, :reason :newer-version,
     :vmap (-> vmap
             (add-version lib coord path coord-id)
             (deselect-orphans (set (map #(conj % lib) (selected-paths vmap lib))))
             (select-version lib coord-id false))}

    ;; existing lib, older version => omit
    :else
    {:include false, :reason :older-version, :vmap vmap}))

(defn- next-path
  [pendq q]
  (let [[fchild & rchildren] pendq]
    (if fchild
      {:path fchild, :pendq rchildren, :q' q}
      (let [next-q (peek q)
            q' (pop q)]
        (if (map? next-q)
          (let [{:keys [children ppath child-pred]} next-q]
            (recur (->> children (filter (fn [[lib _coord]] (child-pred lib))) (map #(conj ppath %))) q'))
          {:path next-q, :q' q'})))))

(defn- children-node [lib use-coord use-path child-pred]
  {:children (memoized [:deps lib (ext/dep-id lib use-coord)]
                       (fn [] (vec (ext/coord-deps lib use-coord))))
   :ppath use-path
   :child-pred child-pred})

(defn- expand-deps
  "Dep tree expansion, returns the version map. `order` is an atom collecting
  libs in first-inclusion order, so the final source roots keep a stable
  breadth-first precedence."
  [deps default-deps override-deps order]
  (loop [pendq nil ;; a resolved child list to look at first
         q (into clojure.lang.PersistentQueue/EMPTY (map vector deps)) ;; queue of nodes or child-lookups
         version-map nil ;; track all seen versions of libs and which version is selected
         exclusions nil ;; tracks exclusions marked in the tree
         cut nil] ;; tracks cuts made of child nodes based on exclusions
    (let [{:keys [path pendq q']} (next-path pendq q)]
      (if path
        (let [[lib coord] (peek path)
              parents (pop path)
              use-path (conj parents lib)
              override-coord (get override-deps lib)
              choose-coord (cond override-coord override-coord
                                 coord coord
                                 :else (get default-deps lib))]
          (if (or (nil? choose-coord) (not (known-coord? choose-coord)))
            (do (warn-unsupported lib choose-coord)
                (recur pendq q' version-map exclusions cut))
            (let [use-coord choose-coord
                  coord-id (ext/dep-id lib use-coord)
                  {:keys [include reason vmap]} (include-coord? version-map lib use-coord coord-id parents exclusions)
                  _ (when include (swap! order conj lib))
                  {:keys [exclusions' cut' child-pred]} (update-excl lib use-coord coord-id use-path include reason exclusions cut)
                  new-q (if child-pred (conj q' (children-node lib use-coord use-path child-pred)) q')]
              (recur pendq new-q vmap exclusions' cut'))))
        version-map))))

(defn- cut-orphans
  "Remove any selected lib that does not have a selected parent path"
  [version-map]
  (reduce-kv
    (fn [vmap lib {:keys [select]}]
      (if (nil? select)
        (dissoc vmap lib)
        vmap))
    version-map version-map))

(defn- lib-paths
  "Convert version map to lib map"
  [version-map]
  (reduce-kv
    (fn [ret lib {:keys [select versions]}]
      (assoc ret lib (get versions select)))
    {} version-map))

;; --- reconciliation ---------------------------------------------------------
;; Dependencies are resolved as a TREE (resolve-deps' BFS, which visits each
;; coordinate once) and then reconciled into a definitive, de-duplicated set —
;; one place, not ad-hoc per call site. dedup-by keeps the first item per key,
;; order preserved; it dedups both source roots (by path) and native libraries
;; (by identity), so an app pulling two libs that declare the same shared object
;; (e.g. libcrypto via both http-client and the ring adapter) includes and loads
;; it ONCE.
(defn- dedup-by [key xs]
  (second (reduce (fn [[seen acc] x]
                    (let [k (key x)]
                      (if (contains? seen k) [seen acc] [(conj seen k) (conj acc x)])))
                  [#{} []] xs)))

(defn- native-key
  "Identity of a :jolt/native spec. A :process lib (the running process's own
  symbols, e.g. libc) keys on that flag; a file lib on its :name, else on its
  platform candidate paths — two deps naming the same lib reconcile to one load."
  [spec]
  (letfn [(cands [k] (let [v (get spec k)] (cond (string? v) [v] (sequential? v) (vec v) :else [])))]
    (if (:process spec)
      [:process (:name spec)]
      [:native (or (:name spec) (vec (sort (concat (cands :darwin) (cands :linux) (cands :win)))))])))

(defn resolve-deps
  "Expand a deps map through the tools.deps expansion engine, then collect the
  selected libraries' source roots and :jolt/native declarations in stable
  first-inclusion order. Returns {:roots [...] :natives [...] :prep [...]
  :libs {lib coord}} — :libs is the tools.deps lib map (selected coordinate
  per library).

  `opts` carries the alias-combined coordinate maps applied at every node like
  tools.deps: :override-deps replaces a lib's coordinate wherever it appears
  (top-level or transitive); :default-deps supplies one where a dependent left
  the coordinate nil."
  ([deps base-dir] (resolve-deps deps base-dir nil))
  ([deps base-dir {:keys [override-deps default-deps]}]
   (binding [*procure-memo* (or *procure-memo* (atom {}))]
     (let [abs #(absolutize-local % base-dir)
           top (filter-deps deps base-dir)
           override-deps (some->> override-deps (map (fn [[l c]] [l (abs c)])) (into {}))
           default-deps (some->> default-deps (map (fn [[l c]] [l (abs c)])) (into {}))
           order (atom [])
           vmap (cut-orphans (expand-deps top default-deps override-deps order))
           libmap (lib-paths vmap)
           infos (keep (fn [lib]
                         (when-let [coord (get libmap lib)]
                           (let [info (ext/coord-info lib coord)]
                             (when (:root info) (assoc info :lib lib)))))
                       (distinct @order))]
       {:roots (vec (mapcat (fn [{:keys [root manifest edn]}]
                              (if (= manifest :deps-edn)
                                (map #(abspath root %) (or (:paths edn) ["src"]))
                                [root]))
                            infos))
        :natives (vec (mapcat (fn [{:keys [edn]}] (:jolt/native edn)) infos))
        ;; libs whose deps.edn declares :deps/prep-lib — jolt runs no prep
        ;; steps, so their compiled/generated assets will be missing; the
        ;; caller warns with the lib names.
        :prep (vec (keep (fn [{:keys [lib edn]}] (when (:deps/prep-lib edn) lib)) infos))
        :libs libmap}))))

;; --- public -----------------------------------------------------------------
(defn- user-deps-path
  "The user deps.edn location, per the same rules as clj: $CLJ_CONFIG, else
  $XDG_CONFIG_HOME/clojure, else ~/.clojure."
  []
  (let [cfg (getenv "CLJ_CONFIG")
        xdg (getenv "XDG_CONFIG_HOME")
        home (getenv "HOME")]
    (cond cfg (str cfg "/deps.edn")
          xdg (str xdg "/clojure/deps.edn")
          :else (str (or home ".") "/.clojure/deps.edn"))))

(defn- read-deps-file
  "Read + canonicalize a deps.edn file (simple lib symbols qualify with a
  deprecation warning, like tools.deps); nil when absent."
  [path]
  (some-> (read-edn path) dedn/canonicalize))

(defn resolve-project
  "Resolve `project-dir`'s deps.edn with the selected alias keywords. Returns
  {:roots [...] :main-opts [...] :tasks {...} :natives [...]}; :natives are the
  project's + deps' :jolt/native shared-library declarations.

  The deps.edn chain merges like tools.deps (jolt.deps.edn/merge-edns): the
  user deps.edn ($CLJ_CONFIG / $XDG_CONFIG_HOME/clojure / ~/.clojure — skipped
  under JOLT_NO_USER_DEPS), then the project deps.edn, then an optional extra
  map (the CLI's -Sdeps). Aliases combine from the merged map with the
  tools.deps rules (combine-aliases) and apply like tools.deps: :replace-deps
  (legacy :deps) replaces the project deps map, :extra-deps merges into it,
  :override-deps / :default-deps adjust coordinates at every node of the walk;
  :replace-paths (legacy :paths) replaces the project paths, :extra-paths
  appends; :main-opts is last-wins across the selected aliases. Custom Maven
  repositories come from the merged :mvn/repos."
  ([project-dir] (resolve-project project-dir []))
  ([project-dir alias-kws] (resolve-project project-dir alias-kws nil))
  ([project-dir alias-kws extra-edn] (resolve-project project-dir alias-kws extra-edn nil))
  ([project-dir alias-kws extra-edn {:keys [tool?]}]
   (let [project-edn (read-deps-file (str project-dir "/deps.edn"))
         user-edn (when-not (getenv "JOLT_NO_USER_DEPS")
                    (try (read-deps-file (user-deps-path))
                         (catch :default e (warn (ex-message e)) nil)))
         edn (dedn/merge-edns [user-edn project-edn (some-> extra-edn dedn/canonicalize)])
         argmap (dedn/combine-aliases edn alias-kws)
         ;; an unknown alias is an error, matching tools.deps ("Specified
         ;; aliases are undeclared") — silently ignoring a typo'd alias runs
         ;; the program without its deps and fails somewhere far away.
         _ (let [missing (remove #(get-in edn [:aliases %]) alias-kws)]
             (when (seq missing)
               (throw (ex-info (str "Specified aliases are undeclared: " (vec missing))
                               {:aliases (vec missing)}))))
         main-opts (:main-opts argmap)
         ;; tool mode (-T): the project's own paths and deps are replaced —
         ;; the tool's alias supplies its own (clj CLI tool-basis defaults
         ;; :replace-paths ["."] :replace-deps {}).
         project-paths (concat (or (:replace-paths argmap) (:paths argmap)
                                   (if tool? ["."] (or (:paths edn) ["src"])))
                               (:extra-paths argmap))
         project-roots (map #(abspath project-dir %) project-paths)
         all-deps (merge (or (:replace-deps argmap) (:deps argmap)
                             (if tool? {} (:deps edn)))
                         (:extra-deps argmap))
         {dep-roots :roots dep-natives :natives prep-libs :prep}
         (binding [*mvn-local-repo* (when-let [r (:mvn/local-repo edn)]
                                      (abspath project-dir r))
                   *mvn-repos* (mvn-repo-urls edn)]
           (resolve-deps all-deps project-dir
                         {:override-deps (:override-deps argmap)
                          :default-deps (:default-deps argmap)}))
         _ (when (seq prep-libs)
             (warn "deps declare :deps/prep-lib steps jolt does not run "
                   "(their compiled/generated assets will be missing): "
                   (str/join ", " prep-libs)))]
     ;; reconcile: the project's own roots/natives + every dep's, deduped once.
     {:roots (dedup-by identity (concat project-roots dep-roots))
      :main-opts main-opts
      ;; the combined alias args map — the CLI's -X/-T read :exec-fn /
      ;; :exec-args / :ns-default / :ns-aliases from it.
      :argmap argmap
      ;; the project's own paths (relative to project-dir) and absolute resource
      ;; roots, plus its :jolt/build options — `jolt build` uses these to bundle
      ;; resources into / alongside a standalone binary.
      :project-dir project-dir
      :project-paths (vec project-paths)
      :project-roots (vec project-roots)
      :build (:jolt/build edn)
      :embed-dirs (mapv #(abspath project-dir %) (:embed (:jolt/build edn)))
      :tasks (:tasks edn)
      :natives (dedup-by native-key (concat (:jolt/native edn) dep-natives))
      ;; nREPL middleware a library contributes (jolt.nrepl composes them over its
      ;; built-in handler) — symbols resolving to a middleware fn or a vector of them.
      :nrepl-middleware (:nrepl/middleware edn)})))

(defn add-deps
  "Resolve an inline deps map and add the resulting source roots to the loader,
  so a following `require` can load them — the programmatic twin of a deps.edn
  :deps entry, mirroring babashka.deps/add-deps:

    (add-deps '{:deps {org.clojure/data.json {:mvn/version \"2.5.0\"}}})
    (require '[clojure.data.json :as json])

  Coordinates: :git/url + :git/sha (:git/url may be omitted when the lib name
  names a host, e.g. io.github.OWNER/REPO), :local/root (resolved against
  JOLT_PWD), and :mvn/version (JAR source fetched from Clojars, then Central). A top-level
  :mvn/local-repo in the map relocates the Maven repository for this call,
  like the deps.edn key. New roots
  are appended AFTER the current roots, so an added dep can never shadow a
  namespace the runtime already resolves. Returns the vector of roots added
  (empty when everything was already on the roots).

  :jolt/native declarations carried by added deps are NOT auto-loaded (that is
  a project-launch concern — see jolt.main); a warning names them so the
  caller can load via jolt.ffi. The second arity accepts an options map for
  babashka call-shape compatibility; no options are currently honored."
  ([deps-map] (add-deps deps-map nil))
  ([{:keys [deps] :as m} _opts]
   (let [base (or (getenv "JOLT_PWD") ".")
         {:keys [roots natives]}
         (binding [*mvn-local-repo* (when-let [r (:mvn/local-repo m)]
                                      (abspath base r))]
           (resolve-deps deps base))
         current (vec (jolt.host/source-roots))
         added (vec (remove (set current) (dedup-by identity roots)))]
     (when (seq added)
       (jolt.host/set-source-roots! (into current added)))
     (when (seq natives)
       (info "added deps declare :jolt/native libraries (not auto-loaded): "
             (pr-str (dedup-by native-key natives))))
     added)))
