unit PascalCommon.Validators;

{$I pascalcommon.inc}

{ Validators: checks that refuse a value and change nothing, one validator
  interface and one factory class per type (TPcStringValidators,
  TPcIntegerValidators...), and a collector (TPcValidation) that gathers
  every failing field and raises them together (1.21.0).

  The mirror of PascalCommon.Normalizers, and their partner: a normalizer
  turns a value into the form to store and never refuses; a validator then
  says whether that value is acceptable. An application inherits a factory to
  add its rules next to the library's (TValid = class(TPcStringValidators)),
  as it does with TPcStringNormalizers.

    LCheck := TPcValidation.Create;
    LCheck.Check('name', LName, TPcStringValidators.All([TValid.Required,
      TValid.MaxLength(100)]));
    LCheck.Check('durationMinutes', APatch.DurationMinutes,
      TPcIntegerValidators.Range(5, 480));
    LCheck.RaiseIfAny;   // EPcValidationError with every failure, or nothing

  Why here and not in pascal-api-infra-faa: a queue consumer, a pipe server
  or a desktop client validate the same DTO the same way, and none of them
  speaks HTTP. EPcValidationError is neutral; pascal-api-infra-faa's error
  handler turns it into a 400 that lists the fields. Designed in
  pascal-api-infra-faa's docs/validation-design.md, from pascal-agenda-faa,
  whose repositories wrote each rule three times (a required string, an
  optional checked when it came, a nullable one checked when it came with a
  value).

  - TPcValidation.Check has one overload per shape of member: a plain value
    is always checked; an IOptXxx only when it came; an INullXxx or
    IOptNullXxx only when it holds a value (null is a value the type allows).
    That rule lives here, once.
  - One error per field: a field already failed isn't checked again, and All
    stops at its first failing validator.
  - Lengths are characters (Unicode code points, PcCharCount), the same on
    both compilers and what JSON Schema's maxLength means.
  - Numbers in messages use '.' as the decimal separator whatever the locale;
    dates are ISO 8601.
  - Messages come from TPcValidationMessages.Current (English by default,
    Portuguese ready), with the field's name in them; a FromFunc rule writes
    its own.
  - A validator holds no state that changes, so one instance may be kept and
    used from many threads. A parameter that takes one isn't const, as with
    normalizers: TX.Create(...) passed to a const interface parameter would
    never be freed. FromFunc takes a plain function (FPC 3.2.2 has no
    closures); a rule with state (a row that must exist) is a class
    implementing the interface.
  - FPC: TOptNullXxx.Undefined/Null/From(...) answer the class, which fits
    every overload of Check; pass a typed variable.
  - FPC 3.2.2: a fractional literal used as a Currency value is converted to
    a near value (Range(0, 100000.5) gets 100000.4992, measured on Windows
    and Linux x86_64; gotcha 13). Write Currency bounds as typed constants
    (const MAX_PRICE: Currency = 100000.5) or whole numbers. }

interface

uses
  SysUtils,
  PascalCommon.Optionals;

const
  PC_VALIDATION_REQUIRED = 'required';
  PC_VALIDATION_TOO_SHORT = 'too_short';
  PC_VALIDATION_TOO_LONG = 'too_long';
  PC_VALIDATION_NOT_ALLOWED = 'not_allowed';
  PC_VALIDATION_BELOW_MINIMUM = 'below_minimum';
  PC_VALIDATION_ABOVE_MAXIMUM = 'above_maximum';
  PC_VALIDATION_OUT_OF_RANGE = 'out_of_range';
  PC_VALIDATION_NOT_MULTIPLE = 'not_multiple';
  PC_VALIDATION_TOO_MANY_DECIMALS = 'too_many_decimals';

