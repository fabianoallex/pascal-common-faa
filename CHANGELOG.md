# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). While the version is 0.x, a minor version
may change the API; each such change is listed here. From 1.0 on, a minor version only adds.

## [Unreleased]

## [1.15.0] - 2026-10-18

### Added

- Unit `PascalCommon.Random`: `PcFillRandom(var ABuffer; ACount)` and `PcRandomBytes(ACount)`,
  random bytes from the operating system's cryptographic source (BCryptGenRandom on Windows,
  `/dev/urandom` elsewhere), raising `EPcRandom` when the source fails and never falling back
  to `Random`. For secrets: pascal-api-infra-faa's JWT signing keys are its second user.

### Changed

- `PascalCommon.TraceContext` takes its random bytes from `PascalCommon.Random` (the same code,
  moved). Its ids and its errors are unchanged: a failure of the source is still
  `EPcTraceContext`, with the same message.

## [1.14.0] - 2026-10-17

### Added

- Unit `PascalCommon.Normalizers`, which doesn't depend on the optionals: the function types and
  normalizer interfaces (`TPcStringFunc`/`IPcStringNormalizer` ... `TPcGuidFunc`/`IPcGuidNormalizer`,
  same GUIDs) and the factories (`TPcStringNormalizers` ... `TPcGuidNormalizers`), moved here
  without changes. A normalizer now serves a plain value without bringing in the optionals:
  `TNorm.Cep.Apply(S)`, as well as `X.Normalize(TNorm.Cep)`. The dependency goes
  `Text` → `Normalizers` → `Optionals`.

### Changed

- `PascalCommon.Optionals` declares the function types and normalizer interfaces as aliases of
  `PascalCommon.Normalizers`. An alias is the same type, so code written for 1.12 that uses only
  `PascalCommon.Optionals` builds and behaves the same.

### Removed

- Unit `PascalCommon.Optionals.Normalizers` (1.13.0): its factories are in
  `PascalCommon.Normalizers`, unchanged. **An exception to strict semver**, taken knowingly: the
  unit was one day old, and its only consumer, the sample and DTO guide of pascal-api-infra-faa,
  was migrated in the same change. Code written for 1.13.0 replaces the unit name in its `uses`
  clause; nothing else changes. 1.13.0 is marked yanked below.

## [1.13.0] - 2026-10-16 [YANKED]

### Added

- Unit `PascalCommon.Optionals.Normalizers`: one factory class per type (`TPcStringNormalizers`,
  `TPcIntegerNormalizers`, `TPcInt64Normalizers`, `TPcSingleNormalizers`, `TPcDoubleNormalizers`,
  `TPcCurrencyNormalizers`, `TPcDateTimeNormalizers`, `TPcBooleanNormalizers`,
  `TPcGuidNormalizers`), to find normalizers through the editor's completion. Each has
  `FromFunc(AFunc)` (a `TPcXxxFunc` as a normalizer) and `Chain([...])` (several normalizers
  applied in order, as one); the string one also has `Trim`, `Upper` and `Lower` (shared
  instances, the same transformations as `TOptionals.Trim/Upper/Lower`). An application inherits
  a factory and adds its own normalizers as class functions, so they show up next to the
  library's: `TNorm.Cep := Chain([Trim, OnlyDigits, MaxLength(8)])`, then
  `X.Normalize(TNorm.Cep)`. `FromFunc(nil)` and a `nil` item in `Chain` raise
  `EArgumentException`; `Chain([])` returns the value unchanged. Inheritance rather than a class
  helper, because Delphi and FPC 3.2 see one helper per type, so two units with helpers would
  hide each other. The interfaces and function types stay in `PascalCommon.Optionals`.
- Unit `PascalCommon.Text`: `PcUpperCase` and `PcLowerCase`, Unicode-aware and independent of the
  process locale on both compilers (gotcha 10). It is the code `TOptionals.Upper/Lower` already
  used, moved out of `PascalCommon.Optionals` so the normalizers share one copy; behavior is the
  same.

## [1.12.0] - 2026-10-16

