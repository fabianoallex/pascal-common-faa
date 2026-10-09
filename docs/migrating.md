# Migrating to pascal-common-faa

This guide is for moving a library (pascal-db-faa, pascal-named-pipes-faa, pascal-amqp-faa,
pascal-redis-faa) off its own copy of the shared code. There are no alias units and no
compatibility layer: none of these libraries has a reported user yet, so each one renames in one
go (plan decision 4).

## Steps

1. **Add the submodule** for your own tests and CI only:
   `git submodule add https://github.com/fabianoallex/pascal-common-faa.git external/pascal-common-faa`.
   Never put it in what the application builds: the application provides the single copy (see
   the README, "For library authors"). **If your consumers clone your library with
   `--recursive`** (because it has another submodule they need at runtime, as delphi-api-infra-faa
   does with SwagDoc), that clone also brings `external/pascal-common-faa`, and its own
   `external/pascal-jsonmapper-faa`, into the application's tree. Measured in F9. It does no
   harm while the application's search path and packages point at the application's own copy,
   but it is a second copy one `;` away. Say in your README that `external/` is never on the
   application's search path. Not measured: marking the submodule `update = none` in your
   `.gitmodules`, so that only your own tests and CI check it out explicitly.
2. **Delete the moved units** (table below) and rename what remains (name map below).
3. **Depend on the package, by name.** On Lazarus, the library's own `.lpk` requires
   `pascal_common_faa` **by name only**, with no `DefaultFilename`, and a `MinVersion`:

   ```xml
   <Item>
     <PackageName Value="pascal_common_faa"/>
     <MinVersion Major="1" Valid="True"/>
   </Item>
   ```

   A `DefaultFilename` into `external/` would let Lazarus fall back to the library's private copy:
   that is the diamond the README rules out. Each test or sample `.lpi` of the library then lists
   `pascal_common_faa` **first**, with `DefaultFilename` into
   `external/pascal-common-faa/packages/` and `Prefer="True"`; the library's package resolves to
   the copy already loaded. Without `Prefer`, a `pascal_common_faa.lpk` registered in the IDE
   wins over the `DefaultFilename`. Building the library's `.lpk` alone with lazbuild fails until
   `pascal_common_faa.lpk` is registered (by design), and leaves a `packagefiles.xml` in the
   current folder (gotcha 6): register it first, and ignore `/packagefiles.xml`. On Delphi, add
   `external/pascal-common-faa/src` to the test projects' search path.

   An application, or a project that compiles a library from its `src` folder instead of its
   `.lpk`, needs only the `pascal_common_faa` package on lazbuild (first, `DefaultFilename`,
   `Prefer="True"`). Don't also put pascal-common-faa's `src` on its search path: that is
   redundant and risks compiling the units twice. Measured in pascal-dfe-broker (F10): the units
   were compiled only into the package's `lib` folder. The `src` path is needed on Delphi, and
   where `fpc` is called directly without lazbuild (Docker scripts: `-Fu` and `-Fi` on `src`).
4. **If the library uses the JSON bridge,** each project that uses it also requires the mapper
   itself, before the bridge:

   ```xml
   <Item>
     <PackageName Value="pascaljsonmapper_pkg"/>
     <DefaultFilename Value="..\..\external\pascal-jsonmapper-faa\packages\pascaljsonmapper_pkg.lpk" Prefer="True"/>
   </Item>
   <Item>
     <PackageName Value="pascal_common_faa_jsonmapper"/>
     <DefaultFilename Value="..\..\external\pascal-common-faa\packages\pascal_common_faa_jsonmapper.lpk" Prefer="True"/>
   </Item>
   ```

   The bridge's `.lpk` requires `pascaljsonmapper_pkg` by name only, so the project decides which
   copy of the mapper is used. Leave out the mapper line and lazbuild **silently** builds against
   whatever `pascaljsonmapper_pkg` is registered in the IDE. Measured in the pascal-db-faa pilot
   (F6) and in this repository's own tests. On Delphi, add `bridges/jsonmapper` and your
   mapper's `src` to the search path.
