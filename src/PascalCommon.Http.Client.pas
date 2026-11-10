unit PascalCommon.Http.Client;

{$I pascalcommon.inc}

{ PcNewHttpTransport: an HTTP/1.1 client over PascalCommon.Transport, the
  same on Delphi and FPC, with verified TLS and a small pool of kept-alive
  connections. The contract is PascalCommon.Http's.

  Why a client of its own (docs/http-design.md, H2 and H3; the numbers are
  the probe's, .ci/probe-http/findings.md):
  - FPC 3.2.2's fphttpclient verifies nothing over https by default, and its
    VerifyPeerCert never checks the host name (finding 4). Its openssl unit
    can't load OpenSSL 3 on Windows, nor on Debian 12 without libssl-dev
    (findings 1 and 2). It turns a connection closed before the status line
    into status 0 (finding 5).
  - Delphi's THTTPClient trusts the Windows store only. Its certificate
    event fires after WinHTTP refused and gets no chain, and accepting there
    turns off the host name check too (findings 8-11), so "trust this
    private CA" can't be done with it.
  PcTlsConnect verifies the chain and the name on both backends (SChannel,
  OpenSSL 3 or 1.1). So one client, on both compilers, with one set of TLS
  options and one behavior.

  What it does, and nothing more (H2):
  - The request line, Host (with the port when it isn't the scheme's),
    the caller's headers, Content-Length (always for POST, PUT and PATCH;
    for other methods only with a body), then the body.
  - The answer: an HTTP/1.0 or 1.1 status line, the headers (duplicates kept
    in order), 1xx answers skipped (101 is returned), and the body framed by
    chunked (trailers dropped), by Content-Length, or by the server's close.
    HEAD, 204 and 304 have no body. A transfer coding other than chunked
    (gzip...) is refused: it is never asked for, and can't be decoded.
  - No redirects, no compression (no Accept-Encoding is sent), no proxy, no
    HTTP/2, no Expect: 100-continue, no cookies, no authentication scheme:
    headers are the caller's.
  - TimeoutMs (0 = PC_HTTP_DEFAULT_TIMEOUT_MS) is the connect budget, the
    TLS handshake's (unless Tls.HandshakeTimeoutMs says otherwise) and the
    deadline of every wait to read or write. Per wait, not a total.
  - A head over PC_HTTP_MAX_HEAD_BYTES and a body over MaxResponseBytes are
    "not an HTTP answer this client accepts": EPcHttpTransport.

  A request it can't send as given raises EArgumentException before any
  connection: a URL PcParseHttpUrl refuses, a method that isn't a token, a
  header name that isn't one, a value with a control character (CR or LF
  would let a value forge headers), and a header the client owns (Host,
  Content-Length, Transfer-Encoding, Connection). Those are programming
  errors; sending something other than what the caller wrote would hide
  them.

  The pool (H5). Each transport keeps its idle connections per scheme, host
  and port, last in first out, up to MaxIdlePerHost. A connection serves one
  Send at a time; the lock guards only the idle lists, never a socket wait,
  so Send is callable from many threads. A connection goes back only after
  its whole answer was read, and not when the answer said "Connection:
  close", came from HTTP/1.0 without keep-alive, was framed by the close, or
  left bytes after its end. Before reuse, an idle connection older than
  IdleTimeoutMs is closed, and a younger one is checked with
  TPcEndpoint.HasPendingInput, which doesn't wait: input pending on an idle
  connection is the server's close (or a stray byte), and that connection is
  dropped. The design said a 1 ms read; a 1 ms wait measured 15.5 ms on
  Windows, more than a new TLS connection on loopback.

  If a REUSED connection fails before the first byte of the answer (the
  server closed it in between), the request is sent once more on a new
  connection, for the idempotent methods only (PcHttpMethodIsIdempotent).
  POST and PATCH are never sent twice: that failure is EPcHttpTransport and
  the caller decides. A timeout is never replayed.

  The default idle timeout, 4 s, is below the 5 s keep-alive of actix-web
  (Meilisearch), read in its documentation, not measured.

  TLS for https comes from TPcHttpOptions.Tls. Zeroed, the server is checked
  against the system store and by host name. On Linux the store is
  /etc/ssl/certs: a slim image without the ca-certificates package refuses
  every public site (finding 6). Tls.SkipServerVerification turns the checks
  off; it is insecure, for a lab only: the traffic is then encrypted to
  whoever answers. }

interface

uses
  SysUtils,
  PascalCommon.Transport,
  PascalCommon.Http;