### Added

- `IPcStringNormalizer` (`function Apply(const AValue: string): string`) and `Normalize`, which
  is `Map` with that object instead of a function: `TOptionals.Normalize(X, N)` and `X.Normalize(N)`
  on `IOptString`, `INullString` and `IOptNullString`. It is for a normalization with parameters,
  which a plain `TPcStringFunc` can't carry without closures (FPC 3.2.2 has none):
  `LZip := LZip.Trim.Map(OnlyDigits).Normalize(TMaxLength.Create(8))`. The rules are the ones of
  `Map`: `Apply` runs only for a present value, the state is kept, an unchanged value returns the
  same instance, and a `nil` normalizer raises `EArgumentException`. The reference count frees an
  object created in the call, and one instance can be kept and used for many values. The
  parameter is not `const` on purpose: an object created in the call and passed to a `const`
  interface parameter gets no reference and is never freed.
  It isn't a `Map` overload because Delphi rejects an overloaded interface method mapped by a
  method resolution clause (new gotcha 12), and an overload would make `Map(X, nil)` ambiguous.
- `Map` and `Normalize` for every other type: Integer, Int64, Single, Double, Currency,
  TDateTime, Boolean and TGUID, in the three flavors, as methods and in `TOptionals`. Each type
  has its own function type and normalizer interface (`TPcIntegerFunc`/`IPcIntegerNormalizer`,
  `TPcDateTimeFunc`/`IPcDateTimeNormalizer`...): one generic version would need generic methods
  on an interface, which neither compiler allows. The rules are the string ones. Single and
  Double keep the source's `DecimalPlaces`, except for a result of 0, which is `From`'s shared
  zero (`DecimalPlaces` -1). Boolean returns the shared `TrueValue`/`FalseValue`. TGUID is
  compared with `IsEqualGUID`.

## [1.11.0] - 2026-10-16

### Added

- The string normalizers as methods of the string optionals, so they chain:
  `LDto.State := LDto.State.Trim.Upper`. `IOptString` has `Trim`, `Upper`, `Lower`,
  `UndefinedIfEmpty` and `Map(AFunc)`; `INullString` has `Trim`, `Upper`, `Lower`,
  `NullIfEmpty` and `Map(AFunc)`; `IOptNullString` has all six. Each returns its own flavor and
  calls the `TOptionals` method of the same name with `Self`, so the rules are the same: the
  state is kept, an unchanged value returns the same instance, and the hidden states (Null held
  by an `IOptString`, Undefined held by an `INullString`) come back unchanged.
  One difference: a method can't be called on `nil`. Where the variable may be `nil`, start the
  chain with `TOptionals.Safe(X)` or use the `TOptionals` form, which reads `nil` as `Safe` does.
- `IOptString`, `INullString` and `IOptNullString` are implemented only by `TOptNullString` and
  aren't meant to be implemented outside the library. That is what lets this minor version add
  methods to them. No class outside `PascalCommon.Optionals` implemented them.

### Changed

- `TPcStringFunc` is now declared before the optional interfaces (the fluent `Map` takes it).
  Same unit, same declaration.

## [1.10.0] - 2026-10-15

### Added

- `PcSetSafeLogUtf8(AEnabled)` and `PcSafeLogUtf8` (`PascalCommon.SafeLog`). When it's on,
  `SafeWriteln` writes UTF-8 to a file or a pipe, and UTF-16 through `WriteConsoleW` to a
  Windows console. It holds for every thread. It's off by default, because turning it on
  changes the bytes a consumer's log already gets.
  Found by pascal-api-infra-faa (samples/04-messaging): on FPC/Windows, the consumer's log
  showed "café" with byte 0x82, the é of code page 850. Measured on FPC 3.2.2 and Delphi 12,
  with the same results for `SafeWriteln` and plain `Writeln` (new gotcha 11):
  - **Redirected to a file or a pipe:** neither compiler writes UTF-8. FPC writes in the
    console's code page (850), Delphi in the ANSI code page (1252), and a character outside
    that code page becomes `?`.
  - **On a console:** both use the console's code page, so the euro sign becomes `?` under 850.
  - **Why the program can't fix it at startup on FPC:** `SetTextCodePage(Output, CP_UTF8)`
    doesn't reach other threads, because `Output` is a threadvar there.
  - **How it works.** For a file or a pipe, the code page of `Output` is set to `CP_UTF8` for
    that one line and set back afterwards, inside the lock. A `Writeln` outside `SafeWriteln`
    keeps the old code page, so a log fed by both mixes two encodings. For a console,
    `WriteConsoleW` is used instead of `SetConsoleOutputCP`, which would change the code page
    of the whole console, the parent shell's included. Outside Windows, the output is UTF-8
    whatever the locale.

