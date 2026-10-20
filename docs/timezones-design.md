# IANA time zones — design

Status: **built, T1–T4 (pascal-common-faa 1.22.0)**,
2026-10-20. The user accepted every recommendation below as written ("sim, pode seguir",
2026-10-20). FPC 3.2.2: 391 tests, 0 errors, 0 failures, 0 leaks on Windows x64 and Linux
x86_64 and i386 (Docker); the time zone tests 40 of 40 green at `--cpus=1` with 8 containers at
once; the directory source also against Debian 13's tree. Delphi 12 CE Win32/Win64: 391 of 391, 0 leaks, no EULA reminder (after the golden answers moved to a data file). T5 is
pascal-agenda-faa's. The measurements below were taken on 2026-10-20 on this machine (Windows 11
10.0.26200, Docker 29.3) and are the evidence for each decision.

### Found while building (2026-10-20)

- **IANA was already at 2026e** (`data.iana.org/time-zones/tzdb/version`) while the newest
  Debian image carried 2026c: the embedded data is 2026e, and `tools/check_tzdb.sh` (run by CI as
  a warning) says when IANA moves on. The tarball's signature isn't checked yet: IANA's key isn't
  in the keyring here; `gen_tzdata.py` prints the SHA-512 and checks the `.asc` when it can.
- **Debian 13 builds with backzone**: its `tzdata.zi` lists 436 zones (IANA's default build: 344)
  and 162 links, among them names whose files aren't installed (`US/Eastern`, in
  `tzdata-legacy`). The directory source keeps only names whose file exists and starts with
  `TZif`; history before 1970 legitimately differs from the embedded data there. Debian 12 also
  has `posix/` and `right/` subtrees (skipped) and 365 symbolic links.
- The two references agreed on all **18 700 transitions** (zdump) and 21 492 offsets and 7 380
  gap/overlap answers (Python). Two deliberate faults in the engine (the footer ignored; the DST
  end computed in standard time) made the golden tests report 1 708 and 10 706 differences: they
  can fail.
- Debian's fat files and the embedded slim ones give the same transitions 1990–2037 for the named
  zones (`DirectorySource_System`, Linux only).
- Decision 1b: the generated data unit is 1.1 MB of source (8 900 lines); FPC and Delphi 12 CE
  build it without trouble, and Delphi Win32/Win64 pass 391 of 391 tests with 0 leaks.
- **Delphi Community Edition showed its "EULA Reminder" on every build of the test project** once
  the golden file was a Pascal unit too (1.5 MB, 15 500 lines, on top of the data unit). Measured
  with two one-unit projects: neither the data unit alone (what an application links) nor the
  golden unit alone triggered it; the sum in the test project did. The golden answers are now a
  data file, `tests/Unit/golden/tzdata-golden.txt`, read once per run and found by walking up
  from the executable's folder. An application is not affected by the change; one already near
  that point in CE gets 8 900 more lines from the data unit.

## Why

pascal-agenda-faa (multi-tenant scheduling, a sibling repository; its `docs/design.md`) computes
free slots in M2. Each tenant has an IANA time zone (`America/Sao_Paulo`, `Europe/Lisbon`...),
working hours are the tenant's local clock (`{"weekday":1,"from":"09:00","to":"12:00"}`, ISO
weekday) and everything is stored in UTC (Unix seconds). Its decision 3: real IANA zones, not a
fixed offset table, with a design phase of its own. Listed as "IANA time zones on both compilers"
in pascal-api-infra-faa's `docs/plan.md`, section 10, and now in this repository's `docs/plan.md`,
"Candidates to move here".

Neither RTL converts an arbitrary zone. Delphi's `TTimeZone` knows only the machine's zone; FPC
3.2.2 has nothing public (its `unix` unit reads `/etc/localtime` for the local zone only). A
scheduling, billing or reporting API in any of the `*-faa` libraries' consumers needs the same
thing, which is why it belongs here and not in the application.

## What the agenda needs (the minimum contract)

1. **Local to UTC.** Given a zone, a date and a local time, the instant, with both daylight-saving
   edges resolved: the **gap** (02:30 doesn't exist on the day the clock moves forward) and the
   **overlap** (01:30 happens twice on the day it moves back).
2. **UTC to local.** An instant's offset and local date and time: to show it, and to know its
   local weekday.
3. **A local day's bounds in UTC** (local 00:00 to the next day's 00:00), which aren't always 24 h:
   the availability query is by date.
