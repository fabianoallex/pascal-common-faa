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

initialization
  TDUnitX.RegisterTestFixture(TTextTests);
end.
