unit PascalCommon.Transport.Posix;

{$I pascalcommon.inc}

{ A connected socket and a listening socket on FPC/Unix, by file descriptor:
  the TPcEndpoint and TPcListener behind PascalCommon.Transport.Tcp there.

  It came from pascal-pipes-faa's Pipes.Transport.Posix, translated. They take
  any stream socket the caller has already set up (AF_INET, AF_INET6 or
  AF_UNIX), so pipes' Unix domain socket transport builds its socket and
  hands it to these same classes.

  Interrupting blocking IO uses a self-pipe: each endpoint and listener has
  its own fpPipe pair, and every wait is one fpPoll on [the operation's fd,
  the self-pipe's read end]. CloseAbort/Close write one byte to the self-pipe
  (waking the poll) and, on the endpoint, fpShutdown(SHUT_RDWR) disarms any
  read/write left in the kernel. No wait polls on a timer: waking is always by
  an event.

  - The self-pipe is never drained after CloseAbort, so every later wait wakes
    at once and raises EPcTransportClosed.
  - The fd is closed only in the destructor, after the threads that used it
    were joined: closing it under a thread still in fpPoll risks IO on a fd
    the kernel has already reused.
  - Writes always pass MSG_NOSIGNAL: a dead peer gives EPIPE (raised as
    EPcTransportClosed), never SIGPIPE, which would kill the process.
  - recv and send pass MSG_DONTWAIT, so a call after the poll only does what
    fits right now and EAGAIN goes back to the poll. Without it a blocking
    send of a large buffer, after poll reported a little room, waits inside
    the kernel until the whole buffer is sent: the IO deadline is never
    looked at again (found here: SetIoDeadline_WriteTimesOutWhenThePeerStops-
    Reading hung on Linux; pascal-pipes-faa has the same code). The socket
    stays in blocking mode, so a caller that uses the fd directly sees no
    change.
  - Every wait polls before recv/send, so a reader and a writer on the same
    endpoint never steal each other's wake-up (the Windows backend needs a
    second event per direction for that; see PascalCommon.Transport.Tcp).

  Delphi for Linux/Android is not covered (BaseUnix/Sockets are FPC units).
  pipes keeps its Android TCP endpoint (docs/transport-design.md, T4). }

interface

{$IFDEF FPC}{$IFDEF UNIX}

uses
  UnixType,
  BaseUnix,
  Sockets,
  SysUtils,
  PascalCommon.Threading,
  PascalCommon.Transport;

const
  /// The IPv6 family on Linux (Windows uses 23).
  PC_AF_INET6_POSIX = 10;

type
  TPcPosixSocketEndpoint = class(TPcEndpoint)
  private
    FFd: cint;
    FStopR: cint;          // self-pipe, read end (in every fpPoll)
    FStopW: cint;          // self-pipe, write end (CloseAbort writes 1 byte)
    FClosed: Integer;      // atomic: 1 after CloseAbort
    // 0 = no deadline. One per direction (SetReadDeadline/SetWriteDeadline),
    // each written only by that direction's thread.
    FReadTimeoutMs: Cardinal;
    FWriteTimeoutMs: Cardinal;
    /// Waits for the fd to become ready (AEvents) or for the stop.
    procedure WaitReadyOrStop(AEvents: SmallInt; const AOp: string);
  public
    /// Takes ownership of AFd, a connected stream socket in blocking mode.
    constructor Create(AFd: cint);
    destructor Destroy; override;
    function Read(var ABuffer; ACount: Integer): Integer; override;
    procedure WriteExactly(const ABuffer; ACount: Integer); override;
    procedure CloseAbort; override;
    procedure SetIoDeadline(ATimeoutMs: Cardinal); override;
    procedure SetReadDeadline(ATimeoutMs: Cardinal); override;
    procedure SetWriteDeadline(ATimeoutMs: Cardinal); override;
    /// True only for an AF_INET/AF_INET6 socket; an AF_UNIX one has no IP.
    function TryPeerAddress(out AAddress: string): Boolean; override;
    function HasPendingInput: Boolean; override;
    property Fd: cint read FFd;
  end;

  /// Called on each accepted fd before it becomes an endpoint (socket
  /// options the listening socket doesn't pass on).
  TPcPosixAcceptHook = procedure(AFd: cint) of object;

  TPcPosixSocketListener = class(TPcListener)
  private
    FFd: cint;             // listening socket
    FStopR: cint;
    FStopW: cint;
    FClosed: Integer;      // atomic
    FUnlinkPath: string;
    FOnAccepted: TPcPosixAcceptHook;
  public
    /// Takes ownership of AFd, a socket already listening. AUnlinkPath: a
    /// Unix socket file to remove in the destructor ('' = none).
    constructor Create(AFd: cint; const AUnlinkPath: string = '');
    destructor Destroy; override;
    function Accept: TPcEndpoint; override;
    procedure Close; override;
    /// The bound port (getsockname); 0 for an AF_UNIX socket.
    function Port: Word; override;
    property OnAccepted: TPcPosixAcceptHook read FOnAccepted write FOnAccepted;
  end;

