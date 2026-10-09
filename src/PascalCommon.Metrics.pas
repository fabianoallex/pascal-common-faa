unit PascalCommon.Metrics;

{$I pascalcommon.inc}

(* Metrics primitives (counter, up-down counter, gauge, histogram), a registry,
  and the Prometheus text exposition of a registry, the same on Delphi and FPC.

  It is phase B of pascal-api-infra-faa's observability design
  (docs/observability-design.md there): the API records
  http.server.request.duration and http.server.active_requests and serves
  them on GET /metrics. It lives here, not in the API library, so that
  pascal-db-faa, pascal-redis-faa and pascal-amqp-faa can record into the same
  registry later (phase D).

  Names and units are OpenTelemetry's (instrument "http.server.request.duration",
  unit "s"; attribute "http.request.method"), and the Prometheus writer
  converts them the way OpenTelemetry's Prometheus compatibility specification
  says: characters outside [a-zA-Z0-9_:] become "_" (runs collapsed to one),
  the unit becomes a suffix ("s" -> "_seconds", "By" -> "_bytes", "{request}"
  -> nothing, "1" -> "_ratio" on a gauge), and a counter ends in "_total". So
  the same metrics can be exported over OTLP (phase C) without a second set of
  names. PcPrometheusName shows the result of the conversion.

  Shape. A metric is a family (name, unit, description, label names) holding
  one series per combination of label values: Labels(['GET', '200']) finds or
  creates it under the family's lock, and the series itself is updated with
  atomics only (the PcAtomic functions), so a caller that keeps the series object pays no
  lock at all. A family without labels has its one series from the start
  (exported as 0 before any use), reached through the family's own Inc / Add /
  SetValue / Observe. Series are never removed: keep label values bounded (a
  route template, never a raw path or an id).

  Values are Doubles kept as their Int64 bit pattern and updated with a
  compare-and-swap loop (PcAtomicCompareExchange64), which works on both
  compilers and on 32-bit targets. A histogram keeps one counter per bucket
  (not cumulative); a snapshot derives Count from the buckets, so _count and
  the +Inf bucket always agree even while other threads observe. Sum is read
  separately and may lag by the observations in flight.

  Invalid input on the recording path never raises: a counter ignores a
  negative or NaN increment (OpenTelemetry's rule; it would make the counter
  go backwards), every instrument ignores NaN. Mistakes in the definition
  (a bad name, the wrong number of label values, the same name registered with
  another kind or labels) raise EPcMetrics: they are programming errors.

  PcMetrics is the process-wide registry, created in initialization (no lazy
  shared instances; see CLAUDE.md). The metric objects belong to their
  registry: never free them.

  Float text: integral values below 2^53 are written as integers ("3", not
  "3.0"); others with 15 significant digits (FloatToStrF, ffGeneral), '.' as
  the decimal separator on every locale; "+Inf", "-Inf" and "NaN" as
  Prometheus writes them. Not 17: FPC 3.2.2's FloatToStrF stops at 15 digits
  whatever precision is asked (measured: 0.1 + 0.2 gives "0.3" with 15, 16
  and 17), so 15 is what both compilers write the same way. The text can be
  one unit off in the 15th digit, nothing a metric notices. *)

interface

uses
  SysUtils,
  SyncObjs,
  Generics.Collections;

