unit PascalCommon.TextTests;

{ Tests for PascalCommon.Text (1.13.0): PcUpperCase and PcLowerCase map
  accented letters on every platform. The Linux CI container runs without
  LANG (locale "C"), which is where a locale-dependent call such as
  AnsiUpperCase on FPC leaves 'ã' alone (gotcha 10), so a return to it fails
  there. This file is UTF-8 with a BOM, so Delphi reads the literals right.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalCommon.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalCommon.DUnitXCompat,
  PascalCommon.Text;

type
  [TestFixture]
  TTextTests = class
  public
    [Test]
    procedure UpperCase_MapsAccentedLetters;
    [Test]
    procedure LowerCase_MapsAccentedLetters;
    [Test]
    procedure Case_LeavesOtherCharactersAlone;
    [Test]
    procedure Fold_AsciiCase;
    [Test]
    procedure Fold_PortugueseAccents;
    [Test]
    procedure Fold_OtherLatinLetters;
    [Test]
    procedure Fold_Blanks;
    [Test]
    procedure Fold_KeepsWhatItDoesntKnow;
    [Test]
    procedure Fold_LowerCasesOtherScripts;
    [Test]
    procedure CharCount_CodePoints;
  end;

implementation

procedure TTextTests.UpperCase_MapsAccentedLetters;
begin
  TAssert.AssertEquals('SÃO PAULO ÇÃO Ñ Ü', PcUpperCase('são paulo ção ñ ü'));
end;

procedure TTextTests.LowerCase_MapsAccentedLetters;
begin
  TAssert.AssertEquals('são paulo ção ñ ü', PcLowerCase('SÃO PAULO ÇÃO Ñ Ü'));
end;

procedure TTextTests.Case_LeavesOtherCharactersAlone;
begin
  TAssert.AssertEquals('empty', '', PcUpperCase(''));
  TAssert.AssertEquals('digits and symbols', '89.010-000 @#', PcUpperCase('89.010-000 @#'));
  TAssert.AssertEquals('digits and symbols', '89.010-000 @#', PcLowerCase('89.010-000 @#'));
end;

procedure TTextTests.Fold_AsciiCase;
begin
  TAssert.AssertEquals('corte de cabelo', PcFoldForSearch('Corte DE Cabelo'));
end;

procedure TTextTests.Fold_PortugueseAccents;
begin
  TAssert.AssertEquals('sao conceicao', PcFoldForSearch('São Conceição'));
  TAssert.AssertEquals('aaaaa eee ii oooo uu c n', PcFoldForSearch('ÁÀÂÃÄ ÉÊË ÍÏ ÓÔÕÖ ÚÜ Ç Ñ'));
  TAssert.AssertEquals('aaaaa eee ii oooo uu c n', PcFoldForSearch('áàâãä éêë íï óôõö úü ç ñ'));
end;

procedure TTextTests.Fold_OtherLatinLetters;
begin
  TAssert.AssertEquals('lodz stastny orsted yves', PcFoldForSearch('Łódź Šťastný Ørsted Ÿves'));
end;

procedure TTextTests.Fold_Blanks;
begin
  TAssert.AssertEquals('a b c d', PcFoldForSearch('  a   b'#9'c'#13#10'd  '));
  TAssert.AssertEquals('no-break space', 'a b', PcFoldForSearch('a'#$00A0'b'));
  TAssert.AssertEquals('', PcFoldForSearch('   '));
  TAssert.AssertEquals('', PcFoldForSearch(''));
end;

procedure TTextTests.Fold_KeepsWhatItDoesntKnow;
begin
  TAssert.AssertEquals('cafe ☕ 東京 1-2/3 ß æ', PcFoldForSearch('café ☕ 東京 1-2/3 ß Æ'));
end;

procedure TTextTests.Fold_LowerCasesOtherScripts;
begin
  // Outside the accent table a letter is only lower-cased (PcLowerCase).
  TAssert.AssertEquals('ωμέγα москва', PcFoldForSearch('ΩΜΈΓΑ МОСКВА'));
end;

procedure TTextTests.CharCount_CodePoints;
begin
  TAssert.AssertEquals(0, PcCharCount(''));
  TAssert.AssertEquals(3, PcCharCount('abc'));
  TAssert.AssertEquals('accents: one character each', 3, PcCharCount('São'));
  TAssert.AssertEquals('an emoji is one character (a surrogate pair)', 3, PcCharCount('a😀b'));
  TAssert.AssertEquals(2, PcCharCount('東京'));
end;

initialization
  TDUnitX.RegisterTestFixture(TTextTests);
end.
