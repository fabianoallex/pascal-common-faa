unit PascalCommon.OptionalsNormalizeTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalCommon.OptionalsNormalizeTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for the string normalizers of PascalCommon.Optionals
  (TOptionals.Trim/Upper/Lower/NullIfEmpty/UndefinedIfEmpty/Map): every
  flavor that has them (IOptString, INullString, IOptNullString) in every
  state (nil, Undefined, Null, a value), plus the state a flavor can't express
  but its object can (TOptNullString.Null held by an IOptString,
  TOptNullString.Undefined held by an INullString), which must come back
  unchanged instead of becoming ''.

  The Fluent_* tests cover the same normalizers as methods of the string
  flavors (X.Trim.Upper, 1.11.0): the same rules in every state, chains,
  the hidden states, the same instance for an unchanged value, and
  TOptionals.Safe(X) as the start of a chain when X is nil.

  The Normalizer_* tests cover Normalize (1.12.0), Map with an
  IPcStringNormalizer: the same rules, Apply never called without a value,
  one instance reused for many values, and an object created in the call
  (Normalize(TX.Create(...))) freed once the call returns. That last one runs the call in a separate
  function, because Delphi keeps an expression's temporaries until the
  routine ends.

  Each result is reduced to a text (Describe*: 'nil', 'undefined', 'null' or
  'value:<text>'), so a failure shows the state it got. Upper/Lower are
  checked with 'são paulo' on every platform: they must not depend on the
  process locale (gotcha 10; the Linux CI container runs without LANG, which
  is how the first version, AnsiUpperCase on FPC too, was caught). This file
  is UTF-8 with a BOM, so Delphi reads the literal right.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalCommon.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  PascalCommon.Optionals;

type
  TOptionalNormalizeTests = class(TTestCase)
  published
    procedure Trim_Opt_KeepsStateAndTrimsValue;
    procedure Trim_Null_KeepsStateAndTrimsValue;
    procedure Trim_OptNull_KeepsStateAndTrimsValue;
    procedure Trim_UnchangedValue_ReturnsSameInstance;
    procedure Trim_StateKept_ReturnsSameInstance;
    procedure Upper_Opt_KeepsStateAndUppercasesValue;
    procedure Upper_Null_KeepsStateAndUppercasesValue;
    procedure Upper_OptNull_KeepsStateAndUppercasesValue;
    procedure Upper_Accents_AreUppercased;
    procedure Lower_Opt_KeepsStateAndLowercasesValue;
    procedure Lower_Null_KeepsStateAndLowercasesValue;
    procedure Lower_OptNull_KeepsStateAndLowercasesValue;
    procedure Lower_Accents_AreLowercased;
    procedure NullIfEmpty_Null_EmptyBecomesNull;
    procedure NullIfEmpty_OptNull_EmptyBecomesNull;
    procedure UndefinedIfEmpty_Opt_EmptyBecomesUndefined;
    procedure UndefinedIfEmpty_OptNull_EmptyBecomesUndefined;
    procedure Compose_UpperOfTrim;
    procedure Compose_NullIfEmptyOfTrim_BlankBecomesNull;
    procedure Compose_UndefinedIfEmptyOfTrim_BlankBecomesUndefined;
    procedure Map_Opt_KeepsStateAndAppliesFunction;
    procedure Map_Null_KeepsStateAndAppliesFunction;
    procedure Map_OptNull_KeepsStateAndAppliesFunction;
    procedure Map_NilFunction_RaisesEArgumentException;
    procedure Fluent_Opt_KeepsStateAndTransformsValue;
    procedure Fluent_Null_KeepsStateAndTransformsValue;
    procedure Fluent_OptNull_KeepsStateAndTransformsValue;
    procedure Fluent_HiddenStates_AreKept;
    procedure Fluent_Chain_TrimUpper;
    procedure Fluent_Chain_BlankBecomesNullOrUndefined;
    procedure Fluent_AssignToItself;
    procedure Fluent_UnchangedValue_ReturnsSameInstance;
    procedure Fluent_SafeOfNil_StartsAChain;
    procedure Fluent_MapNilFunction_RaisesEArgumentException;
    procedure Normalizer_Opt_KeepsStateAndApplies;
    procedure Normalizer_Null_KeepsStateAndApplies;
    procedure Normalizer_OptNull_KeepsStateAndApplies;
    procedure Normalizer_NotCalledWithoutValue;
    procedure Normalizer_ReusedForManyValues;
    procedure Normalizer_CreatedInTheCall_IsFreed;
    procedure Normalizer_ChainsWithFunctionsAndBuiltins;
    procedure Normalizer_UnchangedValue_ReturnsSameInstance;
    procedure Normalizer_Nil_RaisesEArgumentException;
  end;

implementation

{ Inputs }

