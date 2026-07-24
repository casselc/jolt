# Windows absolute-path invariants

Jolt's source launcher changes its process directory to the Jolt checkout and
preserves the caller's project directory in `JOLT_PWD`. Every filesystem path
that is already absolute must therefore pass through unchanged:

```text
absolute(path)  =>  project-relative(path) = path
relative(path)  =>  project-relative(path) = JOLT_PWD + "/" + path
```

The former implementation recognized only a leading `/`. On Windows,
`D:/a/project/deps.edn` existed when `jolt.deps` probed it, but `slurp` treated
the same string as relative and tried to open
`D:/a/project/D:/a/project/deps.edn`. Source-mode projects consequently failed
before their `deps.edn` could be parsed.

The shared host predicate now recognizes:

- `/rooted` on every host;
- `C:/rooted` and `C:\rooted` on Windows;
- Windows root/UNC paths beginning with `\`; and
- not `C:drive-relative`, which remains relative like `java.io.File`.

`project-relative`, `java.io.File.isAbsolute`, `java.nio.file.Path.isAbsolute`,
and `jolt.deps` root resolution all use this predicate. The target unit cases
assert their agreement and are exercised on each CI host. The public Hegel
consumer workflow is the end-to-end Windows witness: it launches Jolt from a
separate source checkout and resolves an absolute `JOLT_PWD/deps.edn`.
