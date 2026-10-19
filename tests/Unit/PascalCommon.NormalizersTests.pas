unit PascalCommon.NormalizersTests;

{ Tests for PascalCommon.Normalizers (1.14.0; the factories came from
  PascalCommon.Optionals.Normalizers, 1.13.0): the string factory's
  normalizers (Trim, Upper, Lower), FromFunc, Chain, the pattern the README
  recommends (an application factory, TTestNorm below, that inherits
  TPcStringNormalizers and adds its own class functions), and FromFunc/Chain
  on the factory of every other type.

  This unit doesn't use PascalCommon.Optionals on purpose: it proves the
  normalizers build and work on plain values without it. The optionals side
  (Normalize, and the 1.13 unit names) is in
  PascalCommon.OptionalsNormalizersTests.

  The Factory_<Type> tests come from one template, as the factories do: a
  function that changes the value, one that keeps it, FromFunc, Chain in
  order, an empty Chain, and nil raising EArgumentException.

  Chain_FreesItsItems builds the chain in a separate function, because
  Delphi keeps an expression's temporaries until the routine ends; the
  counting normalizer reports its destruction through a pointer. The whole
  suite also runs under heaptrc / ReportMemoryLeaksOnShutdown, which catches
  a chain that keeps or loses a reference.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalCommon.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalCommon.DUnitXCompat,
  SysUtils,
  PascalCommon.Normalizers;

type
  [TestFixture]
  TNormalizersTests = class
  public
    [Test]
    procedure Builtins_Apply;
    [Test]
    procedure Builtins_AreSharedInstances;
    [Test]
    procedure FromFunc_AppliesTheFunction;
    [Test]
    procedure FromFunc_Nil_RaisesEArgumentException;
    [Test]
    procedure Chain_AppliesInOrder;
    [Test]
    procedure Chain_Empty_ReturnsTheValueUnchanged;
    [Test]
    procedure Chain_Nested;
    [Test]
    procedure Chain_NilItem_RaisesEArgumentException;
    [Test]
    procedure Chain_FreesItsItems;
    [Test]
    procedure Factory_InheritsTheLibraryNormalizers;
    [Test]
    procedure Factory_RuleMadeOfAChain;
    [Test]
    procedure Factory_Integer_FromFuncAndChain;
    [Test]
    procedure Factory_Int64_FromFuncAndChain;
    [Test]
    procedure Factory_Single_FromFuncAndChain;
    [Test]
    procedure Factory_Double_FromFuncAndChain;
    [Test]
    procedure Factory_Currency_FromFuncAndChain;
    [Test]
    procedure Factory_DateTime_FromFuncAndChain;
    [Test]
    procedure Factory_Boolean_FromFuncAndChain;
    [Test]
    procedure Factory_Guid_FromFuncAndChain;
  end;

implementation

{ A normalizer with a parameter, and one that counts its destruction. }

type
  TMaxLength = class(TInterfacedObject, IPcStringNormalizer)
  private
    FMax: Integer;
  public
    constructor Create(AMax: Integer);
    function Apply(const AValue: string): string;
  end;

  TCountingFree = class(TInterfacedObject, IPcStringNormalizer)
  private
    FFreed: PInteger;
  public
    constructor Create(AFreed: PInteger);
    destructor Destroy; override;
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

constructor TCountingFree.Create(AFreed: PInteger);
begin
  inherited Create;
  FFreed := AFreed;
end;

destructor TCountingFree.Destroy;
begin
  Inc(FFreed^);
  inherited Destroy;
end;

function TCountingFree.Apply(const AValue: string): string;
begin
  Result := AValue + '!';
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

{ The application factory the README describes: it inherits the library's
  normalizers and adds its own, so all of them are under TTestNorm. }

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

function ApplyNewChainWithCounting(AFreed: PInteger): string;
begin
  Result := TPcStringNormalizers.Chain([TCountingFree.Create(AFreed),
    TCountingFree.Create(AFreed)]).Apply('a');
end;

{ Functions for the other types' factories. }

const
  GUID_A: TGUID = '{0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F1}';
  GUID_B: TGUID = '{1A2B3C4D-5E6F-4A8B-9CAD-BECFD0E1F203}';

function SameInteger(const A, B: Integer): Boolean;
begin
  Result := A = B;
end;

function ChangeInteger(const AValue: Integer): Integer;
begin
  Result := AValue * 2;
end;

function KeepInteger(const AValue: Integer): Integer;
begin
  Result := AValue;
end;

function SameInt64(const A, B: Int64): Boolean;
begin
  Result := A = B;
end;

function ChangeInt64(const AValue: Int64): Int64;
begin
  Result := AValue * 2;
end;

function KeepInt64(const AValue: Int64): Int64;
begin
  Result := AValue;
end;

function SameSingle(const A, B: Single): Boolean;
begin
  Result := Abs(A - B) < 1e-6;
end;

function ChangeSingle(const AValue: Single): Single;
begin
  Result := AValue * 2;
end;

function KeepSingle(const AValue: Single): Single;
begin
  Result := AValue;
end;

function SameDouble(const A, B: Double): Boolean;
begin
  Result := Abs(A - B) < 1e-9;
end;

function ChangeDouble(const AValue: Double): Double;
begin
  Result := AValue * 2;
end;

function KeepDouble(const AValue: Double): Double;
begin
  Result := AValue;
end;

function SameCurrency(const A, B: Currency): Boolean;
begin
  Result := A = B;
end;

function ChangeCurrency(const AValue: Currency): Currency;
begin
  Result := AValue * 2;
end;

function KeepCurrency(const AValue: Currency): Currency;
begin
  Result := AValue;
end;

function SameDateTime(const A, B: TDateTime): Boolean;
begin
  Result := Abs(A - B) < 1e-9;
end;

function ChangeDateTime(const AValue: TDateTime): TDateTime;
begin
  Result := AValue + 1;
end;

function KeepDateTime(const AValue: TDateTime): TDateTime;
begin
  Result := AValue;
end;

function SameBoolean(const A, B: Boolean): Boolean;
begin
  Result := A = B;
end;

function ChangeBoolean(const AValue: Boolean): Boolean;
begin
  Result := not AValue;
end;

function KeepBoolean(const AValue: Boolean): Boolean;
begin
  Result := AValue;
end;

function SameGuid(const A, B: TGUID): Boolean;
begin
  Result := IsEqualGUID(A, B);
end;

function ChangeGuid(const AValue: TGUID): TGUID;
begin
  Result := GUID_B;
end;

function KeepGuid(const AValue: TGUID): TGUID;
begin
  Result := AValue;
end;

{ TNormalizersTests }

procedure TNormalizersTests.Builtins_Apply;
begin
  TAssert.AssertEquals('trim', 'a b', TPcStringNormalizers.Trim.Apply('  a b '));
  TAssert.AssertEquals('upper', 'SÃO PAULO', TPcStringNormalizers.Upper.Apply('são paulo'));
  TAssert.AssertEquals('lower', 'são paulo', TPcStringNormalizers.Lower.Apply('SÃO PAULO'));
  TAssert.AssertEquals('fold', 'sao paulo', TPcStringNormalizers.FoldForSearch.Apply(' SÃO  Paulo '));
end;

procedure TNormalizersTests.Builtins_AreSharedInstances;
begin
  TAssert.AssertTrue('trim', TPcStringNormalizers.Trim = TPcStringNormalizers.Trim);
  TAssert.AssertTrue('upper', TPcStringNormalizers.Upper = TPcStringNormalizers.Upper);
  TAssert.AssertTrue('lower', TPcStringNormalizers.Lower = TPcStringNormalizers.Lower);
  TAssert.AssertTrue('fold', TPcStringNormalizers.FoldForSearch = TPcStringNormalizers.FoldForSearch);
end;

procedure TNormalizersTests.FromFunc_AppliesTheFunction;
begin
  TAssert.AssertEquals('89010000', TPcStringNormalizers.FromFunc(OnlyDigits).Apply('89.010-000'));
end;

procedure TNormalizersTests.FromFunc_Nil_RaisesEArgumentException;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    TPcStringNormalizers.FromFunc(nil);
  except
    on E: EArgumentException do
      LRaised := True;
  end;
  TAssert.AssertTrue(LRaised);
end;

procedure TNormalizersTests.Chain_AppliesInOrder;
begin
  TAssert.AssertEquals('trim, then cut', 'abc',
    TPcStringNormalizers.Chain([TPcStringNormalizers.Trim, TTestNorm.MaxLength(3)]).Apply('  abcd'));
  TAssert.AssertEquals('cut, then trim', '',
    TPcStringNormalizers.Chain([TTestNorm.MaxLength(2), TPcStringNormalizers.Trim]).Apply('  abcd'));
end;

procedure TNormalizersTests.Chain_Empty_ReturnsTheValueUnchanged;
begin
  TAssert.AssertEquals(' a ', TPcStringNormalizers.Chain([]).Apply(' a '));
end;

procedure TNormalizersTests.Chain_Nested;
var
  LInner: IPcStringNormalizer;
begin
  LInner := TPcStringNormalizers.Chain([TPcStringNormalizers.Trim, TPcStringNormalizers.Upper]);
  TAssert.AssertEquals('SP', TPcStringNormalizers.Chain([LInner, TTestNorm.MaxLength(5)]).Apply(' sp '));
end;

procedure TNormalizersTests.Chain_NilItem_RaisesEArgumentException;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    TPcStringNormalizers.Chain([TPcStringNormalizers.Trim, nil]);
  except
    on E: EArgumentException do
      LRaised := True;
  end;
  TAssert.AssertTrue(LRaised);
end;

procedure TNormalizersTests.Chain_FreesItsItems;
var
  LFreed: Integer;
begin
  LFreed := 0;
  TAssert.AssertEquals('applied in order', 'a!!', ApplyNewChainWithCounting(@LFreed));
  TAssert.AssertEquals('both items freed with the chain', 2, LFreed);
end;

procedure TNormalizersTests.Factory_InheritsTheLibraryNormalizers;
begin
  TAssert.AssertTrue('the same shared instance', TTestNorm.Trim = TPcStringNormalizers.Trim);
  TAssert.AssertEquals('ABC', TTestNorm.Chain([TTestNorm.Upper, TTestNorm.MaxLength(3)]).Apply('abcd'));
end;

procedure TNormalizersTests.Factory_RuleMadeOfAChain;
begin
  TAssert.AssertEquals('89010000', TTestNorm.Cep.Apply(' 89.010-000 '));
  TAssert.AssertEquals('already clean', '89010000', TTestNorm.Cep.Apply('89010000'));
end;

procedure TNormalizersTests.Factory_Integer_FromFuncAndChain;
var
  LRaisedFunc, LRaisedChain: Boolean;
begin
  TAssert.AssertTrue('fromfunc', SameInteger(6, TPcIntegerNormalizers.FromFunc(ChangeInteger).Apply(3)));
  TAssert.AssertTrue('chain', SameInteger(6,
    TPcIntegerNormalizers.Chain([TPcIntegerNormalizers.FromFunc(KeepInteger), TPcIntegerNormalizers.FromFunc(ChangeInteger)]).Apply(3)));
  TAssert.AssertTrue('chain twice', SameInteger(12,
    TPcIntegerNormalizers.Chain([TPcIntegerNormalizers.FromFunc(ChangeInteger), TPcIntegerNormalizers.FromFunc(ChangeInteger)]).Apply(3)));
  TAssert.AssertTrue('empty chain', SameInteger(3, TPcIntegerNormalizers.Chain([]).Apply(3)));
  LRaisedFunc := False;
  try
    TPcIntegerNormalizers.FromFunc(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedChain := False;
  try
    TPcIntegerNormalizers.Chain([nil]);
  except
    on E: EArgumentException do
      LRaisedChain := True;
  end;
  TAssert.AssertTrue('fromfunc nil', LRaisedFunc);
  TAssert.AssertTrue('chain nil item', LRaisedChain);
end;

procedure TNormalizersTests.Factory_Int64_FromFuncAndChain;
var
  LRaisedFunc, LRaisedChain: Boolean;
begin
  TAssert.AssertTrue('fromfunc', SameInt64(10000000000, TPcInt64Normalizers.FromFunc(ChangeInt64).Apply(5000000000)));
  TAssert.AssertTrue('chain', SameInt64(10000000000,
    TPcInt64Normalizers.Chain([TPcInt64Normalizers.FromFunc(KeepInt64), TPcInt64Normalizers.FromFunc(ChangeInt64)]).Apply(5000000000)));
  TAssert.AssertTrue('chain twice', SameInt64(20000000000,
    TPcInt64Normalizers.Chain([TPcInt64Normalizers.FromFunc(ChangeInt64), TPcInt64Normalizers.FromFunc(ChangeInt64)]).Apply(5000000000)));
  TAssert.AssertTrue('empty chain', SameInt64(5000000000, TPcInt64Normalizers.Chain([]).Apply(5000000000)));
  LRaisedFunc := False;
  try
    TPcInt64Normalizers.FromFunc(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedChain := False;
  try
    TPcInt64Normalizers.Chain([nil]);
  except
    on E: EArgumentException do
      LRaisedChain := True;
  end;
  TAssert.AssertTrue('fromfunc nil', LRaisedFunc);
  TAssert.AssertTrue('chain nil item', LRaisedChain);
end;

procedure TNormalizersTests.Factory_Single_FromFuncAndChain;
var
  LRaisedFunc, LRaisedChain: Boolean;
begin
  TAssert.AssertTrue('fromfunc', SameSingle(3.0, TPcSingleNormalizers.FromFunc(ChangeSingle).Apply(1.5)));
  TAssert.AssertTrue('chain', SameSingle(3.0,
    TPcSingleNormalizers.Chain([TPcSingleNormalizers.FromFunc(KeepSingle), TPcSingleNormalizers.FromFunc(ChangeSingle)]).Apply(1.5)));
  TAssert.AssertTrue('chain twice', SameSingle(6.0,
    TPcSingleNormalizers.Chain([TPcSingleNormalizers.FromFunc(ChangeSingle), TPcSingleNormalizers.FromFunc(ChangeSingle)]).Apply(1.5)));
  TAssert.AssertTrue('empty chain', SameSingle(1.5, TPcSingleNormalizers.Chain([]).Apply(1.5)));
  LRaisedFunc := False;
  try
    TPcSingleNormalizers.FromFunc(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedChain := False;
  try
    TPcSingleNormalizers.Chain([nil]);
  except
    on E: EArgumentException do
      LRaisedChain := True;
  end;
  TAssert.AssertTrue('fromfunc nil', LRaisedFunc);
  TAssert.AssertTrue('chain nil item', LRaisedChain);
end;

procedure TNormalizersTests.Factory_Double_FromFuncAndChain;
var
  LRaisedFunc, LRaisedChain: Boolean;
begin
  TAssert.AssertTrue('fromfunc', SameDouble(2.5, TPcDoubleNormalizers.FromFunc(ChangeDouble).Apply(1.25)));
  TAssert.AssertTrue('chain', SameDouble(2.5,
    TPcDoubleNormalizers.Chain([TPcDoubleNormalizers.FromFunc(KeepDouble), TPcDoubleNormalizers.FromFunc(ChangeDouble)]).Apply(1.25)));
  TAssert.AssertTrue('chain twice', SameDouble(5.0,
    TPcDoubleNormalizers.Chain([TPcDoubleNormalizers.FromFunc(ChangeDouble), TPcDoubleNormalizers.FromFunc(ChangeDouble)]).Apply(1.25)));
  TAssert.AssertTrue('empty chain', SameDouble(1.25, TPcDoubleNormalizers.Chain([]).Apply(1.25)));
  LRaisedFunc := False;
  try
    TPcDoubleNormalizers.FromFunc(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedChain := False;
  try
    TPcDoubleNormalizers.Chain([nil]);
  except
    on E: EArgumentException do
      LRaisedChain := True;
  end;
  TAssert.AssertTrue('fromfunc nil', LRaisedFunc);
  TAssert.AssertTrue('chain nil item', LRaisedChain);
end;

procedure TNormalizersTests.Factory_Currency_FromFuncAndChain;
var
  LRaisedFunc, LRaisedChain: Boolean;
begin
  TAssert.AssertTrue('fromfunc', SameCurrency(2.5, TPcCurrencyNormalizers.FromFunc(ChangeCurrency).Apply(1.25)));
  TAssert.AssertTrue('chain', SameCurrency(2.5,
    TPcCurrencyNormalizers.Chain([TPcCurrencyNormalizers.FromFunc(KeepCurrency), TPcCurrencyNormalizers.FromFunc(ChangeCurrency)]).Apply(1.25)));
  TAssert.AssertTrue('chain twice', SameCurrency(5,
    TPcCurrencyNormalizers.Chain([TPcCurrencyNormalizers.FromFunc(ChangeCurrency), TPcCurrencyNormalizers.FromFunc(ChangeCurrency)]).Apply(1.25)));
  TAssert.AssertTrue('empty chain', SameCurrency(1.25, TPcCurrencyNormalizers.Chain([]).Apply(1.25)));
  LRaisedFunc := False;
  try
    TPcCurrencyNormalizers.FromFunc(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedChain := False;
  try
    TPcCurrencyNormalizers.Chain([nil]);
  except
    on E: EArgumentException do
      LRaisedChain := True;
  end;
  TAssert.AssertTrue('fromfunc nil', LRaisedFunc);
  TAssert.AssertTrue('chain nil item', LRaisedChain);
end;

procedure TNormalizersTests.Factory_DateTime_FromFuncAndChain;
var
  LRaisedFunc, LRaisedChain: Boolean;
begin
  TAssert.AssertTrue('fromfunc', SameDateTime(EncodeDate(2026, 10, 17), TPcDateTimeNormalizers.FromFunc(ChangeDateTime).Apply(EncodeDate(2026, 10, 16))));
  TAssert.AssertTrue('chain', SameDateTime(EncodeDate(2026, 10, 17),
    TPcDateTimeNormalizers.Chain([TPcDateTimeNormalizers.FromFunc(KeepDateTime), TPcDateTimeNormalizers.FromFunc(ChangeDateTime)]).Apply(EncodeDate(2026, 10, 16))));
  TAssert.AssertTrue('chain twice', SameDateTime(EncodeDate(2026, 10, 18),
    TPcDateTimeNormalizers.Chain([TPcDateTimeNormalizers.FromFunc(ChangeDateTime), TPcDateTimeNormalizers.FromFunc(ChangeDateTime)]).Apply(EncodeDate(2026, 10, 16))));
  TAssert.AssertTrue('empty chain', SameDateTime(EncodeDate(2026, 10, 16), TPcDateTimeNormalizers.Chain([]).Apply(EncodeDate(2026, 10, 16))));
  LRaisedFunc := False;
  try
    TPcDateTimeNormalizers.FromFunc(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedChain := False;
  try
    TPcDateTimeNormalizers.Chain([nil]);
  except
    on E: EArgumentException do
      LRaisedChain := True;
  end;
  TAssert.AssertTrue('fromfunc nil', LRaisedFunc);
  TAssert.AssertTrue('chain nil item', LRaisedChain);
end;

procedure TNormalizersTests.Factory_Boolean_FromFuncAndChain;
var
  LRaisedFunc, LRaisedChain: Boolean;
begin
  TAssert.AssertTrue('fromfunc', SameBoolean(False, TPcBooleanNormalizers.FromFunc(ChangeBoolean).Apply(True)));
  TAssert.AssertTrue('chain', SameBoolean(False,
    TPcBooleanNormalizers.Chain([TPcBooleanNormalizers.FromFunc(KeepBoolean), TPcBooleanNormalizers.FromFunc(ChangeBoolean)]).Apply(True)));
  TAssert.AssertTrue('chain twice', SameBoolean(True,
    TPcBooleanNormalizers.Chain([TPcBooleanNormalizers.FromFunc(ChangeBoolean), TPcBooleanNormalizers.FromFunc(ChangeBoolean)]).Apply(True)));
  TAssert.AssertTrue('empty chain', SameBoolean(True, TPcBooleanNormalizers.Chain([]).Apply(True)));
  LRaisedFunc := False;
  try
    TPcBooleanNormalizers.FromFunc(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedChain := False;
  try
    TPcBooleanNormalizers.Chain([nil]);
  except
    on E: EArgumentException do
      LRaisedChain := True;
  end;
  TAssert.AssertTrue('fromfunc nil', LRaisedFunc);
  TAssert.AssertTrue('chain nil item', LRaisedChain);
end;

procedure TNormalizersTests.Factory_Guid_FromFuncAndChain;
var
  LRaisedFunc, LRaisedChain: Boolean;
begin
  TAssert.AssertTrue('fromfunc', SameGuid(GUID_B, TPcGuidNormalizers.FromFunc(ChangeGuid).Apply(GUID_A)));
  TAssert.AssertTrue('chain', SameGuid(GUID_B,
    TPcGuidNormalizers.Chain([TPcGuidNormalizers.FromFunc(KeepGuid), TPcGuidNormalizers.FromFunc(ChangeGuid)]).Apply(GUID_A)));
  TAssert.AssertTrue('chain twice', SameGuid(GUID_B,
    TPcGuidNormalizers.Chain([TPcGuidNormalizers.FromFunc(ChangeGuid), TPcGuidNormalizers.FromFunc(ChangeGuid)]).Apply(GUID_A)));
  TAssert.AssertTrue('empty chain', SameGuid(GUID_A, TPcGuidNormalizers.Chain([]).Apply(GUID_A)));
  LRaisedFunc := False;
  try
    TPcGuidNormalizers.FromFunc(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedChain := False;
  try
    TPcGuidNormalizers.Chain([nil]);
  except
    on E: EArgumentException do
      LRaisedChain := True;
  end;
  TAssert.AssertTrue('fromfunc nil', LRaisedFunc);
  TAssert.AssertTrue('chain nil item', LRaisedChain);
end;

initialization
  TDUnitX.RegisterTestFixture(TNormalizersTests);
end.