5. **Add the minimum-version check** in a unit every user of the library compiles, **after the
   `uses` that brings in `PascalCommon.Version`**: `$IF` only sees constants of units already
   used. pascal-db-faa has it in `PascalDb.Interfaces`, right after the interface `uses`:

   ```pascal
   uses
     ..., PascalCommon.Version;

   {$IF PASCALCOMMON_VERSION < 10000}
     {$MESSAGE FATAL 'pascal-db-faa needs pascal-common-faa 1.0.0 or later'}
   {$IFEND}
   ```

   Measured in the pilot on both compilers: an older copy stops the build with that text (FPC:
   `Fatal: (2022) User defined: ...`; Delphi: `F1054 ...`).
6. **CI:** check out submodules without `recursive`. pascal-common-faa has its own
   `external/pascal-jsonmapper-faa`, used only by its own tests. A library that also uses the
   mapper keeps its own copy and builds the bridge against that one (step 4).
7. **Run every suite** (unit, integration, samples) on both compilers, with 0 leaks. On FPC,
   "0 leaks" means you **saw** the `0 unfreed memory blocks` line, in the heaptrc file
   (`HEAPTRC="log=<file>"`, gotcha 5), not that no leak line appeared. Check first that heaptrc
   is on at all (`-gh`, or `UseHeaptrc` in the `.lpi`): pascal-redis-faa's test projects never
   had it, so its FPC leaks had never been measured before its migration.

## Units

| Before | After |
|---|---|
| `PascalDb.Threading`, `Pipes.Threading`, `AMQP.Threading`, `Redis.Threading` (atomics, ticks) | `PascalCommon.Threading` |
| `Pipes.Threading`, `AMQP.Threading`, `Redis.Threading` (monitor, pool) | `PascalCommon.ThreadPool` |
| `PascalDb.SystemContext` | `PascalCommon.SystemContext` |
| `PascalDb.ClockCache` | `PascalCommon.ClockCache` |
| `PascalDb.Optionals` | `PascalCommon.Optionals` |
| `PascalDb.JsonMapper.Optionals` | `PascalCommon.JsonMapper.Optionals` |
| package `pascal_db_faa_jsonmapper.lpk` | `pascal_common_faa_jsonmapper.lpk` |
| `PascalDb.SafeLog` (pascal-db-faa), `Common.SafeLog` (delphi-api-infra-faa) | `PascalCommon.SafeLog` (since 1.3.0; see "SafeLog" below) |

## SafeLog (1.3.0)

`PascalCommon.SafeLog` replaces `PascalDb.SafeLog` (pascal-db-faa) and `Common.SafeLog`
(delphi-api-infra-faa). The point of moving it is the lock: each copy had its own, so an
application using both libraries had two locks over one console, and a line from one could land
in the middle of a line from the other. Every library must use this unit, and keep no copy.

- **Same API:** `SafeWriteln(const AText: string)` and
  `SafeWriteln(const AFormatStr: string; const AArgs: array of const)`. Only the unit name
  changes: `PascalDb.SafeLog` or `Common.SafeLog` → `PascalCommon.SafeLog` in each `uses`, then
  delete the old unit (and its line in the `.lpk`, `.dproj` and `.dpr`).
- **Same behavior:** one critical section created in `initialization`, a no-op when not
  `IsConsole`, and the `Format` overload checks `IsConsole` before formatting. The only
  difference: on FPC, `SafeWriteln` flushes `Output` inside the lock (gotcha 8). Without that,
  lines from different threads came out mixed on FPC whenever stdout was a file or a pipe.
- **Minimum version:** raise the library's check to `PASCALCOMMON_VERSION < 10300`, and the
  `MinVersion` of `pascal_common_faa` in its `.lpk` to 1.3.
- **The library's own tests of its copy** (if any) go away: this repository's
  `PascalCommon.SafeLogTests` covers the unit.

## Tracing (1.7.0)

`PascalCommon.Tracing` replaces pascal-api-infra-faa's `PascalApi.Tracing` (phase C of its
observability design). It moved so the sibling libraries can open spans that join an API's
trace (phase D) without depending on the API library. The exporters stay in
pascal-api-infra-faa: `PascalApi.Otlp`'s `TOtlpHttpExporter` implements `IPcSpanExporter`.

