unit PascalCommon.TimeZonesTests;

{ Tests for PascalCommon.TimeZones (1.22.0): IANA zones on both compilers.

  Every expected value below was checked against the tzdb itself, not
  memory: Python zoneinfo (tzdata 2026b) and zdump on Debian 12 (2026b) and
  13 (2026c) agreed on all of them (docs/timezones-design.md, "The expected
  values"); none of these zones changed in 2026c-2026e. The Golden_* tests go
  further: every zone of the embedded data against the answers of zdump and
  Python for the same compiled release, in tests/Unit/golden/
  tzdata-golden.txt (written by tools/gen_tzdata.py). A data file read at
  run time, found by walking up from the executable's folder, and not a
  Pascal unit: 15 000 generated lines more made Delphi Community Edition show
  its EULA reminder on every build of this project.

  The hand-made TZif files (BuildTzif) cover what the real data doesn't:
  version 1 files, an empty footer, broken files, and each footer form alone
  (a file with no transitions follows its footer at every instant).

  Exceptions are checked with try/except on the exact class rather than
  AssertException, whose descendant rule differs between DUnitX and FPCUnit.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalCommon.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalCommon.DUnitXCompat,
  Classes,
  SysUtils,
  SyncObjs,
  DateUtils,
  {$IFNDEF FPC}
  System.IOUtils,
  {$ENDIF}
  PascalCommon.Threading,
  PascalCommon.TimeZones,
  PascalCommon.TimeZones.Data;

type
  [TestFixture]
  TTimeZonesTests = class
  public
    [Test]
    procedure LocalDateTime_Calendar;
    [Test]
    procedure NewYork_SpringGap;
    [Test]
    procedure NewYork_AutumnOverlap;
    [Test]
    procedure NewYork_TransitionsAndDays;
    [Test]
    procedure Lisbon_TransitionsAndDays;
    [Test]
    procedure SaoPaulo_History;
    [Test]
    procedure SaoPaulo_DayWithoutMidnight;
    [Test]
    procedure Kathmandu_QuarterHourOffset;
    [Test]
    procedure LordHowe_HalfHourDst;
    [Test]
    procedure Utc_Zone;
    [Test]
    procedure FarPastAndFuture;
    [Test]
    procedure Range_AndInvalidInput;
    [Test]
    procedure DateTime_Conveniences;
    [Test]
    procedure Names_Unknown;
    [Test]
    procedure Names_WrongCase;
    [Test]
    procedure Names_BackwardLink;
    [Test]
    procedure Names_UtcAndGmt;
    [Test]
    procedure Names_Malformed;
    [Test]
    procedure Catalog_CachesAndVersion;
    [Test]
    procedure Footer_EachFormMatchesItsZone;
    [Test]
    procedure Footer_SpecialRules;
    [Test]
    procedure Footer_Invalid;
    [Test]
    procedure Tzif_Version1AndEmptyFooter;
    [Test]
    procedure Tzif_Broken;
    [Test]
    procedure MemorySource_Catalog;
    [Test]
    procedure DirectorySource_Tree;
    [Test]
    procedure DirectorySource_System;
    [Test]
    procedure Golden_Names;
    [Test]
    procedure Golden_Offsets;
    [Test]
    procedure Golden_Transitions;
    [Test]
    procedure Golden_Mappings;
    [Test]
    procedure Threads_ConvertThroughOneCatalog;
  end;

implementation

const
  JAN_2026 = 1767225600;   // 2026-01-01T00:00:00Z

function Local(AYear, AMonth, ADay, AHour, AMinute: Integer): TPcLocalDateTime;
begin
  Result := TPcLocalDateTime.Create(AYear, AMonth, ADay, AHour, AMinute);
end;

function Zone(const AName: string): IPcTimeZone;
begin
  Result := PcTimeZones.Find(AName);
end;

procedure CheckDay(const AZone: IPcTimeZone; AYear, AMonth, ADay: Integer;
  AStart, AEnd: Int64);
var
  LStart, LEnd: Int64;
begin
  AZone.DayBounds(AYear, AMonth, ADay, LStart, LEnd);
  TAssert.AssertEquals(Format('%s %d-%d-%d start', [AZone.Name, AYear, AMonth, ADay]), AStart, LStart);
  TAssert.AssertEquals(Format('%s %d-%d-%d end', [AZone.Name, AYear, AMonth, ADay]), AEnd, LEnd);
end;

procedure CheckNext(const AZone: IPcTimeZone; AFrom, AExpected: Int64;
  ABefore, AAfter: Integer);
var
  LAt: Int64;
begin
  TAssert.AssertTrue(AZone.Name + ' has a next transition', AZone.NextTransition(AFrom, LAt));
  TAssert.AssertEquals(AZone.Name + ' transition', AExpected, LAt);
  TAssert.AssertEquals(AZone.Name + ' offset before', ABefore, AZone.OffsetAt(LAt - 1));
  TAssert.AssertEquals(AZone.Name + ' offset after', AAfter, AZone.OffsetAt(LAt));
end;

procedure CheckGap(const AZone: IPcTimeZone; const ALocal: TPcLocalDateTime;
  AShifted, ATransition: Int64);
var
  LMap: TPcZoneMapping;
begin
  LMap := AZone.Map(ALocal);
  TAssert.AssertEquals(ALocal.ToString + ' is in a gap', 0, LMap.Count);
  TAssert.AssertEquals(ALocal.ToString + ' transition', ATransition, LMap.Transition);
  TAssert.AssertEquals(ALocal.ToString + ' shift forward', AShifted, AZone.ToUtc(ALocal));
  TAssert.AssertEquals(ALocal.ToString + ' start of after', ATransition,
    AZone.ToUtc(ALocal, gapStartOfAfter));
end;

procedure CheckOverlap(const AZone: IPcTimeZone; const ALocal: TPcLocalDateTime;
  AEarlier, ALater: Int64);
var
  LMap: TPcZoneMapping;
begin
  LMap := AZone.Map(ALocal);
  TAssert.AssertEquals(ALocal.ToString + ' is in an overlap', 2, LMap.Count);
  TAssert.AssertEquals(ALocal.ToString + ' earlier', AEarlier, LMap.Earlier);
  TAssert.AssertEquals(ALocal.ToString + ' later', ALater, LMap.Later);
  TAssert.AssertEquals(ALocal.ToString + ' default', AEarlier, AZone.ToUtc(ALocal));
  TAssert.AssertEquals(ALocal.ToString + ' later rule', ALater,
    AZone.ToUtc(ALocal, gapShiftForward, overlapLater));
end;

{ Hand-made TZif }

procedure PutByte(var A: TBytes; AValue: Integer);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := Byte(AValue);
end;

procedure PutU32(var A: TBytes; AValue: Int64);
begin
  PutByte(A, (AValue shr 24) and $FF);
  PutByte(A, (AValue shr 16) and $FF);
  PutByte(A, (AValue shr 8) and $FF);
  PutByte(A, AValue and $FF);
end;

procedure PutI64(var A: TBytes; AValue: Int64);
begin
  PutU32(A, (AValue shr 32) and $FFFFFFFF);
  PutU32(A, AValue and $FFFFFFFF);
end;

procedure PutText(var A: TBytes; const AText: string);
var
  I: Integer;
begin
  for I := 1 to Length(AText) do
    PutByte(A, Ord(AText[I]));
end;

procedure PutBlock(var A: TBytes; AVersion: Integer; ATimeSize: Integer;
  const ATimes: array of Int64; const ATypeOf: array of Byte; const AOffsets: array of Integer;
  const AIsDst: array of Boolean; const AAbbrs: array of string; ALeapCount: Integer);
var
  I, LChars: Integer;
  LAbbrIndex: array of Integer;
begin
  SetLength(LAbbrIndex, Length(AAbbrs));
  LChars := 0;
  for I := 0 to High(AAbbrs) do
  begin
    LAbbrIndex[I] := LChars;
    Inc(LChars, Length(AAbbrs[I]) + 1);
  end;
  PutText(A, 'TZif');
  PutByte(A, AVersion);
  for I := 1 to 15 do
    PutByte(A, 0);
  PutU32(A, 0);                    // isutcnt
  PutU32(A, 0);                    // isstdcnt
  PutU32(A, ALeapCount);
  PutU32(A, Length(ATimes));
  PutU32(A, Length(AOffsets));
  PutU32(A, LChars);
  for I := 0 to High(ATimes) do
    if ATimeSize = 4 then
      PutU32(A, ATimes[I] and $FFFFFFFF)
    else
      PutI64(A, ATimes[I]);
  for I := 0 to High(ATypeOf) do
    PutByte(A, ATypeOf[I]);
  for I := 0 to High(AOffsets) do
  begin
    PutU32(A, AOffsets[I] and $FFFFFFFF);
    PutByte(A, Ord(AIsDst[I]));
    PutByte(A, LAbbrIndex[I]);
  end;
  for I := 0 to High(AAbbrs) do
  begin
    PutText(A, AAbbrs[I]);
    PutByte(A, 0);
  end;
  for I := 1 to ALeapCount * (ATimeSize + 4) do
    PutByte(A, 0);
end;

/// AVersion 0 writes a version 1 file (no 64-bit block, no footer).
function BuildTzif(AVersion: Integer; const ATimes: array of Int64; const ATypeOf: array of Byte;
  const AOffsets: array of Integer; const AIsDst: array of Boolean; const AAbbrs: array of string;
  const AFooter: string; ALeapCount: Integer = 0): TBytes;
begin
  Result := nil;
  PutBlock(Result, AVersion, 4, ATimes, ATypeOf, AOffsets, AIsDst, AAbbrs, ALeapCount);
  if AVersion = 0 then
    Exit;
  PutBlock(Result, AVersion, 8, ATimes, ATypeOf, AOffsets, AIsDst, AAbbrs, ALeapCount);
  PutByte(Result, 10);
  PutText(Result, AFooter);
  PutByte(Result, 10);
end;

/// A file with no transitions: the footer applies at every instant.
function FooterZone(const AFooter: string): IPcTimeZone;
begin
  Result := PcTimeZoneFromTzif('Test/Footer',
    BuildTzif(Ord('2'), [], [], [0], [False], ['LMT'], AFooter));
end;

{ The golden file }

type
  TGolden = record
    Version: string;
    Names: TArray<string>;
    Offsets, Transitions, Mappings: TArray<Int64>;
    OffsetCount, TransitionCount, MappingCount: Integer;
  end;

const
  GOLDEN_FILE = 'tzdata-golden.txt';

function FindGoldenFile: string;
var
  LDir, LParent: string;
  I: Integer;
begin
  // Delphi: tests/Unit/Win32/Debug; FPC: tests/Unit/fpc; Docker: /t/runner.
  LDir := ExcludeTrailingPathDelimiter(ExtractFilePath(ExpandFileName(ParamStr(0))));
  for I := 1 to 8 do
  begin
    Result := LDir + PathDelim + 'golden' + PathDelim + GOLDEN_FILE;
    if FileExists(Result) then
      Exit;
    Result := LDir + PathDelim + 'tests' + PathDelim + 'Unit' + PathDelim + 'golden' + PathDelim +
      GOLDEN_FILE;
    if FileExists(Result) then
      Exit;
    LParent := ExtractFileDir(LDir);
    if (LParent = '') or (LParent = LDir) then
      Break;
    LDir := LParent;
  end;
  raise Exception.Create(GOLDEN_FILE + ' not found above ' + ExtractFilePath(ParamStr(0)));
end;

// The fields after the line's kind letter. Not TStringList.DelimitedText:
// it cost 0.6 s for the file's 47 000 lines.
function Fields(const ALine: string): TArray<string>;
var
  P, LStart, N: Integer;
begin
  SetLength(Result, 8);
  N := 0;
  P := 2;
  while P <= Length(ALine) do
  begin
    while (P <= Length(ALine)) and (ALine[P] = ' ') do
      Inc(P);
    LStart := P;
    while (P <= Length(ALine)) and (ALine[P] <> ' ') do
      Inc(P);
    if P > LStart then
    begin
      if N = Length(Result) then
        SetLength(Result, N * 2);
      Result[N] := Copy(ALine, LStart, P - LStart);
      Inc(N);
    end;
  end;
  SetLength(Result, N);
end;

procedure AddValues(var AArray: TArray<Int64>; var ACount: Integer; const ALine: string;
  AWidth: Integer);
var
  LFields: TArray<string>;
  I: Integer;
begin
  LFields := Fields(ALine);
  if Length(LFields) <> AWidth then
    raise Exception.Create('Bad golden line: ' + ALine);
  if (ACount + 1) * AWidth > Length(AArray) then
    SetLength(AArray, Length(AArray) * 2 + AWidth * 1024);
  for I := 0 to AWidth - 1 do
    AArray[ACount * AWidth + I] := StrToInt64(LFields[I]);
  Inc(ACount);
end;

function ReadGolden: TGolden;
var
  LLines: TStringList;
  I, LNames: Integer;
  LLine: string;
begin
  Result.Version := '';
  Result.Names := nil;
  Result.Offsets := nil;
  Result.Transitions := nil;
  Result.Mappings := nil;
  Result.OffsetCount := 0;
  Result.TransitionCount := 0;
  Result.MappingCount := 0;
  LNames := 0;
  LLines := TStringList.Create;
  try
    LLines.LoadFromFile(FindGoldenFile);
    SetLength(Result.Names, LLines.Count);
    for I := 0 to LLines.Count - 1 do
    begin
      LLine := LLines[I];
      if (LLine = '') or (LLine[1] = '#') then
        Continue;
      case LLine[1] of
        'V': Result.Version := Trim(Copy(LLine, 2, MaxInt));
        'N':
          begin
            Result.Names[LNames] := Trim(Copy(LLine, 2, MaxInt));
            Inc(LNames);
          end;
        'O': AddValues(Result.Offsets, Result.OffsetCount, LLine, 3);
        'T': AddValues(Result.Transitions, Result.TransitionCount, LLine, 4);
        'M': AddValues(Result.Mappings, Result.MappingCount, LLine, 5);
      else
        raise Exception.Create('Bad golden line: ' + LLine);
      end;
    end;
    SetLength(Result.Names, LNames);
  finally
    LLines.Free;
  end;
end;

var
  GGolden: TGolden;
  GGoldenRead: Boolean;

// Read once per run (0.6 s under heaptrc); the runner calls tests from one
// thread, so a plain flag is enough here.
function LoadGolden: TGolden;
begin
  if not GGoldenRead then
  begin
    GGolden := ReadGolden;
    GGoldenRead := True;
  end;
  Result := GGolden;
end;

{ TTimeZonesTests }

procedure TTimeZonesTests.LocalDateTime_Calendar;
begin
  TAssert.AssertEquals('2026-10-20 is a Tuesday', 2, Local(2026, 10, 20, 0, 0).IsoWeekday);
  TAssert.AssertEquals('0001-01-01 was a Monday', 1, Local(1, 1, 1, 0, 0).IsoWeekday);
  TAssert.AssertEquals('9999-12-31 is a Friday', 5, Local(9999, 12, 31, 0, 0).IsoWeekday);
  TAssert.AssertEquals('1970-01-01 was a Thursday', 4, Local(1970, 1, 1, 0, 0).IsoWeekday);
  TAssert.AssertTrue('2028-02-29', Local(2028, 2, 29, 0, 0).IsValid);
  TAssert.AssertTrue('2000-02-29', Local(2000, 2, 29, 0, 0).IsValid);
  TAssert.AssertFalse('2027-02-29', Local(2027, 2, 29, 0, 0).IsValid);
  TAssert.AssertFalse('1900-02-29', Local(1900, 2, 29, 0, 0).IsValid);
  TAssert.AssertFalse('hour 24', Local(2026, 1, 1, 24, 0).IsValid);
  TAssert.AssertFalse('year 0', Local(0, 1, 1, 0, 0).IsValid);
  TAssert.AssertFalse('year 10000', Local(10000, 1, 1, 0, 0).IsValid);
  TAssert.AssertEquals('2028-02-29T09:30:00', Local(2028, 2, 28, 9, 30).AddDays(1).ToString);
  TAssert.AssertEquals('2027-01-01T00:00:00', Local(2026, 12, 31, 0, 0).AddDays(1).ToString);
  TAssert.AssertEquals('2026-02-28T00:00:00', Local(2026, 3, 1, 0, 0).AddDays(-1).ToString);
  TAssert.AssertTrue(Local(2026, 3, 1, 2, 3).SameAs(TPcLocalDateTime.Create(2026, 3, 1, 2, 3, 0)));
  TAssert.AssertFalse(Local(2026, 3, 1, 2, 3).SameAs(TPcLocalDateTime.Create(2026, 3, 1, 2, 3, 1)));
end;

procedure TTimeZonesTests.NewYork_SpringGap;
var
  NY: IPcTimeZone;
  LMap: TPcZoneMapping;
begin
  NY := Zone('America/New_York');
  // 2026-03-08: 02:00 EST becomes 03:00 EDT at 07:00Z.
  CheckGap(NY, Local(2026, 3, 8, 2, 30), 1772955000, 1772953200);
  CheckGap(NY, Local(2026, 3, 8, 2, 0), 1772953200, 1772953200);
  LMap := NY.Map(Local(2026, 3, 8, 2, 30));
  TAssert.AssertEquals('offset before', -18000, LMap.OffsetBefore);
  TAssert.AssertEquals('offset after', -14400, LMap.OffsetAfter);
  try
    NY.ToUtc(Local(2026, 3, 8, 2, 30), gapRaise);
    TAssert.Fail('gapRaise must raise');
  except
    on E: EPcSkippedLocalTime do
      TAssert.AssertTrue(E.Message, Pos('2026-03-08T02:30:00', E.Message) > 0);
  end;
  // Either side of the gap is an ordinary reading.
  TAssert.AssertEquals('01:59', 1772953140, NY.ToUtc(Local(2026, 3, 8, 1, 59)));
  TAssert.AssertEquals('03:00', 1772953200, NY.ToUtc(Local(2026, 3, 8, 3, 0)));
  TAssert.AssertEquals('normal count', 1, NY.Map(Local(2026, 3, 8, 3, 0)).Count);
end;

procedure TTimeZonesTests.NewYork_AutumnOverlap;
var
  NY: IPcTimeZone;
  LMap: TPcZoneMapping;
begin
  NY := Zone('America/New_York');
  // 2026-11-01: 02:00 EDT becomes 01:00 EST at 06:00Z.
  CheckOverlap(NY, Local(2026, 11, 1, 1, 30), 1793511000, 1793514600);
  CheckOverlap(NY, Local(2026, 11, 1, 1, 0), 1793509200, 1793512800);
  LMap := NY.Map(Local(2026, 11, 1, 1, 30));
  TAssert.AssertEquals('transition', 1793512800, LMap.Transition);
  TAssert.AssertEquals('offset before', -14400, LMap.OffsetBefore);
  TAssert.AssertEquals('offset after', -18000, LMap.OffsetAfter);
  TAssert.AssertEquals('02:00 is once', 1, NY.Map(Local(2026, 11, 1, 2, 0)).Count);
  TAssert.AssertEquals('02:00', 1793516400, NY.ToUtc(Local(2026, 11, 1, 2, 0)));
  try
    NY.ToUtc(Local(2026, 11, 1, 1, 30), gapShiftForward, overlapRaise);
    TAssert.Fail('overlapRaise must raise');
  except
    on E: EPcAmbiguousLocalTime do
      TAssert.AssertTrue(E.Message, Pos('America/New_York', E.Message) > 0);
  end;
end;

procedure TTimeZonesTests.NewYork_TransitionsAndDays;
var
  NY: IPcTimeZone;
begin
  NY := Zone('America/New_York');
  CheckNext(NY, JAN_2026, 1772953200, -18000, -14400);
  CheckNext(NY, 1772953200, 1793512800, -14400, -18000);
  TAssert.AssertEquals('2026-03-08T03:00:00', NY.ToLocal(1772953200).ToString);
  TAssert.AssertEquals('EDT', NY.Info(1772953200).Abbreviation);
  TAssert.AssertTrue('EDT is DST', NY.Info(1772953200).IsDst);
  TAssert.AssertEquals('2026-11-01T01:00:00', NY.ToLocal(1793512800).ToString);
  TAssert.AssertEquals('EST', NY.Info(1793512800).Abbreviation);
  CheckDay(NY, 2026, 3, 8, 1772946000, 1773028800);     // 23 h
  CheckDay(NY, 2026, 11, 1, 1793505600, 1793595600);    // 25 h
  CheckDay(NY, 2026, 3, 9, 1773028800, 1773115200);     // 24 h
end;

procedure TTimeZonesTests.Lisbon_TransitionsAndDays;
var
  LIS: IPcTimeZone;
begin
  LIS := Zone('Europe/Lisbon');
  CheckNext(LIS, JAN_2026, 1774746000, 0, 3600);
  CheckNext(LIS, 1774746000, 1792890000, 3600, 0);
  TAssert.AssertEquals('2026-03-29T02:00:00', LIS.ToLocal(1774746000).ToString);
  TAssert.AssertEquals('WEST', LIS.Info(1774746000).Abbreviation);
  TAssert.AssertEquals('2026-10-25T01:00:00', LIS.ToLocal(1792890000).ToString);
  CheckGap(LIS, Local(2026, 3, 29, 1, 30), 1774747800, 1774746000);
  CheckOverlap(LIS, Local(2026, 10, 25, 1, 30), 1792888200, 1792891800);
  CheckDay(LIS, 2026, 3, 29, 1774742400, 1774825200);   // 23 h
  CheckDay(LIS, 2026, 10, 25, 1792882800, 1792972800);  // 25 h
end;

procedure TTimeZonesTests.SaoPaulo_History;
var
  SP: IPcTimeZone;
  LAt: Int64;
  LLocal: TPcLocalDateTime;
begin
  SP := Zone('America/Sao_Paulo');
  CheckNext(SP, 1483228800, 1487469600, -7200, -10800);   // 2017-02-19
  CheckNext(SP, 1487469600, 1508036400, -10800, -7200);   // 2017-10-15
  CheckNext(SP, 1508036400, 1518919200, -7200, -10800);   // 2018-02-18
  CheckNext(SP, 1518919200, 1541300400, -10800, -7200);   // 2018-11-04
  CheckNext(SP, 1541300400, 1550368800, -7200, -10800);   // 2019-02-17, the last
  TAssert.AssertFalse('no DST since 2019', SP.NextTransition(1550368800, LAt));
  LLocal := SP.ToLocal(1547553600);                        // 2019-01-15T12:00Z
  TAssert.AssertEquals('2019-01-15T10:00:00', LLocal.ToString);
  TAssert.AssertEquals('-02', SP.Info(1547553600).Abbreviation);
  LLocal := SP.ToLocal(1768478400);                        // 2026-01-15T12:00Z
  TAssert.AssertEquals('2026-01-15T09:00:00', LLocal.ToString);
  TAssert.AssertEquals('a Thursday', 4, LLocal.IsoWeekday);
  TAssert.AssertEquals('-03', SP.Info(1768478400).Abbreviation);
  CheckOverlap(SP, Local(2019, 2, 16, 23, 30), 1550367000, 1550370600);
end;

procedure TTimeZonesTests.SaoPaulo_DayWithoutMidnight;
var
  SP: IPcTimeZone;
begin
  SP := Zone('America/Sao_Paulo');
  // 2018-11-04 00:00 didn't exist: the clock went from 23:59:59 to 01:00.
  CheckGap(SP, Local(2018, 11, 4, 0, 30), 1541302200, 1541300400);
  CheckDay(SP, 2018, 11, 4, 1541300400, 1541383200);   // starts at 01:00, 23 h
  CheckDay(SP, 2019, 2, 16, 1550282400, 1550372400);   // 25 h
  TAssert.AssertEquals('2018-11-04T01:00:00', SP.ToLocal(1541300400).ToString);
end;

procedure TTimeZonesTests.Kathmandu_QuarterHourOffset;
var
  KTM: IPcTimeZone;
  LAt: Int64;
begin
  KTM := Zone('Asia/Kathmandu');
  TAssert.AssertEquals('2026-06-01T05:45:00', KTM.ToLocal(1780272000).ToString);
  TAssert.AssertEquals('+05:45', 20700, KTM.OffsetAt(1780272000));
  TAssert.AssertEquals('+0545', KTM.Info(1780272000).Abbreviation);
  CheckNext(KTM, 473385600, 504901800, 19800, 20700);     // 1986: +05:30 -> +05:45
  TAssert.AssertEquals('1986-01-01T00:15:00', KTM.ToLocal(504901800).ToString);
  TAssert.AssertFalse('no change since', KTM.NextTransition(504901800, LAt));
  TAssert.AssertEquals('09:00', 1780283700, KTM.ToUtc(Local(2026, 6, 1, 9, 0)));
end;

procedure TTimeZonesTests.LordHowe_HalfHourDst;
var
  LH: IPcTimeZone;
begin
  LH := Zone('Australia/Lord_Howe');
  CheckNext(LH, JAN_2026, 1775314800, 39600, 37800);      // 2026-04-05 02:00 -> 01:30
  CheckNext(LH, 1775314800, 1791041400, 37800, 39600);    // 2026-10-04 02:00 -> 02:30
  TAssert.AssertEquals('2026-04-05T01:30:00', LH.ToLocal(1775314800).ToString);
  TAssert.AssertEquals('2026-10-04T02:30:00', LH.ToLocal(1791041400).ToString);
  CheckGap(LH, Local(2026, 10, 4, 2, 15), 1791042300, 1791041400);
  CheckOverlap(LH, Local(2026, 4, 5, 1, 45), 1775313900, 1775315700);
  CheckDay(LH, 2026, 10, 4, 1791034200, 1791118800);      // 23.5 h
  CheckDay(LH, 2026, 4, 5, 1775307600, 1775395800);       // 24.5 h
end;

procedure TTimeZonesTests.Utc_Zone;
var
  LAt: Int64;
begin
  TAssert.AssertEquals('Etc/UTC', PcUtcZone.Name);
  TAssert.AssertEquals('Etc/UTC', PcUtcZone.CanonicalName);
  TAssert.AssertEquals(0, PcUtcZone.OffsetAt(1772953200));
  TAssert.AssertEquals('UTC', PcUtcZone.Info(1772953200).Abbreviation);
  TAssert.AssertEquals('2026-03-08T07:00:00', PcUtcZone.ToLocal(1772953200).ToString);
  TAssert.AssertEquals('a Sunday', 7, PcUtcZone.ToLocal(1772953200).IsoWeekday);
  TAssert.AssertEquals(1772953200, PcUtcZone.ToUtc(Local(2026, 3, 8, 7, 0)));
  TAssert.AssertFalse(PcUtcZone.NextTransition(0, LAt));
  CheckDay(PcUtcZone, 2026, 3, 8, 1772928000, 1773014400);
  TAssert.AssertEquals('UTC from the data', 0, Zone('UTC').OffsetAt(1772953200));
  TAssert.AssertEquals('Etc/UTC from the data', 0, Zone('Etc/UTC').OffsetAt(-5364619200));
end;

procedure TTimeZonesTests.FarPastAndFuture;
var
  NY, SP: IPcTimeZone;
begin
  NY := Zone('America/New_York');
  SP := Zone('America/Sao_Paulo');
  // After the last explicit transition: the footer.
  TAssert.AssertEquals('2100-07-01T08:00:00', NY.ToLocal(4118126400).ToString);
  TAssert.AssertEquals('EDT', NY.Info(4118126400).Abbreviation);
  TAssert.AssertEquals('2500-01-01T07:00:00', NY.ToLocal(16725268800).ToString);
  TAssert.AssertEquals('EST', NY.Info(16725268800).Abbreviation);
  // Before the first transition: the first type, local mean time.
  TAssert.AssertEquals('1800-01-01T07:03:58', NY.ToLocal(-5364619200).ToString);
  TAssert.AssertEquals(-17762, NY.OffsetAt(-5364619200));
  TAssert.AssertEquals('LMT', NY.Info(-5364619200).Abbreviation);
  TAssert.AssertEquals('1900-01-01T08:53:32', SP.ToLocal(-2208945600).ToString);
  TAssert.AssertEquals(-11188, SP.OffsetAt(-2208945600));
  // The edges of the range.
  TAssert.AssertEquals('0001-01-01T00:00:00', PcUtcZone.ToLocal(-62135596800).ToString);
  TAssert.AssertEquals('9999-12-31T23:59:59', PcUtcZone.ToLocal(253402300799).ToString);
  TAssert.AssertEquals('9999-12-31T18:59:59', NY.ToLocal(253402300799).ToString);
end;

procedure TTimeZonesTests.Range_AndInvalidInput;
var
  NY: IPcTimeZone;
  LStart, LEnd: Int64;
begin
  NY := Zone('America/New_York');
  try
    PcUtcZone.ToLocal(253402300800);
    TAssert.Fail('year 10000 must raise');
  except
    on E: EPcTimeZoneError do
      TAssert.AssertTrue(E.Message, Pos('9999', E.Message) > 0);
  end;
  try
    PcUtcZone.OffsetAt(-62135596801);
    TAssert.Fail('year 0 must raise');
  except
    on E: EPcTimeZoneError do ;
  end;
  try
    // The instant is in range, its local time (year 0, LMT) isn't.
    Zone('America/New_York').ToLocal(-62135596800);
    TAssert.Fail('local year 0 must raise');
  except
    on E: EPcTimeZoneError do ;
  end;
  try
    NY.ToUtc(Local(2026, 2, 30, 9, 0));
    TAssert.Fail('2026-02-30 must raise');
  except
    on E: EPcTimeZoneError do
      TAssert.AssertTrue(E.Message, Pos('2026-02-30', E.Message) > 0);
  end;
  try
    NY.Map(Local(2026, 1, 1, 9, 60));
    TAssert.Fail('minute 60 must raise');
  except
    on E: EPcTimeZoneError do ;
  end;
  try
    NY.DayBounds(2026, 13, 1, LStart, LEnd);
    TAssert.Fail('month 13 must raise');
  except
    on E: EPcTimeZoneError do ;
  end;
end;

procedure TTimeZonesTests.DateTime_Conveniences;
var
  NY: IPcTimeZone;
begin
  NY := Zone('America/New_York');
  TAssert.AssertTrue('03:00 EDT', SameDateTime(EncodeDateTime(2026, 3, 8, 3, 0, 0, 0),
    NY.ToLocalDateTime(1772953200)));
  TAssert.AssertEquals('gap', 1772955000, NY.LocalDateTimeToUtc(EncodeDateTime(2026, 3, 8, 2, 30, 0, 0)));
  TAssert.AssertEquals('overlap, later', 1793514600,
    NY.LocalDateTimeToUtc(EncodeDateTime(2026, 11, 1, 1, 30, 0, 0), gapShiftForward, overlapLater));
  TAssert.AssertEquals('499 ms rounds down', 1773061200,
    NY.LocalDateTimeToUtc(EncodeDateTime(2026, 3, 9, 9, 0, 0, 499)));
  TAssert.AssertEquals('500 ms rounds up', 1773061201,
    NY.LocalDateTimeToUtc(EncodeDateTime(2026, 3, 9, 9, 0, 0, 500)));
end;

procedure TTimeZonesTests.Names_Unknown;
var
  LZone: IPcTimeZone;
begin
  TAssert.AssertFalse(PcTimeZones.IsValidName('Mars/Olympus'));
  TAssert.AssertFalse(PcTimeZones.TryFind('Mars/Olympus', LZone));
  TAssert.AssertTrue('nil when not found', LZone = nil);
  try
    PcTimeZones.Find('Mars/Olympus');
    TAssert.Fail('Find must raise');
  except
    on E: EPcUnknownTimeZone do
      TAssert.AssertEquals('Unknown time zone "Mars/Olympus"', E.Message);
  end;
end;

procedure TTimeZonesTests.Names_WrongCase;
var
  LZone: IPcTimeZone;
  LSpelled: string;
begin
  TAssert.AssertFalse('case-sensitive', PcTimeZones.IsValidName('america/new_york'));
  TAssert.AssertFalse(PcTimeZones.TryFind('AMERICA/SAO_PAULO', LZone));
  TAssert.AssertTrue(PcTimeZones.TryCanonicalCase('america/new_york', LSpelled));
  TAssert.AssertEquals('America/New_York', LSpelled);
  TAssert.AssertTrue(PcTimeZones.TryCanonicalCase('AMERICA/SAO_PAULO', LSpelled));
  TAssert.AssertEquals('America/Sao_Paulo', LSpelled);
  TAssert.AssertTrue('a link too', PcTimeZones.TryCanonicalCase('us/eastern', LSpelled));
  TAssert.AssertEquals('US/Eastern', LSpelled);
  TAssert.AssertFalse(PcTimeZones.TryCanonicalCase('mars/olympus', LSpelled));
  TAssert.AssertEquals('', LSpelled);
end;

procedure TTimeZonesTests.Names_BackwardLink;
var
  LLink: IPcTimeZone;
begin
  TAssert.AssertTrue(PcTimeZones.IsValidName('US/Eastern'));
  LLink := Zone('US/Eastern');
  TAssert.AssertEquals('US/Eastern', LLink.Name);
  TAssert.AssertEquals('America/New_York', LLink.CanonicalName);
  TAssert.AssertEquals(-14400, LLink.OffsetAt(1780272000));
  TAssert.AssertEquals('America/New_York', Zone('America/New_York').CanonicalName);
  TAssert.AssertEquals('Asia/Kolkata', Zone('Asia/Calcutta').CanonicalName);
  TAssert.AssertEquals('America/Nuuk', Zone('America/Godthab').CanonicalName);
end;

procedure TTimeZonesTests.Names_UtcAndGmt;
begin
  TAssert.AssertTrue(PcTimeZones.IsValidName('UTC'));
  TAssert.AssertTrue(PcTimeZones.IsValidName('Etc/UTC'));
  TAssert.AssertTrue(PcTimeZones.IsValidName('GMT'));
  TAssert.AssertTrue(PcTimeZones.IsValidName('Etc/GMT+5'));
  TAssert.AssertEquals('Etc/GMT+5 is UTC-5', -18000, Zone('Etc/GMT+5').OffsetAt(JAN_2026));
  TAssert.AssertEquals(0, Zone('GMT').OffsetAt(JAN_2026));
end;

procedure TTimeZonesTests.Names_Malformed;
begin
  TAssert.AssertTrue(PcIsWellFormedTimeZoneName('America/Argentina/Buenos_Aires'));
  TAssert.AssertTrue(PcIsWellFormedTimeZoneName('Etc/GMT-14'));
  TAssert.AssertTrue(PcIsWellFormedTimeZoneName('UTC'));
  TAssert.AssertFalse('empty', PcIsWellFormedTimeZoneName(''));
  TAssert.AssertFalse('..', PcIsWellFormedTimeZoneName('../etc/passwd'));
  TAssert.AssertFalse('dot', PcIsWellFormedTimeZoneName('zone.tab'));
  TAssert.AssertFalse('leading /', PcIsWellFormedTimeZoneName('/America/New_York'));
  TAssert.AssertFalse('trailing /', PcIsWellFormedTimeZoneName('America/New_York/'));
  TAssert.AssertFalse('empty segment', PcIsWellFormedTimeZoneName('America//New_York'));
  TAssert.AssertFalse('backslash', PcIsWellFormedTimeZoneName('America\New_York'));
  TAssert.AssertFalse('space', PcIsWellFormedTimeZoneName('America/New York'));
  TAssert.AssertFalse('non-ASCII', PcIsWellFormedTimeZoneName('América/São_Paulo'));
  TAssert.AssertFalse('too long', PcIsWellFormedTimeZoneName(StringOfChar('A', 129)));
  // Well formed, but files of a zoneinfo tree that aren't zones.
  TAssert.AssertFalse(PcTimeZones.IsValidName('posixrules'));
  TAssert.AssertFalse(PcTimeZones.IsValidName('localtime'));
  TAssert.AssertFalse(PcTimeZones.IsValidName('Factory'));
  TAssert.AssertFalse(PcTimeZones.IsValidName('../etc/passwd'));
end;

procedure TTimeZonesTests.Catalog_CachesAndVersion;
var
  LNames: TArray<string>;
  I: Integer;
begin
  TAssert.AssertTrue('the same zone object', Zone('Europe/Lisbon') = Zone('Europe/Lisbon'));
  TAssert.AssertEquals(PC_TZDB_VERSION, PcTimeZones.DataVersion);
  TAssert.AssertEquals('golden written from the same release', LoadGolden.Version,
    PcTimeZones.DataVersion);
  LNames := PcTimeZones.Names;
  TAssert.AssertEquals(PC_TZDB_ZONE_COUNT + PC_TZDB_LINK_COUNT, Length(LNames));
  for I := 1 to High(LNames) do
    TAssert.AssertTrue('sorted at ' + LNames[I], CompareStr(LNames[I - 1], LNames[I]) < 0);
end;

procedure TTimeZonesTests.Footer_EachFormMatchesItsZone;
const
  ZONES: array[0..6] of string = ('America/Nuuk', 'Asia/Jerusalem', 'America/Santiago',
    'Pacific/Chatham', 'Australia/Sydney', 'Europe/Dublin', 'America/New_York');
  FOOTERS: array[0..6] of string = ('<-02>2<-01>,M3.5.0/-1,M10.5.0/0',
    'IST-2IDT,M3.4.4/26,M10.5.0', '<-04>4<-03>,M9.1.6/24,M4.1.6/24',
    '<+1245>-12:45<+1345>,M9.5.0/2:45,M4.1.0/3:45', 'AEST-10AEDT,M10.1.0,M4.1.0/3',
    'IST-1GMT0,M10.5.0,M3.5.0/1', 'EST5EDT,M3.2.0,M11.1.0');
var
  I, N: Integer;
  LReal, LFooter: IPcTimeZone;
  LAt, LFooterAt: Int64;
begin
  // From 2030, past every zone's last explicit transition, the real zone
  // follows its footer: the footer alone must give the same transitions
  // (and the real zones are checked against zdump by Golden_Transitions).
  for I := 0 to High(ZONES) do
  begin
    LReal := Zone(ZONES[I]);
    LFooter := FooterZone(FOOTERS[I]);
    LAt := 1893456000;           // 2030-01-01T00:00Z
    LFooterAt := LAt;
    for N := 1 to 20 do
    begin
      TAssert.AssertTrue(ZONES[I], LReal.NextTransition(LAt, LAt));
      TAssert.AssertTrue(FOOTERS[I], LFooter.NextTransition(LFooterAt, LFooterAt));
      TAssert.AssertEquals(FOOTERS[I] + ' transition', LAt, LFooterAt);
      TAssert.AssertEquals(FOOTERS[I] + ' offset', LReal.OffsetAt(LAt), LFooter.OffsetAt(LAt));
      TAssert.AssertEquals(FOOTERS[I] + ' DST', LReal.Info(LAt).IsDst, LFooter.Info(LAt).IsDst);
      TAssert.AssertEquals(FOOTERS[I] + ' abbreviation', LReal.Info(LAt).Abbreviation,
        LFooter.Info(LAt).Abbreviation);
    end;
  end;
end;

procedure TTimeZonesTests.Footer_SpecialRules;
var
  LZone: IPcTimeZone;
  LAt: Int64;
begin
  // No DST: a fixed offset, with minutes.
  LZone := FooterZone('<+0545>-5:45');
  TAssert.AssertEquals(20700, LZone.OffsetAt(JAN_2026));
  TAssert.AssertFalse(LZone.NextTransition(JAN_2026, LAt));
  // DST all year: the rule ends one year at the instant the next one starts.
  LZone := FooterZone('EST5EDT4,0/0,J365/25');
  TAssert.AssertEquals('January', -14400, LZone.OffsetAt(JAN_2026));
  TAssert.AssertEquals('July', -14400, LZone.OffsetAt(1782907200));
  TAssert.AssertEquals('New Year''s Eve', -14400, LZone.OffsetAt(1798761599));
  TAssert.AssertFalse('never changes', LZone.NextTransition(JAN_2026, LAt));
  // A DST name with no rule: the POSIX default (the United States' rule)
  // and an hour ahead of standard time.
  LZone := FooterZone('EST5EDT');
  TAssert.AssertEquals(-18000, LZone.OffsetAt(JAN_2026));
  TAssert.AssertEquals(-14400, LZone.OffsetAt(1782907200));
  TAssert.AssertTrue(LZone.NextTransition(JAN_2026, LAt));
  TAssert.AssertEquals('second Sunday of March', 1772953200, LAt);
  // Jn never counts February 29; n does. 2028 is a leap year.
  LZone := FooterZone('XST0XDT,J60/0,J61/0');      // March 1 (J60) to March 2
  TAssert.AssertEquals('2028-03-01T00:00Z', 3600, LZone.OffsetAt(1835481600));
  TAssert.AssertEquals('2028-02-29T12:00Z', 0, LZone.OffsetAt(1835438400));
  LZone := FooterZone('XST0XDT,59/0,60/0');        // day 59 = Feb 29 in 2028
  TAssert.AssertEquals('2028-02-29T12:00Z', 3600, LZone.OffsetAt(1835438400));
  TAssert.AssertEquals('2027-03-01T12:00Z', 3600, LZone.OffsetAt(1803902400));
end;

procedure TTimeZonesTests.Footer_Invalid;
const
  BAD: array[0..7] of string = ('EST', 'ES5', 'EST5EDT,M3.2.0', 'EST5EDT,M13.1.0,M11.1.0',
    'EST5EDT,M3.6.0,M11.1.0', '<+03', 'EST5EDT,M3.2.0,M11.1.0x', 'EST5EDT,J0,J365');
var
  I: Integer;
begin
  for I := 0 to High(BAD) do
    try
      FooterZone(BAD[I]);
      TAssert.Fail('must refuse "' + BAD[I] + '"');
    except
      on E: EPcTimeZoneError do
        TAssert.AssertTrue(E.Message, Pos(BAD[I], E.Message) > 0);
    end;
end;

procedure TTimeZonesTests.Tzif_Version1AndEmptyFooter;
var
  LZone: IPcTimeZone;
  LAt: Int64;
begin
  // Version 1: 32-bit transitions, no footer: the last type stays.
  LZone := PcTimeZoneFromTzif('Test/V1', BuildTzif(0, [0, 1000000], [1, 2],
    [100, 3600, 7200], [False, True, False], ['LMT', 'ONE', 'TWO'], ''));
  TAssert.AssertEquals('before the first', 100, LZone.OffsetAt(-1));
  TAssert.AssertEquals('at the first', 3600, LZone.OffsetAt(0));
  TAssert.AssertEquals('ONE', LZone.Info(999999).Abbreviation);
  TAssert.AssertTrue(LZone.Info(999999).IsDst);
  TAssert.AssertEquals('forever after', 7200, LZone.OffsetAt(16725268800));
  TAssert.AssertTrue(LZone.NextTransition(0, LAt));
  TAssert.AssertEquals(1000000, LAt);
  TAssert.AssertFalse(LZone.NextTransition(LAt, LAt));
  // Version 2 with an empty footer: the same.
  LZone := PcTimeZoneFromTzif('Test/V2', BuildTzif(Ord('2'), [-5000000000, 1000000], [1, 2],
    [100, 3600, 7200], [False, True, False], ['LMT', 'ONE', 'TWO'], ''));
  TAssert.AssertEquals('64-bit transition', 3600, LZone.OffsetAt(-5000000000));
  TAssert.AssertEquals(100, LZone.OffsetAt(-5000000001));
  TAssert.AssertEquals(7200, LZone.OffsetAt(16725268800));
  // Version 3 and 4 read the same way.
  LZone := PcTimeZoneFromTzif('Test/V4', BuildTzif(Ord('4'), [0], [1], [0, 3600],
    [False, False], ['LMT', 'ONE'], 'ONE-1'));
  TAssert.AssertEquals(3600, LZone.OffsetAt(16725268800));
  TAssert.AssertEquals('Test/V4', LZone.Name);
  TAssert.AssertEquals('Test/V4', LZone.CanonicalName);
end;

procedure TTimeZonesTests.Tzif_Broken;
var
  LGood, LBad: TBytes;
  I: Integer;
  LWhy: string;
begin
  LGood := BuildTzif(Ord('2'), [0, 1000], [0, 1], [0, 3600], [False, False], ['AAA', 'BBB'], 'BBB-1');
  for I := 0 to 6 do
  begin
    LBad := Copy(LGood, 0, Length(LGood));
    case I of
      0: LBad := Copy(LGood, 0, 40);                          // truncated header
      1: LBad[0] := Ord('X');                                 // magic
      2: LBad := Copy(LGood, 0, Length(LGood) - 1);           // footer's last newline
      3: LBad[4] := Ord('1');                                 // version
      4: LBad := BuildTzif(Ord('2'), [1000, 0], [0, 1], [0, 3600], [False, False],
           ['AAA', 'BBB'], 'BBB-1');                          // out of order
      5: LBad := BuildTzif(Ord('2'), [0], [5], [0, 3600], [False, False],
           ['AAA', 'BBB'], 'BBB-1');                          // type index
      6: LBad := BuildTzif(Ord('2'), [0], [1], [0, 3600], [False, False],
           ['AAA', 'BBB'], 'BBB-1', 1);                       // leap seconds
    end;
    try
      PcTimeZoneFromTzif('Test/Bad', LBad);
      TAssert.Fail('must refuse case ' + IntToStr(I));
    except
      on E: EPcTimeZoneError do
        LWhy := E.Message;
    end;
    TAssert.AssertTrue(LWhy, Pos('Invalid TZif', LWhy) = 1);
  end;
  TAssert.AssertTrue(Pos('leap', LWhy) > 0);
end;

procedure TTimeZonesTests.MemorySource_Catalog;
var
  LMemory: TPcMemoryTzSource;
  LSource: IPcTzSource;
  LCatalog: TPcTimeZoneCatalog;
  LNames: TArray<string>;
  LZone, LAlias: IPcTimeZone;
begin
  LMemory := TPcMemoryTzSource.Create('test-1');
  LSource := LMemory;
  LMemory.Add('Test/Zone', BuildTzif(Ord('2'), [0], [1], [0, 3600], [False, False],
    ['AAA', 'BBB'], 'BBB-1'));
  LMemory.AddLink('Test/Alias', 'Test/Zone');
  LMemory.Add('Test/Broken', TBytes.Create(1, 2, 3));
  LMemory.Add('not a name', TBytes.Create(1, 2, 3));
  LCatalog := TPcTimeZoneCatalog.Create(LSource);
  try
    TAssert.AssertEquals('test-1', LCatalog.DataVersion);
    LNames := LCatalog.Names;
    TAssert.AssertEquals('ill-formed names dropped', 3, Length(LNames));
    TAssert.AssertEquals('Test/Alias', LNames[0]);
    TAssert.AssertEquals('Test/Broken', LNames[1]);
    TAssert.AssertEquals('Test/Zone', LNames[2]);
    TAssert.AssertFalse(LCatalog.IsValidName('not a name'));
    TAssert.AssertFalse('the default catalog''s zones aren''t here',
      LCatalog.IsValidName('America/New_York'));
    LZone := LCatalog.Find('Test/Zone');
    LAlias := LCatalog.Find('Test/Alias');
    TAssert.AssertEquals('Test/Zone', LAlias.CanonicalName);
    TAssert.AssertEquals(3600, LAlias.OffsetAt(10));
    TAssert.AssertTrue('a zone per name', LZone <> LAlias);
    try
      LCatalog.Find('Test/Broken');
      TAssert.Fail('broken data must raise');
    except
      on E: EPcUnknownTimeZone do
        TAssert.Fail('broken data isn''t an unknown zone');
      on E: EPcTimeZoneError do
        TAssert.AssertTrue(E.Message, Pos('Test/Broken: Invalid TZif', E.Message) = 1);
    end;
  finally
    LCatalog.Free;
  end;
end;

{ A zoneinfo tree on disk }

function TempDir: string;
begin
  {$IFDEF FPC}
  Result := GetTempDir;
  {$ELSE}
  Result := TPath.GetTempPath;
  {$ENDIF}
end;

procedure WriteFile(const APath: string; const AData: TBytes);
var
  LStream: TFileStream;
begin
  ForceDirectories(ExtractFileDir(APath));
  LStream := TFileStream.Create(APath, fmCreate);
  try
    if Length(AData) > 0 then
      LStream.WriteBuffer(AData[0], Length(AData));
  finally
    LStream.Free;
  end;
end;

function TextBytes(const AText: string): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(AText));
  for I := 1 to Length(AText) do
    Result[I - 1] := Ord(AText[I]);
end;

function EmbeddedBytes(const AName: string): TBytes;
var
  LSource: IPcTzSource;
begin
  LSource := TPcEmbeddedTzSource.Create;
  if not LSource.TryRead(AName, Result) then
    raise Exception.Create('not embedded: ' + AName);
end;

procedure RemoveTree(const ADir: string);
var
  LSearch: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, LSearch) = 0 then
  try
    repeat
      if (LSearch.Name = '.') or (LSearch.Name = '..') then
        Continue;
      if (LSearch.Attr and faDirectory) <> 0 then
        RemoveTree(IncludeTrailingPathDelimiter(ADir) + LSearch.Name)
      else
        DeleteFile(IncludeTrailingPathDelimiter(ADir) + LSearch.Name);
    until FindNext(LSearch) <> 0;
  finally
    FindClose(LSearch);
  end;
  RemoveDir(ADir);
