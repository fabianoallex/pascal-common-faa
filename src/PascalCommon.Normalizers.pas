unit PascalCommon.Normalizers;

{$I pascalcommon.inc}

{ Value normalizers that don't depend on the optionals: one function type
  and one normalizer interface per type (TPcStringFunc/IPcStringNormalizer,
  TPcIntegerFunc/IPcIntegerNormalizer...), and one factory class per type
  (TPcStringNormalizers, TPcIntegerNormalizers...), so the editor's
  completion lists the normalizers under one name.

  The same normalizer serves a plain value and an optional:

    S := TNorm.Cep.Apply(Edit1.Text);          // this unit only
    LCep := LDto.Cep.Normalize(TNorm.Cep);     // with PascalCommon.Optionals

  Why a unit of its own (1.14.0): the types and factories were born with the
  optionals (1.12.0 and 1.13.0), but nothing in them needs one, and code that
  only wanted to clean a string had to bring in the optionals, their cache
  and ClockCache. The dependency now goes one way: Text <- Normalizers <-
  Optionals. PascalCommon.Optionals keeps the type names as aliases (the
  same types, not copies), so code written for 1.12 that uses only it builds
  unchanged. The 1.13 unit PascalCommon.Optionals.Normalizers was removed
  instead of kept as aliases: it had no consumer outside the author's
  pascal-api-infra-faa sample, migrated in the same change (CHANGELOG).

  Layers: the logic of a ready-made normalizer lives in a plain function
  (PcUpperCase in PascalCommon.Text), callable without an object, and the
  normalizer only wraps it, so there is one copy of each rule.

  An application inherits a factory and adds its own normalizers as class
  functions; its normalizers and the library's then show up under one name,
  and the classes behind them stay in the application's implementation
  section (README, "One place for your normalizers"):

    TNorm = class(TPcStringNormalizers)
    public
      class function Cep: IPcStringNormalizer; static;
    end;
    ...
    Result := Chain([Trim, FromFunc(OnlyDigits), MaxLength(8)]);

  Inheritance rather than a class helper: Delphi and FPC 3.2 see one helper
  per type, so two units with helpers for the same class would hide each
  other. A library on top of this one can have its own factory that
  inherits this one, and the application can inherit that library's.

  What belongs here: generic transformations only (case, blanks, length,
  digits, rounding, a date without its time), and only once a second library
  or a measured case asks for one, as everything in pascal-common-faa.
  Business rules (a CEP, a CPF, a phone number) belong in the application's
  factory. Today every factory has FromFunc and Chain, and the string one
  also has Trim, Upper, Lower and (1.20.0) FoldForSearch.

  The per-type code is written from one template (FPC 3.2.2 has no generic
  methods on interfaces, and a generic class can't implement an interface
  chosen by a type parameter); keep the types alike. Chain copies the open
  array into its own dynamic array, which takes the references the chain
  lives on, so Chain([TX.Create(...)]) frees TX with the chain. }

interface

uses
  SysUtils;