const
  /// TPcHttpOptions.MaxResponseBytes = 0: 64 MiB.
  PC_HTTP_MAX_RESPONSE_DEFAULT = 64 * 1024 * 1024;
  /// The status line and headers of one answer (1xx ones included), and
  /// the trailers of a chunked body apart.
  PC_HTTP_MAX_HEAD_BYTES = 64 * 1024;
  /// TPcHttpOptions.MaxIdlePerHost = 0.
  PC_HTTP_MAX_IDLE_PER_HOST_DEFAULT = 4;
  /// TPcHttpOptions.IdleTimeoutMs = 0.
  PC_HTTP_IDLE_TIMEOUT_DEFAULT = 4000;

type
  { A transport's options. A zeroed record (Default) is the recommended one:
    https verified against the system store and by host name, keep-alive on,
    the limits above. }
  TPcHttpOptions = record
    /// TLS for https URLs. CaFile: trust this CA (PEM) instead of the system
    /// store. CertFile/KeyFile/CertPassword: a client certificate (mTLS).
    /// Backend: tbDefault, tbSChannel, tbOpenSsl. HandshakeTimeoutMs 0: the
    /// request's TimeoutMs. SkipServerVerification: INSECURE, for a lab.
    Tls: TPcTlsOptions;
    /// The largest body accepted. 0 = PC_HTTP_MAX_RESPONSE_DEFAULT.
    MaxResponseBytes: Int64;
    /// True: one connection per exchange, closed after it ("Connection:
    /// close" is sent).
    NoKeepAlive: Boolean;
    /// Idle connections kept per scheme, host and port.
    /// 0 = PC_HTTP_MAX_IDLE_PER_HOST_DEFAULT.
    MaxIdlePerHost: Integer;
    /// An idle connection older than this is closed, not reused.
    /// 0 = PC_HTTP_IDLE_TIMEOUT_DEFAULT.
    IdleTimeoutMs: Cardinal;
  end;

/// A transport with zeroed options.
function PcNewHttpTransport: IPcHttpTransport; overload;
/// A transport with these options. Build one per service it talks to and
/// keep it: its pool lives as long as it does, and freeing it closes the
/// idle connections.
function PcNewHttpTransport(const AOptions: TPcHttpOptions): IPcHttpTransport; overload;

implementation

uses
  SyncObjs,
  PascalCommon.Threading,
  PascalCommon.Utf8,
  PascalCommon.Transport.Tcp,
  PascalCommon.Transport.Tls;

const
  CBufSize = 16 * 1024;
  // A body up to this size goes in the same write as the head.
  CJoinBodyMax = 16 * 1024;

type
  { An answer that isn't HTTP, or one this client doesn't accept. }
  ENotHttp = class(Exception);

  { A growing byte buffer (the body). }
  TByteBuilder = record
    Data: TBytes;
    Len: Integer;
    procedure Append(const ABuf; ACount: Integer);
    function ToBytes: TBytes;
  end;

  { One connection and its read buffer. Used by one Send at a time. }
  TPcHttpConn = class
  public
    Endpoint: TPcEndpoint;
    Key: string;
    IdleSince: UInt64;
    Reused: Boolean;
    /// Bytes read during the current exchange.
    Received: Int64;
    Buf: TBytes;
    BufPos: Integer;
    BufLen: Integer;
    constructor Create(AEndpoint: TPcEndpoint; const AKey: string);
    destructor Destroy; override;
    procedure Fill;
    /// A line without its CRLF (a bare LF ends one too). ABudget counts what
    /// the head may still take.
    function ReadLine(var ABudget: Integer): TBytes;
    procedure ReadInto(var ABody: TByteBuilder; ACount: Integer);
  end;

  TRawAnswer = record
    Status: Integer;
    Headers: TPcHttpHeaders;
    Body: TBytes;
    KeepAlive: Boolean;
  end;

  TPcHttpClient = class(TInterfacedObject, IPcHttpTransport)
  private
    FOptions: TPcHttpOptions;
    FMaxBody: Integer;
    FMaxIdle: Integer;
    FIdleTimeoutMs: Cardinal;
    FLock: TCriticalSection;
    FIdle: array of TPcHttpConn; // oldest first
    function TakeIdle(const AKey: string): TPcHttpConn;
    procedure Release(AConn: TPcHttpConn);
    function Connect(const AUrl: TPcHttpUrl; const AKey: string;
      ATimeoutMs: Cardinal): TPcHttpConn;
    procedure Exchange(AConn: TPcHttpConn; const AMethod: string;
      const AHead, ABody: TBytes; ATimeoutMs: Cardinal; out AAnswer: TRawAnswer);
    procedure ReadBody(AConn: TPcHttpConn; AChunked: Boolean;
      ALength: Int64; out ABody: TBytes);
  public
    constructor Create(const AOptions: TPcHttpOptions);
    destructor Destroy; override;
    function Send(const ARequest: TPcHttpRequest): TPcHttpResponse;
  end;

