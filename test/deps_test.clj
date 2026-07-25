(ns deps-test
  "Deterministic local-Git tests for jolt.deps' checkout cache. No network is
  used: each remote is a temporary repository created by this test.

  The Makefile supplies isolated JOLT_GITLIBS and GITLIBS directories plus the
  fixture root as argv[0]."
  (:require [clojure.edn :as edn]
            [clojure.string :as str]
            [jolt.deps]))

;; Private implementation seams are intentional here: these tests pin the
;; publication/validation protocol below the public dependency walker.
(def ensure-git         (var jolt.deps/ensure-git))
(def sanitize           (var jolt.deps/sanitize))
(def shell-quote        (var jolt.deps/shell-quote))
(def coordinate-cache-key (var jolt.deps/git-coordinate-cache-key))
(def cache-entry-dir    (var jolt.deps/git-cache-entry-dir))
(def origin-marker      (var jolt.deps/git-cache-origin-marker))
(def origin-claim       (var jolt.deps/git-cache-origin-claim))
(def cache-lock-dir     (var jolt.deps/git-cache-lock-dir))
(def cache-stage-dir    (var jolt.deps/git-cache-stage-dir))
(def remove-cache-path! (var jolt.deps/remove-own-cache-path!))
(def checkout-inspection (var jolt.deps/git-checkout-inspection))
(def checkout-valid?    (var jolt.deps/git-checkout-valid?))
(def publish-checkout!  (var jolt.deps/publish-git-checkout!))
(def lock-wait-attempts (var jolt.deps/git-lock-wait-attempts))
(def lock-wait-ms       (var jolt.deps/git-lock-wait-ms))

(def ^:private failures (atom []))
(def ^:private checks (atom 0))

(defn- check [pred label]
  (swap! checks inc)
  (when-not pred (swap! failures conj label)))

(defn- check= [expected actual label]
  (check (= expected actual)
         (str label " — expected " (pr-str expected) ", got " (pr-str actual))))

(defn- throws? [f]
  (try (f) false (catch :default _ true)))

(defn- thrown-data [f]
  (try (f) nil (catch :default e (ex-data e))))

(defn- sh! [cmd]
  (let [code (jolt.host/sh cmd)]
    (when-not (zero? code)
      (throw (ex-info (str "fixture command failed: " cmd) {:exit code :command cmd}))))
  nil)

(defn- sh-out [cmd]
  (str/trim (jolt.host/sh-out cmd)))

(defn- mkdir! [path]
  (sh! (str "mkdir -p " (shell-quote path)))
  path)

(defn- commit! [repo filename content message]
  (spit (str repo "/" filename) content)
  (sh! (str "git -C " (shell-quote repo) " add " (shell-quote filename)))
  (sh! (str "git -C " (shell-quote repo)
            " -c user.name=jolt-test -c user.email=jolt-test@example.invalid"
            " commit --quiet -m " (shell-quote message)))
  (sh-out (str "git -C " (shell-quote repo) " rev-parse HEAD")))

(defn- commit-all! [repo message]
  (sh! (str "git -C " (shell-quote repo) " add -A"))
  (sh! (str "git -C " (shell-quote repo)
            " -c user.name=jolt-test -c user.email=jolt-test@example.invalid"
            " commit --quiet -m " (shell-quote message)))
  (sh-out (str "git -C " (shell-quote repo) " rev-parse HEAD")))

(defn- init-repo! [repo label]
  (mkdir! repo)
  (sh! (str "git -C " (shell-quote repo) " init --quiet"))
  (commit! repo "deps.edn" (str "{:fixture " (pr-str label) "}\n") "initial"))

(defn- cache-target [url sha]
  (cache-entry-dir url sha))

(defn- write-claim! [dir url sha]
  (spit (origin-marker dir) (pr-str {:url url :sha sha})))

(defn- head [repo]
  (sh-out (str "git -C " (shell-quote repo) " rev-parse HEAD")))

(defn- parent-path [path]
  (subs path 0 (.lastIndexOf path "/")))