type
  /// The texts of the built-in validators. Format placeholders, in order:
  /// the field ("%s") first, then the limits as text.
  TPcValidationMessages = record
    Required: string;         // field
    TooShort: string;         // field, minimum characters
    TooLong: string;          // field, maximum characters
    NotAllowed: string;       // field, the allowed values
    BelowMinimum: string;     // field, minimum
    AboveMaximum: string;     // field, maximum
    OutOfRange: string;       // field, minimum, maximum
    NotMultiple: string;      // field, step
    TooManyDecimals: string;  // field, decimals
    class function English: TPcValidationMessages; static;
    class function Portuguese: TPcValidationMessages; static;
    /// The messages in use. Assign once, at startup.
    class var Current: TPcValidationMessages;
  end;

  // Each validator answers '' when the value passes, else the error code,
  // with AMessage filled (AField in it).

  IPcStringValidator = interface
    ['{873ACDB6-0B16-46AA-A5E6-5DFF7BA54AE9}']
    function Check(const AField, AValue: string; out AMessage: string): string;
  end;

  IPcIntegerValidator = interface
    ['{A33BF67B-4BBB-4F1B-B39F-5649D3CA2F4A}']
    function Check(const AField: string; const AValue: Integer; out AMessage: string): string;
  end;

  IPcInt64Validator = interface
    ['{582F9ADA-7037-4CF6-8B01-EA920840D76D}']
    function Check(const AField: string; const AValue: Int64; out AMessage: string): string;
  end;

  IPcDoubleValidator = interface
    ['{FEA9F0F9-11C8-4FAC-98FE-C2B86DFC2625}']
    function Check(const AField: string; const AValue: Double; out AMessage: string): string;
  end;

  IPcCurrencyValidator = interface
    ['{B4E46AFE-E9CA-4C8C-8DF9-4305E2C4E98E}']
    function Check(const AField: string; const AValue: Currency; out AMessage: string): string;
  end;

  IPcDateTimeValidator = interface
    ['{149E7320-0E53-4268-A985-79D328DB6B5A}']
    function Check(const AField: string; const AValue: TDateTime; out AMessage: string): string;
  end;

  /// An application's rule as a plain function, for FromFunc: '' when AValue
  /// passes, else the error code with AMessage filled.
  TPcStringCheckFunc = function(const AField, AValue: string; out AMessage: string): string;
  TPcIntegerCheckFunc = function(const AField: string; const AValue: Integer; out AMessage: string): string;
  TPcInt64CheckFunc = function(const AField: string; const AValue: Int64; out AMessage: string): string;
  TPcDoubleCheckFunc = function(const AField: string; const AValue: Double; out AMessage: string): string;
  TPcCurrencyCheckFunc = function(const AField: string; const AValue: Currency; out AMessage: string): string;
  TPcDateTimeCheckFunc = function(const AField: string; const AValue: TDateTime; out AMessage: string): string;

  TPcStringValidators = class
  public
    /// Something besides blanks.
    class function Required: IPcStringValidator; static;
    /// At least AChars characters (code points).
    class function MinLength(AChars: Integer): IPcStringValidator; static;
    /// At most AChars characters (code points).
    class function MaxLength(AChars: Integer): IPcStringValidator; static;
    /// One of AValues, exactly (case-sensitive).
    class function OneOf(const AValues: array of string): IPcStringValidator; static;
    class function FromFunc(AFunc: TPcStringCheckFunc): IPcStringValidator; static;
    /// The validators in order; the first that fails answers.
    class function All(const AValidators: array of IPcStringValidator): IPcStringValidator; static;
  end;

  TPcIntegerValidators = class
  public
    class function Min(AMin: Integer): IPcIntegerValidator; static;
    class function Max(AMax: Integer): IPcIntegerValidator; static;
    class function Range(AMin, AMax: Integer): IPcIntegerValidator; static;
    /// A multiple of AStep (AStep > 0).
    class function MultipleOf(AStep: Integer): IPcIntegerValidator; static;
    class function FromFunc(AFunc: TPcIntegerCheckFunc): IPcIntegerValidator; static;
    class function All(const AValidators: array of IPcIntegerValidator): IPcIntegerValidator; static;
  end;

  TPcInt64Validators = class
  public
    class function Min(AMin: Int64): IPcInt64Validator; static;
    class function Max(AMax: Int64): IPcInt64Validator; static;
    class function Range(AMin, AMax: Int64): IPcInt64Validator; static;
    class function MultipleOf(AStep: Int64): IPcInt64Validator; static;
    class function FromFunc(AFunc: TPcInt64CheckFunc): IPcInt64Validator; static;
    class function All(const AValidators: array of IPcInt64Validator): IPcInt64Validator; static;
  end;

  TPcDoubleValidators = class
  public
    class function Min(AMin: Double): IPcDoubleValidator; static;
    class function Max(AMax: Double): IPcDoubleValidator; static;
    class function Range(AMin, AMax: Double): IPcDoubleValidator; static;
    class function FromFunc(AFunc: TPcDoubleCheckFunc): IPcDoubleValidator; static;
    class function All(const AValidators: array of IPcDoubleValidator): IPcDoubleValidator; static;
  end;

  TPcCurrencyValidators = class
  public
    class function Min(AMin: Currency): IPcCurrencyValidator; static;
    class function Max(AMax: Currency): IPcCurrencyValidator; static;
    class function Range(AMin, AMax: Currency): IPcCurrencyValidator; static;
    /// At most ADecimals decimal places (0 to 4), checked on Currency's exact
    /// 1/10000 units, never through floating point.
    class function MaxDecimals(ADecimals: Integer): IPcCurrencyValidator; static;
    class function FromFunc(AFunc: TPcCurrencyCheckFunc): IPcCurrencyValidator; static;
    class function All(const AValidators: array of IPcCurrencyValidator): IPcCurrencyValidator; static;
  end;

  TPcDateTimeValidators = class
  public
    class function Min(AMin: TDateTime): IPcDateTimeValidator; static;
    class function Max(AMax: TDateTime): IPcDateTimeValidator; static;
    class function Range(AMin, AMax: TDateTime): IPcDateTimeValidator; static;
    class function FromFunc(AFunc: TPcDateTimeCheckFunc): IPcDateTimeValidator; static;
    class function All(const AValidators: array of IPcDateTimeValidator): IPcDateTimeValidator; static;
  end;

  TPcFieldError = record
    Field: string;
    Code: string;
    Message: string;
  end;
  TPcFieldErrors = array of TPcFieldError;

  /// Every failing field of one validation. Message is the first one's.
  EPcValidationError = class(Exception)
  private
    FErrors: TPcFieldErrors;
  public
    constructor Create(const AErrors: TPcFieldErrors);
    property Errors: TPcFieldErrors read FErrors;
  end;

  /// Collects the failures of one validation; RaiseIfAny raises them
  /// together. A record: no Free, no try/finally.
  TPcValidation = record
  private
    FErrors: TPcFieldErrors;
    procedure Add(const AField, ACode, AMessage: string);
  public
    class function Create: TPcValidation; static;

    procedure Check(const AField: string; const AValue: string; AValidator: IPcStringValidator); overload;
    procedure Check(const AField: string; const AValue: IOptString; AValidator: IPcStringValidator); overload;
    procedure Check(const AField: string; const AValue: INullString; AValidator: IPcStringValidator); overload;
    procedure Check(const AField: string; const AValue: IOptNullString; AValidator: IPcStringValidator); overload;

    procedure Check(const AField: string; const AValue: Integer; AValidator: IPcIntegerValidator); overload;
    procedure Check(const AField: string; const AValue: IOptInteger; AValidator: IPcIntegerValidator); overload;
    procedure Check(const AField: string; const AValue: INullInteger; AValidator: IPcIntegerValidator); overload;
    procedure Check(const AField: string; const AValue: IOptNullInteger; AValidator: IPcIntegerValidator); overload;

    procedure Check(const AField: string; const AValue: Int64; AValidator: IPcInt64Validator); overload;
    procedure Check(const AField: string; const AValue: IOptInt64; AValidator: IPcInt64Validator); overload;
    procedure Check(const AField: string; const AValue: INullInt64; AValidator: IPcInt64Validator); overload;
    procedure Check(const AField: string; const AValue: IOptNullInt64; AValidator: IPcInt64Validator); overload;

    procedure Check(const AField: string; const AValue: Double; AValidator: IPcDoubleValidator); overload;
    procedure Check(const AField: string; const AValue: IOptDouble; AValidator: IPcDoubleValidator); overload;
    procedure Check(const AField: string; const AValue: INullDouble; AValidator: IPcDoubleValidator); overload;
    procedure Check(const AField: string; const AValue: IOptNullDouble; AValidator: IPcDoubleValidator); overload;

    procedure Check(const AField: string; const AValue: Currency; AValidator: IPcCurrencyValidator); overload;
    procedure Check(const AField: string; const AValue: IOptCurrency; AValidator: IPcCurrencyValidator); overload;
    procedure Check(const AField: string; const AValue: INullCurrency; AValidator: IPcCurrencyValidator); overload;
    procedure Check(const AField: string; const AValue: IOptNullCurrency; AValidator: IPcCurrencyValidator); overload;

    procedure Check(const AField: string; const AValue: TDateTime; AValidator: IPcDateTimeValidator); overload;
    procedure Check(const AField: string; const AValue: IOptDateTime; AValidator: IPcDateTimeValidator); overload;
    procedure Check(const AField: string; const AValue: INullDateTime; AValidator: IPcDateTimeValidator); overload;
    procedure Check(const AField: string; const AValue: IOptNullDateTime; AValidator: IPcDateTimeValidator); overload;

    /// A failure the validators can't express (one member against another).
    procedure Fail(const AField, ACode, AMessage: string);
    function HasFailed(const AField: string): Boolean;
    function IsValid: Boolean;
    function Errors: TPcFieldErrors;
    /// EPcValidationError with every failure; nothing when none.
    procedure RaiseIfAny;
  end;

