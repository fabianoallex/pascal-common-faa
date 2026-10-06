# pascal-common-faa — Guide for AI agents

A **dual-compiler** (Delphi + Lazarus/FPC) base library shared by the `*-faa` libraries
(pascal-db-faa, pascal-named-pipes-faa, pascal-amqp-faa, pascal-redis-faa): optional/nullable
types, portable atomics and monotonic time, a monitor and a thread pool, a clock/sleep context
and a bounded cache.

**Work in progress: read [`docs/plan.md`](docs/plan.md) first** — why this library exists, the
decisions already taken, the phases and where they stand.

For the general dual-compiler rules (project anatomy, `.inc`, mirrored tests, CI), use the
`dual-compiler-delphi-lazarus` skill (`../skills/dual-compiler-delphi-lazarus`). This file
records only what is specific to this repo.

---

## Language

Everything in this repository is in **English**: code, identifiers, comments, runtime messages,
test names and assertion messages, documentation and commit messages. Test *data* may contain
non-ASCII values on purpose (e.g. `'São Paulo'`). Code ported from the Portuguese libraries
(pipes, amqp, redis) is translated on the way in.

---

## What belongs here

Only what at least two libraries use, or what a type shared between libraries needs (the
optionals). Everything here is a dependency of every consumer, so the library stays small and
changes slowly. Feature code stays in its library: the keyed dispatcher and heartbeat thread in
pipes, `AmqpWallMs` in amqp. `SafeLog` came here in 1.3.0, once a second library had a copy:
code that must share one lock across the process (a console lock) belongs here as soon as two
libraries need it. pascal-jsonmapper-faa is a separate library on purpose; this repository only
has the optionals bridge to it.

---

## Versioning and consumers (no diamond dependencies)

- **Strict semver.** Within a major version, only additions: no rename, no signature change, no
  behavior change a consumer could observe. That is what lets an application that uses several
  `*-faa` libraries pick the newest version of this one for all of them.
- **`PascalCommon.Version`** holds `PASCALCOMMON_VERSION` (major × 10000 + minor × 100 + patch)
  and `PASCALCOMMON_VERSION_STRING`; bump both with every release, together with the `.lpk`
  version and `CHANGELOG.md`. Consumers check the minimum they need at compile time:

  ```pascal
  {$IF PASCALCOMMON_VERSION < 10400}
    {$MESSAGE FATAL 'pascal-db-faa needs pascal-common-faa 1.4 or later'}
  {$IFEND}
  ```

  (measured on FPC 3.2.2: a constant from another unit is evaluated in `$IF`.)
- **A consumer never ships this library inside itself.** It may have it as a submodule in
  `external/` for its own tests and CI; the application provides the one copy (one registered
  `pascal_common_faa.lpk`, or one search path in Delphi).

---

## Code rules (apply to every unit in `src/` and `bridges/`)

- **Every unit includes `{$I pascalcommon.inc}` right after `unit ...;`.** The `.inc` turns on
  `{$MODE DELPHI}{$H+}` on FPC and normalizes `PASCALCOMMON_WINDOWS`.
- **Prefixes:** units `PascalCommon.*`, free functions `Pc*`, types `TPc*` (interfaces `IPc*`
  when new). The optional types keep their established names (`IOptString`, `TOptionals`...).
- **`uses` without namespaces** (`SysUtils`, `Generics.Collections`), never `System.SysUtils`.
  A Delphi-only unit goes inside `{$IFNDEF FPC}` with its full name (`Winapi.Windows`).
- **No anonymous methods**: stable FPC 3.2.2 doesn't have them. Use a `TThread` subclass or a
  named function/method.
- **Public callbacks follow `PASCALCOMMON_FUNCREFS`** (see `pascalcommon.inc`): `reference to`
  in Delphi, `of object` in FPC.
- **No lazily created shared instances.** A global default (clock, sleep, pool) is created in
  the unit's `initialization`, not on first use: lazy creation raced in pascal-db-faa
  (`TClock`/`TSleep`, fixed in its `5c853c6`), and double-checked locking without a barrier is
  unsafe on weakly ordered CPUs.
- **Never `TDictionary.Create(AComparer)` with a possibly-`nil` `AComparer`** (pascal-db-faa's
  gotcha 1).
- **Top-of-file comment in every unit, program and test**, between `unit X;` (+ `{$I
  pascalcommon.inc}`) and `interface`/`uses`: one sentence saying what the unit is, then
  paragraphs on why it exists, decisions and Delphi × FPC gotchas. Plain prose, no banners. If
  the text quotes something containing `}`, use `(* ... *)`.

---

## Tests

- The masters are the **DUnitX** files in `tests/Unit/*Tests.pas`, written in **FPCUnit's
  assertion dialect** (`TAssert.AssertEquals/AssertTrue/AssertFalse/Fail`), provided on Delphi by
  `tests/Unit/PascalCommon.DUnitXCompat.pas`.
- **`tests/Unit/fpc/*Tests.pas` are generated**: `python tools/gen_fpc_mirror.py`. Never edit
  them by hand. `--check` fails if any mirror is out of date.
- **Run on FPC (Windows):** `sh tools/test_fpc.sh`. **On Linux:** `sh tools/test_fpc_docker.sh`
  (FPC 3.2.2 container; `FPC_IMAGE` selects the image). **CI:** `.github/workflows/ci.yml` only
  calls `sh tools/ci-test.sh`.
- **On Delphi:** open `PascalCommon.groupproj` and run `tests/Unit/PascalCommon.UnitTests.dproj`
  (Win32 and Win64). Delphi Community Edition doesn't compile from the command line: `dcc32`
  prints "This version of the product does not support command line compiling." and **exits
  with code 0**. Don't read that as success.
- **Acceptance criterion:** every test green **and 0 leaks on both sides** (heaptrc on FPC,
  `ReportMemoryLeaksOnShutdown` on Delphi).
- Floating point **always with an explicit delta** (`AssertEquals(E, A, 0)` for exact).
- Concurrency tests must be deterministic: wait on events with a deadline, never on `Sleep` and
  hope. pascal-db-faa reproduced its races with `--cpus=1` and several runners at once on Linux;
  do the same for anything in `Threading`/`ThreadPool`.

---

## Gotchas

Numbered gotchas (symptom → cause → fix) live in [`docs/gotchas.md`](docs/gotchas.md). The ones
inherited with the moved code keep a pointer to their number in the library they came from.
