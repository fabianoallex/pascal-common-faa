unit PascalCommon.Transport.Tls;

{$I pascalcommon.inc}

{ TLS over any TPcEndpoint: PcTlsConnect, PcTlsListen and PcTlsWrap, with the
  backend (SChannel or OpenSSL) chosen at run time by TPcTlsOptions.Backend.

  It came from pascal-pipes-faa's Pipes.Transport.Tls, translated. This unit
  implements no TLS: it picks the backend and adapts contracts.

    TPcEndpoint --TPcEndpointStream--> TStream --backend--> TPcTlsSession
                                                                 |
    TPcTlsEndpoint <---------------------------------------------+

  The TCP endpoint becomes a TStream, the backend encrypts over it, and
  TPcTlsEndpoint brings the result back to the TPcEndpoint contract.

  - OWNERSHIP: the endpoint owns the inner endpoint and the session; the
    session owns the TPcEndpointStream. Destruction: the session first (it
    tries the close_notify), then the inner endpoint.
  - ABORT: CloseAbort goes to the inner endpoint. Every wait of a backend
    ends in the inner endpoint's Read/WriteExactly, so aborting there
    unblocks the whole stack with EPcTransportClosed.
  - DEADLINE: SetIoDeadline, SetReadDeadline and SetWriteDeadline go to the
    inner endpoint (pipes' adapter didn't forward the first, so it silently
    did nothing on TLS). The handshake has its own
    (HandshakeTimeoutMs), armed only while negotiating: an established session
    may idle for hours.
  - Read never returns 0: the peer's close_notify is EPcTransportClosed.
  - WHERE EACH SIDE NEGOTIATES: the client in PcTlsWrap/PcTlsConnect, on the
    caller's thread. The server NOT in Accept: the listener returns the
    endpoint not negotiated yet, and the connection's own thread calls
    Handshake, so one client stalling mid-handshake doesn't hold the accept
    loop. Read or WriteExactly before it raises EPcTls.

  Backend choice (T3): tbDefault is SChannel on Windows and OpenSSL
  elsewhere; tbSChannel off Windows raises EPcTls. Both backends are compiled
  on Windows; OpenSSL costs nothing until used (it is loaded then). }

interface

uses
  SysUtils,
  Classes,
  PascalCommon.Transport;

type
  TPcTlsEndpoint = class(TPcEndpoint)
  private
    FInner: TPcEndpoint;      // owned
    FSession: TPcTlsSession;  // owned
    FHandshakeTimeoutMs: Cardinal; // resolved: 0 = none
    FServer: Boolean;
    FNegotiated: Boolean;
    procedure Negotiate;
  public
    /// Takes ownership of AInner and ASession (also when this raises). The
    /// client side negotiates here; the server side in Handshake.
    constructor Create(AInner: TPcEndpoint; ASession: TPcTlsSession;
      AServer: Boolean; const AOptions: TPcTlsOptions);
    destructor Destroy; override;
    procedure Handshake; override;
    function Read(var ABuffer; ACount: Integer): Integer; override;
    procedure WriteExactly(const ABuffer; ACount: Integer); override;
    procedure CloseAbort; override;
    procedure SetIoDeadline(ATimeoutMs: Cardinal); override;
    /// Both go to the inner endpoint. They count the raw socket's waits: a
    /// TLS read that must first flush bytes of its own (OpenSSL may) waits
    /// on that write under the write deadline.
    procedure SetReadDeadline(ATimeoutMs: Cardinal); override;
    procedure SetWriteDeadline(ATimeoutMs: Cardinal); override;
    /// Not a TLS matter: always the inner endpoint's, even before Handshake.
    function TryPeerAddress(out AAddress: string): Boolean; override;
    /// Server side under mTLS, after Handshake. A client gets False: who the
    /// server is was decided by the chain and hostname check during the
    /// handshake; a name returned here would invite deciding trust later.
    function TryPeerIdentity(out AIdentity: TPcPeerIdentity): Boolean; override;
    property Inner: TPcEndpoint read FInner;
  end;

  TPcTlsListener = class(TPcListener)
  private
    FInner: TPcListener;                    // owned
    FCredentials: TPcTlsServerCredentials;  // owned
    FOptions: TPcTlsOptions;
  public
    /// Takes ownership of AInner and ACredentials.
    constructor Create(AInner: TPcListener;
      ACredentials: TPcTlsServerCredentials; const AOptions: TPcTlsOptions);
    destructor Destroy; override;
    /// A TPcTlsEndpoint NOT negotiated yet (see Handshake), or nil after Close.
    function Accept: TPcEndpoint; override;
    procedure Close; override;
    function Port: Word; override;
  end;

