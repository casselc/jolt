;; jolt.process gate — exercises the public sub-process API against real programs.
;; Run: bin/jolt run test/chez/process-test.clj (smoke.sh greps for "PROCESS-TEST OK").
(ns process-test
  (:require [jolt.process :as p :refer [process sh check pipeline]]
            [jolt.fs :as fs]
            [clojure.string :as str]))

(def failures (atom []))

;; A MACRO, not a fn, so the label is announced BEFORE the expression under test runs
;; — as a fn, `got` is evaluated at the call site and a check that blocks never
;; reaches the announcement. Every check here spawns a real child process, so any one
;; of them can block forever on a pipe or a wait, and this file used to print nothing
;; until the final verdict: a hung check left an empty log with no way to tell which.
;; (It hung the CI gate for over three hours exactly this way; jolt-pgbh.)
;;
;; The flush is load-bearing, not decoration: smoke.sh redirects this to a file, where
;; output is block-buffered, so a killed process loses whatever it had not flushed —
;; which is how "it printed nothing at all" survived even a 120s cap.
(defmacro check-eq [label got want]
  `(do
     (print (str "  .. " ~label "\n"))
     (flush)
     (let [g# ~got w# ~want]
       (when-not (= g# w#)
         (swap! failures conj (str ~label ": want " (pr-str w#) " got " (pr-str g#)))))))

;; tokenize (pure)
(check-eq "tokenize" (p/tokenize "a  b 'c d'") ["a" "b" "c d"])
(check-eq "tokenize empty" (p/tokenize "") [])

;; capture stdout / exit codes
(check-eq "sh out" (:out (sh ["echo" "hello"])) "hello\n")
(check-eq "sh exit 0" (:exit (sh ["true"])) 0)
(check-eq "sh exit 1" (:exit (sh ["false"])) 1)
(check-eq "exit code passthrough" (:exit (sh ["sh" "-c" "exit 7"])) 7)

;; args are literal (no shell splitting/globbing of an argument)
(check-eq "literal arg" (:out (sh ["echo" "a b  c"])) "a b  c\n")

;; stderr: capture, and merge into stdout
(check-eq "err capture" (:err (sh ["sh" "-c" "echo boom 1>&2"] {:err :string})) "boom\n")
(check-eq "err->out" (:out (sh ["sh" "-c" "echo e 1>&2"] {:err :out})) "e\n")

;; stdin: feed a string
(check-eq "in string" (:out (sh ["cat"] {:in "line1\nline2\n"})) "line1\nline2\n")

;; :dir and :env / :extra-env
(check-eq "dir" (:out (sh ["pwd"] {:dir "/tmp"})) "/tmp\n")
(check-eq "env replace" (:out (sh ["sh" "-c" "echo $JP_VAR"] {:env {"JP_VAR" "set"}})) "set\n")
(check-eq "extra-env keeps PATH" (:out (sh ["sh" "-c" "echo $JP_X"] {:extra-env {"JP_X" "y"}})) "y\n")

;; check throws on non-zero, returns the derefed process on success
(check-eq "check ok exit" (:exit (check (process ["true"]))) 0)
(check-eq "check throws"
          (try (check (process ["false"])) :no-throw (catch Exception _ :threw)) :threw)

;; pipelines via threading and via pipeline
(check-eq "pipe ->" (-> (process ["printf" "a\nb\nc\n"]) (process ["grep" "b"]) :out slurp) "b\n")
(check-eq "pipeline count" (count (pipeline (-> (process ["echo" "x"]) (process ["cat"])))) 2)

;; process record deref carries :out/:exit
(let [res @(process ["echo" "derefed"] {:out :string})]
  (check-eq "deref out" (:out res) "derefed\n")
  (check-eq "deref exit" (:exit res) 0))

;; timed deref honours the timeout BOTH ways (jolt-go9n): a live process answers
;; the timeout value, a finished one its map — and neither throws a cast error
;; (jolt takes the vendored :jolt splice arm, not bb's empty one).
(let [slow (process ["sleep" "30"])]
  (check-eq "timed deref times out" (deref slow 150 :timed-out) :timed-out)
  (p/destroy slow))
(check-eq "timed deref after exit" (:exit (deref (process ["true"]) 5000 :hung)) 0)

;; :out to a file
(let [tmp (str (fs/create-temp-file {:prefix "jp-" :suffix ".txt"}))]
  @(process ["echo" "to-file"] {:out tmp})
  (check-eq "out->file" (slurp tmp) "to-file\n")
  (fs/delete-if-exists tmp))

;; alive? / destroy / signal exit code
(let [proc (process ["sleep" "10"])]
  (check-eq "alive?" (p/alive? proc) true)
  (p/destroy proc)
  (check-eq "sigterm exit" (:exit @proc) 143)
  (check-eq "dead after destroy" (p/alive? proc) false))

;; a spawned child inherits the user's cwd (user.dir / JOLT_PWD), not jolt's OS cwd
;; (the launcher cd's to the repo root but preserves the user's cwd in JOLT_PWD)
(check-eq "child cwd = user.dir"
          (str (fs/canonicalize (str/trim (:out (sh ["pwd"])))))
          (str (fs/canonicalize (System/getProperty "user.dir"))))
;; an explicit :dir sets the child's cwd (pwd echoes the logical cd path)
(let [sub (fs/create-temp-dir {:prefix "jp-dir-"})]
  (check-eq "dir set" (str/trim (:out (sh ["pwd"] {:dir (str sub)}))) (str sub))
  (fs/delete-tree sub))

;; ProcessBuilder.start throws (like the JVM) when the program can't be resolved,
;; with a "No such file" message — not a shell "not found" after spawning
(check-eq "missing program throws"
          (try (sh ["definitely-no-such-program-xyz"]) :no-throw
               (catch Exception e (if (re-find #"No such file" (str (ex-message e))) :nosuch :other)))
          :nosuch)

;; A child that cannot be waited on must still produce an answer. With SIGCHLD set
;; to SIG_IGN the kernel reaps every child itself, so waitpid can only ever fail
;; with ECHILD — and the reap loop used to treat that as "ask again", spinning
;; forever while holding the process mutex. No output, no exit, for as long as the
;; caller waited: that is what sat on a CI gate for 3h42m (jolt-pgbh). The
;; disposition survives exec, so jolt can inherit it from a parent it never chose,
;; which is why it reproduced on one runner and nowhere else.
;;
;; Set it here deliberately, after a spawn has already run (so the spawn path's
;; SIG_DFL restore has happened and is not what is under test), to put the reap
;; loop in exactly that state. If this check hangs, the spin is back — smoke.sh's
;; per-case cap names it.
(jolt.ffi/load-library)
(def c-signal (jolt.ffi/__cfn "signal" [:int :pointer] :pointer))
(def SIGCHLD (if (str/includes? (System/getProperty "os.name") "Mac") 20 17))
;; Every blocking call stays INSIDE a check-eq, so the label is announced before it
;; runs: written as a `let` binding instead, the deref hangs before anything is
;; printed and the log ends on the PREVIOUS check's label — pointing at the wrong
;; one. (Verified by reintroducing the spin: that is exactly what it did.)
(let [prev (c-signal SIGCHLD 1)]                     ; 1 = SIG_IGN
  ;; 0 when the kernel auto-reaped it (the status is then unrecoverable — a
  ;; documented divergence from the JVM, which always reaps its own children), or
  ;; the true 5 on a platform that still let us reap. Never a hang.
  (check-eq "unwaitable child still yields an exit code"
            (contains? #{0 5} (:exit @(process ["sh" "-c" "exit 5"]))) true)
  ;; a signalled child's status IS recoverable without waitpid: 128+signal
  (let [proc (process ["sleep" "10"])]
    (p/destroy proc)
    (check-eq "unwaitable signalled child reports 128+SIGTERM" (:exit @proc) 143))
  (c-signal SIGCHLD prev))                           ; put the disposition back

;; class / instance? derive from the central registry
(check-eq "pb instance?" (instance? java.lang.ProcessBuilder (java.lang.ProcessBuilder. ["true"])) true)
(check-eq "proc class" (.getName (class (:proc @(process ["true"])))) "java.lang.Process")

;; --- ProcessBuilder.inheritIO and the redirect getters (jolt-674) -------------
;; inheritIO() is defined as redirectInput(INHERIT).redirectOutput(INHERIT)
;; .redirectError(INHERIT) returning this. Before it existed the miss reported as
;; "No matching field found: inheritIO" — jolt reads a 0-arg method miss as a
;; field probe, like the JVM reflector — and callers had to spell the three out.
;; Every value below is JVM Clojure's.
(check-eq "inheritIO runs the issue's repro" (.. (java.lang.ProcessBuilder. ["true"]) inheritIO start waitFor) 0)
(check-eq "inheritIO propagates a non-zero exit" (.. (java.lang.ProcessBuilder. ["false"]) inheritIO start waitFor) 1)
(let [pb (java.lang.ProcessBuilder. ["true"])]
  (check-eq "inheritIO returns this" (identical? pb (.inheritIO pb)) true))
(let [pb (doto (java.lang.ProcessBuilder. ["true"]) .inheritIO)]
  (check-eq "inheritIO sets stdin"  (= (.redirectInput pb)  java.lang.ProcessBuilder$Redirect/INHERIT) true)
  (check-eq "inheritIO sets stdout" (= (.redirectOutput pb) java.lang.ProcessBuilder$Redirect/INHERIT) true)
  (check-eq "inheritIO sets stderr" (= (.redirectError pb)  java.lang.ProcessBuilder$Redirect/INHERIT) true))
;; the getters: an unset stream reads back as PIPE, the documented default
(let [pb (java.lang.ProcessBuilder. ["true"])]
  (check-eq "an unset redirect is PIPE" (= (.redirectInput pb) java.lang.ProcessBuilder$Redirect/PIPE) true)
  (check-eq "redirectErrorStream defaults false" (.redirectErrorStream pb) false))
(check-eq "redirectErrorStream round-trips"
          (.redirectErrorStream (doto (java.lang.ProcessBuilder. ["true"]) (.redirectErrorStream true))) true)
;; the two are independent on the JVM: inheritIO does not clear a merge
(check-eq "inheritIO leaves redirectErrorStream alone"
          (.redirectErrorStream (doto (java.lang.ProcessBuilder. ["true"])
                                  (.redirectErrorStream true) .inheritIO)) true)
;; a later redirect overrides only the stream it names
(let [pb (doto (java.lang.ProcessBuilder. ["true"])
           .inheritIO (.redirectOutput java.lang.ProcessBuilder$Redirect/PIPE))]
  (check-eq "a later redirect overrides one stream"
            [(= (.redirectOutput pb) java.lang.ProcessBuilder$Redirect/PIPE)
             (= (.redirectInput pb) java.lang.ProcessBuilder$Redirect/INHERIT)] [true true]))

;; --- fd-level INHERIT ---------------------------------------------------------
;; Redirect.INHERIT hands the child jolt's REAL fds (posix_spawn leaves 0/1/2
;; untouched), not a pump-fed pipe. Two things only real inheritance can do:
;; the child sees a tty when jolt runs on one, and successive INHERIT-stdin
;; children share the fd offset. Both run a nested jolt, because this test's
;; own stdio belongs to the smoke harness.
(def jolt-bin (or (System/getenv "JOLT_BIN") "bin/jolt"))
(def mac? (str/includes? (System/getProperty "os.name") "Mac"))

;; a child that writes through INHERIT lands on the nested jolt's stdout
(let [nested (str "(-> (java.lang.ProcessBuilder. [\"sh\" \"-c\" \"echo INHERITED-OUT\"])"
                  " (.redirectOutput java.lang.ProcessBuilder$Redirect/INHERIT)"
                  " (.start) (.waitFor))")
      out (:out (sh [jolt-bin "-e" nested]))]
  (check-eq "INHERIT stdout reaches the parent's stdout"
            (str/includes? out "INHERITED-OUT") true))

;; inheritIO is real fd inheritance, not a recorded flag: BOTH streams land on
;; the nested jolt's stdio, and stderr with them (the single-stream test above
;; only covers stdout).
(let [nested (str "(.. (java.lang.ProcessBuilder. [\"sh\" \"-c\" \"echo IIO-OUT; echo IIO-ERR 1>&2\"])"
                  " inheritIO start waitFor)")
      r (sh [jolt-bin "-e" nested])]
  (check-eq "inheritIO stdout reaches the parent" (str/includes? (:out r) "IIO-OUT") true)
  (check-eq "inheritIO stderr reaches the parent" (str/includes? (str (:out r) (:err r)) "IIO-ERR") true))

;; isatty: under a pty (script(1)), an INHERIT child's stdout IS the terminal.
;; A pump-fed pipe can never answer true here.
(when (fs/which "script")
  (let [nested (str "(-> (java.lang.ProcessBuilder. [\"sh\" \"-c\" \"test -t 1 && echo IS-A-TTY || echo NOT-A-TTY\"])"
                    " (.redirectOutput java.lang.ProcessBuilder$Redirect/INHERIT)"
                    " (.start) (.waitFor))")
        cmd (if mac?
              ["script" "-q" "/dev/null" jolt-bin "-e" nested]
              ["script" "-qec" (str jolt-bin " -e '" nested "'") "/dev/null"])
        out (:out (sh cmd))]
    (check-eq "INHERIT stdout is the real fd (isatty under a pty)"
              (str/includes? out "IS-A-TTY") true)))

;; INHERIT stdin shares the fd AND its read offset: a first child consuming
;; exactly two bytes leaves the rest for the second. The pumps slurped ahead
;; into the first child's pipe, starving the second.
(let [nested (str "(let [rd (fn [cmd] (let [p (-> (java.lang.ProcessBuilder. cmd)"
                  " (.redirectInput java.lang.ProcessBuilder$Redirect/INHERIT) (.start))]"
                  " (.waitFor p) (slurp (.getInputStream p))))]"
                  " (rd [\"sh\" \"-c\" \"dd bs=1 count=2 2>/dev/null >/dev/null\"])"
                  " (print (str \"SECOND=<\" (rd [\"cat\"]) \">\")))")
      out (:out (sh [jolt-bin "-e" nested] {:in "ABCD"}))]
  (check-eq "INHERIT stdin shares the fd offset between children"
            (str/includes? out "SECOND=<CD>") true))

;; --- shutdown hooks -----------------------------------------------------------
;; Runtime.addShutdownHook is what babashka.process's `:shutdown` option registers,
;; so if the hooks never run, `:shutdown destroy-tree` cleans up nothing (#571).
;; A nested jolt, because a hook can only be observed by letting a process exit.
(let [out (:out (sh [jolt-bin "-e" (str "(.addShutdownHook (Runtime/getRuntime)"
                                        " (Thread. (fn [] (println \"HOOK\"))))"
                                        " (println \"MAIN\")")]))]
  (check-eq "shutdown hook runs when the process exits" (str/split-lines out) ["MAIN" "HOOK"]))

(let [out (:out (sh [jolt-bin "-e" (str "(.addShutdownHook (Runtime/getRuntime)"
                                        " (Thread. (fn [] (println \"HOOK\"))))"
                                        " (println \"MAIN\") (System/exit 0)")]))]
  (check-eq "shutdown hook runs on System/exit" (str/split-lines out) ["MAIN" "HOOK"]))

;; Chez's exit-handler is a THREAD parameter, so a hook registered from a worker
;; installs the wrapper on that worker and nowhere else. The main thread has to
;; carry one of its own or this hook would be dropped on the way out.
(let [out (:out (sh [jolt-bin "-e" (str "(let [t (Thread. (fn [] (.addShutdownHook (Runtime/getRuntime)"
                                        "                          (Thread. (fn [] (println \"HOOK\"))))))]"
                                        "  (.start t) (.join t) (println \"MAIN\"))")]))]
  (check-eq "a hook registered off the main thread still runs" (str/split-lines out) ["MAIN" "HOOK"]))

(let [out (:out (sh [jolt-bin "-e" (str "(let [rt (Runtime/getRuntime)"
                                        "      h (Thread. (fn [] (println \"HOOK\")))]"
                                        "  (.addShutdownHook rt h) (.removeShutdownHook rt h)"
                                        "  (println \"MAIN\"))")]))]
  (check-eq "a removed shutdown hook does not run" (str/split-lines out) ["MAIN"]))

;; Is a pid still alive? `kill -0` is the portable answer (exit 0 = alive). Run
;; through `sh` so it is the shell BUILTIN: a standalone kill(1) is not on every
;; Linux image, and ProcessBuilder.start rejects a program it cannot resolve.
(defn- pid-alive? [pid]
  (zero? (:exit (sh ["sh" "-c" (str "kill -0 " pid)] {:err :string}))))

;; SIGTERM to a jolt process must run its shutdown hooks BEFORE it exits — the
;; whole point of `:shutdown destroy-tree` is that a supervisor's `kill` does not
;; leave the child tree running (#571). Both spawn paths are covered: the default
;; (piped stdio, Chez's own fork) and fd-level INHERIT (posix_spawn).
;;
;; The nested jolt writes its child's pid out through a shell `$$` — the same
;; probe the bug report used — so this side can ask whether that exact process
;; outlived the parent.
(doseq [[label redirs] [["piped stdio" ""]
                        ["fd-level INHERIT" " :out :inherit :err :inherit"]]]
  (let [pidf (str (fs/create-temp-file {:prefix "jp-shutdown-" :suffix ".pid"}))
        nested (str "(require '[jolt.process :as p])"
                    " @(p/process [\"sh\" \"-c\" \"echo $$ > \\\"$CHILD_PID_FILE\\\"; sleep 30\"]"
                    " {:extra-env {\"CHILD_PID_FILE\" \"" pidf "\"}" redirs
                    "  :shutdown p/destroy-tree})")
        parent (process [jolt-bin "-e" nested])]
    ;; the grandchild publishes its pid before it sleeps
    (loop [n 0]
      (when (and (< n 200) (str/blank? (slurp pidf)))
        (Thread/sleep 50)
        (recur (inc n))))
    (let [gpid (str/trim (slurp pidf))]
      (p/destroy parent)
      ;; poll rather than deref: a regression here is "the parent ignores
      ;; SIGTERM", and @parent would then hang the gate instead of failing it
      (loop [n 0] (when (and (< n 60) (p/alive? parent)) (Thread/sleep 50) (recur (inc n))))
      (when (p/alive? parent) (.destroyForcibly (:proc parent)) (Thread/sleep 200))
      ;; the hook's kill and the child's death are not instantaneous
      (loop [n 0] (when (and (< n 40) (pid-alive? gpid)) (Thread/sleep 50) (recur (inc n))))
      (check-eq (str "SIGTERM runs :shutdown hooks (" label ")")
                (and (seq gpid) (pid-alive? gpid)) false)
      (when (pid-alive? gpid) (sh ["sh" "-c" (str "kill -9 " gpid)])))
    (fs/delete-if-exists pidf)))

;; --- descendants / destroy-tree over a real grandchild (jolt-hpdu) -----------
;; ProcessHandle.descendants was hardcoded empty, so destroy-tree WAS destroy:
;; killing a wrapper left whatever the wrapper spawned running (a `lake env repl`
;; wrapper's repl survived as a 4.8GB orphan). The direct child here is a sh that
;; publishes its background sleep's pid ($!) and waits, so the sleep is a genuine
;; grandchild: descendants must see it, and destroy-tree must kill it.
(let [pidf (str (fs/create-temp-file {:prefix "jp-desc-" :suffix ".pid"}))
      p (process ["sh" "-c" (str "sleep 30 & echo $! > " pidf "; wait")])]
  (loop [n 0]
    (when (and (< n 200) (str/blank? (slurp pidf)))
      (Thread/sleep 50)
      (recur (inc n))))
  (let [gpid (str/trim (slurp pidf))
        handles (iterator-seq (.iterator (.descendants (.toHandle (:proc p)))))]
    (check-eq "descendants sees the grandchild"
              (boolean (some #(= (str (.pid %)) gpid) handles)) true)
    (p/destroy-tree p)
    (loop [n 0] (when (and (< n 60) (pid-alive? gpid)) (Thread/sleep 50) (recur (inc n))))
    (check-eq "destroy-tree kills the grandchild"
              (and (seq gpid) (pid-alive? gpid)) false)
    (when (pid-alive? gpid) (sh ["sh" "-c" (str "kill -9 " gpid)]))
    (loop [n 0] (when (and (< n 60) (p/alive? p)) (Thread/sleep 50) (recur (inc n))))
    (check-eq "destroy-tree kills the direct child" (p/alive? p) false))
  (fs/delete-if-exists pidf))

;; A jolt sitting at a stdin prompt must still take SIGTERM, hooks and all. It
;; used to wait INSIDE Chez's blocking read, which holds the whole Scheme world:
;; nothing else runs, so the watcher could not have woken there (jolt-p9ua).
;; The nested jolt registers a hook, then blocks on read-line with a pipe stdin
;; nothing ever writes to.
;;
;; Nothing here blocks without a bound: a failure has to report itself, not hang
;; the gate.
(let [readyf (str (fs/create-temp-file {:prefix "jp-stdin-" :suffix ".txt"}))
      hookf (str (fs/create-temp-file {:prefix "jp-stdin-hook-" :suffix ".txt"}))
      nested (str "(.addShutdownHook (Runtime/getRuntime)"
                  "  (Thread. (fn [] (spit \"" hookf "\" \"RAN\"))))"
                  " (spit \"" readyf "\" \"ready\") (read-line)")
      proc (process [jolt-bin "-e" nested])]
  (loop [n 0]
    (when (and (< n 200) (str/blank? (slurp readyf)))
      (Thread/sleep 50)
      (recur (inc n))))
  (p/destroy proc)
  (loop [n 0] (when (and (< n 60) (p/alive? proc)) (Thread/sleep 50) (recur (inc n))))
  (check-eq "SIGTERM reaches a jolt parked at a stdin prompt" (p/alive? proc) false)
  ;; SIGKILL, since a process that survived SIGTERM will survive another one
  (when (p/alive? proc) (.destroyForcibly (:proc proc)) (Thread/sleep 200))
  (check-eq "and its shutdown hooks run there too" (slurp hookf) "RAN")
  (fs/delete-if-exists readyf)
  (fs/delete-if-exists hookf))

;; Same root cause from the other side: while the main thread waits on stdin the
;; rest of the program has to keep running. A future stopped ticking the moment a
;; prompt was reached, which is not what a JVM does with a thread in
;; System.in.read() (jolt-p9ua).
(let [tickf (str (fs/create-temp-file {:prefix "jp-ticks-" :suffix ".txt"}))
      nested (str "(future (dotimes [i 100] (Thread/sleep 50) (spit \"" tickf "\" (str i))))"
                  " (read-line)")
      proc (process [jolt-bin "-e" nested])
      tick (fn [] (let [s (str/trim (slurp tickf))] (when-not (str/blank? s) (parse-long s))))]
  (loop [n 0] (when (and (< n 200) (nil? (tick))) (Thread/sleep 50) (recur (inc n))))
  (check-eq "a future runs while the main thread waits on stdin" (some? (tick)) true)
  ;; and keeps running, rather than getting one tick in before the read parks
  (let [before (or (tick) 0)]
    (Thread/sleep 400)
    (check-eq "and keeps running" (> (or (tick) 0) before) true))
  (.destroyForcibly (:proc proc))
  (fs/delete-if-exists tickf))

;; A child must be interruptible by ^C, on every spawn path. Chez's fork leaves
;; SIGINT set to SIG_IGN in the child — the system(3) leak the convention exists
;; to avoid, not the convention — so a child spawned the default way could not be
;; interrupted at all where the JVM's dies (jolt-a4hs). posix_spawn drives both
;; paths now, and `sh` reports 128+SIGINT when the signal lands.
(check-eq "a child dies on SIGINT (piped stdio)"
          (:exit (sh ["sh" "-c" "kill -INT $$"])) 130)
(check-eq "a child dies on SIGINT (fd-level INHERIT)"
          (:exit @(process ["sh" "-c" "kill -INT $$"] {:out :string :err :inherit})) 130)

;; jolt blocks signals in its own threads — SIGINT so ^C reaches the thread parked
;; in park-until-interrupt rather than a worker in a foreign call, SIGTERM/SIGHUP
;; so the shutdown watcher can take them — and a spawn hands the calling thread's
;; mask straight to the child. Neither may travel: a child with SIGTERM blocked
;; survives the very destroy the hook exists to call, and one with SIGINT blocked
;; ignores ^C (jolt-e5sb).
(.addShutdownHook (Runtime/getRuntime) (Thread. (fn [] nil)))
(let [proc (process ["sleep" "10"])]
  (p/destroy proc)
  (check-eq "a child spawned after a shutdown hook is still killable" (:exit @proc) 143))
(check-eq "a child does not inherit jolt's blocked SIGTERM"
          (:exit @(process ["sh" "-c" "kill -TERM $$"] {:out :string :err :inherit})) 143)
(jolt.host/block-sigint)
(check-eq "a child does not inherit jolt's blocked SIGINT"
          (:exit @(process ["sh" "-c" "kill -INT $$"] {:out :string :err :inherit})) 130)

;; --- opt-in scoped process ownership (jolt.host/process-scope-run) -----------
;; Linux-only facility (host/chez/java/process.ss): an OPT-IN structured request
;; spawns a DIRECT argv (no shell built by the API) into its own process group;
;; on controller timeout the cleanup TERMs the whole group, then KILLs it, and
;; the call returns only once /proc confirms nothing live remains in the owned
;; scope. Everything above — ProcessBuilder, process, sh, destroy semantics — is
;; the unscoped API and passing unchanged IS the no-regression proof for it.
;; Off Linux the entry point throws UnsupportedOperationException, so the whole
;; section is gated.
(def scope-linux? (str/includes? (System/getProperty "os.name") "Linux"))

;; Alive, in the same sense the facility's confirm loop means it: a /proc entry
;; whose state is not Z/X/x. kill -0 (pid-alive? above) answers true for a
;; zombie, which would false-fail a confirm that did its job — a terminated
;; grandchild pid 1 has not reaped yet is dead. RACE-HARDENED: the process may
;; exit between the stat check and the read, and a vanished /proc entry means
;; NOT live (exited), never an exception that kills the whole test file; a
;; truncated/odd stat line is likewise not-live rather than a crash.
(defn- scope-proc-live? [pid]
  (when pid
    (try
      (let [s (slurp (str "/proc/" pid "/stat"))
            rp (.lastIndexOf s ")")]
        (and (>= rp 0)
             (> (count s) (+ rp 2))
             (not (contains? #{"Z" "X" "x"} (subs s (+ rp 2) (+ rp 3))))))
      (catch Exception _ false))))

;; Belt and braces so a REGRESSION cannot leak the TERM-resistant tree into the
;; CI box AFTER a failed check — but only after: the assertion runs first and
;; captures its evidence into @failures, because a cleanup that ran first would
;; destroy the very thing the check must observe (a nuked grandchild looks
;; dead to a check that follows). No "--" before the negative pid: dash's kill
;; builtin rejects that spelling ("Illegal number: -") where the bare negative
;; argument is the group address it understands.
(defn- scope-nuke-group [pgid]
  (sh ["sh" "-c" (str "kill -9 -" pgid)] {:err :string}))

(when scope-linux?
  ;; The regression case: a tree where EVERY member resists SIGTERM — the child
  ;; traps TERM, and a shell that has trapped TERM leaves SIG_IGN in place for
  ;; everything it spawns after the trap (dispositions are inherited across
  ;; fork+exec), so the grandchild's sleep survives the TERM wave too. Only
  ;; kill(-pgid, KILL) can clear it. If cleanup ever degrades to signalling the
  ;; root pid alone, or to TERM without the KILL escalation, the grandchild is
  ;; still alive when the call returns and these checks fail.
  (let [pidf (str (fs/create-temp-file {:prefix "jp-scope-" :suffix ".pid"}))
        script (str "trap '' TERM; "
                    "/bin/sh -c 'trap \"\" TERM; echo $$ > " pidf "; sleep 60' & wait")
        res (jolt.host/process-scope-run
              {:cmd ["/bin/sh" "-c" script]
               :timeout-ms 800
               :term-grace-ms 250})]
    ;; the root ignored TERM, so a reaped 137 (128+SIGKILL) is direct evidence
    ;; the escalation reached the KILL wave rather than stopping at TERM
    (check-eq "scoped: timed out" (:timed-out res) true)
    (check-eq "scoped: TERM-resistant root died to the KILL wave (:exit 137)" (:exit res) 137)
    (check-eq "scoped: root is gone from /proc" (scope-proc-live? (:pid res)) false)
    ;; and the independently-published grandchild pid is dead too — confirmed
    ;; OUTSIDE the facility, not by trusting its return value. ASSERT FIRST:
    ;; leaked? is sampled and recorded before any cleanup fires, so a failure
    ;; keeps its evidence and the nuke below cannot mask it into a pass.
    (let [gpid (str/trim (slurp pidf))
          leaked (scope-proc-live? gpid)]
      (check-eq "scoped: TERM-resistant grandchild is not alive after timeout"
                leaked false)
      (when leaked (scope-nuke-group (:pid res))))
    (fs/delete-if-exists pidf))

  ;; A descendant that ESCAPES the group — `setsid sleep` takes its own
  ;; session+group — while its ppid link still names the root: the group waves
  ;; cannot reach it, so the per-pid net must. That net revalidates the pid
  ;; against reuse immediately before each kill (reading the CURRENT /proc
  ;; ppid chain), so this case is also the regression proof for the
  ;; revalidation: without it, an escaped descendant outlives the call. The
  ;; root does not trap TERM, so it dies at the TERM wave (143) while the
  ;; escaped sleep is TERMed by pid.
  (when (fs/which "setsid")
    (let [pidf (str (fs/create-temp-file {:prefix "jp-scope-esc-" :suffix ".pid"}))
          res (jolt.host/process-scope-run
                {:cmd ["/bin/sh" "-c"
                       (str "setsid sleep 60 & echo $! > " pidf "; wait")]
                :timeout-ms 800 :term-grace-ms 250})
          gpid (str/trim (slurp pidf))
          leaked (scope-proc-live? gpid)]
      (check-eq "scoped: timed out (escaped-descendant case)" (:timed-out res) true)
      (check-eq "scoped: unresisting root dies at the TERM wave" (:exit res) 143)
      (check-eq "scoped: group-escaped descendant is killed by the revalidated per-pid net"
                leaked false)
      ;; it escaped into its OWN group, so its pid is its pgid
      (when leaked (scope-nuke-group gpid))
      (fs/delete-if-exists pidf)))

  ;; The distinct execution group, reported by the child itself: its pgid is
  ;; its OWN pid and not jolt's group. sh's comm has no spaces, so sh's read
  ;; can split /proc/self/stat fields (pid comm state ppid pgrp ...).
  (let [pidf (str (fs/create-temp-file {:prefix "jp-scope-grp-" :suffix ".txt"}))
        res (jolt.host/process-scope-run
              {:cmd ["/bin/sh" "-c"
                     (str "read -r a b c d e f < /proc/self/stat; echo \"$a $e\" > " pidf "; sleep 30")]
               :timeout-ms 3000 :term-grace-ms 200})
        mine (let [s (slurp "/proc/self/stat")
                   rp (.lastIndexOf s ")")]
               ;; after the last ')': state ppid pgrp ... — pgrp is index 2
               (nth (str/split (subs s (+ rp 2)) #"\s+") 2))
        [cpid cgrp] (map str/trim (str/split (str/trim (slurp pidf)) #"\s+"))]
    (check-eq "scoped: returned pid is the child the tree grew from" (str (:pid res)) cpid)
    (check-eq "scoped: child leads its own process group" cpid cgrp)
    (check-eq "scoped: group is distinct from jolt's" (not= cgrp (str/trim mine)) true)
    ;; this child traps nothing: the TERM wave alone clears it (exit 143)
    (check-eq "scoped: TERM-susceptible tree dies at the TERM wave" (:exit res) 143)
    (fs/delete-if-exists pidf))

  ;; normal completion inside the timeout: no escalation, exit passthrough
  (check-eq "scoped: normal exit code passes through"
            (:exit (jolt.host/process-scope-run
                     {:cmd ["/bin/sh" "-c" "exit 7"] :timeout-ms 10000})) 7)
  (check-eq "scoped: normal exit is not a timeout"
            (:timed-out (jolt.host/process-scope-run
                          {:cmd ["/bin/true"] :timeout-ms 10000})) false)

  ;; ownership is not conditional on the timeout: a root that exits normally
  ;; while leaving a worker behind still owes the scope its cleanup. Same
  ;; assert-before-cleanup ordering as above: evidence first, nuke second.
  (let [pidf (str (fs/create-temp-file {:prefix "jp-scope-orphan-" :suffix ".pid"}))
        res (jolt.host/process-scope-run
              {:cmd ["/bin/sh" "-c" (str "sleep 60 & echo $! > " pidf "; exit 3")]
               :timeout-ms 8000 :term-grace-ms 200})
        gpid (str/trim (slurp pidf))
        leaked (scope-proc-live? gpid)]
    (check-eq "scoped: normal-exit keeps its own exit code" (:exit res) 3)
    (check-eq "scoped: normal-exit still cleans the leftover grandchild"
              leaked false)
    (when leaked (scope-nuke-group (:pid res)))
    (fs/delete-if-exists pidf))

  ;; :dir and :env (full replacement — HOME is not passed through; PATH is not
  ;; asserted because sh fabricates a default when it is unset)
  (let [of (str (fs/create-temp-file {:prefix "jp-scope-dir-" :suffix ".txt"}))]
    (jolt.host/process-scope-run {:cmd ["/bin/sh" "-c" (str "pwd > " of)]
                                  :dir "/tmp" :timeout-ms 10000})
    (check-eq "scoped: :dir sets the child cwd" (str/trim (slurp of)) "/tmp")
    (fs/delete-if-exists of))
  (let [of (str (fs/create-temp-file {:prefix "jp-scope-env-" :suffix ".txt"}))]
    (jolt.host/process-scope-run {:cmd ["/bin/sh" "-c" (str "echo \"$JP_V|${HOME:-unset}\" > " of)]
                                  :env {"JP_V" "scoped"} :timeout-ms 10000})
    (check-eq "scoped: :env replaces the environment"
              (str/trim (slurp of)) "scoped|unset")
    (fs/delete-if-exists of))

  ;; resolution failures throw like ProcessBuilder.start, not a shell 127
  (check-eq "scoped: missing program throws No-such-file"
            (try (jolt.host/process-scope-run
                   {:cmd ["definitely-no-such-program-xyz"] :timeout-ms 1000})
                 :no-throw
                 (catch Exception e
                   (if (re-find #"No such file" (ex-message e)) :nosuch :other)))
            :nosuch)
  (check-eq "scoped: missing :cmd throws"
            (try (jolt.host/process-scope-run {:timeout-ms 1000}) :no-throw
                 (catch Exception _ :threw)) :threw)
  (check-eq "scoped: missing :timeout-ms throws"
            (try (jolt.host/process-scope-run {:cmd ["true"]}) :no-throw
                 (catch Exception _ :threw)) :threw)

  ;; --- separately bounded stdout/stderr capture (jolt.host/process-scope-run) --
  ;; :out-bytes / :err-bytes replace that stream's /dev/null with a pipe the
  ;; controller loop itself drains via poll(2) (both ends in ONE loop: the
  ;; two-pipe deadlock is structurally impossible), memory stops at the
  ;; caller's cap, and the cap REACHED is an abort that runs the same
  ;; TERM/grace/KILL/confirm cleanup a timeout runs — with :timed-out still
  ;; false, because the clock did not fire. Statuses: :complete = EOF seen
  ;; (the string is the stream's ENTIRE output), :truncated = the byte cap was
  ;; reached (exactly-the-cap and more-than-the-cap are deliberately not
  ;; distinguished), :partial = the run ended with neither.

  ;; clean output on both streams, generously bounded: full capture, no abort
  (let [res (jolt.host/process-scope-run
              {:cmd ["/bin/sh" "-c" "echo hello-out; echo hello-err 1>&2"]
               :timeout-ms 10000 :out-bytes 1000 :err-bytes 1000})]
    (check-eq "scoped capture: stdout string" (:out res) "hello-out\n")
    (check-eq "scoped capture: stderr string" (:err res) "hello-err\n")
    (check-eq "scoped capture: stdout complete" (:out-status res) :complete)
    (check-eq "scoped capture: stderr complete" (:err-status res) :complete)
    (check-eq "scoped capture: clean exit" (:exit res) 0)
    (check-eq "scoped capture: not a timeout" (:timed-out res) false))

  ;; callers not requesting capture keep the /dev/null default — observable in
  ;; the RETURN SHAPE: no :out/:err keys at all, not empty strings
  (let [res (jolt.host/process-scope-run
              {:cmd ["/bin/sh" "-c" "echo noise; echo noise 1>&2"]
               :timeout-ms 10000})]
    (check-eq "scoped: no capture -> no :out key" (nil? (:out res)) true)
    (check-eq "scoped: no capture -> no :out-status key" (nil? (:out-status res)) true)
    (check-eq "scoped: no capture -> no :err key" (nil? (:err res)) true)
    (check-eq "scoped: no capture -> exit passthrough" (:exit res) 0))

  ;; stdout FLOOD: the cap is hit in milliseconds against a 20s clock, so the
  ;; run can only have ended as a capture-overflow abort. The bound is honored
  ;; exactly (never more bytes retained), the retained prefix is real, and the
  ;; scope is dead when the call returns.
  (let [res (jolt.host/process-scope-run
              {:cmd ["/bin/sh" "-c"
                     "echo FLOOD-START; while :; do echo 0123456789012345678901234567890123456789; done"]
               :timeout-ms 20000 :out-bytes 64})]
    (check-eq "scoped flood: overflow aborts long before the clock" (:timed-out res) false)
    (check-eq "scoped flood: status is :truncated" (:out-status res) :truncated)
    (check-eq "scoped flood: byte bound honored exactly" (count (:out res)) 64)
    (check-eq "scoped flood: retained bytes are the true prefix"
              (str/starts-with? (:out res) "FLOOD-START\n") true)
    (check-eq "scoped flood: root is gone from /proc" (scope-proc-live? (:pid res)) false)
    ;; an untrapping shell dies at the TERM wave (143); the KILL wave (137) is
    ;; the documented backstop — both are honest outcomes of the ladder
    (check-eq "scoped flood: killed by the overflow escalation"
              (contains? #{137 143} (:exit res)) true))

  ;; SEPARATE bounds: stderr floods past a tiny cap while the generously
  ;; bounded stdout still captures completely — the abort killed the writer,
  ;; then the final drain read stdout to EOF. One stream's overflow must not
  ;; corrupt the other's capture.
  (let [res (jolt.host/process-scope-run
              {:cmd ["/bin/sh" "-c"
                     (str "echo one-line; i=0; "
                          "while [ $i -lt 100000 ]; do echo E$i 1>&2; i=$((i+1)); done; "
                          "sleep 30")]
               :timeout-ms 20000 :err-bytes 16 :out-bytes 4096})]
    (check-eq "scoped: stderr flood truncates at its own cap" (:err-status res) :truncated)
    (check-eq "scoped: stderr bound exact" (count (:err res)) 16)
    (check-eq "scoped: bounded stdout still complete" (:out-status res) :complete)
    (check-eq "scoped: bounded stdout content intact" (:out res) "one-line\n")
    (check-eq "scoped: stderr overflow abort is not a timeout" (:timed-out res) false))

  ;; output LARGER than the pipe buffer (~64K): a naive reader deadlocks here
  ;; (the child blocks on the full pipe, the controller blocks on the child).
  ;; The poll-integrated drain must keep both moving: 20000 lines (~108KB)
  ;; captured whole.
  (when (fs/which "seq")
    (let [res (jolt.host/process-scope-run
                {:cmd ["seq" "20000"] :timeout-ms 20000 :out-bytes 1000000})]
      (check-eq "scoped: >pipe-buffer output captured whole" (:out-status res) :complete)
      (check-eq "scoped: big output content intact" (str/ends-with? (:out res) "20000\n") true)
      (check-eq "scoped: big output line count" (count (str/split-lines (:out res))) 20000)
      (check-eq "scoped: big output clean exit" (:exit res) 0)))

  ;; adversarial bytes: invalid UTF-8 must come back as an INERT string —
  ;; lossy decode (U+FFFD per invalid byte), never an exception, never
  ;; evaluated. café = valid C3 A9 passes through; FF is never valid.
  (let [res (jolt.host/process-scope-run
              {:cmd ["/bin/sh" "-c" "printf 'caf\\303\\251\\377\\n'"]
               :timeout-ms 10000 :out-bytes 100})]
    (check-eq "scoped: invalid utf-8 decodes lossily to an inert string"
              (:out res) "caf\u00e9\uFFFD\n")
    (check-eq "scoped: lossy decode is still complete" (:out-status res) :complete))

  ;; :env / :dir compose with capture. The program is spelled ABSOLUTELY, so
  ;; this stays a pure env/cwd composition — bare-PATH resolution is a
  ;; separate arm of proc-sc-resolve-program with its own regression below.
  (let [res (jolt.host/process-scope-run
              {:cmd ["/bin/sh" "-c" "echo \"$JP_CAP in $(pwd)\""]
               :env {"JP_CAP" "scoped"} :dir "/tmp"
               :timeout-ms 10000 :out-bytes 1000})]
    (check-eq "scoped capture: env replaced and cwd set" (:out res) "scoped in /tmp\n")
    (check-eq "scoped capture: env/cwd run completes" (:out-status res) :complete))

  ;; bare-PATH program resolution, as its own regression: the PATH-scan arm of
  ;; proc-sc-resolve-program carried no consequent, so a SUCCESSFUL bare-name
  ;; lookup returned the test's own #t instead of the joined path, and
  ;; posix_spawn rejected #t as a foreign argument. Every pre-existing scoped
  ;; caller spelled /bin/sh, so the arm had never run with a hit before the
  ;; capture tests started using "seq" (which is fs/which-gated above). A bare
  ;; "sh" must resolve through PATH here — asserted by CONTENT, so it fails
  ;; whether resolution throws, mis-spawns, or captures nothing.
  (check-eq "scoped: bare program name resolves through PATH"
            (let [res (jolt.host/process-scope-run
                        {:cmd ["sh" "-c" "echo BARE-PATH-OK"]
                         :timeout-ms 10000 :out-bytes 100})]
              [(:out-status res) (:out res)])
            [:complete "BARE-PATH-OK\n"])

  ;; capture bounds fail closed before anything is spawned — and must be
  ;; INTEGRAL: jnum->exact's truncate would silently floor 2.5 to 2, so the
  ;; bound is checked for integrality and a fraction is a caller error.
  (check-eq "scoped: :out-bytes 0 throws"
            (try (jolt.host/process-scope-run {:cmd ["true"] :timeout-ms 1000 :out-bytes 0})
                 :no-throw (catch Exception _ :threw)) :threw)
  (check-eq "scoped: fractional :out-bytes throws, never silently truncated"
            (try (jolt.host/process-scope-run {:cmd ["true"] :timeout-ms 1000 :out-bytes 2.5})
                 :no-throw (catch Exception _ :threw)) :threw)
  (check-eq "scoped: negative :err-bytes throws"
            (try (jolt.host/process-scope-run {:cmd ["true"] :timeout-ms 1000 :err-bytes -5})
                 :no-throw (catch Exception _ :threw)) :threw)
  (check-eq "scoped: :err-bytes non-numeric throws"
            (try (jolt.host/process-scope-run {:cmd ["true"] :timeout-ms 1000 :err-bytes "big"})
                 :no-throw (catch Exception _ :threw)) :threw)

  ;; timeout with a TERM-resistant tree WHILE CAPTURING: the invariant under
  ;; load — the flood-proof drain neither breaks the escalation ladder nor
  ;; leaks the grandchild, and the grandchild's own stdout line (written
  ;; through the root's inherited pipe) still arrives complete, because the
  ;; final drain runs only after /proc confirms every writer is dead.
  (let [pidf (str (fs/create-temp-file {:prefix "jp-scope-cap-" :suffix ".pid"}))
        script (str "trap '' TERM; "
                    "/bin/sh -c 'trap \"\" TERM; echo $$ > " pidf "; echo GRAND-OUT; sleep 60' & wait")
        res (jolt.host/process-scope-run
              {:cmd ["/bin/sh" "-c" script]
               :timeout-ms 800 :term-grace-ms 250
               :out-bytes 1000})]
    (check-eq "scoped+capture: timed out" (:timed-out res) true)
    (check-eq "scoped+capture: resistant root died to the KILL wave (:exit 137)"
              (:exit res) 137)
    (check-eq "scoped+capture: grandchild's line captured after the kill"
              (:out res) "GRAND-OUT\n")
    (check-eq "scoped+capture: capture complete after the scope emptied"
              (:out-status res) :complete)
    ;; the independently-published grandchild pid is dead, confirmed OUTSIDE
    ;; the facility; assert first, nuke second, exactly like the unscoped case
    (let [gpid (str/trim (slurp pidf))
          leaked (scope-proc-live? gpid)]
      (check-eq "scoped+capture: TERM-resistant grandchild is not alive after timeout"
                leaked false)
      (when leaked (scope-nuke-group (:pid res))))
    (fs/delete-if-exists pidf)))

(if (empty? @failures)
  (println "PROCESS-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "PROCESS-TEST FAILED:" (count @failures))))
