unit PascalCommon.TraceContext;

{$I pascalcommon.inc}

{ W3C Trace Context (Level 1) ids and headers: new trace and span ids,
  validation, and the traceparent / tracestate rules, the same on Delphi and
  FPC.

  It is phase A, part 1, of pascal-api-infra-faa's observability design
  (docs/observability-design.md there): the trace id that crosses process
  boundaries and becomes the API's X-Request-Id. It lives here, not in the
  API library, because pascal-db-faa, pascal-redis-faa and pascal-amqp-faa
  will carry the same context (phase D) and already depend on this library.
  Everything is fixed by the W3C specification, so it can go into a 1.x
  release without fear of a later breaking change.

  Ids are lowercase hex strings, not byte records: every caller writes them
  to a header or a log line. PcFormatTraceParent writes what it is given;
  callers pass ids from PcNewTraceId/PcNewSpanId or from a parsed header.

  Random source. CreateGUID was read in FPC 3.2.2's RTL before choosing:
  on Linux it reads /proc/sys/kernel/random/uuid and parses the string, then
  /dev/urandom, and as a last resort Random (a Mersenne twister seeded from
  the clock, a global state not safe across threads); on Unix systems other
  than Linux and FreeBSD it is Random alone. A GUID v4 also has fixed
  version and variant bits, and TGUID's first fields are little-endian in
  memory. So the bytes come from the OS directly: BCryptGenRandom
  (BCRYPT_USE_SYSTEM_PREFERRED_RNG, Windows 7 and later) on Windows, and
  /dev/urandom elsewhere, opened once in initialization (no lazily created
  shared state, see CLAUDE.md) and read through SysUtils' FileRead, which
  both compilers have on every POSIX target. Concurrent reads of one
  /dev/urandom descriptor are safe: it is a character device with no
  position. If the source fails, EPcTraceContext is raised rather than
  falling back to a predictable generator: a trace id that repeats across
  processes merges unrelated traces in the backend.

  Parsing follows the specification's text (Level 1, sections 3.2 and 3.3):
  lowercase hex only, version ff invalid, all-zero trace id or parent id
  invalid; version 00 is exactly 55 characters; a higher version is parsed
  when its first 55 characters do and the 56th, if any, is "-", and its
  unknown fields are not interpreted. Surrounding spaces and tabs (OWS) are
  ignored, as the W3C test suite expects. tracestate is not parsed: it is
  forwarded unchanged when traceparent was valid and dropped otherwise, or
  when it is longer than 512 characters (the specification asks for at least
  512 to be propagated and allows dropping whole entries beyond that; phase A
  drops the whole header instead of parsing the list). }

interface

uses
  SysUtils;

type
  EPcTraceContext = class(Exception);

  /// A parsed traceparent header.
  TPcTraceParent = record
    /// 2 lowercase hex digits; 0 for every header this library writes.
    Version: Byte;
    /// 32 lowercase hex digits, not all zeros.
    TraceId: string;
    /// 16 lowercase hex digits, not all zeros: the caller's span.
    ParentId: string;
    /// As received. Only bit 0 (sampled) is defined in version 00.
    Flags: Byte;
    function Sampled: Boolean;
  end;

const
  /// Length of a version 00 traceparent header.
  PC_TRACEPARENT_LENGTH = 55;
  /// Longest tracestate PcResolveTraceState forwards.
  PC_TRACESTATE_MAX_LENGTH = 512;

/// A new random trace id: 32 lowercase hex digits, never all zeros.
/// Raises EPcTraceContext if the OS random source fails.
function PcNewTraceId: string;
/// A new random span id: 16 lowercase hex digits, never all zeros.
/// Raises EPcTraceContext if the OS random source fails.
function PcNewSpanId: string;

/// True when AValue is exactly 32 lowercase hex digits and not all zeros.
function PcIsValidTraceId(const AValue: string): Boolean;
/// True when AValue is exactly 16 lowercase hex digits and not all zeros.
function PcIsValidSpanId(const AValue: string): Boolean;

