# Single-flight — design

Status: **built, 1.30.0 (2026-11-05)**. The user accepted every recommendation below as written
("aceito tudo", 2026-11-05), S7 included. FPC 3.2.2: 617/617 on Windows x64, 539/539 on Linux
x86_64 and i386, 0 leaks; the single-flight and cache suites 40 runs each green at `--cpus=1`
with 8 containers at once. Delphi 12 CE Win32 and Win64: 617/617, 0 leaks. What building
it settled is in "Decided while building".

## Where this came from

`TPcCache.GetOrLoad` (`PascalCommon.Cache`, 1.29.0, `docs/cache-design.md` C5 and "Decided in
F1") already has a single-flight: concurrent misses of one key run the loader once, the other
threads wait for its result, a loader's exception reaches all of them, and nothing is kept once
the load ends. It is private to the cache (`FLoading`, `TPcCacheFlight`, `Lead`, `EndFlight`,
`ReleaseFlight`).

The pattern is useful without a cache, and today whoever needs it writes it again:

- renewing an expired token once when several requests notice it at the same time;
- loading a tenant's catalog on its first request;
- calls to slow or rate-limited external APIs;
- reconnecting to Redis or AMQP after an outage, once and not once per thread.

The user asked (2026-11-05) to extract it into a generic, reusable unit and to make `TPcCache`
use it inside, with no change to the cache's public API.

## What it is, in one paragraph

`TPcSingleFlight<T>.Run(AKey, ALoader, AArg)`: the first thread that calls it for `AKey` runs
`ALoader(AArg)`; any thread that calls it for the same key while that runs waits, and gets the
same result (or an exception, S3). When the load ends the key is forgotten: the next call runs
the loader again. It is not a cache; it only joins calls that overlap in time, in one process.

## Measured (2026-11-05)

A probe (`TSingleFlight<T>` with a nested `TLoader = function(const AArg: string): T of object`,
a generic flight class `TSfFlight<T>` holding the value, a `TDictionary<string, TSfFlight<T>>`, a
`TEvent` per flight, a virtual method overridden by a subclass of the `string` specialization),
built with `{$MODE DELPHI}` on FPC 3.2.2, with heaptrc:

| What | FPC Win x64 | FPC Linux x86_64 | FPC Linux i386 |
|---|---|---|---|
| specialized for `Integer`, a record with a string, `IInterface`, `string` | runs | runs | runs |
| 8 threads on one key, the loader held until the other 7 wait: 1 call, 8 equal values | yes | yes | yes |
| loader raises `EConvertError`: the leader gets it, the 7 waiters get a recreated `EConvertError`, same message | yes | yes | yes |
| subclass of `TSingleFlight<string>` overriding the waiters' exception | yes | yes | yes |
| `PTypeInfo(TypeInfo(T))^.Kind = tkClass` in the constructor refuses `T = TObject` | yes | yes | yes |
| leaks, apart from the two below | 0 | 0 | 0 |
| `ExceptClass(EOutOfMemory).Create('x').Free`, same for `EInvalidPointer` | **leak** (1 block each) | **leak** | **leak** |
| generic body calling a routine declared only in the `implementation` section | **compile error** | — | — |
| generic body using a unit from the `implementation` `uses` | compiles, runs | — | — |

Conclusions: **the generic works on FPC 3.2.2**, no non-generic fallback is needed. Two
findings shape the design:

1. **FPC: "Global Generic template references static symtable"** when a generic method's body
   calls a routine or uses a constant declared only in the `implementation` section (the body is
   compiled where it is specialized, in another unit). Delphi has the same rule (E2506, "Method of
   parameterized type declared in interface section must not use local symbol"). Helpers go in
   the class (private methods) or in the interface. New gotcha in `docs/gotchas.md`.
2. **Recreating a heap exception leaks it.** `EOutOfMemory` and `EInvalidPointer` (descendants
   of `EHeapMemoryError` on FPC, `EHeapException` on Delphi) have a `FreeInstance` that frees
   only the instances the RTL marks as freeable; one built with `Create` is never freed. S3 wraps
   them instead.

**Delphi 12** (run by the user in the IDE, 2026-11-05): the same probe with `reference to
function(const AArg: string): T`, plus a closure capturing a local. The same output as on FPC
plus `closure:y`; the leak report listed exactly the `EOutOfMemory` and `EInvalidPointer` built on
purpose (and their two message strings). The generic works on both compilers.

## Decisions

### S1 — name and shape (recommended)

```pascal
unit PascalCommon.SingleFlight;

type
  EPcSingleFlight = class(Exception);

  /// Raised in a waiting thread when the loader's exception can't be
  /// recreated (S3), and for a re-entrant call (S7).
  EPcSingleFlightError = class(EPcSingleFlight)
  public
    constructor Create(const AOriginalClassName, AMessage: string);
    property OriginalClassName: string read ...;
  end;

  TPcSingleFlight<T> = class
  public type
    {$IFDEF PASCALCOMMON_FUNCREFS}
    TLoadFunc = reference to function(const AArg: string): T;
    {$ELSE}
    TLoadFunc = function(const AArg: string): T of object;
    {$ENDIF}
  protected
    /// The exception a waiting thread raises when the loader raised (S3).
    function WaiterException(AClass: ExceptClass; const AClassName,
      AMessage: string): Exception; virtual;
  public
    constructor Create;
    destructor Destroy; override;
    /// ALoader(AArg) once per key among the threads that call it together.
    function Run(const AKey: string; const ALoader: TLoadFunc; const AArg: string): T;
    /// Threads waiting now for another thread's load (every key).
    function Waiting: Integer;
  end;
```

- A class the owner creates and frees, as `TPcCache` holds its dictionary today. No interface:
  a generic interface would need a GUID per specialization, and there is no second
  implementation to hide.
- `Waiting` is what `TPcCache.LoadsWaiting` returns today; deterministic tests need it (the
  loader is released only once the others wait).
- The key is a `string`: what every case above has (a cache key, a tenant id, `'token'`, a host).
  A generic key (`TPcSingleFlight<K, T>`) would need an equality comparer and the `TDictionary`
  gotcha (never a possibly-`nil` comparer); not worth it without a case.
- Alternative (only if the Delphi probe fails): non-generic `TPcStringSingleFlight` (string to
  string) plus `TPcInterfaceSingleFlight` (string to `IInterface`), which cover values as JSON and
  any object behind an interface.

### S2 — the loader (recommended)

`TLoadFunc` follows `PASCALCOMMON_FUNCREFS`: a method on FPC 3.2.2, `reference to` on Delphi
(a closure or a method). One `string` argument, like `TPcCacheLoadFunc`, because a method can't
capture the caller's locals.

Only the leader's `ALoader` and `AArg` run; a waiter's are ignored and it gets the leader's
result. So **one key must mean one piece of work**: two calls with the same key and different
`AArg` get the same answer. Documented on `Run`.

`TPcCacheLoadFunc` and `TLoadFunc` are different types (on Delphi two `reference to` types with
the same signature aren't assignment-compatible); the cache doesn't pass its loader through
anyway (S8).

### S3 — the loader's exception (recommended: recreate, with a fallback)

The thread that ran the loader gets the original exception (`raise;`). Each waiting thread gets
a new exception, since one exception object can't be raised in several threads. Which one is the
protected virtual `WaiterException`; the default:

- **the same class, with the same message** (and `HelpContext`): `AClass.Create(AMessage)`, so
  `on E: ETokenRejected do` works the same in every thread. It runs `Exception.Create`, not the
  subclass's own constructor: **a subclass's own fields stay empty** (an `EOSError`'s
  `ErrorCode`, `EPcCacheLoadError`'s `OriginalClassName`) and anything its constructor sets up is
  not there. Documented; an owner that needs more overrides `WaiterException`.
- **`EPcSingleFlightError`** (the original class name in `OriginalClassName`, the same message)
  when the class can't be recreated:
  - what was raised isn't an `Exception` (`AClass = nil`);
  - a heap exception (`EOutOfMemory`, `EInvalidPointer`: measured to leak when built with
    `Create`);
  - `AClass.Create` itself raises.

Alternative: always `EPcSingleFlightError`, which is what the cache does today with
`EPcCacheLoadError`. Predictable, never a half-built exception, but an `on E: EMyError` handler
sees the error only in the thread that happened to lead. The cache keeps its behavior either
way (S8).

### S4 — what T can be (recommended: refuse a class)

Every waiting thread gets a copy of the leader's `T`. Safe: ordinal and float values, `string`
(reference-counted, copy on write), records of those. Shared, so read-only or thread-safe:
interfaces (one object, atomic reference count) and dynamic arrays (one array, no copy on
write: writing an element is seen by every thread). A **class** would give every thread the same
instance with no owner: nobody can free it safely.

Options: (a) refuse a class in the constructor (`EArgumentException` when `TypeInfo(T)` is a
`tkClass`; measured on FPC); (b) document only; (c) a compile-time constraint, which neither
compiler can express ("anything but a class"). Recommendation: (a): it fails on the first
`Create`, in any test, at no cost on `Run`. Interfaces and arrays: documented on the class.

### S5 — nothing outlives the flight (recommended, as today)

A flight is an entry in a dictionary under one lock, with a reference count. The leader removes
the entry **before** it wakes the waiters, so a call that comes after the flight ended starts a
new one; the flight object is freed by the last thread that leaves it (the `ReleaseFlight` of
today). The result is written before the event is set and read after the wait, which orders it
on every CPU. Freeing the `TPcSingleFlight` while a `Run` is in progress is the caller's bug, as
it is for `TPcCache`.

Atomics only through `PascalCommon.Threading` (`PcAtomicInc`/`Dec`/`Get` for `Waiting`).

### S6 — no timeout, no cancellation, no metrics (recommended for now)

- **Timeout for waiters.** The loader bounds its own time (an HTTP or database timeout); a waiter
  that gives up earlier only gets an error sooner while the leader keeps working. Additive later
  (`Run` overload with `ATimeoutMs`, raising `EPcSingleFlightTimeout`; the reference count already
  lets a waiter leave early).
- **Cancellation.** Pascal has no cancellation token shared by both compilers here; a loader that
  must stop on shutdown watches `PascalCommon.StopSignal` itself. Not now.
- **Metrics.** The owner knows what a load is and labels it (`TPcCache` keeps
  `pc.cache.loads`/`load_failures`). A `PcMetrics` series here would need a name per instance;
  additive later as a constructor overload. Only `Waiting` now.

### S7 — a re-entrant call raises instead of hanging (recommended; the user's choice)

A loader that calls `Run` with the same key on the same instance, in the same thread, waits for
itself forever (true of `TPcCache.GetOrLoad` today). The flight records the leader's thread id;
a thread that finds its own flight raises `EPcSingleFlightError` ("re-entrant call for key ...").
A cycle across two threads and two keys still hangs; documented.

For `TPcCache` this turns a hang into an exception. Strictly that is a change a consumer could
observe; nobody can rely on a hang, so the recommendation is to take it and say so in the
CHANGELOG. Alternative: leave it out.

### S8 — `TPcCache` on top of it (recommended)

`TPcCache` keeps its public API, its metrics and `EPcCacheLoadError`:

- a private `TPcSingleFlight<string>` subclass overrides `WaiterException` to return
  `EPcCacheLoadError(AClassName, AMessage)`, so waiters get exactly what they get today;
- the store `Put` must happen **inside** the flight (today: before the flight ends, so a thread
  that misses right after finds the value). On FPC the loader can't be a closure, so `GetOrLoad`
  creates a small object per miss (the cache, the store key, the TTL, the application loader)
  whose method runs the load (with the `loads`/`load_failures` counters) and the `Put`, and passes
  that method to `Run`. One allocation per miss, next to a database query;
- `LoadsWaiting` returns the flights' `Waiting`;
- `Key = ''` still loads without single-flight;
- a non-`Exception` raised by the loader: today the waiters get `EPcCacheLoadError('TObject',
  'The cache loader raised an object that is not an Exception')`; kept by the override (it
  receives `AClass = nil`).

The 26 cache tests stay as they are and must stay green.

### S9 — in the process only (recommended)

One process. For several instances (only one of them renews a shared token, or loads into a
shared Redis), pascal-redis-faa's `TRedisLock` is the distributed lock; the two compose: the
single-flight makes one thread per process ask for the lock.

### S10 — release (recommended)

Additive: minor **1.30.0**. `PascalCommon.Version`, both version fields of the `.lpk` (and the
unit added to it), README (unit list and a usage section), CHANGELOG, `docs/plan.md` ("Candidates"
table), this file's status, and the skill's `references/faa-libraries.md` if it lists the units.

## Decided while building (2026-11-05)

- **A non-generic base, `TPcSingleFlightBase`**, holds the lock, the dictionary, the wait, the
  reference count and the exceptions; `TPcSingleFlight<T>` only adds the constructor's check and
  `Run` (about 30 lines). That is what gotcha 16 asks for, and it keeps the code each
  specialization generates small. The flight is `TPcFlight` (non-generic) with
  `TPcFlightOf<T>` adding `Value`; both are in the interface section, marked internal, because
  the generic's body names them. `WaiterException` is declared on the base, so an override works
  for every `T`.
- **`GetTypeKind(T) = tkClass`** for S4, not `PTypeInfo(TypeInfo(T))^.Kind`: an intrinsic on both
  compilers (measured on FPC 3.2.2), no `TypInfo` unit. Either one needs type information, so an
  enumeration with explicit values (`(a = 1, b = 5)`) can't be `T` ("No type info available" on
  FPC); documented in the unit header.
- **The leader's thread id**: `GetCurrentThreadId` on FPC, `TThread.CurrentThread.ThreadID` on
  Delphi, recorded when the flight is created (S7).
- **S8, a store bug in `Put`.** Before, the leader set the value and ended the flight in a
  `finally` around `Put`: the waiters got the value and the leader got the bug. With `Put` inside
  the loader the bug would have failed the flight and given the waiters `EPcCacheLoadError`.
  `TPcCacheLoadCall` keeps it as it was: it catches the bug (`AcquireExceptionObject`), returns
  the value, and `GetOrLoad` raises it in the leader after `Run`. A test covers it.
- **S8, a non-`Exception` from the cache's loader**: the override gives
  `EPcCacheLoadError('TObject', 'The cache loader raised an object that is not an Exception')`, the
  text of 1.29.0; a test covers it.
- The leader also catches what isn't an `Exception` (a bare `except`, `ExceptObject`), so its
  waiters always wake.
- Two gotchas: 16 (generic bodies and implementation symbols) and 17 (recreating heap
  exceptions).

## Usage

```pascal
type
  TApiClient = class
  private
    FRenew: TPcSingleFlight<string>;
    function RenewToken(const AArg: string): string;   // the loader, a method
  public
    function Token: string;
  end;

function TApiClient.RenewToken(const AArg: string): string;
begin
  // Check again inside: a flight that ended a moment ago may have renewed it.
  if not TokenExpired then
    Exit(CurrentToken);
  Result := FetchNewTokenFromServer;   // its own HTTP timeout bounds the wait
  StoreToken(Result);
end;

function TApiClient.Token: string;
begin
  if not TokenExpired then
    Exit(CurrentToken);
  Result := FRenew.Run('token', RenewToken, '');
end;
```

Not a cache: a call after the flight ended runs the loader again, so the loader checks first
(above) or the caller keeps the result (`TPcCache.GetOrLoad` does both).

## Tests (planned)

Master `tests/Unit/PascalCommon.SingleFlightTests.pas` (DUnitX, FPCUnit dialect), mirror
generated. No `Sleep`: the loader waits on an event released once `Waiting` reaches N − 1, with
a deadline, as the cache's single-flight test does.

- N threads, one key: the loader runs once, every thread gets the same value; `Waiting` back to 0.
- Different keys in parallel: each loader runs, neither waits for the other (both loaders held
  at once, then released).
- The loader raises: the leader gets the original, every waiter an exception of the same class
  and message; a non-`Exception` and `EOutOfMemory` give `EPcSingleFlightError` with the class
  name.
- After a flight (value and exception), the next `Run` runs the loader again.
- `T` as `Integer`, a record, an interface; a class refused in the constructor.
- Re-entrant call raises (if S7 is accepted).
- An override of `WaiterException` is used.
- The 26 cache tests, unchanged.

Concurrency at `--cpus=1` with several containers at once on Linux, as for the cache.

## Phases

| Phase | What | Done when |
|---|---|---|
| D | this document, the probe on Delphi | the user decides S1–S10 — **done 2026-11-05**: all accepted |
| I1 | `PascalCommon.SingleFlight` + tests; `TPcCache` on it | FPC Windows and Linux (x86_64, i386) and Delphi 12 CE Win32/Win64 green, 0 leaks; the cache tests unchanged — **FPC done 2026-11-05**: 617/617 Windows x64, 539/539 Linux x86_64 and i386, 0 leaks, 12 new tests, `PascalCommon.CacheTests.pas` untouched; 40 runs each of both suites at `--cpus=1` with 8 containers at once. Delphi 12 CE Win32 and Win64: 617/617, 0 leaks |
| I2 | release 1.30.0 (S10) | version, `.lpk`, README, CHANGELOG, plan, skill index — **done 2026-11-05**, tag `v1.30.0` |