| Before (`PascalApi.Tracing`) | After (`PascalCommon.Tracing`) |
|---|---|
| `TTracing` | `TPcTracing` (same class methods) |
| `ISpan`, `ISpanExporter` | `IPcSpan`, `IPcSpanExporter` (new GUIDs) |
| `TSpanData`, `TSpanDataArray` | `TPcSpanData`, `TPcSpanDataArray` |
| `TSpanKind`, `TSpanStatus`, `TSpanAttributeType` | `TPcSpanKind`, `TPcSpanStatus`, `TPcSpanAttributeType` (same values: `skServer`, `ssError`, `satInt`...) |
| `TSpanAttribute`, `TSpanAttributes` | `TPcSpanAttribute`, `TPcSpanAttributes` |
| `TTracingOptions` | `TPcTracingOptions` |
| `UnixNanoOfLocal` | `PcUnixNanoOfLocal` |
| `TLogProc` (for `Start`'s `AOnError`) | `TPcLogProc`, the same signature |
| `ParseKeyValueList` | stays in pascal-api-infra-faa (only the exporter uses it) |

- **`TTracingOptions.FromEnvironment`** read the variables through `TAppConfig`, so a `.env`
  file counted. `TPcTracingOptions.FromEnvironment(AName, AVersion)` reads only the process
  environment; to keep the `.env`, pass a lookup:
  `TPcTracingOptions.FromEnvironment(AName, AVersion, ReadConfig)`, where `ReadConfig` is a
  plain function `(const AName: string): string` that returns `TAppConfig.Get(AName, '')`.
  The parsing and the limits are the same.
- **`TLogProc` and `TPcLogProc`** have the same signature but are two declarations (on Delphi,
  two `reference to` types). Declaring `TLogProc = TPcLogProc` in `PascalApi.Http` makes them
  one type, so a `TLogProc` goes to `TPcTracing.Start` as it is, on both compilers, without
  depending on how each compiler matches two procedural types.
- **Behavior:** `Enabled` no longer takes a lock; `SetName` after `Finish` is ignored (it changed
  the exported name before); `ShouldSample` reads the id as lowercase hex only (trace ids are
  always lowercase, `PascalCommon.TraceContext`). New: `StartSpanFromParent`.
- **Minimum version:** `PASCALCOMMON_VERSION < 10700`, and `MinVersion` 1.7 in the `.lpk`
  (`10800` and 1.8 for `StartDetachedSpan` and `StartChildSpan`: work that ends on another
  thread, such as a transaction committed elsewhere, must not use a span that becomes the
  current one; see the unit header).
- **The tests** came with the unit (`PascalCommon.TracingTests`, all but the
  `ParseKeyValueList` one), so pascal-api-infra-faa keeps only that one.

## Names

`Xxx` stands for each library's prefix: `Pdb` (pascal-db-faa), `Pipe` (pipes), `Amqp` (amqp),
`Redis` (redis). The class prefixes are `TPipe`, `TAMQP` and `TRedis`.

| Before | After | Notes |
|---|---|---|
| `XxxAtomicInc`, `XxxAtomicDec` | `PcAtomicInc`, `PcAtomicDec` | |
| `XxxAtomicGet`, `XxxAtomicSet`, `XxxAtomicCompareExchange` | `PcAtomicGet`, `PcAtomicSet`, `PcAtomicCompareExchange` | |
| `PdbAtomicInc64`, `PdbAtomicAdd64`, `PdbAtomicRead64` (`Int64`) | `PcAtomicInc64`, `PcAtomicAdd64`, `PcAtomicRead64` | `Int64` overload |
| `XxxAtomicRead64`, `XxxAtomicWrite64` (`UInt64`) | `PcAtomicRead64`, `PcAtomicWrite64` | `UInt64` overload |
| `PipeAtomicCompareExchange64`, `PipeAtomicAdd64` (`UInt64`) | `PcAtomicCompareExchange64`, `PcAtomicAdd64` | `UInt64` overload |
| `XxxTickMs` | `PcTickMs` | |
| `PdbTickUs` | `PcTickUs` | |
| `PIPES_WAIT_INFINITE`, `AMQP_WAIT_INFINITE`, `REDIS_WAIT_INFINITE` | `PC_WAIT_INFINITE` | in `PascalCommon.ThreadPool` |
| `TPipeMonitor`, `TAMQPMonitor`, `TRedisMonitor` | `TPcMonitor` | |
| `TPipeWorkItem`, `TAMQPWorkItem`, `TRedisWorkItem` | `TPcWorkItem` | |
| `TPipeThreadPool`, `TAMQPThreadPool`, `TRedisThreadPool` | `TPcThreadPool` | |
| `PipePool`, `AmqpPool`, `RedisPool` | `PcPool` | one pool for the whole process |
| `TXxxCondGen`, `TXxxPoolWorker` | — | private nested types now; nothing outside used them |
| `IClock`/`TClock`, `ITicker`/`TTicker`, `ISleep`/`TSleep` | unchanged | see "Name clash" below |
| `TClockCache`, `TCacheHitRate`, `TCacheStats`, `TAdmissionPolicy` | unchanged | |
| `IOptXxx`, `INullXxx`, `IOptNullXxx`, `TOptNullXxx`, `TOptionals` | unchanged | |
| `TOptNullXxx.SafeNullable`, `SafeOptional`, `SafeOptNull` (deprecated) | `TOptionals.Safe` | removed in 0.2.0 |
| `TOptionalsJsonConverter`, `RegisterOptionalsConverter` | unchanged | |

A rename for pascal-db-faa (check the diff; the other libraries need their own prefixes):

```sh
perl -pi -e 's/\bPascalDb\.(Threading|SystemContext|ClockCache|Optionals|JsonMapper\.Optionals)\b/PascalCommon.$1/g;
             s/\bPdb(Atomic\w*|Tick(?:Ms|Us))\b/Pc$1/g;
             s/pascal_db_faa_jsonmapper/pascal_common_faa_jsonmapper/g' <files>
```

Always match whole words (`\b`): amqp has `TAMQPMonitorThread`, a different type from
`TAMQPMonitor`, and a pattern without `\b` would turn it into `TPcMonitorThread`. Use `perl -pi`,
not `sed -i`: in Git Bash on Windows, `sed -i` rewrites every file it is given
with LF line endings, even the files where nothing matched (gotcha 3). `perl -pi` keeps CRLF.

## Behavior to know about

- **Stays in its library:** `TPipeKeyedDispatcher`, `PipeGroupDispatcher` and
  `TPipeHeartbeatThread` (pipes), `AmqpWallMs` (amqp). `PascalDb.SafeLog` stayed in
  pascal-db-faa until 1.3.0, when a second user appeared (see "SafeLog" above).
  `TPipeKeyedDispatcher` runs on any `TPcThreadPool`; `PipeGroupDispatcher` can be built on
  `PcPool`.
- **`PcPool` is shared by every library in the process**, and created in
  `PascalCommon.ThreadPool`'s initialization (the donors created theirs lazily). Its
  `QueueDepth` counts every library's items. Your unit is finalized before
  `PascalCommon.ThreadPool`, so `PcPool` is still alive and still running your items when your
  finalization frees things. The donors didn't have this problem: each one owned its pool and
  freed it first, and that ran the whole queue. See the next point.
- **`PcPool` is for work that may block** (user callbacks, I/O). Work that another thread waits
  for synchronously, such as an actor answering requests or a dispatcher whose items reply to a
  caller, belongs on a `TPcThreadPool` of its own. `PcPool` has a ceiling (`MaxWorkers`,
  `max(16, 4 × cores)`; cores from `PcProcessorCount`, real on Linux since 1.2.0, 1 on FPC for
  macOS and the BSDs: gotcha 7) shared by every library in the process, so one library's slow callbacks
  become another library's timeouts. This is a correctness issue, not only a latency one.
  Measured in the pascal-amqp-faa migration (F8), with `PcPool` saturated by blocking items: with
  the broker's queue actors on `PcPool`, `Queue.Declare` waited its full 15 s and the broker
  dropped the connection; on a pool of the broker's own, it took 26 ms. amqp's broker now owns
  its pool, and its client stays on `PcPool`.
- **An object whose work runs on `PcPool` and that you free in your finalization must wait for
  its own items.** pascal-named-pipes-faa's `PipeGroupDispatcher` (a keyed dispatcher whose
  drain items run on the global pool) used to be freed after the pool. Freed before `PcPool`,
  as it is now, a queued drain item called into the freed object, and the items still in its
  mailboxes were lost (measured in F8: 0 of 15 items run, 6 unfreed blocks). What pipes does
  now, and what works:
  - count the items **from the moment they are queued**, not from when they start;
  - decrement the counter in the work item's **destructor**, not at the end of `Execute`. The
    destructor also runs when the pool frees an item without running it, and it is the item's
    last access to the owner;
  - in the owner's `Destroy`, wait by polling that atomic counter down to 0 (with a deadline).
    Don't wait on an event the item signals: the item's last act would be a `SetEvent` on an
    object the waiter may already be freeing.

  See `Pipes.Threading` (`TPipeMailboxDrainWork.Destroy`, `TPipeKeyedDispatcher.Destroy`) in
  pascal-named-pipes-faa.