type
  EPcMetrics = class(Exception);

  TPcMetricKind = (mkCounter, mkUpDownCounter, mkGauge, mkHistogram);

  TPcLabelValues = array of string;
  TPcBucketBounds = array of Double;
  TPcBucketCounts = array of UInt64;

  /// One series as read by TPcMetric.Snapshot.
  TPcMetricPoint = record
    LabelValues: TPcLabelValues;
    /// Counter, up-down counter and gauge.
    Value: Double;
    /// Histogram: observations per bucket, not cumulative; one more entry
    /// than the bounds (the last one is above the highest bound).
    BucketCounts: TPcBucketCounts;
    /// Histogram: the sum of BucketCounts.
    Count: UInt64;
    /// Histogram: the sum of the observed values.
    Sum: Double;
  end;
  TPcMetricPoints = array of TPcMetricPoint;

  /// A series: the base class of the four kinds below.
  TPcSeries = class
  private
    FLabelValues: TPcLabelValues;
  public
    property LabelValues: TPcLabelValues read FLabelValues;
  end;

  TPcCounterSeries = class(TPcSeries)
  private
    FBits: Int64;
  public
    procedure Inc;
    /// Ignored when AValue is negative or NaN.
    procedure Add(AValue: Double);
    function Value: Double;
  end;

  TPcUpDownCounterSeries = class(TPcSeries)
  private
    FBits: Int64;
  public
    procedure Inc;
    procedure Dec;
    /// Ignored when AValue is NaN.
    procedure Add(AValue: Double);
    function Value: Double;
  end;

  TPcGaugeSeries = class(TPcSeries)
  private
    FBits: Int64;
  public
    /// Ignored when AValue is NaN.
    procedure SetValue(AValue: Double);
    function Value: Double;
  end;

  TPcHistogramSeries = class(TPcSeries)
  private
    FBounds: TPcBucketBounds;
    FBuckets: array of UInt64;
    FSumBits: Int64;
  public
    /// Counts AValue in the first bucket whose bound is >= AValue (or the
    /// last one); ignored when AValue is NaN.
    procedure Observe(AValue: Double);
    function Count: UInt64;
    function Sum: Double;
  end;

  /// A metric family. Created by a TPcMetricRegistry, which owns it.
  TPcMetric = class
  private
    FName: string;
    FMetricUnit: string;
    FDescription: string;
    FKind: TPcMetricKind;
    FLabelNames: TPcLabelValues;
    FBounds: TPcBucketBounds;
    FLock: TCriticalSection;
    FSeriesByKey: TDictionary<string, TPcSeries>;
    FSeries: TList<TPcSeries>;
    function NewSeries: TPcSeries;
    function FindOrCreate(const AValues: array of string): TPcSeries;
    function DefaultSeries: TPcSeries;
  public
    constructor Create(AKind: TPcMetricKind; const AName, AMetricUnit, ADescription: string;
      const ALabelNames: array of string; const ABounds: array of Double);
    destructor Destroy; override;
    /// The series, in creation order, read now. Safe while other threads record.
    function Snapshot: TPcMetricPoints;
    property Name: string read FName;
    /// UCUM unit, as in OpenTelemetry ("s", "By", "{request}", "1"); may be ''.
    property MetricUnit: string read FMetricUnit;
    property Description: string read FDescription;
    property Kind: TPcMetricKind read FKind;
    property LabelNames: TPcLabelValues read FLabelNames;
    /// Histogram bucket upper bounds (inclusive), increasing; empty otherwise.
    property Bounds: TPcBucketBounds read FBounds;
  end;

  TPcCounter = class(TPcMetric)
  public
    /// The series for these label values (as many as LabelNames), created on
    /// first use. Keep it to skip the lookup.
    function Labels(const AValues: array of string): TPcCounterSeries;
    /// The series of a counter without labels; raise EPcMetrics otherwise.
    procedure Inc;
    procedure Add(AValue: Double);
  end;

  TPcUpDownCounter = class(TPcMetric)
  public
    function Labels(const AValues: array of string): TPcUpDownCounterSeries;
    procedure Inc;
    procedure Dec;
    procedure Add(AValue: Double);
  end;

  TPcGauge = class(TPcMetric)
  public
    function Labels(const AValues: array of string): TPcGaugeSeries;
    procedure SetValue(AValue: Double);
  end;

  TPcHistogram = class(TPcMetric)
  public
    function Labels(const AValues: array of string): TPcHistogramSeries;
    procedure Observe(AValue: Double);
  end;

  TPcMetricList = array of TPcMetric;

  TPcMetricRegistry = class
  private
    FLock: TCriticalSection;
    FByName: TDictionary<string, TPcMetric>;
    FMetrics: TList<TPcMetric>;
    function GetOrAdd(AKind: TPcMetricKind; const AName, AMetricUnit, ADescription: string;
      const ALabelNames: array of string; const ABounds: array of Double): TPcMetric;
  public
    constructor Create;
    destructor Destroy; override;
    /// Each of these returns the metric of that name, creating it on the first
    /// call. A second call must give the same kind, unit, label names (and
    /// bounds); otherwise EPcMetrics. The description of the first call stays.
    /// AName: OpenTelemetry instrument name, [A-Za-z][A-Za-z0-9_.-/]*, up to
    /// 255 characters. Label names: [A-Za-z_][A-Za-z0-9_.]*, distinct, not
    /// starting with "__"; a histogram can't have one that becomes "le".
    function Counter(const AName, AMetricUnit, ADescription: string;
      const ALabelNames: array of string): TPcCounter;
    function UpDownCounter(const AName, AMetricUnit, ADescription: string;
      const ALabelNames: array of string): TPcUpDownCounter;
    function Gauge(const AName, AMetricUnit, ADescription: string;
      const ALabelNames: array of string): TPcGauge;
    /// ABounds: finite, strictly increasing upper bounds; may be empty (only
    /// the +Inf bucket). PC_DURATION_BUCKETS for durations in seconds.
    function Histogram(const AName, AMetricUnit, ADescription: string;
      const ALabelNames: array of string; const ABounds: array of Double): TPcHistogram;
    /// The metrics, in registration order.
    function Metrics: TPcMetricList;
  end;

