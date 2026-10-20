unit PascalCommon.TimeZones;

{$I pascalcommon.inc}

{ IANA time zones on both compilers: an instant's local time and offset, a
  local time's instant with the daylight-saving gap and overlap resolved, a
  local day's bounds, and zone names checked against a catalog (1.22.0).

  Why it exists: neither RTL converts an arbitrary zone. Delphi's TTimeZone
  knows only the machine's zone and FPC 3.2.2 has nothing public. A
  scheduling API whose tenants live in different zones (pascal-agenda-faa,
  where it was designed: docs/timezones-design.md) needs "09:00 on Monday in
  America/Sao_Paulo" as an instant, and a local day's bounds for a query by
  date.

    LZone := LCatalog.Find('America/New_York');
    LStart := LZone.ToUtc(TPcLocalDateTime.Create(2026, 3, 9, 9, 0));
    LZone.DayBounds(2026, 3, 8, LDayStart, LDayEnd);   // 23 hours
    LWeekday := LZone.ToLocal(LInstant).IsoWeekday;

  Decisions (docs/timezones-design.md, user 2026-10-20):

  - One engine reads TZif (RFC 8536, versions 1 to 4, "fat" or "slim") and
    evaluates its footer, the POSIX TZ rule that covers everything after the
    last transition (slim files stop at the last rule change: 2007 for New
    York). A source (IPcTzSource) only hands it bytes:
    TPcEmbeddedTzSource, the IANA tzdb compiled into
    PascalCommon.TimeZones.Data (the default, PcTimeZones: the same answers
    on every target); TPcDirectoryTzSource, a tree such as
    /usr/share/zoneinfo (the system's updates, and its differences: Debian 13
    has no US/Eastern and builds with backzone); TPcMemoryTzSource. No
    Windows registry or ICU: measured, neither gives IANA data that is
    current and complete (ICU on Windows 11 was 2022g, and silently answers
    GMT for an unknown name).
  - The embedded data follows IANA's releases: tools/gen_tzdata.py rebuilds
    it, and its golden file, from the release's tarball; a release that
    changes a zone is a patch release of this library (PC_TZDB_VERSION says
    which is in).
  - Instants are Int64 Unix seconds; a local reading is TPcLocalDateTime (no
    zone). TDateTime only through ToLocalDateTime/LocalDateTimeToUtc, named
    apart: an Int64/TDateTime overload pair makes an integer literal
    ambiguous. Inside, only integer arithmetic on days and seconds, so both
    compilers give the same answer.
  - Years 1 to 9999 (proleptic Gregorian), for the UTC and the local side;
    outside, EPcTimeZoneError. Offsets are whole seconds: before a zone's
    first transition the file's first type applies (LMT, -04:56:02 for New
    York), as zdump and Python do.
  - The gap and the overlap follow java.time and NodaTime's lenient rule by
    default: in a gap the reading moves forward by the gap's length (02:30
    becomes 03:30 EDT), in an overlap the earlier offset wins (01:30 EDT).
    TPcGapRule/TPcOverlapRule choose otherwise, Map gives every answer.
    DayBounds starts a day at its first valid instant (São Paulo's
    2018-11-04 started at 01:00).
  - Names are case-sensitive, as the tzdb spells them (as java.time, NodaTime,
    Python and ICU do); TryCanonicalCase finds the spelling for an error
    message. Only names the source lists are zones (not posixrules,
    localtime, Factory); a name that isn't segments of [A-Za-z0-9_+-]
    separated by '/' never reaches a source, so a directory source can't be
    walked out of with '..'.
  - A zone is immutable once built: many threads convert through one zone
    with no lock. A catalog parses a zone on its first Find and keeps it,
    behind a lock taken on every lookup (no double-checked locking); links
    (US/Eastern) share their target's data.
  - Leap-second files (the "right/" tree) are refused: their instants aren't
    Unix seconds.
  - A parameter that takes a source isn't const: TPcMemoryTzSource.Create
    passed to a const interface parameter would never be freed. }

interface

uses
  SysUtils,
  SyncObjs,
  Generics.Collections;

type
  EPcTimeZoneError = class(Exception);
  /// The name isn't a zone of the catalog.
  EPcUnknownTimeZone = class(EPcTimeZoneError);
  /// The local time falls in a gap and the rule was gapRaise.
  EPcSkippedLocalTime = class(EPcTimeZoneError);
  /// The local time falls in an overlap and the rule was overlapRaise.
  EPcAmbiguousLocalTime = class(EPcTimeZoneError);

  /// A wall-clock reading with no zone: what a person reads on a clock.
  TPcLocalDateTime = record
    Year, Month, Day, Hour, Minute, Second: Integer;
    class function Create(AYear, AMonth, ADay: Integer; AHour: Integer = 0;
      AMinute: Integer = 0; ASecond: Integer = 0): TPcLocalDateTime; static;
    /// Year 1..9999, a real date, 00:00:00..23:59:59.
    function IsValid: Boolean;
    /// 1 = Monday .. 7 = Sunday.
    function IsoWeekday: Integer;
    /// The same clock time ADays later (or earlier, when negative).
    function AddDays(ADays: Integer): TPcLocalDateTime;
    function SameAs(const AOther: TPcLocalDateTime): Boolean;
    /// 'YYYY-MM-DDTHH:MM:SS'.
    function ToString: string;
  end;

  TPcGapRule = (
    gapShiftForward,  // 02:30 -> 03:30 EDT: forward by the gap (the default)
    gapStartOfAfter,  // 02:30 -> 03:00 EDT: the first valid instant
    gapRaise);        // EPcSkippedLocalTime

  TPcOverlapRule = (
    overlapEarlier,   // 01:30 EDT, the first occurrence (the default)
    overlapLater,     // 01:30 EST, the second
    overlapRaise);    // EPcAmbiguousLocalTime

  /// What a local reading maps to in a zone.
  TPcZoneMapping = record
    /// 0 = in a gap, 1 = normal, 2 = in an overlap.
    Count: Integer;
    /// The instants when Count >= 1 (equal when 1); undefined when 0.
    Earlier, Later: Int64;
    /// Seconds east of UTC around the transition (gap, overlap); when Count
    /// is 1 both hold the reading's offset.
    OffsetBefore, OffsetAfter: Integer;
    /// The transition's instant (gap, overlap); 0 when Count is 1.
    Transition: Int64;
  end;

  TPcOffsetInfo = record
    /// Seconds east of UTC.
    Offset: Integer;
    /// As the data says: Europe/Dublin's winter is the "daylight" type.
    IsDst: Boolean;
    /// 'EST', '-03', '+0545'.
    Abbreviation: string;
  end;

  IPcTimeZone = interface
    ['{2C991F9B-34EC-4807-83C8-25582D2D6664}']
    /// The name it was found by ('US/Eastern').
    function Name: string;
    /// The link's target ('America/New_York'); Name when not a link.
    function CanonicalName: string;
    function Info(AUtc: Int64): TPcOffsetInfo;
    function OffsetAt(AUtc: Int64): Integer;
    function ToLocal(AUtc: Int64): TPcLocalDateTime;
    function Map(const ALocal: TPcLocalDateTime): TPcZoneMapping;
    function ToUtc(const ALocal: TPcLocalDateTime; AGap: TPcGapRule = gapShiftForward;
      AOverlap: TPcOverlapRule = overlapEarlier): Int64;
    /// [AStart, AEnd): from the local day's first valid instant to the next
    /// day's. AEnd - AStart is the day's length (23 h, 25 h, 23.5 h...).
    procedure DayBounds(AYear, AMonth, ADay: Integer; out AStart, AEnd: Int64);
    /// The next instant after AUtc where the offset changes; False when the
    /// offset never changes again.
    function NextTransition(AUtc: Int64; out ATransition: Int64): Boolean;
    /// ToLocal as a TDateTime (whole seconds).
    function ToLocalDateTime(AUtc: Int64): TDateTime;
    /// ToUtc from a TDateTime local reading, rounded to the nearest second.
    function LocalDateTimeToUtc(ALocal: TDateTime; AGap: TPcGapRule = gapShiftForward;
      AOverlap: TPcOverlapRule = overlapEarlier): Int64;
  end;

  /// Where a catalog takes its zones from.
  IPcTzSource = interface
    ['{3F4E23BA-19A3-4279-A192-95D36F80EBAA}']
    /// The TZif bytes of AName (exact case), or False.
    function TryRead(const AName: string; out AData: TBytes): Boolean;
    /// Every zone and link name the source has.
    function Names: TArray<string>;
    /// A link's target; AName when it isn't a link.
    function CanonicalName(const AName: string): string;
    /// The tzdb release ('2026c'), or '' when unknown.
    function Version: string;
  end;

  /// Zones held in memory: tests, or data an application ships its own way.
  /// Fill it before handing it to a catalog; it isn't locked.
  TPcMemoryTzSource = class(TInterfacedObject, IPcTzSource)
  private
    FData: TDictionary<string, TBytes>;
    FLinks: TDictionary<string, string>;
    FVersion: string;
  public
    constructor Create(const AVersion: string = '');
    destructor Destroy; override;
    procedure Add(const AName: string; const AData: TBytes);
    procedure AddLink(const ALink, ATarget: string);
    function TryRead(const AName: string; out AData: TBytes): Boolean;
    function Names: TArray<string>;
    function CanonicalName(const AName: string): string;
    function Version: string;
  end;

  /// The IANA tzdb compiled into the library (PascalCommon.TimeZones.Data,
  /// generated by tools/gen_tzdata.py): the same answers on every target.
  TPcEmbeddedTzSource = class(TInterfacedObject, IPcTzSource)
  private
    FZones: TDictionary<string, Integer>;
    FLinks: TDictionary<string, Integer>;
  public
    constructor Create;
    destructor Destroy; override;
    function TryRead(const AName: string; out AData: TBytes): Boolean;
    function Names: TArray<string>;
    function CanonicalName(const AName: string): string;
    function Version: string;
  end;

  /// A zoneinfo tree such as /usr/share/zoneinfo (Linux, macOS): the
  /// system's updates, and its differences (docs/timezones-design.md).
  /// The names and links come from the tree's tzdata.zi when it has one,
  /// else from walking it; either way only names whose file exists and
  /// starts with the TZif magic. posix/ and right/ are skipped, and so are
  /// posixrules, localtime and Factory. Listed once, in the constructor.
  TPcDirectoryTzSource = class(TInterfacedObject, IPcTzSource)
  private
    FRoot: string;
    FVersion: string;
    FNames: TArray<string>;
    FLinks: TDictionary<string, string>;
    function FileOf(const AName: string): string;
    function IsZoneFile(const AName: string): Boolean;
    procedure ReadZi(const APath: string; var ANames: TArray<string>);
    procedure Walk(const ADir, APrefix: string; ADepth: Integer; var ANames: TArray<string>);
  public
    constructor Create(const ARoot: string);
    destructor Destroy; override;
    function TryRead(const AName: string; out AData: TBytes): Boolean;
    function Names: TArray<string>;
    function CanonicalName(const AName: string): string;
    function Version: string;
  end;

  /// The zones of one source, parsed on first use and kept. Thread-safe.
  TPcTimeZoneCatalog = class
  private
    FSource: IPcTzSource;
    FLock: TCriticalSection;
    FNames: TArray<string>;
    FNameSet: TDictionary<string, Boolean>;
    FZones: TDictionary<string, IPcTimeZone>;
    FRules: TDictionary<string, IInterface>;  // canonical name -> IPcTzRulesRef
  public
    constructor Create(ASource: IPcTzSource);
    destructor Destroy; override;
    function TryFind(const AName: string; out AZone: IPcTimeZone): Boolean;
    /// EPcUnknownTimeZone when AName isn't a zone.
    function Find(const AName: string): IPcTimeZone;
    /// AName is a zone of the catalog (exact case). Doesn't parse it.
    function IsValidName(const AName: string): Boolean;
    /// The catalog's spelling of AName, ignoring case ('america/new_york' ->
    /// 'America/New_York'): for an error message, not to accept the name.
    function TryCanonicalCase(const AName: string; out ASpelled: string): Boolean;
    /// Every name, sorted (ordinal).
    function Names: TArray<string>;
    function DataVersion: string;
  end;

