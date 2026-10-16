unit PascalCommon.OptionalsMapTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalCommon.OptionalsMapTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for Map and Normalize on the non-string optionals (Integer, Int64,
  Single, Double, Currency, TDateTime, Boolean, TGUID; 1.12.0), in the
  fluent form (X.Map(F), X.Normalize(N)) and in TOptionals: every flavor
  keeps its state (nil reads as in Safe, Undefined and Null pass through, the
  state a flavor can't express but its object can comes back unchanged), a
  present value is transformed, an unchanged value returns the same
  instance, and a nil function or normalizer raises EArgumentException.
  Single and Double also keep the source's DecimalPlaces.

  One test per type and form, written from the same template so the eight
  types are checked alike: each type has a function (Twice, Trunc, not...),
  a normalizer class with a parameter (TAdd<Type>) and a Same<Type>
  comparison, with a tolerance for the floating-point ones. Values are
  compared with Same<Type> and AssertTrue rather than AssertEquals, whose
  Integer/Int64/Currency overloads would be ambiguous for some literals.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalCommon.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  PascalCommon.Optionals;

type
  TOptionalMapTests = class(TTestCase)
  published
    procedure Map_Integer_KeepsStateAndTransforms;
    procedure Normalize_Integer_KeepsStateAndApplies;
    procedure Map_Int64_KeepsStateAndTransforms;
    procedure Normalize_Int64_KeepsStateAndApplies;
    procedure Map_Single_KeepsStateAndTransforms;
    procedure Normalize_Single_KeepsStateAndApplies;
    procedure Map_Double_KeepsStateAndTransforms;
    procedure Normalize_Double_KeepsStateAndApplies;
    procedure Map_Currency_KeepsStateAndTransforms;
    procedure Normalize_Currency_KeepsStateAndApplies;
    procedure Map_DateTime_KeepsStateAndTransforms;
    procedure Normalize_DateTime_KeepsStateAndApplies;
    procedure Map_Boolean_KeepsStateAndTransforms;
    procedure Normalize_Boolean_KeepsStateAndApplies;
    procedure Map_Guid_KeepsStateAndTransforms;
    procedure Normalize_Guid_KeepsStateAndApplies;
    procedure Map_FloatKeepsDecimalPlaces;
    procedure Map_Boolean_ReturnsSharedInstances;
  end;

implementation

const
  GUID_A: TGUID = '{0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F1}';
  GUID_B: TGUID = '{1A2B3C4D-5E6F-4A8B-9CAD-BECFD0E1F203}';
  GUID_C: TGUID = '{2B3C4D5E-6F70-4B9C-8DBE-CFD0E1F20314}';

{ Functions for Map: named, since FPC 3.2.2 has no anonymous functions. }

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
  Result := Trunc(AValue);
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

{ Normalizers: a class each, because they carry a parameter. }

type
  TAddInteger = class(TInterfacedObject, IPcIntegerNormalizer)
  private
    FStep: Integer;
  public
    constructor Create(const AStep: Integer);
    function Apply(const AValue: Integer): Integer;
  end;

  TAddInt64 = class(TInterfacedObject, IPcInt64Normalizer)
  private
    FStep: Int64;
  public
    constructor Create(const AStep: Int64);
    function Apply(const AValue: Int64): Int64;
  end;

  TAddSingle = class(TInterfacedObject, IPcSingleNormalizer)
  private
    FStep: Single;
  public
    constructor Create(const AStep: Single);
    function Apply(const AValue: Single): Single;
  end;

  TAddDouble = class(TInterfacedObject, IPcDoubleNormalizer)
  private
    FStep: Double;
  public
    constructor Create(const AStep: Double);
    function Apply(const AValue: Double): Double;
  end;

  TAddCurrency = class(TInterfacedObject, IPcCurrencyNormalizer)
  private
    FStep: Currency;
  public
    constructor Create(const AStep: Currency);
    function Apply(const AValue: Currency): Currency;
  end;

  TAddDateTime = class(TInterfacedObject, IPcDateTimeNormalizer)
  private
    FStep: Integer;
  public
    constructor Create(const AStep: Integer);
    function Apply(const AValue: TDateTime): TDateTime;
  end;

  TAddBoolean = class(TInterfacedObject, IPcBooleanNormalizer)
  private
    FStep: Boolean;
  public
    constructor Create(const AStep: Boolean);
    function Apply(const AValue: Boolean): Boolean;
  end;

  TAddGuid = class(TInterfacedObject, IPcGuidNormalizer)
  private
    FStep: TGUID;
  public
    constructor Create(const AStep: TGUID);
    function Apply(const AValue: TGUID): TGUID;
  end;

constructor TAddInteger.Create(const AStep: Integer);
begin
  inherited Create;
  FStep := AStep;
end;

function TAddInteger.Apply(const AValue: Integer): Integer;
begin
  Result := AValue + FStep;
end;

constructor TAddInt64.Create(const AStep: Int64);
begin
  inherited Create;
  FStep := AStep;
end;

function TAddInt64.Apply(const AValue: Int64): Int64;
begin
  Result := AValue + FStep;
end;

constructor TAddSingle.Create(const AStep: Single);
begin
  inherited Create;
  FStep := AStep;
end;

function TAddSingle.Apply(const AValue: Single): Single;
begin
  Result := AValue + FStep;
end;

constructor TAddDouble.Create(const AStep: Double);
begin
  inherited Create;
  FStep := AStep;
end;

function TAddDouble.Apply(const AValue: Double): Double;
begin
  Result := AValue + FStep;
end;

constructor TAddCurrency.Create(const AStep: Currency);
begin
  inherited Create;
  FStep := AStep;
end;

function TAddCurrency.Apply(const AValue: Currency): Currency;
begin
  Result := AValue + FStep;
end;

constructor TAddDateTime.Create(const AStep: Integer);
begin
  inherited Create;
  FStep := AStep;
end;

function TAddDateTime.Apply(const AValue: TDateTime): TDateTime;
begin
  Result := AValue + FStep;
end;

constructor TAddBoolean.Create(const AStep: Boolean);
begin
  inherited Create;
  FStep := AStep;
end;

function TAddBoolean.Apply(const AValue: Boolean): Boolean;
begin
  Result := AValue and FStep;
end;

constructor TAddGuid.Create(const AStep: TGUID);
begin
  inherited Create;
  FStep := AStep;
end;

function TAddGuid.Apply(const AValue: TGUID): TGUID;
begin
  Result := FStep;
end;

{ Inputs. Boolean's From returns an IOptNullBoolean, so it goes through as;
  the other From return the class. }

function OptIntegerOf(const AValue: Integer): IOptInteger;
begin
  Result := TOptNullInteger.From(AValue);
end;

function NullIntegerOf(const AValue: Integer): INullInteger;
begin
  Result := TOptNullInteger.From(AValue);
end;

function OptNullIntegerOf(const AValue: Integer): IOptNullInteger;
begin
  Result := TOptNullInteger.From(AValue);
end;

function OptInt64Of(const AValue: Int64): IOptInt64;
begin
  Result := TOptNullInt64.From(AValue);
end;

function NullInt64Of(const AValue: Int64): INullInt64;
begin
  Result := TOptNullInt64.From(AValue);
end;

function OptNullInt64Of(const AValue: Int64): IOptNullInt64;
begin
  Result := TOptNullInt64.From(AValue);
end;

function OptSingleOf(const AValue: Single): IOptSingle;
begin
  Result := TOptNullSingle.From(AValue);
end;

function NullSingleOf(const AValue: Single): INullSingle;
begin
  Result := TOptNullSingle.From(AValue);
end;

function OptNullSingleOf(const AValue: Single): IOptNullSingle;
begin
  Result := TOptNullSingle.From(AValue);
end;

function OptDoubleOf(const AValue: Double): IOptDouble;
begin
  Result := TOptNullDouble.From(AValue);
end;

function NullDoubleOf(const AValue: Double): INullDouble;
begin
  Result := TOptNullDouble.From(AValue);
end;

function OptNullDoubleOf(const AValue: Double): IOptNullDouble;
begin
  Result := TOptNullDouble.From(AValue);
end;

function OptCurrencyOf(const AValue: Currency): IOptCurrency;
begin
  Result := TOptNullCurrency.From(AValue);
end;

function NullCurrencyOf(const AValue: Currency): INullCurrency;
begin
  Result := TOptNullCurrency.From(AValue);
end;

function OptNullCurrencyOf(const AValue: Currency): IOptNullCurrency;
begin
  Result := TOptNullCurrency.From(AValue);
end;

function OptDateTimeOf(const AValue: TDateTime): IOptDateTime;
begin
  Result := TOptNullDateTime.From(AValue);
end;

function NullDateTimeOf(const AValue: TDateTime): INullDateTime;
begin
  Result := TOptNullDateTime.From(AValue);
end;

function OptNullDateTimeOf(const AValue: TDateTime): IOptNullDateTime;
begin
  Result := TOptNullDateTime.From(AValue);
end;

function OptBooleanOf(const AValue: Boolean): IOptBoolean;
begin
  Result := TOptNullBoolean.From(AValue) as IOptBoolean;
end;

function NullBooleanOf(const AValue: Boolean): INullBoolean;
begin
  Result := TOptNullBoolean.From(AValue) as INullBoolean;
end;

function OptNullBooleanOf(const AValue: Boolean): IOptNullBoolean;
begin
  Result := TOptNullBoolean.From(AValue) as IOptNullBoolean;
end;

function OptGuidOf(const AValue: TGUID): IOptGuid;
begin
  Result := TOptNullGuid.From(AValue);
end;

function NullGuidOf(const AValue: TGUID): INullGuid;
begin
  Result := TOptNullGuid.From(AValue);
end;

function OptNullGuidOf(const AValue: TGUID): IOptNullGuid;
begin
  Result := TOptNullGuid.From(AValue);
end;

{ TOptionalMapTests }

procedure TOptionalMapTests.Map_Integer_KeepsStateAndTransforms;
var
  LOpt: IOptInteger;
  LNull: INullInteger;
  LOptNull: IOptNullInteger;
begin
  // IOptInteger
  TAssert.AssertFalse('opt nil', TOptionals.Map(IOptInteger(nil), ChangeInteger).HasValue);
  LOpt := TOptNullInteger.Undefined;
  TAssert.AssertTrue('opt undefined', LOpt.Map(ChangeInteger) = LOpt);
  LOpt := TOptNullInteger.Null;
  TAssert.AssertTrue('opt hidden null', LOpt.Map(ChangeInteger) = LOpt);
  LOpt := OptIntegerOf(3);
  TAssert.AssertTrue('opt value', SameInteger(6, LOpt.Map(ChangeInteger).Value));
  TAssert.AssertTrue('opt static', SameInteger(6, TOptionals.Map(LOpt, ChangeInteger).Value));
  TAssert.AssertTrue('opt unchanged', LOpt.Map(KeepInteger) = LOpt);
  // INullInteger
  TAssert.AssertTrue('null nil', TOptionals.Map(INullInteger(nil), ChangeInteger).IsNull);
  LNull := TOptNullInteger.Null;
  TAssert.AssertTrue('null null', LNull.Map(ChangeInteger) = LNull);
  LNull := TOptNullInteger.Undefined;
  TAssert.AssertTrue('null hidden undefined', LNull.Map(ChangeInteger) = LNull);
  LNull := NullIntegerOf(3);
  TAssert.AssertTrue('null value', SameInteger(6, LNull.Map(ChangeInteger).Value));
  TAssert.AssertTrue('null unchanged', LNull.Map(KeepInteger) = LNull);
  // IOptNullInteger
  TAssert.AssertFalse('optnull nil', TOptionals.Map(IOptNullInteger(nil), ChangeInteger).HasValue);
  LOptNull := TOptNullInteger.Undefined;
  TAssert.AssertTrue('optnull undefined', LOptNull.Map(ChangeInteger) = LOptNull);
  LOptNull := TOptNullInteger.Null;
  TAssert.AssertTrue('optnull null', LOptNull.Map(ChangeInteger) = LOptNull);
  LOptNull := OptNullIntegerOf(3);
  LOptNull := LOptNull.Map(ChangeInteger);
  TAssert.AssertTrue('optnull value', LOptNull.HasValue and not LOptNull.IsNull);
  TAssert.AssertTrue('optnull value', SameInteger(6, LOptNull.Value));
  TAssert.AssertTrue('optnull unchanged', LOptNull.Map(KeepInteger) = LOptNull);
end;

procedure TOptionalMapTests.Normalize_Integer_KeepsStateAndApplies;
var
  LOpt: IOptInteger;
  LNull: INullInteger;
  LOptNull: IOptNullInteger;
  LRaisedFunc, LRaisedNormalizer: Boolean;
begin
  LOpt := OptIntegerOf(3);
  TAssert.AssertTrue('opt', SameInteger(13, LOpt.Normalize(TAddInteger.Create(10)).Value));
  TAssert.AssertTrue('opt static', SameInteger(13, TOptionals.Normalize(LOpt, TAddInteger.Create(10)).Value));
  LNull := NullIntegerOf(3);
  TAssert.AssertTrue('null', SameInteger(13, LNull.Normalize(TAddInteger.Create(10)).Value));
  LOptNull := OptNullIntegerOf(3);
  TAssert.AssertTrue('optnull', SameInteger(13, LOptNull.Normalize(TAddInteger.Create(10)).Value));
  LOpt := TOptNullInteger.Undefined;
  TAssert.AssertTrue('undefined kept', LOpt.Normalize(TAddInteger.Create(10)) = LOpt);
  LNull := TOptNullInteger.Null;
  TAssert.AssertTrue('null kept', LNull.Normalize(TAddInteger.Create(10)) = LNull);
  LOptNull := TOptNullInteger.Undefined;
  TAssert.AssertTrue('nil reads as Safe', TOptionals.Normalize(IOptNullInteger(nil), TAddInteger.Create(10)) = LOptNull);

  LRaisedFunc := False;
  try
    LOpt.Map(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedNormalizer := False;
  try
    TOptionals.Normalize(LNull, IPcIntegerNormalizer(nil));
  except
    on E: EArgumentException do
      LRaisedNormalizer := True;
  end;
  TAssert.AssertTrue('nil function, even with no value', LRaisedFunc);
  TAssert.AssertTrue('nil normalizer, even with no value', LRaisedNormalizer);
end;

procedure TOptionalMapTests.Map_Int64_KeepsStateAndTransforms;
var
  LOpt: IOptInt64;
  LNull: INullInt64;
  LOptNull: IOptNullInt64;
begin
  // IOptInt64
  TAssert.AssertFalse('opt nil', TOptionals.Map(IOptInt64(nil), ChangeInt64).HasValue);
  LOpt := TOptNullInt64.Undefined;
  TAssert.AssertTrue('opt undefined', LOpt.Map(ChangeInt64) = LOpt);
  LOpt := TOptNullInt64.Null;
  TAssert.AssertTrue('opt hidden null', LOpt.Map(ChangeInt64) = LOpt);
  LOpt := OptInt64Of(5000000000);
  TAssert.AssertTrue('opt value', SameInt64(10000000000, LOpt.Map(ChangeInt64).Value));
  TAssert.AssertTrue('opt static', SameInt64(10000000000, TOptionals.Map(LOpt, ChangeInt64).Value));
  TAssert.AssertTrue('opt unchanged', LOpt.Map(KeepInt64) = LOpt);
  // INullInt64
  TAssert.AssertTrue('null nil', TOptionals.Map(INullInt64(nil), ChangeInt64).IsNull);
  LNull := TOptNullInt64.Null;
  TAssert.AssertTrue('null null', LNull.Map(ChangeInt64) = LNull);
  LNull := TOptNullInt64.Undefined;
  TAssert.AssertTrue('null hidden undefined', LNull.Map(ChangeInt64) = LNull);
  LNull := NullInt64Of(5000000000);
  TAssert.AssertTrue('null value', SameInt64(10000000000, LNull.Map(ChangeInt64).Value));
  TAssert.AssertTrue('null unchanged', LNull.Map(KeepInt64) = LNull);
  // IOptNullInt64
  TAssert.AssertFalse('optnull nil', TOptionals.Map(IOptNullInt64(nil), ChangeInt64).HasValue);
  LOptNull := TOptNullInt64.Undefined;
  TAssert.AssertTrue('optnull undefined', LOptNull.Map(ChangeInt64) = LOptNull);
  LOptNull := TOptNullInt64.Null;
  TAssert.AssertTrue('optnull null', LOptNull.Map(ChangeInt64) = LOptNull);
  LOptNull := OptNullInt64Of(5000000000);
  LOptNull := LOptNull.Map(ChangeInt64);
  TAssert.AssertTrue('optnull value', LOptNull.HasValue and not LOptNull.IsNull);
  TAssert.AssertTrue('optnull value', SameInt64(10000000000, LOptNull.Value));
  TAssert.AssertTrue('optnull unchanged', LOptNull.Map(KeepInt64) = LOptNull);
end;

procedure TOptionalMapTests.Normalize_Int64_KeepsStateAndApplies;
var
  LOpt: IOptInt64;
  LNull: INullInt64;
  LOptNull: IOptNullInt64;
  LRaisedFunc, LRaisedNormalizer: Boolean;
begin
  LOpt := OptInt64Of(5000000000);
  TAssert.AssertTrue('opt', SameInt64(5000000010, LOpt.Normalize(TAddInt64.Create(10)).Value));
  TAssert.AssertTrue('opt static', SameInt64(5000000010, TOptionals.Normalize(LOpt, TAddInt64.Create(10)).Value));
  LNull := NullInt64Of(5000000000);
  TAssert.AssertTrue('null', SameInt64(5000000010, LNull.Normalize(TAddInt64.Create(10)).Value));
  LOptNull := OptNullInt64Of(5000000000);
  TAssert.AssertTrue('optnull', SameInt64(5000000010, LOptNull.Normalize(TAddInt64.Create(10)).Value));
  LOpt := TOptNullInt64.Undefined;
  TAssert.AssertTrue('undefined kept', LOpt.Normalize(TAddInt64.Create(10)) = LOpt);
  LNull := TOptNullInt64.Null;
  TAssert.AssertTrue('null kept', LNull.Normalize(TAddInt64.Create(10)) = LNull);
  LOptNull := TOptNullInt64.Undefined;
  TAssert.AssertTrue('nil reads as Safe', TOptionals.Normalize(IOptNullInt64(nil), TAddInt64.Create(10)) = LOptNull);

  LRaisedFunc := False;
  try
    LOpt.Map(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedNormalizer := False;
  try
    TOptionals.Normalize(LNull, IPcInt64Normalizer(nil));
  except
    on E: EArgumentException do
      LRaisedNormalizer := True;
  end;
  TAssert.AssertTrue('nil function, even with no value', LRaisedFunc);
  TAssert.AssertTrue('nil normalizer, even with no value', LRaisedNormalizer);
end;

procedure TOptionalMapTests.Map_Single_KeepsStateAndTransforms;
var
  LOpt: IOptSingle;
  LNull: INullSingle;
  LOptNull: IOptNullSingle;
begin
  // IOptSingle
  TAssert.AssertFalse('opt nil', TOptionals.Map(IOptSingle(nil), ChangeSingle).HasValue);
  LOpt := TOptNullSingle.Undefined;
  TAssert.AssertTrue('opt undefined', LOpt.Map(ChangeSingle) = LOpt);
  LOpt := TOptNullSingle.Null;
  TAssert.AssertTrue('opt hidden null', LOpt.Map(ChangeSingle) = LOpt);
  LOpt := OptSingleOf(1.5);
  TAssert.AssertTrue('opt value', SameSingle(3.0, LOpt.Map(ChangeSingle).Value));
  TAssert.AssertTrue('opt static', SameSingle(3.0, TOptionals.Map(LOpt, ChangeSingle).Value));
  TAssert.AssertTrue('opt unchanged', LOpt.Map(KeepSingle) = LOpt);
  // INullSingle
  TAssert.AssertTrue('null nil', TOptionals.Map(INullSingle(nil), ChangeSingle).IsNull);
  LNull := TOptNullSingle.Null;
  TAssert.AssertTrue('null null', LNull.Map(ChangeSingle) = LNull);
  LNull := TOptNullSingle.Undefined;
  TAssert.AssertTrue('null hidden undefined', LNull.Map(ChangeSingle) = LNull);
  LNull := NullSingleOf(1.5);
  TAssert.AssertTrue('null value', SameSingle(3.0, LNull.Map(ChangeSingle).Value));
  TAssert.AssertTrue('null unchanged', LNull.Map(KeepSingle) = LNull);
  // IOptNullSingle
  TAssert.AssertFalse('optnull nil', TOptionals.Map(IOptNullSingle(nil), ChangeSingle).HasValue);
  LOptNull := TOptNullSingle.Undefined;
  TAssert.AssertTrue('optnull undefined', LOptNull.Map(ChangeSingle) = LOptNull);
  LOptNull := TOptNullSingle.Null;
  TAssert.AssertTrue('optnull null', LOptNull.Map(ChangeSingle) = LOptNull);
  LOptNull := OptNullSingleOf(1.5);
  LOptNull := LOptNull.Map(ChangeSingle);
  TAssert.AssertTrue('optnull value', LOptNull.HasValue and not LOptNull.IsNull);
  TAssert.AssertTrue('optnull value', SameSingle(3.0, LOptNull.Value));
  TAssert.AssertTrue('optnull unchanged', LOptNull.Map(KeepSingle) = LOptNull);
end;

procedure TOptionalMapTests.Normalize_Single_KeepsStateAndApplies;
var
  LOpt: IOptSingle;
  LNull: INullSingle;
  LOptNull: IOptNullSingle;
  LRaisedFunc, LRaisedNormalizer: Boolean;
begin
  LOpt := OptSingleOf(1.5);
  TAssert.AssertTrue('opt', SameSingle(11.5, LOpt.Normalize(TAddSingle.Create(10)).Value));
  TAssert.AssertTrue('opt static', SameSingle(11.5, TOptionals.Normalize(LOpt, TAddSingle.Create(10)).Value));
  LNull := NullSingleOf(1.5);
  TAssert.AssertTrue('null', SameSingle(11.5, LNull.Normalize(TAddSingle.Create(10)).Value));
  LOptNull := OptNullSingleOf(1.5);
  TAssert.AssertTrue('optnull', SameSingle(11.5, LOptNull.Normalize(TAddSingle.Create(10)).Value));
  LOpt := TOptNullSingle.Undefined;
  TAssert.AssertTrue('undefined kept', LOpt.Normalize(TAddSingle.Create(10)) = LOpt);
  LNull := TOptNullSingle.Null;
  TAssert.AssertTrue('null kept', LNull.Normalize(TAddSingle.Create(10)) = LNull);
  LOptNull := TOptNullSingle.Undefined;
  TAssert.AssertTrue('nil reads as Safe', TOptionals.Normalize(IOptNullSingle(nil), TAddSingle.Create(10)) = LOptNull);

  LRaisedFunc := False;
  try
    LOpt.Map(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedNormalizer := False;
  try
    TOptionals.Normalize(LNull, IPcSingleNormalizer(nil));
  except
    on E: EArgumentException do
      LRaisedNormalizer := True;
  end;
  TAssert.AssertTrue('nil function, even with no value', LRaisedFunc);
  TAssert.AssertTrue('nil normalizer, even with no value', LRaisedNormalizer);
end;

procedure TOptionalMapTests.Map_Double_KeepsStateAndTransforms;
var
  LOpt: IOptDouble;
  LNull: INullDouble;
  LOptNull: IOptNullDouble;
begin
  // IOptDouble
  TAssert.AssertFalse('opt nil', TOptionals.Map(IOptDouble(nil), ChangeDouble).HasValue);
  LOpt := TOptNullDouble.Undefined;
  TAssert.AssertTrue('opt undefined', LOpt.Map(ChangeDouble) = LOpt);
  LOpt := TOptNullDouble.Null;
  TAssert.AssertTrue('opt hidden null', LOpt.Map(ChangeDouble) = LOpt);
  LOpt := OptDoubleOf(1.25);
  TAssert.AssertTrue('opt value', SameDouble(2.5, LOpt.Map(ChangeDouble).Value));
  TAssert.AssertTrue('opt static', SameDouble(2.5, TOptionals.Map(LOpt, ChangeDouble).Value));
  TAssert.AssertTrue('opt unchanged', LOpt.Map(KeepDouble) = LOpt);
  // INullDouble
  TAssert.AssertTrue('null nil', TOptionals.Map(INullDouble(nil), ChangeDouble).IsNull);
  LNull := TOptNullDouble.Null;
  TAssert.AssertTrue('null null', LNull.Map(ChangeDouble) = LNull);
  LNull := TOptNullDouble.Undefined;
  TAssert.AssertTrue('null hidden undefined', LNull.Map(ChangeDouble) = LNull);
  LNull := NullDoubleOf(1.25);
  TAssert.AssertTrue('null value', SameDouble(2.5, LNull.Map(ChangeDouble).Value));
  TAssert.AssertTrue('null unchanged', LNull.Map(KeepDouble) = LNull);
  // IOptNullDouble
  TAssert.AssertFalse('optnull nil', TOptionals.Map(IOptNullDouble(nil), ChangeDouble).HasValue);
  LOptNull := TOptNullDouble.Undefined;
  TAssert.AssertTrue('optnull undefined', LOptNull.Map(ChangeDouble) = LOptNull);
  LOptNull := TOptNullDouble.Null;
  TAssert.AssertTrue('optnull null', LOptNull.Map(ChangeDouble) = LOptNull);
  LOptNull := OptNullDoubleOf(1.25);
  LOptNull := LOptNull.Map(ChangeDouble);
  TAssert.AssertTrue('optnull value', LOptNull.HasValue and not LOptNull.IsNull);
  TAssert.AssertTrue('optnull value', SameDouble(2.5, LOptNull.Value));
  TAssert.AssertTrue('optnull unchanged', LOptNull.Map(KeepDouble) = LOptNull);
end;

procedure TOptionalMapTests.Normalize_Double_KeepsStateAndApplies;
var
  LOpt: IOptDouble;
  LNull: INullDouble;
  LOptNull: IOptNullDouble;
  LRaisedFunc, LRaisedNormalizer: Boolean;
begin
  LOpt := OptDoubleOf(1.25);
  TAssert.AssertTrue('opt', SameDouble(11.25, LOpt.Normalize(TAddDouble.Create(10)).Value));
  TAssert.AssertTrue('opt static', SameDouble(11.25, TOptionals.Normalize(LOpt, TAddDouble.Create(10)).Value));
  LNull := NullDoubleOf(1.25);
  TAssert.AssertTrue('null', SameDouble(11.25, LNull.Normalize(TAddDouble.Create(10)).Value));
  LOptNull := OptNullDoubleOf(1.25);
  TAssert.AssertTrue('optnull', SameDouble(11.25, LOptNull.Normalize(TAddDouble.Create(10)).Value));
  LOpt := TOptNullDouble.Undefined;
  TAssert.AssertTrue('undefined kept', LOpt.Normalize(TAddDouble.Create(10)) = LOpt);
  LNull := TOptNullDouble.Null;
  TAssert.AssertTrue('null kept', LNull.Normalize(TAddDouble.Create(10)) = LNull);
  LOptNull := TOptNullDouble.Undefined;
  TAssert.AssertTrue('nil reads as Safe', TOptionals.Normalize(IOptNullDouble(nil), TAddDouble.Create(10)) = LOptNull);

  LRaisedFunc := False;
  try
    LOpt.Map(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedNormalizer := False;
  try
    TOptionals.Normalize(LNull, IPcDoubleNormalizer(nil));
  except
    on E: EArgumentException do
      LRaisedNormalizer := True;
  end;
  TAssert.AssertTrue('nil function, even with no value', LRaisedFunc);
  TAssert.AssertTrue('nil normalizer, even with no value', LRaisedNormalizer);
end;

procedure TOptionalMapTests.Map_Currency_KeepsStateAndTransforms;
var
  LOpt: IOptCurrency;
  LNull: INullCurrency;
  LOptNull: IOptNullCurrency;
begin
  // IOptCurrency
  TAssert.AssertFalse('opt nil', TOptionals.Map(IOptCurrency(nil), ChangeCurrency).HasValue);
  LOpt := TOptNullCurrency.Undefined;
  TAssert.AssertTrue('opt undefined', LOpt.Map(ChangeCurrency) = LOpt);
  LOpt := TOptNullCurrency.Null;
  TAssert.AssertTrue('opt hidden null', LOpt.Map(ChangeCurrency) = LOpt);
  LOpt := OptCurrencyOf(1.25);
  TAssert.AssertTrue('opt value', SameCurrency(2.5, LOpt.Map(ChangeCurrency).Value));
  TAssert.AssertTrue('opt static', SameCurrency(2.5, TOptionals.Map(LOpt, ChangeCurrency).Value));
  TAssert.AssertTrue('opt unchanged', LOpt.Map(KeepCurrency) = LOpt);
  // INullCurrency
  TAssert.AssertTrue('null nil', TOptionals.Map(INullCurrency(nil), ChangeCurrency).IsNull);
  LNull := TOptNullCurrency.Null;
  TAssert.AssertTrue('null null', LNull.Map(ChangeCurrency) = LNull);
  LNull := TOptNullCurrency.Undefined;
  TAssert.AssertTrue('null hidden undefined', LNull.Map(ChangeCurrency) = LNull);
  LNull := NullCurrencyOf(1.25);
  TAssert.AssertTrue('null value', SameCurrency(2.5, LNull.Map(ChangeCurrency).Value));
  TAssert.AssertTrue('null unchanged', LNull.Map(KeepCurrency) = LNull);
  // IOptNullCurrency
  TAssert.AssertFalse('optnull nil', TOptionals.Map(IOptNullCurrency(nil), ChangeCurrency).HasValue);
  LOptNull := TOptNullCurrency.Undefined;
  TAssert.AssertTrue('optnull undefined', LOptNull.Map(ChangeCurrency) = LOptNull);
  LOptNull := TOptNullCurrency.Null;
  TAssert.AssertTrue('optnull null', LOptNull.Map(ChangeCurrency) = LOptNull);
  LOptNull := OptNullCurrencyOf(1.25);
  LOptNull := LOptNull.Map(ChangeCurrency);
  TAssert.AssertTrue('optnull value', LOptNull.HasValue and not LOptNull.IsNull);
  TAssert.AssertTrue('optnull value', SameCurrency(2.5, LOptNull.Value));
  TAssert.AssertTrue('optnull unchanged', LOptNull.Map(KeepCurrency) = LOptNull);
end;

procedure TOptionalMapTests.Normalize_Currency_KeepsStateAndApplies;
var
  LOpt: IOptCurrency;
  LNull: INullCurrency;
  LOptNull: IOptNullCurrency;
  LRaisedFunc, LRaisedNormalizer: Boolean;
begin
  LOpt := OptCurrencyOf(1.25);
  TAssert.AssertTrue('opt', SameCurrency(11.25, LOpt.Normalize(TAddCurrency.Create(10)).Value));
  TAssert.AssertTrue('opt static', SameCurrency(11.25, TOptionals.Normalize(LOpt, TAddCurrency.Create(10)).Value));
  LNull := NullCurrencyOf(1.25);
  TAssert.AssertTrue('null', SameCurrency(11.25, LNull.Normalize(TAddCurrency.Create(10)).Value));
  LOptNull := OptNullCurrencyOf(1.25);
  TAssert.AssertTrue('optnull', SameCurrency(11.25, LOptNull.Normalize(TAddCurrency.Create(10)).Value));
  LOpt := TOptNullCurrency.Undefined;
  TAssert.AssertTrue('undefined kept', LOpt.Normalize(TAddCurrency.Create(10)) = LOpt);
  LNull := TOptNullCurrency.Null;
  TAssert.AssertTrue('null kept', LNull.Normalize(TAddCurrency.Create(10)) = LNull);
  LOptNull := TOptNullCurrency.Undefined;
  TAssert.AssertTrue('nil reads as Safe', TOptionals.Normalize(IOptNullCurrency(nil), TAddCurrency.Create(10)) = LOptNull);

  LRaisedFunc := False;
  try
    LOpt.Map(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedNormalizer := False;
  try
    TOptionals.Normalize(LNull, IPcCurrencyNormalizer(nil));
  except
    on E: EArgumentException do
      LRaisedNormalizer := True;
  end;
  TAssert.AssertTrue('nil function, even with no value', LRaisedFunc);
  TAssert.AssertTrue('nil normalizer, even with no value', LRaisedNormalizer);
end;

procedure TOptionalMapTests.Map_DateTime_KeepsStateAndTransforms;
var
  LOpt: IOptDateTime;
  LNull: INullDateTime;
  LOptNull: IOptNullDateTime;
begin
  // IOptDateTime
  TAssert.AssertFalse('opt nil', TOptionals.Map(IOptDateTime(nil), ChangeDateTime).HasValue);
  LOpt := TOptNullDateTime.Undefined;
  TAssert.AssertTrue('opt undefined', LOpt.Map(ChangeDateTime) = LOpt);
  LOpt := TOptNullDateTime.Null;
  TAssert.AssertTrue('opt hidden null', LOpt.Map(ChangeDateTime) = LOpt);
  LOpt := OptDateTimeOf(EncodeDate(2026, 10, 16) + 0.5);
  TAssert.AssertTrue('opt value', SameDateTime(EncodeDate(2026, 10, 16), LOpt.Map(ChangeDateTime).Value));
  TAssert.AssertTrue('opt static', SameDateTime(EncodeDate(2026, 10, 16), TOptionals.Map(LOpt, ChangeDateTime).Value));
  TAssert.AssertTrue('opt unchanged', LOpt.Map(KeepDateTime) = LOpt);
  // INullDateTime
  TAssert.AssertTrue('null nil', TOptionals.Map(INullDateTime(nil), ChangeDateTime).IsNull);
  LNull := TOptNullDateTime.Null;
  TAssert.AssertTrue('null null', LNull.Map(ChangeDateTime) = LNull);
  LNull := TOptNullDateTime.Undefined;
  TAssert.AssertTrue('null hidden undefined', LNull.Map(ChangeDateTime) = LNull);
  LNull := NullDateTimeOf(EncodeDate(2026, 10, 16) + 0.5);
  TAssert.AssertTrue('null value', SameDateTime(EncodeDate(2026, 10, 16), LNull.Map(ChangeDateTime).Value));
  TAssert.AssertTrue('null unchanged', LNull.Map(KeepDateTime) = LNull);
  // IOptNullDateTime
  TAssert.AssertFalse('optnull nil', TOptionals.Map(IOptNullDateTime(nil), ChangeDateTime).HasValue);
  LOptNull := TOptNullDateTime.Undefined;
  TAssert.AssertTrue('optnull undefined', LOptNull.Map(ChangeDateTime) = LOptNull);
  LOptNull := TOptNullDateTime.Null;
  TAssert.AssertTrue('optnull null', LOptNull.Map(ChangeDateTime) = LOptNull);
  LOptNull := OptNullDateTimeOf(EncodeDate(2026, 10, 16) + 0.5);
  LOptNull := LOptNull.Map(ChangeDateTime);
  TAssert.AssertTrue('optnull value', LOptNull.HasValue and not LOptNull.IsNull);
  TAssert.AssertTrue('optnull value', SameDateTime(EncodeDate(2026, 10, 16), LOptNull.Value));
  TAssert.AssertTrue('optnull unchanged', LOptNull.Map(KeepDateTime) = LOptNull);
end;

procedure TOptionalMapTests.Normalize_DateTime_KeepsStateAndApplies;
var
  LOpt: IOptDateTime;
  LNull: INullDateTime;
  LOptNull: IOptNullDateTime;
  LRaisedFunc, LRaisedNormalizer: Boolean;
begin
  LOpt := OptDateTimeOf(EncodeDate(2026, 10, 16) + 0.5);
  TAssert.AssertTrue('opt', SameDateTime(EncodeDate(2026, 10, 26) + 0.5, LOpt.Normalize(TAddDateTime.Create(10)).Value));
  TAssert.AssertTrue('opt static', SameDateTime(EncodeDate(2026, 10, 26) + 0.5, TOptionals.Normalize(LOpt, TAddDateTime.Create(10)).Value));
  LNull := NullDateTimeOf(EncodeDate(2026, 10, 16) + 0.5);
  TAssert.AssertTrue('null', SameDateTime(EncodeDate(2026, 10, 26) + 0.5, LNull.Normalize(TAddDateTime.Create(10)).Value));
  LOptNull := OptNullDateTimeOf(EncodeDate(2026, 10, 16) + 0.5);
  TAssert.AssertTrue('optnull', SameDateTime(EncodeDate(2026, 10, 26) + 0.5, LOptNull.Normalize(TAddDateTime.Create(10)).Value));
  LOpt := TOptNullDateTime.Undefined;
  TAssert.AssertTrue('undefined kept', LOpt.Normalize(TAddDateTime.Create(10)) = LOpt);
  LNull := TOptNullDateTime.Null;
  TAssert.AssertTrue('null kept', LNull.Normalize(TAddDateTime.Create(10)) = LNull);
  LOptNull := TOptNullDateTime.Undefined;
  TAssert.AssertTrue('nil reads as Safe', TOptionals.Normalize(IOptNullDateTime(nil), TAddDateTime.Create(10)) = LOptNull);

  LRaisedFunc := False;
  try
    LOpt.Map(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedNormalizer := False;
  try
    TOptionals.Normalize(LNull, IPcDateTimeNormalizer(nil));
  except
    on E: EArgumentException do
      LRaisedNormalizer := True;
  end;
  TAssert.AssertTrue('nil function, even with no value', LRaisedFunc);
  TAssert.AssertTrue('nil normalizer, even with no value', LRaisedNormalizer);
end;

procedure TOptionalMapTests.Map_Boolean_KeepsStateAndTransforms;
var
  LOpt: IOptBoolean;
  LNull: INullBoolean;
  LOptNull: IOptNullBoolean;
begin
  // IOptBoolean
  TAssert.AssertFalse('opt nil', TOptionals.Map(IOptBoolean(nil), ChangeBoolean).HasValue);
  LOpt := TOptNullBoolean.Undefined;
  TAssert.AssertTrue('opt undefined', LOpt.Map(ChangeBoolean) = LOpt);
  LOpt := TOptNullBoolean.Null;
  TAssert.AssertTrue('opt hidden null', LOpt.Map(ChangeBoolean) = LOpt);
  LOpt := OptBooleanOf(True);
  TAssert.AssertTrue('opt value', SameBoolean(False, LOpt.Map(ChangeBoolean).Value));
  TAssert.AssertTrue('opt static', SameBoolean(False, TOptionals.Map(LOpt, ChangeBoolean).Value));
  TAssert.AssertTrue('opt unchanged', LOpt.Map(KeepBoolean) = LOpt);
  // INullBoolean
  TAssert.AssertTrue('null nil', TOptionals.Map(INullBoolean(nil), ChangeBoolean).IsNull);
  LNull := TOptNullBoolean.Null;
  TAssert.AssertTrue('null null', LNull.Map(ChangeBoolean) = LNull);
  LNull := TOptNullBoolean.Undefined;
  TAssert.AssertTrue('null hidden undefined', LNull.Map(ChangeBoolean) = LNull);
  LNull := NullBooleanOf(True);
  TAssert.AssertTrue('null value', SameBoolean(False, LNull.Map(ChangeBoolean).Value));
  TAssert.AssertTrue('null unchanged', LNull.Map(KeepBoolean) = LNull);
  // IOptNullBoolean
  TAssert.AssertFalse('optnull nil', TOptionals.Map(IOptNullBoolean(nil), ChangeBoolean).HasValue);
  LOptNull := TOptNullBoolean.Undefined;
  TAssert.AssertTrue('optnull undefined', LOptNull.Map(ChangeBoolean) = LOptNull);
  LOptNull := TOptNullBoolean.Null;
  TAssert.AssertTrue('optnull null', LOptNull.Map(ChangeBoolean) = LOptNull);
  LOptNull := OptNullBooleanOf(True);
  LOptNull := LOptNull.Map(ChangeBoolean);
  TAssert.AssertTrue('optnull value', LOptNull.HasValue and not LOptNull.IsNull);
  TAssert.AssertTrue('optnull value', SameBoolean(False, LOptNull.Value));
  TAssert.AssertTrue('optnull unchanged', LOptNull.Map(KeepBoolean) = LOptNull);
end;

procedure TOptionalMapTests.Normalize_Boolean_KeepsStateAndApplies;
var
  LOpt: IOptBoolean;
  LNull: INullBoolean;
  LOptNull: IOptNullBoolean;
  LRaisedFunc, LRaisedNormalizer: Boolean;
begin
  LOpt := OptBooleanOf(True);
  TAssert.AssertTrue('opt', SameBoolean(False, LOpt.Normalize(TAddBoolean.Create(False)).Value));
  TAssert.AssertTrue('opt static', SameBoolean(False, TOptionals.Normalize(LOpt, TAddBoolean.Create(False)).Value));
  LNull := NullBooleanOf(True);
  TAssert.AssertTrue('null', SameBoolean(False, LNull.Normalize(TAddBoolean.Create(False)).Value));
  LOptNull := OptNullBooleanOf(True);
  TAssert.AssertTrue('optnull', SameBoolean(False, LOptNull.Normalize(TAddBoolean.Create(False)).Value));
  LOpt := TOptNullBoolean.Undefined;
  TAssert.AssertTrue('undefined kept', LOpt.Normalize(TAddBoolean.Create(False)) = LOpt);
  LNull := TOptNullBoolean.Null;
  TAssert.AssertTrue('null kept', LNull.Normalize(TAddBoolean.Create(False)) = LNull);
  LOptNull := TOptNullBoolean.Undefined;
  TAssert.AssertTrue('nil reads as Safe', TOptionals.Normalize(IOptNullBoolean(nil), TAddBoolean.Create(False)) = LOptNull);

  LRaisedFunc := False;
  try
    LOpt.Map(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedNormalizer := False;
  try
    TOptionals.Normalize(LNull, IPcBooleanNormalizer(nil));
  except
    on E: EArgumentException do
      LRaisedNormalizer := True;
  end;
  TAssert.AssertTrue('nil function, even with no value', LRaisedFunc);
  TAssert.AssertTrue('nil normalizer, even with no value', LRaisedNormalizer);
end;

procedure TOptionalMapTests.Map_Guid_KeepsStateAndTransforms;
var
  LOpt: IOptGuid;
  LNull: INullGuid;
  LOptNull: IOptNullGuid;
begin
  // IOptGuid
  TAssert.AssertFalse('opt nil', TOptionals.Map(IOptGuid(nil), ChangeGuid).HasValue);
  LOpt := TOptNullGuid.Undefined;
  TAssert.AssertTrue('opt undefined', LOpt.Map(ChangeGuid) = LOpt);
  LOpt := TOptNullGuid.Null;
  TAssert.AssertTrue('opt hidden null', LOpt.Map(ChangeGuid) = LOpt);
  LOpt := OptGuidOf(GUID_A);
  TAssert.AssertTrue('opt value', SameGuid(GUID_B, LOpt.Map(ChangeGuid).Value));
  TAssert.AssertTrue('opt static', SameGuid(GUID_B, TOptionals.Map(LOpt, ChangeGuid).Value));
  TAssert.AssertTrue('opt unchanged', LOpt.Map(KeepGuid) = LOpt);
  // INullGuid
  TAssert.AssertTrue('null nil', TOptionals.Map(INullGuid(nil), ChangeGuid).IsNull);
  LNull := TOptNullGuid.Null;
  TAssert.AssertTrue('null null', LNull.Map(ChangeGuid) = LNull);
  LNull := TOptNullGuid.Undefined;
  TAssert.AssertTrue('null hidden undefined', LNull.Map(ChangeGuid) = LNull);
  LNull := NullGuidOf(GUID_A);
  TAssert.AssertTrue('null value', SameGuid(GUID_B, LNull.Map(ChangeGuid).Value));
  TAssert.AssertTrue('null unchanged', LNull.Map(KeepGuid) = LNull);
  // IOptNullGuid
  TAssert.AssertFalse('optnull nil', TOptionals.Map(IOptNullGuid(nil), ChangeGuid).HasValue);
  LOptNull := TOptNullGuid.Undefined;
  TAssert.AssertTrue('optnull undefined', LOptNull.Map(ChangeGuid) = LOptNull);
  LOptNull := TOptNullGuid.Null;
  TAssert.AssertTrue('optnull null', LOptNull.Map(ChangeGuid) = LOptNull);
  LOptNull := OptNullGuidOf(GUID_A);
  LOptNull := LOptNull.Map(ChangeGuid);
  TAssert.AssertTrue('optnull value', LOptNull.HasValue and not LOptNull.IsNull);
  TAssert.AssertTrue('optnull value', SameGuid(GUID_B, LOptNull.Value));
  TAssert.AssertTrue('optnull unchanged', LOptNull.Map(KeepGuid) = LOptNull);
end;

procedure TOptionalMapTests.Normalize_Guid_KeepsStateAndApplies;
var
  LOpt: IOptGuid;
  LNull: INullGuid;
  LOptNull: IOptNullGuid;
  LRaisedFunc, LRaisedNormalizer: Boolean;
begin
  LOpt := OptGuidOf(GUID_A);
  TAssert.AssertTrue('opt', SameGuid(GUID_C, LOpt.Normalize(TAddGuid.Create(GUID_C)).Value));
  TAssert.AssertTrue('opt static', SameGuid(GUID_C, TOptionals.Normalize(LOpt, TAddGuid.Create(GUID_C)).Value));
  LNull := NullGuidOf(GUID_A);
  TAssert.AssertTrue('null', SameGuid(GUID_C, LNull.Normalize(TAddGuid.Create(GUID_C)).Value));
  LOptNull := OptNullGuidOf(GUID_A);
  TAssert.AssertTrue('optnull', SameGuid(GUID_C, LOptNull.Normalize(TAddGuid.Create(GUID_C)).Value));
  LOpt := TOptNullGuid.Undefined;
  TAssert.AssertTrue('undefined kept', LOpt.Normalize(TAddGuid.Create(GUID_C)) = LOpt);
  LNull := TOptNullGuid.Null;
  TAssert.AssertTrue('null kept', LNull.Normalize(TAddGuid.Create(GUID_C)) = LNull);
  LOptNull := TOptNullGuid.Undefined;
  TAssert.AssertTrue('nil reads as Safe', TOptionals.Normalize(IOptNullGuid(nil), TAddGuid.Create(GUID_C)) = LOptNull);

  LRaisedFunc := False;
  try
    LOpt.Map(nil);
  except
    on E: EArgumentException do
      LRaisedFunc := True;
  end;
  LRaisedNormalizer := False;
  try
    TOptionals.Normalize(LNull, IPcGuidNormalizer(nil));
  except
    on E: EArgumentException do
      LRaisedNormalizer := True;
  end;
  TAssert.AssertTrue('nil function, even with no value', LRaisedFunc);
  TAssert.AssertTrue('nil normalizer, even with no value', LRaisedNormalizer);
end;

procedure TOptionalMapTests.Map_FloatKeepsDecimalPlaces;
var
  LSingle: IOptSingle;
  LDouble: INullDouble;
begin
  LSingle := TOptNullSingle.From(1.5, 2);
  LSingle := LSingle.Map(ChangeSingle);
  TAssert.AssertEquals('single', 2, LSingle.DecimalPlaces);
  LDouble := TOptNullDouble.From(1.25, 3);
  LDouble := LDouble.Normalize(TAddDouble.Create(10));
  TAssert.AssertEquals('double', 3, LDouble.DecimalPlaces);
  TAssert.AssertTrue('double value', SameDouble(11.25, LDouble.Value));
end;

procedure TOptionalMapTests.Map_Boolean_ReturnsSharedInstances;
var
  LTrue, LFalse: IOptNullBoolean;
begin
  LTrue := TOptNullBoolean.TrueValue;
  LFalse := TOptNullBoolean.FalseValue;
  TAssert.AssertTrue('false', LTrue.Map(ChangeBoolean) = LFalse);
  TAssert.AssertTrue('true', LFalse.Map(ChangeBoolean) = LTrue);
end;

initialization
  RegisterTest(TOptionalMapTests);
end.