function OptOf(const AValue: string): IOptString;
begin
  Result := TOptNullString.From(AValue);
end;

function OptUndefined: IOptString;
begin
  Result := TOptNullString.Undefined;
end;

function OptHiddenNull: IOptString;
begin
  Result := TOptNullString.Null;
end;

function NullOf(const AValue: string): INullString;
begin
  Result := TOptNullString.From(AValue);
end;

function NullNull: INullString;
begin
  Result := TOptNullString.Null;
end;

function NullHiddenUndefined: INullString;
begin
  Result := TOptNullString.Undefined;
end;

function OptNullOf(const AValue: string): IOptNullString;
begin
  Result := TOptNullString.From(AValue);
end;

function OptNullUndefined: IOptNullString;
begin
  Result := TOptNullString.Undefined;
end;

function OptNullNull: IOptNullString;
begin
  Result := TOptNullString.Null;
end;

{ Results as text }

function IsHiddenNull(const AValue: IInterface): Boolean;
var
  LNullable: INullableBase;
begin
  Result := Supports(AValue, INullableBase, LNullable) and LNullable.IsNull;
end;

function IsHiddenUndefined(const AValue: IInterface): Boolean;
var
  LOptional: IOptionalBase;
begin
  Result := Supports(AValue, IOptionalBase, LOptional) and not LOptional.HasValue;
end;

function DescribeOpt(const AValue: IOptString): string;
begin
  if not Assigned(AValue) then
    Result := 'nil'
  else if not AValue.HasValue then
    Result := 'undefined'
  else if IsHiddenNull(AValue) then
    Result := 'null'
  else
    Result := 'value:' + AValue.Value;
end;

function DescribeNull(const AValue: INullString): string;
begin
  if not Assigned(AValue) then
    Result := 'nil'
  else if AValue.IsNull then
    Result := 'null'
  else if IsHiddenUndefined(AValue) then
    Result := 'undefined'
  else
    Result := 'value:' + AValue.Value;
end;

function DescribeOptNull(const AValue: IOptNullString): string;
begin
  if not Assigned(AValue) then
    Result := 'nil'
  else if not AValue.HasValue then
    Result := 'undefined'
  else if AValue.IsNull then
    Result := 'null'
  else
    Result := 'value:' + AValue.Value;
end;

{ A named function for Map: FPC 3.2.2 has no anonymous functions. }

function OnlyDigits(const AValue: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AValue) do
    if (AValue[I] >= '0') and (AValue[I] <= '9') then
      Result := Result + AValue[I];
end;

{ Normalizers for Normalize: classes, because they carry parameters. TCounting
  counts its Apply calls and reports its destruction through pointers, so a
  test can check both after the object is gone. }

type
  TMaxLength = class(TInterfacedObject, IPcStringNormalizer)
  private
    FMax: Integer;
  public
    constructor Create(AMax: Integer);
    function Apply(const AValue: string): string;
  end;

  TCounting = class(TInterfacedObject, IPcStringNormalizer)
  private
    FCalls: PInteger;
    FFreed: PBoolean;
  public
    constructor Create(ACalls: PInteger; AFreed: PBoolean);
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

constructor TCounting.Create(ACalls: PInteger; AFreed: PBoolean);
begin
  inherited Create;
  FCalls := ACalls;
  FFreed := AFreed;
end;

destructor TCounting.Destroy;
begin
  if FFreed <> nil then
    FFreed^ := True;
  inherited Destroy;
end;

function TCounting.Apply(const AValue: string): string;
begin
  Inc(FCalls^);
  Result := '<' + AValue + '>';
end;

function MapWithNewCounting(const AValue: IOptString; ACalls: PInteger;
  AFreed: PBoolean): string;
begin
  Result := DescribeOpt(AValue.Normalize(TCounting.Create(ACalls, AFreed)));
end;

{ TOptionalNormalizeTests }

procedure TOptionalNormalizeTests.Trim_Opt_KeepsStateAndTrimsValue;
begin
  TAssert.AssertEquals('nil', 'undefined', DescribeOpt(TOptionals.Trim(IOptString(nil))));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOpt(TOptionals.Trim(OptUndefined)));
  TAssert.AssertEquals('hidden null', 'null', DescribeOpt(TOptionals.Trim(OptHiddenNull)));
  TAssert.AssertEquals('value', 'value:a b', DescribeOpt(TOptionals.Trim(OptOf('  a b  '))));
  TAssert.AssertEquals('blank', 'value:', DescribeOpt(TOptionals.Trim(OptOf('   '))));
end;