## [1.9.0] - 2026-10-15

### Added

- String normalizers for the optionals: `TOptionals.Trim`, `Upper` and `Lower` (for
  `IOptString`, `INullString` and `IOptNullString`), `NullIfEmpty` (`INullString`,
  `IOptNullString`), `UndefinedIfEmpty` (`IOptString`, `IOptNullString`), and
  `Map(AValue, AFunc)` with `TPcStringFunc = function(const AValue: string): string`. The
  result keeps the state: Undefined stays Undefined, Null stays Null, `nil` reads as in `Safe`
  (the result is never `nil`), and only a present value is transformed. An unchanged value
  returns the same instance. A state the flavor can't express but its object can is kept as it
  is: `TOptNullString.Null` held by an `IOptString` stays Null instead of becoming `''`, and
  `TOptNullString.Undefined` held by an `INullString` stays Undefined.
  `Map` with `AFunc = nil` raises `EArgumentException`.
  Found by pascal-api-infra-faa (sample 02, `PATCH /cities/:code`). The DTO's name needed
  `Trim` and its state `UpperCase(Trim(...))`. Without a way to transform the value inside the
  optional, the code went back to `if LName.HasValue then ...`, or the normalization moved
  into the SQL, which doesn't help an AMQP message, a JSON response or an in-memory comparison.
  - **Why `Map` takes a plain function pointer.** It doesn't follow `PASCALCOMMON_FUNCREFS`.
    That type is `of object` on FPC, so a plain function a Delphi caller passes to the
    `reference to` type would compile on Delphi and fail on FPC.
  - **Case mapping on FPC.** `Upper`/`Lower` use `AnsiUpperCase`/`AnsiLowerCase` on Delphi and
    the `Character` unit on FPC. On FPC/Unix, `AnsiUpperCase` follows the process locale and
    left `'são paulo'` as `'SãO PAULO'` in a container without `LANG` (new gotcha 10). The cost
    is the `Character` tables in FPC binaries, measured on Linux: about 240 KB without smart
    linking, about 90 KB with `-XX -CX`.
  - **What wasn't added.** The other eight types got no normalizers (no consumer needs one
    yet), and the JSON bridge is unchanged: it doesn't trim on reading.

## [1.8.1] - 2026-10-14

### Fixed

- `SafeWriteln` didn't flush on Delphi. With standard output redirected to a file or a pipe
  (Docker, a service wrapper), the end of the last line written stayed in the RTL's buffer until
  more output came, and was lost if the process died. Found by pascal-api-infra-faa on Delphi 12
  (Win32 and Win64): a 300-byte access-log line stayed cut at `...,"dur`. Cause (new gotcha 9):
  on Windows, Delphi's RTL flushes `Writeln` only when the handle is a console, and its text
  buffer is 128 bytes, so what reaches a file is the output cut down to a multiple of 128 bytes;
  a line shows up whole only once later output pushes a boundary past its end, whatever its
  length. `SafeWriteln` now calls `Flush(Output)` inside the lock on both compilers, as it did on
  FPC since 1.3.0. New test `FileOutput_EachLineReachesTheFileBeforeTheNextWrite`: redirects
  `Output` to a temporary file and reads it, without closing `Output`, after each line; checked
  to fail without the `Flush` (on FPC, with the flush removed on purpose).

## [1.8.0] - 2026-10-09

