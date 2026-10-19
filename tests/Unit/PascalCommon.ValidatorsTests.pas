unit PascalCommon.ValidatorsTests;

{ Tests for PascalCommon.Validators (1.21.0): every built-in validator and its
  English message, Portuguese messages, FromFunc and All, a factory inherited
  by an application, and the collector: absent, null and value per shape of
  member, one error per field, every field raised together. This file is
  UTF-8 with a BOM, so Delphi reads the accented literals right.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalCommon.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalCommon.DUnitXCompat,
  SysUtils,
  DateUtils,
  PascalCommon.Optionals,
  PascalCommon.Validators;

type
  // An application's factory: the library's validators and its own.
  TTestValid = class(TPcStringValidators)
  public
    class function Even: IPcStringValidator; static;
  end;

  [TestFixture]
  TValidatorsTests = class
  public
    [Test] procedure Required_Blanks;
    [Test] procedure Length_CountsCharacters;
    [Test] procedure OneOf_Exact;
    [Test] procedure FromFunc_And_Inherited;
    [Test] procedure All_FirstFailureAnswers;
    [Test] procedure Integer_Bounds_And_Multiple;
    [Test] procedure Int64_Bounds;
    [Test] procedure Double_InvariantText;
    [Test] procedure Currency_Decimals_And_Range;
    [Test] procedure DateTime_Range_Iso;
    [Test] procedure Messages_Portuguese;
    [Test] procedure Arguments_Refused;
    [Test] procedure Collector_ShapesOfMember;
    [Test] procedure Collector_OneErrorPerField;
    [Test] procedure Collector_RaisesEveryField;
    [Test] procedure Collector_Fail_And_Valid;
  end;

implementation

const
  // A typed constant, not the literal in the call: FPC 3.2.2 turns a
  // fractional literal used as a Currency value into a near value (100000.5
  // becomes 100000.4992, Windows and Linux; pascal-common-faa gotcha 13).
  MAX_PRICE: Currency = 100000.5;
  JUST_ABOVE: Currency = 100000.51;

function EvenLength(const AField, AValue: string; out AMessage: string): string;
begin
  Result := '';
  if Length(AValue) mod 2 <> 0 then
  begin
    Result := 'odd';
    AMessage := Format('"%s" must have an even length.', [AField]);
  end;
end;

class function TTestValid.Even: IPcStringValidator;
begin
  Result := FromFunc(EvenLength);
end;

// "code: message" from one validator, '' when it passes.
function S(AValidator: IPcStringValidator; const AValue: string): string;
var
  LMessage, LCode: string;
begin
  LCode := AValidator.Check('name', AValue, LMessage);
  if LCode = '' then
    Result := ''
  else
    Result := LCode + ': ' + LMessage;
end;

function I(AValidator: IPcIntegerValidator; AValue: Integer): string;
var
  LMessage, LCode: string;
begin
  LCode := AValidator.Check('n', AValue, LMessage);
  if LCode = '' then
    Result := ''
  else
    Result := LCode + ': ' + LMessage;
end;

procedure TValidatorsTests.Required_Blanks;
begin
  TAssert.AssertEquals('', S(TPcStringValidators.Required, 'Ana'));
  TAssert.AssertEquals('required: "name" is required.', S(TPcStringValidators.Required, ''));
  TAssert.AssertEquals('required: "name" is required.', S(TPcStringValidators.Required, '  '#9));
end;

procedure TValidatorsTests.Length_CountsCharacters;
begin
  // 'São' is 3 characters on both compilers (4 UTF-8 bytes on FPC).
  TAssert.AssertEquals('', S(TPcStringValidators.MaxLength(3), 'São'));
  TAssert.AssertEquals('too_long: "name" must have at most 3 characters.',
    S(TPcStringValidators.MaxLength(3), 'Sãoo'));
  TAssert.AssertEquals('too_short: "name" must have at least 2 characters.',
    S(TPcStringValidators.MinLength(2), 'ã'));
  TAssert.AssertEquals('', S(TPcStringValidators.MinLength(2), 'ãé'));
end;

procedure TValidatorsTests.OneOf_Exact;
begin
  TAssert.AssertEquals('', S(TPcStringValidators.OneOf(['owner', 'staff']), 'staff'));
  TAssert.AssertEquals('not_allowed: "name" must be one of: owner, staff.',
    S(TPcStringValidators.OneOf(['owner', 'staff']), 'Staff'));
end;

procedure TValidatorsTests.FromFunc_And_Inherited;
begin
  TAssert.AssertEquals('', S(TTestValid.Even, 'ab'));
  TAssert.AssertEquals('odd: "name" must have an even length.', S(TTestValid.Even, 'abc'));
  TAssert.AssertEquals('the library''s, through the application''s factory',
    'required: "name" is required.', S(TTestValid.Required, ''));
end;

procedure TValidatorsTests.All_FirstFailureAnswers;
var
  LRule: IPcStringValidator;
begin
  LRule := TPcStringValidators.All([TPcStringValidators.Required,
    TPcStringValidators.MaxLength(4), TTestValid.Even]);
  TAssert.AssertEquals('required: "name" is required.', S(LRule, ''));
  TAssert.AssertEquals('too_long: "name" must have at most 4 characters.', S(LRule, 'abcdef'));
  TAssert.AssertEquals('odd: "name" must have an even length.', S(LRule, 'abc'));
  TAssert.AssertEquals('', S(LRule, 'abcd'));
end;

procedure TValidatorsTests.Integer_Bounds_And_Multiple;
begin
  TAssert.AssertEquals('', I(TPcIntegerValidators.Range(5, 480), 5));
  TAssert.AssertEquals('', I(TPcIntegerValidators.Range(5, 480), 480));
  TAssert.AssertEquals('out_of_range: "n" must be from 5 to 480.',
    I(TPcIntegerValidators.Range(5, 480), 481));
  TAssert.AssertEquals('below_minimum: "n" must be at least 0.', I(TPcIntegerValidators.Min(0), -1));
  TAssert.AssertEquals('above_maximum: "n" must be at most 10.', I(TPcIntegerValidators.Max(10), 11));
  TAssert.AssertEquals('not_multiple: "n" must be a multiple of 5.',
    I(TPcIntegerValidators.MultipleOf(5), 7));
  TAssert.AssertEquals('', I(TPcIntegerValidators.MultipleOf(5), -10));
end;

procedure TValidatorsTests.Int64_Bounds;
var
  LMessage: string;
begin
  TAssert.AssertEquals('out_of_range', TPcInt64Validators.Range(0, 9000000000).Check('n',
    9000000001, LMessage));
  TAssert.AssertEquals('"n" must be from 0 to 9000000000.', LMessage);
  TAssert.AssertEquals('', TPcInt64Validators.MultipleOf(60).Check('n', 1798117200, LMessage));
end;

procedure TValidatorsTests.Double_InvariantText;
var
  LMessage: string;
begin
  TAssert.AssertEquals('out_of_range', TPcDoubleValidators.Range(0.5, 2.5).Check('ratio', 3,
    LMessage));
  TAssert.AssertEquals('"." whatever the locale', '"ratio" must be from 0.5 to 2.5.', LMessage);
  TAssert.AssertEquals('', TPcDoubleValidators.Min(0).Check('ratio', 0, LMessage));
end;

procedure TValidatorsTests.Currency_Decimals_And_Range;
var
  LMessage: string;
begin
  TAssert.AssertEquals('', TPcCurrencyValidators.MaxDecimals(2).Check('price', 80.5, LMessage));
  TAssert.AssertEquals('too_many_decimals', TPcCurrencyValidators.MaxDecimals(2).Check('price',
    1.234, LMessage));
  TAssert.AssertEquals('"price" can have at most 2 decimal places.', LMessage);
  TAssert.AssertEquals('', TPcCurrencyValidators.MaxDecimals(0).Check('price', -3, LMessage));
  TAssert.AssertEquals('out_of_range', TPcCurrencyValidators.Range(0, MAX_PRICE).Check('price',
    JUST_ABOVE, LMessage));
  TAssert.AssertEquals('"price" must be from 0 to 100000.5.', LMessage);
  TAssert.AssertEquals('the bound itself passes', '',
    TPcCurrencyValidators.Range(0, MAX_PRICE).Check('price', MAX_PRICE, LMessage));
end;

procedure TValidatorsTests.DateTime_Range_Iso;
var
  LMessage: string;
begin
  TAssert.AssertEquals('below_minimum', TPcDateTimeValidators.Min(EncodeDateTime(2026, 1, 1, 0, 0,
    0, 0)).Check('at', EncodeDate(2025, 12, 31), LMessage));
  TAssert.AssertEquals('"at" must be at least 2026-01-01T00:00:00.', LMessage);
end;

procedure TValidatorsTests.Messages_Portuguese;
var
  LSaved: TPcValidationMessages;
begin
  LSaved := TPcValidationMessages.Current;
  TPcValidationMessages.Current := TPcValidationMessages.Portuguese;
  try
    TAssert.AssertEquals('required: "name" é obrigatório.', S(TPcStringValidators.Required, ''));
    TAssert.AssertEquals('out_of_range: "n" deve estar entre 5 e 480.',
      I(TPcIntegerValidators.Range(5, 480), 1));
  finally
    TPcValidationMessages.Current := LSaved;
  end;
  TAssert.AssertEquals('required: "name" is required.', S(TPcStringValidators.Required, ''));
end;

procedure TValidatorsTests.Arguments_Refused;

  function Raises(AKind: Integer): Boolean;
  begin
    Result := False;
    try
      case AKind of
        0: TPcIntegerValidators.Range(5, 1);
        1: TPcStringValidators.OneOf([]);
        2: TPcIntegerValidators.MultipleOf(0);
        3: TPcCurrencyValidators.MaxDecimals(5);
        4: TPcStringValidators.FromFunc(nil);
      end;
    except
      on E: EArgumentException do
        Result := True;
    end;
  end;

var
  K: Integer;
begin
  for K := 0 to 4 do
    TAssert.AssertTrue('argument case ' + IntToStr(K), Raises(K));
end;

procedure TValidatorsTests.Collector_ShapesOfMember;
var
  LCheck: TPcValidation;
  LAbsent: IOptString;
  LNull: IOptNullString;
  LNullPlain: INullString;
  LBad: IOptNullString;
  LCount: IOptInteger;
begin
  LAbsent := TOptNullString.Undefined;
  LNull := TOptNullString.Null;
  LNullPlain := TOptNullString.Null;
  LBad := TOptNullString.From('');
  LCount := TOptNullInteger.From(7);
  LCheck := TPcValidation.Create;
  LCheck.Check('a', LAbsent, TPcStringValidators.Required);        // absent: not checked
  LCheck.Check('b', LNull, TPcStringValidators.Required);          // null: not checked
  LCheck.Check('c', LNullPlain, TPcStringValidators.Required);     // null: not checked
  LCheck.Check('d', LBad, TPcStringValidators.Required);           // a value: checked
  LCheck.Check('e', LCount, TPcIntegerValidators.MultipleOf(5));   // a value: checked
  LCheck.Check('f', '', TPcStringValidators.Required);             // plain: always
  TAssert.AssertEquals(3, Length(LCheck.Errors));
  TAssert.AssertEquals('d', LCheck.Errors[0].Field);
  TAssert.AssertEquals('e', LCheck.Errors[1].Field);
  TAssert.AssertEquals('not_multiple', LCheck.Errors[1].Code);
  TAssert.AssertEquals('f', LCheck.Errors[2].Field);
end;

procedure TValidatorsTests.Collector_OneErrorPerField;
var
  LCheck: TPcValidation;
begin
  LCheck := TPcValidation.Create;
  LCheck.Check('name', '', TPcStringValidators.Required);
  LCheck.Check('name', '', TPcStringValidators.MinLength(3));
  LCheck.Fail('name', 'other', 'another');
  TAssert.AssertEquals(1, Length(LCheck.Errors));
  TAssert.AssertEquals('required', LCheck.Errors[0].Code);
  TAssert.AssertTrue(LCheck.HasFailed('name'));
end;

procedure TValidatorsTests.Collector_RaisesEveryField;
var
  LCheck: TPcValidation;
  LRaised: Boolean;
begin
  LCheck := TPcValidation.Create;
  LCheck.Check('name', '', TPcStringValidators.Required);
  LCheck.Check('durationMinutes', 7, TPcIntegerValidators.MultipleOf(5));
  LRaised := False;
  try
    LCheck.RaiseIfAny;
  except
    on E: EPcValidationError do
    begin
      LRaised := True;
      TAssert.AssertEquals(2, Length(E.Errors));
      TAssert.AssertEquals('the first one''s message', '"name" is required.', E.Message);
      TAssert.AssertEquals('durationMinutes', E.Errors[1].Field);
      TAssert.AssertEquals('"durationMinutes" must be a multiple of 5.', E.Errors[1].Message);
    end;
  end;
  TAssert.AssertTrue(LRaised);
end;

procedure TValidatorsTests.Collector_Fail_And_Valid;
var
  LCheck: TPcValidation;
begin
  LCheck := TPcValidation.Create;
  LCheck.Check('name', 'Ana', TPcStringValidators.Required);
  TAssert.AssertTrue(LCheck.IsValid);
  LCheck.RaiseIfAny; // nothing
  LCheck.Fail('endsAt', 'before_start', '"endsAt" must come after "startsAt".');
  TAssert.AssertFalse(LCheck.IsValid);
  TAssert.AssertEquals('before_start', LCheck.Errors[0].Code);
end;

initialization
  TDUnitX.RegisterTestFixture(TValidatorsTests);
end.
