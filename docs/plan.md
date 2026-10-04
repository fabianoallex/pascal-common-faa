# pascal-common-faa — plan

Started 2026-10-04, from a design session in pascal-db-faa. This file is the plan and the record
of why; `CLAUDE.md` holds the rules that stay after the plan is done.

## Why this repository exists

Four libraries carry their own copy of the same infrastructure, and the optional types live in
one of them:

| Library | Unit | Code lines (no comments) | Contents |
|---|---|---|---|
| pascal-named-pipes-faa | `Pipes.Threading` | 526 | atomics + monitor + thread pool + keyed dispatcher + heartbeat thread |
| pascal-amqp-faa | `AMQP.Threading` | 333 | atomics + monitor + thread pool + `AmqpWallMs` |
| pascal-redis-faa | `Redis.Threading` | 320 | atomics + monitor + thread pool |
| pascal-db-faa | `PascalDb.Threading` | 103 | atomics (Int64) + `TickMs` + `TickUs` |

Measured 2026-10-03 (prefixes normalized, comments stripped, `diff`):

- Pipes, AMQP and Redis share one origin (delphi-amqp-faa) and **have not diverged**: the code
  they have in common (atomics, monitor, pool, global pool) is identical line by line. Every
  difference is an addition — AMQP added `AmqpWallMs`; Pipes added `CompareExchange64`, `Add64`,
  `QueueDepth`, `TPipeKeyedDispatcher`, `TPipeHeartbeatThread`. Redis is the plain copy and says
  so in its header ("a bug fix on one side must be ported by hand to the other").
- No fix was made in one copy and missed in another (git history: Redis 1 commit on the unit,
  AMQP 3, Pipes 5, all features).
- `PascalDb.Threading` is a different lineage (from delphi-api-infra-faa): 64-bit counters are
  `Int64` (the others use `UInt64`), it alone has `TickUs`, and it has no monitor or pool. Its
  32-bit atomics and `TickMs` have the same bodies as the others.
- The global pools (`AmqpPool`, `PipePool`, `RedisPool`, `PipeGroupDispatcher`) are created
  lazily with double-checked locking: the first read of the global is outside the lock and has
  no memory barrier. Fine on x86/x64; on a weakly ordered CPU (ARM) it is the same family as the
  `TClock`/`TSleep` race fixed in pascal-db-faa (`5c853c6`). Not measured on ARM.

The optional types (`PascalDb.Optionals`, 1483 lines) depend only on `ClockCache`,
`SystemContext` and `Threading` — no database code. The reason to share them rather than copy
them: an interface's identity is its GUID and its unit. If pipes or amqp had their own
`IOptString`, a DTO filled from a message could not be handed to the database's `IParams`
without converting every field.

## Decisions

1. **One base repository, small and slow-moving.** Optionals and the threading primitives
   together, since the optionals already pull in `Threading` and `ClockCache`.
2. **pascal-jsonmapper-faa stays separate.** It is a feature library (3,100 lines, RTL only, its
   own releases), not infrastructure; putting it here would make every library carry a JSON
   mapper and turn every mapper release into a base release. The optionals bridge
   (`PascalDb.JsonMapper.Optionals`) moves here as an optional package, with the mapper as a
   test-only submodule — the same arrangement pascal-db-faa has today.
3. **Names.** Units `PascalCommon.*` (a bare `Common.*` collides with delphi-api-infra-faa's
   `Common.*`, the same reason pascal-db-faa uses `PascalDb.*`). Free functions `Pc*`
   (`PcAtomicInc`, `PcTickMs`), types `TPc*` (`TPcMonitor`, `TPcThreadPool`). The optional types
   keep their names (`IOptString`, `TOptionals`...), which are already neutral.
4. **No backward compatibility.** None of the libraries has a reported user. No alias units;
   instead, a migration guide (`docs/migrating.md`) with the name map.
5. **Migration order.** pascal-db-faa first, right after this library works (it is the donor and
   its integration suite, 12 adapter × database combinations, exercises the optionals more than
   anything else). Whatever that pilot finds goes into this library before 1.0. Then pipes, amqp
   and redis, each in its own session, in any order.
