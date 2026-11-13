unit PascalCommon.Http.Telemetry;

{$I pascalcommon.inc}

(* An IPcHttpTransport that records the exchanges of another one: a client
  span per Send, with its traceparent sent, and the histogram
  http.client.request.duration on PcMetrics.

    Search := PcNewTracedHttpTransport(PcNewHttpTransport(Options));

  It exists because the client span around a Send was written twice in the
  family (pascal-api-infra-faa's MCP executor, pascal-agenda-faa's HTTP
  client) and pascal-search-faa would have been the third
  (docs/http-telemetry-design.md, 1.33.0). Names and attributes are
  OpenTelemetry's HTTP client semantic conventions.

  Decisions:
  - A decorator, not part of PcNewHttpTransport (HT1): PascalCommon.Http and
    PascalCommon.Http.Client stay free of Tracing and Metrics, and it records
    any transport, the fake included.
  - The span is started and finished inside Send, on the calling thread, as
    a child of the thread's current span (HT2). It is named after the method
    ('HTTP' for an unknown one); url.full has no query and no fragment (a
    query can carry an API key or what a user typed). A status of 400 or
    more, or an exception, is an error; the exception is re-raised as it
    was.
  - With no current span, no span and no traceparent (HT3), unless
    RootWhenNoParent. NEVER wrap the transport of a span exporter (an OTLP
    exporter) with RootWhenNoParent: the exporter sends on its own thread,
    with no current span, so every batch would make a span to export, and
    so on without end (docs/gotchas.md, 20). With the zeroed options such a
    transport only records its metric.
  - A request that already carries traceparent belongs to its caller, who
    manages the context by hand: no span, the headers unchanged (HT4). The
    metric is still recorded.
  - The metric (HT5) is labelled by method, server address and port, scheme,
    status and error.type, '' when absent (an empty Prometheus label is no
    label); never the path. Its duration includes connecting, the client's
    one replay of H5 and reading the body.
  - A URL PcParseHttpUrl refuses is passed on unrecorded: the client refuses
    it with the same EArgumentException, and another transport may accept
    it.
  - http.request.resend_count comes from TPcHttpRequest.ResendCount (HT6):
    only the caller knows that it is retrying. *)

interface

uses
  SysUtils,
  PascalCommon.Http;

type
  TPcHttpTelemetryOptions = record
    /// True: no span and no traceparent; the metric is still recorded.
    NoSpans: Boolean;
    /// True: no metric.
    NoMetrics: Boolean;
    /// True: with no current span, each exchange is the root of a new
    /// trace. False (zeroed): no span and no traceparent then. Never on the
    /// transport of a span exporter (see the unit header).
    RootWhenNoParent: Boolean;
  end;

const
  /// The histogram every traced transport records into, on PcMetrics.
  PC_HTTP_CLIENT_DURATION_METRIC = 'http.client.request.duration';

/// AInner, recorded with zeroed options: spans under the current one and
/// the metric.
function PcNewTracedHttpTransport(const AInner: IPcHttpTransport): IPcHttpTransport; overload;
function PcNewTracedHttpTransport(const AInner: IPcHttpTransport;
  const AOptions: TPcHttpTelemetryOptions): IPcHttpTransport; overload;

/// The method as a span name and metric label: AMethod when it is one of
/// RFC 9110's or PATCH, exactly (methods are case-sensitive); '_OTHER'
/// otherwise, so a label can't take unbounded values.
function PcHttpMetricMethod(const AMethod: string): string;

implementation

uses
  PascalCommon.Threading,
  PascalCommon.Metrics,
  PascalCommon.Tracing;

type
  TPcTracedHttpTransport = class(TInterfacedObject, IPcHttpTransport)
  private
    FInner: IPcHttpTransport;
    FOptions: TPcHttpTelemetryOptions;
    /// nil with NoMetrics. Owned by PcMetrics.
    FDuration: TPcHistogram;
    function StartSpan(const ARequest: TPcHttpRequest): IPcSpan;
  public
    constructor Create(const AInner: IPcHttpTransport; const AOptions: TPcHttpTelemetryOptions);
    function Send(const ARequest: TPcHttpRequest): TPcHttpResponse;
  end;

function PcHttpMetricMethod(const AMethod: string): string;
const
  KNOWN: array[0..8] of string = ('GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'CONNECT',
    'OPTIONS', 'TRACE', 'PATCH');
var
  I: Integer;
begin
  for I := 0 to High(KNOWN) do
    if AMethod = KNOWN[I] then
      Exit(AMethod);
  Result := '_OTHER';
end;

function PcNewTracedHttpTransport(const AInner: IPcHttpTransport): IPcHttpTransport;
begin
  Result := PcNewTracedHttpTransport(AInner, Default(TPcHttpTelemetryOptions));