### Added

- `TPcTracing.StartDetachedSpan(AName, AKind, AParent)`: a span that never becomes the
  thread's current span, so it can be finished on any thread. Its parent is `AParent`, else
  the current span, else a new trace. `TPcTracing.StartChildSpan(AParent, AName, AKind)`: a
  child of `AParent` instead of the current span, current on this thread until it finishes
  (then the previous current span comes back). Found by pascal-db-faa in phase D: a
  transaction span is open while its queries run, but the commit may happen on another
  thread. A span that is the current one and is finished and freed on another thread leaves
  the starting thread pointing at freed memory (measured: an access violation on that
  thread's next `Current`). With these two, the transaction is a detached span and its queries
  name it as their parent. The unit header now states the rule: a span that becomes current is
  finished on the thread that started it.

## [1.7.0] - 2026-10-09

### Added

- `PascalCommon.Tracing`: spans, moved from pascal-api-infra-faa's `PascalApi.Tracing` (phase C
  of its observability design, unstable there) at the start of phase D, so pascal-db-faa,
  pascal-redis-faa and pascal-amqp-faa can open spans that join an API's trace.
  `TPcTracing` (`Start`/`Shutdown`, `StartSpan`, `StartSpanWith`, `Current`, `ShouldSample`,
  `FlushNow`, `DroppedCount`, `PendingCount`), `IPcSpan`, `IPcSpanExporter`, `TPcSpanData`,
  `TPcTracingOptions` (`Default`, `FromEnvironment` with the `OTEL_*` variables),
  `PcUnixNanoOfLocal`, `TPcLogProc`. Not started, every call still works and exports nothing.
  Changes on the way in: the `Pc` prefixes; `Enabled` reads a flag without a lock;
  `FromEnvironment` reads the process environment, with an overload that takes the lookup
  (`TPcEnvironmentLookup`); `StartSpanFromParent`, a child of the remote span in a
  `traceparent` (or the same as `StartSpan` when it is invalid), for a message consumer;
  `SetName` after `Finish` is ignored like the other setters. The OTLP exporter stays in
  pascal-api-infra-faa (it needs an HTTP client and a JSON writer); `docs/migrating.md` has the
  name map.

## [1.6.0] - 2026-10-09

### Added

- `PascalCommon.Metrics`: metrics primitives and the Prometheus text exposition, phase B of
  pascal-api-infra-faa's observability design, here so the sibling libraries can record into
  the same registry later. `TPcMetricRegistry` with `Counter`, `UpDownCounter`, `Gauge` and
  `Histogram` (get-or-create by name; another definition under the same name raises
  `EPcMetrics`); a family's `Labels([...])` gives the series for those label values, updated
  with atomics only (a Double kept as its Int64 bits, compare-and-swap); `Snapshot` reads the
  series (for the Prometheus writer here and an OTLP exporter later); `PcMetrics`, the
  process-wide registry, created in `initialization`. `PcPrometheusText` writes the text format
  0.0.4 (`PC_PROMETHEUS_CONTENT_TYPE`), converting OpenTelemetry names and units the way
  OpenTelemetry's Prometheus compatibility specification says (`http.server.request.duration`
  in `s` becomes `http_server_request_duration_seconds`, a counter ends in `_total`).
  `PC_DURATION_BUCKETS`: OpenTelemetry's buckets for HTTP durations, 5 ms to 10 s. A counter
  ignores negative increments and every instrument ignores NaN, so recording never raises.
  Floats are written with 15 significant digits on both compilers, because FPC 3.2.2's
  `FloatToStrF` gives no more (measured). The output passes `promtool check metrics`
  (Prometheus 2.53).

## [1.5.0] - 2026-10-09

### Added

