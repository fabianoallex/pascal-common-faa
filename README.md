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
| `PascalCommon.ThreadPool` | `TPcMonitor` (lock + condition variable), `TPcThreadPool` with `TPcWorkItem`, the process-wide pool `PcPool`, and `PcProcessorCount` (the real CPU count, also on FPC for Linux) |
| `PascalCommon.SystemContext` | Replaceable wall clock (`TClock`), monotonic clock (`TTicker`) and wait (`TSleep`), so tests can run time-dependent code without real waits |
| `PascalCommon.ClockCache` | `TClockCache<K, V>`: a thread-safe, fixed-size cache (G-Clock eviction) with predictable latency |
| `PascalCommon.SafeLog` | `SafeWriteln`: a console `Writeln` safe to call from any thread, with one lock for the whole process, and a no-op in a binary without a console (service, GUI). `PcSetSafeLogUtf8(True)` makes it write UTF-8 to a file or a pipe and UTF-16 to a Windows console, the same on both compilers |
| `PascalCommon.Utf8` | `PcTryUtf8BytesToString`: UTF-8 bytes to a string that refuses, on FPC, to corrupt non-ASCII text when the process code page isn't UTF-8 |
| `PascalCommon.TraceContext` | W3C Trace Context: new trace and span ids (`PcNewTraceId`, `PcNewSpanId`, from the OS random source), validation, and `traceparent`/`tracestate` parse and format (`PcTryParseTraceParent`, `PcFormatTraceParent`, `PcResolveTraceState`) |
| `PascalCommon.Metrics` | Counter, up-down counter, gauge and histogram with labels, a registry (`PcMetrics` is the process-wide one), and the Prometheus text exposition (`PcPrometheusText`). OpenTelemetry names and units (`http.server.request.duration`, `s`) become Prometheus names (`http_server_request_duration_seconds`); recording is lock-free on a series |
| `PascalCommon.Tracing` | Spans: `TPcTracing.StartSpan` (a child of the thread's current span), `StartSpanWith`, `StartSpanFromParent` (from a `traceparent` header), `StartDetachedSpan` (never the current span, finished on any thread) with `StartChildSpan` (an explicit parent), attributes and status; parent-based sampling with a ratio; a batch processor that hands finished spans to an `IPcSpanExporter` on its own thread. The exporter (OTLP over HTTP) lives in pascal-api-infra-faa |
| `PascalCommon.Optionals` | Optional and nullable types: `IOptXxx` ("was it provided?"), `INullXxx` ("is it null?") and `IOptNullXxx` (both), for String, Integer, Int64, Single, Double, Currency, TDateTime, Boolean and TGUID, with `TOptionals.Safe`, and string normalizers that keep the state (`TOptionals.Trim`, `Upper`, `Lower`, `NullIfEmpty`, `UndefinedIfEmpty`, `Map`) |
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

### Normalizing an optional string without an `if`

`TOptionals.Trim`, `Upper` and `Lower` take an `IOptString`, `INullString` or `IOptNullString`
and return the same flavor. Undefined stays Undefined and Null stays Null. Only a value that is
present is changed. `nil` reads as it does in `Safe`, so the result is never `nil`. The result
can go straight to a parameter, a message or a comparison:

```pascal
// DTO of a PATCH: Name, State: IOptString; Nickname: IOptNullString
LQuery.Params.OptStrings['NAME']  := TOptionals.Trim(LDto.Name);
LQuery.Params.OptStrings['STATE'] := TOptionals.Upper(TOptionals.Trim(LDto.State));
LNickname := TOptionals.NullIfEmpty(TOptionals.Trim(LDto.Nickname)); // '   ' becomes Null
```

- `NullIfEmpty` (`INullString`, `IOptNullString`) turns `''` into Null.
- `UndefinedIfEmpty` (`IOptString`, `IOptNullString`) turns `''` into Undefined.
- Neither one trims: compose with `Trim` to treat blanks as empty.
- `Upper`/`Lower` map every Unicode letter (`'são paulo'` → `'SÃO PAULO'`) on both compilers
  whatever the process locale (on FPC through the `Character` unit; see `docs/gotchas.md`,
  gotcha 10).
- `Map(AValue, AFunc)` applies a function of your own to a present value. `AFunc` is a
  `TPcStringFunc = function(const AValue: string): string`: a plain function, the same on both
  compilers, because FPC 3.2.2 has no closures.

```pascal
function OnlyDigits(const AValue: string): string;
...
LZip := TOptionals.Map(LDto.Zip, OnlyDigits);
```

The same normalizers are methods of the string optionals (1.11.0), so they chain. Each one
calls the `TOptionals` method of the same name, with the same rules:

```pascal
LDto.State    := LDto.State.Trim.Upper;
LDto.Nickname := LDto.Nickname.Trim.NullIfEmpty;
LZip          := LDto.Zip.Map(OnlyDigits);
```

A method can't be called on `nil`. Where the field may be `nil`, start the chain with `Safe`
(`TOptionals.Safe(LDto.State).Trim.Upper`), or use the `TOptionals` form, which reads `nil` as
`Safe` does. `IOptString`, `INullString` and `IOptNullString` are implemented only by
`TOptNullString`. Don't implement them in your own classes: a minor version may add methods to
them.

Only the string optionals have normalizers. The other types get theirs when a consumer needs
them.

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
