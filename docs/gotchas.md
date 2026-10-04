# Gotchas

Symptom → cause → fix, numbered; new ones go at the end and keep the numbering. Gotchas
inherited with code moved from another library point to their number there (e.g.
"pascal-db-faa gotcha 1").

## 1. FPC 32-bit: `Identifier not found "InterLockedIncrement64"`

**Symptom.** A unit that compiles on FPC x86_64 fails on FPC i386 (Win32, Linux-32) with
`Identifier not found "InterLockedIncrement64"` (likewise `InterLockedExchangeAdd64`,
`InterLockedExchange64`, `InterlockedCompareExchange64`). Measured 2026-10-04 on FPC 3.2.2 i386
(Debian bookworm) with `PascalDb.Threading`; the `*64` atomics in `Pipes/AMQP/Redis.Threading`
use the same functions.

**Cause.** FPC 3.2.2 declares the 64-bit `InterLocked*` functions only inside `{$ifdef cpu64}`
in `rtl/inc/systemh.inc`. i386 implements a 64-bit compare-exchange in `rtl/i386/i386.inc` but
doesn't export it. Delphi Win32 has no such gap: `AtomicCmpExchange` and friends accept `Int64`.

**Fix.** `PascalCommon.Threading` routes the 64-bit operations through one critical section on
FPC when `CPU64` is not defined (`PASCALCOMMON_ATOMIC64_LOCK`). Correct as long as every access
to the variable goes through `PcAtomic*64`. `tools/ci-test.sh` runs the suite on i386 too, so
that path is compiled and tested.

## 2. lazbuild builds against a different copy of a package, silently

**Symptom.** A project that requires `pascal_common_faa_jsonmapper` builds and its tests pass,
but the build log shows the mapper compiled from another folder (the `-Fu` of a separate
checkout's `packages/lib`), not from the project's own `external/` copy. Measured 2026-10-04
with lazbuild 4.0 / FPC 3.2.2 on Windows, in the pascal-db-faa pilot (F6) and in this
repository's own unit tests. Only the Docker builds, which pass `-Fu` by hand, used the
submodule.

**Cause.** When lazbuild resolves a required package, one registered in the IDE
(`packagefiles.xml`) wins over a `DefaultFilename` without `Prefer`, and a `DefaultFilename` that
doesn't exist falls back to the registered one without a word. The bridge's `.lpk` pointed the
mapper at `external/pascal-jsonmapper-faa`, which doesn't exist in a consumer (submodules are not
checked out recursively).

**Fix.** The bridge's `.lpk` requires `pascaljsonmapper_pkg` by name only. Each project lists the
copy it wants, with `DefaultFilename` and `Prefer="True"`, before the packages that need it. This
repository's test `.lpi` does that for `pascal_common_faa`, the mapper and the bridge, and
`docs/migrating.md` (steps 3 and 4) gives consumers the same rule. When in doubt, check the paths
in the build log.

## 3. `sed -i` turns CRLF into LF on Git for Windows

**Symptom.** After a rename with `sed -i` in Git Bash, every file passed to it has LF line
endings, including the files where nothing matched. With `core.autocrlf=true`, `git diff` shows
no content change, but the working copy differs from a fresh checkout, and git warns "LF will be
replaced by CRLF" for each file. Reported by the pascal-named-pipes-faa migration (F8), and
reproduced here 2026-10-04: a CRLF file with no match comes out with no CR.

**Cause.** The `sed` that ships with Git for Windows; not investigated further. The same files
run through `perl -pi` keep their CRs (measured in the same reproduction).

**Fix.** Use `perl -pi -e` with the same regex (`\b` works; write `$1` instead of `\1`): it keeps
the line endings. `docs/migrating.md` uses it. If `sed -i` already ran, `git checkout --` the files
with no real change.

## 4. Delphi: `E2029 Declaration expected but 'FINALIZATION' found`

**Symptom.** A unit with a `finalization` section and no `initialization` compiles on FPC 3.2.2,
but Delphi rejects it with `E2029 Declaration expected but 'FINALIZATION' found`. Reported by the
pascal-named-pipes-faa migration (F8), which copied the idea of
`PascalCommon.ThreadPoolTests`' finalization check into a unit of its own.

**Cause.** Delphi only accepts `finalization` after an `initialization` section. FPC also allows
it on its own.

**Fix.** Give the unit an `initialization` section, even an empty one. `PascalCommon.ThreadPoolTests`
has one because it registers its fixture there.

