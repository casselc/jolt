;; java.lang.ProcessBuilder / java.lang.Process over posix_spawn.
;;
;; babashka.process (vendored under jolt.process) is built entirely on the JVM
;; ProcessBuilder / Process API; this file provides that surface so the library
;; runs unmodified. A subprocess is a `/bin/sh -c CMD` spawned with posix_spawn,
;; handing back binary stdin/stdout/stderr ports plus the pid. We drive it as
;; ProcessBuilder does:
;;
;;   - the argv list is shell-quoted and `exec`'d, so the shell performs no word
;;     splitting or globbing (matching ProcessBuilder, which execs directly) and
;;     the pid is the target program, not the intermediate sh.
;;   - :dir  -> `cd 'DIR' &&` prefix
;;   - :env  -> `env -i K=V …` prefix (the env map starts as a copy of the parent
;;     environment, so `env -i` reproduces exactly the intended set)
;;   - file / discard redirects -> shell `1> 'f'` / `2>> 'f'` / `1>/dev/null`
;;   - INHERIT -> no file action, so the child keeps jolt's real descriptor (true
;;     fd-level inheritance: isatty holds, stdin offsets are shared); every other
;;     stream gets a pipe.
;;
;; Chez's own open-process-ports is the FALLBACK, for machine types where that
;; FFI surface is missing (Windows), with a pump thread copying between the pipe
;; and jolt's stdio to emulate INHERIT. It is not the primary path: its fork
;; leaves SIGINT ignored in the child, so a subprocess spawned through it cannot
;; be interrupted with ^C (jolt-a4hs).
;;
;; Exit status, liveness and signalling go through libc waitpid/kill via FFI. A
;; per-process mutex serialises reaping so isAlive/waitFor/exitValue never race a
;; second waitpid (which would ECHILD); the decoded status is cached in a box.
;;
;; Loaded after io-streams.ss (make-in-stream / make-out-stream) and the jhost
;; registries (host-static.ss), and after host-static-methods.ss (all-env-pairs).

;; --- libc entry points -------------------------------------------------------
;; Only ever called WNOHANG (see proc-wait-blocking): a blocking waitpid parks in
;; the kernel, where SIGCHLD=SIG_IGN can hold it indefinitely, and a plain foreign
;; call also keeps the thread "active" for the stop-the-world collector while it
;; waits. Polling sidesteps both.
(define proc-waitpid (jolt-foreign-proc-safe "waitpid" '(int void* int) 'int))
(define proc-kill    (jolt-foreign-proc-safe "kill"    '(int int)       'int))
;; libc signal(2). Named apart from the proc-signal recorder further down — this
;; file is load-ed at top level, so a second define of the same name silently wins
;; and the SIGCHLD restore below would reach the recorder instead.
(define proc-libc-signal (jolt-foreign-proc-safe "signal" '(int void*) 'void*))
;; errno, to tell a waitpid that was merely interrupted (EINTR — retry) from one
;; that can never succeed (ECHILD — the child is gone, retrying is an infinite
;; loop). Both spellings of the location accessor: Darwin/BSD, then glibc/musl.
(define proc-errno-loc
  (or (jolt-foreign-proc-safe "__error" '() 'void*)
      (jolt-foreign-proc-safe "__errno_location" '() 'void*)))