/// Parses a traceparent header. False (AValue cleared) when the header must
/// be ignored and a new trace started.
function PcTryParseTraceParent(const AHeader: string; out AValue: TPcTraceParent): Boolean;
/// A version 00 traceparent: '00-<trace id>-<span id>-01' when ASampled,
/// '-00' otherwise. The ids are written as given.
function PcFormatTraceParent(const ATraceId, ASpanId: string; ASampled: Boolean): string;

/// The tracestate to forward: AHeader without surrounding spaces and tabs
/// when ATraceParentValid, '' when the traceparent was invalid or missing,
/// or when the header is longer than PC_TRACESTATE_MAX_LENGTH.
function PcResolveTraceState(ATraceParentValid: Boolean; const AHeader: string): string;

implementation

{$IFDEF PASCALCOMMON_WINDOWS}
const
  BCRYPT_USE_SYSTEM_PREFERRED_RNG = $00000002;

function BCryptGenRandom(hAlgorithm: Pointer; pbBuffer: PByte; cbBuffer: Cardinal;
  dwFlags: Cardinal): LongInt; stdcall; external 'bcrypt.dll' name 'BCryptGenRandom';
{$ELSE}
const
  URANDOM_PATH = '/dev/urandom';

var
  GUrandom: THandle;
  GUrandomOpen: Boolean;
{$ENDIF}

const
  HEX_DIGITS: array[0..15] of Char = ('0', '1', '2', '3', '4', '5', '6', '7',
    '8', '9', 'a', 'b', 'c', 'd', 'e', 'f');

procedure FillRandom(var ABuffer; ACount: Integer);
{$IFDEF PASCALCOMMON_WINDOWS}
var
  LStatus: LongInt;
