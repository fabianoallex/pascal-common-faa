unit PascalCommon.Http.Fake;

{$I pascalcommon.inc}

{ An IPcHttpTransport for tests: it answers from a queue the test fills
  (Answer, Fail) and keeps every request it was given (Requests), so a test
  checks what the client sent and how it read each answer, with no server.

  Thread-safe: a client's calls from several threads at once can be
  checked. A Send with the queue empty raises EPcFakeHttpTransport, not
  EPcHttpTransport: a request the test didn't expect is the test's failure,
  not a lost connection for the client to retry.

  Hold it through an IPcHttpTransport variable as well as the class one (it
  is reference counted), and give the IPcHttpTransport to the client.

  It came from pascal-api-infra-faa's PascalApi.HttpTransport.Fake (1.31.0,
  docs/http-design.md, H8), renamed; it is in src/, not in the tests, so an
  application's tests can use it too. }

interface

uses
  SysUtils,
  SyncObjs,
  PascalCommon.Http;

type
  EPcFakeHttpTransport = class(Exception);

  TPcFakeHttpTransport = class(TInterfacedObject, IPcHttpTransport)
  private type
    TQueued = record
      Fails: Boolean;
      Response: TPcHttpResponse;
      Message: string;
    end;
  private
    FLock: TCriticalSection;
    FQueue: TArray<TQueued>;
    FRequests: TArray<TPcHttpRequest>;
    procedure Push(const AQueued: TQueued);
  public
    constructor Create;
    destructor Destroy; override;
    /// Queues an answer; AHeaders as 'Name: value' lines.
    procedure Answer(AStatus: Integer; const ABody: string;
      const AHeaders: array of string); overload;
    procedure Answer(AStatus: Integer; const ABody: string = ''); overload;
    /// Queues a lost connection: that Send raises EPcHttpTransport(AMessage).
    procedure Fail(const AMessage: string = 'connection refused');
    /// Answers queued and not yet given.
    function Pending: Integer;
    function RequestCount: Integer;
    /// A copy of the requests, in the order received.
    function Requests: TArray<TPcHttpRequest>;
    /// The I-th request (from 0); raises EPcFakeHttpTransport past the last.
    function Request(AIndex: Integer): TPcHttpRequest;
    function Send(const ARequest: TPcHttpRequest): TPcHttpResponse;
  end;

implementation

constructor TPcFakeHttpTransport.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TPcFakeHttpTransport.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TPcFakeHttpTransport.Push(const AQueued: TQueued);
var
  N: Integer;
begin
  FLock.Acquire;
  try
    N := Length(FQueue);
    SetLength(FQueue, N + 1);
    FQueue[N] := AQueued;
  finally
    FLock.Release;
  end;
end;

procedure TPcFakeHttpTransport.Answer(AStatus: Integer; const ABody: string;
  const AHeaders: array of string);
var
  LQueued: TQueued;
  I, N: Integer;
begin
  LQueued.Fails := False;
  LQueued.Message := '';
  LQueued.Response.Status := AStatus;
  LQueued.Response.Body := ABody;
  LQueued.Response.Headers := nil;
  for I := 0 to High(AHeaders) do
  begin
    N := Length(LQueued.Response.Headers);
    SetLength(LQueued.Response.Headers, N + 1);
    if not PcHttpSplitHeaderLine(AHeaders[I], LQueued.Response.Headers[N]) then
      raise EPcFakeHttpTransport.CreateFmt('not a header line: "%s"', [AHeaders[I]]);
  end;
  Push(LQueued);
end;

procedure TPcFakeHttpTransport.Answer(AStatus: Integer; const ABody: string);
begin
  Answer(AStatus, ABody, []);
end;

procedure TPcFakeHttpTransport.Fail(const AMessage: string);
var
  LQueued: TQueued;
begin
  LQueued.Fails := True;
  LQueued.Message := AMessage;
  LQueued.Response.Status := 0;
  LQueued.Response.Body := '';
  LQueued.Response.Headers := nil;
  Push(LQueued);
end;

function TPcFakeHttpTransport.Pending: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FQueue);
  finally
    FLock.Release;
  end;
end;

function TPcFakeHttpTransport.RequestCount: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FRequests);
  finally
    FLock.Release;
  end;
end;

function TPcFakeHttpTransport.Requests: TArray<TPcHttpRequest>;
begin
  FLock.Acquire;
  try
    Result := Copy(FRequests, 0, Length(FRequests));
  finally
    FLock.Release;
  end;
end;

function TPcFakeHttpTransport.Request(AIndex: Integer): TPcHttpRequest;
begin
  FLock.Acquire;
  try
    if (AIndex < 0) or (AIndex >= Length(FRequests)) then
      raise EPcFakeHttpTransport.CreateFmt('no request %d (%d received)',
        [AIndex, Length(FRequests)]);
    Result := FRequests[AIndex];
  finally
    FLock.Release;
  end;
end;

function TPcFakeHttpTransport.Send(const ARequest: TPcHttpRequest): TPcHttpResponse;
var
  LQueued: TQueued;
  N: Integer;
begin
  FLock.Acquire;
  try
    N := Length(FRequests);
    SetLength(FRequests, N + 1);
    FRequests[N] := ARequest;
    if Length(FQueue) = 0 then
      raise EPcFakeHttpTransport.CreateFmt('%s %s: no answer queued', [ARequest.Method, ARequest.Url]);
    LQueued := FQueue[0];
    Delete(FQueue, 0, 1);
  finally
    FLock.Release;
  end;
  if LQueued.Fails then
    raise EPcHttpTransport.Create(LQueued.Message);
  Result := LQueued.Response;
end;

end.