end;

function PcNewTracedHttpTransport(const AInner: IPcHttpTransport;
  const AOptions: TPcHttpTelemetryOptions): IPcHttpTransport;
begin
  if AInner = nil then
    raise EArgumentException.Create('PcNewTracedHttpTransport: no transport to record');
  Result := TPcTracedHttpTransport.Create(AInner, AOptions);
end;

{ TPcTracedHttpTransport }

constructor TPcTracedHttpTransport.Create(const AInner: IPcHttpTransport;
  const AOptions: TPcHttpTelemetryOptions);
begin
  inherited Create;
  FInner := AInner;
  FOptions := AOptions;
  FDuration := nil;
  if not FOptions.NoMetrics then
    FDuration := PcMetrics.Histogram(PC_HTTP_CLIENT_DURATION_METRIC, 's',
      'Duration of HTTP client requests.',
      ['http.request.method', 'server.address', 'server.port', 'url.scheme',
       'http.response.status_code', 'error.type'], PC_DURATION_BUCKETS);
end;

// The span of this exchange, or nil (HT2-HT4).
function TPcTracedHttpTransport.StartSpan(const ARequest: TPcHttpRequest): IPcSpan;
var
  LParent: IPcSpan;
  LName, LIgnored: string;
begin
  Result := nil;
  if FOptions.NoSpans or PcHttpFindHeader(ARequest.Headers, 'traceparent', LIgnored) then
    Exit;
  LParent := TPcTracing.Current;
  if (LParent = nil) and not FOptions.RootWhenNoParent then
    Exit;
  LParent := nil;
  LName := PcHttpMetricMethod(ARequest.Method);
  if LName = '_OTHER' then
    LName := 'HTTP';
  Result := TPcTracing.StartSpan(LName, skClient);
end;

function TPcTracedHttpTransport.Send(const ARequest: TPcHttpRequest): TPcHttpResponse;
var
  LUrl: TPcHttpUrl;
  LValidUrl: Boolean;
  LSpan: IPcSpan;
  LSend: TPcHttpRequest;
  LMethod, LStatus, LError, LIgnored: string;
  LStart: Int64;
begin
  LValidUrl := True;
  try
    LUrl := PcParseHttpUrl(ARequest.Url);
  except
    on EArgumentException do
      LValidUrl := False;
  end;
  if not LValidUrl then
  begin
    Result := FInner.Send(ARequest);
    Exit;
  end;

  LMethod := PcHttpMetricMethod(ARequest.Method);
  LSend := ARequest;
  LSpan := StartSpan(ARequest);
  try
    if LSpan <> nil then
    begin
      LSpan.SetAttribute('http.request.method', LMethod);
      LSpan.SetAttribute('server.address', LUrl.Host);
      LSpan.SetIntAttribute('server.port', LUrl.Port);
      LSpan.SetAttribute('url.scheme', LUrl.Scheme);
      LSpan.SetAttribute('url.full', PcUrlWithoutQuery(ARequest.Url));
      if ARequest.ResendCount > 0 then
        LSpan.SetIntAttribute('http.request.resend_count', ARequest.ResendCount);
      // A copy of the headers: the caller's request is const, and the
      // dynamic array is shared with it until changed.
      LSend.Headers := Copy(ARequest.Headers, 0, Length(ARequest.Headers));
      LSend.AddHeader('traceparent', LSpan.TraceParent);
      if (LSpan.TraceState <> '') and
         not PcHttpFindHeader(ARequest.Headers, 'tracestate', LIgnored) then
        LSend.AddHeader('tracestate', LSpan.TraceState);
    end;

    LStatus := '';
    LError := '';
    LStart := PcTickUs;
    try
      try
        Result := FInner.Send(LSend);
      except
        on E: Exception do
        begin
          LError := E.ClassName;
          if LSpan <> nil then
          begin
            LSpan.SetAttribute('error.type', LError);
            LSpan.SetStatus(ssError, E.Message);
          end;
          raise;
        end;
      end;
      LStatus := IntToStr(Result.Status);
      if LSpan <> nil then
        LSpan.SetIntAttribute('http.response.status_code', Result.Status);
      if Result.Status >= 400 then
      begin
        LError := LStatus;
        if LSpan <> nil then
        begin
          LSpan.SetAttribute('error.type', LError);
          LSpan.SetStatus(ssError);
        end;
      end;
    finally
      if FDuration <> nil then
        FDuration.Labels([LMethod, LUrl.Host, IntToStr(LUrl.Port), LUrl.Scheme, LStatus,
          LError]).Observe((PcTickUs - LStart) / 1000000);
    end;
  finally
    // Finished here, on the thread that started it (it is its current span).
    if LSpan <> nil then
      LSpan.Finish;
  end;
end;

end.