const
  /// OpenTelemetry's recommended buckets for http.server.request.duration
  /// (seconds): 5 ms to 10 s.
  PC_DURATION_BUCKETS: array[0..13] of Double = (0.005, 0.01, 0.025, 0.05, 0.075,
    0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10);

  /// The Content-Type of PcPrometheusText's output (text format 0.0.4).
  PC_PROMETHEUS_CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8';

var
  /// The process-wide registry. Created in initialization, freed in
  /// finalization.
  PcMetrics: TPcMetricRegistry;

/// The Prometheus name of a metric (see the unit header).
function PcPrometheusName(AMetric: TPcMetric): string;
/// The Prometheus name of a label (OpenTelemetry attribute) name.
function PcPrometheusLabelName(const AName: string): string;
/// A Double as the Prometheus text format writes it.
function PcPrometheusFloat(AValue: Double): string;
/// Every metric of ARegistry in the Prometheus text exposition format 0.0.4:
/// "# HELP" (when there is a description), "# TYPE", then the samples; LF
/// line ends, the last line ended too. '' for an empty registry.
function PcPrometheusText(ARegistry: TPcMetricRegistry): string;

implementation

uses
  Math,
  PascalCommon.Threading;

var
  GInvariant: TFormatSettings;

{ Double <-> Int64 bits }

function BitsToDouble(ABits: Int64): Double; inline;
begin
  Result := 0;
  Move(ABits, Result, SizeOf(Result));
end;

function DoubleToBits(AValue: Double): Int64; inline;
begin
  Result := 0;
  Move(AValue, Result, SizeOf(Result));
end;

function AtomicReadDouble(var ABits: Int64): Double;
begin
  Result := BitsToDouble(PcAtomicRead64(ABits));
end;

procedure AtomicAddDouble(var ABits: Int64; ADelta: Double);
var
  LOld: Int64;
begin
  repeat
    LOld := PcAtomicRead64(ABits);
  until PcAtomicCompareExchange64(ABits, DoubleToBits(BitsToDouble(LOld) + ADelta), LOld) = LOld;
end;

{ Validation }

function IsLetter(C: Char): Boolean; inline;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z'));
end;

function IsDigit(C: Char): Boolean; inline;
begin
  Result := (C >= '0') and (C <= '9');
end;

procedure CheckMetricName(const AName: string);
var
  I: Integer;
begin
  if (AName = '') or (Length(AName) > 255) or not IsLetter(AName[1]) then
    raise EPcMetrics.CreateFmt('Invalid metric name "%s"', [AName]);
  for I := 2 to Length(AName) do
    if not (IsLetter(AName[I]) or IsDigit(AName[I]) or CharInSet(AName[I], ['_', '.', '-', '/'])) then
      raise EPcMetrics.CreateFmt('Invalid metric name "%s"', [AName]);
end;

procedure CheckUnit(const AUnit: string);
var
  I: Integer;
begin
  if Length(AUnit) > 63 then
    raise EPcMetrics.CreateFmt('Invalid unit "%s"', [AUnit]);
  for I := 1 to Length(AUnit) do
    if (AUnit[I] <= ' ') or (AUnit[I] > '~') then
      raise EPcMetrics.CreateFmt('Invalid unit "%s"', [AUnit]);
end;

procedure CheckLabelNames(AKind: TPcMetricKind; const ANames: array of string);
var
  I, J: Integer;
  S: string;
begin
  for I := 0 to High(ANames) do
  begin
    S := ANames[I];
    if (S = '') or not (IsLetter(S[1]) or (S[1] = '_')) or (Copy(S, 1, 2) = '__') then
      raise EPcMetrics.CreateFmt('Invalid label name "%s"', [S]);
    for J := 2 to Length(S) do
      if not (IsLetter(S[J]) or IsDigit(S[J]) or (S[J] = '_') or (S[J] = '.')) then
        raise EPcMetrics.CreateFmt('Invalid label name "%s"', [S]);
    if (AKind = mkHistogram) and (PcPrometheusLabelName(S) = 'le') then
      raise EPcMetrics.Create('A histogram can''t have a label named "le"');
    for J := 0 to I - 1 do
      if ANames[J] = S then
        raise EPcMetrics.CreateFmt('Duplicate label name "%s"', [S]);
  end;