implementation

uses
  PascalCommon.Text;

var
  GInvariant: TFormatSettings;

function Msg(const AFormat: string; const AArgs: array of const): string;
begin
  Result := Format(AFormat, AArgs);
end;

function FloatText(AValue: Double): string;
begin
  Result := FloatToStr(AValue, GInvariant);
end;

// Currency through its exact Int64 count of 1/10000, never floating point.
function CurrText(AValue: Currency): string;
var
  LUnits, LAbs: Int64;
  LFrac: string;
begin
  Move(AValue, LUnits, SizeOf(LUnits));
  LAbs := Abs(LUnits);
  Result := IntToStr(LAbs div 10000);
  LFrac := Format('%.4d', [LAbs mod 10000]);
  while (LFrac <> '') and (LFrac[Length(LFrac)] = '0') do
    Delete(LFrac, Length(LFrac), 1);
  if LFrac <> '' then
    Result := Result + '.' + LFrac;
  if LUnits < 0 then
    Result := '-' + Result;
end;

function DateText(AValue: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss', AValue);
end;

{ TPcValidationMessages }

class function TPcValidationMessages.English: TPcValidationMessages;
begin
  Result.Required := '"%s" is required.';
  Result.TooShort := '"%s" must have at least %s characters.';
  Result.TooLong := '"%s" must have at most %s characters.';
  Result.NotAllowed := '"%s" must be one of: %s.';
  Result.BelowMinimum := '"%s" must be at least %s.';
  Result.AboveMaximum := '"%s" must be at most %s.';
  Result.OutOfRange := '"%s" must be from %s to %s.';
  Result.NotMultiple := '"%s" must be a multiple of %s.';
  Result.TooManyDecimals := '"%s" can have at most %s decimal places.';
end;

class function TPcValidationMessages.Portuguese: TPcValidationMessages;
begin
  Result.Required := '"%s" é obrigatório.';
  Result.TooShort := '"%s" deve ter pelo menos %s caracteres.';
  Result.TooLong := '"%s" deve ter no máximo %s caracteres.';
  Result.NotAllowed := '"%s" deve ser um destes: %s.';
  Result.BelowMinimum := '"%s" deve ser no mínimo %s.';
  Result.AboveMaximum := '"%s" deve ser no máximo %s.';
  Result.OutOfRange := '"%s" deve estar entre %s e %s.';
  Result.NotMultiple := '"%s" deve ser múltiplo de %s.';
  Result.TooManyDecimals := '"%s" pode ter no máximo %s casas decimais.';
end;

{ string validators }

type
  TStringRequired = class(TInterfacedObject, IPcStringValidator)
    function Check(const AField, AValue: string; out AMessage: string): string;
  end;

  TStringLength = class(TInterfacedObject, IPcStringValidator)
  private
    FMin, FMax: Integer; // -1: none
  public
    constructor Create(AMin, AMax: Integer);
    function Check(const AField, AValue: string; out AMessage: string): string;
  end;

  TStringOneOf = class(TInterfacedObject, IPcStringValidator)
  private
    FValues: array of string;
  public
    constructor Create(const AValues: array of string);
    function Check(const AField, AValue: string; out AMessage: string): string;
  end;

  TStringFunc = class(TInterfacedObject, IPcStringValidator)
  private
    FFunc: TPcStringCheckFunc;
  public
    constructor Create(AFunc: TPcStringCheckFunc);
    function Check(const AField, AValue: string; out AMessage: string): string;
  end;

  TStringAll = class(TInterfacedObject, IPcStringValidator)
  private
    FItems: array of IPcStringValidator;
  public
    constructor Create(const AItems: array of IPcStringValidator);
    function Check(const AField, AValue: string; out AMessage: string): string;
  end;

function TStringRequired.Check(const AField, AValue: string; out AMessage: string): string;
begin
  Result := '';
  AMessage := '';
  if Trim(AValue) = '' then
  begin
    Result := PC_VALIDATION_REQUIRED;
    AMessage := Msg(TPcValidationMessages.Current.Required, [AField]);
  end;
end;

constructor TStringLength.Create(AMin, AMax: Integer);
begin
  inherited Create;
  FMin := AMin;
  FMax := AMax;
end;

function TStringLength.Check(const AField, AValue: string; out AMessage: string): string;
var
  LCount: Integer;
begin
  Result := '';
  AMessage := '';
  LCount := PcCharCount(AValue);
  if (FMin >= 0) and (LCount < FMin) then
  begin
    Result := PC_VALIDATION_TOO_SHORT;
    AMessage := Msg(TPcValidationMessages.Current.TooShort, [AField, IntToStr(FMin)]);
  end
  else if (FMax >= 0) and (LCount > FMax) then
  begin
    Result := PC_VALIDATION_TOO_LONG;
    AMessage := Msg(TPcValidationMessages.Current.TooLong, [AField, IntToStr(FMax)]);
  end;
end;

constructor TStringOneOf.Create(const AValues: array of string);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FValues, Length(AValues));
  for I := 0 to High(AValues) do
    FValues[I] := AValues[I];
end;

function TStringOneOf.Check(const AField, AValue: string; out AMessage: string): string;
var
  I: Integer;
  LList: string;
begin
  Result := '';
  AMessage := '';
  for I := 0 to High(FValues) do
    if FValues[I] = AValue then
      Exit;
  LList := '';
  for I := 0 to High(FValues) do
  begin
    if I > 0 then
      LList := LList + ', ';
    LList := LList + FValues[I];
  end;
  Result := PC_VALIDATION_NOT_ALLOWED;
  AMessage := Msg(TPcValidationMessages.Current.NotAllowed, [AField, LList]);
end;

constructor TStringFunc.Create(AFunc: TPcStringCheckFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TStringFunc.Check(const AField, AValue: string; out AMessage: string): string;
begin
  AMessage := '';
  Result := FFunc(AField, AValue, AMessage);
end;

constructor TStringAll.Create(const AItems: array of IPcStringValidator);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(AItems));
  for I := 0 to High(AItems) do
    FItems[I] := AItems[I];
