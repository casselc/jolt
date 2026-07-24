(ns jolt.deps
  "Resolve a deps.edn into an ordered list of source roots. A reduced
  tools.deps: :paths, :deps (`:git/url`+`:git/sha` / `:local/root` /
  `:mvn/version`), :aliases (:extra-paths / :extra-deps / :main-opts), :tasks.

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
            [clojure.string :as str]
            [jolt.mvn-http :as http]))

;; --- small host seams -------------------------------------------------------
(defn- getenv [n] (jolt.host/getenv n))
(defn- file-exists? [p] (jolt.host/file-exists? p))
(defn- sh [cmd] (jolt.host/sh cmd))           ; exit code, inherits stdout/stderr
(defn- warn [& xs] (binding [*out* *err*] (println (str "[jolt.deps] " (apply str xs)))))
;; Progress / informational lines (fetching, using-cache, skipping, added-natives)
;; print only when JOLT_DEBUG is set — otherwise a routine run (e.g. a ys-generated
;; program pulling a native-declaring lib) barfs them on every invocation. Genuine
;; warnings (an unresolvable dep, a malformed deps.edn) always print via `warn`.
(defn- info [& xs] (when (jolt.host/getenv "JOLT_DEBUG") (apply warn xs)))

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
    (str "git --no-optional-locks --no-replace-objects"
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
                      " | git hash-object --stdin"))
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
                        (let [sub-dirs
                              (git-result
                                dir ["submodule" "foreach" "--quiet"
                                     "--recursive" "pwd"])]
                          (if-not (result-ok? sub-dirs)
                            {:valid? false :reason :git-error
                             :operation :submodule-foreach :path dir
                             :exit (:exit sub-dirs)}
                            (or
                              (some
                                (fn [subdir]
                                  (let [inspection
                                        (inspect-worktree-state subdir)]
                                    (when-not (:valid? inspection)
                                      (assoc inspection
                                             :submodule? true
                                             :checkout-path dir))))
                                (result-lines sub-dirs))
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

(defn- remove-own-cache-path!
  "Remove only the final url@sha leaf or that leaf's private lock/stage paths.
  Refuse every broader or unrelated target even if a caller regresses."
  [dir path]
  (when-not (or (= path dir)
                (= path (str dir ".jolt-lock"))
                (= path (str dir ".jolt-lock/checkout")))
    (throw (ex-info (str "refusing unsafe git cache removal " path)
                    {:cache-entry dir :path path})))
  (when (file-exists? path)
    (when-not (zero? (sh (str "rm -rf " (shell-quote path))))
      (throw (ex-info (str "could not remove incomplete git cache entry " path)
                      {:path path}))))
  nil)

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
  "The caller owns `lock`. Clone beneath it, then publish with a same-filesystem
  rename only after checkout and recursive submodule initialisation succeed."
  [url sha dir lock]
  (let [stage (str lock "/checkout")]
    (try
      ;; A killed older owner can leave its private staging payload behind if a
      ;; user elects to remove/recover the lock. Never clone over that residue.
      (remove-own-cache-path! dir stage)
      ;; The final target may be an empty/partial checkout from the pre-lock
      ;; implementation. It is safe to repair only this exact url@sha leaf.
      (remove-own-cache-path! dir dir)
      (info "fetching " url " @ " (subs sha 0 (min 12 (count sha))))
      (when-not (zero? (sh (str "git clone --quiet --origin origin "
                                (shell-quote url)
                                " " (shell-quote stage))))
        (throw (ex-info (str "git clone failed: " url) {:url url :sha sha})))
      ;; Git canonicalizes a relative/local clone source before storing it in
      ;; remote.origin.url. Cache identity is the dependency's literal URL, so
      ;; restore that exact spelling before strict origin validation.
      (when-not
        (zero?
          (sh (str "git -C " (shell-quote stage)
                   " config --local --replace-all remote.origin.url "
                   (shell-quote url))))
        (throw
          (ex-info (str "could not record literal git origin: " url)
                   {:url url :sha sha :path stage})))
      (when-not (zero? (sh (str "git -C " (shell-quote stage)
                                " checkout --quiet " (shell-quote sha))))
        (throw (ex-info (str "git checkout failed: " sha " in " url)
                        {:url url :sha sha})))
      ;; Submodules are part of the pinned checkout and therefore part of the
      ;; transaction: a failure must not publish the parent repository.
      (when-not (zero? (sh (str "git -C " (shell-quote stage)
                                " submodule update --init --recursive --quiet")))
        (throw (ex-info (str "git submodule update failed for " url)
                        {:url url :sha sha})))
      (when-not (git-checkout-valid? stage sha url)
        (let [inspection (git-checkout-inspection stage sha url)]
          (throw (ex-info (str "git checkout validation failed: " url " @ " sha)
                          {:url url :sha sha :path stage
                           :inspection inspection}))))
      (publish-git-checkout! stage dir url sha)
      (finally
        ;; On success this removes an empty lock dir. On any failure it removes
        ;; only this target's private staging tree, leaving no publishable
        ;; residue for a retry.
        (remove-own-cache-path! dir lock)))))

(defn- ensure-own-git
  "Return jolt's verified checkout for url@sha. An atomic mkdir is the bounded
  ownership protocol: one writer stages under the lock while losers wait for a
  verified publication. A crashed owner leaves a visible lock and produces a
  bounded, actionable error instead of allowing a second writer to consume or
  overwrite its partial state."
  [url sha dir]
  (let [parent (subs dir 0 (.lastIndexOf dir "/"))
        lock (str dir ".jolt-lock")]
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
                (do (remove-own-cache-path! dir lock) dir)

                (:valid? owned-inspection)
                (do
                  (claim-cache-origin! dir lock url sha)
                  (remove-own-cache-path! dir lock)
                  dir)

                :else
                (do
                  (when-not (:claimed? owned-claim)
                    (claim-cache-origin! dir lock url sha))
                  (fetch-git-while-locked! url sha dir lock))))
            (catch :default cause
              ;; fetch-git-while-locked! owns its own finally. This branch also
              ;; covers metadata failure before that transaction starts.
              (when (file-exists? lock)
                (remove-own-cache-path! dir lock))
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

(def ^:private mvn-repos
  ["https://repo.clojars.org" "https://repo1.maven.org/maven2"])

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
        (loop [repos mvn-repos]
          (if (empty? repos)
            (do (warn "maven dep " coord " " version " not found (Clojars/Central)") nil)
            (if (do (sh (str "mkdir -p " (pr-str (if legacy dir (str (m2-repo-dir) "/" vdir-rel)))))
                    (http/fetch (str (first repos) "/" vdir-rel "/" jar-name) jar))
              (do (info "fetching " coord " " version)
                  (let [d (extract-jar! jar dir)]
                    ;; legacy layout never keeps the jar; the m2 layout does —
                    ;; that IS the sharing.
                    (when legacy (sh (str "rm -f " (pr-str jar))))
                    d))
              (recur (rest repos)))))))))