/// A zone from TZif bytes. EPcTimeZoneError when the data isn't valid TZif.
function PcTimeZoneFromTzif(const AName: string; const AData: TBytes;
  const ACanonicalName: string = ''): IPcTimeZone;

/// The default catalog: the embedded tzdb. Created at unit initialization.
function PcTimeZones: TPcTimeZoneCatalog;

/// Etc/UTC, built in: no lookup, offset 0 at every instant.
function PcUtcZone: IPcTimeZone;

/// Segments of [A-Za-z0-9_+-] separated by '/', at most 128 characters. Says
/// nothing about whether the zone exists.
function PcIsWellFormedTimeZoneName(const AName: string): Boolean;

implementation

uses
  Classes,
  DateUtils,
  PascalCommon.TimeZones.Data;

const
  SECONDS_PER_DAY = 86400;
  // 0001-01-01T00:00:00 and 9999-12-31T23:59:59, as Unix seconds.
  MIN_SECONDS: Int64 = -62135596800;
  MAX_SECONDS: Int64 = 253402300799;
  // A window wider than any offset (RFC 8536: under 26 hours) on each side.
  MAP_WINDOW = 2 * SECONDS_PER_DAY;
  DEFAULT_RULE_TIME = 2 * 3600;
  MAX_NAME_LENGTH = 128;