end;

procedure CheckBounds(const ABounds: array of Double);
var
  I: Integer;
begin
  for I := 0 to High(ABounds) do
  begin
    if IsNan(ABounds[I]) or IsInfinite(ABounds[I]) then
      raise EPcMetrics.Create('Histogram bounds must be finite');
    if (I > 0) and (ABounds[I] <= ABounds[I - 1]) then
      raise EPcMetrics.Create('Histogram bounds must be strictly increasing');
  end;
end;

{ TPcCounterSeries }

procedure TPcCounterSeries.Inc;
begin
  AtomicAddDouble(FBits, 1);
end;

procedure TPcCounterSeries.Add(AValue: Double);
begin
  if IsNan(AValue) or (AValue < 0) then
    Exit;
  AtomicAddDouble(FBits, AValue);
end;

function TPcCounterSeries.Value: Double;
begin
  Result := AtomicReadDouble(FBits);
end;

{ TPcUpDownCounterSeries }

procedure TPcUpDownCounterSeries.Inc;
begin
  AtomicAddDouble(FBits, 1);
end;

procedure TPcUpDownCounterSeries.Dec;
begin
  AtomicAddDouble(FBits, -1);
end;

procedure TPcUpDownCounterSeries.Add(AValue: Double);
begin
  if IsNan(AValue) then
    Exit;
  AtomicAddDouble(FBits, AValue);
end;

function TPcUpDownCounterSeries.Value: Double;
begin
  Result := AtomicReadDouble(FBits);
end;

{ TPcGaugeSeries }

procedure TPcGaugeSeries.SetValue(AValue: Double);
begin
  if IsNan(AValue) then
    Exit;
  PcAtomicWrite64(FBits, DoubleToBits(AValue));
end;

function TPcGaugeSeries.Value: Double;
begin
  Result := AtomicReadDouble(FBits);
end;

{ TPcHistogramSeries }

procedure TPcHistogramSeries.Observe(AValue: Double);
var
  I: Integer;
begin
  if IsNan(AValue) then
    Exit;
  I := 0;
  while (I < Length(FBounds)) and (AValue > FBounds[I]) do
    System.Inc(I);
  PcAtomicInc64(FBuckets[I]);
  AtomicAddDouble(FSumBits, AValue);
end;

function TPcHistogramSeries.Count: UInt64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FBuckets) do
    Result := Result + PcAtomicRead64(FBuckets[I]);
end;

function TPcHistogramSeries.Sum: Double;
begin
  Result := AtomicReadDouble(FSumBits);
end;

{ TPcMetric }

constructor TPcMetric.Create(AKind: TPcMetricKind; const AName, AMetricUnit, ADescription: string;
  const ALabelNames: array of string; const ABounds: array of Double);
var
  I: Integer;
begin
  inherited Create;
  CheckMetricName(AName);
  CheckUnit(AMetricUnit);
  CheckLabelNames(AKind, ALabelNames);
  if AKind = mkHistogram then
    CheckBounds(ABounds);
  FKind := AKind;
  FName := AName;
  FMetricUnit := AMetricUnit;
  FDescription := ADescription;
  SetLength(FLabelNames, Length(ALabelNames));
  for I := 0 to High(ALabelNames) do
    FLabelNames[I] := ALabelNames[I];
  if AKind = mkHistogram then
  begin
    SetLength(FBounds, Length(ABounds));
    for I := 0 to High(ABounds) do
      FBounds[I] := ABounds[I];
  end;
  FLock := TCriticalSection.Create;
  FSeriesByKey := TDictionary<string, TPcSeries>.Create;
  FSeries := TList<TPcSeries>.Create;
  if Length(FLabelNames) = 0 then
    FindOrCreate([]);
end;

destructor TPcMetric.Destroy;
var
  I: Integer;
begin
  if FSeries <> nil then
    for I := 0 to FSeries.Count - 1 do
      FSeries[I].Free;
  FSeries.Free;
  FSeriesByKey.Free;
  FLock.Free;
  inherited;
end;

function TPcMetric.NewSeries: TPcSeries;
var
  LHistogram: TPcHistogramSeries;
begin
  case FKind of
    mkCounter: Result := TPcCounterSeries.Create;
    mkUpDownCounter: Result := TPcUpDownCounterSeries.Create;
    mkGauge: Result := TPcGaugeSeries.Create;
  else
    LHistogram := TPcHistogramSeries.Create;
    LHistogram.FBounds := FBounds;
    SetLength(LHistogram.FBuckets, Length(FBounds) + 1);
    Result := LHistogram;
  end;
