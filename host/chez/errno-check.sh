#!/bin/sh
# errno-check.sh — whole-tree gate: an FFI consumer must capture a syscall's
# native error ATOMICALLY, at the syscall, not by making a SEPARATE foreign
# call to read the ambient errno/GetLastError slot afterward.
#
# WHY THIS GATE EXISTS. errno survives only until the next thing that can set
# it, and reading it is itself a foreign call: jolt.ffi/errno is __error /
# __errno_location, process.ss's own former proc-errno was the same shape, and
# an allocation or runtime/native work on the same thread on the way to either
# can leave a completely different code behind. Two questions about one syscall --
# (eintr?) and then (eagain?), or a syscall's result checked and then a
# separate errno read -- can therefore get answers about TWO DIFFERENT
# failures. That is not theoretical:
#
#   - stdlib/jolt/socket.clj's io-call did exactly that. Under CPU load,
#     recv's EAGAIN read back as ENOMEM often enough to matter: the retry
#     branch was missed, the -1 fell through, and do-recv answered EOF on a
#     live connection. Measured 13 of 60 runs under load.
#   - host/chez/java/process.ss's proc-waitpid-once, and its pipe pump loops,
#     read errno the same separate way after waitpid/read/write.
#
# THE FIX (jolt-9wt2 / #51 #52): every syscall wrapper that needs its error
# now uses atomic capture — {:capture-native-error true} on a jolt.ffi defcfn
# (stdlib/jolt/socket.clj), or jolt-foreign-proc-native-error-safe /
# jolt-ffi-native-error-procedure at the raw Scheme level (host/chez/rt.ss;
# host/chez/java/process.ss, io.ss). Both return [result error-code] (or the
# Scheme two-value equivalent) from the SAME foreign-call return path the
# syscall used, so the value can never be asked for a second time.
#
# THIS GATE keeps that fixed. Two things done ONCE, at the syscall site, must
# never recur in the reviewed production source roots outside the small set of
# files that define the primitives. This is intentionally a lexical gate; the
# compiler/effect layer is the later home for alias- and dataflow-aware proof.
#   (1) a bare (0-arg) ambient-error READ in Clojure: (poller/errno),
#       (poller/eagain?), (poller/eintr?), (ffi/errno) — the value-taking
#       arities exist for exactly this reason (io_poller.clj's own doc
#       comment): a caller with the value already in hand branches on IT, not
#       on a fresh read.
#   (2) a NEW manually-resolved errno/GetLastError accessor in a Scheme host
#       file under host/chez/java/ ("__error" / "__errno_location" /
#       "GetLastError" dlsym'd via jolt-foreign-proc-safe) — the sanctioned
#       path there is jolt-foreign-proc-native-error-safe, which composes the
#       same fail-closed symbol lookup with call-boundary capture.
#
# Exempt (they DEFINE the primitives, or deliberately exercise the unsafe
# shape to prove the vulnerability class in a test): stdlib/jolt/io_poller.clj,
# stdlib/jolt/ffi.clj, host/chez/rt.ss, host/chez/scheme-adapter-runtime.ss,
# and anything under test/.
#
#   sh host/chez/errno-check.sh
set -eu
cd "$(dirname "$0")/../.."

bad=0

# -- (1) Clojure: a bare ambient-error read outside its own definition -------
clj_files=$(rg --files stdlib -g '*.clj' \
  -g '!stdlib/jolt/io_poller.clj' -g '!stdlib/jolt/ffi.clj')
for f in $clj_files; do
  hits=$(grep -nE '\(poller/errno\)|\(poller/eagain\?\)|\(poller/eintr\?\)|\(ffi/errno\)' "$f" || true)
  if [ -n "$hits" ]; then
    echo "errno-check: $f reads errno a second time (a bare, value-less read)"
    echo "             instead of branching on the value a capturing binding"
    echo "             already returned at the syscall:"
    echo "$hits" | sed 's/^/             /'
    bad=1
  fi
done

# -- (2) Scheme host/chez/java/*.ss: no native-error accessor symbol --------
ss_files=$(rg --files host/chez/java -g '*.ss')
for f in $ss_files; do
  hits=$(grep -nE '"(__error|__errno_location|_errno|GetLastError|WSAGetLastError)"|\(proc-errno\)' "$f" || true)
  if [ -n "$hits" ]; then
    echo "errno-check: $f reads or resolves an ambient native-error accessor"
    echo "             instead of jolt-foreign-proc-native-error-safe, which"
    echo "             captures the same slot atomically at the call:"
    echo "$hits" | sed 's/^/             /'
    bad=1
  fi
done

# -- self-test: the scanner must actually catch what it claims to -----------
probe_clj=$(mktemp)
probe_ss=$(mktemp)
trap 'rm -f "$probe_clj" "$probe_ss"' EXIT HUP INT TERM
printf '%s\n' '(poller/errno)' '(poller/eagain?)' '(poller/eintr?)' '(ffi/errno)' > "$probe_clj"
printf '%s\n' '"__error"' '"__errno_location"' '"_errno"' '"GetLastError"' '"WSAGetLastError"' '(proc-errno)' > "$probe_ss"
if [ "$(grep -cE '\(poller/errno\)|\(poller/eagain\?\)|\(poller/eintr\?\)|\(ffi/errno\)' "$probe_clj" || true)" -ne 4 ]; then
  echo "errno-check: self-test failed (Clojure pattern did not match its own probe)" >&2
  exit 1
fi
if [ "$(grep -cE '"(__error|__errno_location|_errno|GetLastError|WSAGetLastError)"|\(proc-errno\)' "$probe_ss" || true)" -ne 6 ]; then
  echo "errno-check: self-test failed (Scheme pattern did not match its own probe)" >&2
  exit 1
fi

if [ "$bad" -ne 0 ]; then exit 1; fi
echo "errno-check: no ambient native-error re-read outside the capturing primitives"