{ Calendar arithmetic (proleptic Gregorian, Howard Hinnant's algorithms) }

function FloorDiv(A, B: Int64): Int64;
begin
  Result := A div B;
  if ((A mod B) <> 0) and ((A < 0) <> (B < 0)) then
    Dec(Result);
end;

function FloorMod(A, B: Int64): Int64;
begin
  Result := A - FloorDiv(A, B) * B;
end;

function IsLeapYear(AYear: Int64): Boolean;
begin
  Result := ((AYear mod 4 = 0) and (AYear mod 100 <> 0)) or (AYear mod 400 = 0);
end;

function DaysInMonth(AYear: Int64; AMonth: Integer): Integer;
const
  DAYS: array[1..12] of Integer = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
begin
  Result := DAYS[AMonth];
  if (AMonth = 2) and IsLeapYear(AYear) then
    Result := 29;
end;

/// Days since 1970-01-01.
function DaysFromCivil(AYear: Int64; AMonth, ADay: Integer): Int64;
var
  LYear, LEra, LYoe, LDoy, LDoe, LMonth: Int64;
begin
  LYear := AYear;
  if AMonth <= 2 then
    Dec(LYear);
  LEra := FloorDiv(LYear, 400);
  LYoe := LYear - LEra * 400;
  LMonth := AMonth;
  if LMonth > 2 then
    LMonth := LMonth - 3
  else
    LMonth := LMonth + 9;
  LDoy := (153 * LMonth + 2) div 5 + ADay - 1;
  LDoe := LYoe * 365 + LYoe div 4 - LYoe div 100 + LDoy;
  Result := LEra * 146097 + LDoe - 719468;
end;

procedure CivilFromDays(ADays: Int64; out AYear: Int64; out AMonth, ADay: Integer);
var
  LZ, LEra, LDoe, LYoe, LDoy, LMp: Int64;
begin
  LZ := ADays + 719468;
  LEra := FloorDiv(LZ, 146097);
  LDoe := LZ - LEra * 146097;
  LYoe := (LDoe - LDoe div 1460 + LDoe div 36524 - LDoe div 146096) div 365;
  LDoy := LDoe - (365 * LYoe + LYoe div 4 - LYoe div 100);
  LMp := (5 * LDoy + 2) div 153;
  ADay := LDoy - (153 * LMp + 2) div 5 + 1;
  if LMp < 10 then
    AMonth := LMp + 3
  else
    AMonth := LMp - 9;
  AYear := LYoe + LEra * 400;
  if AMonth <= 2 then
    Inc(AYear);
end;

function YearOfDays(ADays: Int64): Integer;
var
  LYear: Int64;
  LMonth, LDay: Integer;
begin
  CivilFromDays(ADays, LYear, LMonth, LDay);
  Result := LYear;
end;

function LocalSeconds(const ALocal: TPcLocalDateTime): Int64;
begin
  Result := DaysFromCivil(ALocal.Year, ALocal.Month, ALocal.Day) * SECONDS_PER_DAY +
    ALocal.Hour * 3600 + ALocal.Minute * 60 + ALocal.Second;
end;

function LocalFromSeconds(ASeconds: Int64): TPcLocalDateTime;
var
  LDays, LSecs, LYear: Int64;
begin
  LDays := FloorDiv(ASeconds, SECONDS_PER_DAY);
  LSecs := ASeconds - LDays * SECONDS_PER_DAY;
  CivilFromDays(LDays, LYear, Result.Month, Result.Day);
  Result.Year := LYear;
  Result.Hour := LSecs div 3600;
  Result.Minute := (LSecs mod 3600) div 60;
  Result.Second := LSecs mod 60;
end;

procedure CheckRange(ASeconds: Int64; const AWhat: string);
begin
  if (ASeconds < MIN_SECONDS) or (ASeconds > MAX_SECONDS) then
    raise EPcTimeZoneError.CreateFmt('%s %d is outside the years 1 to 9999', [AWhat, ASeconds]);
end;

{ TPcLocalDateTime }

class function TPcLocalDateTime.Create(AYear, AMonth, ADay: Integer; AHour: Integer;
  AMinute: Integer; ASecond: Integer): TPcLocalDateTime;
begin
  Result.Year := AYear;
  Result.Month := AMonth;
  Result.Day := ADay;
  Result.Hour := AHour;
  Result.Minute := AMinute;
  Result.Second := ASecond;
end;

function TPcLocalDateTime.IsValid: Boolean;
begin
  Result := (Year >= 1) and (Year <= 9999) and (Month >= 1) and (Month <= 12) and
    (Day >= 1) and (Day <= DaysInMonth(Year, Month)) and (Hour >= 0) and (Hour <= 23) and
    (Minute >= 0) and (Minute <= 59) and (Second >= 0) and (Second <= 59);
end;

function TPcLocalDateTime.IsoWeekday: Integer;
begin
  // 1970-01-01 was a Thursday (ISO 4).
  Result := FloorMod(DaysFromCivil(Year, Month, Day) + 3, 7) + 1;
end;

function TPcLocalDateTime.AddDays(ADays: Integer): TPcLocalDateTime;
var
  LYear: Int64;
begin
  Result := Self;
  CivilFromDays(DaysFromCivil(Year, Month, Day) + ADays, LYear, Result.Month, Result.Day);
  Result.Year := LYear;
end;

function TPcLocalDateTime.SameAs(const AOther: TPcLocalDateTime): Boolean;
begin
  Result := (Year = AOther.Year) and (Month = AOther.Month) and (Day = AOther.Day) and
    (Hour = AOther.Hour) and (Minute = AOther.Minute) and (Second = AOther.Second);
end;

function TPcLocalDateTime.ToString: string;
begin
  Result := Format('%.4d-%.2d-%.2dT%.2d:%.2d:%.2d', [Year, Month, Day, Hour, Minute, Second]);
end;

{ The parsed rules of one zone }

type
  TPcTzRuleDateKind = (rdJulianNoLeap, rdJulianZero, rdMonthWeekDay);

  TPcTzRuleDate = record
    Kind: TPcTzRuleDateKind;
    Number: Integer;       // Jn: 1..365; n: 0..365
    Month, Week, WeekDay: Integer;
    Time: Integer;         // seconds after local midnight, -167h..167h
  end;

  TPcTzType = record
    Offset: Integer;
    IsDst: Boolean;
    Abbr: string;
  end;

  TPcTzChange = record
    At: Int64;
    Before, After: Integer;
  end;

  TPcTzRules = class;

  // Keeps a TPcTzRules alive by reference count and hands it back (an
  // interface can't be cast to its class the same way on both compilers).
  IPcTzRulesRef = interface
    ['{27A46900-B81E-462D-82E2-CE79C5CB390B}']
    function Rules: TPcTzRules;
  end;

  TPcTzRules = class(TInterfacedObject, IPcTzRulesRef)
  private
    FTimes: array of Int64;
    FTypeOf: array of Integer;
    FTypes: array of TPcTzType;
    FHasFooter: Boolean;
    FFooterDst: Boolean;
    FStd, FDst: TPcTzType;
    FStartRule, FEndRule: TPcTzRuleDate;
    function RuleDay(const ARule: TPcTzRuleDate; AYear: Int64): Int64;
    procedure FooterEvents(AYear: Int64; out AStart, AEnd: Int64);
    function FooterTypeAt(AUtc: Int64): TPcTzType;
    function FirstIndexAfter(AUtc: Int64): Integer;
    procedure ParseFooter(const AText: string);
  public
    function Rules: TPcTzRules;
    procedure Parse(const AData: TBytes);
    procedure MakeFixed(AOffset: Integer; const AAbbr: string);
    function TypeAt(AUtc: Int64): TPcTzType;
    function OffsetAt(AUtc: Int64): Integer;
    procedure MapLocal(ALocal: Int64; out AMapping: TPcZoneMapping);
    function NextChange(AUtc: Int64; out AAt: Int64): Boolean;
  end;

procedure SortInt64(var A: array of Int64; ACount: Integer);
var
  I, J: Integer;
  V: Int64;
begin
  for I := 1 to ACount - 1 do
  begin
    V := A[I];
    J := I - 1;
    while (J >= 0) and (A[J] > V) do
    begin
      A[J + 1] := A[J];
      Dec(J);
    end;
    A[J + 1] := V;
  end;
end;

function TPcTzRules.Rules: TPcTzRules;
begin
  Result := Self;
end;

procedure TPcTzRules.MakeFixed(AOffset: Integer; const AAbbr: string);
begin
  SetLength(FTypes, 1);
  FTypes[0].Offset := AOffset;
  FTypes[0].IsDst := False;
  FTypes[0].Abbr := AAbbr;
end;

function TPcTzRules.RuleDay(const ARule: TPcTzRuleDate; AYear: Int64): Int64;
var
  LFirst: Int64;
  LDay, LDow, LDim: Integer;
begin
  case ARule.Kind of
    rdJulianNoLeap:
      begin
        // Jn counts 1..365 and never counts February 29.
        LDay := ARule.Number - 1;
        if IsLeapYear(AYear) and (ARule.Number >= 60) then
          Inc(LDay);
        Result := DaysFromCivil(AYear, 1, 1) + LDay;
      end;
    rdJulianZero:
      Result := DaysFromCivil(AYear, 1, 1) + ARule.Number;
  else
    begin
      LFirst := DaysFromCivil(AYear, ARule.Month, 1);
      LDow := FloorMod(LFirst + 4, 7);   // 0 = Sunday; 1970-01-01 was a Thursday
      LDay := (ARule.WeekDay - LDow + 7) mod 7 + (ARule.Week - 1) * 7;
      LDim := DaysInMonth(AYear, ARule.Month);
      while LDay >= LDim do
        Dec(LDay, 7);                   // week 5 means "the last"
      Result := LFirst + LDay;
    end;
  end;
end;

procedure TPcTzRules.FooterEvents(AYear: Int64; out AStart, AEnd: Int64);
begin
  // The start is given in standard time, the end in daylight time.
  AStart := RuleDay(FStartRule, AYear) * SECONDS_PER_DAY + FStartRule.Time - FStd.Offset;
  AEnd := RuleDay(FEndRule, AYear) * SECONDS_PER_DAY + FEndRule.Time - FDst.Offset;
end;

function TPcTzRules.FooterTypeAt(AUtc: Int64): TPcTzType;
var
  LStart, LEnd, LBest: Int64;
  LYear, Y: Integer;
  LFound, LBestDst: Boolean;

  procedure Consider(AAt: Int64; AIsStart: Boolean);
  begin
    if AAt > AUtc then
      Exit;
    // On a tie the start wins: "daylight all year" rules end one year at the
    // instant the next one starts.
    if (not LFound) or (AAt > LBest) or ((AAt = LBest) and AIsStart) then
    begin
      LFound := True;
      LBest := AAt;
      LBestDst := AIsStart;
    end;
  end;

begin
  if not FFooterDst then
    Exit(FStd);
  LYear := YearOfDays(FloorDiv(AUtc + FStd.Offset, SECONDS_PER_DAY));
  LFound := False;
  LBest := 0;
  LBestDst := False;
  for Y := LYear - 1 to LYear + 1 do
  begin
    FooterEvents(Y, LStart, LEnd);
    Consider(LEnd, False);
    Consider(LStart, True);
  end;
  if LFound and LBestDst then
    Result := FDst
  else
    Result := FStd;
end;

function TPcTzRules.FirstIndexAfter(AUtc: Int64): Integer;
var
  LLow, LHigh, LMid: Integer;
begin
  LLow := 0;
  LHigh := Length(FTimes);
  while LLow < LHigh do
  begin
    LMid := (LLow + LHigh) div 2;
    if FTimes[LMid] <= AUtc then
      LLow := LMid + 1
    else
      LHigh := LMid;
  end;
  Result := LLow;
end;

function TPcTzRules.TypeAt(AUtc: Int64): TPcTzType;
var
  N, I: Integer;
begin
  N := Length(FTimes);
  if N = 0 then
  begin
    if FHasFooter then
      Result := FooterTypeAt(AUtc)
    else
      Result := FTypes[0];
    Exit;
  end;
  // RFC 8536: before the first transition, the first type.
  if AUtc < FTimes[0] then
    Exit(FTypes[0]);
  if (AUtc >= FTimes[N - 1]) and FHasFooter then
    Exit(FooterTypeAt(AUtc));
  I := FirstIndexAfter(AUtc) - 1;
  Result := FTypes[FTypeOf[I]];
end;

function TPcTzRules.OffsetAt(AUtc: Int64): Integer;
begin
  Result := TypeAt(AUtc).Offset;
end;

procedure TPcTzRules.MapLocal(ALocal: Int64; out AMapping: TPcZoneMapping);
var
  LFrom, LTo, LStart, LEnd, LU, LSince: Int64;
  LYear, LFirstYear, LLastYear: Integer;
  LCandidates: array of Int64;
  LChanges: array of TPcTzChange;
  LFound: array[0..7] of Int64;
  LCount, LChangeCount, LFoundCount, I, LOffset, LPrev: Integer;

  procedure AddCandidate(AAt: Int64);
  begin
    if (AAt <= LFrom) or (AAt > LTo) then
      Exit;
    if LCount = Length(LCandidates) then
      SetLength(LCandidates, LCount * 2 + 8);
    LCandidates[LCount] := AAt;
    Inc(LCount);
  end;

  procedure AddFound(AAt: Int64);
  begin
    if LFoundCount <= High(LFound) then
    begin
      LFound[LFoundCount] := AAt;
      Inc(LFoundCount);
    end;
  end;

begin
  LFrom := ALocal - MAP_WINDOW;
  LTo := ALocal + MAP_WINDOW;

  // Every instant in the window where the offset may change.
  LCount := 0;
  SetLength(LCandidates, 8);
  I := FirstIndexAfter(LFrom);
  while (I < Length(FTimes)) and (FTimes[I] <= LTo) do
  begin
    AddCandidate(FTimes[I]);
    Inc(I);
  end;
  if FHasFooter and FFooterDst then
  begin
    LFirstYear := YearOfDays(FloorDiv(LFrom, SECONDS_PER_DAY)) - 1;
    LLastYear := YearOfDays(FloorDiv(LTo, SECONDS_PER_DAY)) + 1;
    for LYear := LFirstYear to LLastYear do
    begin
      FooterEvents(LYear, LStart, LEnd);
      AddCandidate(LStart);
      AddCandidate(LEnd);
    end;
  end;
  SortInt64(LCandidates, LCount);

  // The changes of offset, in order.
  SetLength(LChanges, LCount);
  LChangeCount := 0;
  LPrev := OffsetAt(LFrom);
  for I := 0 to LCount - 1 do
  begin
    if (I > 0) and (LCandidates[I] = LCandidates[I - 1]) then
      Continue;
    LOffset := OffsetAt(LCandidates[I]);
    if LOffset <> LPrev then
    begin
      LChanges[LChangeCount].At := LCandidates[I];
      LChanges[LChangeCount].Before := LPrev;
      LChanges[LChangeCount].After := LOffset;
      Inc(LChangeCount);
      LPrev := LOffset;
    end;
  end;

  // Each interval of constant offset gives the reading an instant, which
  // counts when it falls inside that interval.
  LFoundCount := 0;
  LSince := LFrom;
  LOffset := OffsetAt(LFrom);
  for I := 0 to LChangeCount - 1 do
  begin
    LU := ALocal - LOffset;
    if (LU >= LSince) and (LU < LChanges[I].At) then
      AddFound(LU);
    LSince := LChanges[I].At;
    LOffset := LChanges[I].After;
  end;
  LU := ALocal - LOffset;
  if LU >= LSince then
    AddFound(LU);

  AMapping.Transition := 0;
  if LFoundCount = 1 then
  begin
    AMapping.Count := 1;
    AMapping.Earlier := LFound[0];
    AMapping.Later := LFound[0];
    AMapping.OffsetBefore := ALocal - LFound[0];
    AMapping.OffsetAfter := AMapping.OffsetBefore;
    Exit;
  end;

  AMapping.Earlier := 0;
  AMapping.Later := 0;
  if LFoundCount = 0 then
  begin
    AMapping.Count := 0;
    for I := 0 to LChangeCount - 1 do
      if (LChanges[I].After > LChanges[I].Before) and
        (ALocal >= LChanges[I].At + LChanges[I].Before) and
        (ALocal < LChanges[I].At + LChanges[I].After) then
      begin
        AMapping.OffsetBefore := LChanges[I].Before;
        AMapping.OffsetAfter := LChanges[I].After;
        AMapping.Transition := LChanges[I].At;
        Exit;
      end;
    raise EPcTimeZoneError.CreateFmt('Local time %d has no instant and no gap', [ALocal]);
  end;

  AMapping.Count := 2;
  AMapping.Earlier := LFound[0];
  AMapping.Later := LFound[0];
  for I := 1 to LFoundCount - 1 do
  begin
    if LFound[I] < AMapping.Earlier then
      AMapping.Earlier := LFound[I];
    if LFound[I] > AMapping.Later then
      AMapping.Later := LFound[I];
  end;
  AMapping.OffsetBefore := ALocal - AMapping.Earlier;
  AMapping.OffsetAfter := ALocal - AMapping.Later;
  for I := 0 to LChangeCount - 1 do
    if (LChanges[I].After < LChanges[I].Before) and
      (ALocal >= LChanges[I].At + LChanges[I].After) and
      (ALocal < LChanges[I].At + LChanges[I].Before) then
    begin
      AMapping.OffsetBefore := LChanges[I].Before;
      AMapping.OffsetAfter := LChanges[I].After;
      AMapping.Transition := LChanges[I].At;
      Break;
    end;
end;

function TPcTzRules.NextChange(AUtc: Int64; out AAt: Int64): Boolean;
var
  LPrev, N, I, LCount: Integer;
  LFrom, LStart, LEnd: Int64;
  LYear, Y: Integer;
  LEvents: array[0..7] of Int64;
begin
  Result := False;
  AAt := 0;
  LPrev := OffsetAt(AUtc);
  N := Length(FTimes);
  I := FirstIndexAfter(AUtc);
  while I < N do
  begin
    if OffsetAt(FTimes[I]) <> LPrev then
    begin
      AAt := FTimes[I];
      Exit(True);
    end;
    Inc(I);
  end;
  if not (FHasFooter and FFooterDst) then
    Exit;
  LFrom := AUtc;
  if (N > 0) and (FTimes[N - 1] > LFrom) then
    LFrom := FTimes[N - 1];
  LYear := YearOfDays(FloorDiv(LFrom, SECONDS_PER_DAY));
  if LYear > 9999 then
    Exit;
  LCount := 0;
  for Y := LYear - 1 to LYear + 2 do
  begin
    FooterEvents(Y, LStart, LEnd);
    LEvents[LCount] := LStart;
    LEvents[LCount + 1] := LEnd;
    Inc(LCount, 2);
  end;
  SortInt64(LEvents, LCount);
  for I := 0 to LCount - 1 do
    if (LEvents[I] > LFrom) and (OffsetAt(LEvents[I]) <> LPrev) then
    begin
      AAt := LEvents[I];
      Exit(True);
    end;
end;

{ TPcTzRules: the footer (a POSIX TZ string, RFC 8536 section 3.3) }

procedure TPcTzRules.ParseFooter(const AText: string);
var
  P, L: Integer;

  procedure Fail;
  begin
    raise EPcTimeZoneError.CreateFmt('Invalid TZ rule "%s" at position %d', [AText, P]);
  end;

  function AtEnd: Boolean;
  begin
    Result := P > L;
  end;

  function IsDigit(C: Char): Boolean;
  begin
    Result := (C >= '0') and (C <= '9');
  end;

  function IsAlpha(C: Char): Boolean;
  begin
    Result := ((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z'));
  end;

  function ReadNumber(AMax: Integer): Integer;
  begin
    if AtEnd or not IsDigit(AText[P]) then
      Fail;
    Result := 0;
    while (not AtEnd) and IsDigit(AText[P]) do
    begin
      Result := Result * 10 + Ord(AText[P]) - Ord('0');
      if Result > AMax then
        Fail;
      Inc(P);
    end;
  end;

  function ReadAbbr: string;
  var
    LStart: Integer;
  begin
    if AtEnd then
      Fail;
    if AText[P] = '<' then
    begin
      Inc(P);
      LStart := P;
      while (not AtEnd) and (AText[P] <> '>') do
        Inc(P);
      if AtEnd or (P - LStart < 3) then
        Fail;
      Result := Copy(AText, LStart, P - LStart);
      Inc(P);
    end
    else
    begin
      LStart := P;
      while (not AtEnd) and IsAlpha(AText[P]) do
        Inc(P);
      if P - LStart < 3 then
        Fail;
      Result := Copy(AText, LStart, P - LStart);
    end;
  end;

  // [+-]hh[:mm[:ss]], in seconds.
  function ReadTime(AMaxHours: Integer): Integer;
  var
    LSign: Integer;
  begin
    LSign := 1;
    if (not AtEnd) and ((AText[P] = '+') or (AText[P] = '-')) then
    begin
      if AText[P] = '-' then
        LSign := -1;
      Inc(P);
    end;
    Result := ReadNumber(AMaxHours) * 3600;
    if (not AtEnd) and (AText[P] = ':') then
    begin
      Inc(P);
      Result := Result + ReadNumber(59) * 60;
      if (not AtEnd) and (AText[P] = ':') then
      begin
        Inc(P);
        Result := Result + ReadNumber(59);
      end;
    end;
    Result := Result * LSign;
  end;

  procedure ReadRuleDate(out ARule: TPcTzRuleDate);
  begin
    if AtEnd then
      Fail;
    if AText[P] = 'J' then
    begin
      Inc(P);
      ARule.Kind := rdJulianNoLeap;
      ARule.Number := ReadNumber(365);
      if ARule.Number < 1 then
        Fail;
    end
    else if AText[P] = 'M' then
    begin
      Inc(P);
      ARule.Kind := rdMonthWeekDay;
      ARule.Month := ReadNumber(12);
      if (ARule.Month < 1) or AtEnd or (AText[P] <> '.') then
        Fail;
      Inc(P);
      ARule.Week := ReadNumber(5);
      if (ARule.Week < 1) or AtEnd or (AText[P] <> '.') then
        Fail;
      Inc(P);
      ARule.WeekDay := ReadNumber(6);
    end
    else
    begin
      ARule.Kind := rdJulianZero;
      ARule.Number := ReadNumber(365);
    end;
    ARule.Time := DEFAULT_RULE_TIME;
    if (not AtEnd) and (AText[P] = '/') then
    begin
      Inc(P);
      ARule.Time := ReadTime(167);
    end;
  end;

  procedure DefaultRule(AMonth, AWeek: Integer; out ARule: TPcTzRuleDate);
  begin
    ARule.Kind := rdMonthWeekDay;
    ARule.Number := 0;
    ARule.Month := AMonth;
    ARule.Week := AWeek;
    ARule.WeekDay := 0;
    ARule.Time := DEFAULT_RULE_TIME;
  end;

begin
  P := 1;
  L := Length(AText);
  FHasFooter := False;
  FFooterDst := False;
  if L = 0 then
    Exit;
  FStd.Abbr := ReadAbbr;
  FStd.IsDst := False;
  // POSIX offsets are west of UTC.
  FStd.Offset := -ReadTime(24);
  FHasFooter := True;
  if AtEnd then
    Exit;
  FDst.Abbr := ReadAbbr;
  FDst.IsDst := True;
  FDst.Offset := FStd.Offset + 3600;
  if (not AtEnd) and (AText[P] <> ',') then
    FDst.Offset := -ReadTime(24);
  if AtEnd then
  begin
    // No rule: the POSIX default (the United States' rule, as glibc does).
    DefaultRule(3, 2, FStartRule);
    DefaultRule(11, 1, FEndRule);
  end
  else
  begin
    if AText[P] <> ',' then
      Fail;
    Inc(P);
    ReadRuleDate(FStartRule);
    if AtEnd or (AText[P] <> ',') then
      Fail;
    Inc(P);
    ReadRuleDate(FEndRule);
    if not AtEnd then
      Fail;
  end;
  FFooterDst := True;
end;

{ TPcTzRules: TZif (RFC 8536) }

procedure TPcTzRules.Parse(const AData: TBytes);
var
  P: Integer;

  procedure Fail(const AWhy: string);
  begin
    raise EPcTimeZoneError.Create('Invalid TZif data: ' + AWhy);
  end;

  procedure Need(ACount: Int64);
  begin
    if (ACount < 0) or (P + ACount > Length(AData)) then
      Fail('truncated');
  end;

  function U32(AAt: Integer): Cardinal;
  begin
    Result := (Cardinal(AData[AAt]) shl 24) or (Cardinal(AData[AAt + 1]) shl 16) or
      (Cardinal(AData[AAt + 2]) shl 8) or Cardinal(AData[AAt + 3]);
  end;

  function I32(AAt: Integer): Integer;
  begin
    Result := Integer(U32(AAt));
  end;

  function I64(AAt: Integer): Int64;
  begin
    Result := (Int64(I32(AAt)) shl 32) or Int64(U32(AAt + 4));
  end;

  procedure ReadHeader(out AVersion: Byte; out AIsUt, AIsStd, ALeap, ATime, AType,
    AChar: Int64);
  begin
    Need(44);
    if (AData[P] <> Ord('T')) or (AData[P + 1] <> Ord('Z')) or (AData[P + 2] <> Ord('i')) or
      (AData[P + 3] <> Ord('f')) then
      Fail('no TZif magic');
    AVersion := AData[P + 4];
    AIsUt := U32(P + 20);
    AIsStd := U32(P + 24);
    ALeap := U32(P + 28);
    ATime := U32(P + 32);
    AType := U32(P + 36);
    AChar := U32(P + 40);
    Inc(P, 44);
  end;

  // One data block; ATimeSize is 4 (version 1) or 8.
  procedure ReadBlock(ATimeSize: Integer; AIsUt, AIsStd, ALeap, ATime, AType, AChar: Int64);
  var
    I, LTypeStart, LCharStart, LIdx, LEnd: Integer;
    LAbbrs: string;
  begin
    if AType = 0 then
      Fail('no local time type');
    if ALeap <> 0 then
      Fail('leap-second data (the "right/" tree) is not supported');
    if ((AIsUt <> 0) and (AIsUt <> AType)) or ((AIsStd <> 0) and (AIsStd <> AType)) then
      Fail('indicator counts');
    Need(ATime * ATimeSize + ATime + AType * 6 + AChar + ALeap * (ATimeSize + 4) + AIsStd + AIsUt);
    SetLength(FTimes, ATime);
    SetLength(FTypeOf, ATime);
    for I := 0 to ATime - 1 do
    begin
      if ATimeSize = 4 then
        FTimes[I] := I32(P + I * 4)
      else
        FTimes[I] := I64(P + I * 8);
      if (I > 0) and (FTimes[I] <= FTimes[I - 1]) then
        Fail('transitions out of order');
    end;
    Inc(P, ATime * ATimeSize);
    for I := 0 to ATime - 1 do
    begin
      FTypeOf[I] := AData[P + I];
      if FTypeOf[I] >= AType then
        Fail('type index');
    end;
    Inc(P, ATime);
    LTypeStart := P;
    LCharStart := P + AType * 6;
    SetLength(LAbbrs, AChar);
    for I := 0 to AChar - 1 do
      LAbbrs[I + 1] := Char(AData[LCharStart + I]);
    SetLength(FTypes, AType);
    for I := 0 to AType - 1 do
    begin
      FTypes[I].Offset := I32(LTypeStart + I * 6);
      FTypes[I].IsDst := AData[LTypeStart + I * 6 + 4] <> 0;
      LIdx := AData[LTypeStart + I * 6 + 5];
      if LIdx >= AChar then
        Fail('abbreviation index');
      LEnd := LIdx + 1;
      while (LEnd <= AChar) and (LAbbrs[LEnd] <> #0) do
        Inc(LEnd);
      FTypes[I].Abbr := Copy(LAbbrs, LIdx + 1, LEnd - LIdx - 1);
    end;
    Inc(P, AType * 6 + AChar + ALeap * (ATimeSize + 4) + AIsStd + AIsUt);
  end;

var
  LVersion: Byte;
  LIsUt, LIsStd, LLeap, LTime, LType, LChar: Int64;
  LStart, I: Integer;
  LFooter: string;
begin
  P := 0;
  ReadHeader(LVersion, LIsUt, LIsStd, LLeap, LTime, LType, LChar);
  if LVersion = 0 then
  begin
    ReadBlock(4, LIsUt, LIsStd, LLeap, LTime, LType, LChar);
    FHasFooter := False;
    Exit;
  end;
  if (LVersion < Ord('2')) or (LVersion > Ord('9')) then
    Fail('version');
  // Version 2 and later: skip the 32-bit block, read the 64-bit one.
  Need(LTime * 4 + LTime + LType * 6 + LChar + LLeap * 8 + LIsStd + LIsUt);
  Inc(P, LTime * 4 + LTime + LType * 6 + LChar + LLeap * 8 + LIsStd + LIsUt);
  ReadHeader(LVersion, LIsUt, LIsStd, LLeap, LTime, LType, LChar);
  ReadBlock(8, LIsUt, LIsStd, LLeap, LTime, LType, LChar);
  // The footer: newline, the TZ string, newline.
  Need(1);
  if AData[P] <> 10 then
    Fail('footer');
  Inc(P);
  LStart := P;
  while (P < Length(AData)) and (AData[P] <> 10) do
    Inc(P);
  if P >= Length(AData) then
    Fail('footer');
  SetLength(LFooter, P - LStart);
  for I := 0 to P - LStart - 1 do
    LFooter[I + 1] := Char(AData[LStart + I]);
  ParseFooter(LFooter);
end;

{ The zone }

type
  TPcTimeZone = class(TInterfacedObject, IPcTimeZone)
  private
    FName: string;
    FCanonical: string;
    FRules: TPcTzRules;
    FRulesRef: IPcTzRulesRef;
    function Resolve(ALocal: Int64; AGap: TPcGapRule; AOverlap: TPcOverlapRule): Int64;
  public
    constructor Create(const AName, ACanonical: string; ARules: TPcTzRules);
    function Name: string;
    function CanonicalName: string;
    function Info(AUtc: Int64): TPcOffsetInfo;
    function OffsetAt(AUtc: Int64): Integer;
    function ToLocal(AUtc: Int64): TPcLocalDateTime;
    function Map(const ALocal: TPcLocalDateTime): TPcZoneMapping;
    function ToUtc(const ALocal: TPcLocalDateTime; AGap: TPcGapRule = gapShiftForward;
      AOverlap: TPcOverlapRule = overlapEarlier): Int64;
    procedure DayBounds(AYear, AMonth, ADay: Integer; out AStart, AEnd: Int64);
    function NextTransition(AUtc: Int64; out ATransition: Int64): Boolean;
    function ToLocalDateTime(AUtc: Int64): TDateTime;
    function LocalDateTimeToUtc(ALocal: TDateTime; AGap: TPcGapRule = gapShiftForward;
      AOverlap: TPcOverlapRule = overlapEarlier): Int64;
  end;

constructor TPcTimeZone.Create(const AName, ACanonical: string; ARules: TPcTzRules);
begin
  inherited Create;
  FName := AName;
  FCanonical := ACanonical;
  if FCanonical = '' then
    FCanonical := AName;
  FRules := ARules;
  FRulesRef := ARules;
end;

function TPcTimeZone.Name: string;
begin
  Result := FName;
end;

function TPcTimeZone.CanonicalName: string;
begin
  Result := FCanonical;
end;

function TPcTimeZone.Info(AUtc: Int64): TPcOffsetInfo;
var
  LType: TPcTzType;
begin
  CheckRange(AUtc, 'Instant');
  LType := FRules.TypeAt(AUtc);
  Result.Offset := LType.Offset;
  Result.IsDst := LType.IsDst;
  Result.Abbreviation := LType.Abbr;
end;

function TPcTimeZone.OffsetAt(AUtc: Int64): Integer;
begin
  CheckRange(AUtc, 'Instant');
  Result := FRules.OffsetAt(AUtc);
end;

function TPcTimeZone.ToLocal(AUtc: Int64): TPcLocalDateTime;
var
  LLocal: Int64;
begin
  CheckRange(AUtc, 'Instant');
  LLocal := AUtc + FRules.OffsetAt(AUtc);
  CheckRange(LLocal, 'Local time of instant');
  Result := LocalFromSeconds(LLocal);
end;

function TPcTimeZone.Map(const ALocal: TPcLocalDateTime): TPcZoneMapping;
begin
  if not ALocal.IsValid then
    raise EPcTimeZoneError.CreateFmt('Invalid local date/time %s', [ALocal.ToString]);
  FRules.MapLocal(LocalSeconds(ALocal), Result);
end;

function TPcTimeZone.Resolve(ALocal: Int64; AGap: TPcGapRule; AOverlap: TPcOverlapRule): Int64;
var
  LMap: TPcZoneMapping;
begin
  FRules.MapLocal(ALocal, LMap);
  case LMap.Count of
    1:
      Result := LMap.Earlier;
    0:
      case AGap of
        gapShiftForward:
          Result := ALocal - LMap.OffsetBefore;
        gapStartOfAfter:
          Result := LMap.Transition;
      else
        raise EPcSkippedLocalTime.CreateFmt('%s does not exist in %s (a daylight-saving gap)',
          [LocalFromSeconds(ALocal).ToString, FName]);
      end;
  else
    case AOverlap of
      overlapEarlier:
        Result := LMap.Earlier;
      overlapLater:
        Result := LMap.Later;
    else
      raise EPcAmbiguousLocalTime.CreateFmt('%s happens twice in %s (a daylight-saving overlap)',
        [LocalFromSeconds(ALocal).ToString, FName]);
    end;
  end;
end;

function TPcTimeZone.ToUtc(const ALocal: TPcLocalDateTime; AGap: TPcGapRule;
  AOverlap: TPcOverlapRule): Int64;
begin
  if not ALocal.IsValid then
    raise EPcTimeZoneError.CreateFmt('Invalid local date/time %s', [ALocal.ToString]);
  Result := Resolve(LocalSeconds(ALocal), AGap, AOverlap);
end;

procedure TPcTimeZone.DayBounds(AYear, AMonth, ADay: Integer; out AStart, AEnd: Int64);
var
  LDay: Int64;
begin
  if not TPcLocalDateTime.Create(AYear, AMonth, ADay).IsValid then
    raise EPcTimeZoneError.CreateFmt('Invalid local date %.4d-%.2d-%.2d', [AYear, AMonth, ADay]);
  LDay := DaysFromCivil(AYear, AMonth, ADay) * SECONDS_PER_DAY;
  AStart := Resolve(LDay, gapStartOfAfter, overlapEarlier);
  AEnd := Resolve(LDay + SECONDS_PER_DAY, gapStartOfAfter, overlapEarlier);
end;

function TPcTimeZone.NextTransition(AUtc: Int64; out ATransition: Int64): Boolean;
begin
  CheckRange(AUtc, 'Instant');
  Result := FRules.NextChange(AUtc, ATransition) and (ATransition <= MAX_SECONDS);
end;

function TPcTimeZone.ToLocalDateTime(AUtc: Int64): TDateTime;
var
  LLocal: TPcLocalDateTime;
begin
  LLocal := ToLocal(AUtc);
  Result := EncodeDateTime(LLocal.Year, LLocal.Month, LLocal.Day, LLocal.Hour, LLocal.Minute,
    LLocal.Second, 0);
end;

function TPcTimeZone.LocalDateTimeToUtc(ALocal: TDateTime; AGap: TPcGapRule;
  AOverlap: TPcOverlapRule): Int64;
var
  LYear, LMonth, LDay, LHour, LMinute, LSecond, LMs: Word;
  LSeconds: Int64;
begin
  DecodeDateTime(ALocal, LYear, LMonth, LDay, LHour, LMinute, LSecond, LMs);
  LSeconds := LocalSeconds(TPcLocalDateTime.Create(LYear, LMonth, LDay, LHour, LMinute, LSecond));
  if LMs >= 500 then
    Inc(LSeconds);
  CheckRange(LSeconds, 'Local time');
  Result := Resolve(LSeconds, AGap, AOverlap);
end;

{ Free functions }

function PcTimeZoneFromTzif(const AName: string; const AData: TBytes;
  const ACanonicalName: string): IPcTimeZone;
var
  LRules: TPcTzRules;
  LRef: IPcTzRulesRef;
begin
  LRules := TPcTzRules.Create;
  LRef := LRules;
  LRules.Parse(AData);
  Result := TPcTimeZone.Create(AName, ACanonicalName, LRules);
end;

var
  GUtcZone: IPcTimeZone;
  GTimeZones: TPcTimeZoneCatalog;

function PcTimeZones: TPcTimeZoneCatalog;
begin
  Result := GTimeZones;
end;

function PcUtcZone: IPcTimeZone;
begin
  Result := GUtcZone;
end;

function CreateUtcZone: IPcTimeZone;
var
  LRules: TPcTzRules;
begin
  LRules := TPcTzRules.Create;
  LRules.MakeFixed(0, 'UTC');
  Result := TPcTimeZone.Create('Etc/UTC', 'Etc/UTC', LRules);
end;

function PcIsWellFormedTimeZoneName(const AName: string): Boolean;
var
  I: Integer;
  C, LPrev: Char;
begin
  Result := False;
  if (AName = '') or (Length(AName) > MAX_NAME_LENGTH) then
    Exit;
  LPrev := '/';
  for I := 1 to Length(AName) do
  begin
    C := AName[I];
    if C = '/' then
    begin
      if LPrev = '/' then
        Exit;   // empty segment, or a leading '/'
    end
    else if not (((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
      ((C >= '0') and (C <= '9')) or (C = '_') or (C = '+') or (C = '-')) then
      Exit;
    LPrev := C;
  end;
  Result := LPrev <> '/';
end;

procedure SortStrings(var A: TArray<string>);
var
  I, J: Integer;
  V: string;
begin
  for I := 1 to High(A) do
  begin
    V := A[I];
    J := I - 1;
    while (J >= 0) and (CompareStr(A[J], V) > 0) do
    begin
      A[J + 1] := A[J];
      Dec(J);
    end;
    A[J + 1] := V;
  end;
end;

{ TPcMemoryTzSource }

constructor TPcMemoryTzSource.Create(const AVersion: string);
begin
  inherited Create;
  FData := TDictionary<string, TBytes>.Create;
  FLinks := TDictionary<string, string>.Create;
  FVersion := AVersion;
end;

destructor TPcMemoryTzSource.Destroy;
begin
  FLinks.Free;
  FData.Free;
  inherited;
end;

procedure TPcMemoryTzSource.Add(const AName: string; const AData: TBytes);
begin
  FData.AddOrSetValue(AName, AData);
end;

procedure TPcMemoryTzSource.AddLink(const ALink, ATarget: string);
begin
  FLinks.AddOrSetValue(ALink, ATarget);
end;

function TPcMemoryTzSource.TryRead(const AName: string; out AData: TBytes): Boolean;
begin
  Result := FData.TryGetValue(CanonicalName(AName), AData);
end;

function TPcMemoryTzSource.Names: TArray<string>;
var
  LName: string;
  I: Integer;
begin
  SetLength(Result, FData.Count + FLinks.Count);
  I := 0;
  for LName in FData.Keys do
  begin
    Result[I] := LName;
    Inc(I);
  end;
  for LName in FLinks.Keys do
  begin
    Result[I] := LName;
    Inc(I);
  end;
end;

function TPcMemoryTzSource.CanonicalName(const AName: string): string;
begin
  if not FLinks.TryGetValue(AName, Result) then
    Result := AName;
end;

function TPcMemoryTzSource.Version: string;
begin
  Result := FVersion;
end;

{ TPcEmbeddedTzSource }

constructor TPcEmbeddedTzSource.Create;
var
  I: Integer;
begin
  inherited Create;
  FZones := TDictionary<string, Integer>.Create;
  FLinks := TDictionary<string, Integer>.Create;
  for I := 0 to PC_TZDB_ZONE_COUNT - 1 do
    FZones.Add(PcTzdbZoneNames[I], I);
  for I := 0 to PC_TZDB_LINK_COUNT - 1 do
    FLinks.Add(PcTzdbLinkNames[I], PcTzdbLinkTargets[I]);
end;

destructor TPcEmbeddedTzSource.Destroy;
begin
  FLinks.Free;
  FZones.Free;
  inherited;
end;

function TPcEmbeddedTzSource.TryRead(const AName: string; out AData: TBytes): Boolean;
var
  LIndex: Integer;
begin
  Result := FZones.TryGetValue(AName, LIndex) or FLinks.TryGetValue(AName, LIndex);
  if not Result then
  begin
    AData := nil;
    Exit;
  end;
  SetLength(AData, PcTzdbZoneLengths[LIndex]);
  Move(PcTzdbBytes[PcTzdbZoneStarts[LIndex]], AData[0], PcTzdbZoneLengths[LIndex]);
end;

function TPcEmbeddedTzSource.Names: TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, PC_TZDB_ZONE_COUNT + PC_TZDB_LINK_COUNT);
  for I := 0 to PC_TZDB_ZONE_COUNT - 1 do
    Result[I] := PcTzdbZoneNames[I];
  for I := 0 to PC_TZDB_LINK_COUNT - 1 do
    Result[PC_TZDB_ZONE_COUNT + I] := PcTzdbLinkNames[I];
end;

function TPcEmbeddedTzSource.CanonicalName(const AName: string): string;
var
  LIndex: Integer;
begin
  if FLinks.TryGetValue(AName, LIndex) then
    Result := PcTzdbZoneNames[LIndex]
  else
    Result := AName;
end;

function TPcEmbeddedTzSource.Version: string;
begin
  Result := PC_TZDB_VERSION;
end;

{ TPcDirectoryTzSource }

const
  MAX_TZIF_SIZE = 1024 * 1024;

procedure AddName(var ANames: TArray<string>; const AName: string);
begin
  SetLength(ANames, Length(ANames) + 1);
  ANames[High(ANames)] := AName;
end;

function ReadFileBytes(const APath: string; AMax: Integer; out AData: TBytes): Boolean;
var
  LStream: TFileStream;
begin
  AData := nil;
  Result := False;
  try
    LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  except
    on EStreamError do
      Exit;
  end;
  try
    if LStream.Size > AMax then
      Exit;
    SetLength(AData, LStream.Size);
    if Length(AData) > 0 then
      LStream.ReadBuffer(AData[0], Length(AData));
    Result := True;
  finally
    LStream.Free;
  end;
end;

constructor TPcDirectoryTzSource.Create(const ARoot: string);
var
  LCandidates: TArray<string>;
  LName: string;
begin
  inherited Create;
  FRoot := IncludeTrailingPathDelimiter(ARoot);
  FLinks := TDictionary<string, string>.Create;
  LCandidates := nil;
  if FileExists(FRoot + 'tzdata.zi') then
    ReadZi(FRoot + 'tzdata.zi', LCandidates)
  else
    Walk(FRoot, '', 0, LCandidates);
  FNames := nil;
  for LName in LCandidates do
    if IsZoneFile(LName) then
      AddName(FNames, LName)
    else
      FLinks.Remove(LName);
  SortStrings(FNames);
end;

destructor TPcDirectoryTzSource.Destroy;
begin
  FLinks.Free;
  inherited;
end;

function TPcDirectoryTzSource.FileOf(const AName: string): string;
begin
  Result := FRoot + StringReplace(AName, '/', PathDelim, [rfReplaceAll]);
end;

function TPcDirectoryTzSource.IsZoneFile(const AName: string): Boolean;
var
  LStream: TFileStream;
  LMagic: array[0..3] of Byte;
begin
  Result := False;
  if (not PcIsWellFormedTimeZoneName(AName)) or (AName = 'posixrules') or
    (AName = 'localtime') or (AName = 'Factory') or (Copy(AName, 1, 6) = 'posix/') or
    (Copy(AName, 1, 6) = 'right/') or not FileExists(FileOf(AName)) then
    Exit;
  try
    LStream := TFileStream.Create(FileOf(AName), fmOpenRead or fmShareDenyWrite);
  except
    on EStreamError do
      Exit;
  end;
  try
    Result := (LStream.Read(LMagic, 4) = 4) and (LMagic[0] = Ord('T')) and
      (LMagic[1] = Ord('Z')) and (LMagic[2] = Ord('i')) and (LMagic[3] = Ord('f'));
  finally
    LStream.Free;
  end;
end;

// tzdata.zi: "# version 2026c", "Z <zone> ...", "L <target> <link>".
procedure TPcDirectoryTzSource.ReadZi(const APath: string; var ANames: TArray<string>);
var
  LLines, LFields: TStringList;
  I: Integer;
  LLine: string;
begin
  LLines := TStringList.Create;
  LFields := TStringList.Create;
  try
    LLines.LoadFromFile(APath);
    LFields.Delimiter := ' ';
    LFields.StrictDelimiter := True;
    for I := 0 to LLines.Count - 1 do
    begin
      LLine := Trim(LLines[I]);
      if Copy(LLine, 1, 10) = '# version ' then
        FVersion := Trim(Copy(LLine, 11, MaxInt))
      else if (Copy(LLine, 1, 2) = 'Z ') or (Copy(LLine, 1, 2) = 'L ') then
      begin
        LFields.DelimitedText := LLine;
        if (LLine[1] = 'Z') and (LFields.Count >= 2) then
          AddName(ANames, LFields[1])
        else if (LLine[1] = 'L') and (LFields.Count >= 3) then
        begin
          FLinks.AddOrSetValue(LFields[2], LFields[1]);
          AddName(ANames, LFields[2]);
        end;
      end;
    end;
  finally
    LFields.Free;
    LLines.Free;
  end;
end;

procedure TPcDirectoryTzSource.Walk(const ADir, APrefix: string; ADepth: Integer;
  var ANames: TArray<string>);
var
  LSearch: TSearchRec;
begin
  if ADepth > 4 then
    Exit;
  if FindFirst(ADir + '*', faAnyFile, LSearch) <> 0 then
    Exit;
  try
    repeat
      if (LSearch.Name = '.') or (LSearch.Name = '..') then
        Continue;
      if (LSearch.Attr and faDirectory) <> 0 then
      begin
        if (ADepth > 0) or ((LSearch.Name <> 'posix') and (LSearch.Name <> 'right')) then
          Walk(ADir + LSearch.Name + PathDelim, APrefix + LSearch.Name + '/', ADepth + 1, ANames);
      end
      else
        AddName(ANames, APrefix + LSearch.Name);
    until FindNext(LSearch) <> 0;
  finally
    FindClose(LSearch);
  end;
end;

function TPcDirectoryTzSource.TryRead(const AName: string; out AData: TBytes): Boolean;
var
  LTarget: string;
begin
  AData := nil;
  Result := False;
  if not PcIsWellFormedTimeZoneName(AName) then
    Exit;
  // The link's own file first: the target may be missing from the tree.
  if ReadFileBytes(FileOf(AName), MAX_TZIF_SIZE, AData) then
    Exit(True);
  LTarget := CanonicalName(AName);
  Result := (LTarget <> AName) and PcIsWellFormedTimeZoneName(LTarget) and
    ReadFileBytes(FileOf(LTarget), MAX_TZIF_SIZE, AData);
end;

function TPcDirectoryTzSource.Names: TArray<string>;
begin
  Result := Copy(FNames, 0, Length(FNames));
end;

function TPcDirectoryTzSource.CanonicalName(const AName: string): string;
begin
  if not FLinks.TryGetValue(AName, Result) then
    Result := AName;
end;

function TPcDirectoryTzSource.Version: string;
begin
  Result := FVersion;
end;

{ TPcTimeZoneCatalog }

constructor TPcTimeZoneCatalog.Create(ASource: IPcTzSource);
var
  LName: string;
begin
  inherited Create;
  if ASource = nil then
    raise EPcTimeZoneError.Create('TPcTimeZoneCatalog needs a source');
  FSource := ASource;
  FLock := TCriticalSection.Create;
  FZones := TDictionary<string, IPcTimeZone>.Create;
  FRules := TDictionary<string, IInterface>.Create;
  FNameSet := TDictionary<string, Boolean>.Create;
  FNames := nil;
  for LName in FSource.Names do
    if PcIsWellFormedTimeZoneName(LName) and not FNameSet.ContainsKey(LName) then
    begin
      FNameSet.Add(LName, True);
      SetLength(FNames, Length(FNames) + 1);
      FNames[High(FNames)] := LName;
    end;
  SortStrings(FNames);
end;

destructor TPcTimeZoneCatalog.Destroy;
begin
  FNameSet.Free;
  FRules.Free;
  FZones.Free;
  FLock.Free;
  inherited;
end;

function TPcTimeZoneCatalog.IsValidName(const AName: string): Boolean;
begin
  // FNameSet never changes after the constructor: no lock needed.
  Result := PcIsWellFormedTimeZoneName(AName) and FNameSet.ContainsKey(AName);
end;

function TPcTimeZoneCatalog.TryFind(const AName: string; out AZone: IPcTimeZone): Boolean;
var
  LCanonical: string;
  LStored: IInterface;
  LRulesRef: IPcTzRulesRef;
  LRules: TPcTzRules;
  LData: TBytes;
begin
  AZone := nil;
  Result := False;
  if not IsValidName(AName) then
    Exit;
  FLock.Enter;
  try
    if FZones.TryGetValue(AName, AZone) then
      Exit(True);
    LCanonical := FSource.CanonicalName(AName);
    if FRules.TryGetValue(LCanonical, LStored) then
      LRules := (LStored as IPcTzRulesRef).Rules
    else
    begin
      if not FSource.TryRead(LCanonical, LData) then
        Exit;
      LRules := TPcTzRules.Create;
      LRulesRef := LRules;
      try
        LRules.Parse(LData);
      except
        on E: EPcTimeZoneError do
          raise EPcTimeZoneError.CreateFmt('%s: %s', [AName, E.Message]);
      end;
      FRules.Add(LCanonical, LRulesRef);
    end;
    AZone := TPcTimeZone.Create(AName, LCanonical, LRules);
    FZones.Add(AName, AZone);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TPcTimeZoneCatalog.Find(const AName: string): IPcTimeZone;
begin
  if not TryFind(AName, Result) then
    raise EPcUnknownTimeZone.CreateFmt('Unknown time zone "%s"', [AName]);
end;

function TPcTimeZoneCatalog.TryCanonicalCase(const AName: string; out ASpelled: string): Boolean;
var
  LName: string;
begin
  for LName in FNames do
    if SameText(LName, AName) then
    begin
      ASpelled := LName;
      Exit(True);
    end;
  ASpelled := '';
  Result := False;
end;

function TPcTimeZoneCatalog.Names: TArray<string>;
begin
  Result := Copy(FNames, 0, Length(FNames));
end;

function TPcTimeZoneCatalog.DataVersion: string;
begin
  Result := FSource.Version;
end;

initialization
  GUtcZone := CreateUtcZone;
  GTimeZones := TPcTimeZoneCatalog.Create(TPcEmbeddedTzSource.Create);

finalization
  FreeAndNil(GTimeZones);
  GUtcZone := nil;

end.
