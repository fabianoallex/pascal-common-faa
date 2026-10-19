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
  TOptionals.Upper/Lower, when the normalizer factories (now
  PascalCommon.Normalizers) needed the same code: one copy, so the FPC
  branch can't drift between the two. It is public because any consumer that changes the case of a name in a Linux
  container meets the same locale trap. This file is UTF-8 with a BOM, so
  Delphi reads the example above right.

  PcFoldForSearch (1.20.0) is a search key: lower case, the accents of the
  Latin letters removed, blanks trimmed and collapsed ("  São   Conceição"
  -> "sao conceicao"). Databases don't agree on this: SQLite's LOWER and
  LIKE fold ASCII only, PostgreSQL's depend on the collation. So an
  application stores the key next to the text and folds what the user types
  the same way, and both sides meet on every database. It came from
  pascal-agenda-faa (Agenda.Text, its services', professionals' and
  customers' search), moved at the user's choice. The accent table covers
  Latin-1 Supplement and Latin Extended-A (U+00C0-U+017F): Portuguese,
  Spanish, French, German, the Nordic and Central European languages. A
  letter outside it is only lower-cased; a ligature (ß, æ, œ) stays as is.
  The loop runs on UnicodeString: Length counts UTF-16 units on both
  compilers, where on FPC a string's Length counts bytes. }

interface

/// Uppercase, Unicode-aware and independent of the process locale:
/// 'são paulo' gives 'SÃO PAULO' on Delphi and on FPC, Windows or Linux.
function PcUpperCase(const AValue: string): string;

/// Lowercase, with the same rules as PcUpperCase.
function PcLowerCase(const AValue: string): string;

/// A search key: PcLowerCase, the accents of Latin letters removed, blanks
/// (space, tab, line breaks, no-break space) trimmed and each run made one
/// space. 'São  CONCEIÇÃO ' gives 'sao conceicao' on both compilers.
function PcFoldForSearch(const AValue: string): string;

/// The number of characters (Unicode code points) in AValue, the same on
/// both compilers (1.21.0): Length counts UTF-8 bytes on FPC and UTF-16 units
/// on Delphi, so "at most 100 characters" needs this. 'São' is 3, an emoji 1.
/// The length JSON Schema's minLength/maxLength mean.
function PcCharCount(const AValue: string): Integer;

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

// The base letter of an accented Latin letter (already lower case, but the
// upper-case code points map too); any other character as is.
function StripAccent(C: WideChar): WideChar;
begin
  case Ord(C) of
    $00C0..$00C5, $00E0..$00E5, $0100..$0105: Result := 'a';
    $00C7, $00E7, $0106..$010D: Result := 'c';
    $010E..$0111: Result := 'd';
    $00C8..$00CB, $00E8..$00EB, $0112..$011B: Result := 'e';
    $011C..$0123: Result := 'g';
    $0124..$0127: Result := 'h';
    $00CC..$00CF, $00EC..$00EF, $0128..$0131: Result := 'i';
    $0134, $0135: Result := 'j';
    $0136, $0137: Result := 'k';
    $0139..$0142: Result := 'l';
    $00D1, $00F1, $0143..$0148: Result := 'n';
    $00D2..$00D6, $00D8, $00F2..$00F6, $00F8, $014C..$0151: Result := 'o';
    $0154..$0159: Result := 'r';
    $015A..$0161: Result := 's';
    $0162..$0167: Result := 't';
    $00D9..$00DC, $00F9..$00FC, $0168..$0173: Result := 'u';
    $0174, $0175: Result := 'w';
    $00DD, $00FD, $00FF, $0176..$0178: Result := 'y';
    $0179..$017E: Result := 'z';
  else
    Result := C;
  end;
end;

function PcFoldForSearch(const AValue: string): string;
var
  LIn, LOut: UnicodeString;
  I, N: Integer;
  C: WideChar;
  LSpace: Boolean;
begin
  LIn := UnicodeString(PcLowerCase(AValue));
  LOut := '';
  SetLength(LOut, Length(LIn));
  N := 0;
  LSpace := False;
  for I := 1 to Length(LIn) do
  begin
    C := StripAccent(LIn[I]);
    case Ord(C) of
      $0009, $000A, $000D, $0020, $00A0:
        begin
          LSpace := N > 0;
          Continue;
        end;
    end;
    if LSpace then
    begin
      Inc(N);
      LOut[N] := ' ';
      LSpace := False;
    end;
    Inc(N);
    LOut[N] := C;
  end;
  SetLength(LOut, N);
  Result := string(LOut);
end;

function PcCharCount(const AValue: string): Integer;
var
  LText: UnicodeString;
  I: Integer;
begin
  // UTF-16 units, the second half of a surrogate pair not counted.
  LText := UnicodeString(AValue);
  Result := 0;
  for I := 1 to Length(LText) do
    if (Ord(LText[I]) < $DC00) or (Ord(LText[I]) > $DFFF) then
      Inc(Result);
end;

end.
