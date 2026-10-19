unit PascalCommon.Optionals;

{$I pascalcommon.inc}

{ Optional and nullable types used in parameters, DTOs and column reads:
  IOptXxx ("was it provided?" — HasValue), INullXxx ("is it null?" —
  IsNull) and IOptNullXxx (both), for String, Integer, Int64, Single, Double,
  Currency, TDateTime, Boolean and TGUID. A single class per type
  (TOptNullXxx) implements all three interfaces.

  TOptionals.Safe(X) never returns nil: with X = nil it returns Undefined
  (HasValue = False) for IOptXxx/IOptNullXxx and Null (IsNull = True) for
  INullXxx. That is the guard that lets consuming code test just
  .HasValue/.IsNull, without Assigned checks field by field.

  Instances are immutable and shared: Null/Undefined are singletons, and
  From(Value) reuses instances through a global per-type cache (a fixed range
  for small integers + TClockCache for the rest), with its own lock — which
  is why From is safe under concurrency.

  TOptionals.Trim/Upper/Lower/NullIfEmpty/UndefinedIfEmpty/Map (1.9.0)
  normalize a string optional without opening it with an if: the result keeps
  the state (Undefined, Null or a value) and only a present value changes, so
  it can go straight to a parameter, a message or a comparison. The named
  ones (Trim, Upper...) exist only for string: it is the measured case (a
  PATCH DTO in pascal-api-infra-faa). Map and Normalize exist for every type
  since 1.12.0, so a caller writes its own for the rest. Map
  takes a plain function pointer (TPcStringFunc) because FPC 3.2.2 has no
  closures, and "of object" there would make a Delphi caller's plain function
  fail to build on FPC; SysUtils.Trim is overloaded, which is one reason the
  common normalizers are named methods here.

  The string flavors also have them as methods (1.11.0), for a chain:
  LDto.State.Trim.Upper. Each method calls the TOptionals one with Self, so
  the rules are the same; the one difference is nil, which TOptionals reads
  as in Safe and a method call can't survive. TOptNullString implements the
  three flavors, whose methods share names but not result types, so it maps
  each one with a method resolution clause (function IOptString.Trim =
  OptTrim), which Delphi and FPC in mode Delphi both accept.

  Normalize (1.12.0) is Map with an IPcStringNormalizer: an object with an
  Apply method, for a transformation with parameters (a maximum length, a
  pad character) that a plain function can't carry without closures. It has
  its own name instead of being a Map overload because Delphi doesn't accept
  a method resolution clause for an overloaded interface method (E2291: it
  binds one overload and reports the other as missing; FPC accepts it), and
  because an overload would make a literal nil passed to Map ambiguous.

  Map and Normalize exist for every type (1.12.0), each with its own
  function type and normalizer interface (TPcIntegerFunc,
  IPcIntegerNormalizer...), since a single generic one would need generic
  methods on an interface, which neither compiler allows. Single and Double
  pass the source's DecimalPlaces to From, so the result keeps them, except
  for a result of 0: From returns its shared zero, whose DecimalPlaces is -1.
  TGUID is compared with IsEqualGUID.

  The function types, the normalizer interfaces and the factories that
  gather the ready-made normalizers (FromFunc, Chain, TPcStringNormalizers...)
  are in PascalCommon.Normalizers (1.14.0), which doesn't depend on this
  unit, so a normalizer also serves a plain value. This unit re-exports the
  types as aliases, so code that uses only PascalCommon.Optionals still sees
  them. Upper and lower case come from PascalCommon.Text.

  Dual-compiler: the cache-key comparers for Single/Double are named
  functions (TEqualityComparer<T>.Construct doesn't accept a closure on FPC
  3.2.2, and the IEqualityComparer<T> signature differs — constref/UInt32 on
  FPC), and the empty GUID is a local constant (TGuid.Empty is a Delphi
  helper). }

interface

uses
  Classes, SysUtils, SyncObjs, PascalCommon.SystemContext,
  PascalCommon.ClockCache, PascalCommon.Normalizers, Generics.Defaults;

