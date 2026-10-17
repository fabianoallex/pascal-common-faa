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

## 5. FPC on Debian: heaptrc prints nothing at exit

**Symptom.** A program built with `-gh` on Linux exits without the `N unfreed memory blocks`
report, so "0 leaks" can't be observed, and a leak goes unnoticed. Reported by the
pascal-amqp-faa migration (F8): its docs said the report was the runners' last line everywhere,
and earlier Linux leak checks had never actually seen it. pascal-dfe-broker (F10) found the same:
its Linux script grepped the console and never built with `-gh`. Reproduced here 2026-10-04 on Debian
bookworm FPC 3.2.2: a program that leaks 10 bytes prints nothing and exits with 0.

**Cause.** There, heaptrc's exit report doesn't reach the console; given a log file, it is
written there. Not investigated further.

**Fix.** Run with `HEAPTRC="log=<file>"` and check the file for `0 unfreed memory blocks`, as
`tools/test_fpc_docker.sh` does. A check that only greps the console output passes on a leak.

## 6. lazbuild leaves a `packagefiles.xml` in the current folder

**Symptom.** `lazbuild <library>.lpk` run from a library's root fails with
`Broken dependency: <library> ...->pascal_common_faa (>=1.0)`, and a `packagefiles.xml` appears in
the current folder. Reported by the pascal-redis-faa migration (F8), reproduced there in an empty
folder; building a `.lpi` that resolves every package doesn't write it.

**Cause.** The library's `.lpk` requires `pascal_common_faa` by name only (`docs/migrating.md`,
step 3), so building it alone can't resolve it until the package is registered. On that broken
dependency, lazbuild writes a copy of the user's package links to the current folder.

**Fix.** Register `pascal_common_faa.lpk` in the IDE (or build through a test `.lpi` that lists it
with `Prefer="True"`), and add `/packagefiles.xml` to `.gitignore`. This repository's
`.gitignore` has it, and pipes, amqp and redis do too.

## 7. FPC outside Windows: `TThread.ProcessorCount` is always 1

**Symptom.** On Linux, `TThread.ProcessorCount` returns 1 whatever the machine has, so a default
derived from it is wrong: `PcPool`'s ceiling, documented as `max(16, 4 × cores)`, is 16 there.
Reported by pascal-amqp-faa after its v0.1.0, and measured here 2026-10-05 on Debian bookworm
FPC 3.2.2: `nproc` 12, `ProcessorCount` 1.

**Cause.** `TThread.FProcessorCount` comes from `GetCPUCount`. FPC 3.2.2 implements that only for
Windows (`rtl/win/sysos.inc`) and OS/2; everywhere else the generic version returns 1.

**Fix.** Use `PcProcessorCount` (`PascalCommon.ThreadPool`, since 1.2.0) instead of
`TThread.ProcessorCount`. On FPC for Linux it reads libc's `sysconf(_SC_NPROCESSORS_ONLN)`, measured
2026-10-05 on Debian bookworm x86_64 and i386: 12, the same as `nproc`, with or without
`--cpus=1`. It counts CPUs, not a container's quota. `TPcThreadPool`'s default ceiling uses it,
so `PcPool` has `max(16, 4 × cores)` on Linux too (48 on that machine, 16 before 1.2.0). Other FPC
targets outside Windows (macOS, the BSDs) still get the RTL's 1: their `sysconf` constants
differ and were not measured. Pass `AMaxWorkers` explicitly there when a pool needs more.


## 8. FPC: lines written under a lock still come out mixed when stdout is a file or a pipe

**Symptom.** Several threads write to the console with `Writeln`, each call inside the same
critical section, and the lines still come out cut and mixed with each other, but only when
standard output is redirected to a file or a pipe (Docker, systemd, `> log`). Measured
2026-10-06 on Debian bookworm FPC 3.2.2: 8 threads writing 2,000 lines each under one lock,
stdout to a file, 2,165 of 16,000 lines corrupted. On a terminal it doesn't show. It affected the
`SafeWriteln` of pascal-db-faa (`PascalDb.SafeLog`) and of delphi-api-infra-faa
(`Common.SafeLog`), had either been used that way on FPC.

**Cause.** On FPC, `Output` (like `Input` and `ErrOutput`) is a **threadvar** (`rtl/inc/systemh.inc`):
each thread has its own text record, with its own buffer, over the same handle. And `OpenStdIO`
(`rtl/inc/text.inc`) sets a `FlushFunc` only when the handle is a device, so for a file or a pipe
`Writeln` leaves the line in the thread's buffer. The buffer goes out when it fills (256 bytes),
in the middle of a line, whenever that thread next writes or ends: the lock around the `Writeln`
guards nothing. On Delphi, `Output` is one global with one buffer, so a lock is enough to keep
lines whole, but not to get them out (gotcha 9).

