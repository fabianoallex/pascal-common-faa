unit PascalCommon.TextTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalCommon.TextTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

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
  fpcunit, testregistry,
  PascalCommon.Text;

type
  TTextTests = class(TTestCase)
  published
    procedure UpperCase_MapsAccentedLetters;
    procedure LowerCase_MapsAccentedLetters;
    procedure Case_LeavesOtherCharactersAlone;
    procedure Fold_AsciiCase;
    procedure Fold_PortugueseAccents;
    procedure Fold_OtherLatinLetters;
    procedure Fold_Blanks;
    procedure Fold_KeepsWhatItDoesntKnow;
    procedure Fold_LowerCasesOtherScripts;
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

initialization
  RegisterTest(TTextTests);
end.