type
  /// A string transformation: FromFunc turns one into a normalizer, and the
  /// optionals' Map takes one directly. A plain function pointer, not
  /// PASCALCOMMON_FUNCREFS: "of object" on FPC would refuse the plain
  /// function a Delphi caller passes to a "reference to", so code written
  /// on one compiler wouldn't build on the other.
  TPcStringFunc = function(const AValue: string): string;

  /// A string transformation that carries its own parameters or state:
  /// TMaxLength.Create(50), TPadLeft.Create(8, '0'). Called directly
  /// (N.Apply(S)) or passed to the optionals' Normalize (1.12.0), which
  /// calls Apply only for a present value. An interface instead of a
  /// closure because FPC 3.2.2 has none; the reference count frees the
  /// object, so X.Normalize(TMaxLength.Create(50)) needs no try/finally. One
  /// instance may be kept and used for many values, from many threads if
  /// Apply doesn't change the object. A parameter that takes a normalizer
  /// should not be const: a newly created object passed to a const
  /// interface parameter gets no reference and is never freed, and
  /// Normalize(TX.Create(...)) is the intended use.
  IPcStringNormalizer = interface
    ['{72A22294-26D8-4400-B228-9AF19707FCBE}']
    function Apply(const AValue: string): string;
  end;

  // The same pair for the other types (1.12.0), with the same rules.

  TPcIntegerFunc = function(const AValue: Integer): Integer;

  IPcIntegerNormalizer = interface
    ['{D57FC7DF-917C-40E5-ADA3-C5182DCA2701}']
    function Apply(const AValue: Integer): Integer;
  end;

  TPcInt64Func = function(const AValue: Int64): Int64;

  IPcInt64Normalizer = interface
    ['{D24895B5-EDB1-44BA-8B05-FFF941E32EC6}']
    function Apply(const AValue: Int64): Int64;
  end;

  TPcSingleFunc = function(const AValue: Single): Single;

  IPcSingleNormalizer = interface
    ['{E197E442-8EF8-40A5-B856-6FBC2E9EB284}']
    function Apply(const AValue: Single): Single;
  end;

  TPcDoubleFunc = function(const AValue: Double): Double;

  IPcDoubleNormalizer = interface
    ['{DECD0C0B-28E2-4634-AA6C-1DA28A08C49C}']
    function Apply(const AValue: Double): Double;
  end;

  TPcCurrencyFunc = function(const AValue: Currency): Currency;

  IPcCurrencyNormalizer = interface
    ['{EDBA68F0-11DF-4B12-A60E-F6E668AE7DB9}']
    function Apply(const AValue: Currency): Currency;
  end;

  TPcDateTimeFunc = function(const AValue: TDateTime): TDateTime;

  IPcDateTimeNormalizer = interface
    ['{39E60801-94FD-4F3B-BA22-47BB551646DA}']
    function Apply(const AValue: TDateTime): TDateTime;
  end;

  TPcBooleanFunc = function(const AValue: Boolean): Boolean;

  IPcBooleanNormalizer = interface
    ['{45504AF1-53FF-4166-A75E-7F80A5D5392A}']
    function Apply(const AValue: Boolean): Boolean;
  end;

  TPcGuidFunc = function(const AValue: TGUID): TGUID;

  IPcGuidNormalizer = interface
    ['{9EC0CE37-C830-4E9A-85F7-171FDA8EA026}']
    function Apply(const AValue: TGUID): TGUID;
  end;

  TPcStringNormalizers = class
  strict private
    class var FTrim: IPcStringNormalizer;
    class var FUpper: IPcStringNormalizer;
    class var FLower: IPcStringNormalizer;
    class var FFoldForSearch: IPcStringNormalizer;
  public
    class constructor Create;
    class destructor Destroy;
    /// The same transformations as TOptionals.Trim/Upper/Lower: shared
    /// instances, created when the unit starts; they hold no state.
    class function Trim: IPcStringNormalizer; static;
    class function Upper: IPcStringNormalizer; static;
    class function Lower: IPcStringNormalizer; static;
    /// PascalCommon.Text's PcFoldForSearch (1.20.0): a search key, lower
    /// case, Latin accents removed, blanks collapsed.
    class function FoldForSearch: IPcStringNormalizer; static;
    /// A plain function as a normalizer. AFunc = nil raises EArgumentException.
    class function FromFunc(AFunc: TPcStringFunc): IPcStringNormalizer; static;
    /// The normalizers applied in order, as one. An empty list returns the
    /// value unchanged; a nil item raises EArgumentException.
    class function Chain(const ANormalizers: array of IPcStringNormalizer): IPcStringNormalizer; static;
  end;

  TPcIntegerNormalizers = class
  public
    /// A plain function as a normalizer. AFunc = nil raises EArgumentException.
    class function FromFunc(AFunc: TPcIntegerFunc): IPcIntegerNormalizer; static;
    /// The normalizers applied in order, as one. An empty list returns the
    /// value unchanged; a nil item raises EArgumentException.
    class function Chain(const ANormalizers: array of IPcIntegerNormalizer): IPcIntegerNormalizer; static;
  end;

  TPcInt64Normalizers = class
  public
    /// A plain function as a normalizer. AFunc = nil raises EArgumentException.
    class function FromFunc(AFunc: TPcInt64Func): IPcInt64Normalizer; static;
    /// The normalizers applied in order, as one. An empty list returns the
    /// value unchanged; a nil item raises EArgumentException.
    class function Chain(const ANormalizers: array of IPcInt64Normalizer): IPcInt64Normalizer; static;
  end;

  TPcSingleNormalizers = class
  public
    /// A plain function as a normalizer. AFunc = nil raises EArgumentException.
    class function FromFunc(AFunc: TPcSingleFunc): IPcSingleNormalizer; static;
    /// The normalizers applied in order, as one. An empty list returns the
    /// value unchanged; a nil item raises EArgumentException.
    class function Chain(const ANormalizers: array of IPcSingleNormalizer): IPcSingleNormalizer; static;
  end;

  TPcDoubleNormalizers = class
  public
    /// A plain function as a normalizer. AFunc = nil raises EArgumentException.
    class function FromFunc(AFunc: TPcDoubleFunc): IPcDoubleNormalizer; static;
    /// The normalizers applied in order, as one. An empty list returns the
    /// value unchanged; a nil item raises EArgumentException.
    class function Chain(const ANormalizers: array of IPcDoubleNormalizer): IPcDoubleNormalizer; static;
  end;

  TPcCurrencyNormalizers = class
  public
    /// A plain function as a normalizer. AFunc = nil raises EArgumentException.
    class function FromFunc(AFunc: TPcCurrencyFunc): IPcCurrencyNormalizer; static;
    /// The normalizers applied in order, as one. An empty list returns the
    /// value unchanged; a nil item raises EArgumentException.
    class function Chain(const ANormalizers: array of IPcCurrencyNormalizer): IPcCurrencyNormalizer; static;
  end;

  TPcDateTimeNormalizers = class
  public
    /// A plain function as a normalizer. AFunc = nil raises EArgumentException.
    class function FromFunc(AFunc: TPcDateTimeFunc): IPcDateTimeNormalizer; static;
    /// The normalizers applied in order, as one. An empty list returns the
    /// value unchanged; a nil item raises EArgumentException.
    class function Chain(const ANormalizers: array of IPcDateTimeNormalizer): IPcDateTimeNormalizer; static;
  end;

  TPcBooleanNormalizers = class
  public
    /// A plain function as a normalizer. AFunc = nil raises EArgumentException.
    class function FromFunc(AFunc: TPcBooleanFunc): IPcBooleanNormalizer; static;
    /// The normalizers applied in order, as one. An empty list returns the
    /// value unchanged; a nil item raises EArgumentException.
    class function Chain(const ANormalizers: array of IPcBooleanNormalizer): IPcBooleanNormalizer; static;
  end;

  TPcGuidNormalizers = class
  public
    /// A plain function as a normalizer. AFunc = nil raises EArgumentException.
    class function FromFunc(AFunc: TPcGuidFunc): IPcGuidNormalizer; static;
    /// The normalizers applied in order, as one. An empty list returns the
    /// value unchanged; a nil item raises EArgumentException.
    class function Chain(const ANormalizers: array of IPcGuidNormalizer): IPcGuidNormalizer; static;
  end;