6. **Diamond dependencies** (an application using db + amqp + pipes, each depending on this
   library) — prevented by four rules, also in `CLAUDE.md`:
   1. a library never ships this one inside itself: the submodule lives in `external/` for tests
      and CI only, and the application provides the single copy (one registered
      `pascal_common_faa.lpk` — Lazarus resolves packages by name — or one search path in Delphi);
   2. strict semver, additive only within a major version, so "different versions" becomes "the
      newest one serves everybody";
   3. a minimum-version check at compile time in each consumer —
      `(*$IF PASCALCOMMON_VERSION < 10400*) (*$MESSAGE FATAL '...'*) (*$IFEND*)` (written with
      braces in real code). Measured on FPC 3.2.2: a constant from another unit is evaluated in
      `$IF`, and the fatal message aborts with the text given. Delphi documents the same
      (constant expressions in `$IF`); to be confirmed in the IDE with the version test;
   4. keep the library small (decision 2).
7. **SystemContext and ClockCache keep their names** (`TClock`, `TTicker`, `TSleep`, `IClock`...,
   `TClockCache`, `TCacheHitRate`...), as the optionals do, instead of the `TPc*` prefix. Decided
   2026-10-04 in F2. Known cost: delphi-api-infra-faa's `Common.SystemContext` and
   `Common.ClockCache` declare the same names, so an application using both must qualify them
   (the unit listed last in `uses` wins otherwise); noted in the unit header.

## What comes in, and from where

| Unit here | From | Notes |
|---|---|---|
| `PascalCommon.Version` | new | `PASCALCOMMON_VERSION` = major × 10000 + minor × 100 + patch |
| `PascalCommon.Threading` | `PascalDb.Threading` + the shared part of `Pipes/AMQP/Redis.Threading` | 32-bit atomics (Inc, Dec, Get, Set, CompareExchange), 64-bit atomics, `PcTickMs`, `PcTickUs` |
| `PascalCommon.ThreadPool` | `Redis.Threading` (the plain copy) + `QueueDepth` from Pipes | `TPcMonitor`, `TPcWorkItem`, `TPcThreadPool`, `PcPool`. Separate unit so pascal-db-faa doesn't link a pool it doesn't use |
| `PascalCommon.SystemContext` | `PascalDb.SystemContext` | `IClock`/`TClock`, `ISleep`/`TSleep`; defaults created in `initialization` (the `5c853c6` fix) |
| `PascalCommon.ClockCache` | `PascalDb.ClockCache` | |
| `PascalCommon.Optionals` | `PascalDb.Optionals` | |
| `PascalCommon.JsonMapper.Optionals` (`bridges/jsonmapper`) | `PascalDb.JsonMapper.Optionals` | package `pascal_common_faa_jsonmapper.lpk`; mapper as submodule `external/pascal-jsonmapper-faa` |

Stays where it is: `TPipeKeyedDispatcher` and `TPipeHeartbeatThread` (pipes), `AmqpWallMs`
(amqp), `PascalDb.SafeLog` (only pascal-db-faa uses it; candidate if a second user appears).

Tests come with the code: `PascalDb.OptionalsTests`, `PascalDb.ClockCacheTests`,
`PascalDb.JsonMapperOptionalsTests` (already in English and in the FPCUnit dialect), and the
atomics/monitor/pool part of `Pipes.ThreadingTests` (Portuguese, DUnitX-native `Assert`:
translate and rewrite in the `TAssert` dialect).

## Open points, to settle with a measurement during implementation

- ~~**Signedness of the 64-bit atomics.**~~ Settled in F1: both, as overloads (`Int64` and
  `UInt64`), sharing one `Int64` implementation. Measured on FPC 3.2.2 (x86_64 Windows/Linux,
  i386 Linux) and Delphi 12 (Win32, Win64).
- ~~**Global pool creation.**~~ Settled in F3: `PcPool` is created in `initialization`. A unit
  that uses `PascalCommon.ThreadPool` is finalized before it, so `PcPool` still runs work there;
  `PascalCommon.ThreadPoolTests`' finalization checks it on every run (FPC and Delphi), and the
  FPC scripts fail on its `FINALIZATION CHECK FAILED` line (the failure path was checked by
  inverting the condition once).
- **Found in F3:** `TXThreadPool.Destroy` never discarded the queued items, although the Pipes
  header and test said so: its workers look at the queue before the shutdown flag, so they
  drain it before they exit. Kept as is (it is the behavior every donor has) and documented;
  the test now asserts that every queued item runs. Worth knowing in F8: pipes' docs describe the
  old, wrong contract.
- ~~**`PcTickUs` on FPC/Unix other than Linux**~~ falls back to `GetTickCount64 × 1000`; noted
  in the unit header (F1).
- **Found in F1:** FPC 3.2.2 has no 64-bit `InterLocked*` on 32-bit CPUs, so the donors' 64-bit
  atomics don't compile on FPC i386 (measured with `PascalDb.Threading`). Fixed here with a lock
  fallback; gotcha 1. CI now also runs the suite on i386.

