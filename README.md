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
| `PascalCommon.Utf8` | `PcTryUtf8BytesToString`: UTF-8 bytes to a string that refuses, on FPC, to corrupt non-ASCII text when the process code page isn't UTF-8; `PcStringToUtf8Bytes`, the other way |
| `PascalCommon.Text` | `PcUpperCase`, `PcLowerCase`: upper and lower case that map every Unicode letter on both compilers, whatever the process locale (`AnsiUpperCase` on FPC/Linux depends on it; gotcha 10). `PcCharCount` (1.21.0): characters as code points, the same on both compilers. `PcFoldForSearch` (1.20.0): a search key, lower case with Latin accents removed and blanks collapsed (`'São  CONCEIÇÃO'` → `'sao conceicao'`), to store next to a name and compare with what the user types, the same on every database |
| `PascalCommon.Crypto` | `PcSha256`, `PcHmacSha256`, `PcBase64UrlEncode`/`Decode`, `PcBytesToHex`, `PcSameBytes` (constant time), `PcPbkdf2HmacSha256` (password hashing, HMAC's states computed once): FPC 3.2.2 has no SHA-256; checked against FIPS 180, RFC 4231, RFC 4648 and RFC 7914 |
| `PascalCommon.AesGcm` | `PcAesGcmEncrypt`, `PcAesGcmDecrypt`: AES-128/192/256-GCM (authenticated encryption with additional data), pure Pascal, checked against NIST and OpenSSL vectors; for secrets at rest (the S-box is a table lookup: see the unit) |
| `PascalCommon.Random` | `PcFillRandom`, `PcRandomBytes`: random bytes from the operating system's cryptographic source (BCryptGenRandom, `/dev/urandom`), for secrets and ids; `EPcRandom` when it fails, never a fallback to `Random` |
| `PascalCommon.TraceContext` | W3C Trace Context: new trace and span ids (`PcNewTraceId`, `PcNewSpanId`, from the OS random source), validation, and `traceparent`/`tracestate` parse and format (`PcTryParseTraceParent`, `PcFormatTraceParent`, `PcResolveTraceState`) |
| `PascalCommon.Metrics` | Counter, up-down counter, gauge and histogram with labels, a registry (`PcMetrics` is the process-wide one), and the Prometheus text exposition (`PcPrometheusText`). OpenTelemetry names and units (`http.server.request.duration`, `s`) become Prometheus names (`http_server_request_duration_seconds`); recording is lock-free on a series |
| `PascalCommon.Tracing` | Spans: `TPcTracing.StartSpan` (a child of the thread's current span), `StartSpanWith`, `StartSpanFromParent` (from a `traceparent` header), `StartDetachedSpan` (never the current span, finished on any thread) with `StartChildSpan` (an explicit parent), attributes and status; parent-based sampling with a ratio; a batch processor that hands finished spans to an `IPcSpanExporter` on its own thread. The exporter (OTLP over HTTP) lives in pascal-api-infra-faa |
| `PascalCommon.Optionals` | Optional and nullable types: `IOptXxx` ("was it provided?"), `INullXxx` ("is it null?") and `IOptNullXxx` (both), for String, Integer, Int64, Single, Double, Currency, TDateTime, Boolean and TGUID, with `TOptionals.Safe`, string normalizers that keep the state (`Trim`, `Upper`, `Lower`, `NullIfEmpty`, `UndefinedIfEmpty`), and `Map`/`Normalize` with your own function or normalizer for every type, all in `TOptionals` and as chainable methods; `ValueOr(default)` on every one (1.19.0). `TOptNullBoolean.From` returns the interface `IOptNullBoolean`; for an `IOptBoolean` or `INullBoolean` use `TrueValue`/`FalseValue` |
| `PascalCommon.Normalizers` | Value normalizers that don't depend on the optionals: a function type and a normalizer interface per type (`TPcStringFunc`/`IPcStringNormalizer`...), and one factory class per type (`TPcStringNormalizers`, `TPcIntegerNormalizers`...), to find them by completion and to inherit with your own: `FromFunc`, `Chain`, and `Trim`/`Upper`/`Lower` for string. The same normalizer works on a plain value (`N.Apply(S)`) and on an optional (`X.Normalize(N)`) |
| `PascalCommon.Validators` | (1.21.0) Checks that refuse a value and change nothing, the normalizers' partner: a validator interface and a factory per type (`TPcStringValidators`: `Required`, `MinLength`, `MaxLength`, `OneOf`; numbers and dates: `Min`, `Max`, `Range`, `MultipleOf`, `MaxDecimals`), `FromFunc`, `All`; `TPcValidation` collects every failing field (an optional checked only when it came) and raises them together as `EPcValidationError`; messages in English and Portuguese |
| `PascalCommon.TimeZones` | (1.22.0) IANA time zones on both compilers (neither RTL converts an arbitrary zone): an instant's local time and offset, a local time's instant with the daylight-saving gap and overlap resolved (java.time's defaults, or your rule), a local day's bounds (23 h, 25 h...), zone names checked case-sensitively (`US/Eastern` and the other backward links accepted). The IANA tzdb is embedded (`PascalCommon.TimeZones.Data`, 2026e, about 200 KB), so the four targets give the same answers; a zoneinfo directory such as `/usr/share/zoneinfo` is an option. Instants are Unix seconds |
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

For a normalization with parameters, which a plain function can't carry, `Normalize` (1.12.0)
is `Map` with an `IPcStringNormalizer`: a class with an `Apply` method.

```pascal
type
  TMaxLength = class(TInterfacedObject, IPcStringNormalizer)
  private
    FMax: Integer;
  public
    constructor Create(AMax: Integer);
    function Apply(const AValue: string): string; // Result := Copy(AValue, 1, FMax)
  end;
...
LZip  := LDto.Zip.Trim.Map(OnlyDigits).Normalize(TMaxLength.Create(8));
LName := TOptionals.Normalize(LDto.Name, TMaxLength.Create(60));
```

The reference count frees the object, so there is no `try/finally`. One instance can also be
kept in a variable and used for many fields.

`Map` and `Normalize` exist for every type, not only string (1.12.0). Each type has its own
function type and normalizer interface: `TPcIntegerFunc`/`IPcIntegerNormalizer`, and likewise
for Int64, Single, Double, Currency, DateTime, Boolean and Guid.

```pascal
function RoundCents(const AValue: Currency): Currency;
...
LPrice    := LDto.Price.Map(RoundCents);
LDeadline := LDto.Deadline.Normalize(TAddBusinessDays.Create(3)); // your IPcDateTimeNormalizer
```

Single and Double keep the source's `DecimalPlaces`, except for a result of 0: `From` returns
its shared zero, whose `DecimalPlaces` is -1.

### One place for your normalizers

With dozens of normalizers, each its own class, finding them gets hard. The unit
`PascalCommon.Normalizers` (1.14.0) has one factory class per type
(`TPcStringNormalizers`, `TPcIntegerNormalizers`, ... `TPcGuidNormalizers`): type
`TPcStringNormalizers.` and the editor lists them. Every factory has `FromFunc` (a plain function
as a normalizer) and `Chain` (several applied in order, as one); the string one also has `Trim`,
`Upper` and `Lower`. Your application inherits a factory and adds its own as class functions, so
the editor lists yours and the library's under one name. The classes behind them stay in the
implementation section:

```pascal
unit App.Normalizers;

interface

uses PascalCommon.Normalizers; // no optionals needed

type
  TNorm = class(TPcStringNormalizers)
  public
    class function MaxLength(AMax: Integer): IPcStringNormalizer; static;
    class function OnlyDigits: IPcStringNormalizer; static;
    class function Cep: IPcStringNormalizer; static;
  end;

implementation

type
  TMaxLength = class(TInterfacedObject, IPcStringNormalizer) ... end;

function DigitsOf(const AValue: string): string; ...

class function TNorm.MaxLength(AMax: Integer): IPcStringNormalizer;
begin
  Result := TMaxLength.Create(AMax);
end;

class function TNorm.OnlyDigits: IPcStringNormalizer;
begin
  Result := FromFunc(DigitsOf);
end;

class function TNorm.Cep: IPcStringNormalizer;
begin
  Result := Chain([Trim, OnlyDigits, MaxLength(8)]); // a business rule, named once
end;

end.
```

The same normalizer serves an optional and a plain value:

```pascal
LDto.Zip  := LDto.Zip.Normalize(TNorm.Cep);       // optional: the state is kept
LDto.Name := LDto.Name.Normalize(TNorm.Chain([TNorm.Trim, TNorm.MaxLength(60)]));

LZip := TNorm.Cep.Apply(EditZip.Text);             // plain string, no optionals
```

`PascalCommon.Normalizers` doesn't depend on `PascalCommon.Optionals` (the dependency goes
`Text` → `Normalizers` → `Optionals`), so code that only normalizes plain values doesn't bring
the optionals in. Keep the rule itself in a plain function and wrap it, as `DigitsOf` above:
code that wants neither objects nor optionals calls the function directly.

Until 1.13 the interfaces and function types were declared in `PascalCommon.Optionals`, which
still has them as aliases (the same types, not copies), so code that uses only that unit builds
unchanged. The factories' 1.13 unit, `PascalCommon.Optionals.Normalizers`, was removed in 1.14:
replace it with `PascalCommon.Normalizers` in the `uses` clause.

- `Trim`, `Upper` and `Lower` return shared instances; they hold no state.
- `Chain([])` returns the value unchanged, and a `nil` item raises `EArgumentException`. The
  chain keeps a reference to each item, so `Chain([TX.Create(...)])` frees `TX` with the chain.
- The library adds a ready-made normalizer only when it is generic (case, blanks, length, digits,
  rounding, a date without its time) and a second library or a measured case needs it. Business
  rules (a CEP, a CPF, a phone number) belong in your factory.
- Use inheritance, not a class helper: Delphi and FPC 3.2 see one helper per type, so two units
  with helpers for the same class hide each other. A library on top of this one can have its own
  factory that inherits this one, and the application can inherit that library's factory.

A method can't be called on `nil`. Where the field may be `nil`, start the chain with `Safe`
(`TOptionals.Safe(LDto.State).Trim.Upper`), or use the `TOptionals` form, which reads `nil` as
`Safe` does. `IOptString`, `INullString` and `IOptNullString` are implemented only by
`TOptNullString`. Don't implement them in your own classes: a minor version may add methods to
them.

Only the string optionals have normalizers. The other types get theirs when a consumer needs
them.

### Time zones

```pascal
uses PascalCommon.TimeZones;

var
  LZone: IPcTimeZone;
  LSpelled: string;
  LStart, LDayStart, LDayEnd: Int64;
begin
  if not PcTimeZones.TryFind(ATenantZone, LZone) then
    if PcTimeZones.TryCanonicalCase(ATenantZone, LSpelled) then
      raise Exception.CreateFmt('Unknown time zone; did you mean %s?', [LSpelled])
    else
      raise Exception.Create('Unknown time zone');
  // Monday's 09:00 in the tenant's zone, as Unix seconds.
  LStart := LZone.ToUtc(TPcLocalDateTime.Create(2026, 3, 9, 9, 0));
  // The local day 2026-03-08 in New York lasts 23 hours.
  LZone.DayBounds(2026, 3, 8, LDayStart, LDayEnd);
  WriteLn(LZone.ToLocal(LStart).IsoWeekday);    // 1 = Monday
end;
```

A local time that doesn't exist (02:30 when the clock jumps from 02:00 to 03:00) moves forward
by the gap, to 03:30; one that happens twice (01:30 when the clock goes back) takes the first.
Pass `gapStartOfAfter`, `gapRaise`, `overlapLater` or `overlapRaise` to `ToUtc` for another rule,
or call `Map` to see every answer. Design, measurements and the update policy for the embedded
data: [`docs/timezones-design.md`](docs/timezones-design.md).

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