/// TLS over an established endpoint, as the CLIENT: runs the handshake on
/// this thread. AHost is the name sent in SNI and checked against the
/// certificate. Takes ownership of AInner, also when this raises (the
/// handshake's failure frees it). pipes' Android TCP endpoint uses this.
function PcTlsWrap(AInner: TPcEndpoint; const AHost: string;
  const ATls: TPcTlsOptions): TPcEndpoint;

/// PcTcpConnect + PcTlsWrap, with AHost as the name to check.
function PcTlsConnect(const AHost: string; APort: Word;
  const AOptions: TPcTcpOptions; const ATls: TPcTlsOptions): TPcEndpoint;

/// PcTcpListen with TLS server credentials, loaded now (a wrong file or
/// password raises EPcTls here). Each accepted endpoint negotiates in
/// Handshake, on its own thread.
function PcTlsListen(const ABindAddress: string; APort: Word;
  const AOptions: TPcTcpOptions; const ATls: TPcTlsOptions): TPcListener;

/// A TLS server over any listener (pipes' Android one, which PcTcpListen
/// can't build there): loads the credentials now, as PcTlsListen does, and
/// wraps each accepted endpoint. Takes ownership of AInner, also when this
/// raises.
function PcTlsListenOver(AInner: TPcListener;
  const ATls: TPcTlsOptions): TPcListener;

/// tbDefault resolved for this platform; tbSChannel off Windows raises EPcTls.
function PcTlsResolveBackend(ABackend: TPcTlsBackend): TPcTlsBackend;

/// 'SChannel' or 'OpenSSL'.
function PcTlsBackendName(ABackend: TPcTlsBackend): string;

/// The backend in use, for logs: SChannel's fixed description, or the
/// OpenSSL version and library actually loaded ('' for OpenSSL before its
/// first use).
function PcTlsBackendInfo(ABackend: TPcTlsBackend): string;

implementation

uses
  PascalCommon.Transport.Tcp,
  {$IFDEF PASCALCOMMON_WINDOWS}
  PascalCommon.Transport.SChannel,
  {$ENDIF}
  PascalCommon.Transport.OpenSSL;

function ResolveHandshakeTimeout(const AOptions: TPcTlsOptions): Cardinal;
begin
  if AOptions.HandshakeTimeoutMs = PC_TLS_HANDSHAKE_NO_TIMEOUT then
    Result := 0
  else if AOptions.HandshakeTimeoutMs = 0 then
    Result := PC_TLS_HANDSHAKE_TIMEOUT_DEFAULT
  else
    Result := AOptions.HandshakeTimeoutMs;
end;

function PcTlsResolveBackend(ABackend: TPcTlsBackend): TPcTlsBackend;
begin
  Result := ABackend;
  if Result = tbDefault then
  begin
    {$IFDEF PASCALCOMMON_WINDOWS}
    Result := tbSChannel;
    {$ELSE}
    Result := tbOpenSsl;
    {$ENDIF}
  end;
  {$IFNDEF PASCALCOMMON_WINDOWS}
  if Result = tbSChannel then
    raise EPcTls.Create('the SChannel TLS backend exists only on Windows');
  {$ENDIF}
end;

function PcTlsBackendName(ABackend: TPcTlsBackend): string;
begin
  case PcTlsResolveBackend(ABackend) of
    tbSChannel: Result := 'SChannel';
  else
    Result := 'OpenSSL';
  end;