procedure TOptionalNormalizeTests.Trim_Null_KeepsStateAndTrimsValue;
begin
  TAssert.AssertEquals('nil', 'null', DescribeNull(TOptionals.Trim(INullString(nil))));
  TAssert.AssertEquals('null', 'null', DescribeNull(TOptionals.Trim(NullNull)));
  TAssert.AssertEquals('hidden undefined', 'undefined', DescribeNull(TOptionals.Trim(NullHiddenUndefined)));
  TAssert.AssertEquals('value', 'value:a b', DescribeNull(TOptionals.Trim(NullOf('  a b  '))));
end;

procedure TOptionalNormalizeTests.Trim_OptNull_KeepsStateAndTrimsValue;
begin
  TAssert.AssertEquals('nil', 'undefined', DescribeOptNull(TOptionals.Trim(IOptNullString(nil))));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOptNull(TOptionals.Trim(OptNullUndefined)));
  TAssert.AssertEquals('null', 'null', DescribeOptNull(TOptionals.Trim(OptNullNull)));
  TAssert.AssertEquals('value', 'value:a b', DescribeOptNull(TOptionals.Trim(OptNullOf('  a b  '))));
end;

procedure TOptionalNormalizeTests.Trim_UnchangedValue_ReturnsSameInstance;
var
  LOpt: IOptString;
  LNull: INullString;
  LOptNull: IOptNullString;
begin
  LOpt := OptOf('already');
  LNull := NullOf('already');
  LOptNull := OptNullOf('already');
  TAssert.AssertTrue('IOptString', TOptionals.Trim(LOpt) = LOpt);
  TAssert.AssertTrue('INullString', TOptionals.Trim(LNull) = LNull);
  TAssert.AssertTrue('IOptNullString', TOptionals.Trim(LOptNull) = LOptNull);
end;

procedure TOptionalNormalizeTests.Trim_StateKept_ReturnsSameInstance;
var
  LOpt: IOptString;
  LNull: INullString;
  LOptNull: IOptNullString;
begin
  LOpt := OptHiddenNull;
  LNull := NullHiddenUndefined;
  LOptNull := OptNullNull;
  TAssert.AssertTrue('IOptString holding Null', TOptionals.Trim(LOpt) = LOpt);
  TAssert.AssertTrue('INullString holding Undefined', TOptionals.Trim(LNull) = LNull);
  TAssert.AssertTrue('IOptNullString Null', TOptionals.Trim(LOptNull) = LOptNull);
end;

procedure TOptionalNormalizeTests.Upper_Opt_KeepsStateAndUppercasesValue;
begin
  TAssert.AssertEquals('nil', 'undefined', DescribeOpt(TOptionals.Upper(IOptString(nil))));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOpt(TOptionals.Upper(OptUndefined)));
  TAssert.AssertEquals('hidden null', 'null', DescribeOpt(TOptionals.Upper(OptHiddenNull)));
  TAssert.AssertEquals('value', 'value:SP', DescribeOpt(TOptionals.Upper(OptOf('sp'))));
end;

procedure TOptionalNormalizeTests.Upper_Null_KeepsStateAndUppercasesValue;
begin
  TAssert.AssertEquals('nil', 'null', DescribeNull(TOptionals.Upper(INullString(nil))));
  TAssert.AssertEquals('null', 'null', DescribeNull(TOptionals.Upper(NullNull)));
  TAssert.AssertEquals('hidden undefined', 'undefined', DescribeNull(TOptionals.Upper(NullHiddenUndefined)));
  TAssert.AssertEquals('value', 'value:SP', DescribeNull(TOptionals.Upper(NullOf('sp'))));
end;

procedure TOptionalNormalizeTests.Upper_OptNull_KeepsStateAndUppercasesValue;
begin
  TAssert.AssertEquals('nil', 'undefined', DescribeOptNull(TOptionals.Upper(IOptNullString(nil))));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOptNull(TOptionals.Upper(OptNullUndefined)));
  TAssert.AssertEquals('null', 'null', DescribeOptNull(TOptionals.Upper(OptNullNull)));
  TAssert.AssertEquals('value', 'value:SP', DescribeOptNull(TOptionals.Upper(OptNullOf('sp'))));
end;

procedure TOptionalNormalizeTests.Upper_Accents_AreUppercased;
begin
  TAssert.AssertEquals('value:SÃO PAULO', DescribeOpt(TOptionals.Upper(OptOf('são paulo'))));
end;

procedure TOptionalNormalizeTests.Lower_Opt_KeepsStateAndLowercasesValue;
begin
  TAssert.AssertEquals('nil', 'undefined', DescribeOpt(TOptionals.Lower(IOptString(nil))));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOpt(TOptionals.Lower(OptUndefined)));
  TAssert.AssertEquals('hidden null', 'null', DescribeOpt(TOptionals.Lower(OptHiddenNull)));
  TAssert.AssertEquals('value', 'value:mail@x.com', DescribeOpt(TOptionals.Lower(OptOf('Mail@X.com'))));
