unit PascalCommon.Tracing;

{$I pascalcommon.inc}

(* Spans: a tracer with a current span per thread, parent-based sampling with
  a ratio for new traces, and a batch processor that hands finished spans to
  an exporter on its own thread.

    TPcTracing.Start(TPcTracingOptions.FromEnvironment('orders', '1.0.0'),
      AnExporter);
    ...
    LSpan := TPcTracing.StartSpan('SELECT orders', skClient);
    try
      LSpan.SetAttribute('db.system', 'postgresql');
      ...
    finally
      LSpan.Finish;
    end;

  It was written in pascal-api-infra-faa as PascalApi.Tracing (phase C of
  docs/observability-design.md there, an unstable API) and moved here at the
  start of phase D, so pascal-db-faa, pascal-redis-faa and pascal-amqp-faa can
  open spans that join the API's trace without depending on the API library.
  The exporters stay out: OTLP over HTTP needs an HTTP client and a JSON
  writer, which this library doesn't have. An exporter is anything that
  implements IPcSpanExporter (pascal-api-infra-faa's TOtlpHttpExporter, or a
  test's fake). What changed on the way: the Pc prefixes; Enabled reads a
  flag without a lock (a library may ask it on every call); FromEnvironment
  reads the process environment, with an overload that takes the lookup (an
  application reading a .env file passes its own); StartSpanFromParent, for
  a consumer that gets traceparent in a message. 1.8.0 added
  StartDetachedSpan and StartChildSpan (see the rule on threads below).

  Decisions (unchanged from the API library):
  - Not started (or after Shutdown), every call still works: spans carry ids
    and a traceparent, record nothing and export nothing. A library can
    instrument unconditionally; one on a hot path may check Enabled first to
    skip even the ids.
  - Sampling: a span with a parent follows the parent's sampled flag; a new
    trace is sampled when the last 16 hex digits of its id, as a 64-bit
    number, fall below SampleRatio * 2^64 (OpenTelemetry's
    TraceIdRatioBased, deterministic for a trace id). Only sampled spans are
    exported.
  - The current span is a per-thread pointer, not an interface threadvar
    (Delphi doesn't finalize managed threadvars). A span holds its parent
    alive; Finish (or freeing an unfinished span) puts the parent back. A
    request served on one thread has its server span as the current one for
    the whole handler; another thread (a pool's) starts with none, and the
    context crosses to it explicitly (StartSpanWith, or a traceparent).
  - A span that becomes the current one (StartSpan, StartSpanWith,
    StartSpanFromParent, StartChildSpan) must be finished on the thread that
    started it. This is a memory rule, not only a tracing one: Finish and
    the destructor can clear only the calling thread's pointer, so a span
    finished and freed on another thread leaves the first thread pointing
    at freed memory, read by its next StartSpan or Current. Work whose end
    happens elsewhere (a transaction committed on another thread, a message
    acknowledged later) uses StartDetachedSpan: it never becomes the current
    span, so it can be finished on any thread, and the spans inside it name
    it as their parent explicitly with StartChildSpan. Found by
    pascal-db-faa in phase D; added in 1.8.0. Any span is used by one thread
    at a time: one handed over passes through whatever synchronizes the
    hand-over.
  - Time: start and end in Unix nanoseconds, UTC. The wall clock is
    TClock.Now (PascalCommon.SystemContext, replaceable in tests) converted
    to UTC with DateTimeToUnix(.., False), milliseconds precision; the
    duration comes from PcTickUs, so end - start is monotonic.
  - The processor's queue is bounded (QueueCapacity): when full, the
    oldest span is dropped and counted (DroppedCount). Exporting never
    blocks the caller; a failed batch is dropped and reported to AOnError.
  - Configuration from the standard OpenTelemetry variables:
    OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES, OTEL_TRACES_SAMPLER_ARG,
    OTEL_BSP_MAX_QUEUE_SIZE, OTEL_BSP_SCHEDULE_DELAY,
    OTEL_BSP_MAX_EXPORT_BATCH_SIZE.
  - At finalization a processor still running is dropped without exporting:
    the exporter's units (an HTTP client) may be finalized already. An
    application that must not lose the last spans calls TPcTracing.Shutdown
    before it ends. *)

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections;

type
  TPcSpanKind = (skInternal, skServer, skClient, skProducer, skConsumer);
  TPcSpanStatus = (ssUnset, ssOk, ssError);
  TPcSpanAttributeType = (satString, satInt, satDouble, satBool);

  TPcSpanAttribute = record
    Key: string;
    ValueType: TPcSpanAttributeType;
    StringValue: string;
    IntValue: Int64;
    DoubleValue: Double;
    BoolValue: Boolean;
  end;
  TPcSpanAttributes = array of TPcSpanAttribute;

  /// A finished span, as the exporter gets it.
  TPcSpanData = record
    TraceId: string;
    SpanId: string;
    ParentSpanId: string;
    TraceState: string;
    Name: string;
    Kind: TPcSpanKind;
    StartUnixNano: Int64;
    EndUnixNano: Int64;
    Attributes: TPcSpanAttributes;
    Status: TPcSpanStatus;
    StatusMessage: string;
  end;
  TPcSpanDataArray = array of TPcSpanData;

  IPcSpan = interface
    ['{8D875876-D7B1-49E4-BED1-A4388B8315AF}']
    function TraceId: string;
    function SpanId: string;
    function ParentSpanId: string;
    function Sampled: Boolean;
    /// '00-<trace id>-<span id>-<flags>': what an outgoing call (an HTTP
    /// request, a message) made inside this span sends.
    function TraceParent: string;
    function TraceState: string;
    procedure SetName(const AName: string);
    /// A second call with the same key replaces the value.
    procedure SetAttribute(const AKey, AValue: string);
    procedure SetIntAttribute(const AKey: string; AValue: Int64);
    procedure SetDoubleAttribute(const AKey: string; AValue: Double);
    procedure SetBoolAttribute(const AKey: string; AValue: Boolean);
    /// The message is kept only with ssError.
    procedure SetStatus(AStatus: TPcSpanStatus; const AMessage: string = '');
    /// Ends the span (only the first call counts), hands it to the exporter
    /// when sampled, and makes its parent the current span again.
    procedure Finish;
  end;

  IPcSpanExporter = interface
    ['{879C17C7-A218-4478-8337-1C9F299C9F63}']
    /// Called on the processor's thread, one batch at a time. Raise (or
    /// return False with AError set) when the batch was not accepted.
    function ExportSpans(const ASpans: TPcSpanDataArray; out AError: string): Boolean;
  end;

  /// Reports what went wrong off the caller's thread (a failed export).
  {$IFDEF PASCALCOMMON_FUNCREFS}
  TPcLogProc = reference to procedure(const ALine: string);
  {$ELSE}
  TPcLogProc = procedure(const ALine: string) of object;
  {$ENDIF}

  /// The value of an environment variable, '' when unset.
  TPcEnvironmentLookup = function(const AName: string): string;

  TPcTracingOptions = record
    ServiceName: string;
    ServiceVersion: string;
    /// 'key=value,key=value' (OTEL_RESOURCE_ATTRIBUTES), for the exporter's
    /// resource after service.name and service.version.
    ResourceAttributes: string;
    /// 0 to 1: the share of new traces sampled. 1 by default.
    SampleRatio: Double;
    /// Spans waiting for export; when full, the oldest is dropped. 2048.
    QueueCapacity: Integer;
    /// Most spans in one export. 512.
    MaxBatchSize: Integer;
    /// Milliseconds between exports. 5000 (OpenTelemetry's default).
    FlushIntervalMs: Integer;
    class function Default(const AServiceName, AServiceVersion: string): TPcTracingOptions; static;
    /// Default, then the OTEL_* variables of the process environment
    /// (OTEL_SERVICE_NAME replaces AServiceName). Invalid values keep the
    /// default.
    class function FromEnvironment(const AServiceName, AServiceVersion: string): TPcTracingOptions; overload; static;
    /// The same, reading each variable through ALookup.
    class function FromEnvironment(const AServiceName, AServiceVersion: string;
      ALookup: TPcEnvironmentLookup): TPcTracingOptions; overload; static;
  end;

  TPcTracing = class
  public
    /// Starts recording: finished sampled spans go to AExporter in batches.
    /// AAutoFlush = False (tests only) starts no thread: FlushNow exports.
    /// Calling Start again replaces the previous configuration (after
    /// flushing it).
    class procedure Start(const AOptions: TPcTracingOptions; const AExporter: IPcSpanExporter;
      AAutoFlush: Boolean = True); overload; static;
    class procedure Start(const AOptions: TPcTracingOptions; const AExporter: IPcSpanExporter;
      const AOnError: TPcLogProc; AAutoFlush: Boolean = True); overload; static;
    /// Exports what is queued, stops the thread, forgets the exporter.
    class procedure Shutdown; static;
    /// Started and not shut down. No lock.
    class function Enabled: Boolean; static;
    class function Options: TPcTracingOptions; static;
    /// A span that is a child of the current one (or the root of a new
    /// trace), and becomes the current one.
    class function StartSpan(const AName: string; AKind: TPcSpanKind = skInternal): IPcSpan; static;
    /// A span with the ids given (a server span whose ids come from the
    /// request, or work handed to another thread), and becomes the current
    /// one.
    class function StartSpanWith(const ATraceId, ASpanId, AParentSpanId, ATraceState: string;
      ASampled: Boolean; const AName: string; AKind: TPcSpanKind): IPcSpan; static;
    /// A child of the remote span in ATraceParent (a message's header), with
    /// its sampled flag and ATraceState (PcResolveTraceState's rules); when
    /// ATraceParent is invalid or empty, the same as StartSpan.
    class function StartSpanFromParent(const ATraceParent, ATraceState, AName: string;
      AKind: TPcSpanKind): IPcSpan; static;
    /// A span that never becomes the current one, so it can be finished on
    /// any thread (see the header). Its parent is AParent; when nil, the
    /// current span; when there is none, it starts a new trace.
    class function StartDetachedSpan(const AName: string; AKind: TPcSpanKind = skInternal;
      const AParent: IPcSpan = nil): IPcSpan; static;
    /// A child of AParent (typically a detached span), not of the current
    /// span, and the current span of this thread until it finishes, when the
    /// previous current span comes back. A nil AParent is StartSpan.
    class function StartChildSpan(const AParent: IPcSpan; const AName: string;
      AKind: TPcSpanKind = skInternal): IPcSpan; static;
    /// The current span of this thread; nil when none.
    class function Current: IPcSpan; static;
    /// The sampling decision for a new trace with this id (see the header).
    class function ShouldSample(const ATraceId: string): Boolean; static;
    /// Exports what is queued now, on the calling thread.
    class procedure FlushNow; static;
    /// Spans dropped because the queue was full, since Start.
    class function DroppedCount: Int64; static;
    /// Spans waiting for export.
    class function PendingCount: Integer; static;
  end;

/// Unix time in nanoseconds, UTC, of a local TDateTime (milliseconds
/// precision).
function PcUnixNanoOfLocal(ATime: TDateTime): Int64;

implementation

uses
  DateUtils,
  PascalCommon.SystemContext,
  PascalCommon.Threading,
  PascalCommon.TraceContext;

type
  TPcSpanProcessor = class;

  TPcSpanProcessorThread = class(TThread)
  private
    FOwner: TPcSpanProcessor;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TPcSpanProcessor);
  end;

  TPcSpanProcessor = class
  private
    FOptions: TPcTracingOptions;
    FExporter: IPcSpanExporter;
    FOnError: TPcLogProc;
    FQueue: TQueue<TPcSpanData>;
    FLock: TCriticalSection;
    FExportLock: TCriticalSection;
    FWake: TEvent;
    FThread: TPcSpanProcessorThread;
    FDropped: Int64;
    function TakeBatch: TPcSpanDataArray;
  public
    constructor Create(const AOptions: TPcTracingOptions; const AExporter: IPcSpanExporter;
      const AOnError: TPcLogProc; AAutoFlush: Boolean);
    destructor Destroy; override;
    procedure Enqueue(const ASpan: TPcSpanData);
    procedure Flush;
    function PendingCount: Integer;
  end;

  TPcSpan = class(TInterfacedObject, IPcSpan)
  private
    FData: TPcSpanData;
    FSampled: Boolean;
    FRecording: Boolean;
    FFinished: Boolean;
    FStartTick: Int64;
    // The span that was current when this one started, restored by Finish;
    // kept alive by FParent, FParentSpan is the same object for the thread's
    // pointer. It is the logical parent except with StartChildSpan, and nil
    // for a detached span.
    FParent: IPcSpan;
    FParentSpan: TPcSpan;
    // Never the current span (StartDetachedSpan).
    FDetached: Boolean;
    procedure AddAttribute(const AAttribute: TPcSpanAttribute);
    procedure LeaveCurrent;
  public
    constructor Create(const ATraceId, ASpanId, AParentSpanId, ATraceState: string;
      ASampled: Boolean; const AName: string; AKind: TPcSpanKind; AParent: TPcSpan);
    destructor Destroy; override;
    function TraceId: string;
    function SpanId: string;
    function ParentSpanId: string;
    function Sampled: Boolean;
    function TraceParent: string;
    function TraceState: string;
    procedure SetName(const AName: string);
    procedure SetAttribute(const AKey, AValue: string);
    procedure SetIntAttribute(const AKey: string; AValue: Int64);
    procedure SetDoubleAttribute(const AKey: string; AValue: Double);
    procedure SetBoolAttribute(const AKey: string; AValue: Boolean);
    procedure SetStatus(AStatus: TPcSpanStatus; const AMessage: string = '');
    procedure Finish;
  end;

threadvar
  // The current span of the thread (a TPcSpan, not counted: see the header).
  GCurrent: Pointer;

var
  // Replaced only by Start/Shutdown (at startup and exit); read by every
  // span's Finish under GStateLock.
  GProcessor: TPcSpanProcessor;
  GOptions: TPcTracingOptions;
  GStateLock: TCriticalSection;
  // 1 while GProcessor is set: Enabled reads it without the lock.
  GEnabled: Integer;
  GInvariant: TFormatSettings;

{ Helpers }

function PcUnixNanoOfLocal(ATime: TDateTime): Int64;
var
  LOffsetSeconds: Int64;
begin
  // DateTimeToUnix(T, False) treats T as local time, (T, True) as UTC: the
  // difference is the local offset in seconds, at that moment.
  LOffsetSeconds := DateTimeToUnix(ATime, False) - DateTimeToUnix(ATime, True);
  Result := (Round((ATime - UnixDateDelta) * MSecsPerDay) + LOffsetSeconds * 1000) * 1000000;
end;

function HexDigit(C: Char; out AValue: Integer): Boolean;
begin
  Result := True;
  if (C >= '0') and (C <= '9') then
    AValue := Ord(C) - Ord('0')
  else if (C >= 'a') and (C <= 'f') then
    AValue := Ord(C) - Ord('a') + 10
  else
  begin
    AValue := 0;
    Result := False;
  end;
end;

function SpanAttribute(const AKey: string; AType: TPcSpanAttributeType): TPcSpanAttribute;
begin
  Result.Key := AKey;
  Result.ValueType := AType;
  Result.StringValue := '';
  Result.IntValue := 0;
  Result.DoubleValue := 0;
  Result.BoolValue := False;
end;

function ProcessEnvironment(const AName: string): string;
begin
  Result := GetEnvironmentVariable(AName);
end;

{ TPcTracingOptions }

class function TPcTracingOptions.Default(const AServiceName, AServiceVersion: string): TPcTracingOptions;
begin
  Result.ServiceName := AServiceName;
  Result.ServiceVersion := AServiceVersion;
  Result.ResourceAttributes := '';
  Result.SampleRatio := 1;
  Result.QueueCapacity := 2048;
  Result.MaxBatchSize := 512;
  Result.FlushIntervalMs := 5000;
end;

class function TPcTracingOptions.FromEnvironment(const AServiceName,
  AServiceVersion: string): TPcTracingOptions;
begin
  Result := FromEnvironment(AServiceName, AServiceVersion, ProcessEnvironment);
end;

class function TPcTracingOptions.FromEnvironment(const AServiceName, AServiceVersion: string;
  ALookup: TPcEnvironmentLookup): TPcTracingOptions;

  procedure ReadPositive(const AName: string; var AValue: Integer);
  var
    LValue: Integer;
  begin
    if TryStrToInt(Trim(ALookup(AName)), LValue) and (LValue >= 1) then
      AValue := LValue;
  end;

var
  LName: string;
  LRatio: Double;
begin
  LName := Trim(ALookup('OTEL_SERVICE_NAME'));
  if LName = '' then
    LName := AServiceName;
  Result := Default(LName, AServiceVersion);
  Result.ResourceAttributes := Trim(ALookup('OTEL_RESOURCE_ATTRIBUTES'));
  if TryStrToFloat(Trim(ALookup('OTEL_TRACES_SAMPLER_ARG')), LRatio, GInvariant)
    and (LRatio >= 0) and (LRatio <= 1) then
    Result.SampleRatio := LRatio;
  ReadPositive('OTEL_BSP_MAX_QUEUE_SIZE', Result.QueueCapacity);
  ReadPositive('OTEL_BSP_SCHEDULE_DELAY', Result.FlushIntervalMs);
  ReadPositive('OTEL_BSP_MAX_EXPORT_BATCH_SIZE', Result.MaxBatchSize);
end;

{ TPcSpanProcessorThread }

constructor TPcSpanProcessorThread.Create(AOwner: TPcSpanProcessor);
begin
  FOwner := AOwner;
  inherited Create(False);
  FreeOnTerminate := False;
end;

procedure TPcSpanProcessorThread.Execute;
begin
  // Woken early only to stop; every interval, export what is queued.
  while FOwner.FWake.WaitFor(FOwner.FOptions.FlushIntervalMs) = wrTimeout do
    FOwner.Flush;
  FOwner.Flush;
end;

{ TPcSpanProcessor }

constructor TPcSpanProcessor.Create(const AOptions: TPcTracingOptions;
  const AExporter: IPcSpanExporter; const AOnError: TPcLogProc; AAutoFlush: Boolean);
begin
  inherited Create;
  FOptions := AOptions;
  FExporter := AExporter;
  FOnError := AOnError;
  FQueue := TQueue<TPcSpanData>.Create;
  FLock := TCriticalSection.Create;
  FExportLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, True, False, '');
  if AAutoFlush then
    FThread := TPcSpanProcessorThread.Create(Self);
end;

destructor TPcSpanProcessor.Destroy;
begin
  if FThread <> nil then
  begin
    FWake.SetEvent;
    FThread.WaitFor;
    FreeAndNil(FThread);
  end
  else
    Flush;
  FWake.Free;
  FExportLock.Free;
  FLock.Free;
  FQueue.Free;
  inherited;
end;

procedure TPcSpanProcessor.Enqueue(const ASpan: TPcSpanData);
begin
  FLock.Acquire;
  try
    if FQueue.Count >= FOptions.QueueCapacity then
    begin
      FQueue.Dequeue;
      Inc(FDropped);
    end;
    FQueue.Enqueue(ASpan);
  finally
    FLock.Release;
  end;
end;

function TPcSpanProcessor.TakeBatch: TPcSpanDataArray;
var
  LCount, I: Integer;
begin
  FLock.Acquire;
  try
    LCount := FQueue.Count;
    if LCount > FOptions.MaxBatchSize then
      LCount := FOptions.MaxBatchSize;
    Result := nil;
    SetLength(Result, LCount);
    for I := 0 to LCount - 1 do
      Result[I] := FQueue.Dequeue;
  finally
    FLock.Release;
  end;
end;

procedure TPcSpanProcessor.Flush;
var
  LBatch: TPcSpanDataArray;
  LError: string;
  LOk: Boolean;
begin
  if FExporter = nil then
    Exit;
  // One export at a time (the thread and a FlushNow may meet).
  FExportLock.Acquire;
  try
    repeat
      LBatch := TakeBatch;
      if Length(LBatch) = 0 then
        Break;
      LError := '';
      try
        LOk := FExporter.ExportSpans(LBatch, LError);
      except
        on E: Exception do
        begin
          LOk := False;
          LError := E.ClassName + ': ' + E.Message;
        end;
      end;
      if (not LOk) and Assigned(FOnError) then
        FOnError(Format('span export failed (%d spans dropped): %s', [Length(LBatch), LError]));
    until False;
  finally
    FExportLock.Release;
  end;
end;

function TPcSpanProcessor.PendingCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FQueue.Count;
  finally
    FLock.Release;
  end;
end;

{ TPcSpan }

constructor TPcSpan.Create(const ATraceId, ASpanId, AParentSpanId, ATraceState: string;
  ASampled: Boolean; const AName: string; AKind: TPcSpanKind; AParent: TPcSpan);
begin
  inherited Create;
  FData.TraceId := ATraceId;
  FData.SpanId := ASpanId;
  FData.ParentSpanId := AParentSpanId;
  FData.TraceState := ATraceState;
  FData.Name := AName;
  FData.Kind := AKind;
  FData.Status := ssUnset;
  FData.StatusMessage := '';
  FData.Attributes := nil;
  FSampled := ASampled;
  FRecording := ASampled and TPcTracing.Enabled;
  FParentSpan := AParent;
  FParent := AParent;
  FData.StartUnixNano := PcUnixNanoOfLocal(TClock.Now);
  FStartTick := PcTickUs;
end;

destructor TPcSpan.Destroy;
begin
  // Freed unfinished (the last reference went away): don't leave the thread
  // pointing at it.
  LeaveCurrent;
  inherited;
end;

procedure TPcSpan.LeaveCurrent;
begin
  // A detached span was never current, and may be finished or freed on a
  // thread whose pointer it must not touch.
  if not FDetached and (GCurrent = Pointer(Self)) then
    GCurrent := Pointer(FParentSpan);
end;

function TPcSpan.TraceId: string;
begin
  Result := FData.TraceId;
end;

function TPcSpan.SpanId: string;
begin
  Result := FData.SpanId;
end;

function TPcSpan.ParentSpanId: string;
begin
  Result := FData.ParentSpanId;
end;

function TPcSpan.Sampled: Boolean;
begin
  Result := FSampled;
end;

function TPcSpan.TraceParent: string;
begin
  Result := PcFormatTraceParent(FData.TraceId, FData.SpanId, FSampled);
end;

function TPcSpan.TraceState: string;
begin
  Result := FData.TraceState;
end;

procedure TPcSpan.SetName(const AName: string);
begin
  if not FFinished then
    FData.Name := AName;
end;

procedure TPcSpan.AddAttribute(const AAttribute: TPcSpanAttribute);
var
  I: Integer;
begin
  if not FRecording or FFinished then
    Exit;
  for I := 0 to High(FData.Attributes) do
    if FData.Attributes[I].Key = AAttribute.Key then
    begin
      FData.Attributes[I] := AAttribute;
      Exit;
    end;
  SetLength(FData.Attributes, Length(FData.Attributes) + 1);
  FData.Attributes[High(FData.Attributes)] := AAttribute;
end;

procedure TPcSpan.SetAttribute(const AKey, AValue: string);
var
  LAttribute: TPcSpanAttribute;
begin
  LAttribute := SpanAttribute(AKey, satString);
  LAttribute.StringValue := AValue;
  AddAttribute(LAttribute);
end;

procedure TPcSpan.SetIntAttribute(const AKey: string; AValue: Int64);
var
  LAttribute: TPcSpanAttribute;
begin
  LAttribute := SpanAttribute(AKey, satInt);
  LAttribute.IntValue := AValue;
  AddAttribute(LAttribute);
end;

procedure TPcSpan.SetDoubleAttribute(const AKey: string; AValue: Double);
var
  LAttribute: TPcSpanAttribute;
begin
  LAttribute := SpanAttribute(AKey, satDouble);
  LAttribute.DoubleValue := AValue;
  AddAttribute(LAttribute);
end;

procedure TPcSpan.SetBoolAttribute(const AKey: string; AValue: Boolean);
var
  LAttribute: TPcSpanAttribute;
begin
  LAttribute := SpanAttribute(AKey, satBool);
  LAttribute.BoolValue := AValue;
  AddAttribute(LAttribute);
end;

procedure TPcSpan.SetStatus(AStatus: TPcSpanStatus; const AMessage: string);
begin
  if FFinished then
    Exit;
  FData.Status := AStatus;
  if AStatus = ssError then
    FData.StatusMessage := AMessage
  else
    FData.StatusMessage := '';
end;

procedure TPcSpan.Finish;
begin
  if FFinished then
    Exit;
  FFinished := True;
  FData.EndUnixNano := FData.StartUnixNano + (PcTickUs - FStartTick) * 1000;
  LeaveCurrent;
  if FRecording then
  begin
    GStateLock.Acquire;
    try
      if GProcessor <> nil then
        GProcessor.Enqueue(FData);
    finally
      GStateLock.Release;
    end;
  end;
end;

{ TPcTracing }

class procedure TPcTracing.Start(const AOptions: TPcTracingOptions;
  const AExporter: IPcSpanExporter; AAutoFlush: Boolean);
begin
  Start(AOptions, AExporter, nil, AAutoFlush);
end;

class procedure TPcTracing.Start(const AOptions: TPcTracingOptions;
  const AExporter: IPcSpanExporter; const AOnError: TPcLogProc; AAutoFlush: Boolean);
var
  LOld: TPcSpanProcessor;
begin
  GStateLock.Acquire;
  try
    LOld := GProcessor;
    GOptions := AOptions;
    GProcessor := TPcSpanProcessor.Create(AOptions, AExporter, AOnError, AAutoFlush);
    PcAtomicSet(GEnabled, 1);
  finally
    GStateLock.Release;
  end;
  LOld.Free;
end;

class procedure TPcTracing.Shutdown;
var
  LOld: TPcSpanProcessor;
begin
  GStateLock.Acquire;
  try
    LOld := GProcessor;
    GProcessor := nil;
    PcAtomicSet(GEnabled, 0);
  finally
    GStateLock.Release;
  end;
  // Exports what is left (the thread's last Flush, or Destroy's).
  LOld.Free;
end;

class function TPcTracing.Enabled: Boolean;
begin
  Result := PcAtomicGet(GEnabled) <> 0;
end;

class function TPcTracing.Options: TPcTracingOptions;
begin
  GStateLock.Acquire;
  try
    Result := GOptions;
  finally
    GStateLock.Release;
  end;
end;

class function TPcTracing.ShouldSample(const ATraceId: string): Boolean;
var
  LRatio: Double;
  LValue: UInt64;
  I, LDigit: Integer;
begin
  LRatio := Options.SampleRatio;
  if LRatio >= 1 then
    Exit(True);
  if (LRatio <= 0) or (Length(ATraceId) <> 32) then
    Exit(False);
  LValue := 0;
  for I := 17 to 32 do
  begin
    if not HexDigit(ATraceId[I], LDigit) then
      Exit(False);
    LValue := (LValue shl 4) or UInt64(LDigit);
  end;
  // The top 53 bits are enough for a Double comparison.
  Result := (LValue shr 11) < UInt64(Trunc(LRatio * 9007199254740992.0));
end;

class function TPcTracing.StartSpanWith(const ATraceId, ASpanId, AParentSpanId,
  ATraceState: string; ASampled: Boolean; const AName: string; AKind: TPcSpanKind): IPcSpan;
var
  LSpan: TPcSpan;
begin
  LSpan := TPcSpan.Create(ATraceId, ASpanId, AParentSpanId, ATraceState, ASampled, AName, AKind,
    TPcSpan(GCurrent));
  Result := LSpan;
  GCurrent := Pointer(LSpan);
end;

class function TPcTracing.StartSpan(const AName: string; AKind: TPcSpanKind): IPcSpan;
var
  LParent: IPcSpan;
  LTraceId: string;
begin
  LParent := Current;
  if LParent <> nil then
    Result := StartSpanWith(LParent.TraceId, PcNewSpanId, LParent.SpanId, LParent.TraceState,
      LParent.Sampled, AName, AKind)
  else
  begin
    LTraceId := PcNewTraceId;
    Result := StartSpanWith(LTraceId, PcNewSpanId, '', '', ShouldSample(LTraceId), AName, AKind);
  end;
end;

class function TPcTracing.StartSpanFromParent(const ATraceParent, ATraceState, AName: string;
  AKind: TPcSpanKind): IPcSpan;
var
  LParent: TPcTraceParent;
begin
  if PcTryParseTraceParent(ATraceParent, LParent) then
    Result := StartSpanWith(LParent.TraceId, PcNewSpanId, LParent.ParentId,
      PcResolveTraceState(True, ATraceState), LParent.Sampled, AName, AKind)
  else
    Result := StartSpan(AName, AKind);
end;

class function TPcTracing.StartDetachedSpan(const AName: string; AKind: TPcSpanKind;
  const AParent: IPcSpan): IPcSpan;
var
  LParent: IPcSpan;
  LTraceId: string;
  LSpan: TPcSpan;
begin
  LParent := AParent;
  if LParent = nil then
    LParent := Current;
  if LParent <> nil then
    LSpan := TPcSpan.Create(LParent.TraceId, PcNewSpanId, LParent.SpanId, LParent.TraceState,
      LParent.Sampled, AName, AKind, nil)
  else
  begin
    LTraceId := PcNewTraceId;
    LSpan := TPcSpan.Create(LTraceId, PcNewSpanId, '', '', ShouldSample(LTraceId), AName, AKind,
      nil);
  end;
  LSpan.FDetached := True;
  Result := LSpan;
end;

class function TPcTracing.StartChildSpan(const AParent: IPcSpan; const AName: string;
  AKind: TPcSpanKind): IPcSpan;
begin
  if AParent = nil then
    Result := StartSpan(AName, AKind)
  else
    Result := StartSpanWith(AParent.TraceId, PcNewSpanId, AParent.SpanId, AParent.TraceState,
      AParent.Sampled, AName, AKind);
end;

class function TPcTracing.Current: IPcSpan;
begin
  if GCurrent = nil then
    Result := nil
  else
    Result := TPcSpan(GCurrent);
end;

class procedure TPcTracing.FlushNow;
begin
  GStateLock.Acquire;
  try
    if GProcessor <> nil then
      GProcessor.Flush;
  finally
    GStateLock.Release;
  end;
end;

class function TPcTracing.DroppedCount: Int64;
begin
  GStateLock.Acquire;
  try
    if GProcessor = nil then
      Result := 0
    else
    begin
      GProcessor.FLock.Acquire;
      try
        Result := GProcessor.FDropped;
      finally
        GProcessor.FLock.Release;
      end;
    end;
  finally
    GStateLock.Release;
  end;
end;

class function TPcTracing.PendingCount: Integer;
begin
  GStateLock.Acquire;
  try
    if GProcessor = nil then
      Result := 0
    else
      Result := GProcessor.PendingCount;
  finally
    GStateLock.Release;
  end;
end;

initialization
  {$IFDEF FPC}
  GInvariant := DefaultFormatSettings;
  {$ELSE}
  GInvariant := TFormatSettings.Create;
  {$ENDIF}
  GInvariant.DecimalSeparator := '.';
  GStateLock := TCriticalSection.Create;
  GOptions := TPcTracingOptions.Default('', '');

finalization
  if GProcessor <> nil then
  begin
    GProcessor.FExporter := nil;
    FreeAndNil(GProcessor);
  end;
  GEnabled := 0;
  GStateLock.Free;

end.