implementation

uses
  PascalCommon.Text;

{ The objects behind FromFunc and Chain, one pair per type. }

type
  TStringFuncNormalizer = class(TInterfacedObject, IPcStringNormalizer)
  private
    FFunc: TPcStringFunc;
  public
    constructor Create(AFunc: TPcStringFunc);
    function Apply(const AValue: string): string;
  end;

  TStringChainNormalizer = class(TInterfacedObject, IPcStringNormalizer)
  private
    FItems: array of IPcStringNormalizer;
  public
    constructor Create(const ANormalizers: array of IPcStringNormalizer);
    function Apply(const AValue: string): string;
  end;

  TIntegerFuncNormalizer = class(TInterfacedObject, IPcIntegerNormalizer)
  private
    FFunc: TPcIntegerFunc;
  public
    constructor Create(AFunc: TPcIntegerFunc);
    function Apply(const AValue: Integer): Integer;
  end;

  TIntegerChainNormalizer = class(TInterfacedObject, IPcIntegerNormalizer)
  private
    FItems: array of IPcIntegerNormalizer;
  public
    constructor Create(const ANormalizers: array of IPcIntegerNormalizer);
    function Apply(const AValue: Integer): Integer;
  end;

  TInt64FuncNormalizer = class(TInterfacedObject, IPcInt64Normalizer)
  private
    FFunc: TPcInt64Func;
  public
    constructor Create(AFunc: TPcInt64Func);
    function Apply(const AValue: Int64): Int64;
  end;

  TInt64ChainNormalizer = class(TInterfacedObject, IPcInt64Normalizer)
  private
    FItems: array of IPcInt64Normalizer;
  public
    constructor Create(const ANormalizers: array of IPcInt64Normalizer);
    function Apply(const AValue: Int64): Int64;
  end;

  TSingleFuncNormalizer = class(TInterfacedObject, IPcSingleNormalizer)
  private
    FFunc: TPcSingleFunc;
  public
    constructor Create(AFunc: TPcSingleFunc);
    function Apply(const AValue: Single): Single;
  end;

  TSingleChainNormalizer = class(TInterfacedObject, IPcSingleNormalizer)
  private
    FItems: array of IPcSingleNormalizer;
  public
    constructor Create(const ANormalizers: array of IPcSingleNormalizer);
    function Apply(const AValue: Single): Single;
  end;

  TDoubleFuncNormalizer = class(TInterfacedObject, IPcDoubleNormalizer)
  private
    FFunc: TPcDoubleFunc;
  public
    constructor Create(AFunc: TPcDoubleFunc);
    function Apply(const AValue: Double): Double;
  end;

  TDoubleChainNormalizer = class(TInterfacedObject, IPcDoubleNormalizer)
  private
    FItems: array of IPcDoubleNormalizer;
  public
    constructor Create(const ANormalizers: array of IPcDoubleNormalizer);
    function Apply(const AValue: Double): Double;
  end;

  TCurrencyFuncNormalizer = class(TInterfacedObject, IPcCurrencyNormalizer)
  private
    FFunc: TPcCurrencyFunc;
  public
    constructor Create(AFunc: TPcCurrencyFunc);
    function Apply(const AValue: Currency): Currency;
  end;

  TCurrencyChainNormalizer = class(TInterfacedObject, IPcCurrencyNormalizer)
  private
    FItems: array of IPcCurrencyNormalizer;
  public
    constructor Create(const ANormalizers: array of IPcCurrencyNormalizer);
    function Apply(const AValue: Currency): Currency;
  end;

  TDateTimeFuncNormalizer = class(TInterfacedObject, IPcDateTimeNormalizer)
  private
    FFunc: TPcDateTimeFunc;
  public
    constructor Create(AFunc: TPcDateTimeFunc);
    function Apply(const AValue: TDateTime): TDateTime;
  end;

  TDateTimeChainNormalizer = class(TInterfacedObject, IPcDateTimeNormalizer)
  private
    FItems: array of IPcDateTimeNormalizer;
  public
    constructor Create(const ANormalizers: array of IPcDateTimeNormalizer);
    function Apply(const AValue: TDateTime): TDateTime;
  end;

  TBooleanFuncNormalizer = class(TInterfacedObject, IPcBooleanNormalizer)
  private
    FFunc: TPcBooleanFunc;
  public
    constructor Create(AFunc: TPcBooleanFunc);
    function Apply(const AValue: Boolean): Boolean;
  end;

  TBooleanChainNormalizer = class(TInterfacedObject, IPcBooleanNormalizer)
  private
    FItems: array of IPcBooleanNormalizer;
  public
    constructor Create(const ANormalizers: array of IPcBooleanNormalizer);
    function Apply(const AValue: Boolean): Boolean;
  end;

  TGuidFuncNormalizer = class(TInterfacedObject, IPcGuidNormalizer)
  private
    FFunc: TPcGuidFunc;
  public
    constructor Create(AFunc: TPcGuidFunc);
    function Apply(const AValue: TGUID): TGUID;
  end;

  TGuidChainNormalizer = class(TInterfacedObject, IPcGuidNormalizer)
  private
    FItems: array of IPcGuidNormalizer;
  public
    constructor Create(const ANormalizers: array of IPcGuidNormalizer);
    function Apply(const AValue: TGUID): TGUID;
  end;