- **In a VCL or LCL application, a form or data module that queues work on `PcPool` must wait
  for its own items in `OnCloseQuery`.** `Application` frees its forms in an exit procedure,
  before every unit finalization, so waiting in a finalization is already too late for them.
  Measured in the pascal-redis-faa migration (F8) on LCL: the form was destroyed before the first
  unit finalization, and all three of its queued items ran afterwards against the freed form. One
  of redis's GUI samples woke a stream consumer 2.6 s after `FormDestroy`, silently: exit code 0,
  and heaptrc doesn't flag a use after free. The VCL does the same (`Vcl.Forms`'
  `DoneApplication`, read in the source). This is not new with pascal-common-faa: the donors'
  pools were also freed in a unit finalization. What redis does now, on top of the counter
  pattern above:
  - each work item counts itself on the form from its constructor (UI thread, before `Queue`) to
    its destructor, and `OnCloseQuery` waits for the counter to reach 0;
  - while waiting, pump `CheckSynchronize(10)` instead of `Sleep(10)`. The items post
    `TThread.Queue` calls as they finish, and nobody runs those after the message loop. On Delphi
    they also leak: `DoneThreadSynchronization` doesn't free what is left in the queue;
  - count the `TThread.Queue` calls an item posts too, not only the item: create the marshal and
    count it before the item uncounts itself in its destructor, so the counter never passes
    through 0 on the way. An item that only posts a marshal and never touches the form still
    causes a use after free. **On FPC, `PcPool`'s own finalization pumps those leftover marshals**:
    `TPcThreadPool.Destroy` joins its workers with `TThread.WaitFor`, which, called from the main
    thread, runs `CheckSynchronize` (read in FPC 3.2.2's `rtl/win/tthread.inc` and
    `rtl/unix/tthread.inc`). So a marshal left behind runs there, against the freed form.
    Measured in pascal-dfe-broker (F10): an access violation in the form's handler with a call
    stack through `TPcThreadPool.Destroy` when the marshal ran; a heaptrc leak when it didn't;
  - a work item never reads a control. On LCL, reading `TEdit.Text` from a worker is a
    cross-thread `SendMessage` to the UI thread, and that is the thread waiting for the item.

  See `docs/DECISOES.md` §50 in pascal-redis-faa, and `ConsumidorDFeVcl` in pascal-dfe-broker.
- **`TPcThreadPool.Destroy` runs every queued item before returning.** The donors did the same.
  The Pipes header and test, and amqp's `AMQP.Server.Queue` header, said Destroy discarded the
  queued items, but it never did. Only an item queued **after** `Destroy` has started is freed
  without running. So never rely on queuing a "stop" item to a pool that is being destroyed.
- **64-bit atomics wrap around** instead of raising, even with overflow checks on in the
  project. pascal-db-faa's `PdbAtomicAdd64` could raise `EIntOverflow` on the returned copy,
  after the shared value had already changed.
- **FPC on 32-bit CPUs now builds.** FPC 3.2.2 has no 64-bit `InterLocked*` there, so the
  donors' `*64` atomics didn't compile on FPC i386; here they go through a lock (gotcha 1).
- **delphi-api-infra-faa used to clash with these names.** Its `Common.SystemContext`,
  `Common.ClockCache` and `Common.Optionals` declared the same names and the same interface GUIDs.
  Since its v0.1.0 (F9) it uses pascal-common-faa instead. Code still on an older infra version
  must not be linked with pascal-common-faa.