end;

function TStringAll.Check(const AField, AValue: string; out AMessage: string): string;
var
  I: Integer;
begin
  Result := '';
  AMessage := '';
  for I := 0 to High(FItems) do
  begin
    Result := FItems[I].Check(AField, AValue, AMessage);
    if Result <> '' then
      Exit;
  end;
end;

class function TPcStringValidators.Required: IPcStringValidator;
begin
  Result := TStringRequired.Create;
end;

class function TPcStringValidators.MinLength(AChars: Integer): IPcStringValidator;
begin
  Result := TStringLength.Create(AChars, -1);
end;

class function TPcStringValidators.MaxLength(AChars: Integer): IPcStringValidator;
begin
  Result := TStringLength.Create(-1, AChars);
end;

class function TPcStringValidators.OneOf(const AValues: array of string): IPcStringValidator;
begin
  if Length(AValues) = 0 then
    raise EArgumentException.Create('TPcStringValidators.OneOf: no values');
  Result := TStringOneOf.Create(AValues);
end;

class function TPcStringValidators.FromFunc(AFunc: TPcStringCheckFunc): IPcStringValidator;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcStringValidators.FromFunc: AFunc is nil');
  Result := TStringFunc.Create(AFunc);
end;

class function TPcStringValidators.All(const AValidators: array of IPcStringValidator): IPcStringValidator;
var
  I: Integer;
begin
  for I := 0 to High(AValidators) do
    if not Assigned(AValidators[I]) then
      raise EArgumentException.CreateFmt('TPcStringValidators.All: item %d is nil', [I]);
  Result := TStringAll.Create(AValidators);
end;

{ Integer and Int64 validators (Int64 inside: an Integer widens exactly) }

type
  TInt64Bounds = class(TInterfacedObject, IPcIntegerValidator, IPcInt64Validator)
  private
    FHasMin, FHasMax: Boolean;
    FMin, FMax: Int64;
    function CheckValue(const AField: string; AValue: Int64; out AMessage: string): string;
  public
    constructor Create(AHasMin: Boolean; AMin: Int64; AHasMax: Boolean; AMax: Int64);
    function Check(const AField: string; const AValue: Integer; out AMessage: string): string; overload;
    function Check(const AField: string; const AValue: Int64; out AMessage: string): string; overload;
  end;

  TInt64Multiple = class(TInterfacedObject, IPcIntegerValidator, IPcInt64Validator)
  private
    FStep: Int64;
    function CheckValue(const AField: string; AValue: Int64; out AMessage: string): string;
  public
    constructor Create(AStep: Int64);
    function Check(const AField: string; const AValue: Integer; out AMessage: string): string; overload;
    function Check(const AField: string; const AValue: Int64; out AMessage: string): string; overload;
  end;

  TIntegerFunc = class(TInterfacedObject, IPcIntegerValidator)
  private
    FFunc: TPcIntegerCheckFunc;
  public
    constructor Create(AFunc: TPcIntegerCheckFunc);
    function Check(const AField: string; const AValue: Integer; out AMessage: string): string;
  end;

  TIntegerAll = class(TInterfacedObject, IPcIntegerValidator)
  private
    FItems: array of IPcIntegerValidator;
  public
    constructor Create(const AItems: array of IPcIntegerValidator);
    function Check(const AField: string; const AValue: Integer; out AMessage: string): string;
  end;

  TInt64Func = class(TInterfacedObject, IPcInt64Validator)
  private
    FFunc: TPcInt64CheckFunc;
  public
    constructor Create(AFunc: TPcInt64CheckFunc);
    function Check(const AField: string; const AValue: Int64; out AMessage: string): string;
  end;

  TInt64All = class(TInterfacedObject, IPcInt64Validator)
  private
    FItems: array of IPcInt64Validator;
  public
    constructor Create(const AItems: array of IPcInt64Validator);
    function Check(const AField: string; const AValue: Int64; out AMessage: string): string;
  end;

constructor TInt64Bounds.Create(AHasMin: Boolean; AMin: Int64; AHasMax: Boolean; AMax: Int64);
begin
  inherited Create;
  FHasMin := AHasMin;
  FMin := AMin;
  FHasMax := AHasMax;
  FMax := AMax;
end;

function TInt64Bounds.CheckValue(const AField: string; AValue: Int64; out AMessage: string): string;
begin
  Result := '';
  AMessage := '';
  if (FHasMin and (AValue < FMin)) or (FHasMax and (AValue > FMax)) then
  begin
    if FHasMin and FHasMax then
    begin
      Result := PC_VALIDATION_OUT_OF_RANGE;
      AMessage := Msg(TPcValidationMessages.Current.OutOfRange,
        [AField, IntToStr(FMin), IntToStr(FMax)]);
    end
    else if FHasMin then
    begin
      Result := PC_VALIDATION_BELOW_MINIMUM;
      AMessage := Msg(TPcValidationMessages.Current.BelowMinimum, [AField, IntToStr(FMin)]);
    end
    else
    begin
      Result := PC_VALIDATION_ABOVE_MAXIMUM;
      AMessage := Msg(TPcValidationMessages.Current.AboveMaximum, [AField, IntToStr(FMax)]);
    end;
  end;
end;

function TInt64Bounds.Check(const AField: string; const AValue: Integer; out AMessage: string): string;
begin
  Result := CheckValue(AField, AValue, AMessage);
end;

function TInt64Bounds.Check(const AField: string; const AValue: Int64; out AMessage: string): string;
begin
  Result := CheckValue(AField, AValue, AMessage);
end;

constructor TInt64Multiple.Create(AStep: Int64);
begin
  inherited Create;
  FStep := AStep;
end;

function TInt64Multiple.CheckValue(const AField: string; AValue: Int64; out AMessage: string): string;
begin
  Result := '';
  AMessage := '';
  if AValue mod FStep <> 0 then
  begin
    Result := PC_VALIDATION_NOT_MULTIPLE;
    AMessage := Msg(TPcValidationMessages.Current.NotMultiple, [AField, IntToStr(FStep)]);
  end;
end;

function TInt64Multiple.Check(const AField: string; const AValue: Integer; out AMessage: string): string;
begin
  Result := CheckValue(AField, AValue, AMessage);
end;

function TInt64Multiple.Check(const AField: string; const AValue: Int64; out AMessage: string): string;
begin
  Result := CheckValue(AField, AValue, AMessage);