end;

procedure TOptionalNormalizeTests.Lower_Null_KeepsStateAndLowercasesValue;
begin
  TAssert.AssertEquals('nil', 'null', DescribeNull(TOptionals.Lower(INullString(nil))));
  TAssert.AssertEquals('null', 'null', DescribeNull(TOptionals.Lower(NullNull)));
  TAssert.AssertEquals('hidden undefined', 'undefined', DescribeNull(TOptionals.Lower(NullHiddenUndefined)));
  TAssert.AssertEquals('value', 'value:mail@x.com', DescribeNull(TOptionals.Lower(NullOf('Mail@X.com'))));
end;

procedure TOptionalNormalizeTests.Lower_OptNull_KeepsStateAndLowercasesValue;
begin
  TAssert.AssertEquals('nil', 'undefined', DescribeOptNull(TOptionals.Lower(IOptNullString(nil))));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOptNull(TOptionals.Lower(OptNullUndefined)));
  TAssert.AssertEquals('null', 'null', DescribeOptNull(TOptionals.Lower(OptNullNull)));
  TAssert.AssertEquals('value', 'value:mail@x.com', DescribeOptNull(TOptionals.Lower(OptNullOf('Mail@X.com'))));
end;

procedure TOptionalNormalizeTests.Lower_Accents_AreLowercased;
begin
  TAssert.AssertEquals('value:são paulo', DescribeOpt(TOptionals.Lower(OptOf('SÃO PAULO'))));
end;

procedure TOptionalNormalizeTests.NullIfEmpty_Null_EmptyBecomesNull;
begin
  TAssert.AssertEquals('nil', 'null', DescribeNull(TOptionals.NullIfEmpty(INullString(nil))));
  TAssert.AssertEquals('null', 'null', DescribeNull(TOptionals.NullIfEmpty(NullNull)));
  TAssert.AssertEquals('hidden undefined', 'undefined', DescribeNull(TOptionals.NullIfEmpty(NullHiddenUndefined)));
  TAssert.AssertEquals('empty', 'null', DescribeNull(TOptionals.NullIfEmpty(NullOf(''))));
  TAssert.AssertEquals('blank is not trimmed', 'value: ', DescribeNull(TOptionals.NullIfEmpty(NullOf(' '))));
  TAssert.AssertEquals('value', 'value:a', DescribeNull(TOptionals.NullIfEmpty(NullOf('a'))));
end;

procedure TOptionalNormalizeTests.NullIfEmpty_OptNull_EmptyBecomesNull;
begin
  TAssert.AssertEquals('nil', 'undefined', DescribeOptNull(TOptionals.NullIfEmpty(IOptNullString(nil))));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOptNull(TOptionals.NullIfEmpty(OptNullUndefined)));
  TAssert.AssertEquals('null', 'null', DescribeOptNull(TOptionals.NullIfEmpty(OptNullNull)));
  TAssert.AssertEquals('empty', 'null', DescribeOptNull(TOptionals.NullIfEmpty(OptNullOf(''))));
  TAssert.AssertEquals('value', 'value:a', DescribeOptNull(TOptionals.NullIfEmpty(OptNullOf('a'))));
end;

procedure TOptionalNormalizeTests.UndefinedIfEmpty_Opt_EmptyBecomesUndefined;
begin
  TAssert.AssertEquals('nil', 'undefined', DescribeOpt(TOptionals.UndefinedIfEmpty(IOptString(nil))));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOpt(TOptionals.UndefinedIfEmpty(OptUndefined)));
  TAssert.AssertEquals('hidden null', 'null', DescribeOpt(TOptionals.UndefinedIfEmpty(OptHiddenNull)));
  TAssert.AssertEquals('empty', 'undefined', DescribeOpt(TOptionals.UndefinedIfEmpty(OptOf(''))));
  TAssert.AssertEquals('blank is not trimmed', 'value: ', DescribeOpt(TOptionals.UndefinedIfEmpty(OptOf(' '))));
  TAssert.AssertEquals('value', 'value:a', DescribeOpt(TOptionals.UndefinedIfEmpty(OptOf('a'))));
end;

procedure TOptionalNormalizeTests.UndefinedIfEmpty_OptNull_EmptyBecomesUndefined;
begin
  TAssert.AssertEquals('nil', 'undefined', DescribeOptNull(TOptionals.UndefinedIfEmpty(IOptNullString(nil))));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOptNull(TOptionals.UndefinedIfEmpty(OptNullUndefined)));
  TAssert.AssertEquals('null', 'null', DescribeOptNull(TOptionals.UndefinedIfEmpty(OptNullNull)));
  TAssert.AssertEquals('empty', 'undefined', DescribeOptNull(TOptionals.UndefinedIfEmpty(OptNullOf(''))));
  TAssert.AssertEquals('value', 'value:a', DescribeOptNull(TOptionals.UndefinedIfEmpty(OptNullOf('a'))));