begin
  LStatus := BCryptGenRandom(nil, PByte(@ABuffer), ACount, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  if LStatus <> 0 then
    raise EPcTraceContext.CreateFmt('BCryptGenRandom failed (NTSTATUS $%.8x)', [LStatus]);
end;
{$ELSE}
var
  P: PByte;
  LRead: Integer;
begin
  if not GUrandomOpen then
    raise EPcTraceContext.Create('Cannot open ' + URANDOM_PATH);
  P := PByte(@ABuffer);
  while ACount > 0 do
  begin
    LRead := FileRead(GUrandom, P^, ACount);
    if LRead <= 0 then
      raise EPcTraceContext.Create('Cannot read ' + URANDOM_PATH);
    Inc(P, LRead);
    Dec(ACount, LRead);
  end;
end;
{$ENDIF}

function NewRandomHex(AByteCount: Integer): string;
var
  LBytes: array[0..15] of Byte;
  I: Integer;
  LNonZero: Boolean;
begin
  FillChar(LBytes, SizeOf(LBytes), 0);
  repeat
    FillRandom(LBytes, AByteCount);
    LNonZero := False;
    for I := 0 to AByteCount - 1 do
      if LBytes[I] <> 0 then
        LNonZero := True;
  until LNonZero;
  Result := '';
  SetLength(Result, AByteCount * 2);
  for I := 0 to AByteCount - 1 do
  begin
    Result[I * 2 + 1] := HEX_DIGITS[LBytes[I] shr 4];
    Result[I * 2 + 2] := HEX_DIGITS[LBytes[I] and $F];
  end;
end;

function IsLowerHex(C: Char): Boolean; inline;
begin
  Result := ((C >= '0') and (C <= '9')) or ((C >= 'a') and (C <= 'f'));
end;

function HexValue(C: Char): Byte; inline;
begin
  if C <= '9' then
    Result := Ord(C) - Ord('0')
  else
    Result := Ord(C) - Ord('a') + 10;
end;

// True when AValue[AStart..AStart+ALength-1] is lowercase hex; ANonZero says
// whether any digit is not '0'.
function ScanHex(const AValue: string; AStart, ALength: Integer; out ANonZero: Boolean): Boolean;
var
  I: Integer;
begin
  ANonZero := False;
  Result := Length(AValue) >= AStart + ALength - 1;
  if not Result then
    Exit;
  for I := AStart to AStart + ALength - 1 do
  begin
    if not IsLowerHex(AValue[I]) then
      Exit(False);
    if AValue[I] <> '0' then
      ANonZero := True;
  end;
end;

function IsValidId(const AValue: string; ALength: Integer): Boolean;
var
  LNonZero: Boolean;
begin
  Result := (Length(AValue) = ALength) and ScanHex(AValue, 1, ALength, LNonZero) and LNonZero;
end;

function IsOws(C: Char): Boolean; inline;
begin
  Result := (C = ' ') or (C = #9);
end;

function TrimOws(const AValue: string): string;
var
  LFirst, LLast: Integer;
begin
  LFirst := 1;
  LLast := Length(AValue);
  while (LFirst <= LLast) and IsOws(AValue[LFirst]) do
    Inc(LFirst);
  while (LLast >= LFirst) and IsOws(AValue[LLast]) do
    Dec(LLast);
  Result := Copy(AValue, LFirst, LLast - LFirst + 1);
end;

{ TPcTraceParent }

function TPcTraceParent.Sampled: Boolean;
begin
  Result := (Flags and $01) <> 0;
end;

function PcNewTraceId: string;
begin
  Result := NewRandomHex(16);
end;

function PcNewSpanId: string;
begin
  Result := NewRandomHex(8);
end;

function PcIsValidTraceId(const AValue: string): Boolean;
begin
  Result := IsValidId(AValue, 32);
end;

function PcIsValidSpanId(const AValue: string): Boolean;
begin
  Result := IsValidId(AValue, 16);
end;

// Layout: vv-<32>-<16>-ff, positions 1-2, 3, 4-35, 36, 37-52, 53, 54-55.
function PcTryParseTraceParent(const AHeader: string; out AValue: TPcTraceParent): Boolean;
var
  S: string;
  LNonZero: Boolean;
begin
  AValue.Version := 0;
  AValue.TraceId := '';
  AValue.ParentId := '';
  AValue.Flags := 0;
  Result := False;
  S := TrimOws(AHeader);
  if Length(S) < PC_TRACEPARENT_LENGTH then
    Exit;
  if not ScanHex(S, 1, 2, LNonZero) or (Copy(S, 1, 2) = 'ff') then
    Exit;
  if (Copy(S, 1, 2) = '00') and (Length(S) <> PC_TRACEPARENT_LENGTH) then
    Exit;
  if (Length(S) > PC_TRACEPARENT_LENGTH) and (S[PC_TRACEPARENT_LENGTH + 1] <> '-') then
    Exit;
  if (S[3] <> '-') or (S[36] <> '-') or (S[53] <> '-') then
    Exit;
  if not ScanHex(S, 4, 32, LNonZero) or not LNonZero then
    Exit;
  if not ScanHex(S, 37, 16, LNonZero) or not LNonZero then
    Exit;
  if not ScanHex(S, 54, 2, LNonZero) then
    Exit;
  AValue.Version := HexValue(S[1]) shl 4 or HexValue(S[2]);
  AValue.TraceId := Copy(S, 4, 32);
  AValue.ParentId := Copy(S, 37, 16);
  AValue.Flags := HexValue(S[54]) shl 4 or HexValue(S[55]);
  Result := True;
end;

function PcFormatTraceParent(const ATraceId, ASpanId: string; ASampled: Boolean): string;
const
  FLAGS: array[Boolean] of string = ('00', '01');
begin
  Result := '00-' + ATraceId + '-' + ASpanId + '-' + FLAGS[ASampled];
end;

function PcResolveTraceState(ATraceParentValid: Boolean; const AHeader: string): string;
begin
  Result := '';
  if not ATraceParentValid then
    Exit;
  Result := TrimOws(AHeader);
  if Length(Result) > PC_TRACESTATE_MAX_LENGTH then
    Result := '';
end;

{$IFNDEF PASCALCOMMON_WINDOWS}
initialization
  GUrandom := FileOpen(URANDOM_PATH, fmOpenRead or fmShareDenyNone);
  GUrandomOpen := GUrandom <> THandle(-1);

finalization
  if GUrandomOpen then
    FileClose(GUrandom);
{$ENDIF}

end.