4. **Validate a zone name.** The tenant catalog stores the name; an invalid one is a 400.

## Measurements (2026-10-20)

### What the systems have

| Target | Time zone data | Notes |
|---|---|---|
| Docker `debian:12-slim` (12.15) | `/usr/share/zoneinfo`, tzdata **2026b**, 900 files, "fat" TZif | the image used by `tools/test_fpc_docker.sh` and the agenda's (`pascalcommon-fpc322`, `agenda-fpc322`: 12.14, 2026b; `pascalcommon-fpc322-i386`: 2026c) |
| Docker `debian:13-slim` (13.7) | tzdata **2026c**, **443 files** | Debian 13 moved the backward names to `tzdata-legacy`, not installed: **`US/Eastern` doesn't exist** there, it does on Debian 12 |
| Docker `alpine:3.20` | **none** | `tzdata` is a separate package |
| Windows 11 — ICU (`icu.dll`, ICU 72.1) | IANA names, tz data **2022g** | four years old on an up-to-date Windows 11. Compared with tzdata 2026b on 598 zones at 16 instants in 2024–2027: **17 zones differ**, among them `America/Vancouver` from 2027 (British Columbia stays on −07 from November 2026), `America/Asuncion`, `Asia/Almaty`, `Africa/Cairo`, `America/Nuuk`. An unknown name, and a known one in another case (`america/new_york`), **silently becomes GMT** (offset 0, no error) |
| Windows 11 — registry (`Time Zones`) | 144 **Windows** zones, `TzVersion` 0x7EA0005 | Windows names (`E. South America Standard Time`), needs CLDR's `windowsZones.xml` to map IANA names; one Windows zone stands for many IANA zones (`Pacific Standard Time` for Los Angeles **and** Vancouver, which now differ); short history: `Dynamic DST` for São Paulo covers 2004–2020, for New York 2006–2007 (one rule before and after) |
| Python 3.12 `zoneinfo` + `tzdata` wheel | tzdata **2026b**, 598 names, "slim" TZif | used here only as the reference to check against |

TZif format, measured on the same zones: Debian builds **fat** files (transitions written out to
2037; `America/New_York` 3552 bytes), the IANA default and the `tzdata` wheel are **slim**
(transitions only up to the last rule change, 1744 bytes; New York's last explicit transition is
in 2007). Both end with a POSIX TZ rule (the "footer") for what comes after:
`EST5EDT,M3.2.0,M11.1.0`. A reader that ignores the footer is wrong for every year after 2007 on
slim data, and after 2037 on fat data.

Size: the 598 names have **341 distinct contents, 204 352 bytes** (slim). Embedding all of it
costs about 200 KB in an executable.

**Do the four targets agree?** With system data they can't: Windows has no IANA data that is
current (ICU) or complete (registry), Alpine has none, and two Debian images built a month apart
carry different releases and different name sets. With data embedded in the library they agree
by construction: the same bytes and the same integer arithmetic on all four.

### The expected values (checked against tzdb, not memory)

Checked on Python `zoneinfo` with tzdata 2026b **and** `zdump -v` on Debian 12 (2026b) and 13
(2026c); the three agree on every value below. Unix seconds; offsets east of UTC.