end;

procedure TOptionalNormalizeTests.Compose_UpperOfTrim;
begin
  TAssert.AssertEquals('value:SP', DescribeOpt(TOptionals.Upper(TOptionals.Trim(OptOf(' sp ')))));
  TAssert.AssertEquals('undefined', DescribeOpt(TOptionals.Upper(TOptionals.Trim(OptUndefined))));
end;

procedure TOptionalNormalizeTests.Compose_NullIfEmptyOfTrim_BlankBecomesNull;
begin
  TAssert.AssertEquals('null', DescribeOptNull(TOptionals.NullIfEmpty(TOptionals.Trim(OptNullOf('   ')))));
  TAssert.AssertEquals('undefined', DescribeOptNull(TOptionals.NullIfEmpty(TOptionals.Trim(OptNullUndefined))));
end;

procedure TOptionalNormalizeTests.Compose_UndefinedIfEmptyOfTrim_BlankBecomesUndefined;
begin
  TAssert.AssertEquals('undefined', DescribeOpt(TOptionals.UndefinedIfEmpty(TOptionals.Trim(OptOf('   ')))));
  TAssert.AssertEquals('value:a', DescribeOpt(TOptionals.UndefinedIfEmpty(TOptionals.Trim(OptOf(' a ')))));
end;

procedure TOptionalNormalizeTests.Map_Opt_KeepsStateAndAppliesFunction;
begin
  TAssert.AssertEquals('nil', 'undefined', DescribeOpt(TOptionals.Map(IOptString(nil), OnlyDigits)));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOpt(TOptionals.Map(OptUndefined, OnlyDigits)));
  TAssert.AssertEquals('hidden null', 'null', DescribeOpt(TOptionals.Map(OptHiddenNull, OnlyDigits)));
  TAssert.AssertEquals('value', 'value:89010000', DescribeOpt(TOptionals.Map(OptOf('89.010-000'), OnlyDigits)));
end;

procedure TOptionalNormalizeTests.Map_Null_KeepsStateAndAppliesFunction;
begin
  TAssert.AssertEquals('nil', 'null', DescribeNull(TOptionals.Map(INullString(nil), OnlyDigits)));
  TAssert.AssertEquals('null', 'null', DescribeNull(TOptionals.Map(NullNull, OnlyDigits)));
  TAssert.AssertEquals('hidden undefined', 'undefined', DescribeNull(TOptionals.Map(NullHiddenUndefined, OnlyDigits)));
  TAssert.AssertEquals('value', 'value:89010000', DescribeNull(TOptionals.Map(NullOf('89.010-000'), OnlyDigits)));
end;

procedure TOptionalNormalizeTests.Map_OptNull_KeepsStateAndAppliesFunction;
begin
  TAssert.AssertEquals('nil', 'undefined', DescribeOptNull(TOptionals.Map(IOptNullString(nil), OnlyDigits)));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOptNull(TOptionals.Map(OptNullUndefined, OnlyDigits)));
  TAssert.AssertEquals('null', 'null', DescribeOptNull(TOptionals.Map(OptNullNull, OnlyDigits)));
  TAssert.AssertEquals('value', 'value:89010000', DescribeOptNull(TOptionals.Map(OptNullOf('89.010-000'), OnlyDigits)));
end;

procedure TOptionalNormalizeTests.Map_NilFunction_RaisesEArgumentException;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    TOptionals.Map(OptUndefined, nil);
  except
    on E: EArgumentException do
      LRaised := True;
  end;
  TAssert.AssertTrue('even with no value to transform', LRaised);
end;

procedure TOptionalNormalizeTests.Fluent_Opt_KeepsStateAndTransformsValue;
begin
  TAssert.AssertEquals('trim undefined', 'undefined', DescribeOpt(OptUndefined.Trim));
  TAssert.AssertEquals('trim', 'value:a b', DescribeOpt(OptOf(' a b ').Trim));
  TAssert.AssertEquals('upper undefined', 'undefined', DescribeOpt(OptUndefined.Upper));
  TAssert.AssertEquals('upper', 'value:SÃO PAULO', DescribeOpt(OptOf('são paulo').Upper));
  TAssert.AssertEquals('lower undefined', 'undefined', DescribeOpt(OptUndefined.Lower));
  TAssert.AssertEquals('lower', 'value:são paulo', DescribeOpt(OptOf('SÃO PAULO').Lower));
  TAssert.AssertEquals('undefinedifempty empty', 'undefined', DescribeOpt(OptOf('').UndefinedIfEmpty));
  TAssert.AssertEquals('undefinedifempty value', 'value:a', DescribeOpt(OptOf('a').UndefinedIfEmpty));
  TAssert.AssertEquals('map undefined', 'undefined', DescribeOpt(OptUndefined.Map(OnlyDigits)));
  TAssert.AssertEquals('map', 'value:89010000', DescribeOpt(OptOf('89.010-000').Map(OnlyDigits)));