end;

function PcTlsBackendInfo(ABackend: TPcTlsBackend): string;
begin
  {$IFDEF PASCALCOMMON_WINDOWS}
  if PcTlsResolveBackend(ABackend) = tbSChannel then
    Exit(PC_SCHANNEL_BACKEND_INFO);
  {$ELSE}
  PcTlsResolveBackend(ABackend); // raises for tbSChannel
  {$ENDIF}
  Result := PcOpenSslInfo;
end;

function NewClientSession(ARaw: TStream; const AHost: string;
  const ATls: TPcTlsOptions): TPcTlsSession;
var
  LBackend: TPcTlsBackend;
begin
  try
    LBackend := PcTlsResolveBackend(ATls.Backend);
  except
    ARaw.Free;
    raise;
  end;
  {$IFDEF PASCALCOMMON_WINDOWS}
  if LBackend = tbSChannel then
    Exit(PcSChannelClientSession(ARaw, AHost, ATls));
  {$ENDIF}
  Result := PcOpenSslClientSession(ARaw, AHost, ATls);
end;

function NewServerCredentials(const ATls: TPcTlsOptions): TPcTlsServerCredentials;
begin
  {$IFDEF PASCALCOMMON_WINDOWS}
  if PcTlsResolveBackend(ATls.Backend) = tbSChannel then
    Exit(PcSChannelServerCredentials(ATls));
  {$ELSE}
  PcTlsResolveBackend(ATls.Backend);
  {$ENDIF}
  Result := PcOpenSslServerCredentials(ATls);
end;

{ TPcTlsEndpoint }

constructor TPcTlsEndpoint.Create(AInner: TPcEndpoint;
  ASession: TPcTlsSession; AServer: Boolean; const AOptions: TPcTlsOptions);
begin
  inherited Create;
  FInner := AInner;     // ownership now: the destructor frees both if the
  FSession := ASession; // client handshake below raises
  FServer := AServer;
  FHandshakeTimeoutMs := ResolveHandshakeTimeout(AOptions);
  if not AServer then
    Negotiate;
end;

destructor TPcTlsEndpoint.Destroy;
begin
  FSession.Free; // tries the close_notify, frees the TPcEndpointStream
  FInner.Free;
  inherited;
end;

procedure TPcTlsEndpoint.Negotiate;
begin
  if FNegotiated then
    Exit;
  // The deadline counts only while negotiating: the peer hasn't proved
  // anything yet and already holds a thread. try/finally so a failed
  // handshake doesn't leave a deadline on an endpoint still alive.
  FInner.SetIoDeadline(FHandshakeTimeoutMs);
  try
    FSession.Negotiate;
  finally
    FInner.SetIoDeadline(0);
  end;
  FNegotiated := True;
end;

procedure TPcTlsEndpoint.Handshake;
begin
  Negotiate; // the client did it already; idempotent
end;

function TPcTlsEndpoint.Read(var ABuffer; ACount: Integer): Integer;
begin
  if not FNegotiated then
    raise EPcTls.Create('Read before Handshake on a TLS server endpoint');
  Result := FSession.Read(ABuffer, ACount);
  if Result <= 0 then
    raise EPcTransportClosed.Create('TLS connection closed by the peer');
end;

procedure TPcTlsEndpoint.WriteExactly(const ABuffer; ACount: Integer);
begin
  if not FNegotiated then
    raise EPcTls.Create('WriteExactly before Handshake on a TLS server endpoint');
  if ACount <= 0 then
    Exit;
  // The backends write everything or raise.
  if FSession.Write(ABuffer, ACount) <> ACount then
    raise EPcTransportClosed.Create('incomplete TLS write');
end;

procedure TPcTlsEndpoint.CloseAbort;
begin
  if Assigned(FInner) then
    FInner.CloseAbort; // idempotent below
end;