| Zone | Fact | Value |
|---|---|---|
| America/New_York | spring transition | 1772953200 = 2026-03-08T07:00Z, −05:00 → −04:00 (local 02:00 → 03:00) |
| | 2026-03-08 02:30 (gap) | earlier offset (shifted forward, 03:30 EDT): 1772955000 (07:30Z); later offset: 1772951400 (06:30Z) |
| | autumn transition | 1793512800 = 2026-11-01T06:00Z, −04:00 → −05:00 (local 02:00 → 01:00) |
| | 2026-11-01 01:30 (overlap) | earlier: 1793511000 (05:30Z, EDT); later: 1793514600 (06:30Z, EST) |
| | day 2026-03-08 | [1772946000, 1773028800) = 05:00Z to 04:00Z next day, **23 h** |
| | day 2026-11-01 | [1793505600, 1793595600) = 04:00Z to 05:00Z next day, **25 h** |
| | day 2026-03-09 | 24 h |
| Europe/Lisbon | March transition | 1774746000 = 2026-03-29T01:00Z, +00:00 → +01:00 (local 01:00 → 02:00) |
| | October transition | 1792890000 = 2026-10-25T01:00Z, +01:00 → +00:00 (local 02:00 → 01:00) |
| | days 2026-03-29 / 2026-10-25 | 23 h ([1774742400, 1774825200)) / 25 h ([1792882800, 1792972800)) |
| America/Sao_Paulo | last DST | started 1541300400 = 2018-11-04T03:00Z (local 00:00 → 01:00: **midnight doesn't exist**), ended 1550368800 = 2019-02-17T02:00Z (local 2019-02-16 24:00 → 23:00) |
| | day 2018-11-04 | [1541300400, 1541383200) = starts at **01:00 local**, 23 h |
| | day 2019-02-16 | [1550282400, 1550372400), 25 h |
| | 2019-01-15T12:00Z / 2026-01-15T12:00Z | 10:00 local (−02:00) / 09:00 local (−03:00), Thursday (ISO 4) |
| | since 2019 | no transition (footer `<-03>3`) |
| Asia/Kathmandu | +05:45 | 2026-06-01T00:00Z = 05:45 local; the +05:30 → +05:45 change at 1985-12-31T18:30Z (local 1986-01-01 00:00 → 00:15) |
| Australia/Lord_Howe | DST of 30 minutes | 1775314800 = 2026-04-04T15:00Z, +11:00 → +10:30 (local 02:00 → 01:30); 1791041400 = 2026-10-03T15:30Z, +10:30 → +11:00 (local 02:00 → 02:30) |
| | days 2026-10-04 / 2026-04-05 | **23.5 h** ([1791034200, 1791118800)) / **24.5 h** ([1775307600, 1775395800)) |
| UTC | | offset 0 at any instant; 2026-03-08T07:00Z is ISO weekday 7 |
| Names | Python | `America/New_York`, `US/Eastern`, `UTC`, `Etc/UTC`, `GMT`, `EST5EDT` accepted; `america/new_york` and `Mars/Olympus` refused; `../etc/passwd` refused |

Beyond the tzdb's explicit transitions (Python, the same data): New York 2100-07-01T12:00Z is
08:00 EDT, 2500-01-01T12:00Z is 07:00 EST (the footer); 1800-01-01T12:00Z is 07:03:58 local,
offset −04:56:02 (LMT, the first type in the file: offsets are **seconds**, not minutes).

Footers worth a test each (tzdata 2026c): `America/Nuuk` `<-02>2<-01>,M3.5.0/-1,M10.5.0/0`
(a negative transition time), `Asia/Jerusalem` `IST-2IDT,M3.4.4/26,M10.5.0` (hour 26),
`America/Santiago` `<-04>4<-03>,M9.1.6/24,M4.1.6/24`, `Pacific/Chatham`
`<+1245>-12:45<+1345>,M9.5.0/2:45,M4.1.0/3:45` (minutes in the time),
`Australia/Sydney` (DST across the new year), `Europe/Dublin` `IST-1GMT0,M10.5.0,M3.5.0/1`
(negative DST: winter is the "daylight" type).

## Decisions to take

### 1. The data source

| Option | For | Against (measured) |
|---|---|---|
| **a) The system's**: TZif from `/usr/share/zoneinfo` on Linux; on Windows the registry + CLDR map, or ICU | no data to maintain; Linux gets `apt` updates | ICU on Windows is 2022g: 17 zones wrong today, unknown names silently GMT; the registry has Windows names, one zone for several IANA zones, history from 2004/2006; Alpine has nothing; Debian 12 and 13 differ in versions and names. The four targets don't agree, and a Docker image is frozen at build time anyway |
| **b) Embedded**: the tzdb compiled into the library, the same on all four targets | identical answers everywhere; no dependency on the image or Windows version; ~200 KB | the library must follow the tzdb releases (several a year) |
| **c) A TZif reader with a pluggable source** (embedded, a directory, memory), like pascal-db-faa's `ISqlSource` | b) by default, a) on Linux when an application prefers the system's; tests feed hand-made files from memory | slightly more surface |

**Recommendation: c), with the embedded data as the default source.** One engine reads TZif v2+
(fat or slim) and evaluates the footer; the sources only hand it bytes:

