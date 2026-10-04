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
3. **Depend on the package:** the library's `.lpk` requires `pascal_common_faa` (and
   `pascal_common_faa_jsonmapper` if it ships the JSON bridge). The test projects point at
   `external/pascal-common-faa/packages/...` on Lazarus, and add `external/pascal-common-faa/src`
   (plus `bridges/jsonmapper`) to the search path on Delphi.
4. **Add the minimum-version check** in a unit every user of the library compiles (`PASCALCOMMON_VERSION`
   is in `PascalCommon.Version`):

   ```pascal
   {$IF PASCALCOMMON_VERSION < 200}
     {$MESSAGE FATAL 'pascal-db-faa needs pascal-common-faa 0.2.0 or later'}
   {$IFEND}
   ```

5. **CI:** check out submodules without `recursive`. pascal-common-faa has its own
   `external/pascal-jsonmapper-faa`, used only by its own tests. A library that also uses the
   mapper keeps its own copy and builds the bridge against that one.
6. **Run every suite** (unit, integration, samples) on both compilers, with 0 leaks.

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

A rename with `sed`, for pascal-db-faa (check the diff; the other libraries need their own
prefixes):

```sh
sed -i -E 's/\bPascalDb\.(Threading|SystemContext|ClockCache|Optionals|JsonMapper\.Optionals)\b/PascalCommon.\1/g;
           s/\bPdb(Atomic\w*|Tick(Ms|Us))\b/Pc\1/g;
           s/pascal_db_faa_jsonmapper/pascal_common_faa_jsonmapper/g' <files>
```

## Behavior to know about

- **Stays in its library:** `TPipeKeyedDispatcher`, `PipeGroupDispatcher` and
  `TPipeHeartbeatThread` (pipes), `AmqpWallMs` (amqp), `PascalDb.SafeLog` (pascal-db-faa).
  `TPipeKeyedDispatcher` runs on any `TPcThreadPool`; `PipeGroupDispatcher` can be built on
  `PcPool`.
- **`PcPool` is shared by every library in the process**, and created in
  `PascalCommon.ThreadPool`'s initialization (the donors created theirs lazily). Its
  `QueueDepth` counts every library's items. Your unit is finalized before
  `PascalCommon.ThreadPool`, so drain your in-flight items in your own finalization, as before.
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
