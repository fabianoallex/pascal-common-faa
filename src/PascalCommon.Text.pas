unit PascalCommon.Text;

{$I pascalcommon.inc}

{ Upper and lower case that map every Unicode letter on both compilers,
  whatever the process locale.

  On Delphi, AnsiUpperCase/AnsiLowerCase map every Unicode letter. On
  FPC/Unix they go through cwstring, which follows the process locale:
  measured on FPC 3.2.2/Linux in a container without LANG (locale "C"),
  AnsiUpperCase('são paulo') gave 'SãO PAULO', and with LANG=C.UTF-8 the same
  binary gave 'SÃO PAULO' (gotcha 10). So FPC uses the Character unit, whose
  tables come with the RTL and ignore the locale. The string goes through
  UnicodeString, which converts from and back to the string's own code page.
  Cost: Character's tables, about 240 KB in a Linux binary without smart
  linking, about 90 KB with -XX -CX (measured).

  It came out of PascalCommon.Optionals in 1.13.0, where it was private to
  TOptionals.Upper/Lower, when PascalCommon.Optionals.Normalizers needed the
  same code: one copy, so the FPC branch can't drift between the two. It is
  public because any consumer that changes the case of a name in a Linux
  container meets the same locale trap. This file is UTF-8 with a BOM, so
  Delphi reads the example above right. }

interface

/// Uppercase, Unicode-aware and independent of the process locale:
/// 'são paulo' gives 'SÃO PAULO' on Delphi and on FPC, Windows or Linux.
function PcUpperCase(const AValue: string): string;

/// Lowercase, with the same rules as PcUpperCase.
function PcLowerCase(const AValue: string): string;

implementation

uses
  {$IFDEF FPC}
  Character,
  {$ENDIF}
  SysUtils;

function PcUpperCase(const AValue: string): string;
begin
  {$IFDEF FPC}
  Result := string(Character.ToUpper(UnicodeString(AValue)));
  {$ELSE}
  Result := AnsiUpperCase(AValue);
  {$ENDIF}
end;

function PcLowerCase(const AValue: string): string;
begin
  {$IFDEF FPC}
  Result := string(Character.ToLower(UnicodeString(AValue)));
  {$ELSE}
  Result := AnsiLowerCase(AValue);
  {$ENDIF}
end;

end.
