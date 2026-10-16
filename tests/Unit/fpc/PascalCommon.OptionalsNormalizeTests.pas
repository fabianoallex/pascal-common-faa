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

initialization
  RegisterTest(TOptionalNormalizeTests);
end.