end;

function TPcMetric.FindOrCreate(const AValues: array of string): TPcSeries;
var
  LKey: string;
  I: Integer;
begin
  if Length(AValues) <> Length(FLabelNames) then
    raise EPcMetrics.CreateFmt('Metric "%s" takes %d label values, got %d',
      [FName, Length(FLabelNames), Length(AValues)]);
  // Length-prefixed, so no value can forge a separator.
  LKey := '';
  for I := 0 to High(AValues) do
    LKey := LKey + IntToStr(Length(AValues[I])) + ':' + AValues[I];
  FLock.Enter;
  try
    if FSeriesByKey.TryGetValue(LKey, Result) then
      Exit;
    Result := NewSeries;
    SetLength(Result.FLabelValues, Length(AValues));
    for I := 0 to High(AValues) do
      Result.FLabelValues[I] := AValues[I];
    FSeries.Add(Result);
    FSeriesByKey.Add(LKey, Result);
  finally
    FLock.Leave;
  end;
end;

function TPcMetric.DefaultSeries: TPcSeries;
begin
  if Length(FLabelNames) <> 0 then
    raise EPcMetrics.CreateFmt('Metric "%s" has labels: use Labels([...])', [FName]);
  Result := FSeries[0];
end;

function TPcMetric.Snapshot: TPcMetricPoints;
var
  LSeries: array of TPcSeries;
  LHistogram: TPcHistogramSeries;
  I, J: Integer;
begin
  LSeries := nil;
  FLock.Enter;
  try
    SetLength(LSeries, FSeries.Count);
    for I := 0 to FSeries.Count - 1 do
      LSeries[I] := FSeries[I];
  finally
    FLock.Leave;
  end;
  Result := nil;
  SetLength(Result, Length(LSeries));
  for I := 0 to High(LSeries) do
  begin
    Result[I].LabelValues := LSeries[I].FLabelValues;
    Result[I].Value := 0;
    Result[I].BucketCounts := nil;
    Result[I].Count := 0;
    Result[I].Sum := 0;
    case FKind of
      mkCounter: Result[I].Value := TPcCounterSeries(LSeries[I]).Value;
      mkUpDownCounter: Result[I].Value := TPcUpDownCounterSeries(LSeries[I]).Value;
      mkGauge: Result[I].Value := TPcGaugeSeries(LSeries[I]).Value;
      mkHistogram:
        begin
          LHistogram := TPcHistogramSeries(LSeries[I]);
          SetLength(Result[I].BucketCounts, Length(LHistogram.FBuckets));
          for J := 0 to High(LHistogram.FBuckets) do
          begin
            Result[I].BucketCounts[J] := PcAtomicRead64(LHistogram.FBuckets[J]);
            Result[I].Count := Result[I].Count + Result[I].BucketCounts[J];
          end;
          Result[I].Sum := LHistogram.Sum;
        end;
    end;
  end;
end;

{ TPcCounter }

function TPcCounter.Labels(const AValues: array of string): TPcCounterSeries;
begin
  Result := TPcCounterSeries(FindOrCreate(AValues));
end;

procedure TPcCounter.Inc;
begin
  TPcCounterSeries(DefaultSeries).Inc;
end;

procedure TPcCounter.Add(AValue: Double);
begin
  TPcCounterSeries(DefaultSeries).Add(AValue);
end;

{ TPcUpDownCounter }

function TPcUpDownCounter.Labels(const AValues: array of string): TPcUpDownCounterSeries;
begin
  Result := TPcUpDownCounterSeries(FindOrCreate(AValues));
end;

procedure TPcUpDownCounter.Inc;
begin
  TPcUpDownCounterSeries(DefaultSeries).Inc;
end;

procedure TPcUpDownCounter.Dec;
begin
  TPcUpDownCounterSeries(DefaultSeries).Dec;
end;

procedure TPcUpDownCounter.Add(AValue: Double);
begin
  TPcUpDownCounterSeries(DefaultSeries).Add(AValue);
end;

{ TPcGauge }

function TPcGauge.Labels(const AValues: array of string): TPcGaugeSeries;
begin
  Result := TPcGaugeSeries(FindOrCreate(AValues));
end;

procedure TPcGauge.SetValue(AValue: Double);
begin
  TPcGaugeSeries(DefaultSeries).SetValue(AValue);
end;

{ TPcHistogram }

function TPcHistogram.Labels(const AValues: array of string): TPcHistogramSeries;
begin
  Result := TPcHistogramSeries(FindOrCreate(AValues));
end;

