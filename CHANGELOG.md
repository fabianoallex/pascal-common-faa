# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). While the version is 0.x, a minor version
may change the API; each such change is listed here. From 1.0 on, a minor version only adds.

## [Unreleased]

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

[Unreleased]: https://github.com/fabianoallex/pascal-common-faa/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/fabianoallex/pascal-common-faa/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/fabianoallex/pascal-common-faa/compare/v0.2.0...v1.0.0
[0.2.0]: https://github.com/fabianoallex/pascal-common-faa/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/fabianoallex/pascal-common-faa/releases/tag/v0.1.0
