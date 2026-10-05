# pascal-common-faa

Base library shared by the `*-faa` libraries — [pascal-db-faa](https://github.com/fabianoallex/pascal-db-faa),
pascal-named-pipes-faa, pascal-amqp-faa, pascal-redis-faa — for **Delphi and Lazarus/Free Pascal**
(dual-compiler, FPC 3.2.2).

It holds what at least two of those libraries need, so each of them stops carrying its own copy.
It also holds the optional types, which must be one shared type: a DTO filled from a message or a
request can then be handed to the database layer as is. The library is small on purpose, and
changes slowly.

Tested here on FPC 3.2.2 (Windows x64, Linux x86_64, Linux i386) and Delphi 12 (Win32, Win64).
Delphi for Android (ARM) is a consumer target that has only been compiled so far, inside
pascal-named-pipes-faa's Android test project, not run on a device. Nothing in the code is
Windows-only, and the shared instances (`PcPool`, the default clock and sleep) are created in
`initialization` instead of lazily, which is what keeps them safe on weakly ordered CPUs such
as ARM.

## Contents

| Unit | What it gives you |
|---|---|
| `PascalCommon.Version` | `PASCALCOMMON_VERSION` (major × 10000 + minor × 100 + patch), for compile-time checks |
| `PascalCommon.Threading` | Atomics (`PcAtomicInc`, `Dec`, `Get`, `Set`, `CompareExchange`; 64-bit `PcAtomicInc64`, `Add64`, `Read64`, `Write64`, `CompareExchange64` for `Int64` and `UInt64`) and monotonic time (`PcTickMs`, `PcTickUs`). `TInterlocked` and `TStopwatch` don't exist in FPC |
| `PascalCommon.ThreadPool` | `TPcMonitor` (lock + condition variable), `TPcThreadPool` with `TPcWorkItem`, and the process-wide pool `PcPool` |
| `PascalCommon.SystemContext` | Replaceable wall clock (`TClock`), monotonic clock (`TTicker`) and wait (`TSleep`), so tests can run time-dependent code without real waits |
| `PascalCommon.ClockCache` | `TClockCache<K, V>`: a thread-safe, fixed-size cache (G-Clock eviction) with predictable latency |
| `PascalCommon.Optionals` | Optional and nullable types: `IOptXxx` ("was it provided?"), `INullXxx` ("is it null?") and `IOptNullXxx` (both), for String, Integer, Int64, Single, Double, Currency, TDateTime, Boolean and TGUID, with `TOptionals.Safe` |
| `PascalCommon.JsonMapper.Optionals` | Optional bridge: a [pascal-jsonmapper-faa](https://github.com/fabianoallex/pascal-jsonmapper-faa) converter for the optional types. Separate package |

```pascal
uses PascalCommon.Optionals, PascalCommon.Threading;

var
  LName: IOptString;
  LCount: Int64;
begin
  LName := TOptNullString.From('São Paulo');
  if TOptionals.Safe(LName).HasValue then
    WriteLn(LName.Value);
  LCount := 0;
  PcAtomicAdd64(LCount, 10);
end;
```

## Installing

**Lazarus:** open and install `packages/pascal_common_faa.lpk`. For the JSON bridge, also
`packages/pascal_common_faa_jsonmapper.lpk`, which requires pascal-jsonmapper-faa's
`pascaljsonmapper_pkg` by name: install or require that one first. A project should name the copy
it wants with `Prefer="True"` (see `docs/gotchas.md`, gotcha 2).

**Delphi:** add `src` to the project's search path (and `bridges/jsonmapper` plus
pascal-jsonmapper-faa's `src` for the bridge).

**FPC on Unix:** `PascalCommon.ThreadPool` starts threads, so the program needs `cthreads` as
the first unit in its `uses`.

## For library authors: one copy per application

An application that uses several `*-faa` libraries gets **one** copy of this one, which it
provides itself: one registered `pascal_common_faa.lpk` in Lazarus, or one search path in
Delphi. That is why:

- **A library never ships pascal-common-faa inside itself.** It may keep it as a submodule in
  `external/` for its own tests and CI, but not in what the application builds. An application
  that clones a library with `--recursive` gets that `external/` copy on disk too, and must never
  put it on its search path.
- **Versions follow strict semver.** From 1.0 on, a minor version only adds, so the newest copy
  serves every library.
- **Each library checks the minimum version it needs**, so an application with an older copy
  gets a clear build error instead of a missing identifier:

```pascal
uses PascalCommon.Version;

{$IF PASCALCOMMON_VERSION < 10400}
  {$MESSAGE FATAL 'my-library needs pascal-common-faa 1.4 or later'}
{$IFEND}
```

Moving a library onto this one: [`docs/migrating.md`](docs/migrating.md) has the name map.

## Documentation

- [`docs/migrating.md`](docs/migrating.md): from the per-library copies to pascal-common-faa.
- [`docs/gotchas.md`](docs/gotchas.md): Delphi × FPC traps found here (symptom → cause → fix).
- [`docs/plan.md`](docs/plan.md): why the library exists, the decisions taken, and the phases.
- [`CHANGELOG.md`](CHANGELOG.md).

## Tests

DUnitX on Delphi and FPCUnit on FPC, with the same test bodies: the FPCUnit fixtures are generated
from the DUnitX ones by `tools/gen_fpc_mirror.py`. Acceptance is every test green and 0 leaks.

- FPC on Windows: `sh tools/test_fpc.sh`
- FPC on Linux, x86_64 and i386, in Docker (what CI runs): `sh tools/ci-test.sh`
- Delphi: open `PascalCommon.groupproj`, build and run `tests/Unit/PascalCommon.UnitTests.dproj`
  (Win32 and Win64)

The bridge tests need the submodule: `git submodule update --init`.

## License

MIT — see [LICENSE](LICENSE).