end;

constructor TIntegerFunc.Create(AFunc: TPcIntegerCheckFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TIntegerFunc.Check(const AField: string; const AValue: Integer; out AMessage: string): string;
begin
  AMessage := '';
  Result := FFunc(AField, AValue, AMessage);
end;

constructor TIntegerAll.Create(const AItems: array of IPcIntegerValidator);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(AItems));
  for I := 0 to High(AItems) do
    FItems[I] := AItems[I];
end;

function TIntegerAll.Check(const AField: string; const AValue: Integer; out AMessage: string): string;
var
  I: Integer;
begin
  Result := '';
  AMessage := '';
  for I := 0 to High(FItems) do
  begin
    Result := FItems[I].Check(AField, AValue, AMessage);
    if Result <> '' then
      Exit;
  end;
end;

constructor TInt64Func.Create(AFunc: TPcInt64CheckFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TInt64Func.Check(const AField: string; const AValue: Int64; out AMessage: string): string;
begin
  AMessage := '';
  Result := FFunc(AField, AValue, AMessage);
end;

constructor TInt64All.Create(const AItems: array of IPcInt64Validator);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(AItems));
  for I := 0 to High(AItems) do
    FItems[I] := AItems[I];
end;

function TInt64All.Check(const AField: string; const AValue: Int64; out AMessage: string): string;
var
  I: Integer;
begin
  Result := '';
  AMessage := '';
  for I := 0 to High(FItems) do
  begin
    Result := FItems[I].Check(AField, AValue, AMessage);
    if Result <> '' then
      Exit;
  end;
end;

class function TPcIntegerValidators.Min(AMin: Integer): IPcIntegerValidator;
begin
  Result := TInt64Bounds.Create(True, AMin, False, 0);
end;

class function TPcIntegerValidators.Max(AMax: Integer): IPcIntegerValidator;
begin
  Result := TInt64Bounds.Create(False, 0, True, AMax);
end;

class function TPcIntegerValidators.Range(AMin, AMax: Integer): IPcIntegerValidator;
begin
  if AMin > AMax then
    raise EArgumentException.Create('TPcIntegerValidators.Range: AMin > AMax');
  Result := TInt64Bounds.Create(True, AMin, True, AMax);
end;

class function TPcIntegerValidators.MultipleOf(AStep: Integer): IPcIntegerValidator;
begin
  if AStep <= 0 then
    raise EArgumentException.Create('TPcIntegerValidators.MultipleOf: AStep must be > 0');
  Result := TInt64Multiple.Create(AStep);
end;

class function TPcIntegerValidators.FromFunc(AFunc: TPcIntegerCheckFunc): IPcIntegerValidator;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcIntegerValidators.FromFunc: AFunc is nil');
  Result := TIntegerFunc.Create(AFunc);
end;

class function TPcIntegerValidators.All(const AValidators: array of IPcIntegerValidator): IPcIntegerValidator;
var
  I: Integer;
begin
  for I := 0 to High(AValidators) do
    if not Assigned(AValidators[I]) then
      raise EArgumentException.CreateFmt('TPcIntegerValidators.All: item %d is nil', [I]);
  Result := TIntegerAll.Create(AValidators);
end;

class function TPcInt64Validators.Min(AMin: Int64): IPcInt64Validator;
begin
  Result := TInt64Bounds.Create(True, AMin, False, 0);
end;

class function TPcInt64Validators.Max(AMax: Int64): IPcInt64Validator;
begin
  Result := TInt64Bounds.Create(False, 0, True, AMax);
end;

class function TPcInt64Validators.Range(AMin, AMax: Int64): IPcInt64Validator;
begin
  if AMin > AMax then
    raise EArgumentException.Create('TPcInt64Validators.Range: AMin > AMax');
  Result := TInt64Bounds.Create(True, AMin, True, AMax);
end;

class function TPcInt64Validators.MultipleOf(AStep: Int64): IPcInt64Validator;
begin
  if AStep <= 0 then
    raise EArgumentException.Create('TPcInt64Validators.MultipleOf: AStep must be > 0');
  Result := TInt64Multiple.Create(AStep);
end;

class function TPcInt64Validators.FromFunc(AFunc: TPcInt64CheckFunc): IPcInt64Validator;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcInt64Validators.FromFunc: AFunc is nil');
  Result := TInt64Func.Create(AFunc);
end;

class function TPcInt64Validators.All(const AValidators: array of IPcInt64Validator): IPcInt64Validator;
var
  I: Integer;
begin
  for I := 0 to High(AValidators) do
    if not Assigned(AValidators[I]) then
      raise EArgumentException.CreateFmt('TPcInt64Validators.All: item %d is nil', [I]);
  Result := TInt64All.Create(AValidators);
end;

{ Double validators }

type
  TDoubleBounds = class(TInterfacedObject, IPcDoubleValidator)
  private
    FHasMin, FHasMax: Boolean;
    FMin, FMax: Double;
  public
    constructor Create(AHasMin: Boolean; AMin: Double; AHasMax: Boolean; AMax: Double);
    function Check(const AField: string; const AValue: Double; out AMessage: string): string;
  end;

  TDoubleFunc = class(TInterfacedObject, IPcDoubleValidator)
  private
    FFunc: TPcDoubleCheckFunc;
  public
    constructor Create(AFunc: TPcDoubleCheckFunc);
    function Check(const AField: string; const AValue: Double; out AMessage: string): string;
  end;

  TDoubleAll = class(TInterfacedObject, IPcDoubleValidator)
  private
    FItems: array of IPcDoubleValidator;
  public
    constructor Create(const AItems: array of IPcDoubleValidator);
    function Check(const AField: string; const AValue: Double; out AMessage: string): string;
  end;

constructor TDoubleBounds.Create(AHasMin: Boolean; AMin: Double; AHasMax: Boolean; AMax: Double);
begin
  inherited Create;
  FHasMin := AHasMin;
  FMin := AMin;
  FHasMax := AHasMax;
  FMax := AMax;
end;

function TDoubleBounds.Check(const AField: string; const AValue: Double; out AMessage: string): string;
begin
  Result := '';
  AMessage := '';
  if (FHasMin and (AValue < FMin)) or (FHasMax and (AValue > FMax)) then
  begin
    if FHasMin and FHasMax then
    begin
      Result := PC_VALIDATION_OUT_OF_RANGE;
      AMessage := Msg(TPcValidationMessages.Current.OutOfRange,
        [AField, FloatText(FMin), FloatText(FMax)]);
    end
    else if FHasMin then
    begin
      Result := PC_VALIDATION_BELOW_MINIMUM;
      AMessage := Msg(TPcValidationMessages.Current.BelowMinimum, [AField, FloatText(FMin)]);
    end
    else
    begin
      Result := PC_VALIDATION_ABOVE_MAXIMUM;
      AMessage := Msg(TPcValidationMessages.Current.AboveMaximum, [AField, FloatText(FMax)]);
    end;
  end;