procedure TPcTlsEndpoint.SetIoDeadline(ATimeoutMs: Cardinal);
begin
  FInner.SetIoDeadline(ATimeoutMs);
end;

procedure TPcTlsEndpoint.SetReadDeadline(ATimeoutMs: Cardinal);
begin
  FInner.SetReadDeadline(ATimeoutMs);
end;

procedure TPcTlsEndpoint.SetWriteDeadline(ATimeoutMs: Cardinal);
begin
  FInner.SetWriteDeadline(ATimeoutMs);
end;

function TPcTlsEndpoint.TryPeerAddress(out AAddress: string): Boolean;
begin
  Result := FInner.TryPeerAddress(AAddress);
end;

function TPcTlsEndpoint.TryPeerIdentity(out AIdentity: TPcPeerIdentity): Boolean;
begin
  if FServer and FNegotiated then
    Result := FSession.TryPeerIdentity(AIdentity)
  else
    Result := inherited TryPeerIdentity(AIdentity);
end;

{ TPcTlsListener }

constructor TPcTlsListener.Create(AInner: TPcListener;
  ACredentials: TPcTlsServerCredentials; const AOptions: TPcTlsOptions);
begin
  inherited Create;
  FInner := AInner;
  FCredentials := ACredentials;
  FOptions := AOptions;
end;

destructor TPcTlsListener.Destroy;
begin
  FInner.Free;
  FCredentials.Free; // each session holds its own reference
  inherited;
end;

function TPcTlsListener.Accept: TPcEndpoint;
var
  LTcp: TPcEndpoint;
  LSession: TPcTlsSession;
begin
  LTcp := FInner.Accept;
  if LTcp = nil then
    Exit(nil); // closed
  // No handshake here on purpose: this is the accepting thread.
  try
    LSession := FCredentials.NewSession(TPcEndpointStream.Create(LTcp));
  except
    LTcp.Free; // the session freed the stream, not the endpoint
    raise;
  end;
  Result := TPcTlsEndpoint.Create(LTcp, LSession, True, FOptions);
end;

procedure TPcTlsListener.Close;
begin
  FInner.Close;
end;

function TPcTlsListener.Port: Word;
begin
  Result := FInner.Port;
end;

{ factories }

function PcTlsWrap(AInner: TPcEndpoint; const AHost: string;
  const ATls: TPcTlsOptions): TPcEndpoint;
var
  LSession: TPcTlsSession;
begin
  try
    LSession := NewClientSession(TPcEndpointStream.Create(AInner), AHost, ATls);
  except
    AInner.Free; // the session (or its factory) freed the stream only
    raise;
  end;
  // Owns both from here; a failed handshake frees them in the destructor.
  Result := TPcTlsEndpoint.Create(AInner, LSession, False, ATls);
end;

function PcTlsConnect(const AHost: string; APort: Word;
  const AOptions: TPcTcpOptions; const ATls: TPcTlsOptions): TPcEndpoint;
begin
  PcTlsResolveBackend(ATls.Backend); // fail before connecting
  Result := PcTlsWrap(PcTcpConnect(AHost, APort, AOptions), AHost, ATls);
end;

function PcTlsListenOver(AInner: TPcListener;
  const ATls: TPcTlsOptions): TPcListener;
var
  LCredentials: TPcTlsServerCredentials;
begin
  try
    LCredentials := NewServerCredentials(ATls);
  except
    AInner.Free;
    raise;
  end;
  Result := TPcTlsListener.Create(AInner, LCredentials, ATls);
end;

function PcTlsListen(const ABindAddress: string; APort: Word;
  const AOptions: TPcTcpOptions; const ATls: TPcTlsOptions): TPcListener;
var
  LCredentials: TPcTlsServerCredentials;
  LTcp: TPcListener;
begin
  LCredentials := NewServerCredentials(ATls);
  try
    LTcp := PcTcpListen(ABindAddress, APort, AOptions);
  except
    LCredentials.Free;
    raise;
  end;
  Result := TPcTlsListener.Create(LTcp, LCredentials, ATls);
end;

end.