procedure TPcHistogram.Observe(AValue: Double);
begin
  TPcHistogramSeries(DefaultSeries).Observe(AValue);
end;

{ TPcMetricRegistry }

constructor TPcMetricRegistry.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FByName := TDictionary<string, TPcMetric>.Create;
  FMetrics := TList<TPcMetric>.Create;
end;

destructor TPcMetricRegistry.Destroy;
var
  I: Integer;
begin
  if FMetrics <> nil then
    for I := 0 to FMetrics.Count - 1 do
      FMetrics[I].Free;
  FMetrics.Free;
  FByName.Free;
  FLock.Free;
  inherited;
end;

function SameDefinition(AMetric: TPcMetric; AKind: TPcMetricKind; const AMetricUnit: string;
  const ALabelNames: array of string; const ABounds: array of Double): Boolean;
var
  I: Integer;
begin
  Result := (AMetric.FKind = AKind) and (AMetric.FMetricUnit = AMetricUnit)
    and (Length(AMetric.FLabelNames) = Length(ALabelNames));
  if Result then
    for I := 0 to High(ALabelNames) do
      if AMetric.FLabelNames[I] <> ALabelNames[I] then
        Exit(False);
  if Result and (AKind = mkHistogram) then
  begin
    if Length(AMetric.FBounds) <> Length(ABounds) then
      Exit(False);
    for I := 0 to High(ABounds) do
      if AMetric.FBounds[I] <> ABounds[I] then
        Exit(False);
  end;
end;

function TPcMetricRegistry.GetOrAdd(AKind: TPcMetricKind; const AName, AMetricUnit,
  ADescription: string; const ALabelNames: array of string;
  const ABounds: array of Double): TPcMetric;
begin
  FLock.Enter;
  try
    if FByName.TryGetValue(AName, Result) then
    begin
      if not SameDefinition(Result, AKind, AMetricUnit, ALabelNames, ABounds) then
        raise EPcMetrics.CreateFmt('Metric "%s" is already registered with another definition',
          [AName]);
      Exit;
    end;
    case AKind of
      mkCounter: Result := TPcCounter.Create(AKind, AName, AMetricUnit, ADescription, ALabelNames, ABounds);
      mkUpDownCounter: Result := TPcUpDownCounter.Create(AKind, AName, AMetricUnit, ADescription, ALabelNames, ABounds);
      mkGauge: Result := TPcGauge.Create(AKind, AName, AMetricUnit, ADescription, ALabelNames, ABounds);
    else
      Result := TPcHistogram.Create(AKind, AName, AMetricUnit, ADescription, ALabelNames, ABounds);
    end;
    try
      FMetrics.Add(Result);
    except
      Result.Free;
      raise;
    end;
    FByName.Add(AName, Result);
  finally
    FLock.Leave;
  end;
end;

function TPcMetricRegistry.Counter(const AName, AMetricUnit, ADescription: string;
  const ALabelNames: array of string): TPcCounter;
begin
  Result := TPcCounter(GetOrAdd(mkCounter, AName, AMetricUnit, ADescription, ALabelNames, []));
end;

function TPcMetricRegistry.UpDownCounter(const AName, AMetricUnit, ADescription: string;
  const ALabelNames: array of string): TPcUpDownCounter;
begin
  Result := TPcUpDownCounter(GetOrAdd(mkUpDownCounter, AName, AMetricUnit, ADescription,
    ALabelNames, []));
end;

function TPcMetricRegistry.Gauge(const AName, AMetricUnit, ADescription: string;
  const ALabelNames: array of string): TPcGauge;
begin
  Result := TPcGauge(GetOrAdd(mkGauge, AName, AMetricUnit, ADescription, ALabelNames, []));
end;

function TPcMetricRegistry.Histogram(const AName, AMetricUnit, ADescription: string;
  const ALabelNames: array of string; const ABounds: array of Double): TPcHistogram;
begin
  Result := TPcHistogram(GetOrAdd(mkHistogram, AName, AMetricUnit, ADescription, ALabelNames,
    ABounds));
end;

function TPcMetricRegistry.Metrics: TPcMetricList;
var
  I: Integer;
begin
  FLock.Enter;
  try
    Result := nil;
    SetLength(Result, FMetrics.Count);
    for I := 0 to FMetrics.Count - 1 do
      Result[I] := FMetrics[I];
  finally
    FLock.Leave;
  end;
end;

{ Prometheus }