end;

procedure TOptionalNormalizeTests.Fluent_Null_KeepsStateAndTransformsValue;
begin
  TAssert.AssertEquals('trim null', 'null', DescribeNull(NullNull.Trim));
  TAssert.AssertEquals('trim', 'value:a b', DescribeNull(NullOf(' a b ').Trim));
  TAssert.AssertEquals('upper null', 'null', DescribeNull(NullNull.Upper));
  TAssert.AssertEquals('upper', 'value:SÃO PAULO', DescribeNull(NullOf('são paulo').Upper));
  TAssert.AssertEquals('lower null', 'null', DescribeNull(NullNull.Lower));
  TAssert.AssertEquals('lower', 'value:são paulo', DescribeNull(NullOf('SÃO PAULO').Lower));
  TAssert.AssertEquals('nullifempty empty', 'null', DescribeNull(NullOf('').NullIfEmpty));
  TAssert.AssertEquals('nullifempty value', 'value:a', DescribeNull(NullOf('a').NullIfEmpty));
  TAssert.AssertEquals('map null', 'null', DescribeNull(NullNull.Map(OnlyDigits)));
  TAssert.AssertEquals('map', 'value:89010000', DescribeNull(NullOf('89.010-000').Map(OnlyDigits)));
end;

procedure TOptionalNormalizeTests.Fluent_OptNull_KeepsStateAndTransformsValue;
begin
  TAssert.AssertEquals('trim undefined', 'undefined', DescribeOptNull(OptNullUndefined.Trim));
  TAssert.AssertEquals('trim null', 'null', DescribeOptNull(OptNullNull.Trim));
  TAssert.AssertEquals('trim', 'value:a b', DescribeOptNull(OptNullOf(' a b ').Trim));
  TAssert.AssertEquals('upper', 'value:SÃO PAULO', DescribeOptNull(OptNullOf('são paulo').Upper));
  TAssert.AssertEquals('lower', 'value:são paulo', DescribeOptNull(OptNullOf('SÃO PAULO').Lower));
  TAssert.AssertEquals('nullifempty empty', 'null', DescribeOptNull(OptNullOf('').NullIfEmpty));
  TAssert.AssertEquals('nullifempty undefined', 'undefined', DescribeOptNull(OptNullUndefined.NullIfEmpty));
  TAssert.AssertEquals('undefinedifempty empty', 'undefined', DescribeOptNull(OptNullOf('').UndefinedIfEmpty));
  TAssert.AssertEquals('undefinedifempty null', 'null', DescribeOptNull(OptNullNull.UndefinedIfEmpty));
  TAssert.AssertEquals('map null', 'null', DescribeOptNull(OptNullNull.Map(OnlyDigits)));
  TAssert.AssertEquals('map', 'value:89010000', DescribeOptNull(OptNullOf('89.010-000').Map(OnlyDigits)));
end;

procedure TOptionalNormalizeTests.Fluent_HiddenStates_AreKept;
begin
  TAssert.AssertEquals('opt hidden null trim', 'null', DescribeOpt(OptHiddenNull.Trim));
  TAssert.AssertEquals('opt hidden null upper', 'null', DescribeOpt(OptHiddenNull.Upper));
  TAssert.AssertEquals('opt hidden null undefinedifempty', 'null', DescribeOpt(OptHiddenNull.UndefinedIfEmpty));
  TAssert.AssertEquals('opt hidden null map', 'null', DescribeOpt(OptHiddenNull.Map(OnlyDigits)));
  TAssert.AssertEquals('null hidden undefined trim', 'undefined', DescribeNull(NullHiddenUndefined.Trim));
  TAssert.AssertEquals('null hidden undefined lower', 'undefined', DescribeNull(NullHiddenUndefined.Lower));
  TAssert.AssertEquals('null hidden undefined nullifempty', 'undefined', DescribeNull(NullHiddenUndefined.NullIfEmpty));
  TAssert.AssertEquals('null hidden undefined map', 'undefined', DescribeNull(NullHiddenUndefined.Map(OnlyDigits)));
end;

procedure TOptionalNormalizeTests.Fluent_Chain_TrimUpper;
begin
  TAssert.AssertEquals('opt', 'value:SÃO PAULO', DescribeOpt(OptOf('  são paulo ').Trim.Upper));
  TAssert.AssertEquals('null', 'value:SÃO PAULO', DescribeNull(NullOf('  são paulo ').Trim.Upper));
  TAssert.AssertEquals('optnull', 'value:SÃO PAULO', DescribeOptNull(OptNullOf('  são paulo ').Trim.Upper));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOpt(OptUndefined.Trim.Upper));
  TAssert.AssertEquals('null state', 'null', DescribeOptNull(OptNullNull.Trim.Upper.Lower));