function NormTrim(const AValue: string): string;
begin
  Result := SysUtils.Trim(AValue);
end;

function NormUpper(const AValue: string): string;
begin
  Result := PcUpperCase(AValue);
end;

function NormLower(const AValue: string): string;
begin
  Result := PcLowerCase(AValue);
end;

function NormFoldForSearch(const AValue: string): string;
begin
  Result := PcFoldForSearch(AValue);
end;

{ String }

constructor TStringFuncNormalizer.Create(AFunc: TPcStringFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TStringFuncNormalizer.Apply(const AValue: string): string;
begin
  Result := FFunc(AValue);
end;

constructor TStringChainNormalizer.Create(const ANormalizers: array of IPcStringNormalizer);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(ANormalizers));
  for I := 0 to High(ANormalizers) do
    FItems[I] := ANormalizers[I];
end;

function TStringChainNormalizer.Apply(const AValue: string): string;
var
  I: Integer;
begin
  Result := AValue;
  for I := 0 to High(FItems) do
    Result := FItems[I].Apply(Result);
end;

class constructor TPcStringNormalizers.Create;
begin
  FTrim := TStringFuncNormalizer.Create(NormTrim);
  FUpper := TStringFuncNormalizer.Create(NormUpper);
  FLower := TStringFuncNormalizer.Create(NormLower);
  FFoldForSearch := TStringFuncNormalizer.Create(NormFoldForSearch);