**Fix.** `Flush(Output)` inside the lock, after the `Writeln`. `Flush` always calls the
record's `InOutFunc`, whatever `FlushFunc` is. `PascalCommon.SafeLog` does this on FPC since
1.3.0 (0 corrupted lines in the same measurement), and its test captures `Output` with a
device whose `FlushFunc` does nothing, like a pipe's, so it fails on FPC without the `Flush`, on
Windows too. (A custom text device for Delphi can't leave `FlushFunc` nil, as FPC's RTL does:
Delphi calls it without checking, an access violation at address 0.) Code that redirects `Output` with `AssignFile` on FPC changes only the calling thread's.


## 9. Delphi on Windows: the last line written to a redirected stdout stays cut

**Symptom.** A Delphi console program with standard output redirected to a file or a pipe
(Docker, a service wrapper, `> log`) writes a line with `Writeln`, and the file shows it cut,
or not at all, until more output comes; if the process dies, it is lost. Seen from
pascal-api-infra-faa on Delphi 12 (Win32 and Win64): a 300-byte access-log line stayed cut at
`...,"dur` until the next one, while a shorter line before it had come out whole. On a console it
doesn't show.

**Cause.** `TextOpen` in Delphi's `System.pas` (Windows branch) sets `FlushFunc` to a no-op and
replaces it with the writing function only when `GetFileType` of the handle is
`FILE_TYPE_CHAR`, a console. `Writeln` ends with a call to `FlushFunc`, so on a file or a pipe it
flushes nothing. The text buffer (`TTextBuf`) is 128 bytes, and `_WriteBytes` writes it out each
time it fills. What reaches the handle is the output so far cut down to a multiple of 128 bytes.
Whether a given line shows up whole depends on whether a 128-byte boundary has been passed after
its end, not on its length: the short line came out whole because the long one that followed
pushed it out. (Delphi on Linux sets the writing `FlushFunc` for standard output always, so it
doesn't happen there.)

**Fix.** `Flush(Output)` after the `Writeln`. `Flush` calls the record's `InOutFunc`, not its
`FlushFunc`, so it writes on a file and a pipe too; on a console the buffer is already empty and
it does nothing. `PascalCommon.SafeLog` does it on both compilers since 1.8.1 (only on FPC before,
for gotcha 8). Its test redirects `Output` to a temporary file and reads the file, without
closing `Output`, after each `SafeWriteln`.

## 10. FPC on Unix: `AnsiUpperCase` leaves accented letters alone, depending on the locale

**Symptom.** `AnsiUpperCase('são paulo')` gives `'SãO PAULO'` on FPC 3.2.2/Linux (x86_64 and
i386), while it gives `'SÃO PAULO'` on Delphi and on FPC/Windows. Same for `AnsiLowerCase`.
Found by the first version of `TOptionals.Upper`/`Lower` (1.9.0, unreleased), in the Docker
suite.

**Cause.** On Unix, `AnsiUpperCase` goes through the widestring manager, `cwstring`, which maps
case with the C library under the process locale. The container runs without `LANG` (locale
"C"), where only ASCII has a case mapping. Measured with the same binary: without `LANG`,
`'SãO PAULO'`; with `LANG=C.UTF-8 LC_ALL=C.UTF-8`, `'SÃO PAULO'`. `cwstring` and
`SetMultiByteConversionCodePage(CP_UTF8)` were both in place: it isn't the code page. So the
result depends on an environment variable of the machine the program runs on, and a service in a
container would store `SãO PAULO` without any error.

**Fix.** On FPC, `Character.ToUpper`/`ToLower` on a `UnicodeString`: the `Character` unit
(rtl-objpas) uses the RTL's own Unicode tables and ignores the locale. Measured right without
`LANG`: `'são paulo ção ñ ü'` → `'SÃO PAULO ÇÃO Ñ Ü'`, and back to lower. Cost: the tables,
about 240 KB in a Linux binary without smart linking (whether or not the function is called) and
about 90 KB with `-XX -CX`. `PascalCommon.Optionals` does this since 1.9.0 (`{$IFDEF FPC}`; Delphi
keeps `AnsiUpperCase`/`AnsiLowerCase`). Since 1.13.0 the code is in `PascalCommon.Text`
(`PcUpperCase`/`PcLowerCase`), public, and used by `Optionals` and `Normalizers`. Its
tests run `'são paulo'` on every platform, and the Linux CI container has no `LANG`, so a return
to the locale-dependent call fails there.


## 11. Windows: a redirected stdout isn't UTF-8, and setting it at startup doesn't reach other threads on FPC

**Symptom.** A console program writes a UTF-8 string with `Writeln` (or `SafeWriteln`), its
stdout goes to a file or a pipe, and the accented letters come out wrong even though the string
is right. Seen from pascal-api-infra-faa (samples/04-messaging, the consumer's log, FPC 3.2.2):
"café" was written with byte 0x82, the é of code page 850. Measured 2026-10-15 on Windows 11
(console code page 850, ANSI code page 1252), for `café ç ã €`:

| Output | FPC 3.2.2 | Delphi 12 |
|---|---|---|
| File or pipe, process with a console | `63 61 66 82 …` (850), € → `?` | `63 61 66 e9 …` (1252) |
| File or pipe, no console attached (a service) | 1252, or UTF-8 after `SetMultiByteConversionCodePage(CP_UTF8)` | 1252 |
| Console | right for what 850 has, € → `?` | the same |

**Cause.** Both RTLs convert the string to the code page of the `Output` text record, chosen
when it's opened. FPC uses `GetConsoleOutputCP` for every standard handle, a console or not
(`rtl/inc/text.inc`, `OpenStdIO`). With no console attached, that function returns 0, which
stands for `DefaultSystemCodePage`. Delphi uses `GetConsoleOutputCP` for a console and
`DefaultSystemCodePage` for anything else (`TextOpen` in `System.pas`). Neither picks UTF-8.
`SetMultiByteConversionCodePage(CP_UTF8)` changes the strings' code page, not `Output`'s.
`SetTextCodePage(Output, CP_UTF8)` at startup fixes a file on Delphi, but on FPC `Output` is a
threadvar (gotcha 8): it fixes only the calling thread's. Measured in one file: `caf c3 a9`
from the main thread, `caf 82` from a `TThread`. On a console, UTF-8 bytes show mojibake under
850. `SetConsoleOutputCP(CP_UTF8)` makes them show right, but it changes the code page of the
whole console, the shell that started the program included.

**Fix.** Call `PcSetSafeLogUtf8(True)` at startup and write through `SafeWriteln` (since
1.10.0). For a file or a pipe, `SafeWriteln` sets `Output`'s code page to `CP_UTF8` for each
line and sets it back, inside its lock, on the calling thread's `Output`. For a console, it
writes UTF-16 with `WriteConsoleW` and leaves the console's code page alone. Measured with the
option on (FPC): UTF-8 from the main thread and from a `TThread`, to a file, a pipe and with no
console attached. On a console, reading the screen back gave `café €`. The classic console
shows an emoji as U+FFFD, a limit of its screen buffer. A plain `Writeln` in the same program
keeps the old code page. `PascalCommon.SafeLogTests` sets the captured or file `Output` to 1252
and checks the bytes, so it fails if the option has no effect.

## 12. Delphi: `E2291 Missing implementation of interface method` with an overloaded method and a method resolution clause

**Symptom.** A class implements an interface whose method is overloaded, and maps it with a
method resolution clause to overloaded methods of its own. FPC 3.2.2 builds it. Delphi 12
stops at the class with `E2291 Missing implementation of interface method IOptString.Map`, one
error per interface. Found in the first version of 1.12.0 (unreleased), where
`IOptString.Map` had a second overload taking an `IPcStringNormalizer`:

```pascal
IOptString = interface
  function Map(AFunc: TPcStringFunc): IOptString; overload;
  function Map(ANormalizer: IPcStringNormalizer): IOptString; overload;
end;
...
function IOptString.Map = OptMap;   // OptMap is overloaded with both signatures
```

**Cause.** Delphi binds a method resolution clause to one overload of the interface method, not
to all of them, and reports the other one as not implemented. `TOptNullString` needs the clause
because it implements three flavors whose `Map` has the same name and a different result type,
so the class can't implement them by name.

**Fix.** Don't overload a method of an interface that a class implements through a resolution
clause; give the new form its own name. 1.12.0 shipped it as `Normalize(ANormalizer)` next to
`Map(AFunc)`. That also keeps a literal `nil` passed to `Map` unambiguous. The FPC build doesn't
catch this: build on Delphi before calling an interface change done.