// Characters outside [a-zA-Z0-9_:] (or [a-zA-Z0-9_] for a label) become "_",
// runs of "_" become one, and a leading digit gets a "_" in front.
function Sanitize(const AValue: string; AAllowColon: Boolean): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    C := AValue[I];
    if not (IsLetter(C) or IsDigit(C) or (C = '_') or (AAllowColon and (C = ':'))) then
      C := '_';
    if (C = '_') and (Result <> '') and (Result[Length(Result)] = '_') then
      Continue;
    Result := Result + C;
  end;
  if (Result <> '') and IsDigit(Result[1]) then
    Result := '_' + Result;
end;

function UnitWord(const AUnit: string): string;
const
  CODES: array[0..24] of string = ('d', 'h', 'min', 's', 'ms', 'us', 'ns', 'By', 'KiBy',
    'MiBy', 'GiBy', 'TiBy', 'KBy', 'MBy', 'GBy', 'TBy', 'm', 'V', 'A', 'J', 'W', 'g', 'Cel',
    'Hz', '%');
  WORDS: array[0..24] of string = ('days', 'hours', 'minutes', 'seconds', 'milliseconds',
    'microseconds', 'nanoseconds', 'bytes', 'kibibytes', 'mebibytes', 'gibibytes',
    'tebibytes', 'kilobytes', 'megabytes', 'gigabytes', 'terabytes', 'meters', 'volts',
    'amperes', 'joules', 'watts', 'grams', 'celsius', 'hertz', 'percent');
var
  I: Integer;
begin
  for I := 0 to High(CODES) do
    if CODES[I] = AUnit then
      Exit(WORDS[I]);
  Result := AUnit;
end;

function PerUnitWord(const AUnit: string): string;
const
  CODES: array[0..6] of string = ('s', 'm', 'h', 'd', 'w', 'mo', 'y');
  WORDS: array[0..6] of string = ('second', 'minute', 'hour', 'day', 'week', 'month', 'year');
var
  I: Integer;
begin
  for I := 0 to High(CODES) do
    if CODES[I] = AUnit then
      Exit(WORDS[I]);
  Result := AUnit;
end;

// "{request}" and other annotations are removed; "1" is handled by the caller.
function StripAnnotations(const AUnit: string): string;
var
  I: Integer;
  LDepth: Integer;
begin
  Result := '';
  LDepth := 0;
  for I := 1 to Length(AUnit) do
    if AUnit[I] = '{' then
      System.Inc(LDepth)
    else if AUnit[I] = '}' then
    begin
      if LDepth > 0 then
        System.Dec(LDepth);
    end
    else if LDepth = 0 then
      Result := Result + AUnit[I];
end;

function UnitSuffix(AKind: TPcMetricKind; const AUnit: string): string;
var
  LUnit, LMain, LPer: string;
  P: Integer;
begin
  Result := '';
  LUnit := StripAnnotations(AUnit);
  if LUnit = '' then
    Exit;
  if LUnit = '1' then
  begin
    if AKind = mkGauge then
      Result := 'ratio';
    Exit;
  end;
  P := Pos('/', LUnit);
  if P > 0 then
  begin
    LMain := Copy(LUnit, 1, P - 1);
    LPer := Copy(LUnit, P + 1, MaxInt);
    if LMain <> '' then
      Result := UnitWord(LMain);
    if LPer <> '' then
    begin
      if Result <> '' then
        Result := Result + '_';
      Result := Result + 'per_' + PerUnitWord(LPer);
    end;
  end
  else
    Result := UnitWord(LUnit);
  Result := Sanitize(Result, False);
  while (Result <> '') and (Result[1] = '_') do
    Delete(Result, 1, 1);
  while (Result <> '') and (Result[Length(Result)] = '_') do
    Delete(Result, Length(Result), 1);
end;

function EndsWith(const AValue, ASuffix: string): Boolean;
begin
  Result := (Length(AValue) >= Length(ASuffix))
    and (Copy(AValue, Length(AValue) - Length(ASuffix) + 1, Length(ASuffix)) = ASuffix);
end;

function PcPrometheusName(AMetric: TPcMetric): string;
var
  LSuffix: string;
begin
  Result := Sanitize(AMetric.Name, True);
  LSuffix := UnitSuffix(AMetric.Kind, AMetric.MetricUnit);
  if (LSuffix <> '') and not EndsWith(Result, '_' + LSuffix) then
    Result := Result + '_' + LSuffix;
  if (AMetric.Kind = mkCounter) and not EndsWith(Result, '_total') then
    Result := Result + '_total';
end;

function PcPrometheusLabelName(const AName: string): string;
begin
  Result := Sanitize(AName, False);
end;