end;

constructor TDoubleFunc.Create(AFunc: TPcDoubleCheckFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TDoubleFunc.Check(const AField: string; const AValue: Double; out AMessage: string): string;
begin
  AMessage := '';
  Result := FFunc(AField, AValue, AMessage);
end;

constructor TDoubleAll.Create(const AItems: array of IPcDoubleValidator);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(AItems));
  for I := 0 to High(AItems) do
    FItems[I] := AItems[I];
end;

function TDoubleAll.Check(const AField: string; const AValue: Double; out AMessage: string): string;
var
  I: Integer;
begin
  Result := '';
  AMessage := '';
  for I := 0 to High(FItems) do
  begin
    Result := FItems[I].Check(AField, AValue, AMessage);
    if Result <> '' then
      Exit;
  end;
end;

class function TPcDoubleValidators.Min(AMin: Double): IPcDoubleValidator;
begin
  Result := TDoubleBounds.Create(True, AMin, False, 0);
end;

class function TPcDoubleValidators.Max(AMax: Double): IPcDoubleValidator;
begin
  Result := TDoubleBounds.Create(False, 0, True, AMax);
end;

class function TPcDoubleValidators.Range(AMin, AMax: Double): IPcDoubleValidator;
begin
  if AMin > AMax then
    raise EArgumentException.Create('TPcDoubleValidators.Range: AMin > AMax');
  Result := TDoubleBounds.Create(True, AMin, True, AMax);
end;

class function TPcDoubleValidators.FromFunc(AFunc: TPcDoubleCheckFunc): IPcDoubleValidator;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcDoubleValidators.FromFunc: AFunc is nil');
  Result := TDoubleFunc.Create(AFunc);
end;

class function TPcDoubleValidators.All(const AValidators: array of IPcDoubleValidator): IPcDoubleValidator;
var
  I: Integer;
begin
  for I := 0 to High(AValidators) do
    if not Assigned(AValidators[I]) then
      raise EArgumentException.CreateFmt('TPcDoubleValidators.All: item %d is nil', [I]);
  Result := TDoubleAll.Create(AValidators);
end;

{ Currency validators: on the exact Int64 units }

type
  TCurrencyBounds = class(TInterfacedObject, IPcCurrencyValidator)
  private
    FHasMin, FHasMax: Boolean;
    FMin, FMax: Currency;
  public
    constructor Create(AHasMin: Boolean; AMin: Currency; AHasMax: Boolean; AMax: Currency);
    function Check(const AField: string; const AValue: Currency; out AMessage: string): string;
  end;

  TCurrencyDecimals = class(TInterfacedObject, IPcCurrencyValidator)
  private
    FDecimals: Integer;
    FUnit: Int64; // 10^(4 - decimals)
  public
    constructor Create(ADecimals: Integer);
    function Check(const AField: string; const AValue: Currency; out AMessage: string): string;
  end;

  TCurrencyFunc = class(TInterfacedObject, IPcCurrencyValidator)
  private
    FFunc: TPcCurrencyCheckFunc;
  public
    constructor Create(AFunc: TPcCurrencyCheckFunc);
    function Check(const AField: string; const AValue: Currency; out AMessage: string): string;
  end;

  TCurrencyAll = class(TInterfacedObject, IPcCurrencyValidator)
  private
    FItems: array of IPcCurrencyValidator;
  public
    constructor Create(const AItems: array of IPcCurrencyValidator);
    function Check(const AField: string; const AValue: Currency; out AMessage: string): string;
  end;

constructor TCurrencyBounds.Create(AHasMin: Boolean; AMin: Currency; AHasMax: Boolean;
  AMax: Currency);
begin
  inherited Create;
  FHasMin := AHasMin;
  FMin := AMin;
  FHasMax := AHasMax;
  FMax := AMax;
end;

function TCurrencyBounds.Check(const AField: string; const AValue: Currency;
  out AMessage: string): string;
begin
  Result := '';
  AMessage := '';
  if (FHasMin and (AValue < FMin)) or (FHasMax and (AValue > FMax)) then
  begin
    if FHasMin and FHasMax then
    begin
      Result := PC_VALIDATION_OUT_OF_RANGE;
      AMessage := Msg(TPcValidationMessages.Current.OutOfRange,
        [AField, CurrText(FMin), CurrText(FMax)]);
    end
    else if FHasMin then
    begin
      Result := PC_VALIDATION_BELOW_MINIMUM;
      AMessage := Msg(TPcValidationMessages.Current.BelowMinimum, [AField, CurrText(FMin)]);
    end
    else
    begin
      Result := PC_VALIDATION_ABOVE_MAXIMUM;
      AMessage := Msg(TPcValidationMessages.Current.AboveMaximum, [AField, CurrText(FMax)]);
    end;
  end;
end;

constructor TCurrencyDecimals.Create(ADecimals: Integer);
var
  I: Integer;
begin
  inherited Create;
  FDecimals := ADecimals;
  FUnit := 1;
  for I := 1 to 4 - ADecimals do
    FUnit := FUnit * 10;
end;

function TCurrencyDecimals.Check(const AField: string; const AValue: Currency;
  out AMessage: string): string;
var
  LUnits: Int64;
begin
  Result := '';
  AMessage := '';
  Move(AValue, LUnits, SizeOf(LUnits));
  if LUnits mod FUnit <> 0 then
  begin
    Result := PC_VALIDATION_TOO_MANY_DECIMALS;
    AMessage := Msg(TPcValidationMessages.Current.TooManyDecimals,
      [AField, IntToStr(FDecimals)]);
  end;
end;

constructor TCurrencyFunc.Create(AFunc: TPcCurrencyCheckFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TCurrencyFunc.Check(const AField: string; const AValue: Currency;
  out AMessage: string): string;
begin
  AMessage := '';
  Result := FFunc(AField, AValue, AMessage);
end;

constructor TCurrencyAll.Create(const AItems: array of IPcCurrencyValidator);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(AItems));
  for I := 0 to High(AItems) do
    FItems[I] := AItems[I];
end;

function TCurrencyAll.Check(const AField: string; const AValue: Currency;
  out AMessage: string): string;
