# Windows toolchains and validation lanes

This note records why the current self-contained Windows `joltc` build uses
MSYS2/MinGW, what that does and does not imply, and which Windows tests can run
without changing the packager. It describes the `casselc/jolt` proposal fork;
it is not an upstream acceptance or release claim.

## The current constraint is inherited, not fundamental

The self-contained packager was designed upstream around one GNU-style build
contract:

- `host/chez/build-joltc.ss` invokes the compiler named by `bld-cc`;
- the Chez kernel input is named `libkernel.a`;
- `scheme.h`, the boot files, and `libkernel.a` are embedded in packaged
  `joltc`; and
- a later `joltc build` can spill those files and relink the launcher with
  static native dependencies.

The relevant upstream history is:

| Commit | Upstream change |
| --- | --- |
| `242eeac5` | Build `joltc` as a self-contained binary. |
| `d79ad6dc` | Static-link native C libraries into built binaries. |
| `b2aa757a` | Add Windows x86_64 release binaries through MSYS2/MinGW. |
| `6bd06ef4` | Productize cross-compilation. |

All four commits are ancestors of the current upstream baseline. In particular,
`b2aa757a` says explicitly that Windows uses Chez 10.4.1 `ta6nt`, built from
source under MSYS2/MinGW, and the same `build-joltc` flow as the other targets.
The proposal fork did not introduce this choice.

Cisco's packaged Chez 10.4.1 Windows installer is therefore not "deficient."
It is an Intel/MSVC distribution, while the current Jolt packager expects a
GNU compiler command, GNU archive naming and format (`libkernel.a`), and GNU
linker flags. These are different toolchain contracts.

The installed package makes that distinction concrete. Its `ta6nt` development
directory contains `scheme.h`, `csv1041md.lib`, `csv1041mt.lib`, `mainmd.obj`,
`mainmt.obj`, and the boot files. It does not contain `libkernel.a`. Those are
the correct MSVC inputs, not a partial GNU installation.

This is also not an inherent Chez or Jolt limitation. Chez supports Windows
x86_64 and AArch64, and source-mode Jolt does not need to relink the Chez
kernel. The mismatch appears when Jolt packages a self-contained compiler or
uses `joltc build`, not when it loads and evaluates Jolt source.

## Current decision

Keep the known-working MinGW path for existing packaged Windows x86_64
artifacts. Do not translate an MSVC installation into a fake `libkernel.a`
layout or add one-off CI conditionals that obscure which compiler owns an
artifact.

Shared prebuilt CI toolchains do not collapse this distinction. The implemented
archive contract labels source-runtime and GNU kernel-development capabilities
separately. Windows ARM64 currently declares source-runtime only; it does not
invent an MSVC kernel-development or packaged-`joltc` claim. See
[`shared-chez-ci-toolchains.md`](shared-chez-ci-toolchains.md).

Treat support for the official Chez Windows package as a second packager
backend. The backend boundary should own at least:

- compiler and linker commands;
- kernel artifact name and format (`.a` versus `.lib`);
- compile, export, subsystem, architecture, and runtime-library flags;
- target executable and library suffixes;
- the native dependency archive contract used by `:jolt/native`;
- how the packaged compiler retains kernel inputs for a later `joltc build`;
  and
- feature detection and actionable diagnostics.

The first two implementations would be GNU/MinGW and MSVC (or `clang-cl` using
the MSVC object/library contract). This shape can also support native Windows
AArch64 without treating it as a special case of x86_64.

## Evidence lanes

Packaging, source execution, ABI facts, and real networking prove different
things and must remain separate in CI.

| Lane | What it proves | Needs the GNU `libkernel.a` packager? |
| --- | --- | --- |
| Pure/model tests under source Jolt | Target selection, parsing, state machines, buffer logic, fake transports, and fail-closed behavior on the native runtime. | No. |
| Native ABI probe | Constants, widths, `sizeof`, and `offsetof` from the target's own headers and compiler. | No. |
| Real loopback/runtime tests | Native calls, handle ownership, readiness, deadlines, EOF, shutdown, and application behavior on real sockets. | No, but it needs a socket/readiness backend for that OS. |
| Packaged-`joltc` smoke | The self-contained compiler starts without a Chez installation and preserves its host/process contracts. | Yes, with the current implementation. |
| `joltc build` smoke | A packaged compiler can compile and link another native program, including declared native libraries. | Yes, with the current implementation. |
| Release artifact test | The exact archive distributed to users runs on its target. | Yes, with the current implementation. |