function PcPrometheusFloat(AValue: Double): string;
begin
  if IsNan(AValue) then
    Exit('NaN');
  if IsInfinite(AValue) then
  begin
    if AValue > 0 then
      Exit('+Inf');
    Exit('-Inf');
  end;
  if (Frac(AValue) = 0) and (Abs(AValue) < 9007199254740992.0) then
    Exit(IntToStr(Trunc(AValue)));
  Result := FloatToStrF(AValue, ffGeneral, 15, 0, GInvariant);
end;

function EscapeHelp(const AValue: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AValue) do
    case AValue[I] of
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
    else
      Result := Result + AValue[I];
    end;
end;

function EscapeLabelValue(const AValue: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AValue) do
    case AValue[I] of
      '\': Result := Result + '\\';
      '"': Result := Result + '\"';
      #10: Result := Result + '\n';
    else
      Result := Result + AValue[I];
    end;
end;

// '{a="x",b="y"}', with AExtra ('le="0.5"') appended; '' when there is nothing.
function LabelText(const ANames: array of string; const AValues: TPcLabelValues;
  const AExtra: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ANames) do
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + ANames[I] + '="' + EscapeLabelValue(AValues[I]) + '"';
  end;
  if AExtra <> '' then
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + AExtra;
  end;
  if Result <> '' then
    Result := '{' + Result + '}';
end;

procedure AppendMetric(ABuilder: TStringBuilder; AMetric: TPcMetric);
const
  TYPE_NAMES: array[TPcMetricKind] of string = ('counter', 'gauge', 'gauge', 'histogram');
  LF = #10;
var
  LName: string;
  LLabelNames: array of string;
  LPoints: TPcMetricPoints;
  LCumulative: UInt64;
  I, J: Integer;
begin
  LName := PcPrometheusName(AMetric);
  LLabelNames := nil;
  SetLength(LLabelNames, Length(AMetric.LabelNames));
  for I := 0 to High(LLabelNames) do
    LLabelNames[I] := PcPrometheusLabelName(AMetric.LabelNames[I]);
  if AMetric.Description <> '' then
    ABuilder.Append('# HELP ').Append(LName).Append(' ').Append(EscapeHelp(AMetric.Description)).Append(LF);
  ABuilder.Append('# TYPE ').Append(LName).Append(' ').Append(TYPE_NAMES[AMetric.Kind]).Append(LF);
  LPoints := AMetric.Snapshot;
  for I := 0 to High(LPoints) do
    if AMetric.Kind <> mkHistogram then
      ABuilder.Append(LName).Append(LabelText(LLabelNames, LPoints[I].LabelValues, ''))
        .Append(' ').Append(PcPrometheusFloat(LPoints[I].Value)).Append(LF)
    else
    begin
      LCumulative := 0;
      for J := 0 to High(LPoints[I].BucketCounts) do
      begin
        LCumulative := LCumulative + LPoints[I].BucketCounts[J];
        if J <= High(AMetric.Bounds) then
          ABuilder.Append(LName).Append('_bucket').Append(LabelText(LLabelNames, LPoints[I].LabelValues,
            'le="' + PcPrometheusFloat(AMetric.Bounds[J]) + '"'))
        else
          ABuilder.Append(LName).Append('_bucket').Append(LabelText(LLabelNames, LPoints[I].LabelValues,
            'le="+Inf"'));
        ABuilder.Append(' ').Append(UIntToStr(LCumulative)).Append(LF);
      end;
      ABuilder.Append(LName).Append('_sum').Append(LabelText(LLabelNames, LPoints[I].LabelValues, ''))
        .Append(' ').Append(PcPrometheusFloat(LPoints[I].Sum)).Append(LF);
      ABuilder.Append(LName).Append('_count').Append(LabelText(LLabelNames, LPoints[I].LabelValues, ''))
        .Append(' ').Append(UIntToStr(LPoints[I].Count)).Append(LF);
    end;
end;

function PcPrometheusText(ARegistry: TPcMetricRegistry): string;
var
  LBuilder: TStringBuilder;
  LMetrics: TPcMetricList;
  I: Integer;
begin
  LMetrics := ARegistry.Metrics;
  LBuilder := TStringBuilder.Create;
  try
    for I := 0 to High(LMetrics) do
      AppendMetric(LBuilder, LMetrics[I]);
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

initialization
  {$IFDEF FPC}
  GInvariant := DefaultFormatSettings;
  {$ELSE}
  GInvariant := TFormatSettings.Create;
  {$ENDIF}
  GInvariant.DecimalSeparator := '.';
  GInvariant.ThousandSeparator := ',';
  PcMetrics := TPcMetricRegistry.Create;

finalization
  FreeAndNil(PcMetrics);

end.