var
  I: Integer;
begin
  Result := '';
  AMessage := '';
  for I := 0 to High(FItems) do
  begin
    Result := FItems[I].Check(AField, AValue, AMessage);
    if Result <> '' then
      Exit;
  end;
end;

class function TPcCurrencyValidators.Min(AMin: Currency): IPcCurrencyValidator;
begin
  Result := TCurrencyBounds.Create(True, AMin, False, 0);
end;

class function TPcCurrencyValidators.Max(AMax: Currency): IPcCurrencyValidator;
begin
  Result := TCurrencyBounds.Create(False, 0, True, AMax);
end;

class function TPcCurrencyValidators.Range(AMin, AMax: Currency): IPcCurrencyValidator;
begin
  if AMin > AMax then
    raise EArgumentException.Create('TPcCurrencyValidators.Range: AMin > AMax');
  Result := TCurrencyBounds.Create(True, AMin, True, AMax);
end;

class function TPcCurrencyValidators.MaxDecimals(ADecimals: Integer): IPcCurrencyValidator;
begin
  if (ADecimals < 0) or (ADecimals > 4) then
    raise EArgumentException.Create('TPcCurrencyValidators.MaxDecimals: 0 to 4');
  Result := TCurrencyDecimals.Create(ADecimals);
end;

class function TPcCurrencyValidators.FromFunc(AFunc: TPcCurrencyCheckFunc): IPcCurrencyValidator;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcCurrencyValidators.FromFunc: AFunc is nil');
  Result := TCurrencyFunc.Create(AFunc);
end;

class function TPcCurrencyValidators.All(const AValidators: array of IPcCurrencyValidator): IPcCurrencyValidator;
var
  I: Integer;
begin
  for I := 0 to High(AValidators) do
    if not Assigned(AValidators[I]) then
      raise EArgumentException.CreateFmt('TPcCurrencyValidators.All: item %d is nil', [I]);
  Result := TCurrencyAll.Create(AValidators);
end;

{ TDateTime validators }

type
  TDateTimeBounds = class(TInterfacedObject, IPcDateTimeValidator)
  private
    FHasMin, FHasMax: Boolean;
    FMin, FMax: TDateTime;
  public
    constructor Create(AHasMin: Boolean; AMin: TDateTime; AHasMax: Boolean; AMax: TDateTime);
    function Check(const AField: string; const AValue: TDateTime; out AMessage: string): string;
  end;

  TDateTimeFunc = class(TInterfacedObject, IPcDateTimeValidator)
  private
    FFunc: TPcDateTimeCheckFunc;
  public
    constructor Create(AFunc: TPcDateTimeCheckFunc);
    function Check(const AField: string; const AValue: TDateTime; out AMessage: string): string;
  end;

  TDateTimeAll = class(TInterfacedObject, IPcDateTimeValidator)
  private
    FItems: array of IPcDateTimeValidator;
  public
    constructor Create(const AItems: array of IPcDateTimeValidator);
    function Check(const AField: string; const AValue: TDateTime; out AMessage: string): string;
  end;

constructor TDateTimeBounds.Create(AHasMin: Boolean; AMin: TDateTime; AHasMax: Boolean;
  AMax: TDateTime);
begin
  inherited Create;
  FHasMin := AHasMin;
  FMin := AMin;
  FHasMax := AHasMax;
  FMax := AMax;
end;

function TDateTimeBounds.Check(const AField: string; const AValue: TDateTime;
  out AMessage: string): string;
begin
  Result := '';
  AMessage := '';
  if (FHasMin and (AValue < FMin)) or (FHasMax and (AValue > FMax)) then
  begin
    if FHasMin and FHasMax then
    begin
      Result := PC_VALIDATION_OUT_OF_RANGE;
      AMessage := Msg(TPcValidationMessages.Current.OutOfRange,
        [AField, DateText(FMin), DateText(FMax)]);
    end
    else if FHasMin then
    begin
      Result := PC_VALIDATION_BELOW_MINIMUM;
      AMessage := Msg(TPcValidationMessages.Current.BelowMinimum, [AField, DateText(FMin)]);
    end
    else
    begin
      Result := PC_VALIDATION_ABOVE_MAXIMUM;
      AMessage := Msg(TPcValidationMessages.Current.AboveMaximum, [AField, DateText(FMax)]);
    end;
  end;
end;

constructor TDateTimeFunc.Create(AFunc: TPcDateTimeCheckFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TDateTimeFunc.Check(const AField: string; const AValue: TDateTime;
  out AMessage: string): string;
begin
  AMessage := '';
  Result := FFunc(AField, AValue, AMessage);
end;

constructor TDateTimeAll.Create(const AItems: array of IPcDateTimeValidator);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(AItems));
  for I := 0 to High(AItems) do
    FItems[I] := AItems[I];
end;

function TDateTimeAll.Check(const AField: string; const AValue: TDateTime;
  out AMessage: string): string;
var
  I: Integer;
begin
  Result := '';
  AMessage := '';
  for I := 0 to High(FItems) do
  begin
    Result := FItems[I].Check(AField, AValue, AMessage);
    if Result <> '' then
      Exit;
  end;
end;

class function TPcDateTimeValidators.Min(AMin: TDateTime): IPcDateTimeValidator;
begin
  Result := TDateTimeBounds.Create(True, AMin, False, 0);
end;

class function TPcDateTimeValidators.Max(AMax: TDateTime): IPcDateTimeValidator;
begin
  Result := TDateTimeBounds.Create(False, 0, True, AMax);
end;

class function TPcDateTimeValidators.Range(AMin, AMax: TDateTime): IPcDateTimeValidator;
begin
  if AMin > AMax then
    raise EArgumentException.Create('TPcDateTimeValidators.Range: AMin > AMax');
  Result := TDateTimeBounds.Create(True, AMin, True, AMax);
end;

class function TPcDateTimeValidators.FromFunc(AFunc: TPcDateTimeCheckFunc): IPcDateTimeValidator;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcDateTimeValidators.FromFunc: AFunc is nil');
  Result := TDateTimeFunc.Create(AFunc);
end;

class function TPcDateTimeValidators.All(const AValidators: array of IPcDateTimeValidator): IPcDateTimeValidator;
var
  I: Integer;
begin
  for I := 0 to High(AValidators) do
    if not Assigned(AValidators[I]) then
      raise EArgumentException.CreateFmt('TPcDateTimeValidators.All: item %d is nil', [I]);
  Result := TDateTimeAll.Create(AValidators);
end;