- `PascalCommon.TraceContext`: W3C Trace Context (Level 1) ids and headers, phase A of
  pascal-api-infra-faa's observability design, here so that pascal-db-faa, pascal-redis-faa and
  pascal-amqp-faa can carry the same context later. `PcNewTraceId` (32 lowercase hex digits)
  and `PcNewSpanId` (16), never all zeros; `PcIsValidTraceId`/`PcIsValidSpanId`;
  `PcTryParseTraceParent` into a `TPcTraceParent` (version, trace id, parent id, flags,
  `Sampled`); `PcFormatTraceParent` (always version 00); `PcResolveTraceState` (forwarded
  unchanged only with a valid `traceparent`, dropped beyond 512 characters). Parsing follows the
  specification: lowercase hex only, version `ff` and all-zero ids invalid, version 00 exactly
  55 characters, a higher version accepted when its first 55 characters parse and the 56th is
  `-`, surrounding spaces and tabs ignored. The random bytes come from the OS (`BCryptGenRandom`
  on Windows, `/dev/urandom` elsewhere, opened in `initialization`), not from `CreateGUID`,
  whose last resort on FPC/Unix is `Random`; if the source fails, `EPcTraceContext` is raised.

## [1.4.0] - 2026-10-08

### Added

- `PascalCommon.Utf8`: `PcTryUtf8BytesToString(ABytes, out AText): Boolean`, UTF-8 bytes (BOM
  optional) to a string, returning False instead of silently turning characters into `?` when,
  on FPC, the bytes have non-ASCII characters and the process default code page isn't UTF-8.
  pascal-db-faa (`PdbUtf8BytesToString`) and pascal-api-infra-faa (`PaUtf8BytesToString`) had
  the same code, differing only in the exception they raise; they keep those functions as thin
  wrappers in their own releases. Raises nothing itself, so each caller reports with its own
  exception and context. On Delphi, invalid UTF-8 still makes `TEncoding.UTF8` raise
  `EEncodingError`, as in both copies.

## [1.3.0] - 2026-10-06

### Added

- `PascalCommon.SafeLog`: `SafeWriteln(AText)` and `SafeWriteln(AFormatStr, AArgs)`, a `Writeln`
  to the console guarded by one critical section for the whole process, and a no-op when not
  `IsConsole` (Windows service, VCL/LCL/FMX application), where `Writeln` would raise
  `EInOutError` 105; the `Format` overload returns before formatting. It replaces
  `PascalDb.SafeLog` (pascal-db-faa) and `Common.SafeLog` (delphi-api-infra-faa), which had the
  same two overloads and bodies but a lock each, so an application using both libraries had two
  locks over one console and their lines could still mix. Those libraries switch in their own
  releases (`docs/migrating.md`). One difference from both copies: on FPC it calls
  `Flush(Output)` before releasing the lock. FPC's `Output` is per thread, and when stdout is a
  file or a pipe (Docker, systemd) the lock alone didn't keep lines whole: 2,165 of 16,000 lines
  corrupted in the measurement, none with the flush (gotcha 8). Nothing changes on Delphi.

## [1.2.0] - 2026-10-05

### Added

- `PcProcessorCount` (`PascalCommon.ThreadPool`): the number of CPUs online, at least 1. On FPC
  for Linux it reads libc's `sysconf(_SC_NPROCESSORS_ONLN)`, because FPC 3.2.2's
  `TThread.ProcessorCount` is always 1 there (gotcha 7); elsewhere it is
  `TThread.ProcessorCount`.

### Changed

- `TPcThreadPool`'s default ceiling (`max(16, 4 × cores)`, including `PcPool`'s) counts cores
  with `PcProcessorCount`. On FPC for Linux it is now what the documentation always said instead
  of 16: 48 on a 12-CPU machine (measured on x86_64 and i386, also under `--cpus=1`, which caps
  CPU time, not the CPU count). Nothing changes on Windows or Delphi. A pool created with an
  explicit `AMaxWorkers` is not affected.

## [1.1.3] - 2026-10-05

### Fixed

