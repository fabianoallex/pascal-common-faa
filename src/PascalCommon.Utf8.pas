unit PascalCommon.Utf8;

{$I pascalcommon.inc}

{ UTF-8 bytes to a string without silent loss, the same on both compilers.

  Text read from files and resources is UTF-8. On Delphi, string is UTF-16
  and TEncoding.UTF8 converts. On FPC, in Delphi mode, string is an
  AnsiString in the process's default code page; unless that code page is
  UTF-8, characters outside it silently become "?" (measured in
  pascal-db-faa: a plain console program runs with DefaultSystemCodePage =
  1252 on Windows; see the dual-compiler skill's rtl-gotchas.md, "Encoding").
  So when the bytes have non-ASCII characters and the code page isn't UTF-8,
  PcTryUtf8BytesToString returns False instead of corrupting the text, and
  the caller raises its own exception with its own context. LCL applications
  already run in UTF-8; console and service programs call
  SetMultiByteConversionCodePage(CP_UTF8) at startup.

  It came here in 1.4.0 because two libraries had the same code:
  pascal-db-faa (PdbUtf8BytesToString, PascalDb.SqlSources, for SQL files and
  resources) and pascal-api-infra-faa (PaUtf8BytesToString, PascalApi.Text,
  for .env files and logs). Compared 2026-10-08: the same body, BOM handling
  included; only the exception class and message differed, which is why this
  function returns a Boolean and raises nothing.

  Since 1.25.0 the bytes are validated as UTF-8 on both compilers before any
  conversion (RFC 3629, Unicode table 3-7: no stray continuation byte, no
  overlong form, no surrogate, nothing above U+10FFFF, no sequence cut at the
  end). Before, a file saved as UTF-16 (PowerShell 5.1's ">" writes FF FE)
  made Delphi's TEncoding.UTF8 raise EEncodingError, with no file name, and on
  FPC passed silently as text full of #0 (found by pascal-agenda-faa with a
  .env, 2026-10-30). PcIsValidUtf8 is public so a caller can tell "not UTF-8"
  from "UTF-8 that this FPC code page can't hold" in its own message.

  PcPercentEncode (1.26.0) is RFC 3986's percent-encoding over the UTF-8
  bytes: every byte but the unreserved characters (A-Z a-z 0-9 - . _ ~)
  becomes %XX, upper-case hex, so a space is %20 (never "+") and "São" is
  S%C3%A3o, the same on both compilers. For a query value or a path
  segment. It came from pascal-agenda-faa (ApiQueryEscape, its desktop
  client's query strings; "M7: design", decision 4), the same byte for byte
  as pascal-api-infra-faa's private McpUrlEncode, which is to call it.

  EPcTextEncoding and PcUtf8BytesToString (1.31.0) are the raising form, for
  a caller with no exception of its own: pascal-api-infra-faa's
  PaUtf8BytesToString and ETextEncodingException, moved here with the HTTP
  transport (docs/http-design.md, H7), whose answers raise it for a body
  that isn't UTF-8. The infra declares its class as an alias of this one, so
  its existing handlers still catch it. }

interface

uses
  SysUtils;

type
  /// Text that isn't UTF-8, or that FPC's code page can't hold (1.31.0).
  EPcTextEncoding = class(Exception);

/// The text in ABytes (UTF-8, with or without a BOM) in AText. False, with
/// AText empty, when ABytes isn't valid UTF-8 (PcIsValidUtf8; a UTF-16 file
/// is one case: FF FE and FE FF never occur in UTF-8), and on FPC when ABytes
/// has non-ASCII bytes and the process default code page isn't UTF-8 (the
/// conversion would replace characters with "?"). Never raises. Empty input
/// gives True and ''.
function PcTryUtf8BytesToString(const ABytes: TBytes; out AText: string): Boolean;

/// PcTryUtf8BytesToString that raises (1.31.0). AOrigin names where the
/// bytes came from, for the message ('the answer to GET https://h/p').
/// EPcTextEncoding when the bytes aren't UTF-8 (a UTF-16 byte order mark is
/// named), and on FPC when they are non-ASCII and the process code page isn't
/// UTF-8.
function PcUtf8BytesToString(const ABytes: TBytes; const AOrigin: string): string;

/// True when ABytes, after an optional UTF-8 BOM, is well-formed UTF-8
/// (1.25.0): RFC 3629 / Unicode table 3-7, so no stray continuation byte, no
/// overlong form, no surrogate (U+D800..U+DFFF), nothing above U+10FFFF and
/// no sequence cut at the end. Empty input is valid. The same answer on both
/// compilers, whatever the code page.
function PcIsValidUtf8(const ABytes: TBytes): Boolean;

/// AText as UTF-8 bytes, without a BOM (1.18.0). On FPC the conversion
/// follows the string's own code page: nothing to do when it is already
/// UTF-8, a real conversion from any other. Moved from pascal-api-infra-faa's
/// PaStringToUtf8Bytes (PascalApi.Text), the same body, for passwords given
/// to PcPbkdf2HmacSha256 and any other text that is hashed.
function PcStringToUtf8Bytes(const AText: string): TBytes;

/// AText percent-encoded as RFC 3986 says (1.26.0): its UTF-8 bytes, each
/// one outside the unreserved characters (A-Z a-z 0-9 - . _ ~) as %XX with
/// upper-case hex. 'a b&c' gives 'a%20b%26c', 'João' gives 'Jo%C3%A3o'.
/// For a query name or value, or a path segment ('/' is encoded too).
function PcPercentEncode(const AText: string): string;

implementation

function Utf8BomLength(const ABytes: TBytes): Integer;
begin
  if (Length(ABytes) >= 3) and (ABytes[0] = $EF) and (ABytes[1] = $BB) and (ABytes[2] = $BF) then
    Result := 3
  else
    Result := 0;
end;

// Table 3-7 of the Unicode standard: the lead byte fixes the length and the
// range of the second byte; every later byte is 80..BF.
function IsValidUtf8Range(const ABytes: TBytes; AStart: Integer): Boolean;
var
  I, LLen, LCount, K: Integer;
  B, LLo, LHi: Byte;
begin
  Result := False;
  LLen := Length(ABytes);
  I := AStart;
  while I < LLen do
  begin
    B := ABytes[I];
    if B < $80 then
    begin
      Inc(I);
      Continue;
    end;
    LLo := $80;
    LHi := $BF;
    case B of
      $C2..$DF: LCount := 1;
      $E0: begin LCount := 2; LLo := $A0; end;
      $E1..$EC, $EE..$EF: LCount := 2;
      $ED: begin LCount := 2; LHi := $9F; end;
      $F0: begin LCount := 3; LLo := $90; end;
      $F1..$F3: LCount := 3;
      $F4: begin LCount := 3; LHi := $8F; end;
    else
      Exit; // 80..C1 (continuation or overlong lead) and F5..FF
    end;
    if I + LCount >= LLen then
      Exit; // cut at the end
    B := ABytes[I + 1];
    if (B < LLo) or (B > LHi) then
      Exit;
    for K := 2 to LCount do
    begin
      B := ABytes[I + K];
      if (B < $80) or (B > $BF) then
        Exit;
    end;
    Inc(I, LCount + 1);
  end;
  Result := True;
end;

function PcIsValidUtf8(const ABytes: TBytes): Boolean;
begin
  Result := IsValidUtf8Range(ABytes, Utf8BomLength(ABytes));
end;

function PcTryUtf8BytesToString(const ABytes: TBytes; out AText: string): Boolean;
var
  LStart, LLen: Integer;
  {$IFDEF FPC}
  I: Integer;
  LUtf8: UTF8String;
  {$ENDIF}
begin
  AText := '';
  Result := True;
  LStart := Utf8BomLength(ABytes);
  LLen := Length(ABytes);
  if LLen - LStart <= 0 then
    Exit;
  if not IsValidUtf8Range(ABytes, LStart) then
    Exit(False);
  {$IFDEF FPC}
  if DefaultSystemCodePage <> CP_UTF8 then
    for I := LStart to LLen - 1 do
      if ABytes[I] >= $80 then
        Exit(False);
  LUtf8 := '';
  SetLength(LUtf8, LLen - LStart);
  Move(ABytes[LStart], LUtf8[1], LLen - LStart);
  AText := string(LUtf8);
  {$ELSE}
  // Validated above, so this shouldn't raise; the guard keeps the "Try"
  // promise if Windows ever disagrees with table 3-7.
  try
    AText := TEncoding.UTF8.GetString(ABytes, LStart, LLen - LStart);
  except
    on EEncodingError do
    begin
      AText := '';
      Result := False;
    end;
  end;
  {$ENDIF}
end;

function PcUtf8BytesToString(const ABytes: TBytes; const AOrigin: string): string;
begin
  if PcTryUtf8BytesToString(ABytes, Result) then
    Exit;
  if (Length(ABytes) >= 2) and (((ABytes[0] = $FF) and (ABytes[1] = $FE)) or
    ((ABytes[0] = $FE) and (ABytes[1] = $FF))) then
    raise EPcTextEncoding.CreateFmt(
      '%s is not UTF-8 (it starts with a UTF-16 byte order mark): save it as UTF-8', [AOrigin]);
  if not PcIsValidUtf8(ABytes) then
    raise EPcTextEncoding.CreateFmt(
      '%s is not UTF-8 (it has bytes that are not valid UTF-8): save it as UTF-8', [AOrigin]);
  raise EPcTextEncoding.CreateFmt(
    '%s contains non-ASCII characters, but the process default code page is %d, ' +
    'not UTF-8 (65001): FPC would silently turn characters outside that code page into "?". ' +
    'Call SetMultiByteConversionCodePage(CP_UTF8) at startup (LCL applications already run in UTF-8).',
    [AOrigin, DefaultSystemCodePage]);
end;

function PcStringToUtf8Bytes(const AText: string): TBytes;
{$IFDEF FPC}
var
  LUtf8: UTF8String;
{$ENDIF}
begin
  Result := nil;
  {$IFDEF FPC}
  LUtf8 := UTF8String(AText);
  SetLength(Result, Length(LUtf8));
  if Length(LUtf8) > 0 then
    Move(LUtf8[1], Result[0], Length(LUtf8));
  {$ELSE}
  Result := TEncoding.UTF8.GetBytes(AText);
  {$ENDIF}
end;

function PcPercentEncode(const AText: string): string;
const
  HEX = '0123456789ABCDEF';
var
  LBytes: TBytes;
  I, LLen: Integer;
  B: Byte;
begin
  Result := '';
  LBytes := PcStringToUtf8Bytes(AText);
  // At most three characters a byte, all ASCII: one allocation.
  SetLength(Result, Length(LBytes) * 3);
  LLen := 0;
  for I := 0 to High(LBytes) do
  begin
    B := LBytes[I];
    if ((B >= Ord('A')) and (B <= Ord('Z'))) or ((B >= Ord('a')) and (B <= Ord('z'))) or
      ((B >= Ord('0')) and (B <= Ord('9'))) or (B = Ord('-')) or (B = Ord('.')) or
      (B = Ord('_')) or (B = Ord('~')) then
    begin
      Inc(LLen);
      Result[LLen] := Char(B);
    end
    else
    begin
      Result[LLen + 1] := '%';
      Result[LLen + 2] := HEX[(B shr 4) + 1];
      Result[LLen + 3] := HEX[(B and $F) + 1];
      Inc(LLen, 3);
    end;
  end;
  SetLength(Result, LLen);
end;

end.