/// Raises EPcTransport with the errno's text.
procedure PcRaisePosixError(const AOp: string; AErr: cint);

{$ENDIF}{$ENDIF}

implementation

{$IFDEF FPC}{$IFDEF UNIX}

const
  // Linux values, declared here: FPC 3.2.2's Sockets unit doesn't expose
  // SHUT_*/MSG_NOSIGNAL uniformly on every target.
  PC_SHUT_RDWR = 2;
  PC_MSG_DONTWAIT = $40;
  PC_MSG_PEEK = 2;
  PC_MSG_NOSIGNAL = $4000;

// Declared here so the address travels as an opaque pointer + size and the
// TPcRawSockAddrStorage buffer fits whatever family the kernel returns.
function pc_getpeername(AFd: cint; AAddr: Pointer;
  var ANameLen: LongWord): cint; cdecl; external 'c' name 'getpeername';
function pc_getsockname(AFd: cint; AAddr: Pointer;
  var ANameLen: LongWord): cint; cdecl; external 'c' name 'getsockname';

procedure PcRaisePosixError(const AOp: string; AErr: cint);
begin
  raise EPcTransport.CreateFmt('%s failed (error %d: %s)',
    [AOp, AErr, SysErrorMessage(AErr)]);
end;

procedure NewSelfPipe(out AReadFd, AWriteFd: cint);
var
  LFds: TFilDes;
begin
  AReadFd := -1;
  AWriteFd := -1;
  if fpPipe(LFds) <> 0 then
    PcRaisePosixError('pipe', fpgeterrno);
  AReadFd := LFds[0];
  AWriteFd := LFds[1];
end;

{ TPcPosixSocketEndpoint }

constructor TPcPosixSocketEndpoint.Create(AFd: cint);
begin
  inherited Create;
  FFd := AFd;
  FStopR := -1;
  FStopW := -1;
  NewSelfPipe(FStopR, FStopW); // if it fails, the destructor closes AFd
end;

destructor TPcPosixSocketEndpoint.Destroy;
begin
  CloseAbort; // idempotent
  if FFd >= 0 then
    fpClose(FFd);
  if FStopR >= 0 then
    fpClose(FStopR);
  if FStopW >= 0 then
    fpClose(FStopW);
  inherited;
end;

procedure TPcPosixSocketEndpoint.CloseAbort;
var
  LByte: Byte;
begin
  if PcAtomicSet(FClosed, 1) = 1 then
    Exit; // already aborted
  LByte := 1;
  if FStopW >= 0 then
    fpWrite(FStopW, LByte, 1);   // wakes current and future waits (never drained)
  if FFd >= 0 then
    fpShutdown(FFd, PC_SHUT_RDWR); // disarms read/write left in the kernel
end;

procedure TPcPosixSocketEndpoint.SetIoDeadline(ATimeoutMs: Cardinal);
begin
  FReadTimeoutMs := ATimeoutMs;
  FWriteTimeoutMs := ATimeoutMs;
end;

procedure TPcPosixSocketEndpoint.SetReadDeadline(ATimeoutMs: Cardinal);
begin
  FReadTimeoutMs := ATimeoutMs;
end;

procedure TPcPosixSocketEndpoint.SetWriteDeadline(ATimeoutMs: Cardinal);
begin
  FWriteTimeoutMs := ATimeoutMs;
end;

function TPcPosixSocketEndpoint.TryPeerAddress(out AAddress: string): Boolean;
var
  LStorage: TPcRawSockAddrStorage;
  LLen: LongWord;