end;

class destructor TPcStringNormalizers.Destroy;
begin
  FTrim := nil;
  FUpper := nil;
  FLower := nil;
  FFoldForSearch := nil;
end;

class function TPcStringNormalizers.Trim: IPcStringNormalizer;
begin
  Result := FTrim;
end;

class function TPcStringNormalizers.Upper: IPcStringNormalizer;
begin
  Result := FUpper;
end;

class function TPcStringNormalizers.Lower: IPcStringNormalizer;
begin
  Result := FLower;
end;

class function TPcStringNormalizers.FoldForSearch: IPcStringNormalizer;
begin
  Result := FFoldForSearch;
end;

class function TPcStringNormalizers.FromFunc(AFunc: TPcStringFunc): IPcStringNormalizer;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcStringNormalizers.FromFunc: AFunc is nil');
  Result := TStringFuncNormalizer.Create(AFunc);
end;

class function TPcStringNormalizers.Chain(const ANormalizers: array of IPcStringNormalizer): IPcStringNormalizer;
var
  I: Integer;
begin
  for I := 0 to High(ANormalizers) do
    if not Assigned(ANormalizers[I]) then
      raise EArgumentException.CreateFmt('TPcStringNormalizers.Chain: item %d is nil', [I]);
  Result := TStringChainNormalizer.Create(ANormalizers);