## Phases

| # | Where | What | Done when |
|---|---|---|---|
| F0 | here | Skeleton: `.inc`, package, `PascalCommon.Version` + test, DUnitX and FPCUnit runners, mirror generator, scripts, CI | FPC suite green with 0 leaks — **done 2026-10-04** on Windows (`tools/test_fpc.sh`) and Linux (`tools/ci-test.sh`); the version check measured to abort the build when the minimum is raised (FPC). Delphi 12 CE Win32 and Win64: 2/2, 0 leaks (the `$IF` on a constant from another unit compiles there; the abort path was only measured on FPC). Committed as `b774354`, public at https://github.com/fabianoallex/pascal-common-faa, GitHub CI green (run 37221548830) |
| F1 | here | `PascalCommon.Threading` (atomics + ticks, merged) with tests | FPC and Delphi green, 0 leaks — **FPC done 2026-10-04**: 15/15, 0 leaks on Windows x64, Linux x86_64 and Linux i386; 40 runs green at `--cpus=1` with 8 containers at once. Delphi 12 CE Win32 and Win64: 15/15, 0 leaks |
| F2 | here | `SystemContext`, `ClockCache`, `Optionals` + their tests | idem — **FPC done 2026-10-04**: 97/97 (ClockCache 12 and Optionals 65, same counts as pascal-db-faa, plus 5 new SystemContext tests), 0 leaks on Windows x64, Linux x86_64 and i386; 40 runs green at `--cpus=1`. Delphi 12 CE Win32 and Win64: 97/97, 0 leaks |
| F3 | here | `PascalCommon.ThreadPool` (monitor + pool, eager global pool) + ported tests | idem — **FPC done 2026-10-04**: 105/105 (8 new ThreadPool tests), 0 leaks on Windows x64, Linux x86_64 and i386; 40 runs green at `--cpus=1`. Delphi 12 CE Win32 and Win64: 105/105, 0 leaks, finalization check silent |
| F4 | here | jsonmapper bridge + submodule + tests | idem; CI checks out submodules — **FPC done 2026-10-04**: 120/120 (15 bridge tests, as in pascal-db-faa), 0 leaks on Windows x64, Linux x86_64 and i386 (the mapper builds on FPC i386 too); mapper v0.2.0 as submodule; the workflow already had `submodules: true`. Delphi 12 CE Win32 and Win64: 120/120, 0 leaks |
| F5 | here | README, `docs/migrating.md` (name map), CHANGELOG, release 0.1.0 | tag pushed (ask first) — **docs done 2026-10-04** (the README example compiled and run on FPC); `PascalCommon.Version` and both `.lpk` were already 0.1.0. Tag `v0.1.0` pushed |
| F6 | pascal-db-faa | **Done 2026-10-04: pascal-db-faa v0.9.0 released on pascal-common-faa 1.0.0.** Findings received 2026-10-04 (pilot against v0.2.0, pascal-db-faa change unreleased, in its `[Unreleased]` as breaking): version bump (solved by 0.2.0), the bridge `.lpk` pointing into an unchecked-out submodule (gotcha 2), and two gaps in `migrating.md` (how to require the package, where the version check goes). Pilot: drop the moved units, `external/pascal-common-faa`, version check, `Pdb*` → `Pc*` | unit suite + the 12 integration combinations + samples green; findings fed back here |
| F7 | here | Fixes from the pilot; release 1.0.0 | Already in, released as 0.2.0 (2026-10-04) for the pilot to point at: the deprecated `TOptNullXxx.Safe*` removed, their logic moved into `TOptionals.Safe`. Pilot findings fixed 2026-10-04 (unreleased): bridge `.lpk` requires the mapper by name, test `.lpi` prefers the submodule copies, `migrating.md` steps 3–5. **Released 1.0.0 (2026-10-04)** |
| F8 | pipes, amqp, redis | Each one migrates in its own session | each library's own suites green — **pipes done 2026-10-04** (pascal-named-pipes-faa v0.1.0, on pascal-common-faa v1.0.0): unit 137/137 and integration 139/139, 0 leaks, on FPC Windows/Linux and Delphi Win32/Win64; its Android project compiles. Its findings went into `migrating.md` (an owner of pool work must wait for its own items; `perl -pi` instead of `sed -i`), the README (platforms) and gotchas 3 and 4, released as 1.0.1. **Pending:** amqp, redis |

## Name map

Moved to [`migrating.md`](migrating.md) in F5, together with the steps for a library and the
behavior differences.