- `TPcThreadPool.Queue` didn't grow the pool during a burst. It only started a worker when no
  worker was idle, and a worker already signalled still counted as idle until it took its item.
  So a burst queued while N workers were idle ran on those N, however many items it held, and
  blocking items waited behind each other below the ceiling. With 6 idle workers, a burst of 17
  blocking items on a pool of 16 ran 6. It now starts a worker whenever the queue holds more
  items than there are idle workers to take them. Found by pascal-amqp-faa after its v0.1.0: it
  explains the intermittent `ConsomeTodas_ComAck_E_Concorrencia` failure seen there since its
  migration. New regression test `Pool_BurstAfterIdleWorkers_GrowsUpToTheCeiling`, checked to
  fail on the old code.

### Changed

- `TPcThreadPool.Create`'s doc comment, `docs/migrating.md` and the new gotcha 7: on FPC outside
  Windows, `TThread.ProcessorCount` is always 1, so the default ceiling there is 16.

## [1.1.2] - 2026-10-05

Documentation only: no change to the API or its behavior.

### Changed

- From the delphi-api-infra-faa migration (F9): `docs/migrating.md` step 1 and the README cover a
  library whose consumers clone it with `--recursive`, which brings its `external/` copy into the
  application's tree (never on the search path). The notes about the name and GUID clash with
  delphi-api-infra-faa's `Common.*` units are now historical, in `migrating.md` and in
  `PascalCommon.SystemContext`'s header (comment only), since that library uses these units.
- From the pascal-dfe-broker update (F10): `docs/migrating.md` says a GUI form must also count
  the `TThread.Queue` calls its work items post, because on FPC `PcPool`'s finalization runs
  leftover ones (`TThread.WaitFor` pumps `CheckSynchronize` on the main thread; measured there as
  an access violation through `TPcThreadPool.Destroy`), and `Destroy`'s doc comment says so; a
  project compiling a library from `src` needs only the `pascal_common_faa` package on lazbuild.

## [1.1.1] - 2026-10-04

Documentation only: no change to the API or its behavior.

### Changed

- `docs/migrating.md`, from the pascal-redis-faa migration (F8): in a VCL/LCL application, a form
  that queues work on `PcPool` must wait for its items in `OnCloseQuery`, pumping
  `CheckSynchronize`, because `Application` frees forms before any unit finalization (measured
  on LCL); step 7 asks to see heaptrc's `0 unfreed memory blocks` in its log file and to check
  heaptrc is on; step 3 mentions the `packagefiles.xml` lazbuild leaves behind.
  `PascalCommon.ThreadPool`'s header says the same about GUI applications (comment only).
- `docs/gotchas.md`: gotcha 6 (`packagefiles.xml` on a broken dependency).

## [1.1.0] - 2026-10-04

### Added

- `TPcThreadPool.MaxWorkers` (read-only): the most workers the pool will start, either the value
  given to `Create` or the default it computed.

### Changed

- `docs/migrating.md`, from the pascal-amqp-faa migration (F8): `PcPool` is for work that may
  block, and work another thread waits for synchronously belongs on a pool of its own (measured
  there: 15 s and a dropped connection against 26 ms); renames always match whole words; an item
  queued after `Destroy` has started is freed without running. `PcPool`'s doc comment says the
  same.