end;

procedure TOptionalNormalizeTests.Fluent_Chain_BlankBecomesNullOrUndefined;
begin
  TAssert.AssertEquals('null', 'null', DescribeNull(NullOf('   ').Trim.NullIfEmpty));
  TAssert.AssertEquals('optnull null', 'null', DescribeOptNull(OptNullOf('   ').Trim.NullIfEmpty));
  TAssert.AssertEquals('opt', 'undefined', DescribeOpt(OptOf('   ').Trim.UndefinedIfEmpty));
  TAssert.AssertEquals('optnull undefined', 'undefined', DescribeOptNull(OptNullOf('   ').Trim.UndefinedIfEmpty));
  TAssert.AssertEquals('value', 'value:a', DescribeOpt(OptOf(' a ').Trim.UndefinedIfEmpty));
end;

procedure TOptionalNormalizeTests.Fluent_AssignToItself;
var
  LOpt: IOptString;
  LNull: INullString;
  LOptNull: IOptNullString;
begin
  LOpt := OptOf(' sp ');
  LOpt := LOpt.Trim.Upper;
  LNull := NullOf(' sp ');
  LNull := LNull.Trim.Upper;
  LOptNull := OptNullOf('   ');
  LOptNull := LOptNull.Trim.NullIfEmpty;
  TAssert.AssertEquals('opt', 'value:SP', DescribeOpt(LOpt));
  TAssert.AssertEquals('null', 'value:SP', DescribeNull(LNull));
  TAssert.AssertEquals('optnull', 'null', DescribeOptNull(LOptNull));
end;

procedure TOptionalNormalizeTests.Fluent_UnchangedValue_ReturnsSameInstance;
var
  LOpt: IOptString;
  LNull: INullString;
  LOptNull: IOptNullString;
begin
  LOpt := OptOf('ALREADY');
  LNull := NullOf('ALREADY');
  LOptNull := OptNullOf('ALREADY');
  TAssert.AssertTrue('IOptString', LOpt.Trim.Upper = LOpt);
  TAssert.AssertTrue('INullString', LNull.Trim.Upper = LNull);
  TAssert.AssertTrue('IOptNullString', LOptNull.Trim.Upper = LOptNull);
end;

procedure TOptionalNormalizeTests.Fluent_SafeOfNil_StartsAChain;
begin
  TAssert.AssertEquals('opt', 'undefined', DescribeOpt(TOptionals.Safe(IOptString(nil)).Trim.Upper));
  TAssert.AssertEquals('null', 'null', DescribeNull(TOptionals.Safe(INullString(nil)).Trim.Upper));
  TAssert.AssertEquals('optnull', 'undefined', DescribeOptNull(TOptionals.Safe(IOptNullString(nil)).Trim.Upper));
end;

procedure TOptionalNormalizeTests.Fluent_MapNilFunction_RaisesEArgumentException;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    OptNullUndefined.Map(nil);
  except
    on E: EArgumentException do
      LRaised := True;
  end;
  TAssert.AssertTrue('even with no value to transform', LRaised);
end;

procedure TOptionalNormalizeTests.Normalizer_Opt_KeepsStateAndApplies;
begin
  TAssert.AssertEquals('nil', 'undefined', DescribeOpt(TOptionals.Normalize(IOptString(nil), TMaxLength.Create(2))));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOpt(OptUndefined.Normalize(TMaxLength.Create(2))));
  TAssert.AssertEquals('hidden null', 'null', DescribeOpt(OptHiddenNull.Normalize(TMaxLength.Create(2))));
  TAssert.AssertEquals('value', 'value:ab', DescribeOpt(OptOf('abcd').Normalize(TMaxLength.Create(2))));
  TAssert.AssertEquals('static', 'value:ab', DescribeOpt(TOptionals.Normalize(OptOf('abcd'), TMaxLength.Create(2))));
end;

procedure TOptionalNormalizeTests.Normalizer_Null_KeepsStateAndApplies;
begin
  TAssert.AssertEquals('nil', 'null', DescribeNull(TOptionals.Normalize(INullString(nil), TMaxLength.Create(2))));
  TAssert.AssertEquals('null', 'null', DescribeNull(NullNull.Normalize(TMaxLength.Create(2))));
  TAssert.AssertEquals('hidden undefined', 'undefined', DescribeNull(NullHiddenUndefined.Normalize(TMaxLength.Create(2))));
  TAssert.AssertEquals('value', 'value:ab', DescribeNull(NullOf('abcd').Normalize(TMaxLength.Create(2))));
  TAssert.AssertEquals('static', 'value:ab', DescribeNull(TOptionals.Normalize(NullOf('abcd'), TMaxLength.Create(2))));
