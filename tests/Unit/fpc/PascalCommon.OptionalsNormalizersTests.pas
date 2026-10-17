unit PascalCommon.OptionalsNormalizersTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalCommon.OptionalsNormalizersTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for the normalizers seen from the optionals: Normalize with the
  factories' normalizers, and the type names PascalCommon.Optionals still
  declares, which since 1.14.0 are aliases of PascalCommon.Normalizers.

  The uses clause lists PascalCommon.Normalizers before
  PascalCommon.Optionals, so an unqualified IPcStringNormalizer here
  resolves to the alias, as it does in code written for 1.12; the new names
  are written qualified. The alias checks are compile-time: assigning one to
  the other only builds if they are the same type.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalCommon.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py - edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  PascalCommon.Normalizers,
  PascalCommon.Optionals;

type
  TOptionalsNormalizersTests = class(TTestCase)
  published
    procedure Aliases_TypesAreTheSameTypes;
    procedure Normalize_KeepsTheState;
    procedure Normalize_RuleMadeOfAChain;
  end;

implementation

type
  TMaxLength = class(TInterfacedObject, IPcStringNormalizer)
  private
    FMax: Integer;
  public
    constructor Create(AMax: Integer);
    function Apply(const AValue: string): string;
  end;

constructor TMaxLength.Create(AMax: Integer);
begin
  inherited Create;
  FMax := AMax;
end;

function TMaxLength.Apply(const AValue: string): string;
begin
  Result := Copy(AValue, 1, FMax);
end;

{ A named function for FromFunc: FPC 3.2.2 has no anonymous functions. }

function OnlyDigits(const AValue: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AValue) do
    if (AValue[I] >= '0') and (AValue[I] <= '9') then
      Result := Result + AValue[I];
end;

function Twice(const AValue: Integer): Integer;
begin
  Result := AValue * 2;
end;

{ An application factory, as the README recommends. }

type
  TTestNorm = class(TPcStringNormalizers)
  public
    class function MaxLength(AMax: Integer): IPcStringNormalizer; static;
    class function Cep: IPcStringNormalizer; static;
  end;

class function TTestNorm.MaxLength(AMax: Integer): IPcStringNormalizer;
begin
  Result := TMaxLength.Create(AMax);
end;

class function TTestNorm.Cep: IPcStringNormalizer;
begin
  Result := Chain([Trim, FromFunc(OnlyDigits), MaxLength(8)]);
end;

{ TOptionalsNormalizersTests }

procedure TOptionalsNormalizersTests.Aliases_TypesAreTheSameTypes;
var
  LOldFunc: PascalCommon.Optionals.TPcStringFunc;
  LNewNorm: PascalCommon.Normalizers.IPcStringNormalizer;
  LOldNorm: PascalCommon.Optionals.IPcStringNormalizer;
  LOldIntFunc: PascalCommon.Optionals.TPcIntegerFunc;
  LOldIntNorm: PascalCommon.Optionals.IPcIntegerNormalizer;
  LValue: IOptString;
begin
  // Each assignment below builds only if the alias is the same type.
  LOldFunc := OnlyDigits;
  LNewNorm := PascalCommon.Normalizers.TPcStringNormalizers.FromFunc(LOldFunc);
  LOldNorm := LNewNorm;
  TAssert.AssertEquals('string', '123', LOldNorm.Apply('1a2b3'));
  LValue := TOptNullString.From('1-2-3');
  TAssert.AssertEquals('through Normalize', '123', LValue.Normalize(LOldNorm).Value);
  LOldIntFunc := Twice;
  LOldIntNorm := PascalCommon.Normalizers.TPcIntegerNormalizers.FromFunc(LOldIntFunc);
  TAssert.AssertEquals('integer', 6, LOldIntNorm.Apply(3));
end;

procedure TOptionalsNormalizersTests.Normalize_KeepsTheState;
var
  LUndefined, LValue: IOptString;
  LNull: INullString;
begin
  LUndefined := TOptNullString.Undefined;
  LNull := TOptNullString.Null;
  LValue := TOptNullString.From(' sp ');
  TAssert.AssertFalse('undefined', LUndefined.Normalize(TPcStringNormalizers.Trim).HasValue);
  TAssert.AssertTrue('null', LNull.Normalize(TPcStringNormalizers.Upper).IsNull);
  TAssert.AssertEquals('value', 'SP',
    LValue.Normalize(TPcStringNormalizers.Trim).Normalize(TPcStringNormalizers.Upper).Value);
end;

procedure TOptionalsNormalizersTests.Normalize_RuleMadeOfAChain;
var
  LZip: IOptNullString;
begin
  LZip := TOptNullString.From(' 89.010-000 ');
  LZip := LZip.Normalize(TTestNorm.Cep);
  TAssert.AssertEquals('89010000', LZip.Value);
  LZip := TOptNullString.Null;
  TAssert.AssertTrue('null kept', LZip.Normalize(TTestNorm.Cep).IsNull);
end;

initialization
  RegisterTest(TOptionalsNormalizersTests);
end.