type
  // Declared in PascalCommon.Normalizers since 1.14.0, which doesn't depend
  // on the optionals; the aliases keep these names visible to code that
  // uses only this unit. An alias is the same type, not a copy.
  TPcStringFunc = PascalCommon.Normalizers.TPcStringFunc;
  IPcStringNormalizer = PascalCommon.Normalizers.IPcStringNormalizer;
  TPcIntegerFunc = PascalCommon.Normalizers.TPcIntegerFunc;
  IPcIntegerNormalizer = PascalCommon.Normalizers.IPcIntegerNormalizer;
  TPcInt64Func = PascalCommon.Normalizers.TPcInt64Func;
  IPcInt64Normalizer = PascalCommon.Normalizers.IPcInt64Normalizer;
  TPcSingleFunc = PascalCommon.Normalizers.TPcSingleFunc;
  IPcSingleNormalizer = PascalCommon.Normalizers.IPcSingleNormalizer;
  TPcDoubleFunc = PascalCommon.Normalizers.TPcDoubleFunc;
  IPcDoubleNormalizer = PascalCommon.Normalizers.IPcDoubleNormalizer;
  TPcCurrencyFunc = PascalCommon.Normalizers.TPcCurrencyFunc;
  IPcCurrencyNormalizer = PascalCommon.Normalizers.IPcCurrencyNormalizer;
  TPcDateTimeFunc = PascalCommon.Normalizers.TPcDateTimeFunc;
  IPcDateTimeNormalizer = PascalCommon.Normalizers.IPcDateTimeNormalizer;
  TPcBooleanFunc = PascalCommon.Normalizers.TPcBooleanFunc;
  IPcBooleanNormalizer = PascalCommon.Normalizers.IPcBooleanNormalizer;
  TPcGuidFunc = PascalCommon.Normalizers.TPcGuidFunc;
  IPcGuidNormalizer = PascalCommon.Normalizers.IPcGuidNormalizer;

  IOptionalBase = interface
    ['{E4F4A971-9D82-4072-9FCD-B94B3534D00B}']
    function HasValue: Boolean;
  end;

  INullableBase = interface
    ['{FF676337-9F25-4E4E-987B-759175358B7E}']
    function IsNull: Boolean;
  end;

  IOptionalNullableBase = interface
    ['{F991DB80-57A5-49FA-812F-70692A6893C8}']
    function IsNull: Boolean;
    function HasValue: Boolean;
  end;

  IOptional<T> = interface(IOptionalBase)
    ['{ED862237-1C8B-4B92-95D1-65E47B4D83B7}']
    function GetValue: T;
    /// The value when there is one; ADefault when it is undefined or null
    /// (1.19.0). On a reference that may be nil, start from
    /// TOptionals.Safe(X).ValueOr(...).
    function ValueOr(const ADefault: T): T;
    property Value: T read GetValue;
  end;

  INullable<T> = interface(INullableBase)
    ['{676D05B3-6E6F-4F82-A9AB-455E9464F866}']
    function GetValue: T;
    /// The value when there is one; ADefault when it is undefined or null
    /// (1.19.0). On a reference that may be nil, start from
    /// TOptionals.Safe(X).ValueOr(...).
    function ValueOr(const ADefault: T): T;
    property Value: T read GetValue;
  end;

  IOptionalNullable<T> = interface(IOptionalNullableBase)
    ['{B27511F9-7746-4432-9165-CF31D058053A}']
    function GetValue: T;
    /// The value when there is one; ADefault when it is undefined or null
    /// (1.19.0). On a reference that may be nil, start from
    /// TOptionals.Safe(X).ValueOr(...).
    function ValueOr(const ADefault: T): T;
    property Value: T read GetValue;
  end;

  { string interfaces }

  // The fluent normalizers (1.11.0) are the TOptionals ones of the same
  // name applied to Self: X.Trim.Upper = TOptionals.Upper(TOptionals.Trim(X)).
  // A method can't be called on nil: where X may be nil, start the chain
  // with TOptionals.Safe(X). These interfaces are implemented only by
  // TOptNullString; they aren't meant to be implemented outside this unit,
  // which is what lets a minor version add methods to them.

  IOptString = interface(IOptional<string>)
    ['{A761330C-AA4B-44A5-A617-C79E3F745A23}']
    function Trim: IOptString;
    function Upper: IOptString;
    function Lower: IOptString;
    function UndefinedIfEmpty: IOptString;
    function Map(AFunc: TPcStringFunc): IOptString;
    function Normalize(ANormalizer: IPcStringNormalizer): IOptString;
  end;

  INullString = interface(INullable<string>)
    ['{C86A1566-0B19-4BE2-B780-D22C3ED385F6}']
    function Trim: INullString;
    function Upper: INullString;
    function Lower: INullString;
    function NullIfEmpty: INullString;
    function Map(AFunc: TPcStringFunc): INullString;
    function Normalize(ANormalizer: IPcStringNormalizer): INullString;
  end;

  IOptNullString = interface(IOptionalNullable<string>)
    ['{E166D638-8A7C-4143-A0EE-22161499F6A8}']
    function Trim: IOptNullString;
    function Upper: IOptNullString;
    function Lower: IOptNullString;
    function NullIfEmpty: IOptNullString;
    function UndefinedIfEmpty: IOptNullString;
    function Map(AFunc: TPcStringFunc): IOptNullString;
    function Normalize(ANormalizer: IPcStringNormalizer): IOptNullString;
  end;

  { Integers interfaces }

  IOptInteger = interface(IOptional<Integer>)
    ['{472AF43B-BC8E-42A5-B275-2D9B0BEE6667}']
    function Map(AFunc: TPcIntegerFunc): IOptInteger;
    function Normalize(ANormalizer: IPcIntegerNormalizer): IOptInteger;
  end;

  INullInteger = interface(INullable<Integer>)
    ['{C040BEFA-C342-4F0A-92AD-6FA7711FA002}']
    function Map(AFunc: TPcIntegerFunc): INullInteger;
    function Normalize(ANormalizer: IPcIntegerNormalizer): INullInteger;
  end;

  IOptNullInteger = interface(IOptionalNullable<Integer>)
    ['{6092BDE1-A122-4BFB-AF50-4947884DA9FD}']
    function Map(AFunc: TPcIntegerFunc): IOptNullInteger;
    function Normalize(ANormalizer: IPcIntegerNormalizer): IOptNullInteger;
  end;

  { Int64 interfaces }

  IOptInt64 = interface(IOptional<Int64>)
    ['{A6307E45-A804-4B1B-BE27-8FB393CC80F5}']
    function Map(AFunc: TPcInt64Func): IOptInt64;
    function Normalize(ANormalizer: IPcInt64Normalizer): IOptInt64;
  end;

  INullInt64 = interface(INullable<Int64>)
    ['{A497772F-B7B2-448E-8191-CE4EEEE0B6C6}']
    function Map(AFunc: TPcInt64Func): INullInt64;
    function Normalize(ANormalizer: IPcInt64Normalizer): INullInt64;
  end;

  IOptNullInt64 = interface(IOptionalNullable<Int64>)
    ['{78F13E94-E8CB-463E-B5A2-A4EC93D20D9D}']
    function Map(AFunc: TPcInt64Func): IOptNullInt64;
    function Normalize(ANormalizer: IPcInt64Normalizer): IOptNullInt64;
  end;

  { DateTime interfaces }

  IOptDateTime = interface(IOptional<TDateTime>)
    ['{764BCB67-F040-4BA1-B127-BA6A5BB5CEF6}']
    function Map(AFunc: TPcDateTimeFunc): IOptDateTime;
    function Normalize(ANormalizer: IPcDateTimeNormalizer): IOptDateTime;
  end;

  INullDateTime = interface(INullable<TDateTime>)
    ['{107CDFB4-20E1-4887-A1D3-9DD247798F9D}']
    function Map(AFunc: TPcDateTimeFunc): INullDateTime;
    function Normalize(ANormalizer: IPcDateTimeNormalizer): INullDateTime;
  end;

  IOptNullDateTime = interface(IOptionalNullable<TDateTime>)
    ['{1C1A3315-7A2A-4764-8E0D-40166907A10B}']
    function Map(AFunc: TPcDateTimeFunc): IOptNullDateTime;
    function Normalize(ANormalizer: IPcDateTimeNormalizer): IOptNullDateTime;
  end;

  { Boolean interfaces }

  IOptBoolean = interface(IOptional<Boolean>)
    ['{E7274751-2E3F-49FF-9DC0-6ED268F400F8}']
    function Map(AFunc: TPcBooleanFunc): IOptBoolean;
    function Normalize(ANormalizer: IPcBooleanNormalizer): IOptBoolean;
  end;

  INullBoolean = interface(INullable<Boolean>)
    ['{07ED6DF4-64E8-4246-BA8F-D232B6336888}']
    function Map(AFunc: TPcBooleanFunc): INullBoolean;
    function Normalize(ANormalizer: IPcBooleanNormalizer): INullBoolean;
  end;

  IOptNullBoolean = interface(IOptionalNullable<Boolean>)
    ['{E1FF6455-38A6-4999-B63D-3A1D48F54A9B}']
    function Map(AFunc: TPcBooleanFunc): IOptNullBoolean;
    function Normalize(ANormalizer: IPcBooleanNormalizer): IOptNullBoolean;
  end;

  { GUID interfaces }

  IOptGuid = interface(IOptional<TGUID>)
    ['{A8135F04-35BF-43EE-B345-85C784E583E0}']
    function Map(AFunc: TPcGuidFunc): IOptGuid;
    function Normalize(ANormalizer: IPcGuidNormalizer): IOptGuid;
  end;

  INullGuid = interface(INullable<TGUID>)
    ['{AD57F2C9-083B-42AE-8980-6B3CD3CE3382}']
    function Map(AFunc: TPcGuidFunc): INullGuid;
    function Normalize(ANormalizer: IPcGuidNormalizer): INullGuid;
  end;

  IOptNullGuid = interface(IOptionalNullable<TGUID>)
    ['{8B4F0499-ECE5-4881-A6AF-F9B7DD875477}']
    function Map(AFunc: TPcGuidFunc): IOptNullGuid;
    function Normalize(ANormalizer: IPcGuidNormalizer): IOptNullGuid;
  end;

  { Currency interfaces }

  IOptCurrency = interface(IOptional<Currency>)
    ['{79A63721-7A39-44F0-A3A8-E0C79A81432E}']
    function Map(AFunc: TPcCurrencyFunc): IOptCurrency;
    function Normalize(ANormalizer: IPcCurrencyNormalizer): IOptCurrency;
  end;

  INullCurrency = interface(INullable<Currency>)
    ['{487532A1-9B21-4E65-B8A2-C1D826B74312}']
    function Map(AFunc: TPcCurrencyFunc): INullCurrency;
    function Normalize(ANormalizer: IPcCurrencyNormalizer): INullCurrency;
  end;

  IOptNullCurrency = interface(IOptionalNullable<Currency>)
    ['{C781A329-8E2B-4F54-9321-A3C9E23D5F11}']
    function Map(AFunc: TPcCurrencyFunc): IOptNullCurrency;
    function Normalize(ANormalizer: IPcCurrencyNormalizer): IOptNullCurrency;
  end;

  IDecimalPrecision = interface
    ['{84D64E10-8D21-4E2F-A2BE-EB399AF77B45}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
  end;

  { Single interfaces }

  IOptSingle = interface(IOptional<Single>)
    ['{52B5032D-B7AD-4A12-B7C1-36D6E146D783}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
    function Map(AFunc: TPcSingleFunc): IOptSingle;
    function Normalize(ANormalizer: IPcSingleNormalizer): IOptSingle;
  end;

  INullSingle = interface(INullable<Single>)
    ['{315FF86F-2214-4250-865C-172898105578}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
    function Map(AFunc: TPcSingleFunc): INullSingle;
    function Normalize(ANormalizer: IPcSingleNormalizer): INullSingle;
  end;

  IOptNullSingle = interface(IOptionalNullable<Single>)
    ['{CF6A4091-6C5B-4CEE-8344-0BC3C6F02567}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
    function Map(AFunc: TPcSingleFunc): IOptNullSingle;
    function Normalize(ANormalizer: IPcSingleNormalizer): IOptNullSingle;
  end;

  { Double interfaces }

  IOptDouble = interface(IOptional<Double>)
    ['{6645BB6E-7837-4A4E-90B5-F1B887C9B0C2}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
    function Map(AFunc: TPcDoubleFunc): IOptDouble;
    function Normalize(ANormalizer: IPcDoubleNormalizer): IOptDouble;
  end;

  INullDouble = interface(INullable<Double>)
    ['{01368222-01F7-4698-8ECB-45AC8D6FA901}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
    function Map(AFunc: TPcDoubleFunc): INullDouble;
    function Normalize(ANormalizer: IPcDoubleNormalizer): INullDouble;
  end;

  IOptNullDouble = interface(IOptionalNullable<Double>)
    ['{3C030269-23A9-4379-B64F-74B3EE9EAE66}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
    function Map(AFunc: TPcDoubleFunc): IOptNullDouble;
    function Normalize(ANormalizer: IPcDoubleNormalizer): IOptNullDouble;
  end;

  { TOptionals Helper }

  TOptionals = class
  public
    // String normalizers (1.9.0). Each keeps the state: Undefined stays
    // Undefined, Null stays Null, nil reads as in Safe, and only a present
    // value is transformed. The result is never nil; an unchanged value
    // returns the same instance.
    class function Trim(const AValue: IOptString): IOptString; overload; static;
    class function Trim(const AValue: INullString): INullString; overload; static;
    class function Trim(const AValue: IOptNullString): IOptNullString; overload; static;
    /// Unicode-aware and independent of the process locale on both
    /// compilers: 'são paulo' gives 'SÃO PAULO'.
    class function Upper(const AValue: IOptString): IOptString; overload; static;
    class function Upper(const AValue: INullString): INullString; overload; static;
    class function Upper(const AValue: IOptNullString): IOptNullString; overload; static;
    /// Lowercase, with the same rules as Upper.
    class function Lower(const AValue: IOptString): IOptString; overload; static;
    class function Lower(const AValue: INullString): INullString; overload; static;
    class function Lower(const AValue: IOptNullString): IOptNullString; overload; static;
    /// '' becomes Null. It doesn't trim: NullIfEmpty(Trim(X)) for blanks.
    class function NullIfEmpty(const AValue: INullString): INullString; overload; static;
    class function NullIfEmpty(const AValue: IOptNullString): IOptNullString; overload; static;
    /// '' becomes Undefined. It doesn't trim: UndefinedIfEmpty(Trim(X)).
    class function UndefinedIfEmpty(const AValue: IOptString): IOptString; overload; static;
    class function UndefinedIfEmpty(const AValue: IOptNullString): IOptNullString; overload; static;
    /// AFunc applied to a present value. AFunc = nil raises EArgumentException.
    class function Map(const AValue: IOptString; AFunc: TPcStringFunc): IOptString; overload; static;
    class function Map(const AValue: INullString; AFunc: TPcStringFunc): INullString; overload; static;
    class function Map(const AValue: IOptNullString; AFunc: TPcStringFunc): IOptNullString; overload; static;
    /// Map with an object: ANormalizer.Apply applied to a present value
    /// (1.12.0). ANormalizer = nil raises EArgumentException.
    class function Normalize(const AValue: IOptString; ANormalizer: IPcStringNormalizer): IOptString; overload; static;
    class function Normalize(const AValue: INullString; ANormalizer: IPcStringNormalizer): INullString; overload; static;
    class function Normalize(const AValue: IOptNullString; ANormalizer: IPcStringNormalizer): IOptNullString; overload; static;
    // Map and Normalize for the other types: the same rules as the string
    // ones. Single and Double keep the source's DecimalPlaces, except for a
    // result of 0 (From's shared zero, DecimalPlaces -1).
    // Integer (1.12.0)
    class function Map(const AValue: IOptInteger; AFunc: TPcIntegerFunc): IOptInteger; overload; static;
    class function Map(const AValue: INullInteger; AFunc: TPcIntegerFunc): INullInteger; overload; static;
    class function Map(const AValue: IOptNullInteger; AFunc: TPcIntegerFunc): IOptNullInteger; overload; static;
    class function Normalize(const AValue: IOptInteger; ANormalizer: IPcIntegerNormalizer): IOptInteger; overload; static;
    class function Normalize(const AValue: INullInteger; ANormalizer: IPcIntegerNormalizer): INullInteger; overload; static;
    class function Normalize(const AValue: IOptNullInteger; ANormalizer: IPcIntegerNormalizer): IOptNullInteger; overload; static;
    // Int64 (1.12.0)
    class function Map(const AValue: IOptInt64; AFunc: TPcInt64Func): IOptInt64; overload; static;
    class function Map(const AValue: INullInt64; AFunc: TPcInt64Func): INullInt64; overload; static;
    class function Map(const AValue: IOptNullInt64; AFunc: TPcInt64Func): IOptNullInt64; overload; static;
    class function Normalize(const AValue: IOptInt64; ANormalizer: IPcInt64Normalizer): IOptInt64; overload; static;
    class function Normalize(const AValue: INullInt64; ANormalizer: IPcInt64Normalizer): INullInt64; overload; static;
    class function Normalize(const AValue: IOptNullInt64; ANormalizer: IPcInt64Normalizer): IOptNullInt64; overload; static;
    // Single (1.12.0)
    class function Map(const AValue: IOptSingle; AFunc: TPcSingleFunc): IOptSingle; overload; static;
    class function Map(const AValue: INullSingle; AFunc: TPcSingleFunc): INullSingle; overload; static;
    class function Map(const AValue: IOptNullSingle; AFunc: TPcSingleFunc): IOptNullSingle; overload; static;
    class function Normalize(const AValue: IOptSingle; ANormalizer: IPcSingleNormalizer): IOptSingle; overload; static;
    class function Normalize(const AValue: INullSingle; ANormalizer: IPcSingleNormalizer): INullSingle; overload; static;
    class function Normalize(const AValue: IOptNullSingle; ANormalizer: IPcSingleNormalizer): IOptNullSingle; overload; static;
    // Double (1.12.0)
    class function Map(const AValue: IOptDouble; AFunc: TPcDoubleFunc): IOptDouble; overload; static;
    class function Map(const AValue: INullDouble; AFunc: TPcDoubleFunc): INullDouble; overload; static;
    class function Map(const AValue: IOptNullDouble; AFunc: TPcDoubleFunc): IOptNullDouble; overload; static;
    class function Normalize(const AValue: IOptDouble; ANormalizer: IPcDoubleNormalizer): IOptDouble; overload; static;
    class function Normalize(const AValue: INullDouble; ANormalizer: IPcDoubleNormalizer): INullDouble; overload; static;
    class function Normalize(const AValue: IOptNullDouble; ANormalizer: IPcDoubleNormalizer): IOptNullDouble; overload; static;
    // Currency (1.12.0)
    class function Map(const AValue: IOptCurrency; AFunc: TPcCurrencyFunc): IOptCurrency; overload; static;
    class function Map(const AValue: INullCurrency; AFunc: TPcCurrencyFunc): INullCurrency; overload; static;
    class function Map(const AValue: IOptNullCurrency; AFunc: TPcCurrencyFunc): IOptNullCurrency; overload; static;
    class function Normalize(const AValue: IOptCurrency; ANormalizer: IPcCurrencyNormalizer): IOptCurrency; overload; static;
    class function Normalize(const AValue: INullCurrency; ANormalizer: IPcCurrencyNormalizer): INullCurrency; overload; static;
    class function Normalize(const AValue: IOptNullCurrency; ANormalizer: IPcCurrencyNormalizer): IOptNullCurrency; overload; static;
    // DateTime (1.12.0)
    class function Map(const AValue: IOptDateTime; AFunc: TPcDateTimeFunc): IOptDateTime; overload; static;
    class function Map(const AValue: INullDateTime; AFunc: TPcDateTimeFunc): INullDateTime; overload; static;
    class function Map(const AValue: IOptNullDateTime; AFunc: TPcDateTimeFunc): IOptNullDateTime; overload; static;
    class function Normalize(const AValue: IOptDateTime; ANormalizer: IPcDateTimeNormalizer): IOptDateTime; overload; static;
    class function Normalize(const AValue: INullDateTime; ANormalizer: IPcDateTimeNormalizer): INullDateTime; overload; static;
    class function Normalize(const AValue: IOptNullDateTime; ANormalizer: IPcDateTimeNormalizer): IOptNullDateTime; overload; static;
    // Boolean (1.12.0)
    class function Map(const AValue: IOptBoolean; AFunc: TPcBooleanFunc): IOptBoolean; overload; static;
    class function Map(const AValue: INullBoolean; AFunc: TPcBooleanFunc): INullBoolean; overload; static;
    class function Map(const AValue: IOptNullBoolean; AFunc: TPcBooleanFunc): IOptNullBoolean; overload; static;
    class function Normalize(const AValue: IOptBoolean; ANormalizer: IPcBooleanNormalizer): IOptBoolean; overload; static;
    class function Normalize(const AValue: INullBoolean; ANormalizer: IPcBooleanNormalizer): INullBoolean; overload; static;
    class function Normalize(const AValue: IOptNullBoolean; ANormalizer: IPcBooleanNormalizer): IOptNullBoolean; overload; static;
    // Guid (1.12.0)
    class function Map(const AValue: IOptGuid; AFunc: TPcGuidFunc): IOptGuid; overload; static;
    class function Map(const AValue: INullGuid; AFunc: TPcGuidFunc): INullGuid; overload; static;
    class function Map(const AValue: IOptNullGuid; AFunc: TPcGuidFunc): IOptNullGuid; overload; static;
    class function Normalize(const AValue: IOptGuid; ANormalizer: IPcGuidNormalizer): IOptGuid; overload; static;
    class function Normalize(const AValue: INullGuid; ANormalizer: IPcGuidNormalizer): INullGuid; overload; static;
    class function Normalize(const AValue: IOptNullGuid; ANormalizer: IPcGuidNormalizer): IOptNullGuid; overload; static;
    // String
    class function Safe(const AValue: IOptString): IOptString; overload; static;
    class function Safe(const AValue: INullString): INullString; overload; static;
    class function Safe(const AValue: IOptNullString): IOptNullString; overload; static;
    // Integer
    class function Safe(const AValue: IOptInteger): IOptInteger; overload; static;
    class function Safe(const AValue: INullInteger): INullInteger; overload; static;
    class function Safe(const AValue: IOptNullInteger): IOptNullInteger; overload; static;
    // Int64
    class function Safe(const AValue: IOptInt64): IOptInt64; overload; static;
    class function Safe(const AValue: INullInt64): INullInt64; overload; static;
    class function Safe(const AValue: IOptNullInt64): IOptNullInt64; overload; static;
    // Single
    class function Safe(const AValue: IOptSingle): IOptSingle; overload; static;
    class function Safe(const AValue: INullSingle): INullSingle; overload; static;
    class function Safe(const AValue: IOptNullSingle): IOptNullSingle; overload; static;
    // Double
    class function Safe(const AValue: IOptDouble): IOptDouble; overload; static;
    class function Safe(const AValue: INullDouble): INullDouble; overload; static;
    class function Safe(const AValue: IOptNullDouble): IOptNullDouble; overload; static;
    // DateTime
    class function Safe(const AValue: IOptDateTime): IOptDateTime; overload; static;
    class function Safe(const AValue: INullDateTime): INullDateTime; overload; static;
    class function Safe(const AValue: IOptNullDateTime): IOptNullDateTime; overload; static;
    // Boolean
    class function Safe(const AValue: IOptBoolean): IOptBoolean; overload; static;
    class function Safe(const AValue: INullBoolean): INullBoolean; overload; static;
    class function Safe(const AValue: IOptNullBoolean): IOptNullBoolean; overload; static;
    // Guid
    class function Safe(const AValue: IOptGuid): IOptGuid; overload; static;
    class function Safe(const AValue: INullGuid): INullGuid; overload; static;
    class function Safe(const AValue: IOptNullGuid): IOptNullGuid; overload; static;
    // Currency
    class function Safe(const AValue: IOptCurrency): IOptCurrency; overload; static;
    class function Safe(const AValue: INullCurrency): INullCurrency; overload; static;
    class function Safe(const AValue: IOptNullCurrency): IOptNullCurrency; overload; static;
  end;

  { TOptionalNullableBase }

  TOptionalNullableBase = class(TInterfacedObject,
    IOptionalBase,
    INullableBase,
    IOptionalNullableBase
  )
  private
    FIsNull: Boolean;
    FHasValue: Boolean;
  public
    constructor Create; overload;      // undefined
    constructor CreateNull; overload;  // null
  public
    function IsNull: Boolean;
    function HasValue: Boolean;
  end;

  TOptionalNullable<T> = class(TOptionalNullableBase,
    IOptional<T>,
    INullable<T>,
    IOptionalNullable<T>
  )
  private
    FValue: T;
  public
    constructor Create(AValue: T); overload;
    function GetValue: T;
    /// One method for the three interfaces: only a defined, non-null
    /// instance has a value of its own.
    function ValueOr(const ADefault: T): T;
    property Value: T read GetValue;
  end;

  { TOptNullString }

  TOptNullString = class(TOptionalNullable<string>,
    IOptString, INullString, IOptNullString)
  type
    TCache = TClockCache<string, IOptNullString>;
  private
    const CACHE_SIZE = 2000;
    class var FGlobalNull: IOptNullString;
    class var FGlobalUndefined: IOptNullString;
    class var FGlobalEmpty: IOptNullString;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  private
    // The fluent normalizers. The three flavors declare methods with the
    // same names and different result types, so each one is mapped to its
    // own method. They are private on purpose: reached only through an
    // interface, the object always has a reference while they run.
    function IOptString.Trim = OptTrim;
    function IOptString.Upper = OptUpper;
    function IOptString.Lower = OptLower;
    function IOptString.UndefinedIfEmpty = OptUndefinedIfEmpty;
    function IOptString.Map = OptMap;
    function IOptString.Normalize = OptNormalize;
    function INullString.Trim = NullTrim;
    function INullString.Upper = NullUpper;
    function INullString.Lower = NullLower;
    function INullString.NullIfEmpty = NullNullIfEmpty;
    function INullString.Map = NullMap;
    function INullString.Normalize = NullNormalize;
    function IOptNullString.Trim = OptNullTrim;
    function IOptNullString.Upper = OptNullUpper;
    function IOptNullString.Lower = OptNullLower;
    function IOptNullString.NullIfEmpty = OptNullNullIfEmpty;
    function IOptNullString.UndefinedIfEmpty = OptNullUndefinedIfEmpty;
    function IOptNullString.Map = OptNullMap;
    function IOptNullString.Normalize = OptNullNormalize;
    function AsOpt: IOptString;
    function AsNull: INullString;
    function AsOptNull: IOptNullString;
    function OptTrim: IOptString;
    function OptUpper: IOptString;
    function OptLower: IOptString;
    function OptUndefinedIfEmpty: IOptString;
    function OptMap(AFunc: TPcStringFunc): IOptString;
    function OptNormalize(ANormalizer: IPcStringNormalizer): IOptString;
    function NullTrim: INullString;
    function NullUpper: INullString;
    function NullLower: INullString;
    function NullNullIfEmpty: INullString;
    function NullMap(AFunc: TPcStringFunc): INullString;
    function NullNormalize(ANormalizer: IPcStringNormalizer): INullString;
    function OptNullTrim: IOptNullString;
    function OptNullUpper: IOptNullString;
    function OptNullLower: IOptNullString;
    function OptNullNullIfEmpty: IOptNullString;
    function OptNullUndefinedIfEmpty: IOptNullString;
    function OptNullMap(AFunc: TPcStringFunc): IOptNullString;
    function OptNullNormalize(ANormalizer: IPcStringNormalizer): IOptNullString;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullString; static;
    class function Undefined: TOptNullString; static;
    class function From(AValue: string): TOptNullString; static;
  end;

  { TOptNullInteger }

  TOptNullInteger = class(TOptionalNullable<Integer>,
    IOptInteger, INullInteger, IOptNullInteger)
  type
    TCache = TClockCache<Integer, IOptNullInteger>;
  private
    const FIXED_CACHE_MIN = -1;
    const FIXED_CACHE_MAX = 20;
    const CACHE_SIZE = 2000;
    class var FGlobalNull: IOptNullInteger;
    class var FGlobalUndefined: IOptNullInteger;
    class var FGlobalCacheFixed: array[FIXED_CACHE_MIN..FIXED_CACHE_MAX] of IOptNullInteger;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  private
    // Map and Normalize for the three flavors (1.12.0), mapped like the
    // string ones in TOptNullString.
    function IOptInteger.Map = OptMap;
    function IOptInteger.Normalize = OptNormalize;
    function INullInteger.Map = NullMap;
    function INullInteger.Normalize = NullNormalize;
    function IOptNullInteger.Map = OptNullMap;
    function IOptNullInteger.Normalize = OptNullNormalize;
    function AsOpt: IOptInteger;
    function AsNull: INullInteger;
    function AsOptNull: IOptNullInteger;
    function OptMap(AFunc: TPcIntegerFunc): IOptInteger;
    function OptNormalize(ANormalizer: IPcIntegerNormalizer): IOptInteger;
    function NullMap(AFunc: TPcIntegerFunc): INullInteger;
    function NullNormalize(ANormalizer: IPcIntegerNormalizer): INullInteger;
    function OptNullMap(AFunc: TPcIntegerFunc): IOptNullInteger;
    function OptNullNormalize(ANormalizer: IPcIntegerNormalizer): IOptNullInteger;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullInteger; static;
    class function Undefined: TOptNullInteger; static;
    class function From(AValue: Integer): TOptNullInteger; static;
  end;

  { TOptNullInt64 }

  TOptNullInt64 = class(TOptionalNullable<Int64>,
    IOptInt64, INullInt64, IOptNullInt64)
  type
    TCache = TClockCache<Int64, IOptNullInt64>;
  private
    const FIXED_CACHE_MIN = -1;
    const FIXED_CACHE_MAX = 20;
    const CACHE_SIZE = 100;
    class var FGlobalNull: IOptNullInt64;
    class var FGlobalUndefined: IOptNullInt64;
    class var FGlobalCacheFixed: array[FIXED_CACHE_MIN..FIXED_CACHE_MAX] of IOptNullInt64;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  private
    // Map and Normalize for the three flavors (1.12.0), mapped like the
    // string ones in TOptNullString.
    function IOptInt64.Map = OptMap;
    function IOptInt64.Normalize = OptNormalize;
    function INullInt64.Map = NullMap;
    function INullInt64.Normalize = NullNormalize;
    function IOptNullInt64.Map = OptNullMap;
    function IOptNullInt64.Normalize = OptNullNormalize;
    function AsOpt: IOptInt64;
    function AsNull: INullInt64;
    function AsOptNull: IOptNullInt64;
    function OptMap(AFunc: TPcInt64Func): IOptInt64;
    function OptNormalize(ANormalizer: IPcInt64Normalizer): IOptInt64;
    function NullMap(AFunc: TPcInt64Func): INullInt64;
    function NullNormalize(ANormalizer: IPcInt64Normalizer): INullInt64;
    function OptNullMap(AFunc: TPcInt64Func): IOptNullInt64;
    function OptNullNormalize(ANormalizer: IPcInt64Normalizer): IOptNullInt64;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullInt64; static;
    class function Undefined: TOptNullInt64; static;
    class function From(AValue: Int64): TOptNullInt64; static;
  end;

  { TOptNullSingle }

  TOptNullSingle = class(TOptionalNullable<Single>,
    IOptSingle, INullSingle, IOptNullSingle, IDecimalPrecision)
  type
    TCacheKey = record
      Value: Single;
      Precision: Integer;
      class operator Equal(const A, B: TCacheKey): Boolean;
    end;
    TCache = TClockCache<TCacheKey, IOptNullSingle>;
  private
    FDecimalPlaces: Integer;
  public
    constructor Create(AValue: Single; ADecimalPlaces: Integer); overload;
    function GetDecimalPlaces: Integer;
  private
    const CACHE_SIZE = 2000;
    class var FGlobalNull: IOptNullSingle;
    class var FGlobalUndefined: IOptNullSingle;
    class var FGlobalZero: IOptNullSingle;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  private
    // Map and Normalize for the three flavors (1.12.0), mapped like the
    // string ones in TOptNullString.
    function IOptSingle.Map = OptMap;
    function IOptSingle.Normalize = OptNormalize;
    function INullSingle.Map = NullMap;
    function INullSingle.Normalize = NullNormalize;
    function IOptNullSingle.Map = OptNullMap;
    function IOptNullSingle.Normalize = OptNullNormalize;
    function AsOpt: IOptSingle;
    function AsNull: INullSingle;
    function AsOptNull: IOptNullSingle;
    function OptMap(AFunc: TPcSingleFunc): IOptSingle;
    function OptNormalize(ANormalizer: IPcSingleNormalizer): IOptSingle;
    function NullMap(AFunc: TPcSingleFunc): INullSingle;
    function NullNormalize(ANormalizer: IPcSingleNormalizer): INullSingle;
    function OptNullMap(AFunc: TPcSingleFunc): IOptNullSingle;
    function OptNullNormalize(ANormalizer: IPcSingleNormalizer): IOptNullSingle;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullSingle; static;
    class function Undefined: TOptNullSingle; static;
    class function From(AValue: Single; ADecimalPlaces: Integer=-1): TOptNullSingle; static;
  end;

  { TOptNullDouble }

  TOptNullDouble = class(TOptionalNullable<Double>,
    IOptDouble, INullDouble, IOptNullDouble, IDecimalPrecision)
  type
    TCacheKey = record
      Value: Double;
      Precision: Integer;
      class operator Equal(const A, B: TCacheKey): Boolean;
    end;
    TCache = TClockCache<TCacheKey, IOptNullDouble>;
  private
    FDecimalPlaces: Integer;
  public
    constructor Create(AValue: Double; ADecimalPlaces: Integer); overload;
    function GetDecimalPlaces: Integer;
  private
    const CACHE_SIZE = 2000;
    class var FGlobalNull: IOptNullDouble;
    class var FGlobalUndefined: IOptNullDouble;
    class var FGlobalZero: IOptNullDouble;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  private
    // Map and Normalize for the three flavors (1.12.0), mapped like the
    // string ones in TOptNullString.
    function IOptDouble.Map = OptMap;
    function IOptDouble.Normalize = OptNormalize;
    function INullDouble.Map = NullMap;
    function INullDouble.Normalize = NullNormalize;
    function IOptNullDouble.Map = OptNullMap;
    function IOptNullDouble.Normalize = OptNullNormalize;
    function AsOpt: IOptDouble;
    function AsNull: INullDouble;
    function AsOptNull: IOptNullDouble;
    function OptMap(AFunc: TPcDoubleFunc): IOptDouble;
    function OptNormalize(ANormalizer: IPcDoubleNormalizer): IOptDouble;
    function NullMap(AFunc: TPcDoubleFunc): INullDouble;
    function NullNormalize(ANormalizer: IPcDoubleNormalizer): INullDouble;
    function OptNullMap(AFunc: TPcDoubleFunc): IOptNullDouble;
    function OptNullNormalize(ANormalizer: IPcDoubleNormalizer): IOptNullDouble;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullDouble; static;
    class function Undefined: TOptNullDouble; static;
    class function From(AValue: Double; ADecimalPlaces: Integer=-1): TOptNullDouble; static;
  end;

  { TOptNullDateTime }

  TOptNullDateTime = class(TOptionalNullable<TDateTime>,
    IOptDateTime, INullDateTime, IOptNullDateTime)
  type
    TCache = TClockCache<TDateTime, IOptNullDateTime>;
  private
    const CACHE_SIZE_DATE = 500;
    const CACHE_SIZE_TIME = 1000;
    class var FGlobalNull: IOptNullDateTime;
    class var FGlobalUndefined: IOptNullDateTime;
    class var FGlobalCacheDate: TCache;
    class var FLockCacheDate: TCriticalSection;
    class var FGlobalCacheTime: TCache;
    class var FLockCacheTime: TCriticalSection;
  private
    // Map and Normalize for the three flavors (1.12.0), mapped like the
    // string ones in TOptNullString.
    function IOptDateTime.Map = OptMap;
    function IOptDateTime.Normalize = OptNormalize;
    function INullDateTime.Map = NullMap;
    function INullDateTime.Normalize = NullNormalize;
    function IOptNullDateTime.Map = OptNullMap;
    function IOptNullDateTime.Normalize = OptNullNormalize;
    function AsOpt: IOptDateTime;
    function AsNull: INullDateTime;
    function AsOptNull: IOptNullDateTime;
    function OptMap(AFunc: TPcDateTimeFunc): IOptDateTime;
    function OptNormalize(ANormalizer: IPcDateTimeNormalizer): IOptDateTime;
    function NullMap(AFunc: TPcDateTimeFunc): INullDateTime;
    function NullNormalize(ANormalizer: IPcDateTimeNormalizer): INullDateTime;
    function OptNullMap(AFunc: TPcDateTimeFunc): IOptNullDateTime;
    function OptNullNormalize(ANormalizer: IPcDateTimeNormalizer): IOptNullDateTime;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullDateTime; static;
    class function Undefined: TOptNullDateTime; static;
    class function From(AValue: TDateTime): TOptNullDateTime; static;
  end;

  { TOptNullBoolean }

  TOptNullBoolean = class(TOptionalNullable<Boolean>,
    IOptBoolean, INullBoolean, IOptNullBoolean)
  private
    class var FGlobalNull: IOptNullBoolean;
    class var FGlobalUndefined: IOptNullBoolean;
    class var FGlobalTrue: IOptNullBoolean;
    class var FGlobalFalse: IOptNullBoolean;
  private
    // Map and Normalize for the three flavors (1.12.0), mapped like the
    // string ones in TOptNullString.
    function IOptBoolean.Map = OptMap;
    function IOptBoolean.Normalize = OptNormalize;
    function INullBoolean.Map = NullMap;
    function INullBoolean.Normalize = NullNormalize;
    function IOptNullBoolean.Map = OptNullMap;
    function IOptNullBoolean.Normalize = OptNullNormalize;
    function AsOpt: IOptBoolean;
    function AsNull: INullBoolean;
    function AsOptNull: IOptNullBoolean;
    function OptMap(AFunc: TPcBooleanFunc): IOptBoolean;
    function OptNormalize(ANormalizer: IPcBooleanNormalizer): IOptBoolean;
    function NullMap(AFunc: TPcBooleanFunc): INullBoolean;
    function NullNormalize(ANormalizer: IPcBooleanNormalizer): INullBoolean;
    function OptNullMap(AFunc: TPcBooleanFunc): IOptNullBoolean;
    function OptNullNormalize(ANormalizer: IPcBooleanNormalizer): IOptNullBoolean;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullBoolean; static;
    class function Undefined: TOptNullBoolean; static;
    class function TrueValue: TOptNullBoolean; static;
    class function FalseValue: TOptNullBoolean; static;
    /// TrueValue or FalseValue, as the interface IOptNullBoolean. Unlike
    /// every other optional's From, which returns its class, this one can't
    /// go into an IOptBoolean or an INullBoolean: write
    /// TOptNullBoolean.TrueValue/FalseValue there (they return the class),
    /// or From(B) as IOptBoolean. An oversight kept for compatibility;
    /// docs/plan.md, "Planned for 2.0", returns the class.
    class function From(AValue: Boolean): IOptNullBoolean; static;
  end;

  { TOptNullGuid }

  TOptNullGuid = class(TOptionalNullable<TGUID>,
    IOptGuid, INullGuid, IOptNullGuid)
  type
    TCache = TClockCache<TGUID, IOptNullGuid>;
  private
    const CACHE_SIZE = 100;
    class var FGlobalNull: IOptNullGuid;
    class var FGlobalUndefined: IOptNullGuid;
    class var FGlobalEmpty: IOptNullGuid;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  private
    // Map and Normalize for the three flavors (1.12.0), mapped like the
    // string ones in TOptNullString.
    function IOptGuid.Map = OptMap;
    function IOptGuid.Normalize = OptNormalize;
    function INullGuid.Map = NullMap;
    function INullGuid.Normalize = NullNormalize;
    function IOptNullGuid.Map = OptNullMap;
    function IOptNullGuid.Normalize = OptNullNormalize;
    function AsOpt: IOptGuid;
    function AsNull: INullGuid;
    function AsOptNull: IOptNullGuid;
    function OptMap(AFunc: TPcGuidFunc): IOptGuid;
    function OptNormalize(ANormalizer: IPcGuidNormalizer): IOptGuid;
    function NullMap(AFunc: TPcGuidFunc): INullGuid;
    function NullNormalize(ANormalizer: IPcGuidNormalizer): INullGuid;
    function OptNullMap(AFunc: TPcGuidFunc): IOptNullGuid;
    function OptNullNormalize(ANormalizer: IPcGuidNormalizer): IOptNullGuid;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullGuid; static;
    class function Undefined: TOptNullGuid; static;
    class function From(AValue: TGUID): TOptNullGuid; static;
  end;

  { TOptNullCurrency }

  TOptNullCurrency = class(TOptionalNullable<Currency>,
    IOptCurrency, INullCurrency, IOptNullCurrency)
  type
    TCache = TClockCache<Currency, IOptNullCurrency>;
  private
    const CACHE_SIZE = 500;
    class var FGlobalNull: IOptNullCurrency;
    class var FGlobalUndefined: IOptNullCurrency;
    class var FGlobalZero: IOptNullCurrency;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  private
    // Map and Normalize for the three flavors (1.12.0), mapped like the
    // string ones in TOptNullString.
    function IOptCurrency.Map = OptMap;
    function IOptCurrency.Normalize = OptNormalize;
    function INullCurrency.Map = NullMap;
    function INullCurrency.Normalize = NullNormalize;
    function IOptNullCurrency.Map = OptNullMap;
    function IOptNullCurrency.Normalize = OptNullNormalize;
    function AsOpt: IOptCurrency;
    function AsNull: INullCurrency;
    function AsOptNull: IOptNullCurrency;
    function OptMap(AFunc: TPcCurrencyFunc): IOptCurrency;
    function OptNormalize(ANormalizer: IPcCurrencyNormalizer): IOptCurrency;
    function NullMap(AFunc: TPcCurrencyFunc): INullCurrency;
    function NullNormalize(ANormalizer: IPcCurrencyNormalizer): INullCurrency;
    function OptNullMap(AFunc: TPcCurrencyFunc): IOptNullCurrency;
    function OptNullNormalize(ANormalizer: IPcCurrencyNormalizer): IOptNullCurrency;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullCurrency; static;
    class function Undefined: TOptNullCurrency; static;
    class function From(AValue: Currency): TOptNullCurrency; static;
  end;

implementation

uses
  PascalCommon.Text;

const
  // TGuid.Empty comes from Delphi's TGuidHelper record helper, which doesn't
  // exist in FPC 3.2.2 — a typed constant works on both.
  EMPTY_GUID: TGUID = '{00000000-0000-0000-0000-000000000000}';

{ Comparers for the TOptNullSingle/TOptNullDouble cache keys.

  Named functions instead of closures: TEqualityComparer<T>.Construct accepts
  "reference to function" in Delphi, but FPC 3.2.2 only accepts a plain
  function pointer or "of object" (there are no anonymous functions in the
  stable compiler). A named function is accepted by both. The signature
  differs too: FPC's rtl-generics declares IEqualityComparer<T> with
  "constref" and a UInt32 hash; Delphi uses "const" and an Integer hash. }

function SingleKeyEquals({$IFDEF FPC}constref{$ELSE}const{$ENDIF} L, R: TOptNullSingle.TCacheKey): Boolean;
begin
  Result := (L.Value = R.Value) and (L.Precision = R.Precision);
end;

function SingleKeyHash({$IFDEF FPC}constref{$ELSE}const{$ENDIF} V: TOptNullSingle.TCacheKey): {$IFDEF FPC}UInt32{$ELSE}Integer{$ENDIF};
var
  LHash: Integer;
begin
  LHash := BobJenkinsHash(V.Value, SizeOf(Single), 0);
  LHash := BobJenkinsHash(V.Precision, SizeOf(Integer), LHash);
  Result := {$IFDEF FPC}UInt32(LHash){$ELSE}LHash{$ENDIF};
end;

function DoubleKeyEquals({$IFDEF FPC}constref{$ELSE}const{$ENDIF} L, R: TOptNullDouble.TCacheKey): Boolean;
begin
  Result := (L.Value = R.Value) and (L.Precision = R.Precision);
end;

function DoubleKeyHash({$IFDEF FPC}constref{$ELSE}const{$ENDIF} V: TOptNullDouble.TCacheKey): {$IFDEF FPC}UInt32{$ELSE}Integer{$ENDIF};
var
  LHash: Integer;
begin
  LHash := BobJenkinsHash(V.Value, SizeOf(Double), 0);
  LHash := BobJenkinsHash(V.Precision, SizeOf(Integer), LHash);
  Result := {$IFDEF FPC}UInt32(LHash){$ELSE}LHash{$ENDIF};
end;

{ String normalizers.

  The state is read through the flavor's own interface (HasValue or IsNull)
  and, for the state that flavor can't express, through the object behind
  it: TOptNullString implements the three flavors, so TOptNullString.Null
  assigned to an IOptString has HasValue = True and Value = '', and
  TOptNullString.Undefined assigned to an INullString has IsNull = False and
  Value = ''. Without the Supports check, Trim would turn either one into a
  made-up ''. They are returned unchanged instead. }

function NormTrim(const AValue: string): string;
begin
  Result := SysUtils.Trim(AValue);
end;

{ Upper and lower case: PascalCommon.Text, which doesn't depend on the
  process locale on FPC/Unix (gotcha 10). }

function NormUpper(const AValue: string): string;
begin
  Result := PcUpperCase(AValue);
end;

function NormLower(const AValue: string): string;
begin
  Result := PcLowerCase(AValue);
end;

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

procedure CheckFunc(AFunc: TPcStringFunc);
begin
  if not Assigned(AFunc) then
    raise EArgumentException.Create('TOptionals.Map: AFunc is nil');
end;

procedure CheckNormalizer(ANormalizer: IPcStringNormalizer);
begin
  if not Assigned(ANormalizer) then
    raise EArgumentException.Create('TOptionals.Normalize: ANormalizer is nil');
end;

{ The helpers below take the transformation as a function or as a
  normalizer (exactly one of them assigned), so the function form, used by
  Trim/Upper/Lower on every call, doesn't allocate a wrapper object. }

function Transform(AFunc: TPcStringFunc; ANormalizer: IPcStringNormalizer;
  const AValue: string): string;
begin
  if Assigned(AFunc) then
    Result := AFunc(AValue)
  else
    Result := ANormalizer.Apply(AValue);
end;

function MapOpt(const AValue: IOptString; AFunc: TPcStringFunc;
  ANormalizer: IPcStringNormalizer = nil): IOptString;
var
  LOld, LNew: string;
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenNull(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  LNew := Transform(AFunc, ANormalizer, LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullString.From(LNew);
end;

function MapNull(const AValue: INullString; AFunc: TPcStringFunc;
  ANormalizer: IPcStringNormalizer = nil): INullString;
var
  LOld, LNew: string;
begin
  if not Assigned(AValue) or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenUndefined(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  LNew := Transform(AFunc, ANormalizer, LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullString.From(LNew);
end;

function MapOptNull(const AValue: IOptNullString; AFunc: TPcStringFunc;
  ANormalizer: IPcStringNormalizer = nil): IOptNullString;
var
  LOld, LNew: string;
begin
  if not Assigned(AValue) or not AValue.HasValue or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  LOld := AValue.Value;
  LNew := Transform(AFunc, ANormalizer, LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullString.From(LNew);
end;

{ Map and Normalize for the other types: the same steps as MapOpt, MapNull
  and MapOptNull above, one set per type (generated; keep them alike). }

procedure RaiseNilMapArgument(const AName: string);
begin
  raise EArgumentException.Create('TOptionals.' + AName + ' is nil');
end;

function BooleanOf(AValue: Boolean): TOptNullBoolean;
begin
  if AValue then
    Result := TOptNullBoolean.TrueValue
  else
    Result := TOptNullBoolean.FalseValue;
end;

function MapOptInteger(const AValue: IOptInteger; AFunc: TPcIntegerFunc;
  ANormalizer: IPcIntegerNormalizer): IOptInteger;
var
  LOld, LNew: Integer;
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenNull(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullInteger.From(LNew);
end;

function MapNullInteger(const AValue: INullInteger; AFunc: TPcIntegerFunc;
  ANormalizer: IPcIntegerNormalizer): INullInteger;
var
  LOld, LNew: Integer;
begin
  if not Assigned(AValue) or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenUndefined(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullInteger.From(LNew);
end;

function MapOptNullInteger(const AValue: IOptNullInteger; AFunc: TPcIntegerFunc;
  ANormalizer: IPcIntegerNormalizer): IOptNullInteger;
var
  LOld, LNew: Integer;
begin
  if not Assigned(AValue) or not AValue.HasValue or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullInteger.From(LNew);
end;

function MapOptInt64(const AValue: IOptInt64; AFunc: TPcInt64Func;
  ANormalizer: IPcInt64Normalizer): IOptInt64;
var
  LOld, LNew: Int64;
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenNull(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullInt64.From(LNew);
end;

function MapNullInt64(const AValue: INullInt64; AFunc: TPcInt64Func;
  ANormalizer: IPcInt64Normalizer): INullInt64;
var
  LOld, LNew: Int64;
begin
  if not Assigned(AValue) or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenUndefined(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullInt64.From(LNew);
end;

function MapOptNullInt64(const AValue: IOptNullInt64; AFunc: TPcInt64Func;
  ANormalizer: IPcInt64Normalizer): IOptNullInt64;
var
  LOld, LNew: Int64;
begin
  if not Assigned(AValue) or not AValue.HasValue or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullInt64.From(LNew);
end;

function MapOptSingle(const AValue: IOptSingle; AFunc: TPcSingleFunc;
  ANormalizer: IPcSingleNormalizer): IOptSingle;
var
  LOld, LNew: Single;
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenNull(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullSingle.From(LNew, AValue.DecimalPlaces);
end;

function MapNullSingle(const AValue: INullSingle; AFunc: TPcSingleFunc;
  ANormalizer: IPcSingleNormalizer): INullSingle;
var
  LOld, LNew: Single;
begin
  if not Assigned(AValue) or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenUndefined(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullSingle.From(LNew, AValue.DecimalPlaces);
end;

function MapOptNullSingle(const AValue: IOptNullSingle; AFunc: TPcSingleFunc;
  ANormalizer: IPcSingleNormalizer): IOptNullSingle;
var
  LOld, LNew: Single;
begin
  if not Assigned(AValue) or not AValue.HasValue or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullSingle.From(LNew, AValue.DecimalPlaces);
end;

function MapOptDouble(const AValue: IOptDouble; AFunc: TPcDoubleFunc;
  ANormalizer: IPcDoubleNormalizer): IOptDouble;
var
  LOld, LNew: Double;
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenNull(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullDouble.From(LNew, AValue.DecimalPlaces);
end;

function MapNullDouble(const AValue: INullDouble; AFunc: TPcDoubleFunc;
  ANormalizer: IPcDoubleNormalizer): INullDouble;
var
  LOld, LNew: Double;
begin
  if not Assigned(AValue) or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenUndefined(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullDouble.From(LNew, AValue.DecimalPlaces);
end;

function MapOptNullDouble(const AValue: IOptNullDouble; AFunc: TPcDoubleFunc;
  ANormalizer: IPcDoubleNormalizer): IOptNullDouble;
var
  LOld, LNew: Double;
begin
  if not Assigned(AValue) or not AValue.HasValue or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullDouble.From(LNew, AValue.DecimalPlaces);
end;

function MapOptCurrency(const AValue: IOptCurrency; AFunc: TPcCurrencyFunc;
  ANormalizer: IPcCurrencyNormalizer): IOptCurrency;
var
  LOld, LNew: Currency;
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenNull(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullCurrency.From(LNew);
end;

function MapNullCurrency(const AValue: INullCurrency; AFunc: TPcCurrencyFunc;
  ANormalizer: IPcCurrencyNormalizer): INullCurrency;
var
  LOld, LNew: Currency;
begin
  if not Assigned(AValue) or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenUndefined(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullCurrency.From(LNew);
end;

function MapOptNullCurrency(const AValue: IOptNullCurrency; AFunc: TPcCurrencyFunc;
  ANormalizer: IPcCurrencyNormalizer): IOptNullCurrency;
var
  LOld, LNew: Currency;
begin
  if not Assigned(AValue) or not AValue.HasValue or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullCurrency.From(LNew);
end;

function MapOptDateTime(const AValue: IOptDateTime; AFunc: TPcDateTimeFunc;
  ANormalizer: IPcDateTimeNormalizer): IOptDateTime;
var
  LOld, LNew: TDateTime;
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenNull(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullDateTime.From(LNew);
end;

function MapNullDateTime(const AValue: INullDateTime; AFunc: TPcDateTimeFunc;
  ANormalizer: IPcDateTimeNormalizer): INullDateTime;
var
  LOld, LNew: TDateTime;
begin
  if not Assigned(AValue) or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenUndefined(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullDateTime.From(LNew);
end;

function MapOptNullDateTime(const AValue: IOptNullDateTime; AFunc: TPcDateTimeFunc;
  ANormalizer: IPcDateTimeNormalizer): IOptNullDateTime;
var
  LOld, LNew: TDateTime;
begin
  if not Assigned(AValue) or not AValue.HasValue or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := TOptNullDateTime.From(LNew);
end;

function MapOptBoolean(const AValue: IOptBoolean; AFunc: TPcBooleanFunc;
  ANormalizer: IPcBooleanNormalizer): IOptBoolean;
var
  LOld, LNew: Boolean;
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenNull(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := BooleanOf(LNew);
end;

function MapNullBoolean(const AValue: INullBoolean; AFunc: TPcBooleanFunc;
  ANormalizer: IPcBooleanNormalizer): INullBoolean;
var
  LOld, LNew: Boolean;
begin
  if not Assigned(AValue) or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenUndefined(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := BooleanOf(LNew);
end;

function MapOptNullBoolean(const AValue: IOptNullBoolean; AFunc: TPcBooleanFunc;
  ANormalizer: IPcBooleanNormalizer): IOptNullBoolean;
var
  LOld, LNew: Boolean;
begin
  if not Assigned(AValue) or not AValue.HasValue or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if LNew = LOld then
    Result := AValue
  else
    Result := BooleanOf(LNew);
end;

function MapOptGuid(const AValue: IOptGuid; AFunc: TPcGuidFunc;
  ANormalizer: IPcGuidNormalizer): IOptGuid;
var
  LOld, LNew: TGUID;
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenNull(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if IsEqualGUID(LNew, LOld) then
    Result := AValue
  else
    Result := TOptNullGuid.From(LNew);
end;

function MapNullGuid(const AValue: INullGuid; AFunc: TPcGuidFunc;
  ANormalizer: IPcGuidNormalizer): INullGuid;
var
  LOld, LNew: TGUID;
begin
  if not Assigned(AValue) or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  if IsHiddenUndefined(AValue) then
    Exit(AValue);
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if IsEqualGUID(LNew, LOld) then
    Result := AValue
  else
    Result := TOptNullGuid.From(LNew);
end;

function MapOptNullGuid(const AValue: IOptNullGuid; AFunc: TPcGuidFunc;
  ANormalizer: IPcGuidNormalizer): IOptNullGuid;
var
  LOld, LNew: TGUID;
begin
  if not Assigned(AValue) or not AValue.HasValue or AValue.IsNull then
    Exit(TOptionals.Safe(AValue));
  LOld := AValue.Value;
  if Assigned(AFunc) then
    LNew := AFunc(LOld)
  else
    LNew := ANormalizer.Apply(LOld);
  if IsEqualGUID(LNew, LOld) then
    Result := AValue
  else
    Result := TOptNullGuid.From(LNew);
end;

{ TOptionals }

class function TOptionals.Trim(const AValue: IOptString): IOptString;
begin
  Result := MapOpt(AValue, NormTrim);
end;

class function TOptionals.Trim(const AValue: INullString): INullString;
begin
  Result := MapNull(AValue, NormTrim);
end;

class function TOptionals.Trim(const AValue: IOptNullString): IOptNullString;
begin
  Result := MapOptNull(AValue, NormTrim);
end;

class function TOptionals.Upper(const AValue: IOptString): IOptString;
begin
  Result := MapOpt(AValue, NormUpper);
end;

class function TOptionals.Upper(const AValue: INullString): INullString;
begin
  Result := MapNull(AValue, NormUpper);
end;

class function TOptionals.Upper(const AValue: IOptNullString): IOptNullString;
begin
  Result := MapOptNull(AValue, NormUpper);
end;

class function TOptionals.Lower(const AValue: IOptString): IOptString;
begin
  Result := MapOpt(AValue, NormLower);
end;

class function TOptionals.Lower(const AValue: INullString): INullString;
begin
  Result := MapNull(AValue, NormLower);
end;

class function TOptionals.Lower(const AValue: IOptNullString): IOptNullString;
begin
  Result := MapOptNull(AValue, NormLower);
end;

class function TOptionals.NullIfEmpty(const AValue: INullString): INullString;
begin
  Result := Safe(AValue);
  if not Result.IsNull and not IsHiddenUndefined(Result) and (Result.Value = '') then
    Result := TOptNullString.Null;
end;

class function TOptionals.NullIfEmpty(const AValue: IOptNullString): IOptNullString;
begin
  Result := Safe(AValue);
  if Result.HasValue and not Result.IsNull and (Result.Value = '') then
    Result := TOptNullString.Null;
end;

class function TOptionals.UndefinedIfEmpty(const AValue: IOptString): IOptString;
begin
  Result := Safe(AValue);
  if Result.HasValue and not IsHiddenNull(Result) and (Result.Value = '') then
    Result := TOptNullString.Undefined;
end;

class function TOptionals.UndefinedIfEmpty(const AValue: IOptNullString): IOptNullString;
begin
  Result := Safe(AValue);
  if Result.HasValue and not Result.IsNull and (Result.Value = '') then
    Result := TOptNullString.Undefined;
end;

class function TOptionals.Map(const AValue: IOptString; AFunc: TPcStringFunc): IOptString;
begin
  CheckFunc(AFunc);
  Result := MapOpt(AValue, AFunc);
end;

class function TOptionals.Map(const AValue: INullString; AFunc: TPcStringFunc): INullString;
begin
  CheckFunc(AFunc);
  Result := MapNull(AValue, AFunc);
end;

class function TOptionals.Map(const AValue: IOptNullString; AFunc: TPcStringFunc): IOptNullString;
begin
  CheckFunc(AFunc);
  Result := MapOptNull(AValue, AFunc);
end;

class function TOptionals.Normalize(const AValue: IOptString; ANormalizer: IPcStringNormalizer): IOptString;
begin
  CheckNormalizer(ANormalizer);
  Result := MapOpt(AValue, nil, ANormalizer);
end;

class function TOptionals.Normalize(const AValue: INullString; ANormalizer: IPcStringNormalizer): INullString;
begin
  CheckNormalizer(ANormalizer);
  Result := MapNull(AValue, nil, ANormalizer);
end;

class function TOptionals.Normalize(const AValue: IOptNullString; ANormalizer: IPcStringNormalizer): IOptNullString;
begin
  CheckNormalizer(ANormalizer);
  Result := MapOptNull(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptInteger; AFunc: TPcIntegerFunc): IOptInteger;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptInteger(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptInteger; ANormalizer: IPcIntegerNormalizer): IOptInteger;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptInteger(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: INullInteger; AFunc: TPcIntegerFunc): INullInteger;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapNullInteger(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: INullInteger; ANormalizer: IPcIntegerNormalizer): INullInteger;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapNullInteger(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptNullInteger; AFunc: TPcIntegerFunc): IOptNullInteger;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptNullInteger(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptNullInteger; ANormalizer: IPcIntegerNormalizer): IOptNullInteger;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptNullInteger(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptInt64; AFunc: TPcInt64Func): IOptInt64;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptInt64(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptInt64; ANormalizer: IPcInt64Normalizer): IOptInt64;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptInt64(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: INullInt64; AFunc: TPcInt64Func): INullInt64;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapNullInt64(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: INullInt64; ANormalizer: IPcInt64Normalizer): INullInt64;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapNullInt64(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptNullInt64; AFunc: TPcInt64Func): IOptNullInt64;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptNullInt64(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptNullInt64; ANormalizer: IPcInt64Normalizer): IOptNullInt64;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptNullInt64(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptSingle; AFunc: TPcSingleFunc): IOptSingle;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptSingle(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptSingle; ANormalizer: IPcSingleNormalizer): IOptSingle;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptSingle(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: INullSingle; AFunc: TPcSingleFunc): INullSingle;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapNullSingle(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: INullSingle; ANormalizer: IPcSingleNormalizer): INullSingle;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapNullSingle(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptNullSingle; AFunc: TPcSingleFunc): IOptNullSingle;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptNullSingle(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptNullSingle; ANormalizer: IPcSingleNormalizer): IOptNullSingle;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptNullSingle(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptDouble; AFunc: TPcDoubleFunc): IOptDouble;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptDouble(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptDouble; ANormalizer: IPcDoubleNormalizer): IOptDouble;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptDouble(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: INullDouble; AFunc: TPcDoubleFunc): INullDouble;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapNullDouble(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: INullDouble; ANormalizer: IPcDoubleNormalizer): INullDouble;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapNullDouble(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptNullDouble; AFunc: TPcDoubleFunc): IOptNullDouble;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptNullDouble(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptNullDouble; ANormalizer: IPcDoubleNormalizer): IOptNullDouble;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptNullDouble(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptCurrency; AFunc: TPcCurrencyFunc): IOptCurrency;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptCurrency(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptCurrency; ANormalizer: IPcCurrencyNormalizer): IOptCurrency;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptCurrency(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: INullCurrency; AFunc: TPcCurrencyFunc): INullCurrency;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapNullCurrency(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: INullCurrency; ANormalizer: IPcCurrencyNormalizer): INullCurrency;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapNullCurrency(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptNullCurrency; AFunc: TPcCurrencyFunc): IOptNullCurrency;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptNullCurrency(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptNullCurrency; ANormalizer: IPcCurrencyNormalizer): IOptNullCurrency;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptNullCurrency(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptDateTime; AFunc: TPcDateTimeFunc): IOptDateTime;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptDateTime(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptDateTime; ANormalizer: IPcDateTimeNormalizer): IOptDateTime;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptDateTime(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: INullDateTime; AFunc: TPcDateTimeFunc): INullDateTime;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapNullDateTime(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: INullDateTime; ANormalizer: IPcDateTimeNormalizer): INullDateTime;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapNullDateTime(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptNullDateTime; AFunc: TPcDateTimeFunc): IOptNullDateTime;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptNullDateTime(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptNullDateTime; ANormalizer: IPcDateTimeNormalizer): IOptNullDateTime;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptNullDateTime(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptBoolean; AFunc: TPcBooleanFunc): IOptBoolean;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptBoolean(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptBoolean; ANormalizer: IPcBooleanNormalizer): IOptBoolean;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptBoolean(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: INullBoolean; AFunc: TPcBooleanFunc): INullBoolean;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapNullBoolean(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: INullBoolean; ANormalizer: IPcBooleanNormalizer): INullBoolean;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapNullBoolean(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptNullBoolean; AFunc: TPcBooleanFunc): IOptNullBoolean;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptNullBoolean(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptNullBoolean; ANormalizer: IPcBooleanNormalizer): IOptNullBoolean;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptNullBoolean(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptGuid; AFunc: TPcGuidFunc): IOptGuid;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptGuid(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptGuid; ANormalizer: IPcGuidNormalizer): IOptGuid;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptGuid(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: INullGuid; AFunc: TPcGuidFunc): INullGuid;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapNullGuid(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: INullGuid; ANormalizer: IPcGuidNormalizer): INullGuid;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapNullGuid(AValue, nil, ANormalizer);
end;

class function TOptionals.Map(const AValue: IOptNullGuid; AFunc: TPcGuidFunc): IOptNullGuid;
begin
  if not Assigned(AFunc) then
    RaiseNilMapArgument('Map: AFunc');
  Result := MapOptNullGuid(AValue, AFunc, nil);
end;

class function TOptionals.Normalize(const AValue: IOptNullGuid; ANormalizer: IPcGuidNormalizer): IOptNullGuid;
begin
  if not Assigned(ANormalizer) then
    RaiseNilMapArgument('Normalize: ANormalizer');
  Result := MapOptNullGuid(AValue, nil, ANormalizer);
end;

class function TOptionals.Safe(const AValue: IOptString): IOptString;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullString.Undefined;
end;

class function TOptionals.Safe(const AValue: INullString): INullString;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullString.Null;
end;

class function TOptionals.Safe(const AValue: IOptNullString): IOptNullString;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullString.Undefined;
end;

class function TOptionals.Safe(const AValue: IOptInteger): IOptInteger;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullInteger.Undefined;
end;

class function TOptionals.Safe(const AValue: INullInteger): INullInteger;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullInteger.Null;
end;

class function TOptionals.Safe(const AValue: IOptNullInteger): IOptNullInteger;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullInteger.Undefined;
end;

class function TOptionals.Safe(const AValue: IOptInt64): IOptInt64;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullInt64.Undefined;
end;

class function TOptionals.Safe(const AValue: INullInt64): INullInt64;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullInt64.Null;
end;

class function TOptionals.Safe(const AValue: IOptNullInt64): IOptNullInt64;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullInt64.Undefined;
end;

class function TOptionals.Safe(const AValue: IOptSingle): IOptSingle;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullSingle.Undefined;
end;

class function TOptionals.Safe(const AValue: INullSingle): INullSingle;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullSingle.Null;
end;

class function TOptionals.Safe(const AValue: IOptNullSingle): IOptNullSingle;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullSingle.Undefined;
end;

class function TOptionals.Safe(const AValue: IOptDouble): IOptDouble;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullDouble.Undefined;
end;

class function TOptionals.Safe(const AValue: INullDouble): INullDouble;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullDouble.Null;
end;

class function TOptionals.Safe(const AValue: IOptNullDouble): IOptNullDouble;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullDouble.Undefined;
end;

class function TOptionals.Safe(const AValue: IOptDateTime): IOptDateTime;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullDateTime.Undefined;
end;

class function TOptionals.Safe(const AValue: INullDateTime): INullDateTime;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullDateTime.Null;
end;

class function TOptionals.Safe(const AValue: IOptNullDateTime): IOptNullDateTime;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullDateTime.Undefined;
end;

class function TOptionals.Safe(const AValue: IOptBoolean): IOptBoolean;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullBoolean.Undefined;
end;

class function TOptionals.Safe(const AValue: INullBoolean): INullBoolean;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullBoolean.Null;
end;

class function TOptionals.Safe(const AValue: IOptNullBoolean): IOptNullBoolean;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullBoolean.Undefined;
end;

class function TOptionals.Safe(const AValue: IOptGuid): IOptGuid;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullGuid.Undefined;
end;

class function TOptionals.Safe(const AValue: INullGuid): INullGuid;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullGuid.Null;
end;

class function TOptionals.Safe(const AValue: IOptNullGuid): IOptNullGuid;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullGuid.Undefined;
end;

class function TOptionals.Safe(const AValue: IOptCurrency): IOptCurrency;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullCurrency.Undefined;
end;

class function TOptionals.Safe(const AValue: INullCurrency): INullCurrency;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullCurrency.Null;
end;

class function TOptionals.Safe(const AValue: IOptNullCurrency): IOptNullCurrency;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullCurrency.Undefined;
end;

{ TOptionalNullableBase }

constructor TOptionalNullableBase.Create;
begin
  FHasValue := False;
  FIsNull := False;
end;

constructor TOptionalNullableBase.CreateNull;
begin
  FHasValue := True;
  FIsNull := True;
end;

function TOptionalNullableBase.IsNull: Boolean;
begin
  Result := FIsNull;
end;

function TOptionalNullableBase.HasValue: Boolean;
begin
  Result := FHasValue;
end;

{ TOptionalNullable<T> }

constructor TOptionalNullable<T>.Create(AValue: T);
begin
  inherited Create;
  FValue := AValue;
  FIsNull := False;
  FHasValue := True;
end;

function TOptionalNullable<T>.GetValue: T;
begin
  Result := FValue;
end;

function TOptionalNullable<T>.ValueOr(const ADefault: T): T;
begin
  if FHasValue and not FIsNull then
    Result := FValue
  else
    Result := ADefault;
end;

{ TOptNullString }

class destructor TOptNullString.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalEmpty := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class constructor TOptNullString.Create;
begin
  FGlobalNull := TOptNullString.CreateNull;
  FGlobalUndefined := TOptNullString.Create;
  FGlobalEmpty := TOptNullString.Create(EmptyStr);
  FGlobalCache := TCache.Create(CACHE_SIZE, 5);
  FLockCache := TCriticalSection.Create;
end;

class function TOptNullString.Null: TOptNullString;
begin
  Result := FGlobalNull as TOptNullString;
end;

class function TOptNullString.Undefined: TOptNullString;
begin
  Result := FGlobalUndefined as TOptNullString;
end;

class function TOptNullString.From(AValue: string): TOptNullString;
var
  Obj: IOptNullString;
begin
  if AValue = EmptyStr then
    Exit(FGlobalEmpty as TOptNullString);

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(AValue, Obj) then
    begin
      Obj := TOptNullString.Create(AValue);
      FGlobalCache.Put(AValue, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullString;
end;

{ TOptNullString: fluent normalizers. Self goes to an interface through a
  plain assignment (the same on both compilers) and then to the TOptionals
  method of the same name, so both forms share one implementation. }

function TOptNullString.AsOpt: IOptString;
begin
  Result := Self;
end;

function TOptNullString.AsNull: INullString;
begin
  Result := Self;
end;

function TOptNullString.AsOptNull: IOptNullString;
begin
  Result := Self;
end;

function TOptNullString.OptTrim: IOptString;
begin
  Result := TOptionals.Trim(AsOpt);
end;

function TOptNullString.OptUpper: IOptString;
begin
  Result := TOptionals.Upper(AsOpt);
end;

function TOptNullString.OptLower: IOptString;
begin
  Result := TOptionals.Lower(AsOpt);
end;

function TOptNullString.OptUndefinedIfEmpty: IOptString;
begin
  Result := TOptionals.UndefinedIfEmpty(AsOpt);
end;

function TOptNullString.OptMap(AFunc: TPcStringFunc): IOptString;
begin
  Result := TOptionals.Map(AsOpt, AFunc);
end;

function TOptNullString.OptNormalize(ANormalizer: IPcStringNormalizer): IOptString;
begin
  Result := TOptionals.Normalize(AsOpt, ANormalizer);
end;

function TOptNullString.NullTrim: INullString;
begin
  Result := TOptionals.Trim(AsNull);
end;

function TOptNullString.NullUpper: INullString;
begin
  Result := TOptionals.Upper(AsNull);
end;

function TOptNullString.NullLower: INullString;
begin
  Result := TOptionals.Lower(AsNull);
end;

function TOptNullString.NullNullIfEmpty: INullString;
begin
  Result := TOptionals.NullIfEmpty(AsNull);
end;

function TOptNullString.NullMap(AFunc: TPcStringFunc): INullString;
begin
  Result := TOptionals.Map(AsNull, AFunc);
end;

function TOptNullString.NullNormalize(ANormalizer: IPcStringNormalizer): INullString;
begin
  Result := TOptionals.Normalize(AsNull, ANormalizer);
end;

function TOptNullString.OptNullTrim: IOptNullString;
begin
  Result := TOptionals.Trim(AsOptNull);
end;

function TOptNullString.OptNullUpper: IOptNullString;
begin
  Result := TOptionals.Upper(AsOptNull);
end;

function TOptNullString.OptNullLower: IOptNullString;
begin
  Result := TOptionals.Lower(AsOptNull);
end;

function TOptNullString.OptNullNullIfEmpty: IOptNullString;
begin
  Result := TOptionals.NullIfEmpty(AsOptNull);
end;

function TOptNullString.OptNullUndefinedIfEmpty: IOptNullString;
begin
  Result := TOptionals.UndefinedIfEmpty(AsOptNull);
end;

function TOptNullString.OptNullMap(AFunc: TPcStringFunc): IOptNullString;
begin
  Result := TOptionals.Map(AsOptNull, AFunc);
end;

function TOptNullString.OptNullNormalize(ANormalizer: IPcStringNormalizer): IOptNullString;
begin
  Result := TOptionals.Normalize(AsOptNull, ANormalizer);
end;

{ TOptNullInteger }

class destructor TOptNullInteger.Destroy;
var
  I: Integer;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  for I := FIXED_CACHE_MIN to FIXED_CACHE_MAX do
    FGlobalCacheFixed[I] := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class constructor TOptNullInteger.Create;
var
  I: Integer;
begin
  FGlobalNull := TOptNullInteger.CreateNull;
  FGlobalUndefined := TOptNullInteger.Create;
  for I := FIXED_CACHE_MIN to FIXED_CACHE_MAX do
    FGlobalCacheFixed[I] := TOptNullInteger.Create(I);
  FGlobalCache := TCache.Create(CACHE_SIZE, 5);
  FLockCache := TCriticalSection.Create;
end;

class function TOptNullInteger.Null: TOptNullInteger;
begin
  Result := FGlobalNull as TOptNullInteger;
end;

class function TOptNullInteger.Undefined: TOptNullInteger;
begin
  Result := FGlobalUndefined as TOptNullInteger;
end;

class function TOptNullInteger.From(AValue: Integer): TOptNullInteger;
var
  Obj: IOptNullInteger;
begin
  if (AValue >= FIXED_CACHE_MIN) and (AValue <= FIXED_CACHE_MAX) then
    Exit(FGlobalCacheFixed[AValue] as TOptNullInteger);

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(AValue, Obj) then
    begin
      Obj := TOptNullInteger.Create(AValue);
      FGlobalCache.Put(AValue, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullInteger;
end;

{ TOptNullInt64 }

class constructor TOptNullInt64.Create;
var
  I: Integer;
begin
  FGlobalNull := TOptNullInt64.CreateNull;
  FGlobalUndefined := TOptNullInt64.Create;
  for I := FIXED_CACHE_MIN to FIXED_CACHE_MAX do
    FGlobalCacheFixed[I] := TOptNullInt64.Create(I);
  FGlobalCache := TCache.Create(CACHE_SIZE, 5);
  FLockCache := TCriticalSection.Create;
end;

class destructor TOptNullInt64.Destroy;
var
  I: Integer;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  for I := FIXED_CACHE_MIN to FIXED_CACHE_MAX do
    FGlobalCacheFixed[I] := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class function TOptNullInt64.Null: TOptNullInt64;
begin
  Result := FGlobalNull as TOptNullInt64;
end;

class function TOptNullInt64.Undefined: TOptNullInt64;
begin
  Result := FGlobalUndefined as TOptNullInt64;
end;

class function TOptNullInt64.From(AValue: Int64): TOptNullInt64;
var
  Obj: IOptNullInt64;
begin
  if (AValue >= FIXED_CACHE_MIN) and (AValue <= FIXED_CACHE_MAX) then
    Exit(FGlobalCacheFixed[AValue] as TOptNullInt64);

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(AValue, Obj) then
    begin
      Obj := TOptNullInt64.Create(AValue);
      FGlobalCache.Put(AValue, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullInt64;
end;

{ TOptNullSingle }

class operator TOptNullSingle.TCacheKey.Equal(const A, B: TCacheKey): Boolean;
begin
  Result := (A.Value = B.Value) and (A.Precision = B.Precision);
end;

constructor TOptNullSingle.Create(AValue: Single; ADecimalPlaces: Integer);
begin
  inherited Create(AValue);
  FDecimalPlaces := ADecimalPlaces;
end;

function TOptNullSingle.GetDecimalPlaces: Integer;
begin
  Result := FDecimalPlaces;
end;

class destructor TOptNullSingle.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalZero := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class constructor TOptNullSingle.Create;
begin
  FGlobalNull := TOptNullSingle.CreateNull;
  FGlobalUndefined := TOptNullSingle.Create;
  FGlobalZero := TOptNullSingle.Create(0.0, -1);
  FGlobalCache := TCache.Create(CACHE_SIZE, 3,
    TEqualityComparer<TCacheKey>.Construct(SingleKeyEquals, SingleKeyHash));
  FLockCache := TCriticalSection.Create;
end;

class function TOptNullSingle.Null: TOptNullSingle;
begin
  Result := FGlobalNull as TOptNullSingle;
end;

class function TOptNullSingle.Undefined: TOptNullSingle;
begin
  Result := FGlobalUndefined as TOptNullSingle;
end;

class function TOptNullSingle.From(AValue: Single; ADecimalPlaces: Integer): TOptNullSingle;
var
  Obj: IOptNullSingle;
  Key: TCacheKey;
begin
  if AValue = 0.0 then
    Exit(FGlobalZero as TOptNullSingle);

  FillChar(Key, SizeOf(Key), 0);
  Key.Value := AValue;
  Key.Precision := ADecimalPlaces;

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(Key, Obj) then
    begin
      Obj := TOptNullSingle.Create(AValue, ADecimalPlaces);
      FGlobalCache.Put(Key, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullSingle;
end;

{ TOptNullDouble }

class operator TOptNullDouble.TCacheKey.Equal(const A, B: TCacheKey): Boolean;
begin
  Result := (A.Value = B.Value) and (A.Precision = B.Precision);
end;

constructor TOptNullDouble.Create(AValue: Double; ADecimalPlaces: Integer);
begin
  inherited Create(AValue);
  FDecimalPlaces := ADecimalPlaces;
end;

function TOptNullDouble.GetDecimalPlaces: Integer;
begin
  Result := FDecimalPlaces;
end;

class destructor TOptNullDouble.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalZero := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class constructor TOptNullDouble.Create;
begin
  FGlobalNull := TOptNullDouble.CreateNull;
  FGlobalUndefined := TOptNullDouble.Create;
  FGlobalZero := TOptNullDouble.Create(0.0, -1);
  FGlobalCache := TCache.Create(CACHE_SIZE, 3,
    TEqualityComparer<TCacheKey>.Construct(DoubleKeyEquals, DoubleKeyHash));
  FLockCache := TCriticalSection.Create;
end;

class function TOptNullDouble.Null: TOptNullDouble;
begin
  Result := FGlobalNull as TOptNullDouble;
end;

class function TOptNullDouble.Undefined: TOptNullDouble;
begin
  Result := FGlobalUndefined as TOptNullDouble;
end;

class function TOptNullDouble.From(AValue: Double; ADecimalPlaces: Integer): TOptNullDouble;
var
  Obj: IOptNullDouble;
  Key: TCacheKey;
begin
  if AValue = 0.0 then
    Exit(FGlobalZero as TOptNullDouble);

  Key.Value := AValue;
  Key.Precision := ADecimalPlaces;

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(Key, Obj) then
    begin
      Obj := TOptNullDouble.Create(AValue, ADecimalPlaces);
      FGlobalCache.Put(Key, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullDouble;
end;

{ TOptNullDateTime }

class destructor TOptNullDateTime.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalCacheDate.Free;
  FLockCacheDate.Free;
  FGlobalCacheTime.Free;
  FLockCacheTime.Free;
end;

class constructor TOptNullDateTime.Create;
begin
  FGlobalNull := TOptNullDateTime.CreateNull;
  FGlobalUndefined := TOptNullDateTime.Create;
  FGlobalCacheDate := TCache.Create(CACHE_SIZE_DATE, 5);
  FLockCacheDate := TCriticalSection.Create;
  FGlobalCacheTime := TCache.Create(CACHE_SIZE_TIME, 2);
  FLockCacheTime := TCriticalSection.Create;
end;

class function TOptNullDateTime.Null: TOptNullDateTime;
begin
  Result := FGlobalNull as TOptNullDateTime;
end;

class function TOptNullDateTime.Undefined: TOptNullDateTime;
begin
  Result := FGlobalUndefined as TOptNullDateTime;
end;

class function TOptNullDateTime.From(AValue: TDateTime): TOptNullDateTime;
var
  OnlyDate: Double;

  function GetFromCache(ACache: TCache; FLock: TCriticalSection): TOptNullDateTime;
  var
    Obj: IOptNullDateTime;
  begin
    FLock.Enter;
    try
      if not ACache.Get(AValue, Obj) then
      begin
        Obj := TOptNullDateTime.Create(AValue);
        ACache.Put(AValue, Obj);
      end;
    finally
      FLock.Leave;
    end;

    Result := Obj as TOptNullDateTime;
  end;

begin
  OnlyDate := Trunc(AValue);

  // separate cache strategies for date-only and date-and-time values
  if OnlyDate = AValue then
    Result := GetFromCache(FGlobalCacheDate, FLockCacheDate)
  else
    Result := GetFromCache(FGlobalCacheTime, FLockCacheTime);
end;

{ TOptNullBoolean }

class destructor TOptNullBoolean.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalTrue := nil;
  FGlobalFalse := nil;
end;

class constructor TOptNullBoolean.Create;
begin
  FGlobalNull := TOptNullBoolean.CreateNull;
  FGlobalUndefined := TOptNullBoolean.Create;
  FGlobalTrue := TOptNullBoolean.Create(True);
  FGlobalFalse := TOptNullBoolean.Create(False);
end;

class function TOptNullBoolean.Null: TOptNullBoolean;
begin
  Result := FGlobalNull as TOptNullBoolean;
end;

class function TOptNullBoolean.Undefined: TOptNullBoolean;
begin
  Result := FGlobalUndefined as TOptNullBoolean;
end;

class function TOptNullBoolean.TrueValue: TOptNullBoolean;
begin
  Result := FGlobalTrue as TOptNullBoolean;
end;

class function TOptNullBoolean.FalseValue: TOptNullBoolean;
begin
  Result := FGlobalFalse as TOptNullBoolean;
end;

class function TOptNullBoolean.From(AValue: Boolean): IOptNullBoolean;
begin
  if AValue then
    Result := TrueValue
  else
    Result := FalseValue;
end;

{ TOptNullGuid }

class destructor TOptNullGuid.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalEmpty := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class constructor TOptNullGuid.Create;
begin
  FGlobalNull := TOptNullGuid.CreateNull;
  FGlobalUndefined := TOptNullGuid.Create;
  FGlobalEmpty := TOptNullGuid.Create(EMPTY_GUID);
  FGlobalCache := TCache.Create(CACHE_SIZE, 5);
  FLockCache := TCriticalSection.Create;
end;

class function TOptNullGuid.Null: TOptNullGuid;
begin
  Result := FGlobalNull as TOptNullGuid;
end;

class function TOptNullGuid.Undefined: TOptNullGuid;
begin
  Result := FGlobalUndefined as TOptNullGuid;
end;

class function TOptNullGuid.From(AValue: TGUID): TOptNullGuid;
var
  Obj: IOptNullGuid;
begin
  if IsEqualGUID(AValue, EMPTY_GUID) then
    Exit(FGlobalEmpty as TOptNullGuid);

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(AValue, Obj) then
    begin
      Obj := TOptNullGuid.Create(AValue);
      FGlobalCache.Put(AValue, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullGuid;
end;

{ TOptNullCurrency }

class destructor TOptNullCurrency.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalZero := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class constructor TOptNullCurrency.Create;
begin
  FGlobalNull := TOptNullCurrency.CreateNull;
  FGlobalUndefined := TOptNullCurrency.Create;
  FGlobalZero := TOptNullCurrency.Create(0.0);
  FGlobalCache := TCache.Create(CACHE_SIZE, 5);
  FLockCache := TCriticalSection.Create;
end;

class function TOptNullCurrency.Null: TOptNullCurrency;
begin
  Result := FGlobalNull as TOptNullCurrency;
end;

class function TOptNullCurrency.Undefined: TOptNullCurrency;
begin
  Result := FGlobalUndefined as TOptNullCurrency;
end;

class function TOptNullCurrency.From(AValue: Currency): TOptNullCurrency;
var
  Obj: IOptNullCurrency;
begin
  if AValue = 0.0 then
    Exit(FGlobalZero as TOptNullCurrency);

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(AValue, Obj) then
    begin
      Obj := TOptNullCurrency.Create(AValue);
      FGlobalCache.Put(AValue, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullCurrency;
end;

{ TOptNullInteger: Map and Normalize }

function TOptNullInteger.AsOpt: IOptInteger;
begin
  Result := Self;
end;

function TOptNullInteger.AsNull: INullInteger;
begin
  Result := Self;
end;

function TOptNullInteger.AsOptNull: IOptNullInteger;
begin
  Result := Self;
end;

function TOptNullInteger.OptMap(AFunc: TPcIntegerFunc): IOptInteger;
begin
  Result := TOptionals.Map(AsOpt, AFunc);
end;

function TOptNullInteger.OptNormalize(ANormalizer: IPcIntegerNormalizer): IOptInteger;
begin
  Result := TOptionals.Normalize(AsOpt, ANormalizer);
end;

function TOptNullInteger.NullMap(AFunc: TPcIntegerFunc): INullInteger;
begin
  Result := TOptionals.Map(AsNull, AFunc);
end;

function TOptNullInteger.NullNormalize(ANormalizer: IPcIntegerNormalizer): INullInteger;
begin
  Result := TOptionals.Normalize(AsNull, ANormalizer);
end;

function TOptNullInteger.OptNullMap(AFunc: TPcIntegerFunc): IOptNullInteger;
begin
  Result := TOptionals.Map(AsOptNull, AFunc);
end;

function TOptNullInteger.OptNullNormalize(ANormalizer: IPcIntegerNormalizer): IOptNullInteger;
begin
  Result := TOptionals.Normalize(AsOptNull, ANormalizer);
end;

{ TOptNullInt64: Map and Normalize }

function TOptNullInt64.AsOpt: IOptInt64;
begin
  Result := Self;
end;

function TOptNullInt64.AsNull: INullInt64;
begin
  Result := Self;
end;

function TOptNullInt64.AsOptNull: IOptNullInt64;
begin
  Result := Self;
end;

function TOptNullInt64.OptMap(AFunc: TPcInt64Func): IOptInt64;
begin
  Result := TOptionals.Map(AsOpt, AFunc);
end;

function TOptNullInt64.OptNormalize(ANormalizer: IPcInt64Normalizer): IOptInt64;
begin
  Result := TOptionals.Normalize(AsOpt, ANormalizer);
end;

function TOptNullInt64.NullMap(AFunc: TPcInt64Func): INullInt64;
begin
  Result := TOptionals.Map(AsNull, AFunc);
end;

function TOptNullInt64.NullNormalize(ANormalizer: IPcInt64Normalizer): INullInt64;
begin
  Result := TOptionals.Normalize(AsNull, ANormalizer);
end;

function TOptNullInt64.OptNullMap(AFunc: TPcInt64Func): IOptNullInt64;
begin
  Result := TOptionals.Map(AsOptNull, AFunc);
end;

function TOptNullInt64.OptNullNormalize(ANormalizer: IPcInt64Normalizer): IOptNullInt64;
begin
  Result := TOptionals.Normalize(AsOptNull, ANormalizer);
end;

{ TOptNullSingle: Map and Normalize }

function TOptNullSingle.AsOpt: IOptSingle;
begin
  Result := Self;
end;

function TOptNullSingle.AsNull: INullSingle;
begin
  Result := Self;
end;

function TOptNullSingle.AsOptNull: IOptNullSingle;
begin
  Result := Self;
end;

function TOptNullSingle.OptMap(AFunc: TPcSingleFunc): IOptSingle;
begin
  Result := TOptionals.Map(AsOpt, AFunc);
end;

function TOptNullSingle.OptNormalize(ANormalizer: IPcSingleNormalizer): IOptSingle;
begin
  Result := TOptionals.Normalize(AsOpt, ANormalizer);
end;

function TOptNullSingle.NullMap(AFunc: TPcSingleFunc): INullSingle;
begin
  Result := TOptionals.Map(AsNull, AFunc);
end;

function TOptNullSingle.NullNormalize(ANormalizer: IPcSingleNormalizer): INullSingle;
begin
  Result := TOptionals.Normalize(AsNull, ANormalizer);
end;

function TOptNullSingle.OptNullMap(AFunc: TPcSingleFunc): IOptNullSingle;
begin
  Result := TOptionals.Map(AsOptNull, AFunc);
end;

function TOptNullSingle.OptNullNormalize(ANormalizer: IPcSingleNormalizer): IOptNullSingle;
begin
  Result := TOptionals.Normalize(AsOptNull, ANormalizer);
end;

{ TOptNullDouble: Map and Normalize }

function TOptNullDouble.AsOpt: IOptDouble;
begin
  Result := Self;
end;

function TOptNullDouble.AsNull: INullDouble;
begin
  Result := Self;
end;

function TOptNullDouble.AsOptNull: IOptNullDouble;
begin
  Result := Self;
end;

function TOptNullDouble.OptMap(AFunc: TPcDoubleFunc): IOptDouble;
begin
  Result := TOptionals.Map(AsOpt, AFunc);
end;

function TOptNullDouble.OptNormalize(ANormalizer: IPcDoubleNormalizer): IOptDouble;
begin
  Result := TOptionals.Normalize(AsOpt, ANormalizer);
end;

function TOptNullDouble.NullMap(AFunc: TPcDoubleFunc): INullDouble;
begin
  Result := TOptionals.Map(AsNull, AFunc);
end;

function TOptNullDouble.NullNormalize(ANormalizer: IPcDoubleNormalizer): INullDouble;
begin
  Result := TOptionals.Normalize(AsNull, ANormalizer);
end;

function TOptNullDouble.OptNullMap(AFunc: TPcDoubleFunc): IOptNullDouble;
begin
  Result := TOptionals.Map(AsOptNull, AFunc);
end;

function TOptNullDouble.OptNullNormalize(ANormalizer: IPcDoubleNormalizer): IOptNullDouble;
begin
  Result := TOptionals.Normalize(AsOptNull, ANormalizer);
end;

{ TOptNullCurrency: Map and Normalize }

function TOptNullCurrency.AsOpt: IOptCurrency;
begin
  Result := Self;
end;

function TOptNullCurrency.AsNull: INullCurrency;
begin
  Result := Self;
end;

function TOptNullCurrency.AsOptNull: IOptNullCurrency;
begin
  Result := Self;
end;

function TOptNullCurrency.OptMap(AFunc: TPcCurrencyFunc): IOptCurrency;
begin
  Result := TOptionals.Map(AsOpt, AFunc);
end;

function TOptNullCurrency.OptNormalize(ANormalizer: IPcCurrencyNormalizer): IOptCurrency;
begin
  Result := TOptionals.Normalize(AsOpt, ANormalizer);
end;

function TOptNullCurrency.NullMap(AFunc: TPcCurrencyFunc): INullCurrency;
begin
  Result := TOptionals.Map(AsNull, AFunc);
end;

function TOptNullCurrency.NullNormalize(ANormalizer: IPcCurrencyNormalizer): INullCurrency;
begin
  Result := TOptionals.Normalize(AsNull, ANormalizer);
end;

function TOptNullCurrency.OptNullMap(AFunc: TPcCurrencyFunc): IOptNullCurrency;
begin
  Result := TOptionals.Map(AsOptNull, AFunc);
end;

function TOptNullCurrency.OptNullNormalize(ANormalizer: IPcCurrencyNormalizer): IOptNullCurrency;
begin
  Result := TOptionals.Normalize(AsOptNull, ANormalizer);
end;

{ TOptNullDateTime: Map and Normalize }

function TOptNullDateTime.AsOpt: IOptDateTime;
begin
  Result := Self;
end;

function TOptNullDateTime.AsNull: INullDateTime;
begin
  Result := Self;
end;

function TOptNullDateTime.AsOptNull: IOptNullDateTime;
begin
  Result := Self;
end;

function TOptNullDateTime.OptMap(AFunc: TPcDateTimeFunc): IOptDateTime;
begin
  Result := TOptionals.Map(AsOpt, AFunc);
end;

function TOptNullDateTime.OptNormalize(ANormalizer: IPcDateTimeNormalizer): IOptDateTime;
begin
  Result := TOptionals.Normalize(AsOpt, ANormalizer);
end;

function TOptNullDateTime.NullMap(AFunc: TPcDateTimeFunc): INullDateTime;
begin
  Result := TOptionals.Map(AsNull, AFunc);
end;

function TOptNullDateTime.NullNormalize(ANormalizer: IPcDateTimeNormalizer): INullDateTime;
begin
  Result := TOptionals.Normalize(AsNull, ANormalizer);
end;

function TOptNullDateTime.OptNullMap(AFunc: TPcDateTimeFunc): IOptNullDateTime;
begin
  Result := TOptionals.Map(AsOptNull, AFunc);
end;

function TOptNullDateTime.OptNullNormalize(ANormalizer: IPcDateTimeNormalizer): IOptNullDateTime;
begin
  Result := TOptionals.Normalize(AsOptNull, ANormalizer);
end;

{ TOptNullBoolean: Map and Normalize }

function TOptNullBoolean.AsOpt: IOptBoolean;
begin
  Result := Self;
end;

function TOptNullBoolean.AsNull: INullBoolean;
begin
  Result := Self;
end;

function TOptNullBoolean.AsOptNull: IOptNullBoolean;
begin
  Result := Self;
end;

function TOptNullBoolean.OptMap(AFunc: TPcBooleanFunc): IOptBoolean;
begin
  Result := TOptionals.Map(AsOpt, AFunc);
end;

function TOptNullBoolean.OptNormalize(ANormalizer: IPcBooleanNormalizer): IOptBoolean;
begin
  Result := TOptionals.Normalize(AsOpt, ANormalizer);
end;

function TOptNullBoolean.NullMap(AFunc: TPcBooleanFunc): INullBoolean;
begin
  Result := TOptionals.Map(AsNull, AFunc);
end;

function TOptNullBoolean.NullNormalize(ANormalizer: IPcBooleanNormalizer): INullBoolean;
begin
  Result := TOptionals.Normalize(AsNull, ANormalizer);
end;

function TOptNullBoolean.OptNullMap(AFunc: TPcBooleanFunc): IOptNullBoolean;
begin
  Result := TOptionals.Map(AsOptNull, AFunc);
end;

function TOptNullBoolean.OptNullNormalize(ANormalizer: IPcBooleanNormalizer): IOptNullBoolean;
begin
  Result := TOptionals.Normalize(AsOptNull, ANormalizer);
end;

{ TOptNullGuid: Map and Normalize }

function TOptNullGuid.AsOpt: IOptGuid;
begin
  Result := Self;
end;

function TOptNullGuid.AsNull: INullGuid;
begin
  Result := Self;
end;

function TOptNullGuid.AsOptNull: IOptNullGuid;
begin
  Result := Self;
end;

function TOptNullGuid.OptMap(AFunc: TPcGuidFunc): IOptGuid;
begin
  Result := TOptionals.Map(AsOpt, AFunc);
end;

function TOptNullGuid.OptNormalize(ANormalizer: IPcGuidNormalizer): IOptGuid;
begin
  Result := TOptionals.Normalize(AsOpt, ANormalizer);
end;

function TOptNullGuid.NullMap(AFunc: TPcGuidFunc): INullGuid;
begin
  Result := TOptionals.Map(AsNull, AFunc);
end;

function TOptNullGuid.NullNormalize(ANormalizer: IPcGuidNormalizer): INullGuid;
begin
  Result := TOptionals.Normalize(AsNull, ANormalizer);
end;

function TOptNullGuid.OptNullMap(AFunc: TPcGuidFunc): IOptNullGuid;
begin
  Result := TOptionals.Map(AsOptNull, AFunc);
end;

function TOptNullGuid.OptNullNormalize(ANormalizer: IPcGuidNormalizer): IOptNullGuid;
begin
  Result := TOptionals.Normalize(AsOptNull, ANormalizer);
end;

end.