begin
  AAddress := '';
  Result := False;
  if PcAtomicGet(FClosed) <> 0 then
    Exit;
  FillChar(LStorage, SizeOf(LStorage), 0);
  LLen := SizeOf(LStorage);
  if pc_getpeername(FFd, @LStorage, LLen) <> 0 then
    Exit; // best effort: the log goes on without an address
  Result := PcFormatSockAddr(LStorage, PC_AF_INET6_POSIX, AAddress);
end;

function TPcPosixSocketEndpoint.HasPendingInput: Boolean;
var
  LByte: Byte;
  LErr: cint;
begin
  if PcAtomicGet(FClosed) <> 0 then
    Exit(True);
  // A byte, or 0 for the peer's FIN, is input pending.
  if NativeInt(fpRecv(FFd, @LByte, 1, PC_MSG_PEEK or PC_MSG_DONTWAIT)) >= 0 then
    Exit(True);
  LErr := fpgeterrno;
  Result := (LErr <> ESysEAGAIN) and (LErr <> ESysEINTR);
end;

procedure TPcPosixSocketEndpoint.WaitReadyOrStop(AEvents: SmallInt;
  const AOp: string);
var
  LFds: array[0..1] of pollfd;
  LRc: cint;
  LDeadline: UInt64;
  LWait: Int64;
  LTimeoutMs: Cardinal;
begin
  if PcAtomicGet(FClosed) <> 0 then
    raise EPcTransportClosed.Create(AOp + ' on a closed endpoint');
  if (AEvents and POLLOUT) <> 0 then
    LTimeoutMs := FWriteTimeoutMs
  else
    LTimeoutMs := FReadTimeoutMs;
  LDeadline := 0;
  if LTimeoutMs <> 0 then
    LDeadline := PcTickMs + LTimeoutMs;
  repeat
    if LTimeoutMs = 0 then
      LWait := -1
    else
    begin
      // Recomputed on every pass: otherwise an EINTR would restart the
      // deadline, and a burst of signals would stretch it forever.
      LWait := Int64(LDeadline) - Int64(PcTickMs);
      if LWait < 0 then
        LWait := 0;
    end;
    LFds[0].fd := FFd;
    LFds[0].events := AEvents;
    LFds[0].revents := 0;
    LFds[1].fd := FStopR;
    LFds[1].events := POLLIN;
    LFds[1].revents := 0;
    LRc := fpPoll(@LFds[0], 2, LWait);
  until (LRc >= 0) or (fpgeterrno <> ESysEINTR);
  if LRc < 0 then
    PcRaisePosixError(AOp + ' (poll)', fpgeterrno);
  if ((LFds[1].revents and POLLIN) <> 0) or (PcAtomicGet(FClosed) <> 0) then
    raise EPcTransportClosed.Create(AOp + ' aborted (CloseAbort)');
  if (LRc = 0) and (LTimeoutMs <> 0) then
    raise EPcTransportTimeout.CreateFmt(
      '%s: the peer did not respond within %u ms', [AOp, LTimeoutMs]);
  // POLLERR/POLLHUP on the fd: let recv/send report it; there may still be
  // data queued to read after the HUP.
end;

function TPcPosixSocketEndpoint.Read(var ABuffer; ACount: Integer): Integer;
var
  LGot: NativeInt;
  LErr: cint;
begin
  while True do
  begin
    WaitReadyOrStop(POLLIN, 'read');
    LGot := NativeInt(fpRecv(FFd, @ABuffer, ACount, PC_MSG_DONTWAIT));
    if LGot > 0 then
      Exit(Integer(LGot));
    if LGot = 0 then
      raise EPcTransportClosed.Create('connection closed by the peer');
    LErr := fpgeterrno;
    case LErr of
      ESysEINTR, ESysEAGAIN:
        ; // back to the poll
      ESysECONNRESET, ESysEPIPE:
        raise EPcTransportClosed.CreateFmt(
          'read: connection closed (error %d)', [LErr]);
    else
      PcRaisePosixError('read', LErr);
    end;
  end;
end;

procedure TPcPosixSocketEndpoint.WriteExactly(const ABuffer; ACount: Integer);
var
  P: PByte;
  LWrote: NativeInt;
  LErr: cint;