(defn- test-private-cache-paths-stay-shallow! [root]
  (let [target (str root "/private-layout/final")
        lock (cache-lock-dir target)
        stage (cache-stage-dir target)
        sentinel (str target ".unrelated")]
    (check= (str target ".jolt-lock") lock
            ".jolt-lock remains the stable cross-version ownership path")
    (check= (str target ".s") stage
            "private checkout uses the bounded sibling stage")
    (check= (+ 2 (count target)) (count stage)
            "staging adds exactly two characters to the Git worktree path")
    (check= (parent-path target) (parent-path stage)
            "stage and final checkout share one publication filesystem")
    (check (not (str/starts-with? stage (str lock "/")))
           "stage is a sibling rather than nested under the lock")

    (mkdir! stage)
    (spit sentinel "preserve")
    (check (throws? #(remove-cache-path! target sentinel))
           "cache cleanup refuses a nearby path outside its exact allowlist")
    (check (jolt.host/file-exists? sentinel)
           "refused cleanup preserves the unrelated sentinel")
    (remove-cache-path! target stage)
    (check (not (jolt.host/file-exists? stage))
           "cache cleanup accepts the exact private stage")
    (check (jolt.host/file-exists? sentinel)
           "private-stage cleanup remains bounded to that stage")))

(defn- test-windows-git-dir-path-budget! [root]
  ;; Git's explicit-GIT_DIR guard rejects strlen >= PATH_MAX-40. Git for
  ;; Windows uses PATH_MAX=260 here, so 219 is the largest accepted path. The
  ;; recursive fixture's nested module metadata suffix is 65 characters.
  ;;
  ;; Keep the production layout within a useful, explicit budget rather than
  ;; shortening only this test's TEMP directory. A cache root of up to 80
  ;; characters plus the exact 54-character v3 stage leaf and a recursive
  ;; suffix of up to 85 characters reaches the inclusive safe boundary 219.
  (let [cache-root (jolt.host/getenv "JOLT_GITLIBS")
        sha (apply str (repeat 40 "a"))
        target (cache-target (str root "/path-budget-origin") sha)
        stage (cache-stage-dir target)
        recursive-suffix
        "/.git/modules/modules/outer sub/modules/nested modules/deep child"
        stage-overhead (- (count stage) (count cache-root))
        git-dir-limit 220]
    (check= 54 stage-overhead
            "v3 coordinate key plus private stage has fixed 54-char overhead")
    (check= 219 (+ 80 stage-overhead 85)
            "declared cache-root and recursive-suffix bounds reach 219 exactly")
    (check (<= (count cache-root) 80)
           "dependency-test cache root is inside the declared Windows budget")
    (check (< (count (str stage recursive-suffix)) git-dir-limit)
           "recursive fixture GIT_DIR remains below Git for Windows guard")))

(defn- test-windows-backslash-mkdirs! [root]
  ;; Native Windows environment variables conventionally contain backslashes.
  ;; File.mkdirs must create every parent in those paths; the Git cache and
  ;; external native-artifact caches both rely on that Java-compatible surface.
  (when (str/includes?
         (str/lower-case (or (System/getProperty "os.name") ""))
         "windows")
    (let [nested (str (str/replace root "/" "\\")
                      "\\backslash-cache\\one\\two")]
      (check (.mkdirs (java.io.File. nested))
             "File.mkdirs creates nested Windows backslash paths")
      (check (.isDirectory (java.io.File. nested))
             "nested Windows backslash path exists as a directory"))))

(defn- test-failed-clone-is-recoverable! [root]
  (let [hidden (str root "/failed-origin-hidden")
        url (str root "/failed-origin")
        sha (init-repo! hidden :failed-clone)
        target (cache-target url sha)
        stage (cache-stage-dir target)]
    ;; The requested URL does not exist yet. A failed clone must leave neither
    ;; the final cache leaf nor its ownership/staging directory.
    (check (throws? #(ensure-git 'fixture/failed url sha))
           "missing local remote reports clone failure")
    (check (not (jolt.host/file-exists? target))
           "failed clone does not publish its target")
    (check (not (jolt.host/file-exists? (cache-lock-dir target)))
           "failed clone removes private lock/staging residue")
    (check (not (jolt.host/file-exists? stage))
           "failed clone removes the sibling checkout stage")
    (check= {:url url :sha sha}
            (edn/read-string (slurp (origin-marker target)))
            "failed clone preserves only its durable literal-coordinate claim")

    ;; Make the exact same url@sha available and retry. This is the concrete
    ;; poisoned-cache reproducer: the retry must clone instead of trusting the
    ;; directory created by the failed attempt.
    (sh! (str "mv " (shell-quote hidden) " " (shell-quote url)))
    (check= target (ensure-git 'fixture/failed url sha)
            "retry after clone failure publishes the requested cache leaf")
    (check (checkout-valid? target sha url)
           "retry result is a verified exact checkout")))

(defn- test-stage-cleanup-failure-retains-lock! [root]
  (let [url (str root "/cleanup-failure-origin")
        sha (init-repo! url :cleanup-failure)
        target (cache-target url sha)
        lock (cache-lock-dir target)
        stage (cache-stage-dir target)
        real-inspection @checkout-inspection
        real-remove @remove-cache-path!
        stage-removals (atom 0)
        data
        (with-redefs-fn
          {checkout-inspection
           (fn [path expected-sha expected-url]
             (if (= path stage)
               {:valid? false :reason :fixture-rejection :path path}
               (real-inspection path expected-sha expected-url)))
           remove-cache-path!
           (fn [dir path]
             (if (and (= path stage)
                      (= 2 (swap! stage-removals inc)))
               (throw (ex-info "fixture stage cleanup failure"
                               {:path path :fixture true}))
               (real-remove dir path)))}
          (fn []
            (thrown-data
              #(ensure-git 'fixture/cleanup-failure url sha))))]
    (check= :jolt.deps/git-cache-cleanup-failed (:type data)
            "cleanup failure preserves a structured combined error")
    (check (some? (:primary-error data))
           "cleanup failure retains the primary checkout error")
    (check (some? (:cleanup-error data))
           "cleanup failure retains the cleanup error")
    (check (jolt.host/file-exists? stage)
           "failed stage cleanup leaves its private residue visible")
    (check (jolt.host/file-exists? lock)
           "failed stage cleanup retains the coordinating lock")
    ;; Restore the original implementation before removing the deliberate
    ;; failure fixture.
    (real-remove target stage)
    (real-remove target lock)))

(defn- test-incomplete-and-dirty-entries-are-repaired! [root]
  (let [url (str root "/repair-origin")
        sha (init-repo! url :repair)
        target (cache-target url sha)
        sentinel (str target "/.git/jolt-test-reuse-sentinel")
        injected (str target "/src/injected.clj")]
    ;; This is the exact shape an older implementation could leave when clone
    ;; failed after creating an owned target but before publication completed.
    (mkdir! target)
    (spit (str target "/poison") "not a repository")
    (let [data (thrown-data #(ensure-git 'fixture/repair url sha))]
      (check= :jolt.deps/git-cache-unowned-entry (:type data)
              "unclaimed non-Git cache entry fails closed"))
    (check (jolt.host/file-exists? (str target "/poison"))
           "unclaimed non-Git cache entry is never deleted")
    (write-claim! target url sha)
    (check= target (ensure-git 'fixture/repair url sha)
            "empty/incomplete target is replaced")
    (check (checkout-valid? target sha url)
           "replacement is an exact checkout")
    (check (not (jolt.host/file-exists? (str target "/poison")))
           "incomplete target contents are gone")

    ;; A valid exact checkout is reused as-is. The sentinel lives under Git's
    ;; private metadata, not the source worktree: any untracked worktree file is
    ;; semantically capable of adding a namespace and must invalidate reuse.
    (spit sentinel "keep")
    (check= target (ensure-git 'fixture/repair url sha)
            "valid exact checkout is reused")
    (check (jolt.host/file-exists? sentinel)
           "reuse does not replace a valid checkout")

    (mkdir! (str target "/src"))
    (spit injected "(ns injected)\n")
    (check (not (checkout-valid? target sha url))
           "untracked source makes an exact-HEAD checkout invalid")
    (check= target (ensure-git 'fixture/repair url sha)
            "untracked source is repaired")
    (check (not (jolt.host/file-exists? injected))
           "repair removes untracked source")
    (check (checkout-valid? target sha url)
           "untracked-source repair restores immutable checkout")

    ;; Matching HEAD with a tracked edit is not the pinned source tree. Repair
    ;; it, while still leaving unrelated cache keys untouched.
    (spit (str target "/deps.edn") "{:fixture :tampered}\n")
    (check= target (ensure-git 'fixture/repair url sha)
            "tracked mutation is repaired")
    (check (checkout-valid? target sha url)
           "tracked mutation repair restores exact checkout")
    (check (not (jolt.host/file-exists? sentinel))
           "repair replaced only the invalid url@sha leaf")))

(defn- test-wrong-head-is-repaired! [root]
  (let [url (str root "/wrong-head-origin")
        old-sha (init-repo! url :wrong-head)
        new-sha (commit! url "version.txt" "two\n" "second")
        target (cache-target url new-sha)]
    (mkdir! (subs target 0 (.lastIndexOf target "/")))
    (sh! (str "git clone --quiet " (shell-quote url) " " (shell-quote target)))
    (sh! (str "git -C " (shell-quote target)
              " checkout --quiet " (shell-quote old-sha)))
    (check= old-sha (head target) "fixture starts at the wrong HEAD")
    (check= target (ensure-git 'fixture/wrong-head url new-sha)
            "wrong-HEAD cache entry is repaired")
    (check= new-sha (head target) "repair checks out the requested HEAD")
    (check (checkout-valid? target new-sha url)
           "wrong-HEAD repair passes full validation")))

(defn- test-concurrent-losers-reuse-winner! [root]
  (let [url (str root "/concurrent-origin")
        sha (init-repo! url :concurrent)
        target (cache-target url sha)
        stage (cache-stage-dir target)
        start (promise)
        jobs (mapv (fn [_]
                     (future
                       @start
                       (ensure-git 'fixture/concurrent url sha)))
                   (range 6))]
    (deliver start true)
    (let [results (mapv #(deref % 30000 ::timeout) jobs)]
      (check (every? #(= target %) results)
             (str "concurrent callers all return the published checkout: "
                  (pr-str results))))
    (check (checkout-valid? target sha url)
           "concurrent winner publishes one valid checkout")
    (check (not (jolt.host/file-exists? (cache-lock-dir target)))
           "concurrent completion leaves no ownership lock")
    (check (not (jolt.host/file-exists? stage))
           "concurrent completion leaves no sibling checkout stage")))

(defn- test-separate-processes-share-one-publication! [root]
  (let [url (str root "/interprocess-origin")
        sha (init-repo! url :interprocess)
        target (cache-target url sha)
        stage (cache-stage-dir target)
        start (str root "/interprocess-start")
        child-a (str root "/interprocess-a.out")
        child-b (str root "/interprocess-b.out")
        joltc (jolt.host/getenv "JOLT_DEPSTEST_JOLTC")
        run-child
        (fn [result]
          (jolt.host/sh
            (str joltc " run test/deps_child.clj "
                 (shell-quote start) " " (shell-quote url) " "
                 (shell-quote sha) " " (shell-quote result))))
        job-a (future (run-child child-a))
        job-b (future (run-child child-b))]
    (Thread/sleep 250)
    (spit start "go")
    (check= 0 (deref job-a 30000 ::timeout)
            "first external Jolt process resolves dependency")
    (check= 0 (deref job-b 30000 ::timeout)
            "second external Jolt process resolves dependency")
    (check= target (when (jolt.host/file-exists? child-a)
                     (slurp child-a))
            "first process returns shared published path")
    (check= target (when (jolt.host/file-exists? child-b)
                     (slurp child-b))
            "second process returns shared published path")
    (check (checkout-valid? target sha url)
           "interprocess winner leaves one exact checkout")
    (check (not (jolt.host/file-exists? (cache-lock-dir target)))
           "interprocess publication leaves no lock residue")
    (check (not (jolt.host/file-exists? stage))
           "interprocess publication leaves no sibling stage residue")))

(defn- test-waiter-observes-in-flight-winner! [root]
  (let [url (str root "/waiter-origin")
        sha (init-repo! url :waiter)
        target (cache-target url sha)
        parent (subs target 0 (.lastIndexOf target "/"))
        lock (cache-lock-dir target)]
    ;; Deterministically put this caller on the loser path instead of relying on
    ;; thread scheduling to overlap two fast local clones.
    (mkdir! parent)
    (sh! (str "mkdir " (shell-quote lock)))
    (write-claim! target url sha)
    (let [waiter (future (ensure-git 'fixture/waiter url sha))]
      (check= ::waiting (deref waiter 150 ::waiting)
              "loser waits while another writer owns the target")
      ;; Model the owner completing its private transaction while its lock is
      ;; still held. A loser may reuse only after the final target validates.
      (sh! (str "git clone --quiet " (shell-quote url) " " (shell-quote target)))
      (check= target (deref waiter 5000 ::timeout)
              "loser returns the winner's verified publication")
      (check (checkout-valid? target sha url)
             "publication observed by loser is exact")
      (check (jolt.host/file-exists? lock)
             "loser never removes another writer's lock")
      (sh! (str "rm -rf " (shell-quote lock))))))

(defn- test-orphan-sibling-stage-is-recovered! [root]
  (let [url (str root "/orphan-stage-origin")
        sha (init-repo! url :orphan-stage)
        target (cache-target url sha)
        lock (cache-lock-dir target)
        stage (cache-stage-dir target)
        unrelated (str target ".preserve")]
    (mkdir! stage)
    (spit (str stage "/poison") "killed writer residue")
    (spit unrelated "not part of the transaction")
    (check= target (ensure-git 'fixture/orphan-stage url sha)
            "new lock owner removes an orphan sibling stage before cloning")
    (check (checkout-valid? target sha url)
           "orphan-stage recovery publishes an exact checkout")
    (check (not (jolt.host/file-exists? stage))
           "successful recovery leaves no sibling stage")
    (check (not (jolt.host/file-exists? lock))
           "successful recovery releases the stable lock")
    (check (jolt.host/file-exists? unrelated)
           "orphan-stage recovery preserves adjacent unrelated state")))

(defn- test-post-lock-origin-reread-precedes-stage-cleanup! [root]
  (let [url (str root "/post-lock-origin")
        sha (init-repo! url :post-lock-origin)
        target (cache-target url sha)
        lock (cache-lock-dir target)
        stage (cache-stage-dir target)
        sentinel (str stage "/foreign-stage-sentinel")
        real-claim @origin-claim
        claim-reads (atom 0)]
    (mkdir! stage)
    (spit sentinel "preserve until durable identity is re-read")
    (let [data
          (with-redefs-fn
            {origin-claim
             (fn [dir expected-url expected-sha]
               (if (= 3 (swap! claim-reads inc))
                 {:claimed? true :matches? false
                  :marker (origin-marker dir)
                  :expected-url expected-url
                  :actual-url "fixture://foreign-owner"
                  :expected-sha expected-sha
                  :actual-sha expected-sha}
                 (real-claim dir expected-url expected-sha)))}
            (fn []
              (thrown-data
                #(ensure-git 'fixture/post-lock-origin url sha))))]
      (check= :jolt.deps/git-cache-origin-mismatch (:type data)
              "post-lock durable-origin mismatch fails closed"))
    (check (>= @claim-reads 3)
           "origin identity is re-read after lock acquisition")
    (check (jolt.host/file-exists? sentinel)
           "post-lock origin mismatch precedes destructive stage cleanup")
    (check (not (jolt.host/file-exists? lock))
           "caller releases only its newly acquired lock on mismatch")
    (remove-cache-path! target stage)))

(defn- test-tools-gitlibs-reuse-is-read-only! [root]
  (let [url (str root "/shared-origin")
        sha (init-repo! url :shared)
        bare (str (jolt.host/getenv "GITLIBS")
                  "/_repos/fixture/shared.git")
        shared (str (jolt.host/getenv "GITLIBS")
                    "/libs/fixture/shared/" sha)
        own (cache-target url sha)
        sentinel (str bare "/jolt-test-read-only-sentinel")
        injected (str shared "/src/injected.clj")]
    ;; tools.gitlibs uses linked worktrees: .git is a pointer file into its
    ;; _repos bookkeeping, not a private metadata directory under the checkout.
    (mkdir! (subs bare 0 (.lastIndexOf bare "/")))
    (mkdir! (subs shared 0 (.lastIndexOf shared "/")))
    (sh! (str "git clone --quiet --bare " (shell-quote url) " "
              (shell-quote bare)))
    (sh! (str "git --git-dir=" (shell-quote bare)
              " worktree add --quiet --detach " (shell-quote shared) " "
              (shell-quote sha)))
    (spit sentinel "owned by tools.gitlibs")
    (check (.isFile (java.io.File. (str shared "/.git")))
           "tools.gitlibs fixture is a real linked worktree")
    ;; Ordinary `git status` refreshes the linked worktree's shared index after
    ;; a tracked-file stat change. Validation promises read-only reuse, so pin
    ;; the index mtime and prove inspection uses Git's no-optional-locks mode.
    (let [index-path (str/trim
                      (jolt.host/sh-out
                       (str "git -C " (shell-quote shared)
                            " rev-parse --git-path index")))
          index-file (java.io.File. index-path)
          tracked-file (java.io.File. (str shared "/deps.edn"))]
      (check (.setLastModified index-file
                               (- (System/currentTimeMillis) 60000))
             "fixture can pin linked-worktree index mtime")
      (let [index-mtime (.lastModified index-file)]
        (check (.setLastModified tracked-file (System/currentTimeMillis))
               "fixture changes tracked-file stat metadata")
        (check (checkout-valid? shared sha nil)
               "stat-only tracked-file change remains a clean checkout")
        (check= index-mtime (.lastModified index-file)
                "tools.gitlibs validation does not refresh its linked index")))
    (check= shared (ensure-git 'fixture/shared url sha)
            "clean tools.gitlibs checkout is reused")
    (check (jolt.host/file-exists? sentinel)
           "jolt does not rewrite tools.gitlibs checkout")
    (check (not (jolt.host/file-exists? own))
           "clean tools.gitlibs reuse does not populate jolt's own cache")

    ;; Read-only never means trusted despite worktree residue. Reject the shared
    ;; checkout, leave it untouched, and build jolt's separate clean cache.
    (mkdir! (str shared "/src"))
    (spit injected "(ns injected)\n")
    (check (not (checkout-valid? shared sha nil))
           "untracked tools.gitlibs source invalidates reuse")
    (check= own (ensure-git 'fixture/shared url sha)
            "dirty tools.gitlibs checkout falls back to jolt cache")
    (check (checkout-valid? own sha url)
           "fallback jolt cache is clean and exact")
    (check (jolt.host/file-exists? injected)
           "dirty tools.gitlibs checkout remains untouched")
    (check (jolt.host/file-exists? sentinel)
           "tools.gitlibs metadata remains untouched")))

(defn- test-submodule-dirt-invalidates-checkout! [root]
  (let [nested-url (str root "/nested-submodule-origin")
        _ (init-repo! nested-url :nested-submodule)
        sub-url (str root "/submodule-origin")
        _ (init-repo! sub-url :submodule)
        _ (commit! sub-url ".gitignore" "ignored.clj\n" "ignore fixture")
        _ (sh! (str "git -c protocol.file.allow=always -C "
                    (shell-quote sub-url) " submodule add --quiet "
                    (shell-quote nested-url)
                    " " (shell-quote "nested modules/deep child")))
        _ (commit-all! sub-url "add nested submodule with spaces")
        parent-url (str root "/submodule-parent-origin")
        _ (init-repo! parent-url :submodule-parent)
        _ (sh! (str "git -c protocol.file.allow=always -C "
                    (shell-quote parent-url) " submodule add --quiet "
                    (shell-quote sub-url)
                    " " (shell-quote "modules/outer sub")))
        sha (commit-all! parent-url "add submodule")
        target (cache-target parent-url sha)
        sub-checkout (str target "/modules/outer sub")
        nested-checkout (str sub-checkout "/nested modules/deep child")
        nested-deps (str nested-checkout "/deps.edn")
        injected (str sub-checkout "/injected.clj")
        ignored (str sub-checkout "/ignored.clj")]
    (check= target (ensure-git 'fixture/submodule parent-url sha)
            "clean recursive submodule checkout is published")
    (check (checkout-valid? target sha parent-url)
           "clean recursive submodule checkout validates")

    ;; Hide a tracked mutation from the root and intermediate porcelain status.
    ;; Inspection can find it only by traversing recursive `submodule foreach`
    ;; and joining Git's top-level-relative $displaypath. The nested path and
    ;; both ancestor paths contain spaces, so this is also a quoting regression.
    (sh! (str "git -C " (shell-quote nested-checkout)
              " update-index --skip-worktree deps.edn"))
    (spit nested-deps "{:fixture :hidden-nested-submodule-tamper}\n")
    (check (str/blank?
             (sh-out (str "git -C " (shell-quote target)
                          " status --porcelain=v1")))
           "nested skip-worktree mutation is hidden from root porcelain")
    (let [inspection (checkout-inspection target sha parent-url)]
      (check= :unsafe-index (:reason inspection)
              "recursive inspection reaches hidden nested index state")
      (check= nested-checkout (:path inspection)
              "recursive inspection reports Git's full nested displaypath")
      (check (:submodule? inspection)
             "nested unsafe index is classified as submodule state")
      (check= target (:checkout-path inspection)
              "nested inspection retains its owning checkout path"))
    (check= target (ensure-git 'fixture/submodule parent-url sha)
            "hidden nested spaced submodule state is repaired")
    (check (checkout-valid? target sha parent-url)
           "nested submodule repair restores recursive immutable checkout")

    (spit injected "(ns injected)\n")
    (check (not (checkout-valid? target sha parent-url))
           "untracked file inside submodule invalidates parent checkout")
    (check= target (ensure-git 'fixture/submodule parent-url sha)
            "untracked submodule state is repaired")
    (check (not (jolt.host/file-exists? injected))
           "submodule repair removes untracked file")
    (check (checkout-valid? target sha parent-url)
           "submodule untracked repair restores immutable checkout")

    ;; Ignored still means outside the commit. A .clj ignored by Git can be
    ;; discovered on a source root just like any other untracked namespace.
    (spit ignored "(ns ignored)\n")
    (check (not (checkout-valid? target sha parent-url))
           "ignored source inside submodule invalidates parent checkout")
    (check= target (ensure-git 'fixture/submodule parent-url sha)
            "ignored submodule state is repaired")
    (check (not (jolt.host/file-exists? ignored))
           "submodule repair removes ignored source")
    (check (checkout-valid? target sha parent-url)
           "ignored submodule repair restores immutable checkout")

    (spit (str sub-checkout "/deps.edn") "{:fixture :submodule-tampered}\n")
    (check (not (checkout-valid? target sha parent-url))
           "tracked modification inside submodule invalidates parent checkout")
    (check= target (ensure-git 'fixture/submodule parent-url sha)
            "tracked submodule state is repaired")
    (check (checkout-valid? target sha parent-url)
           "tracked submodule repair restores immutable checkout")

    ;; Index flags can hide mutations from porcelain status. Apply the check at
    ;; recursive submodule boundaries as well as the parent checkout.
    (sh! (str "git -C " (shell-quote sub-checkout)
              " update-index --skip-worktree deps.edn"))
    (spit (str sub-checkout "/deps.edn")
          "{:fixture :hidden-submodule-tamper}\n")
    (check (str/blank?
             (sh-out (str "git -C " (shell-quote sub-checkout)
                          " status --porcelain=v1")))
           "fixture submodule mutation is hidden from porcelain")
    (check (not (checkout-valid? target sha parent-url))
           "skip-worktree mutation inside submodule invalidates parent")
    (check= target (ensure-git 'fixture/submodule parent-url sha)
            "unsafe submodule index state is repaired")
    (check (checkout-valid? target sha parent-url)
           "submodule index repair restores immutable checkout")))

(defn- test-coordinate-cache-key-separates-sanitize-collision! [root]
  (let [source (str root "/collision-source")
        sha (init-repo! source :collision)
        url-a (str root "/collision/a/b")
        url-b (str root "/collision/a_b")
        _ (mkdir! (str root "/collision/a"))
        _ (sh! (str "git clone --quiet " (shell-quote source)
                    " " (shell-quote url-a)))
        _ (sh! (str "git clone --quiet " (shell-quote source)
                    " " (shell-quote url-b)))
        target-a (cache-target url-a sha)
        target-b (cache-target url-b sha)
        sentinel (str target-a "/.git/jolt-test-collision-sentinel")
        legacy (str (jolt.host/getenv "JOLT_GITLIBS")
                    "/" (sanitize url-a) "/" sha)
        legacy-sentinel (str legacy "/.git/jolt-test-legacy-sentinel")]
    ;; A live legacy leaf is ambiguous by construction. The versioned layout
    ;; must ignore it rather than trying to validate, migrate, or repair it.
    (mkdir! (subs legacy 0 (.lastIndexOf legacy "/")))
    (sh! (str "git clone --quiet " (shell-quote source)
              " " (shell-quote legacy)))
    (spit legacy-sentinel "do not touch")
    (check= (sanitize url-a) (sanitize url-b)
            "fixture URLs collide under legacy sanitize")
    (check (not= (coordinate-cache-key url-a sha)
                 (coordinate-cache-key url-b sha))
           "Git object-ID coordinate keys separate adversarial spellings")
    (check= 44 (count (coordinate-cache-key url-a sha))
            "coordinate cache key has one fixed bounded path component")
    (check= target-a (ensure-git 'fixture/collision-a url-a sha)
            "first colliding legacy URL gets its own checkout")
    (spit sentinel "preserve")
    (check= target-b (ensure-git 'fixture/collision-b url-b sha)
            "second colliding legacy URL gets a distinct checkout")
    (check (not= target-a target-b)
           "distinct URLs never share the same repair leaf")
    (check (not= legacy target-a)
           "versioned URL layout is disjoint from ambiguous legacy leaf")
    (check (checkout-valid? target-a sha url-a)
           "first URL remains valid after second publication")
    (check (checkout-valid? target-b sha url-b)
           "second URL validates independently")
    (check (jolt.host/file-exists? sentinel)
           "second URL repair cannot replace first URL checkout")
    (check (jolt.host/file-exists? legacy-sentinel)
           "new layout never mutates ambiguous legacy checkout")))

(defn- test-literal-origin-survives-insteadof! [root]
  (let [base (str root "/instead-remotes/")
        url-path (str base "fixture")
        _ (init-repo! url-path :instead-of)
        sha (head url-path)
        alias "jolt-review:fixture"
        target (cache-target alias sha)
        key (str "url." base ".insteadOf")]
    ;; A common global Git setup rewrites HTTPS/aliases to a mirror or SSH. Git's
    ;; `remote get-url` expands this rule; the literal config value remains the
    ;; dependency URL and is the identity Jolt must compare.
    (sh! (str "git config --global " (shell-quote key) " "
              (shell-quote "jolt-review:")))
    (check= target (ensure-git 'fixture/instead-of alias sha)
            "insteadOf alias clones and publishes successfully")
    (check= alias
            (sh-out (str "git -C " (shell-quote target)
                         " config --local --get remote.origin.url"))
            "published checkout retains literal dependency origin")
    (check (not=
             alias
             (sh-out (str "git -C " (shell-quote target)
                          " remote get-url origin")))
           "fixture proves remote get-url expands insteadOf")
    (check= target (ensure-git 'fixture/instead-of alias sha)
            "literal-origin validation reuses insteadOf checkout")))

(defn- test-clone-default-remote-name-cannot-break-origin! [root]
  (let [url (str root "/remote-name-origin")
        sha (init-repo! url :remote-name)
        target (cache-target url sha)]
    (sh! "git config --global clone.defaultRemoteName upstream")
    (try
      (check= target (ensure-git 'fixture/remote-name url sha)
              "resolver forces the canonical origin remote name")
      (check= url
              (sh-out (str "git -C " (shell-quote target)
                           " config --local --get remote.origin.url"))
              "literal URL is stored under remote.origin.url")
      (check (str/blank?
               (sh-out (str "git -C " (shell-quote target)
                            " config --local --get remote.upstream.url")))
             "global clone.defaultRemoteName cannot rename dependency remote")
      (finally
        (sh! "git config --global --unset clone.defaultRemoteName")))))

(defn- test-relative-local-origin-retains-literal-identity! [_root]
  ;; `git clone relative/path ...` rewrites remote.origin.url to an absolute
  ;; cwd-prefixed spelling. Jolt keys and validates the dependency's literal
  ;; URL, so publication must restore that spelling before inspection.
  (let [relative (str "target/jolt-relative-origin-"
                      (System/currentTimeMillis))
        absolute (str (System/getProperty "user.dir") "/" relative)]
    (try
      (let [sha (init-repo! absolute :relative-origin)
            target (cache-target relative sha)]
        (check= target (ensure-git 'fixture/relative-origin relative sha)
                "relative local Git URL publishes successfully")
        (check= relative
                (sh-out (str "git -C " (shell-quote target)
                             " config --local --get remote.origin.url"))
                "published checkout retains exact relative literal origin")
        (check (checkout-valid? target sha relative)
               "relative-origin checkout passes strict validation"))
      (finally
        (sh! (str "rm -rf " (shell-quote absolute)))))))

(defn- test-forced-coordinate-key-collision-is-nondestructive! [root]
  (with-redefs-fn
    {coordinate-cache-key (fn [_ _] "dep-forced-collision")}
    (fn []
      (let [source (str root "/forced-collision-source")
            sha (init-repo! source :forced-collision)
            next-sha (commit! source "next.txt" "next\n" "second revision")
            url-a (str root "/forced-collision-a")
            url-b (str root "/forced-collision-b")
            _ (sh! (str "git clone --quiet " (shell-quote source) " "
                        (shell-quote url-a)))
            _ (sh! (str "git clone --quiet " (shell-quote source) " "
                        (shell-quote url-b)))
            target (cache-target url-a sha)
            sentinel (str target "/.git/jolt-collision-preserve")]
        (check= target (ensure-git 'fixture/collision-a url-a sha)
                "first forced hash collision publishes normally")
        (spit sentinel "preserve")
        (let [data (thrown-data
                     #(ensure-git 'fixture/collision-b url-b sha))]
          (check= :jolt.deps/git-cache-origin-mismatch (:type data)
                  "second forced hash collision fails as origin mismatch"))
        (let [data (thrown-data
                     #(ensure-git 'fixture/collision-revision url-a next-sha))]
          (check= :jolt.deps/git-cache-origin-mismatch (:type data)
                  "same URL at a colliding revision fails by durable coordinate"))
        (check (checkout-valid? target sha url-a)
               "forced collision preserves first checkout")
        (check (jolt.host/file-exists? sentinel)
               "forced collision never destructively repairs first origin")
        (let [foreign-dirt (str target "/foreign-untracked")]
          (spit foreign-dirt "belongs to the other origin")
          (let [data (thrown-data
                       #(ensure-git 'fixture/collision-b url-b sha))]
            (check= :jolt.deps/git-cache-origin-mismatch (:type data)
                    "wrong origin wins classification before dirty repair"))
          (check (jolt.host/file-exists? foreign-dirt)
                 "dirty wrong-origin checkout is still never deleted"))
        ;; The durable claim is outside the checkout. Even losing all Git
        ;; metadata cannot turn a key collision into authority to repair it.
        (sh! (str "rm -rf " (shell-quote (str target "/.git"))))
        (let [data (thrown-data
                     #(ensure-git 'fixture/collision-b url-b sha))]
          (check= :jolt.deps/git-cache-origin-mismatch (:type data)
                  "corrupt wrong-origin checkout still fails by durable claim"))
        (check (jolt.host/file-exists? (str target "/deps.edn"))
               "corrupt wrong-origin checkout is never destructively repaired")))))

(defn- test-index-flags-and-sparse-checkout-are-repaired! [root]
  (let [url (str root "/unsafe-index-origin")
        _ (init-repo! url :unsafe-index)
        _ (mkdir! (str url "/src"))
        _ (commit! url "src/kept.clj" "(ns kept)\n" "add source")
        _ (mkdir! (str url "/hidden"))
        sha (commit! url "hidden/omitted.clj" "(ns omitted)\n" "add hidden")
        target (cache-target url sha)]
    (check= target (ensure-git 'fixture/unsafe-index url sha)
            "unsafe-index fixture publishes")

    (sh! (str "git -C " (shell-quote target)
              " update-index --skip-worktree deps.edn"))
    (spit (str target "/deps.edn") "{:fixture :skip-hidden}\n")
    (check (str/blank?
             (sh-out (str "git -C " (shell-quote target)
                          " status --porcelain=v1")))
           "skip-worktree fixture hides tracked mutation from porcelain")
    (check (not (checkout-valid? target sha url))
           "skip-worktree index flag invalidates checkout")
    (check= target (ensure-git 'fixture/unsafe-index url sha)
            "skip-worktree checkout is repaired")

    (sh! (str "git -C " (shell-quote target)
              " update-index --assume-unchanged deps.edn"))
    (spit (str target "/deps.edn") "{:fixture :assume-hidden}\n")
    (check (str/blank?
             (sh-out (str "git -C " (shell-quote target)
                          " status --porcelain=v1")))
           "assume-unchanged fixture hides tracked mutation from porcelain")
    (check (not (checkout-valid? target sha url))
           "assume-unchanged index flag invalidates checkout")
    (check= target (ensure-git 'fixture/unsafe-index url sha)
            "assume-unchanged checkout is repaired")

    (sh! (str "git -C " (shell-quote target)
              " sparse-checkout set src"))
    (check (not (jolt.host/file-exists?
                  (str target "/hidden/omitted.clj")))
           "sparse fixture omits a committed path")
    (check (str/blank?
             (sh-out (str "git -C " (shell-quote target)
                          " status --porcelain=v1")))
           "sparse omission remains porcelain-clean")
    (check (not (checkout-valid? target sha url))
           "sparse checkout invalidates complete-tree contract")
    (check= target (ensure-git 'fixture/unsafe-index url sha)
            "sparse checkout is repaired")
    (check (jolt.host/file-exists? (str target "/hidden/omitted.clj"))
           "sparse repair restores omitted tracked source")))

(defn- test-publish-never-nests-and-revalidates! [root]
  (let [url (str root "/publish-origin")
        sha (init-repo! url :publish)
        stage (str root "/publish-stage")
        target (str root "/publish-target")
        sentinel (str target "/preserve")]
    (sh! (str "git clone --quiet " (shell-quote url) " "
              (shell-quote stage)))
    (mkdir! target)
    (spit sentinel "preserve")
    (check (throws? #(publish-checkout! stage target url sha))
           "publication refuses a destination that appeared")
    (check (not (jolt.host/file-exists? (str target "/publish-stage")))
           "publication never nests stage under existing destination")
    (check (jolt.host/file-exists? sentinel)
           "publish conflict preserves independently created destination")

    (let [stage2 (str root "/publish-stage-final")
          target2 (str root "/publish-target-final")
          validations (atom 0)]
      (sh! (str "git clone --quiet " (shell-quote url) " "
                (shell-quote stage2)))
      (with-redefs-fn
        {checkout-inspection
         (fn [_ _ _]
           (swap! validations inc)
           {:valid? false :reason :dirty})}
        (fn []
          (check (throws? #(publish-checkout! stage2 target2 url sha))
                 "post-publication validation failure is reported")))
      (check= 1 @validations
              "publication validates the final path before returning")
      (check (not (jolt.host/file-exists? target2))
             "failed final validation removes own published residue"))))

(defn- test-healthy-owner-may-take-longer-than-ten-seconds! [root]
  (let [url (str root "/slow-owner-origin")
        sha (init-repo! url :slow-owner)
        target (cache-target url sha)
        parent (subs target 0 (.lastIndexOf target "/"))
        lock (cache-lock-dir target)]
    (mkdir! parent)
    (mkdir! lock)
    (write-claim! target url sha)
    (spit (str lock "/owner.edn")
          (pr-str {:started-ms (System/currentTimeMillis)
                   :fixture :healthy-slow-owner}))
    (let [begin-owner (promise)
          owner (future
                  @begin-owner
                  (Thread/sleep 10500)
                  (sh! (str "git clone --quiet " (shell-quote url) " "
                            (shell-quote target)))
                  target)
          started (jolt.host/monotonic-nanos)
          _ (deliver begin-owner true)]
      (check= target (ensure-git 'fixture/slow-owner url sha)
              "waiter observes a healthy owner after more than ten seconds")
      (check (>= (- (jolt.host/monotonic-nanos) started) 10000000000)
             "healthy-owner regression actually crosses old ten-second bound")
      (check= target (deref owner 5000 ::timeout)
              "slow owner completed its publication")
      (check (jolt.host/file-exists? lock)
             "waiter does not remove healthy owner's lock")
      (sh! (str "rm -rf " (shell-quote lock))))))

(defn- test-stale-lock-diagnostic-preserves-owner! [root]
  (let [url (str root "/stale-owner-origin")
        sha (init-repo! url :stale-owner)
        target (cache-target url sha)
        parent (subs target 0 (.lastIndexOf target "/"))
        lock (cache-lock-dir target)
        owner "{:fixture :stale-owner}"]
    (mkdir! parent)
    (mkdir! lock)
    (spit (str lock "/owner.edn") owner)
    (let [data (with-redefs-fn
                 {lock-wait-attempts 2
                  lock-wait-ms 5}
                 (fn [] (thrown-data
                          #(ensure-git 'fixture/stale-owner url sha))))]
      (check= owner (:owner data)
              "stale-lock timeout reports recorded owner metadata")
      (check (jolt.host/file-exists? lock)
             "stale lock remains fail-closed for manual recovery"))
    (sh! (str "rm -rf " (shell-quote lock)))))

(defn- test-annotated-tag-object-is-not-a-commit-sha! [root]
  (let [url (str root "/annotated-tag-origin")
        _ (init-repo! url :annotated-tag)
        _ (sh! (str "git -C " (shell-quote url)
                    " -c user.name=jolt-test -c user.email=jolt-test@example.invalid"
                    " tag -a jolt-test-tag -m annotated"))
        tag-sha (sh-out (str "git -C " (shell-quote url)
                             " rev-parse refs/tags/jolt-test-tag"))
        commit-sha (head url)
        target (cache-target url tag-sha)
        stage (cache-stage-dir target)]
    (check= "tag" (sh-out (str "git -C " (shell-quote url)
                                " cat-file -t " (shell-quote tag-sha)))
            "fixture SHA names an annotated-tag object")
    (check (throws? #(ensure-git 'fixture/annotated-tag url tag-sha))
           "annotated-tag object ID is rejected instead of peeled")
    (check (not (jolt.host/file-exists? target))
           "annotated-tag object never publishes a cache entry")
    (check (not (jolt.host/file-exists? (cache-lock-dir target)))
           "annotated-tag rejection cleans private staging state")
    (check (not (jolt.host/file-exists? stage))
           "annotated-tag rejection removes the sibling checkout stage")

    ;; Git replacement refs alter cat-file/rev-parse unless every identity query
    ;; explicitly disables them. Seed an otherwise plausible cache leaf whose
    ;; tag object is made to masquerade as the checked-out commit.
    (mkdir! (subs target 0 (.lastIndexOf target "/")))
    (sh! (str "git clone --quiet " (shell-quote url) " "
              (shell-quote target)))
    (sh! (str "git -C " (shell-quote target)
              " update-ref " (shell-quote (str "refs/replace/" tag-sha))
              " " (shell-quote commit-sha)))
    (check= "commit"
            (sh-out (str "git -C " (shell-quote target)
                         " cat-file -t " (shell-quote tag-sha)))
            "fixture replacement makes tag appear to be a commit")
    (check= "tag"
            (sh-out (str "git --no-replace-objects -C "
                         (shell-quote target) " cat-file -t "
                         (shell-quote tag-sha)))
            "literal object query still sees annotated tag")
    (check (not (checkout-valid? target tag-sha url))
           "checkout validation ignores replacement refs")))

(defn- test-public-resolver-uses-verified-root! [root]
  (let [url (str root "/public-origin")
        _ (init-repo! url :public)
        _ (mkdir! (str url "/src/fixture"))
        sha (commit! url "src/fixture/public.clj"
                     "(ns fixture.public)\n(def value :ok)\n"
                     "add source")
        project (str root "/public-project")
        target (cache-target url sha)]
    (mkdir! project)
    (spit (str project "/deps.edn")
          (pr-str {:deps {'fixture/public {:git/url url :git/sha sha}}}))
    (let [resolved (jolt.deps/resolve-project project)]
      (check (some #(= (str target "/src") %) (:roots resolved))
             (str "public resolve-project includes verified Git source root: "
                  (pr-str (:roots resolved))))
      (check (checkout-valid? target sha url)
             "coord-root public path resolves through transactional cache"))))

(defn- test-sha-prefix-contract! [root]
  (let [url (str root "/short-sha-origin")
        sha (init-repo! url :short-sha)
        prefix (subs sha 0 12)
        target (cache-target url prefix)]
    (check= target (ensure-git 'fixture/short-sha url prefix)
            "tools.deps-style abbreviated SHA resolves to its exact commit")
    (check (checkout-valid? target prefix url)
           "abbreviated SHA cache entry compares full resolved object IDs")
    (check (throws? #(ensure-git 'fixture/not-a-sha url "../main"))
           "non-hex ref/path is rejected before cache path construction")))

(defn- run! []
  (let [root (first *command-line-args*)]
    (when-not (and root (jolt.host/getenv "JOLT_GITLIBS")
                   (jolt.host/getenv "GITLIBS"))
      (throw (ex-info "deps-test requires fixture root, JOLT_GITLIBS, and GITLIBS" {})))
    (test-private-cache-paths-stay-shallow! root)
    (test-windows-git-dir-path-budget! root)
    (test-windows-backslash-mkdirs! root)
    (test-failed-clone-is-recoverable! root)
    (test-stage-cleanup-failure-retains-lock! root)
    (test-incomplete-and-dirty-entries-are-repaired! root)
    (test-wrong-head-is-repaired! root)
    (test-concurrent-losers-reuse-winner! root)
    (test-separate-processes-share-one-publication! root)
    (test-waiter-observes-in-flight-winner! root)
    (test-orphan-sibling-stage-is-recovered! root)
    (test-post-lock-origin-reread-precedes-stage-cleanup! root)
    (test-healthy-owner-may-take-longer-than-ten-seconds! root)
    (test-stale-lock-diagnostic-preserves-owner! root)
    (test-tools-gitlibs-reuse-is-read-only! root)
    (test-submodule-dirt-invalidates-checkout! root)
    (test-coordinate-cache-key-separates-sanitize-collision! root)
    (test-literal-origin-survives-insteadof! root)
    (test-clone-default-remote-name-cannot-break-origin! root)
    (test-relative-local-origin-retains-literal-identity! root)
    (test-forced-coordinate-key-collision-is-nondestructive! root)
    (test-index-flags-and-sparse-checkout-are-repaired! root)
    (test-publish-never-nests-and-revalidates! root)
    (test-annotated-tag-object-is-not-a-commit-sha! root)
    (test-public-resolver-uses-verified-root! root)
    (test-sha-prefix-contract! root)))

(defn -main [& _]
  (run!)
  (if (seq @failures)
    (do
      (println "deps-test: FAILED")
      (doseq [failure @failures] (println "  -" failure))
      (throw (ex-info "deps-test failures"
                      {:checks @checks :failures (count @failures)})))
    (println "deps-test:" @checks "checks passed")))

;; `joltc run` loads the file; it does not invoke -main automatically.
(-main)