Consequently, lack of an MSVC packager must not suppress useful Windows
source-mode tests. Conversely, a green parser or fake-transport suite must not
be reported as Winsock support.

## Library CI target

Until `jolt.net` has a Windows readiness backend, use the following split:

| Target | `jolt-net` | `jolt-tcp` | `jolt-http` | `jolt-hegel` |
| --- | --- | --- | --- | --- |
| Linux x86_64 | ABI probe and full real-socket suite | Full real-loopback suite | Full real-loopback suite | Full native suite |
| Linux AArch64 | ABI probe and full real-socket suite | Full real-loopback suite | Full real-loopback suite | Full native suite |
| macOS AArch64 | ABI probe and full real-socket suite | Full real-loopback suite | Full real-loopback suite | Full native suite |
| macOS x86_64 | ABI probe and full real-socket suite | Full real-loopback suite | Full real-loopback suite | Full native suite by building exact upstream `libhegel` 0.30.1 source; there is still no downloadable Darwin x86_64 asset |
| Windows x86_64 | ABI probe; source-mode target/address tests; readiness must fail closed | Source-mode client models and buffer properties; production namespaces load; readiness must fail closed | Source-mode parser/body/fake-transport suites; production dependency graph loads | Full native suite |
| Windows AArch64 | Native MSVC ABI probe plus source-mode target/address tests; readiness must fail closed | Source-mode client models and buffer properties | Source-mode parser/body/fake-transport suites | Full native suite using the published Windows ARM64 asset |

The POSIX jobs are configured to exercise real sockets on every supported
readiness target.
Windows portable jobs deliberately exclude real-loopback groups until
`jolt.net` implements and validates Winsock initialization, nonblocking mode,
readiness/completion, wakeup, connect completion, and socket-error retrieval.

Windows ARM64 uses the `windows-11-vs2026-arm` runner and Chez's supported
`build.bat tarm64nt /only` path. The ABI probe must be compiled explicitly with
the ARM64 MSVC environment. The runner also exposes an x86_64 MinGW `gcc` under
emulation; auto-selecting that compiler would generate a plausible but false
x86_64 descriptor. While that runner image remains in public preview, its jobs
are initially evidence-producing/non-gating and should be promoted after a
stable green history.

## Native Windows validation snapshot

On 2026-07-24 the official Cisco/MSVC Chez 10.4.1 install at
`C:\Program Files\Chez Scheme 10.4.1` was exercised directly from the proposal
fork:

- `scheme.exe --version` reported 10.4.1 and `(machine-type)` reported `ta6nt`;
- the source launcher found the official `scheme` executable without requiring
  a distribution-specific `chez` or `chezscheme` alias;
- source Jolt evaluated `(+ 1 2)` to `3`;
- the target descriptor characterization passed 33/33;
- the packaged-POSIX-shell regression passed with a `TEMP` path containing a
  space; and
- the complete source core unit gate passed 1087/1087.

Those native runs found four real Windows gaps before reaching green:

1. Chez `rename-file` is backed by `_wrename`, which cannot replace an existing
   destination. The fork now centralizes single-operation, same-volume replacement through
   `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING` and `MOVEFILE_WRITE_THROUGH`
   for overwrite `spit`, file-to-file NIO `Files/move`, AOT-cache publication,
   and dev-boot publication. `WRITE_THROUGH` is not claimed as a proved
   power-loss durability or fsync guarantee.
2. `System/getenv()` enumerated the environment by launching POSIX `env -0`.
   The fork now uses `GetEnvironmentStringsW` and
   `FreeEnvironmentStringsW`, preserving Unicode and removing a hidden MSYS
   runtime dependency.
3. `java.io.tmpdir`, `File/createTempFile`, and NIO temp creation assumed
   `TMPDIR` or `/tmp`. They now prefer `TMPDIR`, then native Windows `TEMP` or
   `TMP`, through one shared runtime helper. The add-deps fixture creates its
   directory through `java.nio.file.Files` instead of passing a native Windows
   path through POSIX shell syntax.
4. `user.home` and the default AOT-cache root assumed `HOME`. Native Windows
   now falls back to `USERPROFILE`, while MSYS/POSIX behavior remains unchanged.