end;

{ Integer }

constructor TIntegerFuncNormalizer.Create(AFunc: TPcIntegerFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TIntegerFuncNormalizer.Apply(const AValue: Integer): Integer;
begin
  Result := FFunc(AValue);
end;

constructor TIntegerChainNormalizer.Create(const ANormalizers: array of IPcIntegerNormalizer);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(ANormalizers));
  for I := 0 to High(ANormalizers) do
    FItems[I] := ANormalizers[I];
end;

function TIntegerChainNormalizer.Apply(const AValue: Integer): Integer;
var
  I: Integer;
begin
  Result := AValue;
  for I := 0 to High(FItems) do
    Result := FItems[I].Apply(Result);
end;

class function TPcIntegerNormalizers.FromFunc(AFunc: TPcIntegerFunc): IPcIntegerNormalizer;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcIntegerNormalizers.FromFunc: AFunc is nil');
  Result := TIntegerFuncNormalizer.Create(AFunc);
end;

class function TPcIntegerNormalizers.Chain(const ANormalizers: array of IPcIntegerNormalizer): IPcIntegerNormalizer;
var
  I: Integer;
begin
  for I := 0 to High(ANormalizers) do
    if not Assigned(ANormalizers[I]) then
      raise EArgumentException.CreateFmt('TPcIntegerNormalizers.Chain: item %d is nil', [I]);
  Result := TIntegerChainNormalizer.Create(ANormalizers);
end;

{ Int64 }

constructor TInt64FuncNormalizer.Create(AFunc: TPcInt64Func);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TInt64FuncNormalizer.Apply(const AValue: Int64): Int64;
begin
  Result := FFunc(AValue);
end;

constructor TInt64ChainNormalizer.Create(const ANormalizers: array of IPcInt64Normalizer);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(ANormalizers));
  for I := 0 to High(ANormalizers) do
    FItems[I] := ANormalizers[I];
end;

function TInt64ChainNormalizer.Apply(const AValue: Int64): Int64;
var
  I: Integer;
begin
  Result := AValue;
  for I := 0 to High(FItems) do
    Result := FItems[I].Apply(Result);
end;

class function TPcInt64Normalizers.FromFunc(AFunc: TPcInt64Func): IPcInt64Normalizer;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcInt64Normalizers.FromFunc: AFunc is nil');
  Result := TInt64FuncNormalizer.Create(AFunc);
end;

class function TPcInt64Normalizers.Chain(const ANormalizers: array of IPcInt64Normalizer): IPcInt64Normalizer;
var
  I: Integer;
begin
  for I := 0 to High(ANormalizers) do
    if not Assigned(ANormalizers[I]) then
      raise EArgumentException.CreateFmt('TPcInt64Normalizers.Chain: item %d is nil', [I]);
  Result := TInt64ChainNormalizer.Create(ANormalizers);
end;

{ Single }

constructor TSingleFuncNormalizer.Create(AFunc: TPcSingleFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TSingleFuncNormalizer.Apply(const AValue: Single): Single;
begin
  Result := FFunc(AValue);
end;

constructor TSingleChainNormalizer.Create(const ANormalizers: array of IPcSingleNormalizer);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(ANormalizers));
  for I := 0 to High(ANormalizers) do
    FItems[I] := ANormalizers[I];
end;

function TSingleChainNormalizer.Apply(const AValue: Single): Single;
var
  I: Integer;
begin
  Result := AValue;
  for I := 0 to High(FItems) do
    Result := FItems[I].Apply(Result);
end;

class function TPcSingleNormalizers.FromFunc(AFunc: TPcSingleFunc): IPcSingleNormalizer;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcSingleNormalizers.FromFunc: AFunc is nil');
  Result := TSingleFuncNormalizer.Create(AFunc);
end;