- `TPcEmbeddedTzSource` — the default: the whole tzdb, generated into the library;
- `TPcDirectoryTzSource` — a TZif tree such as `/usr/share/zoneinfo` (Linux, macOS), for an
  application that wants the system's updates and accepts the differences above;
- `TPcMemoryTzSource` — name → bytes, for tests.

No Windows registry or ICU source: neither gives IANA data that is current and complete
(measured). TZif is the only format, so one reader serves every source.

**Update policy for the embedded data** (part of decision 1):

- `tools/gen_tzdata.py <tzdata-YYYYx.tar.gz>` builds the data from IANA's own release (the
  tarball and its signature from `data.iana.org`) with `zic -b slim` in a Debian container
  (`zic` is in `libc-bin`, measured), and writes the generated unit. Then it writes a **golden
  file** from the same compiled tree with Python `zoneinfo` (an independent reader), and the
  test suite checks every zone against it on the four targets.
- `PC_TZDB_VERSION = '2026e'` (a constant) and `TPcTimeZones.DataVersion` say which release is in.
- A tzdb release that changes a zone is a **patch release** of this library (data, not API): a
  zone's offset is a fact about the world, and a consumer on an older patch has the wrong
  answer, not a different contract. CHANGELOG names the zones that changed.
- `tools/check_tzdb.sh` compares `PC_TZDB_VERSION` with `https://data.iana.org/time-zones/tzdb/version`;
  CI may run it as a warning (not a failure, so a new IANA release doesn't turn every
  consumer's CI red).

Sub-decision 1b, **how the bytes are embedded**: a generated Pascal unit with byte-array
constants (no binary file in the repository, no resource compiler, works the same on the four
targets; ~200 KB as about 1 MB of source) or a `.res` (smaller source, but resources on FPC/Linux
and a `.res` built on Windows are one more thing to prove). **Recommendation: the generated
unit**, `PascalCommon.TimeZones.Data`; its compile time and executable size measured in T2 on
Delphi before committing to it (fall back to `.res` if Delphi chokes).

### 2. The years covered

The TZif data covers from its first transition (1800s for most zones) to the last rule change;
the footer covers everything after.

**Recommendation:**

- Any instant whose UTC **and** local date lies in years **1–9999** (proleptic Gregorian, the
  `TDateTime` range); outside it, `EPcTimeZoneError`. Integer arithmetic on Int64 days and
  seconds throughout (no `TDateTime` inside), so no rounding and no compiler difference.
- **Before the first transition: the file's first type** (LMT, e.g. −04:56:02 for New York), as
  zdump and Python do, so the golden comparison holds for the past too. Offsets are whole
  **seconds**.
- **After the last transition: the footer**, computed for the year asked (the two transitions of
  that year, no table). A file without a footer (TZif v1, or an empty footer) keeps its last
  type forever.
- The future is only as right as the data: a country that changes its rules (British Columbia,
  this year) is fixed by the next tzdb release, which is the update policy above.

### 3. The API

**3a. Interface or record.** **Recommendation: an interface, `IPcTimeZone`**, immutable once
built: the library's style (`IClock`, the optionals); the fixed `UTC` zone and a test zone are
other implementations; an application caches one per tenant without copying arrays. Results are
small records (below).

**3b. Units of time.** **Recommendation: Int64 Unix seconds for instants** (what the agenda
stores) **and a wall-clock record for local readings**, `TPcLocalDateTime` (year, month, day,
hour, minute, second; `IsoWeekday`, comparisons). `TDateTime` only as convenience functions with
their own names (`ToLocalDateTime`, `FromLocalDateTime`), not overloads: an `Int64`/`Double`
overload pair makes an integer literal ambiguous.

**3c. Gap and overlap.** What the others do (both documented and matching what was measured):
java.time `ZonedDateTime.of` and NodaTime `AtLeniently` take the **earlier offset in an overlap**
and, **in a gap, shift forward by the gap's length** (02:30 → 03:30 EDT); `ofStrict`/`AtStrictly`
raise; NodaTime's `AtStartOfDay` takes the **start of the interval after** the gap. Python's
`fold=0` gives the same two answers as java.

**Recommendation:**

```pascal
type
  TPcGapRule = (gapShiftForward,  // 02:30 -> 03:30 EDT (java.time, NodaTime lenient) — default
                gapStartOfAfter,  // 02:30 -> 03:00 EDT, the first valid instant
                gapRaise);        // EPcSkippedLocalTime
  TPcOverlapRule = (overlapEarlier, // 01:30 EDT, the first occurrence — default
                    overlapLater,   // 01:30 EST
                    overlapRaise);  // EPcAmbiguousLocalTime

  TPcZoneMapping = record          // what a local reading maps to (NodaTime's ZoneLocalMapping)
    Count: Integer;                // 0 = in a gap, 1 = normal, 2 = in an overlap
    Earlier, Later: Int64;         // the instants when Count >= 1 (equal when 1)
    OffsetBefore, OffsetAfter: Integer; // seconds, around the transition (gap/overlap)
    Transition: Int64;             // the transition's instant (gap/overlap)
  end;

  TPcOffsetInfo = record
    Offset: Integer;               // seconds east of UTC
    IsDst: Boolean;                // as the data says (Europe/Dublin's is inverted)
    Abbreviation: string;          // 'EST', '-03', '+0545'
  end;

  IPcTimeZone = interface
    function Name: string;                        // as asked ('US/Eastern')
    function CanonicalName: string;               // the link's target ('America/New_York')
    function Info(AUtc: Int64): TPcOffsetInfo;
    function OffsetAt(AUtc: Int64): Integer;
    function ToLocal(AUtc: Int64): TPcLocalDateTime;                          // need 2
    function Map(const ALocal: TPcLocalDateTime): TPcZoneMapping;
    function ToUtc(const ALocal: TPcLocalDateTime;
      AGap: TPcGapRule = gapShiftForward;
      AOverlap: TPcOverlapRule = overlapEarlier): Int64;                      // need 1
    procedure DayBounds(AYear, AMonth, ADay: Integer;
      out AStart, AEnd: Int64);                                               // need 3
    function NextTransition(AUtc: Int64; out ATransition: Int64): Boolean;
  end;
```

`DayBounds` is `[ToUtc(D 00:00, gapStartOfAfter, overlapEarlier), ToUtc(D+1 00:00, same))`: São
Paulo's 2018-11-04 starts at 01:00 local (measured above). `AEnd - AStart` is the day's length.
The agenda's working interval `09:00–12:00` is two `ToUtc` calls with the defaults.

**3d. The catalog, the cache and threads.**

```pascal
  TPcTimeZoneCatalog = class           // owns a source and a cache
    constructor Create(const ASource: IPcTzSource);
    function TryFind(const AName: string; out AZone: IPcTimeZone): Boolean;
    function Find(const AName: string): IPcTimeZone;  // EPcUnknownTimeZone
    function IsValidName(const AName: string): Boolean;               // need 4
    function Names: TArray<string>;
    function DataVersion: string;
  end;

  function PcTimeZones: TPcTimeZoneCatalog;   // the default, embedded data
  function PcUtcZone: IPcTimeZone;
```

**Recommendation:** the default catalog is created in `initialization` (the repository's rule;
no lazily created global). Each zone is parsed on its first `Find` and kept; the cache is a
dictionary behind a lock taken on **every** lookup (no double-checked locking, the rule again;
a lookup is a dictionary probe, far cheaper than a request). A zone object is immutable after
construction, so conversions from many threads need no lock at all. Aliases share the parsed
data of their target. An application that prefers `/usr/share/zoneinfo` builds its own
`TPcTimeZoneCatalog.Create(TPcDirectoryTzSource.Create('/usr/share/zoneinfo'))`; the global
default stays the embedded one (no setter on a global).

The alternative, parsing all 598 names in `initialization` (a lock-free read-only dictionary), was
considered: it adds the parse of every zone to the start of every executable that links the unit,
for a lock that costs nothing measurable here. Measured in T2 if it matters.

### 4. Zone names

**Recommendation:**

- **Case-sensitive, exactly as the tzdb spells them**: `america/new_york` is unknown. That is what
  java.time, NodaTime, Python and ICU do (ICU silently, which is worse), and what a Linux directory
  does; a case-insensitive lookup would make the directory source answer differently on Windows
  and Linux. The catalog stores one spelling per tenant. `TryCanonicalCase(AName, out ASpelled)`
  finds the right spelling ignoring case, for an error message ("did you mean
  `America/New_York`?"), never to accept the name silently.
- **The backward links are valid** (`US/Eastern`, `America/Godthab`, `Asia/Calcutta`), as in
  Python and IANA's own build; `CanonicalName` gives the target. With the embedded data that
  doesn't depend on the image (Debian 13 has no `US/Eastern` file).
- **Only names in the catalog**: not `posixrules`, `localtime`, `Factory`, the `.tab` files, nor a
  POSIX TZ string given as a name. A name that isn't `[A-Za-z0-9_+-]` segments separated by `/`
  (no `.`, no `..`, no leading `/`) is refused before any source sees it: the directory source must
  never open `../etc/passwd`.
- `UTC`, `Etc/UTC` and `GMT` are names in the tzdb and valid like any other; `PcUtcZone` is
  `Etc/UTC` without a lookup.

### 5. The name

**`PascalCommon.TimeZones`** (the engine, the catalog, the sources) and
**`PascalCommon.TimeZones.Data`** (generated, the embedded tzdb). Types `TPc*`/`IPc*`, errors
`EPcTimeZoneError` > `EPcUnknownTimeZone`, `EPcSkippedLocalTime`, `EPcAmbiguousLocalTime`.

## Tests

Masters in `tests/Unit/PascalCommon.TimeZonesTests.pas` (DUnitX, FPCUnit dialect), mirror
generated.

- **Known facts**, each from the tables above (every value already checked against tzdb):
  New York's gap and overlap under each `TPcGapRule`/`TPcOverlapRule`, its 23 h and 25 h days;
  Lisbon's two transitions and days; São Paulo's 2017–2019 DST, its day starting at 01:00, no
  DST in 2026; Kathmandu +05:45 and its 1986 change; Lord Howe's 30-minute DST and its 23.5 h and
  24.5 h days; UTC.
- **Names**: an unknown name, the wrong case (refused, `TryCanonicalCase` finds it), a backward
  link, `UTC`/`Etc/UTC`/`GMT`, `../etc/passwd` and an empty name refused.
- **Footer**: each footer listed above, and the far future (New York in 2100 and 2500).
- **Golden**: every zone in the embedded data against the golden file written from the same
  compiled tree by readers that aren't ours: zdump's transitions 1970–2040 (each one, and that no
  other lies between two of them), Python zoneinfo's offsets at 36 instants 1850–2400 for every
  name, and its fold=0/fold=1 answers for a reading inside each gap and overlap since 2010.
  Proves the reader and the footer on all four targets, and that they agree.
- **Sources**: hand-made TZif in memory (v1 only, no footer, empty footer, fat and slim of the same
  zone give the same answers); the directory source against `/usr/share/zoneinfo` on Linux
  (Debian 12 in the test image).
- **Threads**: N threads converting through one catalog from a start event, with a deadline
  (no `Sleep`); run with `--cpus=1` and several containers at once, as `CLAUDE.md` asks.

Acceptance: every test green and 0 leaks on FPC (Windows; Linux x86_64 and i386, Docker) and
Delphi 12 (Win32, Win64).

## Phases (after the decisions)

| # | Where | What | Done when |
|---|---|---|---|
| T1 — done | here | The engine: TZif v1/v2/v3 reader, footer rules, `IPcTimeZone`, `TPcLocalDateTime`, the gap/overlap rules, `DayBounds`, memory source; tests on hand-made files and on the named zones' files | FPC Windows/Linux green, 0 leaks |
| T2 — done | here | `tools/gen_tzdata.py` (IANA tarball → `zic -b slim` → `PascalCommon.TimeZones.Data` + golden file), the catalog, the default embedded source, names; the golden test; Delphi compile time and executable size measured | idem plus Delphi Win32/Win64 (your build) |
| T3 — done | here | The directory source; its tests on Debian 12 and 13 in Docker; `tools/check_tzdb.sh` | idem |
| T4 — done | here | README section, CHANGELOG, `PascalCommon.Version` and `.lpk` 1.22.0, `plan.md`; the skill's `faa-libraries.md` and, when the agenda moves its minimum, `using-faa-libraries/references/application-setup.md` | tag after your "build ok" |
| T5 | pascal-agenda-faa | M2 free slots through `IPcTimeZone`; the tenant's zone validated on create (400 with the spelling hint) | its suites green on the four targets |

T1–T3 may ship as one release (1.22.0); the phases are review points, not releases.
