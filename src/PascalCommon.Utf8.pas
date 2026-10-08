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
  function returns a Boolean and raises nothing. On Delphi, bytes that aren't
  valid UTF-8 still make TEncoding.UTF8 raise EEncodingError, as before. }

interface

uses
  SysUtils;

/// The text in ABytes (UTF-8, with or without a BOM) in AText. False, with
/// AText empty, only on FPC when ABytes has non-ASCII bytes and the process
/// default code page isn't UTF-8 (the conversion would replace characters
/// with "?"). Empty input gives True and ''.
function PcTryUtf8BytesToString(const ABytes: TBytes; out AText: string): Boolean;

implementation

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
  LStart := 0;
  LLen := Length(ABytes);
  if (LLen >= 3) and (ABytes[0] = $EF) and (ABytes[1] = $BB) and (ABytes[2] = $BF) then
    LStart := 3;
  if LLen - LStart <= 0 then
    Exit;
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
  AText := TEncoding.UTF8.GetString(ABytes, LStart, LLen - LStart);
  {$ENDIF}
end;

end.