end;

procedure TTimeZonesTests.DirectorySource_Tree;
var
  LRoot, D: string;
  LSource: IPcTzSource;
  LCatalog: TPcTimeZoneCatalog;
  LNames: TArray<string>;
  LData: TBytes;
  LZone: IPcTimeZone;
begin
  LRoot := IncludeTrailingPathDelimiter(TempDir) + 'pctz-' + IntToStr(PcTickMs) +
    '-' + IntToStr(Random(1000000));
  D := IncludeTrailingPathDelimiter(LRoot);
  try
    WriteFile(D + 'America' + PathDelim + 'New_York', EmbeddedBytes('America/New_York'));
    WriteFile(D + 'Europe' + PathDelim + 'Lisbon', EmbeddedBytes('Europe/Lisbon'));
    WriteFile(D + 'Portugal', EmbeddedBytes('Europe/Lisbon'));
    WriteFile(D + 'posixrules', EmbeddedBytes('America/New_York'));
    WriteFile(D + 'right' + PathDelim + 'America' + PathDelim + 'New_York',
      EmbeddedBytes('America/New_York'));
    WriteFile(D + 'zone.tab', TextBytes('# not a zone' + #10));
    WriteFile(D + 'Broken' + PathDelim + 'Text', TextBytes('not TZif' + #10));

    // No tzdata.zi: the tree is walked.
    LSource := TPcDirectoryTzSource.Create(LRoot);
    LNames := LSource.Names;
    TAssert.AssertEquals('walked names', 3, Length(LNames));
    TAssert.AssertEquals('America/New_York', LNames[0]);
    TAssert.AssertEquals('Europe/Lisbon', LNames[1]);
    TAssert.AssertEquals('Portugal', LNames[2]);
    TAssert.AssertEquals('no version without tzdata.zi', '', LSource.Version);
    TAssert.AssertFalse('never leaves the tree', LSource.TryRead('../Portugal', LData));
    TAssert.AssertFalse(LSource.TryRead('Mars/Olympus', LData));

    // With tzdata.zi: its names and links, those whose file exists.
    WriteFile(D + 'tzdata.zi', TextBytes('# version 2099z' + #10 + '# redo posix_only' + #10 +
      'Z America/New_York -4:56:2 - LMT 1883 N 18 17u' + #10 + 'Z Europe/Lisbon -0:36:45 - LMT 1884' +
      #10 + 'L America/New_York US/Eastern' + #10 + 'L Europe/Lisbon Portugal' + #10));
    LSource := TPcDirectoryTzSource.Create(LRoot);
    TAssert.AssertEquals('2099z', LSource.Version);
    TAssert.AssertEquals('Europe/Lisbon', LSource.CanonicalName('Portugal'));
    LCatalog := TPcTimeZoneCatalog.Create(LSource);
    try
      LNames := LCatalog.Names;
      TAssert.AssertEquals('US/Eastern has no file', 3, Length(LNames));
      TAssert.AssertFalse(LCatalog.IsValidName('US/Eastern'));
      TAssert.AssertFalse(LCatalog.IsValidName('posixrules'));
      LZone := LCatalog.Find('Portugal');
      TAssert.AssertEquals('Europe/Lisbon', LZone.CanonicalName);
      TAssert.AssertEquals(3600, LZone.OffsetAt(1774746000));
      TAssert.AssertEquals(-14400, LCatalog.Find('America/New_York').OffsetAt(1780272000));
    finally
      LCatalog.Free;
    end;
  finally
    RemoveTree(LRoot);
  end;
  TAssert.AssertFalse('cleaned up', DirectoryExists(LRoot));
end;

procedure TTimeZonesTests.DirectorySource_System;
const
  ZONES: array[0..7] of string = ('America/New_York', 'Europe/Lisbon', 'America/Sao_Paulo',
    'Asia/Kathmandu', 'Australia/Lord_Howe', 'Australia/Sydney', 'Europe/Dublin', 'UTC');
  FROM_1990 = 631152000;
  TO_2037 = 2114380800;
var
  LCatalog: TPcTimeZoneCatalog;
  I: Integer;
  LSystem, LEmbedded: IPcTimeZone;
  LAt, LEmbeddedAt: Int64;
  LMore: Boolean;
begin
  // Only where the system has a tree (Linux, macOS). Debian's files are
  // "fat" (transitions written out to 2037), the embedded ones "slim" (the
  // footer from the last rule change): both must give the same answers.
  // Zones that didn't change between 2026b (Debian 12) and the embedded
  // release, from 1990: Debian builds with backzone, whose history before
  // 1970 differs from IANA's default on purpose.
  if not FileExists('/usr/share/zoneinfo/America/New_York') then
    Exit;
  LCatalog := TPcTimeZoneCatalog.Create(TPcDirectoryTzSource.Create('/usr/share/zoneinfo'));
  try
    TAssert.AssertTrue('the system lists its version', LCatalog.DataVersion <> '');
    for I := 0 to High(ZONES) do
    begin
      LSystem := LCatalog.Find(ZONES[I]);
      LEmbedded := Zone(ZONES[I]);
      LAt := FROM_1990;
      LEmbeddedAt := FROM_1990;
      repeat
        LMore := LSystem.NextTransition(LAt, LAt);
        TAssert.AssertEquals(ZONES[I] + ' has the same next', LMore,
          LEmbedded.NextTransition(LEmbeddedAt, LEmbeddedAt));
        if LMore then
        begin
          TAssert.AssertEquals(ZONES[I] + ' transition', LEmbeddedAt, LAt);
          TAssert.AssertEquals(ZONES[I] + ' offset', LEmbedded.OffsetAt(LAt), LSystem.OffsetAt(LAt));
        end;
      until (not LMore) or (LAt > TO_2037);
    end;
  finally
    LCatalog.Free;
  end;
end;

procedure TTimeZonesTests.Golden_Names;
var
  G: TGolden;
  I: Integer;
begin
  G := LoadGolden;
  // An empty or cut file would let the other Golden_* tests check nothing.
  TAssert.AssertTrue('names in the file', Length(G.Names) > 500);
  TAssert.AssertTrue('offsets in the file', G.OffsetCount > 20000);
  TAssert.AssertTrue('transitions in the file', G.TransitionCount > 18000);
  TAssert.AssertTrue('mappings in the file', G.MappingCount > 7000);
  TAssert.AssertEquals('every name', Length(G.Names), Length(PcTimeZones.Names));
  for I := 0 to High(G.Names) do
    TAssert.AssertTrue(G.Names[I], PcTimeZones.IsValidName(G.Names[I]));
end;

procedure TTimeZonesTests.Golden_Offsets;
var
  G: TGolden;
  I, LFailures: Integer;
  LName, LFirst: string;
  LAt: Int64;
  LGot: Integer;
begin
  G := LoadGolden;
  LFailures := 0;
  LFirst := '';
  for I := 0 to G.OffsetCount - 1 do
  begin
    LName := G.Names[Integer(G.Offsets[I * 3])];
    LAt := G.Offsets[I * 3 + 1];
    LGot := Zone(LName).OffsetAt(LAt);
    if LGot <> G.Offsets[I * 3 + 2] then
    begin
      Inc(LFailures);
      if LFirst = '' then
        LFirst := Format('%s at %d: expected %d, got %d', [LName, LAt, G.Offsets[I * 3 + 2], LGot]);
    end;
  end;
  TAssert.AssertEquals(Format('%d of %d offsets differ; first: %s',
    [LFailures, G.OffsetCount, LFirst]), 0, LFailures);
end;

procedure TTimeZonesTests.Golden_Transitions;
var
  G: TGolden;
  I, LFailures, LZoneIndex, LPrevZone: Integer;
  LZone: IPcTimeZone;
  LAt, LExpected, LFrom, LGot: Int64;
  LFirst: string;

  procedure Mismatch(const AWhat: string);
  begin
    Inc(LFailures);
    if LFirst = '' then
      LFirst := Format('%s at %d: %s', [LZone.Name, LExpected, AWhat]);
  end;

begin
  G := LoadGolden;
  LFailures := 0;
  LFirst := '';
  LPrevZone := -1;
  LFrom := 0;
  for I := 0 to G.TransitionCount - 1 do
  begin
    LZoneIndex := Integer(G.Transitions[I * 4]);
    LExpected := G.Transitions[I * 4 + 1];
    if LZoneIndex <> LPrevZone then
    begin
      LZone := Zone(G.Names[LZoneIndex]);
      LFrom := LExpected - 1;    // the chain starts at the first one listed
      LPrevZone := LZoneIndex;
    end;
    // No transition may be missed or invented between two listed ones.
    if not LZone.NextTransition(LFrom, LGot) then
      Mismatch('no next transition')
    else if LGot <> LExpected then
      Mismatch(Format('next transition at %d', [LGot]));
    LAt := LExpected;
    if LZone.OffsetAt(LAt - 1) <> G.Transitions[I * 4 + 2] then
      Mismatch(Format('offset before %d', [LZone.OffsetAt(LAt - 1)]));
    if LZone.OffsetAt(LAt) <> G.Transitions[I * 4 + 3] then
      Mismatch(Format('offset after %d', [LZone.OffsetAt(LAt)]));
    LFrom := LExpected;
  end;
  TAssert.AssertEquals(Format('%d of %d transitions differ; first: %s',
    [LFailures, G.TransitionCount, LFirst]), 0, LFailures);
end;

procedure TTimeZonesTests.Golden_Mappings;
var
  G: TGolden;
  I, LFailures, LCount: Integer;
  LZone: IPcTimeZone;
  LLocalSeconds, LFold0, LFold1: Int64;
  LLocal: TPcLocalDateTime;
  LMap: TPcZoneMapping;
  LFirst: string;
begin
  G := LoadGolden;
  LFailures := 0;
  LFirst := '';
  for I := 0 to G.MappingCount - 1 do
  begin
    LZone := Zone(G.Names[Integer(G.Mappings[I * 5])]);
    LLocalSeconds := G.Mappings[I * 5 + 1];
    LCount := Integer(G.Mappings[I * 5 + 2]);
    LFold0 := G.Mappings[I * 5 + 3];
    LFold1 := G.Mappings[I * 5 + 4];
    LLocal := PcUtcZone.ToLocal(LLocalSeconds);   // the reading, as fields
    LMap := LZone.Map(LLocal);
    // Python's fold=0 is java.time's default: the shifted reading in a gap,
    // the earlier instant in an overlap; fold=1 the later one there.
    if (LMap.Count <> LCount) or (LZone.ToUtc(LLocal) <> LFold0) or
      ((LCount = 2) and ((LMap.Earlier <> LFold0) or (LMap.Later <> LFold1))) then
    begin
      Inc(LFailures);
      if LFirst = '' then
        LFirst := Format('%s %s: expected count %d, %d/%d; got %d, %d/%d', [LZone.Name,
          LLocal.ToString, LCount, LFold0, LFold1, LMap.Count, LZone.ToUtc(LLocal), LMap.Later]);
    end;
  end;
  TAssert.AssertEquals(Format('%d of %d mappings differ; first: %s',
    [LFailures, G.MappingCount, LFirst]), 0, LFailures);
end;

{ Threads }

type
  TConvertThread = class(TThread)
  private
    FCatalog: TPcTimeZoneCatalog;
    FStart, FDone: TEvent;
    FRemaining, FErrors: PInteger;
  protected
    procedure Execute; override;
  public
    constructor Create(ACatalog: TPcTimeZoneCatalog; AStart, ADone: TEvent;
      ARemaining, AErrors: PInteger);
  end;

constructor TConvertThread.Create(ACatalog: TPcTimeZoneCatalog; AStart, ADone: TEvent;
  ARemaining, AErrors: PInteger);
begin
  FCatalog := ACatalog;
  FStart := AStart;
  FDone := ADone;
  FRemaining := ARemaining;
  FErrors := AErrors;
  inherited Create(False);
end;

procedure TConvertThread.Execute;
var
  I, N: Integer;
  LZone: IPcTimeZone;
  LStart, LEnd: Int64;
begin
  try
    if FStart.WaitFor(10000) <> wrSignaled then
      PcAtomicInc(FErrors^)
    else
      for N := 1 to 50 do
        // Every thread asks for the same names at once: the first Find of
        // each parses it while the others wait on the catalog's lock.
        for I := 0 to 19 do
        begin
          LZone := FCatalog.Find(PcTzdbZoneNames[(I * 17) mod PC_TZDB_ZONE_COUNT]);
          if LZone.OffsetAt(1780272000) <>
            PcTimeZones.Find(LZone.Name).OffsetAt(1780272000) then
            PcAtomicInc(FErrors^);
          LZone := FCatalog.Find('America/New_York');
          LZone.DayBounds(2026, 11, 1, LStart, LEnd);
          if (LStart <> 1793505600) or (LEnd <> 1793595600) then
            PcAtomicInc(FErrors^);
          if LZone.ToUtc(TPcLocalDateTime.Create(2026, 3, 8, 2, 30)) <> 1772955000 then
            PcAtomicInc(FErrors^);
        end;
  except
    PcAtomicInc(FErrors^);
  end;
  if PcAtomicDec(FRemaining^) = 0 then
    FDone.SetEvent;
end;

procedure TTimeZonesTests.Threads_ConvertThroughOneCatalog;
const
  THREADS = 8;
var
  LCatalog: TPcTimeZoneCatalog;
  LStart, LDone: TEvent;
  LThreads: array[0..THREADS - 1] of TConvertThread;
  LRemaining, LErrors, I: Integer;
  LSignaled: Boolean;
begin
  LCatalog := TPcTimeZoneCatalog.Create(TPcEmbeddedTzSource.Create);
  LStart := TEvent.Create(nil, True, False, '');
  LDone := TEvent.Create(nil, True, False, '');
  LRemaining := THREADS;
  LErrors := 0;
  try
    for I := 0 to THREADS - 1 do
      LThreads[I] := TConvertThread.Create(LCatalog, LStart, LDone, @LRemaining, @LErrors);
    LStart.SetEvent;
    LSignaled := LDone.WaitFor(60000) = wrSignaled;
    for I := 0 to THREADS - 1 do
    begin
      LThreads[I].WaitFor;
      LThreads[I].Free;
    end;
    TAssert.AssertTrue('every thread finished within the deadline', LSignaled);
    TAssert.AssertEquals('errors', 0, LErrors);
  finally
    LDone.Free;
    LStart.Free;
    LCatalog.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TTimeZonesTests);

end.
