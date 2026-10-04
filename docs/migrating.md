# Migrating to pascal-common-faa

This guide is for moving a library (pascal-db-faa, pascal-named-pipes-faa, pascal-amqp-faa,
pascal-redis-faa) off its own copy of the shared code. There are no alias units and no
compatibility layer: none of these libraries has a reported user yet, so each one renames in one
go (plan decision 4).

## Steps

1. **Add the submodule** for your own tests and CI only:
   `git submodule add https://github.com/fabianoallex/pascal-common-faa.git external/pascal-common-faa`.
   Never put it in what the application builds: the application provides the single copy (see
   the README, "For library authors").
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
   wins over the `DefaultFilename`. On Delphi, add `external/pascal-common-faa/src` to the test
   projects' search path.
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
7. **Run every suite** (unit, integration, samples) on both compilers, with 0 leaks.

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

Use `perl -pi`, not `sed -i`: in Git Bash on Windows, `sed -i` rewrites every file it is given
with LF line endings, even the files where nothing matched (gotcha 3). `perl -pi` keeps CRLF.

## Behavior to know about

- **Stays in its library:** `TPipeKeyedDispatcher`, `PipeGroupDispatcher` and
  `TPipeHeartbeatThread` (pipes), `AmqpWallMs` (amqp), `PascalDb.SafeLog` (pascal-db-faa).
  `TPipeKeyedDispatcher` runs on any `TPcThreadPool`; `PipeGroupDispatcher` can be built on
  `PcPool`.
- **`PcPool` is shared by every library in the process**, and created in
  `PascalCommon.ThreadPool`'s initialization (the donors created theirs lazily). Its
  `QueueDepth` counts every library's items. Your unit is finalized before
  `PascalCommon.ThreadPool`, so `PcPool` is still alive and still running your items when your
  finalization frees things. The donors didn't have this problem: each one owned its pool and
  freed it first, and that ran the whole queue. See the next point.
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
- **`TPcThreadPool.Destroy` runs every queued item before returning.** The donors did the same.
  The Pipes header and test said Destroy discarded the queued items, but it never did.
- **64-bit atomics wrap around** instead of raising, even with overflow checks on in the
  project. pascal-db-faa's `PdbAtomicAdd64` could raise `EIntOverflow` on the returned copy,
  after the shared value had already changed.
- **FPC on 32-bit CPUs now builds.** FPC 3.2.2 has no 64-bit `InterLocked*` there, so the
  donors' `*64` atomics didn't compile on FPC i386; here they go through a lock (gotcha 1).
- **Name clash with delphi-api-infra-faa:** its `Common.SystemContext` and `Common.ClockCache`
  declare `TClock`, `TSleep`, `IClock`, `TClockCache`... too. In code that uses both, qualify
  the names (`PascalCommon.SystemContext.TClock`), or the unit listed last in `uses` wins.