{ helpers }

function IsTokenChar(C: Char): Boolean;
begin
  case C of
    'A'..'Z', 'a'..'z', '0'..'9',
    '!', '#', '$', '%', '&', '''', '*', '+', '-', '.', '^', '_', '`', '|', '~':
      Result := True;
  else
    Result := False;
  end;
end;

function IsToken(const S: string): Boolean;
var
  I: Integer;
begin
  Result := S <> '';
  for I := 1 to Length(S) do
    if not IsTokenChar(S[I]) then
      Exit(False);
end;

function IsDigits(const S: string): Boolean;
var
  I: Integer;
begin
  Result := (S <> '') and (Length(S) <= 18);
  for I := 1 to Length(S) do
    if (S[I] < '0') or (S[I] > '9') then
      Exit(False);
end;

function IsOwnedHeader(const AName: string): Boolean;
begin
  Result := SameText(AName, 'Host') or SameText(AName, 'Content-Length') or
    SameText(AName, 'Transfer-Encoding') or SameText(AName, 'Connection');
end;

procedure CheckRequest(const ARequest: TPcHttpRequest);
var
  I, J: Integer;
  LValue: string;
begin
  if not IsToken(ARequest.Method) then
    raise EArgumentException.CreateFmt('"%s" is not an HTTP method', [ARequest.Method]);
  for I := 0 to High(ARequest.Headers) do
  begin
    if not IsToken(ARequest.Headers[I].Name) then
      raise EArgumentException.CreateFmt('"%s" is not a header name',
        [ARequest.Headers[I].Name]);
    if IsOwnedHeader(ARequest.Headers[I].Name) then
      raise EArgumentException.CreateFmt(
        'the transport sets the %s header itself; don''t add it to the request',
        [ARequest.Headers[I].Name]);
    LValue := ARequest.Headers[I].Value;
    for J := 1 to Length(LValue) do
      if ((LValue[J] < ' ') and (LValue[J] <> #9)) or (LValue[J] = #127) then
        raise EArgumentException.CreateFmt(
          'the value of the %s header has a control character (code %d)',
          [ARequest.Headers[I].Name, Ord(LValue[J])]);
  end;
end;

function BuildHead(const ARequest: TPcHttpRequest; const AUrl: TPcHttpUrl;
  ABodyLength: Integer; ACloseAfter: Boolean): TBytes;
var
  LText: string;
  I: Integer;
begin
  LText := ARequest.Method + ' ' + AUrl.Target + ' HTTP/1.1'#13#10 +
    'Host: ' + AUrl.HostHeader + #13#10;
  for I := 0 to High(ARequest.Headers) do
    LText := LText + ARequest.Headers[I].Name + ': ' + ARequest.Headers[I].Value + #13#10;
  if (ABodyLength > 0) or PcHttpMethodHasBody(ARequest.Method) then
    LText := LText + 'Content-Length: ' + IntToStr(ABodyLength) + #13#10;
  if ACloseAfter then
    LText := LText + 'Connection: close'#13#10;
  Result := PcStringToUtf8Bytes(LText + #13#10);
end;

// The comma-separated items of a header value, trimmed.
function SplitList(const AValue: string): TArray<string>;
var
  I, LStart, N: Integer;
begin
  Result := nil;
  LStart := 1;
  for I := 1 to Length(AValue) + 1 do
    if (I > Length(AValue)) or (AValue[I] = ',') then
    begin
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := Trim(Copy(AValue, LStart, I - LStart));
      LStart := I + 1;
    end;
end;

// Bytes of a head as text: ASCII as is; otherwise UTF-8 when valid, and
// each non-ASCII byte as '?' when not (a server's Latin-1 header).
function HeadText(const ABytes: TBytes; AStart, ACount: Integer): string;
var
  I: Integer;
  LAscii: Boolean;
  LPart: TBytes;
begin
  LAscii := True;
  for I := AStart to AStart + ACount - 1 do
    if ABytes[I] >= $80 then
    begin
      LAscii := False;
      Break;
    end;
  if not LAscii then
  begin
    LPart := Copy(ABytes, AStart, ACount);
    if PcTryUtf8BytesToString(LPart, Result) then
      Exit;
  end;
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    if ABytes[AStart + I] < $80 then
      Result[I + 1] := Char(ABytes[AStart + I])
    else
      Result[I + 1] := '?';
end;

// A line for an error message: at most 60 characters, controls as '?'.
function Shown(const ALine: TBytes): string;
var
  I, N: Integer;
begin
  N := Length(ALine);
  if N > 60 then
    N := 60;
  SetLength(Result, N);
  for I := 0 to N - 1 do
    if (ALine[I] >= 32) and (ALine[I] < 127) then
      Result[I + 1] := Char(ALine[I])
    else
      Result[I + 1] := '?';
  if Length(ALine) > 60 then
    Result := Result + '...';
end;

function ParseStatusLine(const ALine: TBytes; out AHttp11: Boolean): Integer;
const
  CPrefix: array[0..6] of Byte = (Ord('H'), Ord('T'), Ord('T'), Ord('P'),
    Ord('/'), Ord('1'), Ord('.'));
var
  I: Integer;
begin
  AHttp11 := False;
  Result := 0;
  if Length(ALine) < 12 then
    raise ENotHttp.CreateFmt('status line "%s"', [Shown(ALine)]);
  for I := 0 to High(CPrefix) do
    if ALine[I] <> CPrefix[I] then
      raise ENotHttp.CreateFmt('status line "%s"', [Shown(ALine)]);
  if not (ALine[7] in [Ord('0'), Ord('1')]) or (ALine[8] <> Ord(' ')) then
    raise ENotHttp.CreateFmt('status line "%s"', [Shown(ALine)]);
  AHttp11 := ALine[7] = Ord('1');
  for I := 9 to 11 do
  begin
    if (ALine[I] < Ord('0')) or (ALine[I] > Ord('9')) then
      raise ENotHttp.CreateFmt('status line "%s"', [Shown(ALine)]);
    Result := Result * 10 + ALine[I] - Ord('0');
  end;
  if (Result < 100) or ((Length(ALine) > 12) and (ALine[12] <> Ord(' '))) then
    raise ENotHttp.CreateFmt('status line "%s"', [Shown(ALine)]);
end;

function ParseHeaderLine(const ALine: TBytes): TPcHttpHeader;
var
  LColon, I, LStart, LEnd: Integer;
begin
  if (ALine[0] = Ord(' ')) or (ALine[0] = 9) then
    raise ENotHttp.Create('a folded header line (obs-fold)');
  LColon := -1;
  for I := 0 to High(ALine) do
    if ALine[I] = Ord(':') then
    begin
      LColon := I;
      Break;
    end;
  if LColon <= 0 then
    raise ENotHttp.CreateFmt('header line "%s"', [Shown(ALine)]);
  for I := 0 to LColon - 1 do
    if (ALine[I] >= $80) or not IsTokenChar(Char(ALine[I])) then
      raise ENotHttp.CreateFmt('header line "%s"', [Shown(ALine)]);
  Result.Name := HeadText(ALine, 0, LColon);
  LStart := LColon + 1;
  LEnd := Length(ALine);
  while (LStart < LEnd) and ((ALine[LStart] = Ord(' ')) or (ALine[LStart] = 9)) do
    Inc(LStart);
  while (LEnd > LStart) and ((ALine[LEnd - 1] = Ord(' ')) or (ALine[LEnd - 1] = 9)) do
    Dec(LEnd);
  Result.Value := HeadText(ALine, LStart, LEnd - LStart);
end;

// True when the comma-separated values of every AName header contain
// AToken (any case).
function HeaderHasToken(const AHeaders: TPcHttpHeaders; const AName,
  AToken: string): Boolean;
var
  I, J: Integer;
  LParts: TArray<string>;
begin
  for I := 0 to High(AHeaders) do
    if SameText(AHeaders[I].Name, AName) then
    begin
      LParts := SplitList(AHeaders[I].Value);
      for J := 0 to High(LParts) do
        if SameText(LParts[J], AToken) then
          Exit(True);
    end;
  Result := False;
end;

{ TByteBuilder }

procedure TByteBuilder.Append(const ABuf; ACount: Integer);
var
  LCap: Integer;
begin
  if ACount <= 0 then
    Exit;
  if Len + ACount > Length(Data) then
  begin
    LCap := Length(Data) * 2;
    if LCap < 4096 then
      LCap := 4096;
    if LCap < Len + ACount then
      LCap := Len + ACount;
    SetLength(Data, LCap);
  end;
  Move(ABuf, Data[Len], ACount);
  Inc(Len, ACount);
end;

function TByteBuilder.ToBytes: TBytes;
begin
  Result := Data;
  SetLength(Result, Len);
end;

{ TPcHttpConn }

constructor TPcHttpConn.Create(AEndpoint: TPcEndpoint; const AKey: string);
begin
  inherited Create;
  Endpoint := AEndpoint;
  Key := AKey;
  SetLength(Buf, CBufSize);
end;

destructor TPcHttpConn.Destroy;
begin
  Endpoint.Free;
  inherited;
end;

procedure TPcHttpConn.Fill;
begin
  BufPos := 0;
  BufLen := 0;
  BufLen := Endpoint.Read(Buf[0], Length(Buf));
  Inc(Received, BufLen);
end;

function TPcHttpConn.ReadLine(var ABudget: Integer): TBytes;
var
  LStart, I, N, LLen: Integer;
begin
  Result := nil;
  LLen := 0;
  while True do
  begin
    if BufPos >= BufLen then
      Fill;
    LStart := BufPos;
    I := LStart;
    while (I < BufLen) and (Buf[I] <> 10) do
      Inc(I);
    N := I - LStart;
    if N >= ABudget then
      raise ENotHttp.CreateFmt('a head larger than %d bytes', [PC_HTTP_MAX_HEAD_BYTES]);
    Dec(ABudget, N);
    if N > 0 then
    begin
      SetLength(Result, LLen + N);
      Move(Buf[LStart], Result[LLen], N);
      Inc(LLen, N);
    end;
    BufPos := I;
    if I < BufLen then
    begin
      Inc(BufPos); // the LF
      Dec(ABudget);
      if (LLen > 0) and (Result[LLen - 1] = 13) then
        SetLength(Result, LLen - 1);
      Exit;
    end;
  end;
end;

procedure TPcHttpConn.ReadInto(var ABody: TByteBuilder; ACount: Integer);
var
  N: Integer;
begin
  while ACount > 0 do
  begin
    if BufPos >= BufLen then
      Fill;
    N := BufLen - BufPos;
    if N > ACount then
      N := ACount;
    ABody.Append(Buf[BufPos], N);
    Inc(BufPos, N);
    Dec(ACount, N);
  end;
end;

{ TPcHttpClient }

constructor TPcHttpClient.Create(const AOptions: TPcHttpOptions);
begin
  inherited Create;
  FOptions := AOptions;
  if (FOptions.MaxResponseBytes <= 0) then
    FMaxBody := PC_HTTP_MAX_RESPONSE_DEFAULT
  else if FOptions.MaxResponseBytes > MaxInt - CBufSize then
    FMaxBody := MaxInt - CBufSize // a TBytes holds the body
  else
    FMaxBody := Integer(FOptions.MaxResponseBytes);
  FMaxIdle := FOptions.MaxIdlePerHost;
  if FMaxIdle <= 0 then
    FMaxIdle := PC_HTTP_MAX_IDLE_PER_HOST_DEFAULT;
  FIdleTimeoutMs := FOptions.IdleTimeoutMs;
  if FIdleTimeoutMs = 0 then
    FIdleTimeoutMs := PC_HTTP_IDLE_TIMEOUT_DEFAULT;
  FLock := TCriticalSection.Create;
end;

destructor TPcHttpClient.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FIdle) do
    FIdle[I].Free;
  FIdle := nil;
  FLock.Free;
  inherited;
end;

function TPcHttpClient.TakeIdle(const AKey: string): TPcHttpConn;
var
  I: Integer;
  LPending: Boolean;
begin
  while True do
  begin
    Result := nil;
    FLock.Acquire;
    try
      for I := High(FIdle) downto 0 do
        if FIdle[I].Key = AKey then
        begin
          Result := FIdle[I];
          Delete(FIdle, I, 1);
          Break;
        end;
    finally
      FLock.Release;
    end;
    if Result = nil then
      Exit;
    // PcTickMs is read after the connection left the list, so it is never
    // below IdleSince (set under the lock).
    if PcTickMs - Result.IdleSince < FIdleTimeoutMs then
    begin
      try
        LPending := Result.Endpoint.HasPendingInput;
      except
        LPending := True;
      end;
      if not LPending then
        Exit;
    end;
    // Too old, or the server closed it: drop it without the TLS goodbye.
    Result.Endpoint.CloseAbort;
    Result.Free;
  end;
end;

procedure TPcHttpClient.Release(AConn: TPcHttpConn);
var
  LDrop: array of TPcHttpConn;
  LNow: UInt64;
  I, LSame: Integer;

  procedure DropAt(AIndex: Integer);
  begin
    SetLength(LDrop, Length(LDrop) + 1);
    LDrop[High(LDrop)] := FIdle[AIndex];
    Delete(FIdle, AIndex, 1);
  end;

begin
  LDrop := nil;
  AConn.Reused := True;
  FLock.Acquire;
  try
    // The time is read under the lock: read before it, another thread could
    // put back a connection stamped later, and the unsigned difference below
    // would wrap around and drop that connection as expired (found at
    // --cpus=1: 8 threads opened 9 connections).
    LNow := PcTickMs;
    AConn.IdleSince := LNow;
    // Expired ones of any host go first; then the oldest of this one when
    // its list is full.
    for I := High(FIdle) downto 0 do
      if (LNow > FIdle[I].IdleSince) and (LNow - FIdle[I].IdleSince >= FIdleTimeoutMs) then
        DropAt(I);
    LSame := 0;
    for I := 0 to High(FIdle) do
      if FIdle[I].Key = AConn.Key then
        Inc(LSame);
    I := 0;
    while (LSame >= FMaxIdle) and (I <= High(FIdle)) do
      if FIdle[I].Key = AConn.Key then
      begin
        DropAt(I);
        Dec(LSame);
      end
      else
        Inc(I);
    SetLength(FIdle, Length(FIdle) + 1);
    FIdle[High(FIdle)] := AConn;
  finally
    FLock.Release;
  end;
  // Outside the lock: a TLS close writes to the socket.
  for I := 0 to High(LDrop) do
    LDrop[I].Free;
end;

function TPcHttpClient.Connect(const AUrl: TPcHttpUrl; const AKey: string;
  ATimeoutMs: Cardinal): TPcHttpConn;
var
  LTcp: TPcTcpOptions;
  LTls: TPcTlsOptions;
  LEndpoint: TPcEndpoint;
begin
  LTcp := Default(TPcTcpOptions);
  LTcp.ConnectTimeoutMs := ATimeoutMs;
  if AUrl.IsHttps then
  begin
    LTls := FOptions.Tls;
    if LTls.HandshakeTimeoutMs = 0 then
      LTls.HandshakeTimeoutMs := ATimeoutMs;
    LEndpoint := PcTlsConnect(AUrl.Host, AUrl.Port, LTcp, LTls);
  end
  else
    LEndpoint := PcTcpConnect(AUrl.Host, AUrl.Port, LTcp);
  Result := TPcHttpConn.Create(LEndpoint, AKey);
end;

procedure TPcHttpClient.ReadBody(AConn: TPcHttpConn; AChunked: Boolean;
  ALength: Int64; out ABody: TBytes);
var
  LBody: TByteBuilder;
  LLine: TBytes;
  LBudget, I: Integer;
  LSize: Int64;
  LDigit: Integer;
begin
  LBody.Data := nil;
  LBody.Len := 0;
  if AChunked then
  begin
    LBudget := PC_HTTP_MAX_HEAD_BYTES;
    while True do
    begin
      LLine := AConn.ReadLine(LBudget);
      LSize := 0;
      I := 0;
      while I < Length(LLine) do
      begin
        case LLine[I] of
          Ord('0')..Ord('9'): LDigit := LLine[I] - Ord('0');
          Ord('a')..Ord('f'): LDigit := LLine[I] - Ord('a') + 10;
          Ord('A')..Ord('F'): LDigit := LLine[I] - Ord('A') + 10;
        else
          Break;
        end;
        LSize := LSize * 16 + LDigit;
        if LSize > FMaxBody then
          raise ENotHttp.CreateFmt('a body larger than %d bytes', [FMaxBody]);
        Inc(I);
      end;
      if (I = 0) or ((I < Length(LLine)) and not (LLine[I] in [Ord(';'), Ord(' '), 9])) then
        raise ENotHttp.CreateFmt('chunk size "%s"', [Shown(LLine)]);
      if LSize = 0 then
        Break;
      if LBody.Len + LSize > FMaxBody then
        raise ENotHttp.CreateFmt('a body larger than %d bytes', [FMaxBody]);
      AConn.ReadInto(LBody, Integer(LSize));
      LLine := AConn.ReadLine(LBudget);
      if Length(LLine) <> 0 then
        raise ENotHttp.Create('a chunk longer than its size');
    end;
    // Trailers, dropped, up to the empty line.
    repeat
      LLine := AConn.ReadLine(LBudget);
    until Length(LLine) = 0;
  end
  else if ALength >= 0 then
  begin
    if ALength > FMaxBody then
      raise ENotHttp.CreateFmt('a body larger than %d bytes', [FMaxBody]);
    SetLength(LBody.Data, Integer(ALength));
    AConn.ReadInto(LBody, Integer(ALength));
  end
  else
  begin
    // Up to the server's close.
    while True do
    begin
      if AConn.BufPos < AConn.BufLen then
      begin
        if LBody.Len + (AConn.BufLen - AConn.BufPos) > FMaxBody then
          raise ENotHttp.CreateFmt('a body larger than %d bytes', [FMaxBody]);
        LBody.Append(AConn.Buf[AConn.BufPos], AConn.BufLen - AConn.BufPos);
        AConn.BufPos := AConn.BufLen;
      end;
      try
        AConn.Fill;
      except
        on EPcTransportClosed do
          Break;
      end;
    end;
  end;
  ABody := LBody.ToBytes;
end;

procedure TPcHttpClient.Exchange(AConn: TPcHttpConn; const AMethod: string;
  const AHead, ABody: TBytes; ATimeoutMs: Cardinal; out AAnswer: TRawAnswer);
var
  LJoined, LLine: TBytes;
  LBudget, I, N: Integer;
  LHttp11, LChunked, LToClose, LNoBody: Boolean;
  LLength, LValue: Int64;
  LHeader: TPcHttpHeader;
  LParts: TArray<string>;
  LCoding, LIgnored: string;
begin
  AAnswer.Status := 0;
  AAnswer.Headers := nil;
  AAnswer.Body := nil;
  AAnswer.KeepAlive := False;
  AConn.Received := 0;
  AConn.BufPos := 0;
  AConn.BufLen := 0;
  AConn.Endpoint.SetIoDeadline(ATimeoutMs);
  if (Length(ABody) > 0) and (Length(ABody) <= CJoinBodyMax) then
  begin
    SetLength(LJoined, Length(AHead) + Length(ABody));
    Move(AHead[0], LJoined[0], Length(AHead));
    Move(ABody[0], LJoined[Length(AHead)], Length(ABody));
    AConn.Endpoint.WriteExactly(LJoined[0], Length(LJoined));
  end
  else
  begin
    AConn.Endpoint.WriteExactly(AHead[0], Length(AHead));
    if Length(ABody) > 0 then
      AConn.Endpoint.WriteExactly(ABody[0], Length(ABody));
  end;

  // The status line and headers; 1xx answers (but 101) are skipped.
  LBudget := PC_HTTP_MAX_HEAD_BYTES;
  repeat
    LLine := AConn.ReadLine(LBudget);
    AAnswer.Status := ParseStatusLine(LLine, LHttp11);
    AAnswer.Headers := nil;
    while True do
    begin
      LLine := AConn.ReadLine(LBudget);
      if Length(LLine) = 0 then
        Break;
      LHeader := ParseHeaderLine(LLine);
      N := Length(AAnswer.Headers);
      SetLength(AAnswer.Headers, N + 1);
      AAnswer.Headers[N] := LHeader;
    end;
  until (AAnswer.Status >= 200) or (AAnswer.Status = 101);

  // Framing (RFC 9112, 6.3): chunked; else Content-Length; else the close.
  // Any transfer coding but chunked is refused: this client never asks for
  // one (no TE header) and can't decode it, so the body would be returned
  // still encoded. A Transfer-Encoding with a Content-Length is suspect:
  // the body is read as chunked, and the connection is not reused.
  LChunked := False;
  LToClose := False;
  LLength := -1;
  LNoBody := SameText(AMethod, 'HEAD') or (AAnswer.Status = 204) or
    (AAnswer.Status = 304) or (AAnswer.Status = 101);
  if not LNoBody then
  begin
    LCoding := '';
    for I := 0 to High(AAnswer.Headers) do
      if SameText(AAnswer.Headers[I].Name, 'Transfer-Encoding') then
      begin
        LParts := SplitList(AAnswer.Headers[I].Value);
        for N := 0 to High(LParts) do
          if LParts[N] <> '' then
          begin
            if (LCoding <> '') or not SameText(LParts[N], 'chunked') then
              raise ENotHttp.CreateFmt('Transfer-Encoding "%s"', [AAnswer.Headers[I].Value]);
            LCoding := LParts[N];
          end;
      end;
    if LCoding <> '' then
    begin
      LChunked := True;
      LToClose := PcHttpFindHeader(AAnswer.Headers, 'Content-Length', LIgnored);
    end
    else
    begin
      for I := 0 to High(AAnswer.Headers) do
        if SameText(AAnswer.Headers[I].Name, 'Content-Length') then
        begin
          LParts := SplitList(AAnswer.Headers[I].Value);
          for N := 0 to High(LParts) do
          begin
            if not IsDigits(LParts[N]) or not TryStrToInt64(LParts[N], LValue) then
              raise ENotHttp.CreateFmt('Content-Length "%s"', [AAnswer.Headers[I].Value]);
            if (LLength >= 0) and (LValue <> LLength) then
              raise ENotHttp.Create('two different Content-Length values');
            LLength := LValue;
          end;
        end;
      LToClose := LLength < 0;
    end;
    ReadBody(AConn, LChunked, LLength, AAnswer.Body);
  end;

  if LHttp11 then
    AAnswer.KeepAlive := not HeaderHasToken(AAnswer.Headers, 'Connection', 'close')
  else
    AAnswer.KeepAlive := HeaderHasToken(AAnswer.Headers, 'Connection', 'keep-alive');
  AAnswer.KeepAlive := AAnswer.KeepAlive and not LToClose and
    (AAnswer.Status <> 101) and (AConn.BufPos = AConn.BufLen) and
    not FOptions.NoKeepAlive;
end;

function TPcHttpClient.Send(const ARequest: TPcHttpRequest): TPcHttpResponse;
var
  LUrl: TPcHttpUrl;
  LKey, LWhat, LError: string;
  LHead, LBody: TBytes;
  LTimeout: Cardinal;
  LConn: TPcHttpConn;
  LAnswer: TRawAnswer;
  LAttempt: Integer;
  LReplay: Boolean;
begin
  CheckRequest(ARequest);
  LUrl := PcParseHttpUrl(ARequest.Url);
  LWhat := ARequest.Method + ' ' + PcUrlWithoutQuery(ARequest.Url);
  if ARequest.TimeoutMs > 0 then
    LTimeout := Cardinal(ARequest.TimeoutMs)
  else
    LTimeout := PC_HTTP_DEFAULT_TIMEOUT_MS;
  LBody := PcStringToUtf8Bytes(ARequest.Body);
  LHead := BuildHead(ARequest, LUrl, Length(LBody), FOptions.NoKeepAlive);
  LKey := LUrl.Scheme + '://' + LUrl.HostHeader + ':' + IntToStr(LUrl.Port);
  LAttempt := 0;
  while True do
  begin
    LConn := nil;
    if (LAttempt = 0) and not FOptions.NoKeepAlive then
      LConn := TakeIdle(LKey);
    if LConn = nil then
      try
        LConn := Connect(LUrl, LKey, LTimeout);
      except
        on E: Exception do
          raise EPcHttpTransport.CreateFmt('%s: no answer (%s: %s)',
            [LWhat, E.ClassName, E.Message]);
      end;
    LReplay := False;
    LError := '';
    try
      Exchange(LConn, ARequest.Method, LHead, LBody, LTimeout, LAnswer);
    except
      on E: Exception do
      begin
        LReplay := LConn.Reused and (LConn.Received = 0) and (LAttempt = 0) and
          (E is EPcTransport) and not (E is EPcTransportTimeout) and
          PcHttpMethodIsIdempotent(ARequest.Method);
        if E is ENotHttp then
          LError := Format('%s: not an HTTP answer (%s)', [LWhat, E.Message])
        else if LConn.Received = 0 then
          LError := Format('%s: no answer (%s: %s)', [LWhat, E.ClassName, E.Message])
        else
          LError := Format('%s: the answer was cut short (%s: %s)',
            [LWhat, E.ClassName, E.Message]);
        LConn.Endpoint.CloseAbort;
        FreeAndNil(LConn);
      end;
    end;
    if LConn <> nil then
      Break;
    if not LReplay then
      raise EPcHttpTransport.Create(LError);
    Inc(LAttempt);
  end;
  if LAnswer.KeepAlive then
    Release(LConn)
  else
    LConn.Free;
  Result.Status := LAnswer.Status;
  Result.Headers := LAnswer.Headers;
  Result.Body := PcUtf8BytesToString(LAnswer.Body, 'the answer to ' + LWhat);
end;

function PcNewHttpTransport: IPcHttpTransport;
begin
  Result := TPcHttpClient.Create(Default(TPcHttpOptions));
end;

function PcNewHttpTransport(const AOptions: TPcHttpOptions): IPcHttpTransport;
begin
  Result := TPcHttpClient.Create(AOptions);
end;

end.