end;

procedure TOptionalNormalizeTests.Normalizer_OptNull_KeepsStateAndApplies;
begin
  TAssert.AssertEquals('nil', 'undefined', DescribeOptNull(TOptionals.Normalize(IOptNullString(nil), TMaxLength.Create(2))));
  TAssert.AssertEquals('undefined', 'undefined', DescribeOptNull(OptNullUndefined.Normalize(TMaxLength.Create(2))));
  TAssert.AssertEquals('null', 'null', DescribeOptNull(OptNullNull.Normalize(TMaxLength.Create(2))));
  TAssert.AssertEquals('value', 'value:ab', DescribeOptNull(OptNullOf('abcd').Normalize(TMaxLength.Create(2))));
  TAssert.AssertEquals('static', 'value:ab', DescribeOptNull(TOptionals.Normalize(OptNullOf('abcd'), TMaxLength.Create(2))));
end;

procedure TOptionalNormalizeTests.Normalizer_NotCalledWithoutValue;
var
  LCalls: Integer;
  LNormalizer: IPcStringNormalizer;
begin
  LCalls := 0;
  LNormalizer := TCounting.Create(@LCalls, nil);
  OptUndefined.Normalize(LNormalizer);
  OptHiddenNull.Normalize(LNormalizer);
  NullNull.Normalize(LNormalizer);
  NullHiddenUndefined.Normalize(LNormalizer);
  OptNullUndefined.Normalize(LNormalizer);
  OptNullNull.Normalize(LNormalizer);
  TAssert.AssertEquals('no value, no call', 0, LCalls);
  OptOf('a').Normalize(LNormalizer);
  TAssert.AssertEquals('one value, one call', 1, LCalls);
end;

procedure TOptionalNormalizeTests.Normalizer_ReusedForManyValues;
var
  LCalls: Integer;
  LNormalizer: IPcStringNormalizer;
begin
  LCalls := 0;
  LNormalizer := TCounting.Create(@LCalls, nil);
  TAssert.AssertEquals('opt', 'value:<a>', DescribeOpt(OptOf('a').Normalize(LNormalizer)));
  TAssert.AssertEquals('null', 'value:<b>', DescribeNull(NullOf('b').Normalize(LNormalizer)));
  TAssert.AssertEquals('optnull', 'value:<c>', DescribeOptNull(TOptionals.Normalize(OptNullOf('c'), LNormalizer)));
  TAssert.AssertEquals('calls', 3, LCalls);
end;

procedure TOptionalNormalizeTests.Normalizer_CreatedInTheCall_IsFreed;
var
  LCalls: Integer;
  LFreed: Boolean;
begin
  LCalls := 0;
  LFreed := False;
  TAssert.AssertEquals('result', 'value:<a>', MapWithNewCounting(OptOf('a'), @LCalls, @LFreed));
  TAssert.AssertEquals('calls', 1, LCalls);
  TAssert.AssertTrue('freed after the call', LFreed);
end;

procedure TOptionalNormalizeTests.Normalizer_ChainsWithFunctionsAndBuiltins;
var
  LZip: IOptNullString;
begin
  LZip := OptNullOf(' 89.010-000 ');
  LZip := LZip.Trim.Map(OnlyDigits).Normalize(TMaxLength.Create(5));
  TAssert.AssertEquals('value', 'value:89010', DescribeOptNull(LZip));
  TAssert.AssertEquals('blank', 'null',
    DescribeOptNull(OptNullOf(' -.- ').Map(OnlyDigits).Normalize(TMaxLength.Create(5)).NullIfEmpty));
end;

procedure TOptionalNormalizeTests.Normalizer_UnchangedValue_ReturnsSameInstance;
var
  LOpt: IOptString;
begin
  LOpt := OptOf('ab');
  TAssert.AssertTrue(LOpt.Normalize(TMaxLength.Create(5)) = LOpt);
end;

procedure TOptionalNormalizeTests.Normalizer_Nil_RaisesEArgumentException;
var
  LFluent, LStatic: Boolean;
begin
  LFluent := False;
  try
    OptUndefined.Normalize(IPcStringNormalizer(nil));
  except
    on E: EArgumentException do
      LFluent := True;
  end;
  LStatic := False;
  try
    TOptionals.Normalize(NullNull, IPcStringNormalizer(nil));
  except
    on E: EArgumentException do
      LStatic := True;
  end;
  TAssert.AssertTrue('fluent, even with no value to transform', LFluent);
  TAssert.AssertTrue('static, even with no value to transform', LStatic);
end;

initialization
  RegisterTest(TOptionalNormalizeTests);
end.