class function TPcSingleNormalizers.Chain(const ANormalizers: array of IPcSingleNormalizer): IPcSingleNormalizer;
var
  I: Integer;
begin
  for I := 0 to High(ANormalizers) do
    if not Assigned(ANormalizers[I]) then
      raise EArgumentException.CreateFmt('TPcSingleNormalizers.Chain: item %d is nil', [I]);
  Result := TSingleChainNormalizer.Create(ANormalizers);
end;

{ Double }

constructor TDoubleFuncNormalizer.Create(AFunc: TPcDoubleFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TDoubleFuncNormalizer.Apply(const AValue: Double): Double;
begin
  Result := FFunc(AValue);
end;

constructor TDoubleChainNormalizer.Create(const ANormalizers: array of IPcDoubleNormalizer);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(ANormalizers));
  for I := 0 to High(ANormalizers) do
    FItems[I] := ANormalizers[I];
end;

function TDoubleChainNormalizer.Apply(const AValue: Double): Double;
var
  I: Integer;
begin
  Result := AValue;
  for I := 0 to High(FItems) do
    Result := FItems[I].Apply(Result);
end;

class function TPcDoubleNormalizers.FromFunc(AFunc: TPcDoubleFunc): IPcDoubleNormalizer;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcDoubleNormalizers.FromFunc: AFunc is nil');
  Result := TDoubleFuncNormalizer.Create(AFunc);
end;

class function TPcDoubleNormalizers.Chain(const ANormalizers: array of IPcDoubleNormalizer): IPcDoubleNormalizer;
var
  I: Integer;
begin
  for I := 0 to High(ANormalizers) do
    if not Assigned(ANormalizers[I]) then
      raise EArgumentException.CreateFmt('TPcDoubleNormalizers.Chain: item %d is nil', [I]);
  Result := TDoubleChainNormalizer.Create(ANormalizers);
end;

{ Currency }

constructor TCurrencyFuncNormalizer.Create(AFunc: TPcCurrencyFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TCurrencyFuncNormalizer.Apply(const AValue: Currency): Currency;
begin
  Result := FFunc(AValue);
end;

constructor TCurrencyChainNormalizer.Create(const ANormalizers: array of IPcCurrencyNormalizer);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(ANormalizers));
  for I := 0 to High(ANormalizers) do
    FItems[I] := ANormalizers[I];
end;

function TCurrencyChainNormalizer.Apply(const AValue: Currency): Currency;
var
  I: Integer;
begin
  Result := AValue;
  for I := 0 to High(FItems) do
    Result := FItems[I].Apply(Result);
end;

class function TPcCurrencyNormalizers.FromFunc(AFunc: TPcCurrencyFunc): IPcCurrencyNormalizer;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcCurrencyNormalizers.FromFunc: AFunc is nil');
  Result := TCurrencyFuncNormalizer.Create(AFunc);
end;

class function TPcCurrencyNormalizers.Chain(const ANormalizers: array of IPcCurrencyNormalizer): IPcCurrencyNormalizer;
var
  I: Integer;
begin
  for I := 0 to High(ANormalizers) do
    if not Assigned(ANormalizers[I]) then
      raise EArgumentException.CreateFmt('TPcCurrencyNormalizers.Chain: item %d is nil', [I]);
  Result := TCurrencyChainNormalizer.Create(ANormalizers);
end;

{ DateTime }

constructor TDateTimeFuncNormalizer.Create(AFunc: TPcDateTimeFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TDateTimeFuncNormalizer.Apply(const AValue: TDateTime): TDateTime;
begin
  Result := FFunc(AValue);
end;

constructor TDateTimeChainNormalizer.Create(const ANormalizers: array of IPcDateTimeNormalizer);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(ANormalizers));
  for I := 0 to High(ANormalizers) do
    FItems[I] := ANormalizers[I];
end;

function TDateTimeChainNormalizer.Apply(const AValue: TDateTime): TDateTime;
var
  I: Integer;