- `docs/gotchas.md`: gotcha 5 (heaptrc prints nothing at exit on Debian's FPC without `log=`).

## [1.0.1] - 2026-10-04

Documentation only: no change to the API or its behavior.

### Changed

- `docs/migrating.md`, from the pascal-named-pipes-faa migration (F8): how an object whose work
  runs on `PcPool` must wait for its own items before being freed in the consumer's finalization
  (the old "drain as before" didn't hold for a dispatcher); the rename recipe uses `perl -pi`,
  because `sed -i` turns CRLF into LF on Git for Windows.
- README: the verified platforms, and Delphi Android (ARM) as a target compiled by a consumer but
  not run yet.
- `docs/gotchas.md`: gotchas 3 (`sed -i` and CRLF) and 4 (Delphi rejects `finalization` without
  `initialization`).

## [1.0.0] - 2026-10-04

The API is now stable: within 1.x, releases only add (no rename, no signature change, no
behavior change a consumer could observe). Moved to 1.0 after the pascal-db-faa pilot.

### Changed

- `pascal_common_faa_jsonmapper.lpk` requires `pascaljsonmapper_pkg` by name only, no longer
  pointing into this repository's `external/` submodule, which doesn't exist in a consumer. The
  project that uses the bridge names its own copy of the mapper (gotcha 2). The test `.lpi` now
  prefers the submodule copies: until now, local lazbuild runs had silently used the mapper
  registered in the IDE.
- `docs/migrating.md`: how a library's `.lpk` and its test projects require `pascal_common_faa`
  and the mapper, and where the version check goes (findings of the pascal-db-faa pilot).

## [0.2.0] - 2026-10-04

### Removed

- The deprecated `TOptNullXxx.SafeNullable`, `SafeOptional` and `SafeOptNull` (27 methods, 3 per
  type), inherited from pascal-db-faa. Use `TOptionals.Safe`, which now holds their logic.

## [0.1.0] - 2026-10-04

First release: the code shared by the `*-faa` libraries, moved here from their own copies.

### Added

- Project skeleton: `pascalcommon.inc`, Lazarus package `pascal_common_faa.lpk`, DUnitX and
  FPCUnit runners (the FPCUnit fixtures generated from the DUnitX masters by
  `tools/gen_fpc_mirror.py`), test scripts for Windows and Linux (Docker) and CI.
- `PascalCommon.Version`: `PASCALCOMMON_VERSION` (major × 10000 + minor × 100 + patch) for
  consumers' compile-time minimum-version checks.
- `PascalCommon.Threading`: 32-bit atomics (`PcAtomicInc`, `Dec`, `Get`, `Set`,
  `CompareExchange`), 64-bit atomics with `Int64` and `UInt64` overloads (`PcAtomicInc64`,
  `Add64`, `Read64`, `Write64`, `CompareExchange64`), `PcTickMs` and `PcTickUs`. Merged from
  `PascalDb.Threading` and the shared part of `Pipes/AMQP/Redis.Threading`. On FPC for 32-bit
  CPUs the 64-bit atomics go through a lock (FPC 3.2.2 has no 64-bit `InterLocked*` there;
  gotcha 1).
- `PascalCommon.SystemContext` (`TClock`, `TTicker`, `TSleep` and their interfaces),
  `PascalCommon.ClockCache` (`TClockCache<K, V>`) and `PascalCommon.Optionals` (`IOptXxx`,
  `INullXxx`, `IOptNullXxx`, `TOptionals`), moved from pascal-db-faa with their names unchanged,
  together with their tests. New: a test fixture of its own for `SystemContext`.
- `PascalCommon.ThreadPool`: `TPcMonitor` (lock + condition variable), `TPcWorkItem`,
  `TPcThreadPool` (with `QueueDepth`) and the process-wide `PcPool`, created in the unit's
  initialization instead of lazily. Moved from `Pipes/AMQP/Redis.Threading`; the monitor's wait
  generation and the pool's worker thread are now private nested types.
- `PascalCommon.JsonMapper.Optionals` (`bridges/jsonmapper`, package
  `pascal_common_faa_jsonmapper.lpk`): the pascal-jsonmapper-faa converter for the optional
  types, moved from pascal-db-faa with its tests. pascal-jsonmapper-faa v0.2.0 is a submodule in
  `external/`, used by the tests only.
- `README.md` and `docs/migrating.md` (moving a library off its own copy: units, name map,
  behavior differences).

[Unreleased]: https://github.com/fabianoallex/pascal-common-faa/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/fabianoallex/pascal-common-faa/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/fabianoallex/pascal-common-faa/compare/v1.1.3...v1.2.0
[1.1.3]: https://github.com/fabianoallex/pascal-common-faa/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/fabianoallex/pascal-common-faa/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/fabianoallex/pascal-common-faa/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/fabianoallex/pascal-common-faa/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/fabianoallex/pascal-common-faa/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/fabianoallex/pascal-common-faa/compare/v0.2.0...v1.0.0
[0.2.0]: https://github.com/fabianoallex/pascal-common-faa/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/fabianoallex/pascal-common-faa/releases/tag/v0.1.0
