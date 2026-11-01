unit PascalCommon.Transport.Tcp;

{$I pascalcommon.inc}

{ Plain TCP: PcTcpConnect and PcTcpListen, over AF_INET and AF_INET6, with
  the contract of PascalCommon.Transport.

  It came from pascal-pipes-faa's Pipes.Transport.Tcp (docs/transport-
  design.md, T1), translated, with three changes:

  - Connect makes ONE attempt per address the name resolves to, in
    getaddrinfo's order, all inside ConnectTimeoutMs (T5). pipes retried
    until its deadline because a local server may still be starting; that is
    a library's policy and stays there.
  - A listener reports the port it is bound to (TPcListener.Port), so a test
    or a broker can listen on port 0.
  - Windows: a reader and a writer on the same endpoint no longer share one
    wake-up. WSAEventSelect allows one event per socket, and
    WSAEnumNetworkEvents resets it. In pipes, if the FD_WRITE arrived after a
    writer's send failed with WSAEWOULDBLOCK but before the writer entered its
    wait, a reader already waiting could take it and reset the event; the
    writer then slept until the next network event, forever when the peer
    waits for the rest of the write before answering. Here whoever enumerates
    passes the other direction's events on through a per-direction
    auto-reset event (FReadWake/FWriteWake). The window is a few
    microseconds: the request-reply and full-duplex tests pass with or
    without the hand-off (measured on Windows, 3 runs each), so the fix rests
    on the reasoning, not on a reproduction.

  The platforms differ a lot, on purpose:

  - Windows (Delphi and FPC): WinSock2. WSAEventSelect makes the socket
    NON-BLOCKING; every operation tries recv/send first and waits only on
    WSAEWOULDBLOCK, so the edge-triggered FD_READ/FD_WRITE (re-signalled only
    after a call that would block) are never relied on otherwise. Every wait
    is WSAWaitForMultipleEvents on [socket event, stop event, own wake].
    FStopEvent is manual-reset and never reset: after CloseAbort every wait
    wakes at once. No SO_REUSEADDR: on Windows it lets ANOTHER process take a
    port in use.
  - FPC on Unix: the socket is set up here (getaddrinfo, bind/listen or a
    non-blocking connect) and handed to PascalCommon.Transport.Posix, which
    waits with fpPoll and a self-pipe. SO_REUSEADDR is set there: it only
    keeps TIME_WAIT from blocking a rebind.

  getaddrinfo, bind, connect and getpeername are declared here, not taken
  from each compiler's socket unit: Delphi's and FPC's units disagree on
  their signatures (FPC types the address as TSockAddrIn, too small for
  sockaddr_in6), and addrinfo's layout differs between Windows and glibc
  (ai_addr and ai_canonname swap places; ai_addrlen is size_t on Windows
  and a 32-bit socklen_t on glibc).

  WSAStartup runs in this unit's initialization, never lazily (this
  library's rule; a lazy one is a race). It is a reference count and cheap.

  Security: TCP has no access control of its own. A listener on 0.0.0.0
  accepts anyone who reaches the port; authenticating is the protocol's job
  (or mTLS's). }

interface

uses
  SysUtils,
  PascalCommon.Threading,
  PascalCommon.Transport
  {$IFDEF PASCALCOMMON_WINDOWS}
  , Windows, WinSock2
  {$ELSE}
  , UnixType, BaseUnix, Sockets, PascalCommon.Transport.Posix
  {$ENDIF};

{$IFDEF PASCALCOMMON_WINDOWS}
const
  /// The IPv6 family on Windows (Linux uses 10).
  PC_AF_INET6_WINDOWS = 23;

type
  TPcTcpWinEndpoint = class(TPcEndpoint)
  private
    FSocket: TSocket;
    FSockEvent: WSAEVENT;   // FD_READ/FD_WRITE/FD_CLOSE of the socket
    FStopEvent: WSAEVENT;   // manual-reset, set by CloseAbort
    FReadWake: THandle;     // auto-reset: a writer saw FD_READ/FD_CLOSE
    FWriteWake: THandle;    // auto-reset: a reader saw FD_WRITE/FD_CLOSE
    FClosed: Integer;       // atomic: 1 after CloseAbort
    FIoTimeoutMs: Cardinal; // 0 = no deadline (see SetIoDeadline)
    procedure WaitReadyOrStop(AForWrite: Boolean; const AOp: string);
  public
    /// Takes ownership of ASocket (connected).
    constructor Create(ASocket: TSocket; const AOptions: TPcTcpOptions);
    destructor Destroy; override;
    function Read(var ABuffer; ACount: Integer): Integer; override;
    procedure WriteExactly(const ABuffer; ACount: Integer); override;
    procedure CloseAbort; override;
    procedure SetIoDeadline(ATimeoutMs: Cardinal); override;
    function TryPeerAddress(out AAddress: string): Boolean; override;
  end;

  TPcTcpWinListener = class(TPcListener)
  private
    FSocket: TSocket;
    FAcceptEvent: WSAEVENT;
    FStopEvent: WSAEVENT;
    FClosed: Integer;
    FOptions: TPcTcpOptions; // applied to every accepted socket
  public
    /// Takes ownership of ASocket (already listening).
    constructor Create(ASocket: TSocket; const AOptions: TPcTcpOptions);
    destructor Destroy; override;
    function Accept: TPcEndpoint; override;
    procedure Close; override;
    function Port: Word; override;
  end;
{$ELSE}
type
  { The POSIX listener, plus the TCP options it applies to each accepted
    socket (Linux passes TCP_NODELAY on from the listening socket, but the
    standard doesn't promise it; setting it again is cheap). }
  TPcTcpPosixListener = class(TPcPosixSocketListener)
  private
    FOptions: TPcTcpOptions;
    procedure ApplyOptions(AFd: cint);
  public
    constructor Create(AFd: cint; const AOptions: TPcTcpOptions);
  end;
{$ENDIF}

/// Connects to AHost:APort. AHost is a name or an IPv4/IPv6 literal (with or
/// without brackets). Every address the name resolves to is tried once, in
/// getaddrinfo's order, all inside AOptions.ConnectTimeoutMs.
/// EPcTransportTimeout when the budget runs out; EPcTransport when every
/// address refused or failed otherwise (or the name doesn't resolve).
function PcTcpConnect(const AHost: string; APort: Word;
  const AOptions: TPcTcpOptions): TPcEndpoint;

/// Listens on ABindAddress:APort. ABindAddress '' or '*' = every IPv4
/// interface ('0.0.0.0'); '::' for every IPv6 one. APort 0 = a port the OS
/// chooses (read it back with TPcListener.Port). The listener is ready on
/// return: a client may connect before the first Accept.
function PcTcpListen(const ABindAddress: string; APort: Word;
  const AOptions: TPcTcpOptions): TPcListener;

implementation

{ --- getaddrinfo ------------------------------------------------------------ }

type
  PPcAddrInfo = ^TPcAddrInfo;
  TPcAddrInfo = record
    ai_flags: Integer;
    ai_family: Integer;
    ai_socktype: Integer;
    ai_protocol: Integer;
    {$IFDEF PASCALCOMMON_WINDOWS}
    ai_addrlen: NativeUInt;   // size_t
    ai_canonname: PAnsiChar;
    ai_addr: Pointer;         // sockaddr*
    {$ELSE}
    ai_addrlen: LongWord;     // socklen_t; alignment covers the padding
    ai_addr: Pointer;         // sockaddr*
    ai_canonname: PAnsiChar;
    {$ENDIF}
    ai_next: PPcAddrInfo;
  end;

const
  PC_AI_PASSIVE = 1;
  PC_AF_UNSPEC = 0;
  PC_SOCK_STREAM = 1;
  PC_IPPROTO_TCP = 6;
  PC_TCP_NODELAY = 1;
  PC_LISTEN_BACKLOG = 128;

{$IFDEF PASCALCOMMON_WINDOWS}
function pc_getaddrinfo(ANode, AService: PAnsiChar; AHints: PPcAddrInfo;
  out ARes: PPcAddrInfo): Integer; stdcall;
  external 'ws2_32.dll' name 'getaddrinfo';
procedure pc_freeaddrinfo(AInfo: PPcAddrInfo); stdcall;
  external 'ws2_32.dll' name 'freeaddrinfo';
{$ELSE}
function pc_getaddrinfo(ANode, AService: PAnsiChar; AHints: PPcAddrInfo;
  out ARes: PPcAddrInfo): Integer; cdecl;
  external 'c' name 'getaddrinfo';
procedure pc_freeaddrinfo(AInfo: PPcAddrInfo); cdecl;
  external 'c' name 'freeaddrinfo';
{$ENDIF}

function StripBrackets(const AHost: string): string;
begin
  Result := AHost;
  if (Length(Result) >= 2) and (Result[1] = '[')
    and (Result[Length(Result)] = ']') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

// Resolves AHost:APort into a list of candidates. APassive = a listener
// (AI_PASSIVE). The caller frees it with pc_freeaddrinfo.
function ResolveAddress(const AHost: string; APort: Word;
  APassive: Boolean): PPcAddrInfo;
var
  LHints: TPcAddrInfo;
  LRc: Integer;
  LHostA, LPortA: AnsiString;
begin
  Result := nil;
  FillChar(LHints, SizeOf(LHints), 0);
  LHints.ai_family := PC_AF_UNSPEC;      // IPv4 or IPv6, whatever exists
  LHints.ai_socktype := PC_SOCK_STREAM;
  LHints.ai_protocol := PC_IPPROTO_TCP;
  if APassive then
    LHints.ai_flags := PC_AI_PASSIVE;
  LHostA := AnsiString(StripBrackets(AHost));
  LPortA := AnsiString(IntToStr(APort));
  LRc := pc_getaddrinfo(PAnsiChar(LHostA), PAnsiChar(LPortA), @LHints, Result);
  if (LRc <> 0) or (Result = nil) then
  begin
    if Result <> nil then
      pc_freeaddrinfo(Result);
    raise EPcTransport.CreateFmt('could not resolve "%s" (getaddrinfo=%d)',
      [PcFormatHostPort(AHost, APort), LRc]);
  end;
end;

function ConnectTimeout(const AOptions: TPcTcpOptions): Cardinal;
begin
  Result := AOptions.ConnectTimeoutMs;
  if Result = 0 then
    Result := PC_TCP_CONNECT_TIMEOUT_DEFAULT;
end;

function BindHost(const ABindAddress: string): string;
begin
  Result := ABindAddress;
  if (Result = '') or (Result = '*') then
    Result := '0.0.0.0';
end;

{$IFDEF PASCALCOMMON_WINDOWS}

{ ============================ Windows (WinSock2) ============================ }

const
  PC_SD_BOTH = 2;
  PC_FD_READ = $01;
  PC_FD_WRITE = $02;
  PC_FD_ACCEPT = $08;
  PC_FD_CONNECT = $10;
  PC_FD_CONNECT_BIT = 4; // index in TPcNetworkEvents.iErrorCode
  PC_FD_CLOSE = $20;
  PC_SOL_SOCKET = $FFFF;
  PC_SO_KEEPALIVE = $0008;
  // _WSAIOW(IOC_VENDOR, 4), mstcpip.h
  PC_SIO_KEEPALIVE_VALS = LongWord($98000004);
  PC_WSA_INFINITE = Cardinal($FFFFFFFF);
  PC_WSA_WAIT_FAILED = Cardinal($FFFFFFFF);
  PC_WSA_WAIT_EVENT_0 = 0;
  PC_WSA_WAIT_TIMEOUT = Cardinal(258); // = WAIT_TIMEOUT
  // (WSAEVENT)NULL; FPC 3.2.2's WinSock2 doesn't declare WSA_INVALID_EVENT.
  PC_WSA_INVALID_EVENT = 0;

function pc_bind(ASocket: TSocket; AAddr: Pointer;
  ANameLen: Integer): Integer; stdcall; external 'ws2_32.dll' name 'bind';
function pc_connect(ASocket: TSocket; AAddr: Pointer;
  ANameLen: Integer): Integer; stdcall; external 'ws2_32.dll' name 'connect';
function pc_getpeername(ASocket: TSocket; AAddr: Pointer;
  var ANameLen: Integer): Integer; stdcall;
  external 'ws2_32.dll' name 'getpeername';
function pc_getsockname(ASocket: TSocket; AAddr: Pointer;
  var ANameLen: Integer): Integer; stdcall;
  external 'ws2_32.dll' name 'getsockname';

type
  { WSANETWORKEVENTS (FD_MAX_EVENTS = 10). Declared here because FPC takes
    the parameter as a pointer and Delphi as a var, so no single call
    compiles on both. }
  TPcNetworkEvents = record
    lNetworkEvents: LongInt;
    iErrorCode: array[0..9] of Integer;
  end;

  { tcp_keepalive (mstcpip.h), SIO_KEEPALIVE_VALS's argument. }
  TPcTcpKeepalive = record
    onoff: LongWord;
    keepalivetime: LongWord;     // idle ms before the first probe
    keepaliveinterval: LongWord; // ms between probes
  end;

function pc_WSAEnumNetworkEvents(ASocket: TSocket; AEvent: THandle;
  AEvents: Pointer): Integer; stdcall;
  external 'ws2_32.dll' name 'WSAEnumNetworkEvents';

function pc_WSAIoctl(ASocket: TSocket; ACode: LongWord;
  AInBuf: Pointer; AInSize: LongWord; AOutBuf: Pointer; AOutSize: LongWord;
  ABytesReturned: PLongWord; AOverlapped: Pointer;
  ACompletion: Pointer): Integer; stdcall;
  external 'ws2_32.dll' name 'WSAIoctl';

var
  GWinsockError: Integer = -1; // WSAStartup's result (initialization)

procedure EnsureWinsock;
begin
  if GWinsockError <> 0 then
    raise EPcTransport.CreateFmt('WSAStartup failed (WSA %d)', [GWinsockError]);
end;

procedure RaiseWsaError(const AOp: string; AErr: Integer);
begin
  case AErr of
    WSAECONNRESET, WSAECONNABORTED, WSAESHUTDOWN, WSAENETRESET, WSAENOTCONN:
      raise EPcTransportClosed.CreateFmt('%s: connection closed (WSA %d)',
        [AOp, AErr]);
    WSAETIMEDOUT:
      raise EPcTransportTimeout.CreateFmt('%s: timed out (WSA %d)', [AOp, AErr]);
  else
    raise EPcTransport.CreateFmt('%s failed (WSA %d: %s)',
      [AOp, AErr, SysErrorMessage(AErr)]);
  end;
end;

function NewWsaEvent: WSAEVENT;
begin
  Result := WSACreateEvent; // manual-reset, not signalled
  if Result = PC_WSA_INVALID_EVENT then
    raise EPcTransport.CreateFmt('WSACreateEvent failed (WSA %d)',
      [WSAGetLastError]);
end;

function NewAutoEvent: THandle;
begin
  Result := CreateEvent(nil, False, False, nil);
  if Result = 0 then
    raise EPcTransport.CreateFmt('CreateEvent failed (%d)', [GetLastError]);
end;

procedure ApplyNoDelay(ASocket: TSocket; const AOptions: TPcTcpOptions);
var
  LOn: Integer;
begin
  if AOptions.Nagle then
    Exit;
  LOn := 1;
  // Best effort: losing it costs latency, not the connection.
  setsockopt(ASocket, PC_IPPROTO_TCP, PC_TCP_NODELAY, @LOn, SizeOf(LOn));
end;

// Keep-alive with per-socket times through SIO_KEEPALIVE_VALS (Windows 2000
// on), not setsockopt(TCP_KEEPIDLE), which only came with Windows 10 1709.
// The probe count isn't settable there (see PC_TCP_KEEPALIVE_PROBE_COUNT).
procedure ApplyKeepAlive(ASocket: TSocket; ASeconds: Cardinal);
var
  LVals: TPcTcpKeepalive;
  LOn: Integer;
  LReturned: LongWord;
begin
  if ASeconds = 0 then
    Exit;
  LOn := 1;
  setsockopt(ASocket, PC_SOL_SOCKET, PC_SO_KEEPALIVE, @LOn, SizeOf(LOn));
  LVals.onoff := 1;
  LVals.keepalivetime := ASeconds * 1000;
  LVals.keepaliveinterval := PC_TCP_KEEPALIVE_INTERVAL_SECONDS * 1000;
  LReturned := 0;
  // Best effort, like TCP_NODELAY.
  pc_WSAIoctl(ASocket, PC_SIO_KEEPALIVE_VALS, @LVals, SizeOf(LVals),
    nil, 0, @LReturned, nil, nil);
end;

{ TPcTcpWinEndpoint }

constructor TPcTcpWinEndpoint.Create(ASocket: TSocket;
  const AOptions: TPcTcpOptions);
begin
  inherited Create;
  FSocket := ASocket;
  FSockEvent := NewWsaEvent;
  FStopEvent := NewWsaEvent;
  FReadWake := NewAutoEvent;
  FWriteWake := NewAutoEvent;
  // Side effect, documented: the socket becomes NON-BLOCKING. It also
  // replaces the association an accepted socket inherits from the listener.
  if WSAEventSelect(FSocket, FSockEvent,
       PC_FD_READ or PC_FD_WRITE or PC_FD_CLOSE) <> 0 then
    raise EPcTransport.CreateFmt('WSAEventSelect failed (WSA %d)',
      [WSAGetLastError]);
  ApplyNoDelay(FSocket, AOptions);
  ApplyKeepAlive(FSocket, AOptions.KeepAliveSeconds);
end;

destructor TPcTcpWinEndpoint.Destroy;
begin
  CloseAbort; // idempotent
  if FSocket <> INVALID_SOCKET then
    closesocket(FSocket);
  if FSockEvent <> PC_WSA_INVALID_EVENT then
    WSACloseEvent(FSockEvent);
  if FStopEvent <> PC_WSA_INVALID_EVENT then
    WSACloseEvent(FStopEvent);
  if FReadWake <> 0 then
    CloseHandle(FReadWake);
  if FWriteWake <> 0 then
    CloseHandle(FWriteWake);
  inherited;
end;

procedure TPcTcpWinEndpoint.CloseAbort;
begin
  if PcAtomicSet(FClosed, 1) = 1 then
    Exit; // already aborted
  if FStopEvent <> PC_WSA_INVALID_EVENT then
    WSASetEvent(FStopEvent);         // wakes current and future waits
  if FSocket <> INVALID_SOCKET then
    shutdown(FSocket, PC_SD_BOTH);   // disarms recv/send left in the kernel
end;

procedure TPcTcpWinEndpoint.SetIoDeadline(ATimeoutMs: Cardinal);
begin
  FIoTimeoutMs := ATimeoutMs;
end;

function TPcTcpWinEndpoint.TryPeerAddress(out AAddress: string): Boolean;
var
  LStorage: TPcRawSockAddrStorage;
  LLen: Integer;
begin
  AAddress := '';
  Result := False;
  if PcAtomicGet(FClosed) <> 0 then
    Exit;
  FillChar(LStorage, SizeOf(LStorage), 0);
  LLen := SizeOf(LStorage);
  if pc_getpeername(FSocket, @LStorage, LLen) <> 0 then
    Exit; // best effort: the log goes on without an address
  Result := PcFormatSockAddr(LStorage, PC_AF_INET6_WINDOWS, AAddress);
end;

procedure TPcTcpWinEndpoint.WaitReadyOrStop(AForWrite: Boolean;
  const AOp: string);
var
  LEvents: array[0..2] of WSAEVENT;
  LNet: TPcNetworkEvents;
  LRc: DWORD;
  LWait: DWORD;
begin
  if PcAtomicGet(FClosed) <> 0 then
    raise EPcTransportClosed.Create(AOp + ' on a closed endpoint');
  LEvents[0] := FSockEvent;
  LEvents[1] := FStopEvent;
  if AForWrite then
    LEvents[2] := FWriteWake
  else
    LEvents[2] := FReadWake;
  if FIoTimeoutMs = 0 then
    LWait := PC_WSA_INFINITE
  else
    LWait := FIoTimeoutMs;
  LRc := WSAWaitForMultipleEvents(3, @LEvents[0], False, LWait, False);
  if LRc = PC_WSA_WAIT_FAILED then
    RaiseWsaError(AOp + ' (wait)', WSAGetLastError);
  // Stop may be signalled together with the socket: check it explicitly
  // rather than depend on which index the wait returned.
  if (LRc = PC_WSA_WAIT_EVENT_0 + 1) or (PcAtomicGet(FClosed) <> 0) then
    raise EPcTransportClosed.Create(AOp + ' aborted (CloseAbort)');
  if LRc = PC_WSA_WAIT_TIMEOUT then
    raise EPcTransportTimeout.CreateFmt(
      '%s: the peer did not respond within %u ms', [AOp, FIoTimeoutMs]);
  // Resets FSockEvent and takes the pending events. Whatever belongs to the
  // other direction is handed on through its wake event, or a thread already
  // waiting for it would sleep through it (see the unit's header).
  FillChar(LNet, SizeOf(LNet), 0);
  pc_WSAEnumNetworkEvents(FSocket, FSockEvent, @LNet);
  if AForWrite then
  begin
    if (LNet.lNetworkEvents and (PC_FD_READ or PC_FD_CLOSE)) <> 0 then
      SetEvent(FReadWake);
  end
  else
  begin
    if (LNet.lNetworkEvents and (PC_FD_WRITE or PC_FD_CLOSE)) <> 0 then
      SetEvent(FWriteWake);
  end;
  // A concrete error (FD_CLOSE with an error code) is left for the next
  // recv/send to report: there may still be data queued after FD_CLOSE.
end;

function TPcTcpWinEndpoint.Read(var ABuffer; ACount: Integer): Integer;
var
  LGot, LErr: Integer;
begin
  while True do
  begin
    if PcAtomicGet(FClosed) <> 0 then
      raise EPcTransportClosed.Create('read on a closed endpoint');
    LGot := recv(FSocket, ABuffer, ACount, 0);
    if LGot > 0 then
      Exit(LGot);
    if LGot = 0 then
      raise EPcTransportClosed.Create('connection closed by the peer');
    LErr := WSAGetLastError;
    if LErr = WSAEWOULDBLOCK then
      WaitReadyOrStop(False, 'read')
    else
      RaiseWsaError('read', LErr);
  end;
end;

procedure TPcTcpWinEndpoint.WriteExactly(const ABuffer; ACount: Integer);
var
  P: PByte;
  LSent, LErr: Integer;
begin
  P := @ABuffer;
  while ACount > 0 do
  begin
    if PcAtomicGet(FClosed) <> 0 then
      raise EPcTransportClosed.Create('write on a closed endpoint');
    LSent := send(FSocket, P^, ACount, 0);
    if LSent > 0 then
    begin
      Inc(P, LSent);
      Dec(ACount, LSent);
      Continue;
    end;
    LErr := WSAGetLastError;
    if LErr = WSAEWOULDBLOCK then
      WaitReadyOrStop(True, 'write') // send buffer full: wait for room
    else
      RaiseWsaError('write', LErr);
  end;
end;

{ TPcTcpWinListener }

constructor TPcTcpWinListener.Create(ASocket: TSocket;
  const AOptions: TPcTcpOptions);
begin
  inherited Create;
  FSocket := ASocket;
  FOptions := AOptions;
  FAcceptEvent := NewWsaEvent;
  FStopEvent := NewWsaEvent;
  if WSAEventSelect(FSocket, FAcceptEvent, PC_FD_ACCEPT) <> 0 then
    raise EPcTransport.CreateFmt('WSAEventSelect(accept) failed (WSA %d)',
      [WSAGetLastError]);
end;

destructor TPcTcpWinListener.Destroy;
begin
  Close; // idempotent
  // The accepting thread was joined already (the contract).
  if FSocket <> INVALID_SOCKET then
    closesocket(FSocket);
  if FAcceptEvent <> PC_WSA_INVALID_EVENT then
    WSACloseEvent(FAcceptEvent);
  if FStopEvent <> PC_WSA_INVALID_EVENT then
    WSACloseEvent(FStopEvent);
  inherited;
end;

procedure TPcTcpWinListener.Close;
begin
  if PcAtomicSet(FClosed, 1) = 1 then
    Exit;
  if FStopEvent <> PC_WSA_INVALID_EVENT then
    WSASetEvent(FStopEvent); // unblocks a pending Accept (returns nil)
end;

function TPcTcpWinListener.Port: Word;
var
  LStorage: TPcRawSockAddrStorage;
  LLen: Integer;
begin
  Result := 0;
  FillChar(LStorage, SizeOf(LStorage), 0);
  LLen := SizeOf(LStorage);
  if pc_getsockname(FSocket, @LStorage, LLen) <> 0 then
    RaiseWsaError('getsockname', WSAGetLastError);
  if LStorage.Family = PC_AF_INET then
    Result := Swap(LStorage.V4.sin_port)
  else if LStorage.Family = PC_AF_INET6_WINDOWS then
    Result := Swap(LStorage.V6.sin6_port);
end;

function TPcTcpWinListener.Accept: TPcEndpoint;
var
  LEvents: array[0..1] of WSAEVENT;
  LNet: TPcNetworkEvents;
  LRc: DWORD;
  LConn: TSocket;
  LErr: Integer;
begin
  Result := nil;
  // A loop: a client that connects and drops before accept goes back to
  // waiting, without returning a dead endpoint.
  while True do
  begin
    if PcAtomicGet(FClosed) <> 0 then
      Exit;
    LConn := WinSock2.accept(FSocket, nil, nil);
    // If the constructor raises, its destructor closes LConn.
    if LConn <> INVALID_SOCKET then
      Exit(TPcTcpWinEndpoint.Create(LConn, FOptions));
    LErr := WSAGetLastError;
    if LErr <> WSAEWOULDBLOCK then
    begin
      if LErr = WSAECONNRESET then
        Continue; // the client dropped before accept
      RaiseWsaError('accept', LErr);
    end;
    LEvents[0] := FAcceptEvent;
    LEvents[1] := FStopEvent;
    LRc := WSAWaitForMultipleEvents(2, @LEvents[0], False, PC_WSA_INFINITE,
      False);
    if LRc = PC_WSA_WAIT_FAILED then
      RaiseWsaError('accept (wait)', WSAGetLastError);
    if (LRc = PC_WSA_WAIT_EVENT_0 + 1) or (PcAtomicGet(FClosed) <> 0) then
      Exit; // Close: nil
    FillChar(LNet, SizeOf(LNet), 0);
    pc_WSAEnumNetworkEvents(FSocket, FAcceptEvent, @LNet);
  end;
end;

{ --- factories (Windows) --- }

function PcTcpListen(const ABindAddress: string; APort: Word;
  const AOptions: TPcTcpOptions): TPcListener;
var
  LInfo, LCur: PPcAddrInfo;
  LSock: TSocket;
  LErr: Integer;
  LHost: string;
begin
  EnsureWinsock;
  LErr := 0;
  LHost := BindHost(ABindAddress);
  LInfo := ResolveAddress(LHost, APort, True);
  try
    LCur := LInfo;
    while LCur <> nil do
    begin
      LSock := WinSock2.socket(LCur^.ai_family, LCur^.ai_socktype,
        LCur^.ai_protocol);
      if LSock <> INVALID_SOCKET then
      begin
        // No SO_REUSEADDR on purpose (see the unit's header).
        if (pc_bind(LSock, LCur^.ai_addr, Integer(LCur^.ai_addrlen)) = 0)
          and (WinSock2.listen(LSock, PC_LISTEN_BACKLOG) = 0) then
          Exit(TPcTcpWinListener.Create(LSock, AOptions));
        LErr := WSAGetLastError;
        closesocket(LSock);
      end
      else
        LErr := WSAGetLastError;
      LCur := LCur^.ai_next;
    end;
  finally
    pc_freeaddrinfo(LInfo);
  end;
  RaiseWsaError(Format('listen on %s', [PcFormatHostPort(LHost, APort)]), LErr);
  Result := nil; // unreachable
end;

// Tries ONE candidate with a non-blocking connect, bounded by ADeadline.
// Returns the connected socket, or INVALID_SOCKET with AErr set.
//
// It must be non-blocking: a blocking connect stuck in the kernel ignores the
// budget entirely (for a host that doesn't answer the SYN, Windows insists
// for about 20 s).
function ConnectCandidate(ACand: PPcAddrInfo; ADeadline: UInt64;
  out AErr: Integer): TSocket;
var
  LSock: TSocket;
  LEvent: WSAEVENT;
  LNet: TPcNetworkEvents;
  LRemaining: Int64;
  LRc: DWORD;
begin
  Result := INVALID_SOCKET;
  AErr := 0;
  LSock := WinSock2.socket(ACand^.ai_family, ACand^.ai_socktype,
    ACand^.ai_protocol);
  if LSock = INVALID_SOCKET then
  begin
    AErr := WSAGetLastError;
    Exit;
  end;
  LEvent := WSACreateEvent;
  if LEvent = PC_WSA_INVALID_EVENT then
  begin
    AErr := WSAGetLastError;
    closesocket(LSock);
    Exit;
  end;
  try
    // Associating it with an event already makes the socket non-blocking.
    if WSAEventSelect(LSock, LEvent, PC_FD_CONNECT) <> 0 then
    begin
      AErr := WSAGetLastError;
      closesocket(LSock);
      Exit;
    end;
    if pc_connect(LSock, ACand^.ai_addr, Integer(ACand^.ai_addrlen)) = 0 then
      Exit(LSock); // connected at once
    AErr := WSAGetLastError;
    if AErr <> WSAEWOULDBLOCK then
    begin
      closesocket(LSock);
      Exit;
    end;
    LRemaining := Int64(ADeadline) - Int64(PcTickMs);
    if LRemaining < 0 then
      LRemaining := 0;
    LRc := WSAWaitForMultipleEvents(1, @LEvent, True, DWORD(LRemaining), False);
    if LRc <> PC_WSA_WAIT_EVENT_0 then
    begin
      AErr := WSAETIMEDOUT; // the budget ran out (or the wait failed)
      closesocket(LSock);
      Exit;
    end;
    FillChar(LNet, SizeOf(LNet), 0);
    if pc_WSAEnumNetworkEvents(LSock, LEvent, @LNet) <> 0 then
    begin
      AErr := WSAGetLastError;
      closesocket(LSock);
      Exit;
    end;
    AErr := LNet.iErrorCode[PC_FD_CONNECT_BIT];
    if AErr <> 0 then
    begin
      closesocket(LSock); // refused / unreachable
      Exit;
    end;
    Result := LSock;
  finally
    WSACloseEvent(LEvent);
  end;
end;

function PcTcpConnect(const AHost: string; APort: Word;
  const AOptions: TPcTcpOptions): TPcEndpoint;
var
  LInfo, LCur: PPcAddrInfo;
  LSock: TSocket;
  LDeadline: UInt64;
  LErr: Integer;
  LTimeout: Cardinal;
begin
  EnsureWinsock;
  LTimeout := ConnectTimeout(AOptions);
  LDeadline := PcTickMs + LTimeout;
  LInfo := ResolveAddress(AHost, APort, False);
  try
    LErr := 0;
    LCur := LInfo;
    while LCur <> nil do
    begin
      if Int64(LDeadline) - Int64(PcTickMs) <= 0 then
      begin
        LErr := WSAETIMEDOUT;
        Break;
      end;
      LSock := ConnectCandidate(LCur, LDeadline, LErr);
      if LSock <> INVALID_SOCKET then
        Exit(TPcTcpWinEndpoint.Create(LSock, AOptions));
      LCur := LCur^.ai_next;
    end;
  finally
    pc_freeaddrinfo(LInfo);
  end;
  if LErr = WSAETIMEDOUT then
    raise EPcTransportTimeout.CreateFmt('timeout (%u ms) connecting to %s',
      [LTimeout, PcFormatHostPort(AHost, APort)]);
  RaiseWsaError(Format('connect to %s', [PcFormatHostPort(AHost, APort)]), LErr);
  Result := nil; // unreachable
end;

{$ELSE}

{ ============================== POSIX (FPC) ================================= }

const
  // <netinet/tcp.h> (Linux). FPC 3.2.2's Sockets unit doesn't expose them.
  PC_TCP_KEEPIDLE = 4;
  PC_TCP_KEEPINTVL = 5;
  PC_TCP_KEEPCNT = 6;

procedure ApplyNoDelay(AFd: cint; const AOptions: TPcTcpOptions);
var
  LOn: cint;
begin
  if AOptions.Nagle then
    Exit;
  LOn := 1;
  // Best effort (see the Windows one).
  fpSetSockOpt(AFd, PC_IPPROTO_TCP, PC_TCP_NODELAY, @LOn, SizeOf(LOn));
end;

// All three are per socket here, unlike Windows: a dead peer is noticed after
// ASeconds idle + PROBE_COUNT probes INTERVAL seconds apart.
procedure ApplyKeepAlive(AFd: cint; ASeconds: Cardinal);
var
  LVal: cint;
begin
  if ASeconds = 0 then
    Exit;
  LVal := 1;
  fpSetSockOpt(AFd, SOL_SOCKET, SO_KEEPALIVE, @LVal, SizeOf(LVal));
  LVal := cint(ASeconds);
  fpSetSockOpt(AFd, PC_IPPROTO_TCP, PC_TCP_KEEPIDLE, @LVal, SizeOf(LVal));
  LVal := PC_TCP_KEEPALIVE_INTERVAL_SECONDS;
  fpSetSockOpt(AFd, PC_IPPROTO_TCP, PC_TCP_KEEPINTVL, @LVal, SizeOf(LVal));
  LVal := PC_TCP_KEEPALIVE_PROBE_COUNT;
  fpSetSockOpt(AFd, PC_IPPROTO_TCP, PC_TCP_KEEPCNT, @LVal, SizeOf(LVal));
end;

{ TPcTcpPosixListener }

constructor TPcTcpPosixListener.Create(AFd: cint; const AOptions: TPcTcpOptions);
begin
  inherited Create(AFd, '');
  FOptions := AOptions;
  OnAccepted := ApplyOptions;
end;

procedure TPcTcpPosixListener.ApplyOptions(AFd: cint);
begin
  ApplyNoDelay(AFd, FOptions);
  ApplyKeepAlive(AFd, FOptions.KeepAliveSeconds);
end;

function PcTcpListen(const ABindAddress: string; APort: Word;
  const AOptions: TPcTcpOptions): TPcListener;
var
  LInfo, LCur: PPcAddrInfo;
  LFd, LErr, LOn: cint;
  LHost: string;
begin
  LErr := 0;
  LHost := BindHost(ABindAddress);
  LInfo := ResolveAddress(LHost, APort, True);
  try
    LCur := LInfo;
    while LCur <> nil do
    begin
      LFd := fpSocket(LCur^.ai_family, LCur^.ai_socktype, LCur^.ai_protocol);
      if LFd >= 0 then
      begin
        // On POSIX SO_REUSEADDR only keeps TIME_WAIT from blocking a rebind.
        LOn := 1;
        fpSetSockOpt(LFd, SOL_SOCKET, SO_REUSEADDR, @LOn, SizeOf(LOn));
        if (fpBind(LFd, LCur^.ai_addr, LCur^.ai_addrlen) = 0)
          and (fpListen(LFd, PC_LISTEN_BACKLOG) = 0) then
          Exit(TPcTcpPosixListener.Create(LFd, AOptions));
        LErr := fpgeterrno;
        fpClose(LFd);
      end
      else
        LErr := fpgeterrno;
      LCur := LCur^.ai_next;
    end;
  finally
    pc_freeaddrinfo(LInfo);
  end;
  PcRaisePosixError(Format('listen on %s', [PcFormatHostPort(LHost, APort)]),
    LErr);
  Result := nil; // unreachable
end;

// Tries ONE candidate with a non-blocking connect, bounded by ADeadline.
// Returns the connected fd (back in blocking mode) or -1 with AErr set.
function ConnectCandidate(ACand: PPcAddrInfo; ADeadline: UInt64;
  out AErr: cint): cint;
var
  LFd, LFlags, LRc: cint;
  LPoll: pollfd;
  LSoErr: cint;
  LLen: TSockLen;
  LRemaining: Int64;
begin
  Result := -1;
  AErr := 0;
  LFd := fpSocket(ACand^.ai_family, ACand^.ai_socktype, ACand^.ai_protocol);
  if LFd < 0 then
  begin
    AErr := fpgeterrno;
    Exit;
  end;
  LFlags := fpFcntl(LFd, F_GetFl, 0);
  fpFcntl(LFd, F_SetFl, LFlags or O_NONBLOCK);
  if fpConnect(LFd, ACand^.ai_addr, ACand^.ai_addrlen) <> 0 then
  begin
    AErr := fpgeterrno;
    if AErr <> ESysEINPROGRESS then
    begin
      fpClose(LFd);
      Exit;
    end;
    repeat
      // Recomputed on every pass, so an EINTR doesn't restart the budget.
      LRemaining := Int64(ADeadline) - Int64(PcTickMs);
      if LRemaining < 0 then
        LRemaining := 0;
      LPoll.fd := LFd;
      LPoll.events := POLLOUT;
      LPoll.revents := 0;
      LRc := fpPoll(@LPoll, 1, LRemaining);
    until (LRc >= 0) or (fpgeterrno <> ESysEINTR);
    if LRc <= 0 then
    begin
      if LRc = 0 then
        AErr := ESysETIMEDOUT // the budget ran out
      else
        AErr := fpgeterrno;
      fpClose(LFd);
      Exit;
    end;
    // POLLOUT alone isn't success: the connect's result is in SO_ERROR.
    LSoErr := 0;
    LLen := SizeOf(LSoErr);
    if fpGetSockOpt(LFd, SOL_SOCKET, SO_ERROR, @LSoErr, @LLen) <> 0 then
      LSoErr := fpgeterrno;
    if LSoErr <> 0 then
    begin
      AErr := LSoErr;
      fpClose(LFd);
      Exit;
    end;
  end;
  // Back to blocking mode: TPcPosixSocketEndpoint polls before every call.
  fpFcntl(LFd, F_SetFl, LFlags);
  AErr := 0;
  Result := LFd;
end;

function PcTcpConnect(const AHost: string; APort: Word;
  const AOptions: TPcTcpOptions): TPcEndpoint;
var
  LInfo, LCur: PPcAddrInfo;
  LFd, LErr: cint;
  LDeadline: UInt64;
  LTimeout: Cardinal;
begin
  LTimeout := ConnectTimeout(AOptions);
  LDeadline := PcTickMs + LTimeout;
  LInfo := ResolveAddress(AHost, APort, False);
  try
    LErr := 0;
    LCur := LInfo;
    while LCur <> nil do
    begin
      if Int64(LDeadline) - Int64(PcTickMs) <= 0 then
      begin
        LErr := ESysETIMEDOUT;
        Break;
      end;
      LFd := ConnectCandidate(LCur, LDeadline, LErr);
      if LFd >= 0 then
      begin
        ApplyNoDelay(LFd, AOptions);
        ApplyKeepAlive(LFd, AOptions.KeepAliveSeconds);
        Exit(TPcPosixSocketEndpoint.Create(LFd));
      end;
      LCur := LCur^.ai_next;
    end;
  finally
    pc_freeaddrinfo(LInfo);
  end;
  if LErr = ESysETIMEDOUT then
    raise EPcTransportTimeout.CreateFmt('timeout (%u ms) connecting to %s',
      [LTimeout, PcFormatHostPort(AHost, APort)]);
  PcRaisePosixError(Format('connect to %s', [PcFormatHostPort(AHost, APort)]),
    LErr);
  Result := nil; // unreachable
end;

{$ENDIF}

{$IFDEF PASCALCOMMON_WINDOWS}
var
  GWsaData: TWSAData;

initialization
  GWinsockError := WSAStartup($0202, GWsaData);

finalization
  if GWinsockError = 0 then
    WSACleanup;
{$ENDIF}

end.
