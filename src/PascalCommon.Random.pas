unit PascalCommon.Random;

{$I pascalcommon.inc}

{ Random bytes from the operating system's cryptographic source, the same on
  Delphi and FPC: PcFillRandom and PcRandomBytes.

  For secrets and ids: pascal-api-infra-faa's JWT signing keys and this
  library's trace and span ids (PascalCommon.TraceContext, which had this
  code privately until 1.15.0). Not Random/Randomize: a Mersenne twister
  seeded from the clock, predictable, and a global state that isn't safe
  across threads. Not CreateGUID either: on FPC 3.2.2 for Linux it reads
  /proc/sys/kernel/random/uuid, then /dev/urandom, and falls back to Random;
  on Unix systems other than Linux and FreeBSD it is Random alone.

  Windows: BCryptGenRandom with BCRYPT_USE_SYSTEM_PREFERRED_RNG (Windows 7
  and later). Elsewhere: /dev/urandom, opened once in initialization (no
  lazily created shared state) and read through SysUtils' FileRead, which
  both compilers have on every POSIX target. Concurrent reads of the one
  descriptor are safe: it is a character device with no position. When the
  source fails, EPcRandom is raised; there is never a fallback to a
  predictable generator. }

interface

uses
  SysUtils;

type
  EPcRandom = class(Exception);

/// Fills ACount bytes at ABuffer from the OS source. Nothing for 0;
/// EArgumentException for a negative count; EPcRandom when the source fails.
procedure PcFillRandom(var ABuffer; ACount: Integer);

/// ACount bytes from the OS source (an empty array for 0). Same errors as
/// PcFillRandom.
function PcRandomBytes(ACount: Integer): TBytes;

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

procedure PcFillRandom(var ABuffer; ACount: Integer);
{$IFDEF PASCALCOMMON_WINDOWS}
var
  LStatus: LongInt;
begin
  if ACount < 0 then
    raise EArgumentException.CreateFmt('PcFillRandom: negative count %d', [ACount]);
  if ACount = 0 then
    Exit;
  LStatus := BCryptGenRandom(nil, PByte(@ABuffer), Cardinal(ACount),
    BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  if LStatus <> 0 then
    raise EPcRandom.CreateFmt('BCryptGenRandom failed (NTSTATUS $%.8x)', [LStatus]);
end;
{$ELSE}
var
  P: PByte;
  LRead: Integer;
begin
  if ACount < 0 then
    raise EArgumentException.CreateFmt('PcFillRandom: negative count %d', [ACount]);
  if ACount = 0 then
    Exit;
  if not GUrandomOpen then
    raise EPcRandom.Create('Cannot open ' + URANDOM_PATH);
  P := PByte(@ABuffer);
  while ACount > 0 do
  begin
    LRead := FileRead(GUrandom, P^, ACount);
    if LRead <= 0 then
      raise EPcRandom.Create('Cannot read ' + URANDOM_PATH);
    Inc(P, LRead);
    Dec(ACount, LRead);
  end;
end;
{$ENDIF}

function PcRandomBytes(ACount: Integer): TBytes;
begin
  Result := nil;
  if ACount < 0 then
    raise EArgumentException.CreateFmt('PcRandomBytes: negative count %d', [ACount]);
  SetLength(Result, ACount);
  if ACount > 0 then
    PcFillRandom(Result[0], ACount);
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