{ EPcValidationError }

constructor EPcValidationError.Create(const AErrors: TPcFieldErrors);
begin
  if Length(AErrors) > 0 then
    inherited Create(AErrors[0].Message)
  else
    inherited Create('Validation failed.');
  FErrors := Copy(AErrors, 0, Length(AErrors));
end;

{ TPcValidation }

class function TPcValidation.Create: TPcValidation;
begin
  Result.FErrors := nil;
end;

procedure TPcValidation.Add(const AField, ACode, AMessage: string);
begin
  SetLength(FErrors, Length(FErrors) + 1);
  FErrors[High(FErrors)].Field := AField;
  FErrors[High(FErrors)].Code := ACode;
  FErrors[High(FErrors)].Message := AMessage;
end;

function TPcValidation.HasFailed(const AField: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FErrors) do
    if FErrors[I].Field = AField then
      Exit(True);
  Result := False;
end;

procedure TPcValidation.Fail(const AField, ACode, AMessage: string);
begin
  if not HasFailed(AField) then
    Add(AField, ACode, AMessage);
end;

function TPcValidation.IsValid: Boolean;
begin
  Result := Length(FErrors) = 0;
end;

function TPcValidation.Errors: TPcFieldErrors;
begin
  Result := Copy(FErrors, 0, Length(FErrors));
end;

procedure TPcValidation.RaiseIfAny;
begin
  if Length(FErrors) > 0 then
    raise EPcValidationError.Create(FErrors);
end;

procedure TPcValidation.Check(const AField: string; const AValue: string;
  AValidator: IPcStringValidator);
var
  LCode, LMessage: string;
begin
  if HasFailed(AField) then
    Exit;
  LCode := AValidator.Check(AField, AValue, LMessage);
  if LCode <> '' then
    Fail(AField, LCode, LMessage);
end;

procedure TPcValidation.Check(const AField: string; const AValue: IOptString;
  AValidator: IPcStringValidator);
begin
  if Assigned(AValue) and AValue.HasValue then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: INullString;
  AValidator: IPcStringValidator);
begin
  if Assigned(AValue) and not AValue.IsNull then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: IOptNullString;
  AValidator: IPcStringValidator);
begin
  if Assigned(AValue) and AValue.HasValue and not AValue.IsNull then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: Integer;
  AValidator: IPcIntegerValidator);
var
  LCode, LMessage: string;
begin
  if HasFailed(AField) then
    Exit;
  LCode := AValidator.Check(AField, AValue, LMessage);
  if LCode <> '' then
    Fail(AField, LCode, LMessage);
end;

procedure TPcValidation.Check(const AField: string; const AValue: IOptInteger;
  AValidator: IPcIntegerValidator);
begin
  if Assigned(AValue) and AValue.HasValue then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: INullInteger;
  AValidator: IPcIntegerValidator);
begin
  if Assigned(AValue) and not AValue.IsNull then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: IOptNullInteger;
  AValidator: IPcIntegerValidator);
begin
  if Assigned(AValue) and AValue.HasValue and not AValue.IsNull then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: Int64;
  AValidator: IPcInt64Validator);
var
  LCode, LMessage: string;
begin
  if HasFailed(AField) then
    Exit;
  LCode := AValidator.Check(AField, AValue, LMessage);
  if LCode <> '' then
    Fail(AField, LCode, LMessage);
end;

procedure TPcValidation.Check(const AField: string; const AValue: IOptInt64;
  AValidator: IPcInt64Validator);
begin
  if Assigned(AValue) and AValue.HasValue then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: INullInt64;
  AValidator: IPcInt64Validator);
begin
  if Assigned(AValue) and not AValue.IsNull then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: IOptNullInt64;
  AValidator: IPcInt64Validator);
begin
  if Assigned(AValue) and AValue.HasValue and not AValue.IsNull then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: Double;
  AValidator: IPcDoubleValidator);
var
  LCode, LMessage: string;
begin
  if HasFailed(AField) then
    Exit;
  LCode := AValidator.Check(AField, AValue, LMessage);
  if LCode <> '' then
    Fail(AField, LCode, LMessage);
end;

procedure TPcValidation.Check(const AField: string; const AValue: IOptDouble;
  AValidator: IPcDoubleValidator);
begin
  if Assigned(AValue) and AValue.HasValue then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: INullDouble;
  AValidator: IPcDoubleValidator);
begin
  if Assigned(AValue) and not AValue.IsNull then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: IOptNullDouble;
  AValidator: IPcDoubleValidator);
begin
  if Assigned(AValue) and AValue.HasValue and not AValue.IsNull then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: Currency;
  AValidator: IPcCurrencyValidator);
var
  LCode, LMessage: string;
begin
  if HasFailed(AField) then
    Exit;
  LCode := AValidator.Check(AField, AValue, LMessage);
  if LCode <> '' then
    Fail(AField, LCode, LMessage);
end;

procedure TPcValidation.Check(const AField: string; const AValue: IOptCurrency;
  AValidator: IPcCurrencyValidator);
begin
  if Assigned(AValue) and AValue.HasValue then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: INullCurrency;
  AValidator: IPcCurrencyValidator);
begin
  if Assigned(AValue) and not AValue.IsNull then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: IOptNullCurrency;
  AValidator: IPcCurrencyValidator);
begin
  if Assigned(AValue) and AValue.HasValue and not AValue.IsNull then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: TDateTime;
  AValidator: IPcDateTimeValidator);
var
  LCode, LMessage: string;
begin
  if HasFailed(AField) then
    Exit;
  LCode := AValidator.Check(AField, AValue, LMessage);
  if LCode <> '' then
    Fail(AField, LCode, LMessage);
end;

procedure TPcValidation.Check(const AField: string; const AValue: IOptDateTime;
  AValidator: IPcDateTimeValidator);
begin
  if Assigned(AValue) and AValue.HasValue then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: INullDateTime;
  AValidator: IPcDateTimeValidator);
begin
  if Assigned(AValue) and not AValue.IsNull then
    Check(AField, AValue.Value, AValidator);
end;

procedure TPcValidation.Check(const AField: string; const AValue: IOptNullDateTime;
  AValidator: IPcDateTimeValidator);
begin
  if Assigned(AValue) and AValue.HasValue and not AValue.IsNull then
    Check(AField, AValue.Value, AValidator);
end;

initialization
  GInvariant := FormatSettings;
  GInvariant.DecimalSeparator := '.';
  GInvariant.ThousandSeparator := ',';
  TPcValidationMessages.Current := TPcValidationMessages.English;

end.