(defn- pom-deps
  "Transitive deps of an extracted Maven dep, from its pom.xml — as a deps map so
  the BFS walks them like any other. Skips test/provided/system scope, org.clojure/
  clojure (intrinsic), and non-literal versions (ranges / ${properties})."
  [root coord]
  (let [pom (str root "/META-INF/maven/" (mvn-group coord) "/" (name coord) "/pom.xml")]
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

;; --- coordinate -> root dir -------------------------------------------------
(defn- git-coord? [spec]
  (or (:git/url spec) (:git/sha spec) (:git/tag spec)))

(defn- coord-root
  "The on-disk root directory for one dependency coordinate, or nil to skip."
  [coord spec base-dir]
  (cond
    (:local/root spec) (abspath base-dir (:local/root spec))
    ;; a git coordinate: an explicit :git/url, else one inferred from the lib name
    ;; (io.github.OWNER/REPO, …). The :git/sha is what gets checked out; a :git/tag
    ;; without a sha isn't enough to pin a commit, so it's reported as incomplete.
    (git-coord? spec)
    (let [git-url (or (:git/url spec) (infer-git-url coord))]
      (cond
        (and git-url (:git/sha spec))
        (let [checkout (ensure-git coord git-url (:git/sha spec))]
          (if-let [root (:deps/root spec)] (str checkout "/" root) checkout))
        (not git-url)
        (throw (ex-info
                 (str "git dep " coord " has no :git/url and none could be inferred "
                      "from its lib name. Add :git/url, or name the coordinate after "
                      "its host, e.g. io.github.OWNER/REPO for a GitHub repo.")
                 {:coord coord :spec spec}))
        :else
        (throw (ex-info
                 (str "git dep " coord " needs :git/sha (a hexadecimal commit "
                      "object ID or prefix)" (when (:git/tag spec)
                                               " — a :git/tag alone doesn't pin a commit") ".")
                 {:coord coord :spec spec}))))
    (:jolt/module spec)
    (do (info "skipping janet dependency " coord " (:jolt/module is obsolete on Chez)") nil)
    ;; jolt IS Clojure — a dependency on org.clojure/clojure is satisfied
    ;; intrinsically, so skip it silently rather than warning about the (unusable)
    ;; :mvn/version coordinate.
    (= coord 'org.clojure/clojure) nil
    ;; jolt has no ClojureScript compiler, so clojurescript (and the closure /
    ;; rhino toolchain it drags in) is unusable dead weight — a cljc library
    ;; declares it for its :cljs branch, which jolt never takes. Skip its subtree.
    (= coord 'org.clojure/clojurescript) nil
    (:mvn/version spec) (ensure-maven coord (:mvn/version spec))
    :else
    ;; a coordinate that is none of git / mvn / local / module — a typo or an
    ;; unsupported spec. Silently dropping it hides a real problem (a namespace
    ;; missing at runtime), so this stays an unconditional warn, unlike the
    ;; expected-and-obsolete :jolt/module skip above. The message names the
    ;; coordinate shapes jolt understands so the fix is obvious from the warning.
    (do (warn "skipping unsupported coordinate " coord " " (pr-str spec)
              "\n  a dependency needs one of:"
              "\n    {:mvn/version \"1.2.3\"}                              a Maven artifact"
              "\n    {:git/url \"https://…\" :git/sha \"<sha>\"}            an explicit git repo"
              "\n    {:git/sha \"<sha>\"} on io.github.OWNER/REPO          a git repo by host-prefixed name"
              "\n    {:local/root \"../path\"}                             a directory on disk")
        nil)))

(defn- has-clj-source?
  "Does the tree hold any jolt-loadable source (.clj/.cljc)? A Maven JAR that is
  pure-Java (closure-compiler) or ClojureScript-only (cljs.java-time) has none —
  it contributes nothing to run and its transitive deps are the cljs/JVM toolchain,
  so the walk skips it rather than dragging in that whole subtree."
  [root]
  (zero? (sh (str "find " (pr-str root)
                  " \\( -name '*.clj' -o -name '*.cljc' \\) -print -quit 2>/dev/null | grep -q ."))))

(defn- dep-source-roots
  "Source roots a resolved dep contributes. A Maven extraction's classpath root IS
  its source root; a git/local dep uses its deps.edn :paths (default [\"src\"])."
  [root maven?]
  (if maven?
    [root]
    (let [edn (try (read-edn (str root "/deps.edn"))
                   (catch :default e (warn (ex-message e)) nil))
          paths (or (:paths edn) ["src"])]
      (map #(abspath root %) paths))))

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

(defn- resolve-deps
  "Breadth-first walk of a deps map; returns {:roots [...] :natives [...]} — the
  source-root directories and the collected :jolt/native declarations from every
  dep's deps.edn (raw, in walk order; reconcile-project dedups them). `base-dir`
  resolves :local/root and is replaced by a dep's own root as the walk descends."
  [deps base-dir]
  ;; queue grows by appending children at the tail; an index cursor walks it so
  ;; each dequeue is O(1) (was (subvec (vec queue) 1) per pop -> O(n^2)).
  (loop [queue (mapv (fn [[c s]] [c s base-dir]) (seq deps))
         i 0
         seen #{}
         roots []
         natives []]
    (if (>= i (count queue))
      {:roots roots :natives natives}
      (let [[coord spec bd] (nth queue i)
            i (inc i)]
        (if (contains? seen coord)
          (recur queue i seen roots natives)
          (let [root (coord-root coord spec bd)]
            (if (nil? root)
              (recur queue i (conj seen coord) roots natives)
              ;; a DEP repo's malformed deps.edn warns and contributes nothing;
              ;; only the project's own deps.edn is a hard error (resolve-project).
              ;; A Maven dep has no deps.edn — its children come from its pom.xml.
              (let [maven? (boolean (:mvn/version spec))
                    ;; a Maven dep with no jolt-loadable source contributes nothing
                    ;; and its transitive deps are cljs/JVM tooling — don't walk them.
                    usable? (or (not maven?) (has-clj-source? root))
                    edn (when (and usable? (not maven?))
                          (try (read-edn (str root "/deps.edn"))
                               (catch :default e (warn (ex-message e)) nil)))
                    deps (when usable? (if maven? (pom-deps root coord) (:deps edn)))
                    _ (when (and edn deps (not (map? deps)))
                        (throw (ex-info (str "malformed :deps in " root "/deps.edn: expected a map")
                                        {:path root :given (class deps)})))
                    child (mapv (fn [[c s]] [c s root]) (seq deps))]
                (recur (into queue child)
                       i
                       (conj seen coord)
                       (into roots (if usable? (dep-source-roots root maven?) []))
                       (into natives (:jolt/native edn)))))))))))

;; --- public -----------------------------------------------------------------
(defn resolve-project
  "Resolve `project-dir`'s deps.edn with the selected alias keywords. Returns
  {:roots [...] :main-opts [...] :tasks {...} :natives [...]}; :main-opts is the
  last selected alias's, else nil; :natives are the project's + deps' :jolt/native
  shared-library declarations."
  ([project-dir] (resolve-project project-dir []))
  ([project-dir alias-kws]
   (let [edn (read-edn (str project-dir "/deps.edn"))
         aliases (:aliases edn)
         selected (keep #(get aliases %) alias-kws)
         extra-paths (mapcat :extra-paths selected)
         extra-deps (apply merge (map :extra-deps selected))
         main-opts (some :main-opts (reverse selected))
         project-paths (concat (or (:paths edn) ["src"]) extra-paths)
         project-roots (map #(abspath project-dir %) project-paths)
         all-deps (merge (:deps edn) extra-deps)
         {dep-roots :roots dep-natives :natives}
         (binding [*mvn-local-repo* (when-let [r (:mvn/local-repo edn)]
                                      (abspath project-dir r))]
           (resolve-deps all-deps project-dir))]
     ;; reconcile: the project's own roots/natives + every dep's, deduped once.
     {:roots (dedup-by identity (concat project-roots dep-roots))
      :main-opts main-opts
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
   (let [base (or (jolt.host/getenv "JOLT_PWD") ".")
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
