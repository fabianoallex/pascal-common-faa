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
  from "UTF-8 that this FPC code page can't hold" in its own message. }

interface

uses
  SysUtils;

/// The text in ABytes (UTF-8, with or without a BOM) in AText. False, with
/// AText empty, when ABytes isn't valid UTF-8 (PcIsValidUtf8; a UTF-16 file
/// is one case: FF FE and FE FF never occur in UTF-8), and on FPC when ABytes
/// has non-ASCII bytes and the process default code page isn't UTF-8 (the
/// conversion would replace characters with "?"). Never raises. Empty input
/// gives True and ''.
function PcTryUtf8BytesToString(const ABytes: TBytes; out AText: string): Boolean;

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

end.