(define (proc-errno)
  (if proc-errno-loc (guard (e (#t 0)) (sa-foreign-ref 'int (proc-errno-loc) 0)) 0))

(define proc-WNOHANG 1)        ; macOS + Linux
(define proc-SIGTERM 15)
(define proc-SIGKILL 9)
(define proc-EINTR 4)          ; macOS + Linux
(define proc-ECHILD 10)        ; macOS + Linux
;; SIGCHLD is 20 on Darwin/BSD and 17 on Linux. Same os-family test as
;; concurrency.ss uses for the SIG_BLOCK numerics.
(define proc-SIGCHLD (if (eq? (sa-os-family) 'macos) 20 17))

;; EAGAIN/EWOULDBLOCK, for the R8-style non-blocking pipe read/write retry
;; loop (proc-fd-input-port / proc-fd-output-port below). Genuinely
;; platform-dependent, unlike proc-EINTR -- same os-family test process.ss
;; already uses for proc-SIGCHLD.
(define proc-EAGAIN (if (eq? (sa-os-family) 'macos) 35 11))

;; fcntl(F_GETFL)/(F_SETFL) for setting a pipe fd non-blocking, mirroring
;; stdlib/jolt/io_poller.clj's own private c-fcntl binding
;; (io_poller.clj:59-63,70) at the Scheme level. fcntl(2) is C-variadic;
;; F_GETFL is called with NO variadic argument (plain 2-arg binding is
;; correct). F_SETFL is ALWAYS called with one variadic argument (the new
;; flags value) and REQUIRES the (__varargs_after 2) calling-convention
;; token -- "2" is the count of fixed/named params before the first true
;; variadic arg. Without this marker, F_SETFL on Apple arm64 returns
;; success but silently fails to apply the flags (verified by
;; test/chez/ffi-binding-test.ss:82-104, which proves the identical fix
;; via the Clojure FFI :varargs marker on a real socket with F_SETFL
;; before/after flags readback). Mirrors stdlib/jolt/ffi.clj's own
;; :varargs marker (io_poller.clj's `(ffi/defcfn c-fcntl "fcntl"
;; [:int :int :varargs :int] :int)`), exposed here as the raw Scheme-level
;; jolt-foreign-proc-safe 4-arg form (rt.ss:73-88) -- a Chez/Apple-ABI
;; feature, not a jolt invention.
(define proc-fcntl-get (jolt-foreign-proc-safe "fcntl" '(int int) 'int))
(define proc-fcntl-set (jolt-foreign-proc-safe (__varargs_after 2) "fcntl" '(int int int) 'int))
(define proc-F-GETFL 3)
(define proc-F-SETFL 4)
(define proc-O-NONBLOCK (if (eq? (sa-os-family) 'macos) #x4 #x800))

;; Nothing here happens without a working fcntl and a readable errno: a pipe
;; set non-blocking whose EAGAIN cannot be recognised reads as EOF instead
;; (the (else 0) branch in proc-fd-input-port), which is worse than a blocking
;; pipe. So the whole R8 extension is gated on the three bindings, and the
;; degradation when one is missing is "no parking" — the pipes stay blocking
;; and EAGAIN never arrives. Deliberately NOT folded into
;; proc-spawn-fd-ok?: that gate decides posix_spawn vs Chez's fork, and the
;; fork path leaves SIGINT at SIG_IGN in the child (see the comment above
;; proc-spawn-fd-mutex). Correct child signal dispositions are not worth
;; trading for O_NONBLOCK.
(define proc-nonblock-ok? (and proc-fcntl-get proc-fcntl-set proc-errno-loc #t))

(define (proc-set-nonblocking! fd)
  (when proc-nonblock-ok?
    (let ((flags (proc-fcntl-get fd proc-F-GETFL)))
      ;; A negative flags value means F_GETFL itself failed -- don't hand that
      ;; straight to F_SETFL: (fxior -1 proc-O-NONBLOCK) is still negative, and
      ;; the kernel would mask it down, silently leaving the fd blocking with
      ;; no diagnostic that anything went wrong.
      (when (>= flags 0)
        (proc-fcntl-set fd proc-F-SETFL (fxior flags proc-O-NONBLOCK))))))

;; jolt.socket is the only thing in the tree that requires jolt.io-poller, so a
;; program that drives subprocesses from fibers without ever touching a socket
;; — a build-tool wrapper, a shell pipeline — would find wait-ready unbound and
;; take the blocking fallback below, pinning its carrier: exactly the starvation
;; this whole file's R8 extension exists to remove. Autoload the poller instead,
;; at the one moment it is known to be needed, and only when there IS a fiber to
;; park: a plain thread keeps the cheaper blocking read rather than paying a
;; private kqueue/epoll per wait.
;;
;; Safe from inside a port read even though a load can park and can race another
;; thread's: loader.ss's claim protocol owns both cases (ldr-begin-load! steps
;; 2-3), and leaning on it rather than on a latch of our own is what makes the
;; CONCURRENT case come out right. Two fibers on two carriers reach their first
;; EAGAIN at once routinely -- it is the ordinary shape of "read several
;; subprocesses from go blocks", the thing this whole extension is for. A
;; boolean "already tried" latch set before the load would let the second fiber
;; skip straight past it, find the var still unbound because the first is only
;; part way through, and take the blocking fallback -- clearing O_NONBLOCK on
;; its own fd for good, so that one port never parks again for the life of the
;; process. Calling load-namespace instead makes the second fiber WAIT on the
;; first's claim (fiber-aware, via jolt-lock-parked, so it parks rather than
;; pinning), then find a fully built namespace. Already-loaded is a hashtable
;; lookup, and we only get here when the var is unbound anyway.
;;
;; The one thing the loader cannot decide for us is a load that FAILS
;; (jolt.io-poller off the source roots in a trimmed install): the loader rolls
;; its own mark back on a throw, deliberately, so a retry can work. Nothing
;; about the next EAGAIN will have changed, though, so record the failure here
;; and stop asking.
(define proc-poller-load-failed #f)
(define (proc-poller-autoload!)
  (unless proc-poller-load-failed
    (guard (e (#t (set! proc-poller-load-failed #t) #f))
      (load-namespace "jolt.io-poller"))))

;; Bridge to jolt.io-poller/wait-ready: var-deref never throws for a
;; missing var -- jolt-var auto-vivifies a jolt-var-unbound placeholder
;; instead (rt.ss:662-669), checkable via the record type's own
;; predicate. Off a fiber an unbound var stays unbound (see
;; proc-poller-autoload! above for why the load is fiber-only) and this
;; returns #f, so the caller falls back to a real blocking wait it
;; implements itself (the EAGAIN branches in
;; proc-fd-input-port/proc-fd-output-port below -- a bare 0-byte return
;; there would misread as EOF, since the pipe fd is genuinely
;; non-blocking by then). On a fiber the same #f is only reachable when
;; the autoload itself failed.
(define (proc-poller-wait-ready fd filt-kw)
  (let* ((f0 (var-deref "jolt.io-poller" "wait-ready"))
         (f (if (and (jolt-var-unbound? f0) (jolt-current-fiber))
                (begin (proc-poller-autoload!)
                       (var-deref "jolt.io-poller" "wait-ready"))
                f0)))
    (if (jolt-var-unbound? f)
        #f
        (begin (jolt-invoke2 f fd filt-kw) #t))))

;; Bridge to jolt.io-poller/forget!, same shape as proc-poller-wait-ready above.
;; A closed fd is auto-removed from the kernel's kqueue/epoll set, so no
;; event is ever coming for a fiber still parked on it -- without telling
;; the poller to drop its registration, that fiber sleeps forever, and a
;; leaked ready=true tombstone in the poller's shared :fds table (keyed by
;; bare fd integer, shared with jolt.socket) can then be consumed by a
;; REUSED fd number belonging to an unrelated later socket. Mirrors
;; jolt.socket's socket-close! (stdlib/jolt/socket.clj), which does the
;; identical close-then-forget for the same reason. Same unbound-var guard
;; as proc-poller-wait-ready, and no autoload: a poller that was never loaded
;; holds no registration for this fd, so there is nothing to forget.
(define (proc-poller-forget! fd)
  (let ((f (var-deref "jolt.io-poller" "forget!")))
    (unless (jolt-var-unbound? f) (jolt-invoke1 f fd))))

;; A jolt that spawns children has to be able to reap them, so SIGCHLD must not be
;; left at an INHERITED SIG_IGN: with that disposition the kernel reaps every child
;; itself and waitpid can only ever fail with ECHILD, making exit statuses
;; unknowable. The disposition does survive exec, so jolt can arrive with it set
;; through no choice of its own — a CI runner, a supervisor, any parent that
;; ignored SIGCHLD. Restore SIG_DFL once, before the first spawn, as a JVM does
;; when it installs its own child handling.
;;
;; On the first spawn rather than at load: a jolt that never starts a process has
;; no business touching the process's signal dispositions. Only SIG_IGN is
;; replaced — an inherited real HANDLER is left alone, since something in the
;; process legitimately wants those notifications.
(define proc-sigchld-checked? (box #f))
(define (proc-ensure-reapable!)
  (unless (unbox proc-sigchld-checked?)
    (set-box! proc-sigchld-checked? #t)
    (when proc-libc-signal
      (guard (e (#t #f))
        (let ((prev (proc-libc-signal proc-SIGCHLD 0)))   ; install SIG_DFL, get the old one
          ;; SIG_IGN is 1; anything else (SIG_DFL = 0, or a handler address) is put
          ;; back. SIG_ERR is -1 and means the call did not take, so leave it alone.
          (unless (or (eqv? prev 1) (eqv? prev -1))
            (proc-libc-signal proc-SIGCHLD prev)))))))

;; WEXITSTATUS / signalled-process convention: a process killed by signal N
;; reports 128+N, matching the JVM's Process.exitValue on Unix.
(define (proc-decode-status raw)
  (let ((termsig (bitwise-and raw #x7f)))
    (if (= termsig 0)
        (bitwise-and (bitwise-arithmetic-shift-right raw 8) #xff)
        (+ 128 termsig))))

;; One waitpid call; returns (values rc decoded-or-#f errno). rc = pid on reap, 0
;; when WNOHANG and still running, -1 on error (errno says which).
(define (proc-waitpid-once pid nohang?)
  (if (not proc-waitpid)
      (values -1 #f proc-ECHILD)
      (let ((buf (sa-foreign-alloc 4)))
        (let* ((rc (proc-waitpid pid buf (if nohang? proc-WNOHANG 0)))
               (err (if (< rc 0) (proc-errno) 0))
               (raw (sa-foreign-ref 'int buf 0)))
          (sa-foreign-free buf)
          (values rc (and (= rc pid) (proc-decode-status raw)) err)))))

;; The status to report for a child that can no longer be waited on (ECHILD:
;; something else reaped it). If we signalled it, Unix convention gives the answer
;; — 128+signal, the same encoding proc-decode-status uses. Otherwise the status is
;; genuinely unrecoverable and 0 is reported, a documented divergence from the JVM
;; (which always reaps its own children and so always knows). proc-ensure-reapable!
;; is what keeps this from arising in the first place.
(define (proc-lost-status st)
  (or (unbox (proc-p-signalled st)) 0))

;; --- shell command construction ----------------------------------------------
(define (proc-sh-quote s)      ; single-quote a token for /bin/sh
  (let ((s (if (string? s) s (jolt-str-render-one s))))
    (string-append "'"
      (apply string-append
        (map (lambda (c) (if (char=? c #\') "'\\''" (string c))) (string->list s)))
      "'")))

(define (proc-join sep xs)
  (if (null? xs) ""
      (fold-left (lambda (a x) (string-append a sep x)) (car xs) (cdr xs))))

;; A redirect descriptor is a Redirect jhost (kind + optional file) or #f (the
;; default: pipe). Returns the shell redirection fragment for fd `n` ("1"/"2"/"0"),
;; or "" when the pipe is kept (PIPE / INHERIT / a stream target — those are
;; handled by pump threads after start).
(define (proc-redir-fragment n redir)
  (if (not (proc-redirect? redir)) ""
      (let ((kind (proc-redirect-kind redir))
            (file (proc-redirect-file redir)))
        (case kind
          ((write)   (string-append " " n "> "  (proc-sh-quote file)))
          ((append)  (string-append " " n ">> " (proc-sh-quote file)))
          ((read)    (string-append " " n "< "  (proc-sh-quote file)))
          ((discard) (string-append " " n ">/dev/null"))
          (else "")))))                 ; inherit / pipe -> pump or passthrough

(define (proc-env-prefix env-map)
  (if (not env-map) ""
      (let ((pairs (proc-env-map-pairs env-map)))
        (string-append "env -i "
          (proc-join " "
            (map (lambda (p) (proc-sh-quote (string-append (car p) "=" (cdr p)))) pairs))
          " "))))

;; The child's cwd: a JVM child inherits user.dir (the user's cwd), but jolt's OS
;; cwd is the repo root its launcher cd'd to — the user's logical cwd is JOLT_PWD.
;; So default the child to JOLT_PWD and resolve a relative :dir against it (like
;; io.ss project-relative), matching ProcessBuilder.directory semantics.
(define (proc-effective-dir dir)
  (if dir
      (project-relative dir)
      (let ((pwd (getenv "JOLT_PWD"))) (and pwd (> (string-length pwd) 0) pwd))))

(define (proc-build-shell-command st)
  (let* ((cmd     (proc-pb-cmd st))
         (env-map (proc-pb-env st))
         (dir     (proc-effective-dir (proc-pb-dir st)))
         (rin     (proc-pb-redir-in st))
         (rout    (proc-pb-redir-out st))
         (rerr    (proc-pb-redir-err st))
         (merge?  (proc-pb-merge-err? st)))
    (string-append
      (if dir (string-append "cd " (proc-sh-quote dir) " && ") "")
      "exec "
      (proc-env-prefix env-map)
      (proc-join " " (map proc-sh-quote cmd))
      (proc-redir-fragment "0" rin)
      (proc-redir-fragment "1" rout)
      (if merge? " 2>&1" (proc-redir-fragment "2" rerr)))))

;; --- java.lang.ProcessBuilder$Redirect ---------------------------------------
;; state: #(kind file) — kind in {inherit discard pipe write append read}.
(define (make-proc-redirect kind file) (make-jhost "process-redirect" (vector kind file)))
(define (proc-redirect? x) (and (jhost? x) (string=? (jhost-tag x) "process-redirect")))
(define (proc-redirect-kind r) (vector-ref (jhost-state r) 0))
(define (proc-redirect-file r) (vector-ref (jhost-state r) 1))

;; Named so inheritIO() can hand back the SAME object Redirect/INHERIT is. On the
;; JVM these are singletons — (= (.redirectInput pb) Redirect/INHERIT) is true
;; after .inheritIO() — and a fresh instance per call would read as a different
;; redirect to anything comparing them.
(define proc-redirect-inherit (make-proc-redirect 'inherit #f))
(define proc-redirect-pipe (make-proc-redirect 'pipe #f))

(define proc-redirect-statics
  (list (cons "INHERIT" proc-redirect-inherit)
        (cons "DISCARD" (make-proc-redirect 'discard #f))
        (cons "PIPE"    proc-redirect-pipe)
        (cons "to"       (lambda (f) (make-proc-redirect 'write  (file-path-of f))))
        (cons "appendTo" (lambda (f) (make-proc-redirect 'append (file-path-of f))))
        (cons "from"     (lambda (f) (make-proc-redirect 'read   (file-path-of f))))))
;; register-class-statics! mirrors the FQN table to the short name, so a single
;; call serves both java.lang.ProcessBuilder$Redirect/… and ProcessBuilder$Redirect/….
(register-class-statics! "java.lang.ProcessBuilder$Redirect" proc-redirect-statics)
(register-host-methods! "process-redirect"
  (list (cons "type" (lambda (self) (symbol->string (proc-redirect-kind self))))
        (cons "toString" (lambda (self) (string-append "Redirect." (symbol->string (proc-redirect-kind self)))))))

;; --- environment map (ProcessBuilder.environment()) --------------------------
;; A live mutable Map<String,String>, seeded from the parent environment. jolt's
;; babashka.process only calls clear/putAll, but put/get/remove are provided too.
;; state: a Scheme string->string hashtable.
(define (make-proc-env-map)
  (let ((h (make-hashtable string-hash string=?)))
    (for-each (lambda (p) (hashtable-set! h (car p) (cdr p))) (all-env-pairs))
    (make-jhost "jolt-env-map" h)))
(define (proc-env-map? x) (and (jhost? x) (string=? (jhost-tag x) "jolt-env-map")))
(define (proc-env-map-pairs em)
  (let ((h (jhost-state em)))
    (vector->list
      (vector-map (lambda (k) (cons k (hashtable-ref h k ""))) (hashtable-keys h)))))
(define (proc-env-put-all! em m)
  (let ((h (jhost-state em)))
    (unless (jolt-nil? m)
      (for-each (lambda (e)
                  (hashtable-set! h (jolt-str-render-one (jolt-nth e 0))
                                    (jolt-str-render-one (jolt-nth e 1))))
                (seq->list (jolt-seq m))))))
(register-host-methods! "jolt-env-map"
  (list (cons "clear"  (lambda (self) (hashtable-clear! (jhost-state self)) jolt-nil))
        (cons "putAll" (lambda (self m) (proc-env-put-all! self m) jolt-nil))
        (cons "put"    (lambda (self k v)
                         (hashtable-set! (jhost-state self) (jolt-str-render-one k) (jolt-str-render-one v)) jolt-nil))
        (cons "get"    (lambda (self k)
                         (let ((v (hashtable-ref (jhost-state self) (jolt-str-render-one k) #f))) (or v jolt-nil))))
        (cons "remove" (lambda (self k) (hashtable-delete! (jhost-state self) (jolt-str-render-one k)) jolt-nil))
        (cons "containsKey" (lambda (self k) (and (hashtable-contains? (jhost-state self) (jolt-str-render-one k)) #t)))))

;; --- java.lang.ProcessBuilder ------------------------------------------------
;; state: #(cmd env-map dir redir-in redir-out redir-err merge-err?)
(define (make-proc-builder cmd)
  (make-jhost "process-builder" (vector cmd #f #f #f #f #f #f)))
(define (proc-builder? x) (and (jhost? x) (string=? (jhost-tag x) "process-builder")))
(define (proc-pb-cmd st)         (vector-ref (jhost-state st) 0))
(define (proc-pb-env st)         (vector-ref (jhost-state st) 1))
(define (proc-pb-dir st)         (vector-ref (jhost-state st) 2))
(define (proc-pb-redir-in st)    (vector-ref (jhost-state st) 3))
(define (proc-pb-redir-out st)   (vector-ref (jhost-state st) 4))
(define (proc-pb-redir-err st)   (vector-ref (jhost-state st) 5))
(define (proc-pb-merge-err? st)  (vector-ref (jhost-state st) 6))
(define (proc-pb-set! st i v)    (vector-set! (jhost-state st) i v))

;; the ProcessBuilder ctor: (java.lang.ProcessBuilder. cmd) where cmd is a jolt
;; vector/list of strings (or its varargs form).
(define (proc-builder-ctor . args)
  (let ((cmd (cond ((null? args) '())
                   ((and (null? (cdr args)) (not (string? (car args))) (not (jolt-nil? (car args))))
                    ;; a single collection argument -> its elements
                    (map jolt-str-render-one (seq->list (jolt-seq (car args)))))
                   (else (map jolt-str-render-one args)))))
    (make-proc-builder cmd)))
(register-class-ctor! "java.lang.ProcessBuilder" proc-builder-ctor)
(register-class-ctor! "ProcessBuilder" proc-builder-ctor)

(register-host-methods! "process-builder"
  (list (cons "command" (lambda (self . args)
          (if (null? args)
              (apply jolt-vector (proc-pb-cmd self))               ; getter
              (begin (proc-pb-set! self 0 (map jolt-str-render-one (seq->list (jolt-seq (car args))))) self))))
        (cons "directory" (lambda (self f) (proc-pb-set! self 2 (file-path-of f)) self))
        (cons "environment" (lambda (self)
          (or (proc-pb-env self)
              (let ((em (make-proc-env-map))) (proc-pb-set! self 1 em) em))))
        ;; Each redirect method is a setter with an argument and a GETTER with
        ;; none, like the JDK's. An unset stream reads back as PIPE, which is the
        ;; documented default rather than nil.
        (cons "redirectInput"  (lambda (self . r)
          (if (null? r) (or (proc-pb-redir-in self) proc-redirect-pipe)
              (begin (proc-pb-set! self 3 (car r)) self))))
        (cons "redirectOutput" (lambda (self . r)
          (if (null? r) (or (proc-pb-redir-out self) proc-redirect-pipe)
              (begin (proc-pb-set! self 4 (car r)) self))))
        (cons "redirectError"  (lambda (self . r)
          (if (null? r) (or (proc-pb-redir-err self) proc-redirect-pipe)
              (begin (proc-pb-set! self 5 (car r)) self))))
        (cons "redirectErrorStream" (lambda (self . b)
          (if (null? b) (and (proc-pb-merge-err? self) #t)
              (begin (proc-pb-set! self 6 (jolt-truthy? (car b))) self))))
        ;; inheritIO(): set all three standard streams to INHERIT and return this
        ;; — the JDK defines it as exactly redirectInput(INHERIT)
        ;; .redirectOutput(INHERIT).redirectError(INHERIT), and the start path
        ;; already understands the 'inherit kind. Without it a caller had to spell
        ;; those three out, and the miss reported as "No matching field found:
        ;; inheritIO" because jolt reads a 0-arg method miss as a field probe
        ;; (jolt-674). It does NOT clear redirectErrorStream: on the JVM the two
        ;; are independent, and a merge set before or after still wins over the
        ;; error redirect.
        (cons "inheritIO" (lambda (self)
                            (proc-pb-set! self 3 proc-redirect-inherit)
                            (proc-pb-set! self 4 proc-redirect-inherit)
                            (proc-pb-set! self 5 proc-redirect-inherit)
                            self))
        (cons "start" (lambda (self) (proc-pb-start self)))))

;; startPipeline: connect N builders stdout->stdin with pump threads, returning a
;; jolt list of the resulting Processes (JDK9 semantics).
(define (proc-start-pipeline pbs)
  (let* ((pb-list (seq->list (jolt-seq pbs)))
         (procs   (map proc-pb-start pb-list)))
    (let loop ((ps procs))
      (when (and (pair? ps) (pair? (cdr ps)))
        (proc-pump (proc-p-stdout-port (car ps)) (proc-p-stdin-port (cadr ps)) #t)
        (loop (cdr ps))))
    (list->cseq procs)))
(register-class-statics! "java.lang.ProcessBuilder" (list (cons "startPipeline" proc-start-pipeline)))

;; --- pump threads ------------------------------------------------------------
;; Copy a binary input port to a binary output port until EOF; optionally close
;; the destination at EOF (so a downstream process sees end-of-input). Returns a
;; latch (mutex + condition + done box, like Thread.join in concurrency.ss) so a
;; caller can block until the copy is complete — an INHERIT redirect must have
;; forwarded all output before the process is reported finished.
;; Copy one chunk-worth from src to dst, handling either port being binary or
;; textual: a child pipe is binary (bytes), while jolt's own stdio (INHERIT's
;; target) is textual, so bytes are transcoded UTF-8 across the boundary. Returns
;; #f at EOF, #t otherwise.
(define (proc-copy-chunk src dst)
  (if (binary-port? src)
      (let ((bv (get-bytevector-some src)))
        (and (not (eof-object? bv))
             (begin (if (textual-port? dst) (put-string dst (utf8->string bv)) (put-bytevector dst bv))
                    (flush-output-port dst) #t)))
      (let ((s (get-string-some src)))
        (and (not (eof-object? s))
             (begin (if (binary-port? dst) (put-bytevector dst (string->utf8 s)) (put-string dst s))
                    (flush-output-port dst) #t)))))
(define (proc-pump src dst close-dst?)
  (let ((m (make-mutex)) (c (make-condition)) (done (box #f)))
    (fork-thread
      (lambda ()
        (guard (e (#t #f))
          (let loop () (when (proc-copy-chunk src dst) (loop))))
        (when close-dst? (guard (e (#t #f)) (close-port dst)))
        (jolt-with-mutex m (set-box! done #t) (jolt-cv-wake! c))))
    (vector m c done)))
;; A fiber waiting for a subprocess's output collector PARKS. Blocking the carrier
;; would stop every other fiber on it for the life of the subprocess, which is
;; exactly the kind of wait a go block is the natural place for (jolt-x1no).
(define (proc-latch-wait latch)
  (jolt-cv-wait (vector-ref latch 0) (vector-ref latch 1) #f
    (lambda (_timed-out?)
      (if (unbox (vector-ref latch 2)) #t jolt-cv-again))))

;; --- fd-level spawn (the primary path) ---------------------------------------
;; A child fd that gets no file action IS the parent's descriptor — tty answers
;; true, writes land without an intermediary, successive INHERIT-stdin children
;; share the read offset — and pipes are built for the streams that ask for one.
;; open-process-ports can do none of that: it pipes all three streams
;; unconditionally (its child closes every other descriptor), so INHERIT through
;; it can only ever be pump emulation, where the child sees a pipe, isatty is
;; false, output detours through jolt's ports, and stdin reads ahead of what the
;; child consumed. It also leaves SIGINT ignored in its child. So this is the
;; path every spawn takes where the FFI surface exists, and the pump emulation
;; below is what remains where it does not (Windows machine types). Everything
;; downstream — waitpid reaping, kill, the stream wrappers — is shared.

(define proc-c-pipe  (jolt-foreign-proc-safe "pipe"  '(void*) 'int))
(define proc-c-close (jolt-foreign-proc-safe "close" '(int)   'int))
(define proc-fa-init    (jolt-foreign-proc-safe "posix_spawn_file_actions_init"     '(void*) 'int))
(define proc-fa-dup2    (jolt-foreign-proc-safe "posix_spawn_file_actions_adddup2"  '(void* int int) 'int))
(define proc-fa-close   (jolt-foreign-proc-safe "posix_spawn_file_actions_addclose" '(void* int) 'int))
(define proc-fa-destroy (jolt-foreign-proc-safe "posix_spawn_file_actions_destroy"  '(void*) 'int))
(define proc-c-spawn (jolt-foreign-proc-safe "posix_spawn" '(void* string void* void* void* void*) 'int))
(define proc-c-read  (jolt-foreign-proc-blocking "read"  '(int void* size_t) 'ssize_t))
(define proc-c-write (jolt-foreign-proc-blocking "write" '(int void* size_t) 'ssize_t))

;; What posix_spawn-with-pipes needs, and nothing more. The R8 fiber-parking
;; extension's own bindings (fcntl, errno) are gated separately by
;; proc-nonblock-ok? above: losing parking is a performance story, losing this
;; path means falling back to Chez's fork with SIGINT ignored in the child.
(define proc-spawn-fd-ok?
  (and proc-c-pipe proc-c-close proc-fa-init proc-fa-dup2 proc-fa-close
       proc-fa-destroy proc-c-spawn proc-c-read proc-c-write #t))

;; marshal a string list into a NULL-terminated char**; returns (array . cstrs)
;; so the caller can free every allocation once posix_spawn has copied them.
(define (proc-marshal-cstr s)
  (let* ((bv (string->utf8 s))
         (n (bytevector-length bv))
         (p (sa-foreign-alloc (+ n 1))))
    (let loop ((i 0))
      (when (< i n)
        (sa-foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i))
        (loop (+ i 1))))
    (sa-foreign-set! 'unsigned-8 p n 0)
    p))
(define (proc-marshal-argv strs)
  (let* ((ps (map proc-marshal-cstr strs))
         (arr (sa-foreign-alloc (* 8 (+ 1 (length ps))))))
    (let loop ((i 0) (rest ps))
      (if (null? rest)
          (sa-foreign-set! 'void* arr (* 8 i) 0)
          (begin (sa-foreign-set! 'void* arr (* 8 i) (car rest))
                 (loop (+ i 1) (cdr rest)))))
    (cons arr ps)))
(define (proc-free-argv m)
  (for-each sa-foreign-free (cdr m))
  (sa-foreign-free (car m)))

;; binary ports over the raw pipe fds. EINTR is retried; EAGAIN parks the
;; current fiber (or blocks this thread) via jolt.io-poller when it's loaded
;; -- symmetric on both sides below: proc-fd-input-port waits on :read,
;; proc-fd-output-port waits on :write, over the same mk-pipe-created
;; non-blocking fd and the same proc-poller-wait-ready bridge. When no poller is
;; loaded, EAGAIN clears O_NONBLOCK on this fd (fd is genuinely non-blocking
;; now per mk-pipe above, so a no-poller EAGAIN is a live "not ready yet"
;; signal, not a real failure) and falls through to a real blocking
;; proc-c-read/proc-c-write from then on -- exact behavioral parity with a
;; plain blocking fd once triggered, verified standalone: a blocked
;; read/write genuinely waits rather than busy-looping or returning a
;; spurious result. Any OTHER error still ends the port, but the two sides
;; report it differently -- pre-existing asymmetry, unchanged by this: the
;; read side reads it as EOF (0, the child is gone and the pipe with it);
;; the write side raises (child gone, `error 'process "write to child
;; failed"`). A short write returns its count and Chez's port machinery
;; re-calls for the rest.
;;
;; The `closed?` box each port allocates alongside its buf is what makes the
;; close proc safe against a fiber PARKED in that retry loop. Close is three
;; steps -- free buf, close fd, forget the fd -- and the third wakes any parked
;; waiter through jolt.io-poller. That wake is ASYNCHRONOUS: jolt.host's
;; fiber-resume -> sa-fiber-resume (host/chez/fibers.ss) only flips the fiber to
;; 'ready and enqueues it on its carrier's run queue; the fiber's continuation
;; runs later, on the carrier thread. Between the wake and that continuation
;; there is a real scheduling gap, and by then buf is already free()d
;; (sa-foreign-free is a bare foreign-free -- no pooling, no quarantine) and fd
;; is already closed. A closed fd number is immediately eligible for reuse by
;; ANY concurrent pipe/socket/open/accept anywhere in the process -- POSIX hands
;; out the lowest free number, and jolt.process exists to support many
;; concurrent spawns -- so without the flag the woken fiber's (retry) calls
;; proc-c-read/proc-c-write with a fd that is valid again but belongs to
;; something else entirely, handing the kernel a pointer into freed memory. That
;; stale retry could also re-register the reused fd with jolt.io-poller,
;; cross-talking with its new owner's registration. proc-spawn-fd-mutex does not
;; help: it covers only the pipe()-through-posix_spawn sequence, not close and
;; not fd allocation in general.
;;
;; So the close proc sets closed? FIRST, before it frees, closes, or forgets,
;; and the retry loop tests it at the TOP of EVERY iteration -- the first one
;; included, not just the one after a park. The ordering is what makes that test
;; sound rather than hopeful: set-box! happens before proc-poller-forget!, which
;; reaches sa-fiber-resume, which takes and releases the carrier's mutex to
;; enqueue the fiber; the carrier thread takes that SAME mutex in
;; jolt-fiber-dequeue! before it can run the fiber at all. A release/acquire
;; pair on one mutex, so the #t is published to the woken fiber -- it cannot
;; observe a stale #f, and it cannot have cached the read across the park, since
;; the park sits behind proc-poller-wait-ready's opaque var-deref'd call. Same
;; box/set-box!/unbox shape concurrency.ss uses for its own cross-thread flag
;; (agents-shutdown?).
;;
;; Each side short-circuits the way it already reports a dead pipe: the read
;; side returns 0 (the `(else 0)` EOF convention below), the write side raises
;; (the `error 'process` convention below) -- with its own message, so a port
;; closed under a parked write is not misreported as a failing child.
;;
;; Deliberately NOT covered: a close racing a syscall already IN FLIGHT on
;; another thread rather than parked. That caller read fd and buf before any
;; flag could be set, so no flag can help it; it is a pre-existing hazard of
;; closing a port other threads are actively using, not something this adds.
;;
;; Also NOT covered: a fiber that has decided to call proc-poller-wait-ready but
;; has not yet registered when close runs -- forget! finds nothing to drop,
;; then the fiber registers on an already-dead fd. That is a strand (a hang),
;; not a use-after-free; closing it needs coordination on the jolt.io-poller
;; side (a register/forget race), left out of scope here. Pre-existing,
;; not introduced by this fix.
(define proc-fd-buf-size 32768)
(define (proc-fd-input-port fd)
  (let ((buf (sa-foreign-alloc proc-fd-buf-size))
        (closed? (box #f)))
    (make-custom-binary-input-port
      (string-append "process-fd-" (number->string fd))
      (lambda (bv start n)
        (let ((want (min n proc-fd-buf-size)))
          (let retry ()
            ;; Top of EVERY iteration, first one included: a fiber woken by the
            ;; close proc's proc-poller-forget! resumes HERE, and buf is freed and fd
            ;; closed (possibly reused) by then. Read as EOF without touching
            ;; either -- same answer the (else 0) branch below would give for a
            ;; closed fd's EBADF, reached without the syscall.
            (if (unbox closed?)
                0
                (let ((got (proc-c-read fd buf want)))
                  (cond
                    ((> got 0)
                     (let loop ((i 0))
                       (when (< i got)
                         (bytevector-u8-set! bv (+ start i) (sa-foreign-ref 'unsigned-8 buf i))
                         (loop (+ i 1))))
                     got)
                    ((= got 0) 0)
                    ((= (proc-errno) proc-EINTR) (retry))
                    ((= (proc-errno) proc-EAGAIN)
                     (if (proc-poller-wait-ready fd (jolt-keyword "read"))
                         (retry)
                         (begin
                           (let ((flags (proc-fcntl-get fd proc-F-GETFL)))
                             (proc-fcntl-set fd proc-F-SETFL (fxand flags (fxnot proc-O-NONBLOCK))))
                           (retry))))
                    (else 0)))))))
      #f #f
      ;; closed? goes up BEFORE the free/close/forget below, so it is already #t
      ;; on the far side of the carrier-mutex handoff every woken fiber crosses.
      (lambda ()
        (set-box! closed? #t)
        (sa-foreign-free buf) (proc-c-close fd) (proc-poller-forget! fd)))))
(define (proc-fd-output-port fd)
  (let ((buf (sa-foreign-alloc proc-fd-buf-size))
        (closed? (box #f)))
    (make-custom-binary-output-port
      (string-append "process-fd-" (number->string fd))
      (lambda (bv start n)
        (let ((want (min n proc-fd-buf-size)))
          (let loop ((i 0))
            (when (< i want)
              (sa-foreign-set! 'unsigned-8 buf i (bytevector-u8-ref bv (+ start i)))
              (loop (+ i 1))))
          (let retry ()
            ;; Top of EVERY iteration, first one included -- the read side's
            ;; twin, and the branch a fiber woken by the close proc lands on.
            ;; Raises rather than returning a count, matching the (else ...)
            ;; convention below; its own message because the child is fine here,
            ;; the port under this write is not.
            (if (unbox closed?)
                (error 'process "write to closed pipe" fd)
                (let ((wrote (proc-c-write fd buf want)))
                  (cond
                    ((>= wrote 0) wrote)
                    ((= (proc-errno) proc-EINTR) (retry))
                    ((= (proc-errno) proc-EAGAIN)
                     (if (proc-poller-wait-ready fd (jolt-keyword "write"))
                         (retry)
                         (begin
                           (let ((flags (proc-fcntl-get fd proc-F-GETFL)))
                             (proc-fcntl-set fd proc-F-SETFL (fxand flags (fxnot proc-O-NONBLOCK))))
                           (retry))))
                    (else (error 'process "write to child failed" fd))))))))
      #f #f
      ;; closed? goes up BEFORE the free/close/forget below, so it is already #t
      ;; on the far side of the carrier-mutex handoff every woken fiber crosses.
      (lambda ()
        (set-box! closed? #t)
        (sa-foreign-free buf) (proc-c-close fd) (proc-poller-forget! fd)))))

;; What the API hands back for a stream that was INHERITED: the JVM's null
;; streams. Reads are at EOF from the start; writes are accepted and dropped.
(define (proc-null-input-port)
  (open-bytevector-input-port (make-bytevector 0)))
(define (proc-null-output-port)
  (make-custom-binary-output-port "process-null" (lambda (bv start n) n) #f #f #f))

;; The pipe fds are not close-on-exec: macOS has no pipe2()/O_CLOEXEC (unlike
;; Linux), so FD_CLOEXEC can only be applied with a SEPARATE fcntl(F_SETFD)
;; call after pipe() returns -- and that leaves a window, between pipe() and
;; that fcntl call, where a concurrent spawn's child could still inherit the
;; fd and hold a read end open past this child's exit. This is true even now
;; that this file has a working arm64 fcntl binding (proc-fcntl-get/-set
;; above, via the (__varargs_after 2) marker): a working fcntl fixes whether
;; we CAN make the F_SETFD call safely, not the fact that pipe() and
;; F_SETFD are still two separate syscalls with a gap between them. Exclusion
;; by mutex instead: no other fd-level spawn runs between pipe() and
;; posix_spawn.
(define proc-spawn-fd-mutex (make-mutex))

;; Spawn `/bin/sh -c sh-cmd` with fd-level stdio: an inherited stream gets no
;; file action (the child keeps the parent's descriptor); the rest get pipes.
;; Returns (values stdin-port stdout-port stderr-port pid), #f for inherited
;; ends. attrp is NULL: signal mask and dispositions are inherited, matching
;; the pipe path — so the mask is corrected on this side, around the spawn
;; itself (see the call below).
(define (proc-spawn-fd-level sh-cmd inherit-in? inherit-out? inherit-err?)
  ;; nonblocking-read? / nonblocking-write? -- set O_NONBLOCK unconditionally
  ;; on the PARENT's own RETAINED end at creation (never poller-gated), so
  ;; the retry loops below
  ;; (proc-fd-input-port / proc-fd-output-port) can park a fiber on EAGAIN
  ;; instead of pinning the carrier. Which end is "the parent's own" is
  ;; per-role and asymmetric: for out-p/err-p the parent keeps the read end
  ;; (car) and the child gets the write end (cdr) via dup2, so only
  ;; nonblocking-read? applies; in-p is the mirror image -- the CHILD gets
  ;; the read end (dup2'd to its own stdin) and the PARENT keeps the write
  ;; end (cdr, feeding proc-fd-output-port), so only nonblocking-write?
  ;; applies. Per POSIX, dup2/dup/fork-duplicated descriptors share file
  ;; status flags -- including O_NONBLOCK -- via the shared open file
  ;; description; only per-descriptor flags like FD_CLOEXEC are NOT shared
  ;; (verified standalone: a dup()'d fd inherits O_NONBLOCK from the fd it
  ;; was dup'd from). So flipping O_NONBLOCK on the end that gets dup2'd into
  ;; the child would silently change the CHILD's own stdio behavior, not just
  ;; the parent's -- a non-blocking in-p read end makes the child's own
  ;; stdin reads see spurious EAGAIN; a non-blocking out-p/err-p write end
  ;; would do the same to the child's own stdout/stderr writes. Each of the
  ;; three pipes below only ever sets non-blocking on the end the parent
  ;; itself retains.
  (define (mk-pipe nonblocking-read? nonblocking-write?)
    (let ((fds (sa-foreign-alloc 8)))
      (if (= 0 (proc-c-pipe fds))
          (let ((p (cons (sa-foreign-ref 'int fds 0) (sa-foreign-ref 'int fds 4))))
            (sa-foreign-free fds)
            (when nonblocking-read? (proc-set-nonblocking! (car p)))
            (when nonblocking-write? (proc-set-nonblocking! (cdr p)))
            p)
          (begin (sa-foreign-free fds)
                 (throw-jvm (quote java.io.IOException) "pipe: cannot allocate")))))
  ;; spawn-locked hands back RAW FDS and the ports are built after it returns,
  ;; not inside. proc-fd-input-port / proc-fd-output-port can park now (an EAGAIN on
  ;; a fiber waits on jolt.io-poller, and the first such wait may autoload it),
  ;; and a park inside a jolt-with-mutex region is the deadlock shape
  ;; test/parkcheck refuses outright -- host/chez/locks.ss. Only their
  ;; read!/write! callbacks can actually reach a park, and those run when
  ;; someone reads the port rather than here, so nothing was wrong before; but
  ;; the lock has no reason to span the construction either, and its own
  ;; contract is pipe() through posix_spawn and nothing else. Narrowing it makes
  ;; the call graph say what is true instead of asking for an exemption.
  (define (spawn-locked)
    (jolt-with-mutex proc-spawn-fd-mutex
      (let* ((in-p  (and (not inherit-in?)  (mk-pipe #f #t)))
             (out-p (and (not inherit-out?) (mk-pipe #t #f)))
             (err-p (and (not inherit-err?) (mk-pipe #t #f)))
             (fa (sa-foreign-alloc 128))
             (pidbuf (sa-foreign-alloc 8)))
        (proc-fa-init fa)
        (when in-p  (proc-fa-dup2 fa (car in-p) 0)
                    (proc-fa-close fa (car in-p)) (proc-fa-close fa (cdr in-p)))
        (when out-p (proc-fa-dup2 fa (cdr out-p) 1)
                    (proc-fa-close fa (cdr out-p)) (proc-fa-close fa (car out-p)))
        (when err-p (proc-fa-dup2 fa (cdr err-p) 2)
                    (proc-fa-close fa (cdr err-p)) (proc-fa-close fa (car err-p)))
        (let* ((argv (proc-marshal-argv (list "/bin/sh" "-c" sh-cmd)))
               (envp (proc-marshal-argv
                      (map (lambda (p) (string-append (car p) "=" (cdr p)))
                           (all-env-pairs))))
               ;; attrp is NULL, so the child inherits this thread's signal mask —
               ;; which must carry none of jolt's own blocking (concurrency.ss).
               (rc (jolt-with-empty-sigmask
                     (lambda () (proc-c-spawn pidbuf "/bin/sh" fa 0 (car argv) (car envp)))))
               (pid (sa-foreign-ref 'int pidbuf 0)))
          (proc-fa-destroy fa)
          (sa-foreign-free fa) (sa-foreign-free pidbuf)
          (proc-free-argv argv) (proc-free-argv envp)
          ;; parent side: the child's pipe ends close unconditionally; on a failed
          ;; spawn the parent ends close too, before the throw.
          (when in-p  (proc-c-close (car in-p)))
          (when out-p (proc-c-close (cdr out-p)))
          (when err-p (proc-c-close (cdr err-p)))
          (if (= rc 0)
              (vector (and in-p  (cdr in-p))
                      (and out-p (car out-p))
                      (and err-p (car err-p))
                      pid)
              (begin
                (when in-p  (proc-c-close (cdr in-p)))
                (when out-p (proc-c-close (car out-p)))
                (when err-p (proc-c-close (car err-p)))
                (throw-jvm (quote java.io.IOException)
                  (string-append "posix_spawn failed (errno " (number->string rc) ")"))))))))
  (let ((fds (spawn-locked)))
    (values (let ((fd (vector-ref fds 0))) (and fd (proc-fd-output-port fd)))
            (let ((fd (vector-ref fds 1))) (and fd (proc-fd-input-port fd)))
            (let ((fd (vector-ref fds 2))) (and fd (proc-fd-input-port fd)))
            (vector-ref fds 3))))

;; --- java.lang.Process -------------------------------------------------------
;; state: #(stdin-os stdout-is stderr-is pid exit-box cmd mutex stdout-port
;;          stdin-port inherit-latches signalled-box)
(define (proc-p-stdin-os st)   (vector-ref (jhost-state st) 0))
(define (proc-p-stdout-is st)  (vector-ref (jhost-state st) 1))
(define (proc-p-stderr-is st)  (vector-ref (jhost-state st) 2))
(define (proc-p-pid st)        (vector-ref (jhost-state st) 3))
(define (proc-p-exit-box st)   (vector-ref (jhost-state st) 4))
(define (proc-p-cmd st)        (vector-ref (jhost-state st) 5))
(define (proc-p-mutex st)      (vector-ref (jhost-state st) 6))
(define (proc-p-stdout-port st) (vector-ref (jhost-state st) 7))
(define (proc-p-stdin-port st)  (vector-ref (jhost-state st) 8))
(define (proc-p-inherit-latches st) (vector-ref (jhost-state st) 9))
;; The 128+signal status of a signal WE sent, if any — the one recoverable answer
;; when the child turns out to be unwaitable (see proc-lost-status).
(define (proc-p-signalled st)  (vector-ref (jhost-state st) 10))
(define (proc-process? x) (and (jhost? x) (string=? (jhost-tag x) "process")))

;; ProcessBuilder.start resolves the program before spawning and throws
;; IOException("…No such file or directory") when it can't be found; our shell
;; would otherwise fail at exec (127) with a different message. Mirror it:
;;   - absolute program: the file must exist
;;   - slash-bearing relative program: resolves against the child cwd, like exec
;;   - bare name: an entry of that name must be on PATH
(define (proc-path-join a b)
  (if (or (= (string-length a) 0) (char=? (string-ref a (- (string-length a) 1)) #\/))
      (string-append a b)
      (string-append a "/" b)))
(define (proc-has-slash? s)
  (let loop ((i 0)) (cond ((= i (string-length s)) #f)
                          ((char=? (string-ref s i) #\/) #t)
                          (else (loop (+ i 1))))))
(define (proc-on-path? prog)
  (let ((path (getenv "PATH")))
    (and path
         (let loop ((dirs (str-literal-split path ":")))
           (cond ((null? dirs) #f)
                 ((and (> (string-length (car dirs)) 0)
                       (file-exists? (proc-path-join (car dirs) prog))) #t)
                 (else (loop (cdr dirs))))))))
(define (proc-program-resolvable? prog effective-dir)
  (let ((prog (if (string? prog) prog (jolt-str-render-one prog))))
    (cond
      ((= (string-length prog) 0) #f)
      ((char=? (string-ref prog 0) #\/) (file-exists? prog))
      ((proc-has-slash? prog)
       (file-exists? (proc-path-join (or effective-dir (getenv "JOLT_PWD") ".") prog)))
      (else (proc-on-path? prog)))))

(define (proc-pb-start self)
  (let* ((st (jhost-state self))
         (cmd (proc-pb-cmd self)))
    (when (and (pair? cmd)
               (not (proc-program-resolvable? (car cmd) (proc-effective-dir (proc-pb-dir self)))))
      (throw-jvm (quote java.io.IOException)
        (string-append "Cannot run program \""
                       (if (string? (car cmd)) (car cmd) (jolt-str-render-one (car cmd)))
                       "\": error=2, No such file or directory")))
    (proc-ensure-reapable!)
    (let* ((rin  (proc-pb-redir-in self))
           (rout (proc-pb-redir-out self))
           (rerr (proc-pb-redir-err self))
           (inherit? (lambda (r) (and (proc-redirect? r) (eq? (proc-redirect-kind r) 'inherit)))))
      ;; posix_spawn drives EVERY spawn where the FFI surface exists, not only the
      ;; ones with an INHERIT stream — it already pipes each stream that is not
      ;; inherited, so the two differ in how the child is created, not in what it
      ;; gets. Chez's fork leaves SIGINT set to SIG_IGN in the child, which no
      ;; amount of care on this side can undo (it happens between its fork and its
      ;; exec), and a child that cannot be interrupted by ^C is not what
      ;; ProcessBuilder hands you anywhere else. That is the system(3) leak the
      ;; convention exists to avoid, not the convention (jolt-a4hs); through
      ;; posix_spawn a child's dispositions match a plain shell's exactly.
      ;; The fork path stays as the fallback for machine types without the FFI,
      ;; INHERIT emulation and all.
      (if proc-spawn-fd-ok?
          ;; An INHERITED stream means the child writes jolt's real descriptors,
          ;; so anything jolt has buffered must land first to keep its order.
          (begin
            (when (or (inherit? rout) (inherit? rerr))
              (guard (e (#t #f)) (flush-output-port (current-output-port)))
              (guard (e (#t #f)) (flush-output-port (current-error-port))))
            (call-with-values
              (lambda () (proc-spawn-fd-level (proc-build-shell-command self)
                                              (inherit? rin) (inherit? rout) (inherit? rerr)))
              (lambda (cin cout cerr pid)
                (let* ((child-stdin  (or cin  (proc-null-output-port)))
                       (child-stdout (or cout (proc-null-input-port)))
                       (child-stderr (or cerr (proc-null-input-port)))
                       (pst (vector (make-out-stream child-stdin)
                                    (make-in-stream child-stdout)
                                    (make-in-stream child-stderr)
                                    pid (box #f) (proc-pb-cmd self) (make-mutex)
                                    child-stdout child-stdin (box '()) (box #f))))
                  (make-jhost "process" pst)))))
          (call-with-values
            ;; Chez forks for this one, so the child inherits this thread's
            ;; signal mask just as the posix_spawn path does. (It also leaves
            ;; SIGINT ignored in the child, which is why this is the fallback.)
            (lambda () (jolt-with-empty-sigmask
                         (lambda () (sa-run-process (proc-build-shell-command self) #f))))
            (lambda (child-stdin child-stdout child-stderr pid)
              (let* ((latches (box '()))
                     (pst (vector (make-out-stream child-stdin)
                                  (make-in-stream child-stdout)
                                  (make-in-stream child-stderr)
                                  pid (box #f) (proc-pb-cmd self) (make-mutex)
                                  child-stdout child-stdin latches (box #f))))
                ;; INHERIT emulation fallback (no posix_spawn FFI): pump between
                ;; the pipe and jolt's own stdio. The output pumps are latched so
                ;; waitFor can join them — INHERIT output must be flushed before
                ;; the process is reported finished.
                (when (inherit? rin)  (proc-pump (current-input-port) child-stdin #t))
                (when (inherit? rout) (set-box! latches (cons (proc-pump child-stdout (current-output-port) #f) (unbox latches))))
                (when (inherit? rerr) (set-box! latches (cons (proc-pump child-stderr (current-error-port) #f) (unbox latches))))
                (make-jhost "process" pst))))))))

;; Block until the process exits, caching and returning the decoded status. Any
;; INHERIT output pumps are joined first, so all forwarded output has landed by
;; the time the exit status is returned (matching fd-level INHERIT).
;; EVERY branch here has to reach a decision. This loop runs while holding the
;; process mutex, so a branch that retries forever does not merely spin — it
;; deadlocks every other method on the process, silently and for as long as the
;; caller is willing to wait. That is what sat on a CI gate for 3h42m (jolt-pgbh):
;; a waitpid failing with ECHILD fell into the `else` retry, which could never
;; succeed. Only EINTR is retried, because only EINTR means "ask again".
;;
;; POLLS with WNOHANG rather than issuing a blocking waitpid, because a blocking
;; one can park in the KERNEL forever, where no amount of care in this loop
;; reaches it: when SIGCHLD is SIG_IGN, POSIX has wait block until EVERY child has
;; terminated before failing with ECHILD, and a child that became a zombie before
;; the disposition changed leaves it parked indefinitely. A program that sets
;; SIG_IGN itself, or inherits it, then called .waitFor and hung with the whole
;; process at 0% CPU — the same shape as jolt-pgbh, one level lower down.
;; proc-wait-timed already polls for exactly this reason; this is the last caller
;; that did not. Backs off 0.2ms -> 10ms so a short-lived child is still reaped
;; promptly while a long-lived one costs ~100 wakeups a second.
(define proc-poll-step-max 10)                   ; 10ms
;; ONE reap attempt, under the mutex. -> the exit status, or #f meaning "ask again".
;; The mutex is what stops two callers reaping the same child at once, and one
;; attempt is all it has to cover: the exit-box is written under it and read under
;; it, so a caller that loses the race sees the winner's answer on its next pass.
(define (proc-reap-once st)
  (jolt-with-mutex (proc-p-mutex st)
    (or (unbox (proc-p-exit-box st))
        (call-with-values (lambda () (proc-waitpid-once (proc-p-pid st) #t))
          (lambda (rc decoded err)
            (cond
              ((and decoded (= rc (proc-p-pid st)))
               (set-box! (proc-p-exit-box st) decoded) decoded)
              ;; another caller reaped it between our check and our wait
              ((unbox (proc-p-exit-box st)))
              ;; still running (WNOHANG rc = 0), or merely interrupted: both mean
              ;; "ask again", which is #f here and a pause in the caller.
              ((or (= rc 0) (and (< rc 0) (= err proc-EINTR))) #f)
              ;; unwaitable (ECHILD) or waitpid unavailable — no number of retries
              ;; changes that.
              (else (let ((c (proc-lost-status st)))
                      (set-box! (proc-p-exit-box st) c) c))))))))

;; THE PAUSE IS OUTSIDE THE MUTEX, and the loop is out here with it. This used to
;; hold proc-p-mutex across the entire poll, which is for as long as the child runs.
;; Two things were wrong with that and the second is the sharper: a counted lock held
;; for an unbounded time makes the whole CARRIER unpreemptible, because the scheduler
;; refuses to preempt a fiber while its carrier holds one — so a `.waitFor` from a go
;; block froze every fiber on that carrier for the life of the subprocess, out of
;; reach of even the preemption that is supposed to be the backstop. And the pause
;; itself slept the carrier, so a fiber could not have parked in there anyway
;; (jolt-x1no). Now the lock covers one waitpid attempt, and jolt-pause-ms parks a
;; fiber between attempts while a thread sleeps.
;;
;; The interrupt check is per ROUND rather than a registration, because this is a
;; poll and not a condition wait: there is no cv for .interrupt to poke, so the flag
;; is simply read (and cleared) each time round, which is the same
;; check-clear-throw jolt-cv-wait-interruptibly does at the top of its decide.
;; Process.waitFor throws InterruptedException on the JVM.
(define (proc-wait-blocking st)
  (let ((code
          (let loop ((step 1))                   ; 1ms
            (or (proc-reap-once st)
                (begin
                  (jolt-interrupt-poll-check! "Process.waitFor")
                  (jolt-pause-ms step)
                  (loop (min proc-poll-step-max (* step 2))))))))
    (for-each proc-latch-wait (unbox (proc-p-inherit-latches st)))
    code))

;; Non-blocking liveness poll (reaps and caches on exit). An unwaitable child is
;; reported dead AND has its status cached, so a waitFor after it cannot go looking
;; for a child that will never be there.
(define (proc-alive? st)
  (jolt-with-mutex (proc-p-mutex st)
    (if (unbox (proc-p-exit-box st)) #f
        (call-with-values (lambda () (proc-waitpid-once (proc-p-pid st) #t))
          (lambda (rc decoded err)
            (cond ((= rc 0) #t)                      ; still running
                  (decoded (set-box! (proc-p-exit-box st) decoded) #f)
                  ((and (< rc 0) (= err proc-EINTR)) #t)   ; no answer yet, assume alive
                  (else (set-box! (proc-p-exit-box st) (proc-lost-status st)) #f)))))))

;; Records a terminating signal we sent, so proc-lost-status can still give the
;; right answer for a child that something else reaps before we get to it.
(define (proc-signal st sig)
  (when proc-kill
    (proc-kill (proc-p-pid st) sig)
    (when (or (= sig proc-SIGTERM) (= sig proc-SIGKILL))
      (set-box! (proc-p-signalled st) (+ 128 sig))))
  st)

(register-host-methods! "process"
  (list (cons "getOutputStream" (lambda (self) (proc-p-stdin-os self)))
        (cons "getInputStream"  (lambda (self) (proc-p-stdout-is self)))
        (cons "getErrorStream"  (lambda (self) (proc-p-stderr-is self)))
        (cons "pid"             (lambda (self) (->num (proc-p-pid self))))
        (cons "isAlive"         (lambda (self) (proc-alive? self)))
        (cons "destroy"         (lambda (self) (proc-signal self proc-SIGTERM) jolt-nil))
        (cons "destroyForcibly" (lambda (self) (proc-signal self proc-SIGKILL) self))
        (cons "waitFor" (lambda (self . args)
          (if (null? args)
              (->num (proc-wait-blocking self))
              ;; (waitFor timeout unit): babashka always passes MILLISECONDS.
              (proc-wait-timed self (jnum->exact (car args))))))
        (cons "exitValue" (lambda (self)
          (jolt-with-mutex (proc-p-mutex self)
            (or (unbox (proc-p-exit-box self))
                (call-with-values (lambda () (proc-waitpid-once (proc-p-pid self) #t))
                  (lambda (rc decoded err)
                    (cond (decoded (set-box! (proc-p-exit-box self) decoded) (->num decoded))
                          ;; unwaitable: it HAS exited (something else reaped it), so
                          ;; report the recoverable status rather than claiming it is
                          ;; still running — exitValue would otherwise throw forever.
                          ((and (< rc 0) (not (= err proc-EINTR)))
                           (let ((c (proc-lost-status self)))
                             (set-box! (proc-p-exit-box self) c) (->num c)))
                          (else (throw-jvm (quote IllegalThreadStateException) "process has not exited")))))))))
        (cons "toHandle" (lambda (self) (make-proc-handle (proc-p-pid self))))
        (cons "onExit"   (lambda (self) (make-proc-completable self)))
        (cons "toString" (lambda (self) (string-append "#<Process pid=" (number->string (proc-p-pid self)) ">")))))

;; timed waitFor -> #t if exited within `ms`, else #f (polls at ~10ms).
(define (proc-wait-timed st ms)
  (let ((step 10))
    (let loop ((remaining ms))
      (cond ((not (proc-alive? st)) #t)
            ((<= remaining 0) #f)
            ;; a fiber parks for the step rather than sleeping its carrier
            (else (jolt-interrupt-poll-check! "Process.waitFor")
                  (jolt-pause-ms step)
                  (loop (- remaining step)))))))

;; --- java.lang.ProcessHandle (destroy-tree) ----------------------------------
;; descendants asks the OS for the live tree under a pid — jolt tracks nothing
;; itself. Darwin: libproc's proc_listchildpids per pid (returns a COUNT of
;; pid_t entries; the size argument is in BYTES — probed, jolt-hpdu). Linux: one
;; pass over /proc/*/stat building ppid -> pids, then a walk from the root.
;; Windows (no arm here) and a missing entry point answer empty — the old
;; behavior, where destroy-tree reduces to destroy. babashka.process's
;; destroy-tree destroys (cons handle descendants), so a real answer here is
;; what makes killing a wrapper also kill the work it spawned: `lake env repl`
;; killed via :shutdown destroy-tree used to leave the repl grandchild running
;; as an orphan.
(define proc-listchildpids
  (and (eq? (sa-os-family) 'macos)
       (jolt-foreign-proc-safe "proc_listchildpids" '(int u8* int) 'int)))

;; Direct children via libproc. A count equal to the capacity may be a truncated
;; answer: retry doubled, up to a cap no real tree reaches.
(define (proc-children-darwin pid)
  (let loop ((cap 256))
    (let* ((buf (make-bytevector (* cap 4) 0))
           (n (proc-listchildpids pid buf (* cap 4))))
      (cond ((or (not (fixnum? n)) (<= n 0)) '())
            ((and (>= n cap) (<= cap 65536)) (loop (* cap 2)))
            (else (let col ((i 0) (acc '()))
                    (if (= i n) acc
                        (col (+ i 1) (cons (bytevector-s32-native-ref buf (* i 4)) acc)))))))))

;; Linux: /proc/<pid>/stat is "pid (comm) state ppid ..." and comm may contain
;; spaces and ')', so the ppid is parsed after the LAST ')'. Each read is
;; guarded — a process is free to exit between the listing and the read.
(define (proc-linux-ppid-map)
  (let ((tbl (make-eqv-hashtable)))
    (for-each
      (lambda (name)
        (let ((pid (string->number name)))
          (when (fixnum? pid)
            (guard (e (#t #f))
              (let* ((s (call-with-port (open-input-file (string-append "/proc/" name "/stat"))
                          get-string-all))
                     (rp (let scan ((i (- (string-length s) 1)))
                           (cond ((< i 0) #f)
                                 ((char=? (string-ref s i) #\)) i)
                                 (else (scan (- i 1))))))
                     (ppid (and rp
                                (let ((parts (filter (lambda (t) (> (string-length t) 0))
                                                     (str-literal-split
                                                       (substring s (+ rp 1) (string-length s)) " "))))
                                  (and (pair? parts) (pair? (cdr parts))
                                       (string->number (cadr parts)))))))
                (when (fixnum? ppid)
                  (hashtable-set! tbl ppid (cons pid (hashtable-ref tbl ppid '())))))))))
      (guard (e (#t '())) (directory-list "/proc")))
    tbl))

;; All live descendants of pid, depth-first. State is per-call (nothing shared
;; across threads); the seen set stops a walk that pid reuse made cyclic.
(define (proc-descendants pid)
  (let ((kids (cond (proc-listchildpids proc-children-darwin)
                    ((eq? (sa-os-family) 'linux)
                     (let ((tbl (proc-linux-ppid-map)))
                       (lambda (p) (hashtable-ref tbl p '()))))
                    (else (lambda (p) '()))))
        (seen (make-eqv-hashtable)))
    (let walk ((frontier (kids pid)) (acc '()))
      (cond ((null? frontier) (reverse acc))
            ((hashtable-ref seen (car frontier) #f) (walk (cdr frontier) acc))
            (else
             (hashtable-set! seen (car frontier) #t)
             (walk (append (kids (car frontier)) (cdr frontier))
                   (cons (car frontier) acc)))))))

(define (make-proc-handle pid) (make-jhost "process-handle" pid))
(register-host-methods! "process-handle"
  (list (cons "destroy" (lambda (self) (when proc-kill (proc-kill (jhost-state self) proc-SIGTERM)) #t))
        (cons "pid"     (lambda (self) (->num (jhost-state self))))
        (cons "descendants" (lambda (self)
          (apply jolt-vector (map make-proc-handle (proc-descendants (jhost-state self))))))))

;; --- opt-in scoped process ownership (Linux) ----------------------------------
;; The ProcessBuilder surface above is the JVM's: it owns ONE pid, destroy
;; signals ONE pid, and nothing about it can guarantee a caller's timeout kills
;; the work a child spawned — destroy-tree enumerates descendants and signals
;; them one pid at a time, a snapshot racing the tree's own growth, and a child
;; that ignores SIGTERM survives p/destroy indefinitely. This section is a
;; separate, OPT-IN facility for the caller that wants the stronger contract:
;; spawn into a process group jolt owns exclusively, and when the run times out
;; (or the root exits leaving the group populated), TERM the WHOLE group, then
;; KILL it, and return only once /proc confirms nothing live remains in the
;; owned scope. Nothing above changes: unscoped semantics are exactly what they
;; were, and this is reached only through jolt.host/process-scope-run.
;;
;; Linux-only by construction: the scope is a POSIX process group created with
;; POSIX_SPAWN_SETPGROUP — 0x02 in glibc's spawn.h (probed) and musl's (musl
;; git: include/spawn.h) — signalled with kill(-pgid, sig) (kill(2): a pid
;; < -1 addresses every process in that group), and enumerated by scanning
;; /proc/<pid>/stat whose fields after the last ')' are "state ppid pgrp ..."
;; (probed: /proc/self/stat — pgrp is the 3rd token). A full new SESSION is
;; deliberately not attempted: neither libc provides a posix_spawnattr_setsid
;; setter (no such prototype or exported symbol here through glibc 2.43 —
;; probed; musl's spawn.h defines only the macro). glibc 2.43's posix_spawn
;; does honor the raw POSIX_SPAWN_SETSID bit (0x80, __USE_GNU-guarded —
;; probed: a child spawned with the bit lands in its own session), but setting
;; it means poking an opaque struct's flag word and the glibc FLOOR (2.26,
;; amazonlinux:2) is unprobed, so the "distinct execution session" this
;; facility creates is a distinct process GROUP in jolt's session, uniformly:
;; the child's pgid is its own pid, jolt is not a member, and kill(-pgid) can
;; never reach jolt or anything jolt spawned unscoped. A group also detaches
;; the child from the terminal's foreground group, so ^C at a tty does not
;; interrupt it — the controller's timeout is the only way it ends, which is
;; the point of an owned scope.
;;
;; The argv boundary is DIRECT: posix_spawn execs the resolved program with the
;; caller's argv — no /bin/sh, no shell quoting, no word splitting (the
;; ProcessBuilder path above routes through `sh -c` to reuse its cd/env/
;; redirect prefixes; here those are file actions and an explicit envp instead,
;; so no launcher is involved at all). stdio defaults to /dev/null on all three
;; streams: for a caller not requesting capture that means no pipes at all, so
;; a child can never block on a full pipe buffer and forced termination is
;; always prompt — byte-for-byte the behavior this facility has always had.
;; Separately bounded stdout/stderr capture (below) is the one opt-in
;; replacement: a requested stream gets a pipe DRAINED BY THE CONTROLLER LOOP
;; ITSELF through poll(2), so the no-deadlock property survives — both ends
;; drain in the same loop that polls waitpid, and the retained bytes stop
;; growing at the caller's own byte cap.
(define proc-sc-attr-init
  (jolt-foreign-proc-safe "posix_spawnattr_init" '(void*) 'int))
(define proc-sc-attr-destroy
  (jolt-foreign-proc-safe "posix_spawnattr_destroy" '(void*) 'int))
(define proc-sc-attr-setpgroup
  (jolt-foreign-proc-safe "posix_spawnattr_setpgroup" '(void* int) 'int))
;; glibc/musl declare the flags argument short; bound as int, which is
;; ABI-identical on the SysV x86-64 and aarch64 ABIs (both pass the argument in
;; a 32-bit slot; the callee reads the low 16 bits) and keeps to this file's
;; existing type vocabulary.
(define proc-sc-attr-setflags
  (jolt-foreign-proc-safe "posix_spawnattr_setflags" '(void* int) 'int))
(define proc-sc-fa-addopen
  (jolt-foreign-proc-safe "posix_spawn_file_actions_addopen" '(void* int string int int) 'int))
;; addchdir_np is glibc 2.29+/musl 1.1.24+; jolt's floor builds reach older
;; glibc (amazonlinux:2 is 2.26), so the binding is runtime-resolved and a
;; request that needs it fails closed with an error instead of silently
;; spawning in the wrong directory.
(define proc-sc-fa-addchdir
  (jolt-foreign-proc-safe "posix_spawn_file_actions_addchdir_np" '(void* string) 'int))

(define proc-sc-POSIX-SPAWN-SETPGROUP 2)  ; probed: glibc + musl spawn.h
(define proc-sc-O-RDWR 2)                 ; fcntl.h: stable on every Linux arch

;; poll(2), for the scoped run's capture drain (the capture section below owns
;; the pollfd layout notes). Bound with the BLOCKING convention, like
;; proc-c-read/proc-c-write: a wait bounded only by a timeout must be
;; __collect_safe, and the pollfd array the call fills in lives in foreign
;; memory. Defined here, ABOVE proc-scope-ok?, so the gate can require it.
(define proc-sc-poll
  (jolt-foreign-proc-blocking "poll" '(void* size_t int) 'int))
;; POLLIN: 0x001 in glibc's and musl's poll.h on x86-64 and aarch64 alike
;; (table knowledge; this facility is already Linux-x86-64/aarch64 shaped —
;; see the ABI note on proc-sc-attr-setflags).
(define proc-sc-POLLIN 1)

;; Everything the facility needs, present. proc-c-spawn/proc-fa-init/... are
;; shared with the unscoped path; the attr entry points and kill are ours.
;; poll joins the gate because the capture drain is not machinery the facility
;; can degrade around: without it the controller cannot drain its own pipes,
;; and a spawn that can leak a wedged capture is worse than no spawn — fail
;; closed instead. Off Linux (no /proc) the exported fn throws rather than
;; guessing.
(define proc-scope-ok?
  (and (eq? (sa-os-family) 'linux)
       proc-c-spawn proc-fa-init proc-fa-destroy proc-sc-fa-addopen
       proc-sc-attr-init proc-sc-attr-destroy proc-sc-attr-setpgroup
       proc-sc-attr-setflags proc-kill proc-waitpid proc-sc-poll #t))

;; Program resolution with the SAME shape as proc-program-resolvable? above
;; (absolute: file must exist; slash-bearing: against the child cwd; bare: PATH
;; scan) but returning the resolved path, since the scoped spawn execs the path
;; itself rather than handing a shell a quoted token. -> path string or #f.
(define (proc-sc-resolve-program prog effective-dir)
  (cond
    ((= (string-length prog) 0) #f)
    ((char=? (string-ref prog 0) #\/) (and (file-exists? prog) prog))
    ((proc-has-slash? prog)
     (let ((p (proc-path-join (or effective-dir (getenv "JOLT_PWD") ".") prog)))
       (and (file-exists? p) p)))
    (else
      (let ((path (getenv "PATH")))
        (let loop ((dirs (if path (str-literal-split path ":") '())))
          (cond ((null? dirs) #f)
                ;; the clause needs its own consequent: a bare
                ;; ((file-exists? ...)) clause would evaluate to the TEST's
                ;; value (#t), and #t handed to posix_spawn as the path is a
                ;; foreign-call exception — the branch had never been taken
                ;; with a hit before (every caller spelled /bin/sh), so the
                ;; latent bug survived until a bare-name resolution succeeded.
                ((and (> (string-length (car dirs)) 0)
                      (file-exists? (proc-path-join (car dirs) prog)))
                 (proc-path-join (car dirs) prog))
                (else (loop (cdr dirs)))))))))

;; One /proc pass answering BOTH ownership questions: which live processes are
;; members of the owned group (pgrp == pgid), and which live processes descend
;; from the root pid (ppid walk — catches a descendant that left the group via
;; its own setsid while its parent link still names our tree). "Live" excludes
;; Z (zombie) and X/x (dying): the process has terminated and can do nothing
;; further; zombies that pid 1 has not reaped yet must not hold the confirm
;; loop, and the root's own zombie is settled by waitpid afterwards. A process
;; that escaped BOTH nets (setsid AND reparented through an exited
;; intermediate) is unreachable by /proc topology — an inherent limit, and the
;; same one proc-descendants has. Each read is guarded: a process is free to
;; exit between the listing and the read. Returns (values members descendants).
(define (proc-sc-scan root-pid pgid)
  (let ((info (make-eqv-hashtable))     ; pid -> (state-char . pgrp)
        (kids (make-eqv-hashtable)))    ; ppid -> (pid ...)
    (for-each
      (lambda (name)
        (let ((pid (string->number name)))
          (when (fixnum? pid)
            (guard (e (#t #f))
              (call-with-port (open-input-file (string-append "/proc/" name "/stat"))
                (lambda (p)
                  (let* ((s (get-string-all p))
                         (rp (let scan ((i (- (string-length s) 1)))
                               (cond ((< i 0) #f)
                                     ((char=? (string-ref s i) #\)) i)
                                     (else (scan (- i 1)))))))
                    ;; comm can contain spaces and ')', so parse after the
                    ;; LAST ')' exactly as proc-linux-ppid-map does. Tokens
                    ;; start at state; ppid is 2nd, pgrp 3rd (probed).
                    (when rp
                      (let ((parts (filter (lambda (t) (> (string-length t) 0))
                                           (str-literal-split
                                             (substring s (+ rp 1) (string-length s)) " "))))
                        (when (and (pair? parts) (pair? (cdr parts)) (pair? (cddr parts)))
                          (let ((state (string-ref (car parts) 0))
                                (ppid (string->number (cadr parts)))
                                (pgrp (string->number (caddr parts))))
                            (when (and (fixnum? ppid) (fixnum? pgrp))
                              (hashtable-set! info pid (cons state pgrp))
                              (hashtable-set! kids ppid
                                (cons pid (hashtable-ref kids ppid '())))))))))))))))
      (guard (e (#t '())) (directory-list "/proc")))
    ;; let*: the members scan uses dead? from the sibling binding, which a
    ;; parallel let would not make visible to initializers.
    (let* ((live? (lambda (pid)
                    (let ((c (hashtable-ref info pid #f)))
                      (and c (not (memv (car c) '(#\Z #\X #\x)))))))
           (dead? (lambda (c) (memv (car c) '(#\Z #\X #\x))))
           (members
            (let loop ((ps (vector->list (hashtable-keys info))) (acc '()))
              (if (null? ps)
                  acc
                  (let ((c (hashtable-ref info (car ps) #f)))
                    (loop (cdr ps)
                          (if (and c (= (cdr c) pgid) (not (dead? c)))
                              (cons (car ps) acc)
                              acc)))))))
      ;; Walk the ppid edges from the root, live-only, seen-set against cycles
      ;; (pid reuse can, in principle, make the graph cyclic).
      (let ((seen (make-eqv-hashtable)))
        (let walk ((frontier (hashtable-ref kids root-pid '())) (acc '()))
          (cond ((null? frontier) (values members (reverse acc)))
                ((hashtable-ref seen (car frontier) #f) (walk (cdr frontier) acc))
                (else
                 (hashtable-set! seen (car frontier) #t)
                 (walk (append (hashtable-ref kids (car frontier) '()) (cdr frontier))
                       (if (live? (car frontier)) (cons (car frontier) acc) acc)))))))))

;; (proc-sc-stat-entry pid) -> (state-char . ppid) | #f. One guarded read of
;; /proc/<pid>/stat; #f covers every way a process can vanish underneath the
;; read (exited, reaped, or the pid never existed).
(define (proc-sc-stat-entry pid)
  (guard (e (#t #f))
    (call-with-port (open-input-file (string-append "/proc/" (number->string pid) "/stat"))
      (lambda (p)
        (let* ((s (get-string-all p))
               (rp (let scan ((i (- (string-length s) 1)))
                     (cond ((< i 0) #f)
                           ((char=? (string-ref s i) #\)) i)
                           (else (scan (- i 1)))))))
          (and rp
               (let ((parts (filter (lambda (t) (> (string-length t) 0))
                                    (str-literal-split
                                      (substring s (+ rp 1) (string-length s)) " "))))
                 (and (pair? parts) (pair? (cdr parts))
                      (let ((ppid (string->number (cadr parts))))
                        (and (fixnum? ppid)
                             (cons (string-ref (car parts) 0) ppid)))))))))))

;; Live ppid chain from `pid` up to `ancestor`? THE revalidation for bare-pid
;; kills: a pid recorded by an earlier scan may since have exited and been
;; REUSED by an unrelated process, and killing that pid unconditionally could
;; kill the newcomer. The chain is re-checked from /proc immediately before
;; kill(2), confining the signal to a process that is still, provably, inside
;; our tree. The check→kill window itself cannot be closed from userspace
;; (only pidfd_send_signal closes it) — that residue is this facility's
;; documented irreducible limitation. A descendant whose chain broke (an
;; intermediate exited and it was reparented to init) fails the check and is
;; NOT signalled — fail-closed: the survivor then surfaces in the confirm
;; step's loud error instead of risking an innocent kill.
(define (proc-sc-descendant-now? pid ancestor)
  (let loop ((p pid) (hops 0))
    (and (< hops 64)                            ; backstop; pid reuse cannot cycle
         (let ((e (proc-sc-stat-entry p)))
           (cond ((not e) #f)                   ; vanished: dead, or never ours
                 ((= p ancestor) #t)
                 ((memv (car e) '(#\Z #\X #\x)) #f)  ; dead: not ours to signal
                 (else (loop (cdr e) (+ hops 1))))))))

(define (proc-sc-kill-descendant! root-pid pid sig)
  (when (proc-sc-descendant-now? pid root-pid)
    (proc-kill pid sig)))

;; The escalation ladder, scoped and evidence-honest:
;;   1. one /proc scan says what the scope still holds;
;;   2. a TERM wave — kill(-pgid) ONLY under a scan that just showed live
;;      members. While ANY member is alive the pgid cannot be taken by a new
;;      group (the kernel keeps the id hashed while a task references it as
;;      its pgrp — table knowledge, not probed here), so a group signal sent
;;      against a membered group is confined to the owned scope as far as
;;      process group semantics permit. The scan→kill instant, in which the
;;      last member could die and the id be reused, is the irreducible
;;      PID/PGID-reuse residue — same one as above, only pidfd closes it.
;;      Descendants that left the group (own setsid) get per-pid TERMs,
;;      each revalidated against pid reuse;
;;   3. a grace window for the wave to quiet the scope;
;;   4. a KILL wave — same gating, same revalidation. Nothing less can clear
;;      a tree that ignored TERM.
;; kill(2) to a negative pid cannot hit jolt: jolt is not a member. A failing
;; kill is not an error here (ESRCH: the scope emptied first — the race made
;; visible); a kill failing for a real reason (EPERM against a setuid child
;; that kept our pgid) shows up in the confirm step, named. Returns the
;; STRONGEST signal with positive delivery evidence toward the owned scope —
;; kill(2)'s own return decides (0 = a member existed to take it; -1/ESRCH =
;; nothing was delivered) — or 0 when escalation was skipped because the
;; scope was already quiet. The caller must not claim more than that: a root
;; that in fact died of the earlier wave while the KILL wave merely reached
;; another member still reports 128+9 in the unwaitable fallback; which wave
;; killed the root is unknowable without pidfd, and 9 is the honest ceiling.
(define (proc-sc-escalate! root-pid pgid grace-ms)
  (call-with-values (lambda () (proc-sc-scan root-pid pgid))
    (lambda (members descs)
      (let ((sent
              (if (and (pair? members) (zero? (proc-kill (- pgid) proc-SIGTERM)))
                  proc-SIGTERM 0)))
        (for-each (lambda (d) (proc-sc-kill-descendant! root-pid d proc-SIGTERM)) descs)
        (let ((deadline (+ (jolt-mono-nanos) (* grace-ms 1000000))))
          (let loop ((sent sent))
            (call-with-values (lambda () (proc-sc-scan root-pid pgid))
              (lambda (ms ds)
                (cond ((and (null? ms) (null? ds)) sent)
                      ((< (jolt-mono-nanos) deadline) (jolt-pause-ms 10) (loop sent))
                      (else
                       (let ((sent2
                               (if (and (pair? ms) (zero? (proc-kill (- pgid) proc-SIGKILL)))
                                   proc-SIGKILL sent)))
                         (for-each (lambda (d) (proc-sc-kill-descendant! root-pid d proc-SIGKILL)) ds)
                         sent2)))))))))))

;; The waves were sent; the only honest way to know the scope is empty is to
;; keep asking /proc until it agrees — and each pass ACTS on what the current
;; scan shows rather than on the earlier waves' claims: a member can fork in
;; the grace window and a wave delivered before the fork misses the child,
;; which then shows up here as a fresh live member. Re-signalling uses the
;; same confinement rules as the waves (group signal only under a scan that
;; just showed members; per-pid kills revalidated). The one survivor no
;; signal can move is uninterruptible sleep (D state): wait a bounded time,
;; then fail LOUD — returning "cleaned up" while a descendant lives is
;; precisely the false success this facility exists to make impossible.
(define proc-sc-confirm-ms 5000)
(define (proc-sc-confirm-empty! root-pid pgid)
  (let ((deadline (+ (jolt-mono-nanos) (* proc-sc-confirm-ms 1000000))))
    (let loop ()
      (call-with-values (lambda () (proc-sc-scan root-pid pgid))
        (lambda (members descendants)
          (cond ((and (null? members) (null? descendants)) #t)
                ((< (jolt-mono-nanos) deadline)
                 (when (pair? members) (proc-kill (- pgid) proc-SIGKILL))
                 (for-each (lambda (d) (proc-sc-kill-descendant! root-pid d proc-SIGKILL))
                           descendants)
                 (jolt-pause-ms 10) (loop))
                (else
                 (throw-jvm (quote java.lang.RuntimeException)
                   (string-append "process-scope: survivors after SIGKILL (uninterruptible?): group "
                     (proc-join " " (map number->string members))
                     " descendants "
                     (proc-join " " (map number->string descendants)))))))))))

;; The root is jolt's direct child: reap it for the real status — waitpid's
;; answer is the honest one and is what callers get whenever the reap succeeds.
;; A root that reaps as unwaitable (ECHILD — something else got there, e.g. a
;; SIGCHLD=SIG_IGN set after our restore) falls back to 128+sent-sig, where
;; sent-sig is the strongest signal we have POSITIVE delivery evidence for
;; toward the scope (0 when escalation was skipped outright). That fallback is
;; an informed reconstruction, not a fact: which wave actually killed the root
;; is unknowable from here. Bounded by the same cap as the confirm (the root
;; is dead when this runs; the bound is a backstop, not an expectation).
(define (proc-sc-reap-root pid sent-sig)
  (let ((deadline (+ (jolt-mono-nanos) (* proc-sc-confirm-ms 1000000))))
    (let loop ()
      (call-with-values (lambda () (proc-waitpid-once pid #t))
        (lambda (rc decoded err)
          (cond (decoded decoded)
                ((or (= rc 0) (= err proc-EINTR))
                 (if (< (jolt-mono-nanos) deadline)
                     (begin (jolt-pause-ms 5) (loop))
                     (if (> sent-sig 0) (+ 128 sent-sig) 0)))
                (else (if (> sent-sig 0) (+ 128 sent-sig) 0))))))))

;; Fail-closed setup: EVERY posix_spawn attribute / file-action return code is
;; checked BEFORE posix_spawn runs, and any failure aborts the spawn. The
;; setflags call is the load-bearing one — if it failed silently the child
;; would land in jolt's process group, every later kill(-pgid) would address a
;; group that is not the scope (or nothing at all), and the ownership
;; guarantee would be void while everything reported success. No scope
;; operation may run ungrouped; a failed setup means no child exists.
(define (proc-sc-check-rc! what rc)
  (unless (= rc 0)
    (throw-jvm (quote java.io.IOException)
      (string-append "process-scope: " what " failed (rc " (number->string rc) ")"))))

;; --- separately bounded stdout/stderr capture for the scoped run -------------
;; :out-bytes / :err-bytes (independent positive byte caps) replace that
;; stream's /dev/null file action with a pipe drained BY THE CONTROLLER LOOP
;; itself, through poll(2) over a pollfd set rebuilt each iteration: one
;; syscall covers both streams, no reader threads, no fibers, no port
;; machinery. Level-triggered POLLIN before every read is what makes a BLOCKING
;; read safe (POLLIN on a pipe read end guarantees at least one byte or EOF, so
;; the read that follows cannot park — probed standalone: a readable pipe read
;; of N returns what is there, an EOF'd one returns 0) and what makes a flood
;; deadlock-free: both ends drain in the SAME loop, so a child flooding stdout
;; can never stall the reading of stderr — the classic two-pipe deadlock. While
;; data flows, poll returns immediately and the loop degenerates into a tight
;; drain; when the pipes are quiet it waits the same ~10ms the waitpid cadence
;; always used, so an idle capture costs nothing extra.
;;
;; Memory is bounded by the caller's own cap: captured bytes accumulate as
;; chunks in a list that stops growing at the cap, and the cap REACHED is the
;; ABORT condition — the run ends through the same TERM-wave/grace/KILL-wave/
;; confirm-empty escalation a timeout ends through (see the overflow contract
;; in proc-scope-run's doc). The kernel's per-pipe buffer (64K by default, a
;; fixed non-growing allowance) is the only remainder, and a stream whose cap
;; was reached is simply not read anymore, so a flood can hold neither heap
;; nor the loop.
;;
;; POLLIN/proc-sc-poll are bound and documented above, with the other scoped
;; capability bindings — the drain is part of proc-scope-ok?'s gate, so poll
;; is never missing while a capture pipe exists. struct pollfd is
;; {int fd; short events; short revents;} — 8 bytes on both ABIs, packed here
;; with foreign-set! at stride 8. POLLERR (0x8) and POLLHUP (0x10) are drained
;; like POLLIN: on a pipe read end all three surface as "read now, get bytes
;; or EOF".
(define proc-sc-cap-chunk 32768)

;; The capture pipes: BLOCKING fds by design — every read is justified by a
;; just-returned POLLIN, which on a pipe guarantees at least one byte or EOF,
;; so nothing can park. No O_NONBLOCK and no fcntl: the child's dup2'd write
;; end shares this open file description, and O_NONBLOCK here would make the
;; CHILD's own writes see spurious EAGAIN — the exact hazard the mk-pipe
;; comment in proc-spawn-fd-level describes from the other side.
(define (proc-sc-mkpipe)
  (let ((fds (sa-foreign-alloc 8)))
    (if (= 0 (proc-c-pipe fds))
        (let ((r (sa-foreign-ref 'int fds 0))
              (w (sa-foreign-ref 'int fds 4)))
          (sa-foreign-free fds)
          (cons r w))
        (begin
          (sa-foreign-free fds)
          (throw-jvm (quote java.io.IOException)
            "process-scope: pipe: cannot allocate")))))

;; capture state: #(rfd wfd bound chunks total done? clean-eof?)
;;   rfd  — the parent's read end, -1 once closed
;;   wfd  — the parent's write-end copy, alive only between pipe() and the
;;          posix_spawn return that closes it (the child's copy is closed by
;;          file actions after its dup2 onto 1/2)
;;   bound — the caller's byte cap (exact positive integer)
;;   chunks — captured bytevectors, most recent first
;;   total  — bytes captured so far; invariant: (<= total bound)
;;   done?  — stop polling this stream: EOF, read error, bound reached, closed
;;   clean-eof? — a genuine 0-byte read was observed (the :complete evidence)
(define (proc-sc-cap-make bound)      (vector -1 -1 bound '() 0 #f #f))
(define (proc-sc-cap-rfd c)           (vector-ref c 0))
(define (proc-sc-cap-wfd c)           (vector-ref c 1))
(define (proc-sc-cap-bound c)         (vector-ref c 2))
(define (proc-sc-cap-chunks c)        (vector-ref c 3))
(define (proc-sc-cap-total c)         (vector-ref c 4))
(define (proc-sc-cap-done? c)         (vector-ref c 5))
(define (proc-sc-cap-clean-eof? c)    (vector-ref c 6))
(define (proc-sc-cap-rfd! c v)        (vector-set! c 0 v))
(define (proc-sc-cap-wfd! c v)        (vector-set! c 1 v))

;; The bound was reached — truncation, and (mid-run) the overflow abort. Only
;; ever asked of a REQUESTED capture; #f / an absent cap answers #f.
(define (proc-sc-cap-overflow? c)
  (and c (>= (proc-sc-cap-total c) (proc-sc-cap-bound c))))

;; A requested stream whose pipe is still worth polling.
(define (proc-sc-cap-live? c)
  (and c (>= (proc-sc-cap-rfd c) 0) (not (proc-sc-cap-done? c))))

;; Close the read end and retire the stream. Without a prior clean EOF this
;; leaves the status at :partial — closing is how every non-EOF retirement
;; (including the dynamic-wind cleanup on an exception) honestly lands there.
(define (proc-sc-cap-close! c)
  (when (>= (proc-sc-cap-rfd c) 0)
    (proc-c-close (proc-sc-cap-rfd c))
    (proc-sc-cap-rfd! c -1))
  (vector-set! c 5 #t))

;; Close BOTH ends of a capture's pipe — the fail-closed path for a spawn that
;; never succeeded (pipe() or file-action failure, or posix_spawn error), when
;; no run loop exists to own the read end. Idempotent: closed ends read -1.
(define (proc-sc-cap-abort! c)
  (when c
    (when (>= (proc-sc-cap-wfd c) 0)
      (proc-c-close (proc-sc-cap-wfd c))
      (proc-sc-cap-wfd! c -1))
    (proc-sc-cap-close! c)))

;; One POLLIN-justified read into caller-owned foreign scratch (one scratch is
;; shared by both streams; only one read is ever in flight). Never reads past
;; (- bound total), so the cap cannot be exceeded by a chunk. Retires the
;; stream on EOF (clean-eof? #t — the :complete evidence), on a non-EINTR read
;; error (nothing here should produce one; retiring without the EOF flag
;; reports :partial rather than claiming completeness), and on reaching the
;; bound. EINTR leaves the stream live; the next poll re-reports it.
(define (proc-sc-cap-drain! c scratch)
  (let ((want (min proc-sc-cap-chunk
                   (- (proc-sc-cap-bound c) (proc-sc-cap-total c)))))
    (if (<= want 0)
        (proc-sc-cap-close! c)                    ; defensive: a 0-byte read
                                                  ; would misread as EOF
        (let ((got (proc-c-read (proc-sc-cap-rfd c) scratch want)))
          (cond
            ((> got 0)
             (let ((bv (make-bytevector got)))
               (do ((i 0 (+ i 1)))
                   ((= i got))
                 (bytevector-u8-set! bv i (sa-foreign-ref 'unsigned-8 scratch i)))
               (vector-set! c 3 (cons bv (proc-sc-cap-chunks c)))
               (vector-set! c 4 (+ (proc-sc-cap-total c) got)))
             (when (>= (proc-sc-cap-total c) (proc-sc-cap-bound c))
               (proc-sc-cap-close! c)))
            ((= got 0)
             (vector-set! c 6 #t)                 ; genuine EOF: :complete
             (proc-sc-cap-close! c))
            ((= (proc-errno) proc-EINTR) #f)      ; interrupted: poll re-reports
            (else (proc-sc-cap-close! c)))))))

;; poll(2) over the live capture fds, then drain each readable one once.
;; timeout-ms keeps the controller's waitpid cadence when the pipes are quiet.
;; rc <= 0 (timeout or EINTR) is just "nothing readable" — the caller's loop
;; re-checks its own deadline regardless.
(define (proc-sc-poll-drain! caps scratch timeout-ms)
  (let ((live (filter proc-sc-cap-live? caps)))
    (unless (null? live)
      (let ((arr (sa-foreign-alloc (* 8 (length live)))))
        (do ((i 0 (+ i 1)) (cs live (cdr cs)))
            ((null? cs))
          (sa-foreign-set! 'int arr (* 8 i) (proc-sc-cap-rfd (car cs)))
          (sa-foreign-set! 'short arr (+ (* 8 i) 4) proc-sc-POLLIN))
        (let ((rc (proc-sc-poll arr (length live) timeout-ms)))
          (when (> rc 0)
            (do ((i 0 (+ i 1)) (cs live (cdr cs)))
                ((null? cs))
              (unless (= 0 (bitwise-and
                             (sa-foreign-ref 'short arr (+ (* 8 i) 6))
                             #x19))              ; POLLIN|POLLERR|POLLHUP
                (proc-sc-cap-drain! (car cs) scratch)))))
        (sa-foreign-free arr)))))

;; After the scope is confirmed empty, every writer the nets caught is dead,
;; so EOF on a still-open capture pipe is DECIDABLE: drain what the kernel
;; still holds — and what a TERMed writer flushed on the way out — bounded in
;; TIME. A writer that escaped both nets could hold the pipe open forever; the
;; honest answer for a stream that never reached EOF is :partial, not a hang.
(define proc-sc-drain-budget-ms 500)
(define (proc-sc-final-drain! caps scratch)
  (let ((deadline (+ (jolt-mono-nanos) (* proc-sc-drain-budget-ms 1000000))))
    (let loop ()
      (when (and (< (jolt-mono-nanos) deadline)
                 (exists proc-sc-cap-live? caps))
        (proc-sc-poll-drain! caps scratch 50)
        (loop)))))

;; chunks -> one bytevector; total is the exact byte count, so the result
;; never exceeds the caller's cap.
(define (proc-sc-cap-bytes c)
  (let ((out (make-bytevector (proc-sc-cap-total c) 0)))
    (let loop ((i 0) (bs (reverse (proc-sc-cap-chunks c))))
      (if (null? bs)
          out
          (let* ((bv (car bs)) (m (bytevector-length bv)))
            (bytevector-copy! bv 0 out i m)
            (loop (+ i m) (cdr bs)))))))

;; What each status MEANS, exactly:
;;   truncated — the byte bound was reached. Capture stopped there and, when
;;               that happened before the run otherwise ended, ENDED the run as
;;               an overflow abort. Whether the stream held exactly the bound
;;               or more is NOT distinguished — proc-sc-cap-drain! never reads
;;               past the bound to find out, because finding out would mean
;;               either exceeding the cap or parking past the abort decision.
;;   complete  — EOF was observed before the bound was reached: every writer
;;               closed the pipe, so the string is the stream's ENTIRE output.
;;   partial   — the run ended with neither: data may be missing because a
;;               writer escaped the scope's nets and still holds the pipe open,
;;               or the final drain's time budget ran out. The string is a
;;               PREFIX of the stream, never more.
(define (proc-sc-cap-status c)
  (cond ((proc-sc-cap-overflow? c) "truncated")
        ((proc-sc-cap-clean-eof? c) "complete")
        (else "partial")))

;; Lossy UTF-8 decode of the captured bytes: every valid sequence passes
;; through; anything invalid — bad lead byte, bad or missing continuation,
;; overlong form, surrogate, > #x10FFFF, or a valid-looking sequence truncated
;; by the end of the capture — becomes one U+FFFD per invalid byte. The result
;; is INERT data for the caller: returned, never evaluated, and no exception
;; an adversarial writer can provoke. (Chez's own utf8->string ERRORS on
;; invalid input — exactly the behavior a capture API cannot have.)
(define proc-sc-FFFD (integer->char #xFFFD))
(define (proc-sc-utf8->string-lossy bv)
  (let ((n (bytevector-length bv)))
    (let loop ((i 0) (rev '()))
      (if (= i n)
          (list->string (reverse rev))
          (let* ((b0 (bytevector-u8-ref bv i))
                 (b  (lambda (k) (bytevector-u8-ref bv (+ i k))))
                 (ok2? (and (< (+ i 1) n) (<= #x80 (b 1) #xBF)))
                 (ok3? (and ok2? (< (+ i 2) n) (<= #x80 (b 2) #xBF)))
                 (ok4? (and ok3? (< (+ i 3) n) (<= #x80 (b 3) #xBF))))
            (cond
              ((< b0 #x80)
               (loop (+ i 1) (cons (integer->char b0) rev)))
              ((<= #xC2 b0 #xDF)                       ; C0/C1: overlong
               (if ok2?
                   (loop (+ i 2)
                         (cons (integer->char
                                 (+ (* (- b0 #xC0) #x40) (- (b 1) #x80)))
                               rev))
                   (loop (+ i 1) (cons proc-sc-FFFD rev))))
              ((<= #xE0 b0 #xEF)
               (if (and ok3?
                        (or (> b0 #xE0) (>= (b 1) #xA0))   ; E0 A0..: not overlong
                        (or (< b0 #xED) (< (b 1) #xA0)))  ; not ED A0..: no surrogate
                   (loop (+ i 3)
                         (cons (integer->char
                                 (+ (* (- b0 #xE0) #x1000)
                                    (* (- (b 1) #x80) #x40)
                                    (- (b 2) #x80)))
                               rev))
                   (loop (+ i 1) (cons proc-sc-FFFD rev))))
              ((<= #xF0 b0 #xF4)                       ; F5..: > #x10FFFF
               (if (and ok4?
                        (or (> b0 #xF0) (>= (b 1) #x90))  ; F0 90..: not overlong
                        (or (< b0 #xF4) (<= (b 1) #x8F))) ; F4 <= ..8F
                   (loop (+ i 4)
                         (cons (integer->char
                                 (+ (* (- b0 #xF0) #x40000)
                                    (* (- (b 1) #x80) #x1000)
                                    (* (- (b 2) #x80) #x40)
                                    (- (b 3) #x80)))
                               rev))
                   (loop (+ i 1) (cons proc-sc-FFFD rev))))
              (else (loop (+ i 1) (cons proc-sc-FFFD rev)))))))))

;; The result rows for one stream: the inert string and its status, keyed
;; :out/:out-status (or :err/:err-status). An UNREQUESTED stream contributes
;; NOTHING — the /dev/null default is visible in the return SHAPE (no :out key
;; at all), not just in the child's file descriptors.
(define (proc-sc-cap-rows cap+nm)
  (let ((c (car cap+nm)) (nm (cdr cap+nm)))
    (if c
        (list (jolt-keyword nm)
              (proc-sc-utf8->string-lossy (proc-sc-cap-bytes c))
              (jolt-keyword (string-append nm "-status"))
              (jolt-keyword (proc-sc-cap-status c)))
        '())))

;; The structured request, a Clojure map:
;;   :cmd           required — argv vector of strings; exec'd DIRECTLY, no
;;                  Jolt-created shell (posix_spawn execs the resolved program
;;                  with the caller's argv; env/cwd are an explicit envp and a
;;                  file action, not shell prefixes)
;;   :timeout-ms    required — controller timeout; escalation starts when the
;;                  root has not exited by then
;;   :term-grace-ms optional — how long the TERM wave gets before KILL (200)
;;   :dir           optional — child cwd (needs addchdir_np; error if absent)
;;   :env           optional — map of strings; REPLACES the environment
;;                  (ProcessBuilder.environment semantics); absent = inherit
;;   :out-bytes     optional — separately bounded stdout capture: a positive
;;                  integer BYTE cap (integral value: a fraction like 2.5 or a
;;                  non-number throws IllegalArgumentException — it is never
;;                  silently truncated). Present = a pipe replaces that
;;                  stream's /dev/null and the bytes come back in :out;
;;                  absent = the /dev/null default exactly as before, and no
;;                  :out key in the result at all.
;;   :err-bytes     optional — the stderr twin; the two caps are independent
;;                  and neither influences the other's stream, and the same
;;                  integral-value requirement applies.
;; Returns {:pid p :exit code :timed-out bool} — plus, per REQUESTED stream,
;; {:out "…" :out-status :complete|:truncated|:partial} and/or the :err pair
;; (see proc-sc-cap-status for exactly what each status means). The strings
;; are INERT data: a lossy UTF-8 decode of the captured bytes (invalid
;; sequences become U+FFFD, never an exception), returned and never evaluated.
;;
;; CAPTURE OVERFLOW CONTRACT: a stream whose captured bytes reach its cap is
;; truncated and the run ENDS — the same TERM wave, grace, KILL wave and
;; /proc confirm a timeout runs, with the same no-live-scope guarantee on
;; return — but :timed-out stays FALSE, because the controller clock did not
;; fire; the overflowing stream's :truncated status is what says why. The cap
;; is honored exactly (at most :out-bytes bytes retained), and whether the
;; stream held exactly the cap or more is deliberately not distinguished. A
;; timeout that fires first wins, statuses and all.
;;
;; The rest of the guarantee is unchanged: when the call returns, the owned
;; scope holds nothing live — the root has exited AND been reaped (or its
;; status reconstructed per proc-sc-reap-root) and /proc shows no live member
;; of the group and no live descendant — and that guarantee is not
;; conditional on the timeout, on an overflow, or on a clean exit. The
;; capture pipes are drained by the same controller loop that polls waitpid,
;; so a flood on one stream can neither wedge the run on a full pipe nor
;; starve the other stream's drain. Exceptions, by design: survivors of
;; SIGKILL in D state throw rather than return (capture fds are closed on the
;; way out), and a failed posix_spawn setup throws before any child exists
;; (proc-sc-check-rc!) so no scope operation can ever run ungrouped.
(define (proc-scope-run req)
  (unless proc-scope-ok?
    (throw-jvm (quote UnsupportedOperationException)
      "process-scope: requires Linux with posix_spawn process-group and poll(2) support"))
  (let ((get (lambda (k d) (jolt-get-dispatch req k d))))
    (let ((cmd-raw (get (jolt-keyword "cmd") #f))
          (timeout-ms (get (jolt-keyword "timeout-ms") #f))
          (grace-ms (get (jolt-keyword "term-grace-ms") 200))
          (dir (get (jolt-keyword "dir") #f))
          (env-map (get (jolt-keyword "env") #f))
          (out-bytes (get (jolt-keyword "out-bytes") #f))
          (err-bytes (get (jolt-keyword "err-bytes") #f)))
      (unless (and cmd-raw (not (jolt-nil? cmd-raw)))
        (throw-jvm (quote IllegalArgumentException)
          "process-scope: :cmd (argv vector of strings) is required"))
       (let ((cmd (map jolt-str-render-one (seq->list (jolt-seq cmd-raw))))
             ;; A capture request is a positive byte cap; #f / nil = not
             ;; requested. Anything else fails closed BEFORE anything is
             ;; spawned. The value must be INTEGRAL: jnum->exact truncates, so
             ;; routing through it would silently floor a fraction (2.5 -> a
             ;; 2-byte cap) — the exact conversion is checked for integrality
             ;; instead, and a fractional bound is a caller error.
             (cap-n (lambda (who v)
                      (if (or (not v) (jolt-nil? v))
                          #f
                          (let ((n (guard (e (#t #f)) (exact (jolt-need-num v)))))
                            (if (and (integer? n) (> n 0)) n
                                (throw-jvm (quote IllegalArgumentException)
                                  (string-append "process-scope: " who
                                    " must be a positive integer byte bound"))))))))
        (when (null? cmd)
          (throw-jvm (quote IllegalArgumentException)
            "process-scope: :cmd must not be empty"))
        (unless (and timeout-ms (> (jnum->exact timeout-ms) 0))
          (throw-jvm (quote IllegalArgumentException)
            "process-scope: :timeout-ms (positive milliseconds) is required"))
        (let ((timeout-n (jnum->exact timeout-ms))
              (grace-n (max 0 (jnum->exact grace-ms)))
              (dir-s (and dir (not (jolt-nil? dir)) (jolt-str-render-one dir)))
              (out-n (cap-n ":out-bytes" out-bytes))
              (err-n (cap-n ":err-bytes" err-bytes)))
          (when (and dir-s (not proc-sc-fa-addchdir))
            (throw-jvm (quote UnsupportedOperationException)
              "process-scope: :dir needs posix_spawn_file_actions_addchdir_np (glibc 2.29+)"))
          (let* ((eff-dir (if dir-s (project-relative dir-s) (proc-effective-dir #f)))
                 (prog (jolt-str-render-one (car cmd)))
                 (path (proc-sc-resolve-program prog eff-dir)))
            (unless path
              (throw-jvm (quote java.io.IOException)
                (string-append "process-scope: cannot run program \""
                               prog "\": error=2, No such file or directory")))
            (proc-ensure-reapable!)
            ;; argv[0] is the caller's own spelling (what ps shows), exactly as
            ;; ProcessBuilder passes cmdarray through; only the exec PATH is
            ;; the resolved one. envp NULL = inherit, no marshalling needed.
            ;; The env pairs render FIRST — jolt-str-render-one on a bad map
            ;; value can throw, and nothing foreign is allocated yet.
            (let* ((env-pairs (and env-map (not (jolt-nil? env-map))
                                   (map (lambda (e)
                                          (string-append
                                            (jolt-str-render-one (jolt-nth e 0)) "="
                                            (jolt-str-render-one (jolt-nth e 1))))
                                        (seq->list (jolt-seq env-map)))))
                   (argv (proc-marshal-argv cmd))
                   (envp (and env-pairs (proc-marshal-argv env-pairs)))
                   (out-cap (and out-n (proc-sc-cap-make out-n)))
                   (err-cap (and err-n (proc-sc-cap-make err-n)))
                   ;; the REQUESTED captures, absent ones simply left out
                   (caps (append (if out-cap (list out-cap) '())
                                 (if err-cap (list err-cap) '())))
                   (fa (sa-foreign-alloc 128))
                   ;; glibc's posix_spawnattr_t is 336 bytes (probed:
                   ;; sizeof — two 128-byte sigsets plus fields); musl's is
                   ;; the same shape (its spawn.h shows flags/pgrp + two
                   ;; sigset_t + sched fields + pad). 512 covers both with
                   ;; margin; init writes the real size, destroy reads it.
                   (attr (sa-foreign-alloc 512))
                   (pidbuf (sa-foreign-alloc 8))
                   (pid
                     ;; pipe() through posix_spawn under the same exclusion
                     ;; the unscoped fd-level spawn uses: a capture pipe is
                     ;; exactly the no-pipe2()/O_CLOEXEC window that mutex
                     ;; exists to close (see proc-spawn-fd-mutex above).
                     ;; spawned? flips only on a successful posix_spawn; the
                     ;; dynamic-wind after-part uses it to fail CLOSED on
                     ;; every earlier throw (pipe() under fd exhaustion, a
                     ;; failed file action) — no run loop will ever exist to
                     ;; close those pipes, so the after-part closes them.
                     (let ((spawned? (box #f)))
                       (jolt-with-mutex proc-spawn-fd-mutex
                         (dynamic-wind
                           (lambda () #f)
                           (lambda ()
                             (when out-cap
                               (let ((p (proc-sc-mkpipe)))
                                 (proc-sc-cap-rfd! out-cap (car p))
                                 (proc-sc-cap-wfd! out-cap (cdr p))))
                             (when err-cap
                               (let ((p (proc-sc-mkpipe)))
                                 (proc-sc-cap-rfd! err-cap (car p))
                                 (proc-sc-cap-wfd! err-cap (cdr p))))
                             (proc-sc-check-rc! "posix_spawn_file_actions_init" (proc-fa-init fa))
                             ;; stdin is /dev/null ALWAYS — the capture
                             ;; contract has no stdin side.
                             (proc-sc-check-rc! "posix_spawn_file_actions_addopen (stdin)"
                               (proc-sc-fa-addopen fa 0 "/dev/null" proc-sc-O-RDWR 0))
                             ;; stdout: the capture pipe's write end, or the
                             ;; /dev/null default for callers not requesting it
                             (if out-cap
                                 (begin
                                   (proc-sc-check-rc! "posix_spawn_file_actions_adddup2 (stdout)"
                                     (proc-fa-dup2 fa (proc-sc-cap-wfd out-cap) 1))
                                   (proc-sc-check-rc! "posix_spawn_file_actions_addclose (stdout)"
                                     (proc-fa-close fa (proc-sc-cap-wfd out-cap)))
                                   (proc-sc-check-rc! "posix_spawn_file_actions_addclose (stdout read end)"
                                     (proc-fa-close fa (proc-sc-cap-rfd out-cap))))
                                 (proc-sc-check-rc! "posix_spawn_file_actions_addopen (stdout)"
                                   (proc-sc-fa-addopen fa 1 "/dev/null" proc-sc-O-RDWR 0)))
                             (if err-cap
                                 (begin
                                   (proc-sc-check-rc! "posix_spawn_file_actions_adddup2 (stderr)"
                                     (proc-fa-dup2 fa (proc-sc-cap-wfd err-cap) 2))
                                   (proc-sc-check-rc! "posix_spawn_file_actions_addclose (stderr)"
                                     (proc-fa-close fa (proc-sc-cap-wfd err-cap)))
                                   (proc-sc-check-rc! "posix_spawn_file_actions_addclose (stderr read end)"
                                     (proc-fa-close fa (proc-sc-cap-rfd err-cap))))
                                 (proc-sc-check-rc! "posix_spawn_file_actions_addopen (stderr)"
                                   (proc-sc-fa-addopen fa 2 "/dev/null" proc-sc-O-RDWR 0)))
                             (when dir-s
                               (proc-sc-check-rc! "posix_spawn_file_actions_addchdir_np"
                                 (proc-sc-fa-addchdir fa dir-s)))
                             (proc-sc-check-rc! "posix_spawnattr_init" (proc-sc-attr-init attr))
                             (proc-sc-check-rc! "posix_spawnattr_setpgroup" (proc-sc-attr-setpgroup attr 0))
                             (proc-sc-check-rc! "posix_spawnattr_setflags (POSIX_SPAWN_SETPGROUP)"
                               (proc-sc-attr-setflags attr proc-sc-POSIX-SPAWN-SETPGROUP))
                             (let ((rc (jolt-with-empty-sigmask
                                         (lambda ()
                                           (proc-c-spawn pidbuf path fa attr
                                             (car argv) (if envp (car envp) 0))))))
                               (let ((p (sa-foreign-ref 'int pidbuf 0)))
                                 (if (= rc 0)
                                     (begin
                                       ;; the parent keeps ONLY the read ends:
                                       ;; its own write-end copies close now,
                                       ;; inside the excluded window — held any
                                       ;; longer, EOF on the read side would
                                       ;; never become decidable.
                                       (when out-cap
                                         (proc-c-close (proc-sc-cap-wfd out-cap))
                                         (proc-sc-cap-wfd! out-cap -1))
                                       (when err-cap
                                         (proc-c-close (proc-sc-cap-wfd err-cap))
                                         (proc-sc-cap-wfd! err-cap -1))
                                       (set-box! spawned? #t)
                                       p)
                                     (begin
                                       ;; failed spawn: no run loop will own
                                       ;; these pipes — close every end we made
                                       (proc-sc-cap-abort! out-cap)
                                       (proc-sc-cap-abort! err-cap)
                                       (throw-jvm (quote java.io.IOException)
                                         (string-append "process-scope: posix_spawn failed (errno "
                                                        (number->string rc) ")")))))))
                           (lambda ()
                             ;; an EARLIER throw (pipe/file-action failure)
                             ;; never reaches the spawn's own cleanup — the
                             ;; pipes close here instead. After a successful
                             ;; spawn the wfds are -1 and the rfds belong to
                             ;; the run loop, so this is a no-op there.
                              (unless (unbox spawned?)
                                (proc-sc-cap-abort! out-cap)
                                (proc-sc-cap-abort! err-cap))
                              (proc-fa-destroy fa) (proc-sc-attr-destroy attr)
                              (sa-foreign-free fa) (sa-foreign-free attr)
                              (sa-foreign-free pidbuf)
                              (proc-free-argv argv)
                              (when envp (proc-free-argv envp))))))))
               ;; The group is the scope and its id is the root's pid: pgroup 0
               ;; + SETPGROUP makes the child its own group leader before exec
              ;; (probed), so no grandchild can pre-date the group the way a
              ;; parent-side setpgid race would allow.
              (let ((pgid pid))
                (let ((deadline (+ (jolt-mono-nanos) (* timeout-n 1000000)))
                      (scratch (sa-foreign-alloc proc-sc-cap-chunk)))
                  (let ((finish!
                          ;; shared exit path: escalate, confirm, drain what
                          ;; the killed writers left, answer. decoded is the
                          ;; reaped status when the root was waited; otherwise
                          ;; proc-sc-reap-root reconstructs it from the
                          ;; strongest evidenced signal. timed-out? is
                          ;; STRICTLY the controller clock — an overflow abort
                          ;; passes #f and the :truncated status says why.
                          (lambda (decoded timed-out?)
                            (let ((sent (proc-sc-escalate! pid pgid grace-n)))
                              (proc-sc-confirm-empty! pid pgid)
                              ;; the scope is confirmed empty: every writer
                              ;; the nets caught is dead, so EOF on the
                              ;; capture pipes is now decidable — drain the
                              ;; kernel's remainder (bounded in time; a
                              ;; net-escaping writer leaves :partial, not a
                              ;; hang)
                              (proc-sc-final-drain! caps scratch)
                              (apply jolt-hash-map
                                (append
                                  (list (jolt-keyword "pid") pid
                                        (jolt-keyword "exit")
                                        (or decoded (proc-sc-reap-root pid sent))
                                        (jolt-keyword "timed-out") timed-out?)
                                  (apply append
                                    (map proc-sc-cap-rows
                                      (list (cons out-cap "out")
                                            (cons err-cap "err"))))))))))
                    (dynamic-wind
                      (lambda () #f)
                      (lambda ()
                        (let loop ()
                          (call-with-values (lambda () (proc-waitpid-once pid #t))
                            (lambda (rc decoded err)
                              (cond
                                ;; root exited on its own — the scope may still
                                ;; hold its workers; escalation is a no-op when
                                ;; it does not (the entry scan finds nothing to
                                ;; signal).
                                (decoded (finish! decoded #f))
                                ;; timed out: TERM the group, grace, KILL,
                                ;; confirm. sent is the strongest signal
                                ;; DELIVERY was evidenced for — 0 if the scope
                                ;; quieted before any wave landed, and the
                                ;; unwaitable-root fallback claims no more
                                ;; than that.
                                ((and (>= (jolt-mono-nanos) deadline)
                                      (or (= rc 0) (= err proc-EINTR)))
                                 (finish! #f #t))
                                ;; ECHILD before any exit we saw: someone else
                                ;; reaped the root (SIGCHLD=SIG_IGN set after
                                ;; our restore). The scope answer is the same.
                                ((and (< rc 0) (not (= err proc-EINTR)))
                                 (finish! #f #f))
                                ;; capture overflow: the SAME escalation and
                                ;; the SAME no-live-scope confirmation a
                                ;; timeout gets — but the clock did not fire,
                                ;; so :timed-out stays false and the
                                ;; overflowing stream's :truncated says why.
                                ((or (proc-sc-cap-overflow? out-cap)
                                     (proc-sc-cap-overflow? err-cap))
                                 (finish! #f #f))
                                (else
                                  ;; the wait step doubles as the drain step:
                                  ;; poll the live capture pipes with the same
                                  ;; 10ms cadence (level-triggered readiness
                                  ;; turns a flood into a tight drain loop),
                                  ;; or take the plain pause there always was
                                  ;; when no capture is live.
                                  (if (exists proc-sc-cap-live? caps)
                                      (proc-sc-poll-drain! caps scratch 10)
                                      (jolt-pause-ms 10))
                                  (loop)))))))
                      (lambda ()
                        ;; every exit path — return, timeout, overflow, or the
                        ;; survivors exception — closes the capture fds before
                        ;; the scratch buffer goes away under them
                        (for-each proc-sc-cap-close! caps)
                        (sa-foreign-free scratch)))))))))))))

(def-var! "jolt.host" "process-scope-run" proc-scope-run)

;; --- CompletableFuture (Process.onExit().thenRun(f)) -------------------------
;; A minimal one-shot: thenRun spawns a thread that waits for the process to exit
;; and then runs the callback. Enough for babashka's :shutdown / :exit-fn hooks.
(define (make-proc-completable proc-st) (make-jhost "jolt-completable" proc-st))
(register-host-methods! "jolt-completable"
  (list (cons "thenRun" (lambda (self f)
          (let ((proc-st (jhost-state self)))
            (fork-thread (lambda () (guard (e (#t #f)) (proc-wait-blocking proc-st) (jolt-invoke f)))))
          self))
        (cons "thenApply" (lambda (self f) self))))

;; --- java.lang.Runtime shutdown hooks ----------------------------------------
;; addShutdownHook registers a Thread hook to run at jolt exit; babashka.process's
;; `:shutdown` option registers one to kill the child if jolt dies mid-run.
;; The registry, the runner and the SIGTERM/SIGHUP watcher all live in
;; concurrency.ss — these are the JVM-shaped door onto them.
(define the-jolt-runtime (make-jhost "jolt-runtime" #f))

;; A String[] / collection of strings -> a Scheme list of strings; a lone String
;; is whitespace-split (Runtime.exec(String) tokenizes on whitespace).
(define (proc-strings->list x)
  (if (string? x)
      (filter (lambda (s) (> (string-length s) 0))
              (str-literal-split x " "))
      (map jolt-str-render-one (seq->list (jolt-seq x)))))
;; envp: a String[] of "K=V" -> a fully-specified env-map (no parent seed), so it
;; reproduces exactly the given environment (Runtime.exec envp semantics).
(define (make-proc-env-from-strings envp)
  (let ((h (make-hashtable string-hash string=?)))
    (for-each (lambda (kv)
                (let* ((s (jolt-str-render-one kv))
                       (eq (let scan ((i 0))
                             (cond ((= i (string-length s)) #f)
                                   ((char=? (string-ref s i) #\=) i)
                                   (else (scan (+ i 1)))))))
                  (when eq (hashtable-set! h (substring s 0 eq) (substring s (+ eq 1) (string-length s))))))
              (seq->list (jolt-seq envp)))
    (make-jhost "jolt-env-map" h)))

;; Runtime.exec(cmdarray [envp [dir]]): the classic spawn API clojure.java.shell
;; uses. envp/dir may be nil (inherit / cwd). Returns a Process.
(define (proc-runtime-exec args)
  (let* ((cmd  (proc-strings->list (car args)))
         (envp (and (pair? (cdr args)) (cadr args)))
         (dir  (and (pair? (cdr args)) (pair? (cddr args)) (caddr args)))
         (pb   (make-proc-builder cmd)))
    (when (and envp (not (jolt-nil? envp))) (proc-pb-set! pb 1 (make-proc-env-from-strings envp)))
    (when (and dir  (not (jolt-nil? dir)))  (proc-pb-set! pb 2 (file-path-of dir)))
    (proc-pb-start pb)))

(register-host-methods! "jolt-runtime"
  (list (cons "addShutdownHook"
          (lambda (self hook)
            (jolt-register-shutdown-hook! hook
              (lambda () (let ((body (jolt-thread-body hook))) (when body (jolt-invoke body)))))
            jolt-nil))
        (cons "removeShutdownHook"
          (lambda (self hook) (jolt-remove-shutdown-hook! hook)))
        (cons "availableProcessors" (lambda (self) (->num (jolt-available-processors))))
        ;; The memory trio, over Chez's own heap accounting: current-memory-bytes
        ;; is what the collector has reserved from the OS (the JVM's totalMemory)
        ;; and bytes-allocated is what is live inside it, so free is the
        ;; difference. maxMemory is unbounded here — Chez grows the heap on demand
        ;; with no configured ceiling — and Long/MAX_VALUE is what the JVM reports
        ;; for exactly that case. criterium reads all four for its report, and
        ;; without them a benchmark namespace crashes rather than running.
        (cons "totalMemory" (lambda (self) (->num (sa-total-memory-bytes))))
        (cons "freeMemory"
          (lambda (self) (->num (max 0 (- (sa-total-memory-bytes) (sa-bytes-allocated))))))
        (cons "maxMemory" (lambda (self) (->num 9223372036854775807)))
        ;; Runtime.gc routes to System/gc on the JVM, so it gets the same guarded
        ;; hint semantics — Chez's collect refuses while multiple threads are live,
        ;; and neither of these ever throws on the JVM.
        (cons "gc" (lambda (self)
                     (guard (e (#t #f)) (sa-gc-collect))
                     jolt-nil))
        ;; No finalizers on this host, so running them is genuinely a no-op — which
        ;; is also all the JVM promises (a hint, deprecated for removal since 18).
        (cons "runFinalization" (lambda (self) jolt-nil))
        (cons "exec" (lambda (self . args) (proc-runtime-exec args)))))
(register-class-statics! "java.lang.Runtime" (list (cons "getRuntime" (lambda () the-jolt-runtime))))

;; instance? and (class x) for the ProcessBuilder / Process / Redirect shims are
;; DERIVED from the jhost-tag->fqn rows in class-hierarchy.ss (via the arms in
;; host-static-classes.ss) — no per-class instance-check arm here.
