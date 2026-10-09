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
   2026-10-04 in F2. The known cost was that delphi-api-infra-faa's `Common.SystemContext` and
   `Common.ClockCache` declared the same names (and GUIDs). That clash is gone since F9:
   delphi-api-infra-faa v0.1.0 deleted those units and uses these.

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
The second user appeared: delphi-api-infra-faa's `Common.SafeLog`, the same code with its own
lock. Both moved here as `PascalCommon.SafeLog` in 1.3.0 (2026-10-06); see `migrating.md`,
"SafeLog". Each library switches in its own session.

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
| F8 | pipes, amqp, redis | Each one migrates in its own session | each library's own suites green — **pipes done 2026-10-04** (pascal-named-pipes-faa v0.1.0, on pascal-common-faa v1.0.0): unit 137/137 and integration 139/139, 0 leaks, on FPC Windows/Linux and Delphi Win32/Win64; its Android project compiles. Its findings went into `migrating.md` (an owner of pool work must wait for its own items; `perl -pi` instead of `sed -i`), the README (platforms) and gotchas 3 and 4, released as 1.0.1. **amqp done 2026-10-04** (pascal-amqp-faa v0.1.0, on v1.0.1): unit 121, integration 28, server 459/463, acceptance 28, 0 leaks, on FPC Windows/Linux and Delphi Win32 (Win64 never built in amqp, unrelated to the migration); its broker now has a pool of its own. Its findings went into `migrating.md` (own pool for synchronous work, whole-word renames, queue after Destroy), `TPcThreadPool.MaxWorkers` and gotcha 5, released as 1.1.0. **redis done 2026-10-04** (pascal-redis-faa v0.1.0, on v1.1.0; `Redis.Threading` deleted, the version check in `Redis.Types`): unit 436/436 and integration 69/69, 0 leaks, on FPC Windows/Linux and Delphi Win32/Win64. Its findings went into `migrating.md` (forms must wait in `OnCloseQuery`; heaptrc must be seen on; `packagefiles.xml`) and gotcha 6, released as 1.1.1. **F8 done: every library migrated.** |
| F9 | delphi-api-infra-faa, then delphi-api-starter (and api-test, if still in use) | Replace `Common.Optionals`, `Common.SystemContext` and `Common.ClockCache` with pascal-common-faa's; its consumers provide pascal-common-faa | its unit and integration suites green on Delphi Win32/Win64, 0 leaks; the starter builds and runs — **done 2026-10-05**: delphi-api-infra-faa v0.1.1 (on v1.1.1), Unit 263/263 on Win32 and Win64, 0 leaks; delphi-api-starter `b187b31` (infra v0.1.1, /health, CRUD and search checked); api-test updated locally (no remote). The name and GUID clash is gone. Its findings went into `migrating.md` (consumers that clone with `--recursive`) and the obsolete clash notes were rewritten. Left there: retaweb-local (another consumer of the infra) still to migrate, following its `docs/migracao-pascal-common-faa.md`. |
| F10 | pascal-dfe-broker | Move `vendor/pascal-amqp-faa` to amqp v0.1.0, provide pascal-common-faa itself, rename in `ConsumidorDFeVcl`, make that form wait for its pool items in `OnCloseQuery` | its FPC and Delphi suites, the AMQP integration tests and the Linux CI green, 0 leaks — **done 2026-10-05**: pascal-dfe-broker v0.2.0 (pre-release) on amqp v0.1.0 and pascal-common-faa v1.1.1; pure 417, ACBr×simulator 61, AMQP 19, host and demo, 0 leaks seen in the heaptrc file on Linux; Delphi Win32/Win64 unit 421/421. Its findings went into `migrating.md` (count the marshals a work item posts; `PcPool`'s finalization pumps them on FPC; a project compiling a library from `src` needs only the package) and gotcha 5. For pascal-amqp-faa, in pascal-dfe-broker's `.ci/f10-findings.md`: closing a connection while it reconnects waits up to `ReconnectDelayMs` (a `Sleep` instead of an event), and `DrainInFlight` has no deadline, so it waits on a saturated `PcPool` (read, not measured). |
| F11 | pascal-jsonmapper-faa | `PascalJsonMapper.TestOptionals` says "shaped like PascalDb.Optionals": now `PascalCommon.Optionals` (comment only) | — **done 2026-10-05**: pascal-jsonmapper-faa v0.2.1 (docs and comments; `docs/converters.md` now uses pascal-common-faa's bridge as the example). |
| — | pascal-amqp-faa, after F10 | The broker's findings (closing during a reconnect, `DrainInFlight`) and Win64 | **done 2026-10-05**: pascal-amqp-faa v0.1.1, Delphi Win32 and Win64 green. Its findings for this library: `TPcThreadPool.Queue` didn't grow during a burst (fixed in 1.1.3) and `ProcessorCount` is 1 on FPC/Linux (gotcha 7). Once amqp moves its submodule to 1.1.3, its intermittent test should stop failing. Then, released as 1.2.0: `PcProcessorCount` reads the real CPU count on FPC/Linux, and the default ceiling uses it. |

## Beyond the first four libraries (found 2026-10-05)

A survey of the sibling repositories after F8 found three more places affected:

- **delphi-api-infra-faa** (Delphi only, Horse REST infrastructure; consumed as a submodule in
  `infra/` by delphi-api-starter and api-test) still carries `Common.Optionals`,
  `Common.SystemContext` and `Common.ClockCache`. It is the lineage pascal-db-faa's copies came from.
  Compared declaration by declaration:
  - `Common.Optionals` is pascal-common-faa's plus the deprecated `Safe*` removed in 0.2.0. Only
    one test calls them, the same one that did here.
  - `Common.SystemContext` lacks `TTicker`.
  - `Common.ClockCache` is the same.

  **Its interfaces have the same GUIDs** as pascal-common-faa's (`IOptionalBase`, `INullableBase`,
  `IOptString`, `INullString`, `IOptNullString`, `IOptInteger`, `IClock`, `ISleep` checked). An
  application linking both would hold two different `IOptString` types with one GUID: a
  `Supports`/`QueryInterface` by GUID can hand back the other library's interface, which works
  only while the two method layouts stay identical. Not measured; no project here links both
  today, but an API built on Horse with pascal-db-faa is exactly the case this library exists
  for. Its own JSON mapper (`Common.JsonMapper`) also handles the optionals, with rules
  `PascalCommon.JsonMapper.Optionals` documents as different on purpose. F9 migrates it. That
  removes both the name and the GUID clash. Its DB layer (the ancestor of pascal-db-faa) is out
  of F9's scope.
- **pascal-dfe-broker** pins `vendor/pascal-amqp-faa` at `615b397` (2026-09-19, before amqp's
  migration). Nothing breaks until it moves to amqp v0.1.0; then it must provide pascal-common-faa
  itself, and its VCL/LCL sample `ConsumidorDFeVcl` (queues work with the form as `Self` on
  `AmqpPool`) needs the `OnCloseQuery` wait from `migrating.md`. F10.
- **pascal-jsonmapper-faa**: one comment. F11.

**Future topic: two JSON mappers with different rules for the optionals.** delphi-api-infra-faa
kept its own `Common.JsonMapper`, which now resolves the optionals against
`PascalCommon.Optionals` and passed its suites unchanged. The two rules
`PascalCommon.JsonMapper.Optionals` documents as different are still different (null into an
`IOptXxx`: the infra stores Null, the bridge rejects it; a nil `INullXxx`: the infra omits the
member, the bridge writes null). If the infra ever moves to pascal-jsonmapper-faa with the
bridge, those rules change for the HTTP clients of every API built on it: that is a change to
the APIs' contract, not only an internal one.

No action: delphi-amqp-faa (amqp's predecessor; its references are to itself), pascal-snake (a
comment), pascal-skills-threads, pascal-api-infra-faa (an empty folder then; see "Candidates to move here").

## Candidates to move here (2026-10-08)

Code that lives in one library today and would come here, under this library's rule ("what at
least two libraries need"), when a second one needs it. Listed so a new need finds the existing
code instead of writing a third copy; the skill's `references/faa-libraries.md` points here.

| Code | Lives in | Status |
|---|---|---|
| UTF-8 bytes to string, refusing to corrupt non-ASCII text when the FPC code page isn't UTF-8 | was in pascal-db-faa `PdbUtf8BytesToString` and pascal-api-infra-faa `PaUtf8BytesToString` | **moved in 1.4.0** (`PascalCommon.Utf8`); both keep their function as a wrapper |
| W3C Trace Context: trace/span ids, `traceparent`/`tracestate` | designed in pascal-api-infra-faa's `docs/observability-design.md` (phase A), for that library and, in phase D, pascal-db-faa, pascal-redis-faa and pascal-amqp-faa | **moved in 1.5.0** (`PascalCommon.TraceContext`), written here directly: the contract is fixed by the W3C specification |
| Metrics (counter, gauge, histogram, registry) and the Prometheus text writer | designed in pascal-api-infra-faa's `docs/observability-design.md` (phase B), for that library and, in phase D, the sibling libraries | **moved in 1.6.0** (`PascalCommon.Metrics`), written here directly: the contract is fixed by the exposition format and OpenTelemetry's naming rules |
| String to UTF-8 bytes; MD5 as hex (System.Hash on Delphi, `md5` on FPC); UTF-8-safe prefix | pascal-api-infra-faa `PascalApi.Text` | one library |
| SHA-256, HMAC-SHA256, Base64url, constant-time comparison (FPC 3.2.2 has no SHA-256) | pascal-api-infra-faa `PascalApi.Crypto` (only `SysUtils`; NIST/RFC 4231/RFC 4648 vectors in `PascalApi.CryptoTests`) | one library |

Moving one is additive here (a new unit, a minor release) and then a deprecation in the
library it came from.

## Consumers (2026-10-06)

Which pascal-common-faa each project pins, all committed and pushed:

| Project | Its release | pascal-common-faa |
|---|---|---|
| pascal-db-faa | 0.10.1 | v1.2.0 |
| pascal-named-pipes-faa | 0.1.1 | v1.2.0 |
| pascal-amqp-faa | 0.1.2 | v1.2.0 (requires 1.1.3); its intermittent `ConsomeTodas_ComAck_E_Concorrencia` is gone: 40/40 at `--cpus=1` |
| pascal-redis-faa | 0.1.2 | v1.2.0 (requires 1.2.0) |
| pascal-dfe-broker | 0.2.1 | v1.2.0 |
| delphi-api-infra-faa | 0.1.1 | v1.1.1 |
| delphi-api-starter, api-test | — | v1.1.1 |

delphi-api-infra-faa and its consumers staying on v1.1.1 costs nothing: they use `Optionals`,
`SystemContext` and `ClockCache`, which haven't changed since, and not the pool that 1.1.3 and
1.2.0 fixed.

## Name map

Moved to [`migrating.md`](migrating.md) in F5, together with the steps for a library and the
behavior differences.