begin
  P := @ABuffer;
  while ACount > 0 do
  begin
    WaitReadyOrStop(POLLOUT, 'write');
    LWrote := NativeInt(fpSend(FFd, P, ACount, PC_MSG_NOSIGNAL or PC_MSG_DONTWAIT));
    if LWrote > 0 then
    begin
      Inc(P, LWrote);
      Dec(ACount, Integer(LWrote));
      Continue;
    end;
    LErr := fpgeterrno;
    case LErr of
      ESysEINTR, ESysEAGAIN:
        ; // back to the poll
      ESysEPIPE, ESysECONNRESET:
        raise EPcTransportClosed.CreateFmt(
          'write: connection closed (error %d)', [LErr]);
    else
      PcRaisePosixError('write', LErr);
    end;
  end;
end;

{ TPcPosixSocketListener }

constructor TPcPosixSocketListener.Create(AFd: cint; const AUnlinkPath: string);
begin
  inherited Create;
  FFd := AFd;
  FStopR := -1;
  FStopW := -1;
  FUnlinkPath := AUnlinkPath;
  NewSelfPipe(FStopR, FStopW); // if it fails, the destructor closes AFd
end;

destructor TPcPosixSocketListener.Destroy;
begin
  Close; // idempotent
  // The accepting thread was joined already (the contract).
  if FFd >= 0 then
    fpClose(FFd);
  if FStopR >= 0 then
    fpClose(FStopR);
  if FStopW >= 0 then
    fpClose(FStopW);
  if FUnlinkPath <> '' then
    fpUnlink(FUnlinkPath);
  inherited;
end;

procedure TPcPosixSocketListener.Close;
var
  LByte: Byte;
begin
  if PcAtomicSet(FClosed, 1) = 1 then
    Exit;
  LByte := 1;
  if FStopW >= 0 then
    fpWrite(FStopW, LByte, 1); // unblocks a pending Accept (returns nil)
end;

function TPcPosixSocketListener.Port: Word;
var
  LStorage: TPcRawSockAddrStorage;
  LLen: LongWord;
begin
  Result := 0;
  FillChar(LStorage, SizeOf(LStorage), 0);
  LLen := SizeOf(LStorage);
  if pc_getsockname(FFd, @LStorage, LLen) <> 0 then
    PcRaisePosixError('getsockname', fpgeterrno);
  if LStorage.Family = PC_AF_INET then
    Result := Swap(LStorage.V4.sin_port)
  else if LStorage.Family = PC_AF_INET6_POSIX then
    Result := Swap(LStorage.V6.sin6_port);
end;

function TPcPosixSocketListener.Accept: TPcEndpoint;
var
  LFds: array[0..1] of pollfd;
  LRc, LConn, LErr: cint;
begin
  Result := nil;
  // A loop: a client that connects and drops before fpAccept goes back to
  // waiting, without returning a dead endpoint.
  while True do
  begin
    if PcAtomicGet(FClosed) <> 0 then
      Exit;
    LFds[0].fd := FFd;
    LFds[0].events := POLLIN;
    LFds[0].revents := 0;
    LFds[1].fd := FStopR;
    LFds[1].events := POLLIN;
    LFds[1].revents := 0;
    LRc := fpPoll(@LFds[0], 2, -1);
    if LRc < 0 then
    begin
      if fpgeterrno = ESysEINTR then
        Continue;
      PcRaisePosixError('accept (poll)', fpgeterrno);
    end;
    if ((LFds[1].revents and POLLIN) <> 0) or (PcAtomicGet(FClosed) <> 0) then
      Exit; // Close: nil
    LConn := fpAccept(FFd, nil, nil);
    if LConn >= 0 then
    begin
      try
        if Assigned(FOnAccepted) then
          FOnAccepted(LConn);
      except
        fpClose(LConn);
        raise;
      end;
      Exit(TPcPosixSocketEndpoint.Create(LConn));
    end;
    LErr := fpgeterrno;
    if (LErr = ESysEINTR) or (LErr = ESysECONNABORTED) or (LErr = ESysEAGAIN) then
      Continue; // the client dropped between poll and accept
    PcRaisePosixError('accept', LErr);
  end;
end;

{$ENDIF}{$ENDIF}

end.