begin
  Result := AValue;
  for I := 0 to High(FItems) do
    Result := FItems[I].Apply(Result);
end;

class function TPcDateTimeNormalizers.FromFunc(AFunc: TPcDateTimeFunc): IPcDateTimeNormalizer;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcDateTimeNormalizers.FromFunc: AFunc is nil');
  Result := TDateTimeFuncNormalizer.Create(AFunc);
end;

class function TPcDateTimeNormalizers.Chain(const ANormalizers: array of IPcDateTimeNormalizer): IPcDateTimeNormalizer;
var
  I: Integer;
begin
  for I := 0 to High(ANormalizers) do
    if not Assigned(ANormalizers[I]) then
      raise EArgumentException.CreateFmt('TPcDateTimeNormalizers.Chain: item %d is nil', [I]);
  Result := TDateTimeChainNormalizer.Create(ANormalizers);
end;

{ Boolean }

constructor TBooleanFuncNormalizer.Create(AFunc: TPcBooleanFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TBooleanFuncNormalizer.Apply(const AValue: Boolean): Boolean;
begin
  Result := FFunc(AValue);
end;

constructor TBooleanChainNormalizer.Create(const ANormalizers: array of IPcBooleanNormalizer);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(ANormalizers));
  for I := 0 to High(ANormalizers) do
    FItems[I] := ANormalizers[I];
end;

function TBooleanChainNormalizer.Apply(const AValue: Boolean): Boolean;
var
  I: Integer;
begin
  Result := AValue;
  for I := 0 to High(FItems) do
    Result := FItems[I].Apply(Result);
end;

class function TPcBooleanNormalizers.FromFunc(AFunc: TPcBooleanFunc): IPcBooleanNormalizer;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcBooleanNormalizers.FromFunc: AFunc is nil');
  Result := TBooleanFuncNormalizer.Create(AFunc);
end;

class function TPcBooleanNormalizers.Chain(const ANormalizers: array of IPcBooleanNormalizer): IPcBooleanNormalizer;
var
  I: Integer;
begin
  for I := 0 to High(ANormalizers) do
    if not Assigned(ANormalizers[I]) then
      raise EArgumentException.CreateFmt('TPcBooleanNormalizers.Chain: item %d is nil', [I]);
  Result := TBooleanChainNormalizer.Create(ANormalizers);
end;

{ Guid }

constructor TGuidFuncNormalizer.Create(AFunc: TPcGuidFunc);
begin
  inherited Create;
  FFunc := AFunc;
end;

function TGuidFuncNormalizer.Apply(const AValue: TGUID): TGUID;
begin
  Result := FFunc(AValue);
end;

constructor TGuidChainNormalizer.Create(const ANormalizers: array of IPcGuidNormalizer);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FItems, Length(ANormalizers));
  for I := 0 to High(ANormalizers) do
    FItems[I] := ANormalizers[I];
end;

function TGuidChainNormalizer.Apply(const AValue: TGUID): TGUID;
var
  I: Integer;
begin
  Result := AValue;
  for I := 0 to High(FItems) do
    Result := FItems[I].Apply(Result);
end;

class function TPcGuidNormalizers.FromFunc(AFunc: TPcGuidFunc): IPcGuidNormalizer;
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TPcGuidNormalizers.FromFunc: AFunc is nil');
  Result := TGuidFuncNormalizer.Create(AFunc);
end;

class function TPcGuidNormalizers.Chain(const ANormalizers: array of IPcGuidNormalizer): IPcGuidNormalizer;
var
  I: Integer;
begin
  for I := 0 to High(ANormalizers) do
    if not Assigned(ANormalizers[I]) then
      raise EArgumentException.CreateFmt('TPcGuidNormalizers.Chain: item %d is nil', [I]);
  Result := TGuidChainNormalizer.Create(ANormalizers);
end;

end.