The native shell launcher also requires an outer pair of `cmd.exe /c` quotes
around its already token-quoted `sh.exe` and script paths. The regression suite
covers paths with spaces, metacharacters, compound POSIX syntax, and nonzero
exit propagation.

## Local Windows evidence that is most useful

The most useful local x86_64 setup has both of these lanes:

1. Cisco's packaged Chez 10.4.1, to characterize the official MSVC/source-mode
   layout without pretending it satisfies the GNU packager.
2. MSYS2 `MINGW64` with Chez 10.4.1 built from source, matching current Windows
   CI and release packaging.

Install Git for Windows so `C:/Program Files/Git/bin/sh.exe` is present. For the
MinGW lane install MSYS2 packages `git`, `make`, `vim` (for `xxd`),
`mingw-w64-x86_64-gcc`, `mingw-w64-x86_64-lz4`, and
`mingw-w64-x86_64-zlib`. Keep sibling checkouts of `jolt`, `jolt-net`,
`jolt-tcp`, `jolt-http`, and `jolt-hegel` under one ordinary Windows directory.

Build Chez in an MSYS2 **MINGW64** shell from a fresh Windows-side source tree.
Before configuring, `uname -s` must start with `MINGW64_NT` and
`gcc -dumpmachine` must report `x86_64-w64-mingw32`. Do not reuse a tree
configured or built by WSL/Linux: a stale ELF `bin/zuo` produces
`cannot execute binary file: Exec format error`. A fresh clone is the clearest
recovery; in a known-disposable tree, removing `bin/zuo` and rerunning `make`
is sufficient.

For a Scoop-managed MSYS2 installation, launching
`%USERPROFILE%\scoop\apps\msys2\current\mingw64.exe` selects this environment;
the `uname` and compiler-target probes above remain the authoritative checks.

Do not run native Windows `make install` after the MinGW build. Chez 10.4.1's
own `makefiles/install.zuo` says that installer relies on Unix utilities and is
not meant to run on Windows. Keep Cisco's packaged installer as the normal
source-mode installation and stage the MinGW build products explicitly for
Jolt packaging: executables and boot files in one `bin` directory, plus boot
files, `scheme.h`, and `libkernel.a` in the directory named by
`JOLT_CHEZ_CSV`. This is the same boundary used in CI. An install destination
named `csv10.5.0-pre-release.1` is conclusive stale-tree evidence when the
intended source tag is 10.4.1.

For an interactive validation handoff, record:

- the checkout root;
- `where.exe scheme`, `where.exe chez`, `where.exe gcc`, and `where.exe cl`;
- `scheme --version` or `chez --version`;
- the Chez machine type;
- the exact `JOLT_CHEZ` executable selected for fresh compile passes;
- the path containing the Chez boot files and kernel development artifacts;
- the Git-for-Windows `sh.exe` path; and
- whether WSL can invoke the Windows executables and access the checkout under
  `/mnt/c/...`.

Use fresh `JOLT_GITLIBS` and `GITLIBS` roots when validating dependency-cache
behavior for a new core/library revision. Put `TEMP` and `TMP` under a path
containing a space for the host-shell smoke. Preserve the complete command log
and the HTTP progress log when a bounded test times out; redirected Jolt output
may otherwise remain buffered until process exit.

When driving Win32 executables from a WSL checkout, a UNC current directory is
not a valid `cmd.exe` current directory. Use `cmd.exe /c "pushd
\\wsl.localhost\...\jolt && ..."` to map it temporarily, or keep a native
Windows checkout. Variables passed from WSL to Win32 must be named in `WSLENV`
with the `/w` direction flag; for example,
`WSLENV=HOME/w:JOLT_SH/w:TEMP/w:TMP/w`.

The highest-value local sequence is:

1. run source `jolt/bin/joltc` with the official Chez installation;
2. run the core Windows path and POSIX-shell characterization tests;
3. build and smoke the MinGW packaged `joltc`;
4. run the transactional Git-dependency suite with that packaged binary;
5. install/fetch `libhegel` through the public library API;
6. run the `jolt-net`, `jolt-tcp`, and `jolt-http` Windows portable selections;
   and
7. retain failures and generated counterexamples as artifacts.

Real Windows TCP/HTTP loopback tests become the next gate once the Windows
`jolt.net` backend exists; before then, enabling them would test an unsupported
implementation rather than increase coverage.
