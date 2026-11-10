unit PascalCommon.Transport;

{$I pascalcommon.inc}

{ The transport contract shared by the *-faa libraries: an established
  connection (TPcEndpoint), a listening point (TPcListener), a TStream adapter
  for frame readers, the transport exceptions and host:port parsing.

  It came from pascal-pipes-faa's Pipes.Transport (docs/transport-design.md,
  decisions T1 and T2), translated; the factories live in the backend units
  (PcTcpConnect/PcTcpListen in PascalCommon.Transport.Tcp, the TLS ones in a
  later unit), so this unit doesn't depend on any socket API.

  Thread contract, for every endpoint:
  - At most ONE thread in Read at a time, and writes serialized by the caller
    (one writer at a time). A reader and a writer may run at the same time:
    that is what a protocol with a reader thread does.
  - CloseAbort (endpoint) and Close (listener) are thread-safe and idempotent:
    they are how another thread unblocks one stuck in Read, WriteExactly or
    Accept. Free the object only after joining the threads that used it; the
    socket is closed in the destructor, so a thread still inside a wait never
    touches a descriptor the OS has already reused.
  - Read and WriteExactly raise EPcTransportClosed when the peer closes or
    CloseAbort was called; Read never returns 0.

  The base types are abstract classes, not interfaces: within a major version
  this library freezes its public interfaces, but a class may gain methods,
  and the endpoint is expected to (a per-operation deadline, for instance). }

interface

uses
  SysUtils,
  Classes;

type
  /// Any transport failure (base of the others).
  EPcTransport = class(Exception);
  /// The peer closed the connection, or CloseAbort was called.
  EPcTransportClosed = class(EPcTransport);
  /// A wait passed its deadline (connect, SetIoDeadline, TLS handshake).
  EPcTransportTimeout = class(EPcTransport);
  /// Connect: every address answered that nothing listens on the port
  /// (ECONNREFUSED). Its own class because it is the one failure a caller may
  /// want to retry (a server still starting), unlike a name that doesn't
  /// resolve; telling them apart by the message would tie the caller to its
  /// text.
  EPcTransportRefused = class(EPcTransport);
  /// TLS: handshake, certificate validation, or the TLS library is missing.
  EPcTls = class(EPcTransport);

  { Who the peer is, according to the certificate it presented and that was
    already validated against the configured CA. It only exists under mTLS;
    without it there is no identity, not an empty one (TryPeerIdentity answers
    False). The chain was checked before this is filled, so CommonName can be
    trusted to identify the peer. }
  TPcPeerIdentity = record
    /// The subject's CN.
    CommonName: string;
    /// The whole subject (DN), for logs and audit.
    Subject: string;
  end;

  { Options for a TCP connection or listener. A zeroed record (Default, or
    FillChar) is the recommended one: each field's zero means the safe or
    usual behavior. }
  TPcTcpOptions = record
    /// Connect only: the budget for the whole connect, every address of the
    /// name included. 0 = PC_TCP_CONNECT_TIMEOUT_DEFAULT.
    ConnectTimeoutMs: Cardinal;
    /// Idle seconds before the first keep-alive probe; 0 = keep-alive off.
    /// On a listener it applies to the accepted connections.
    KeepAliveSeconds: Cardinal;
    /// True leaves Nagle's algorithm on. Default False = TCP_NODELAY on every
    /// socket: request-reply protocols suffer badly from Nagle's delay. The
    /// field is the negative one so that a zeroed record gets TCP_NODELAY.
    Nagle: Boolean;
  end;

  { Which TLS implementation a connection uses (docs/transport-design.md, T3).
    Chosen at run time, so one build covers both on Windows. }
  TPcTlsBackend = (
    /// SChannel on Windows, OpenSSL elsewhere.
    tbDefault,
    /// Windows only; EPcTls elsewhere.
    tbSChannel,
    /// libssl/libcrypto, loaded on first use (3.x preferred, 1.1.1 accepted).
    tbOpenSsl);

  { TLS options for a client or a server. As with TPcTcpOptions, a zeroed
    record is the safe one: it validates the server against the system store
    and puts the default deadline on the handshake.

    Field                     client                       server
    CertFile (+CertPassword)  own certificate (mTLS)       own certificate
      / KeyFile                                            (required)
    CaFile                    trust THIS CA for the        require client
                              server instead of the        certificates from
                              system store                 this CA (mTLS)
    SkipServerVerification    no chain/hostname check      ignored

    Formats (T7): CaFile is PEM on both backends. A certificate of one's own
    is a PEM pair (CertFile + KeyFile) on OpenSSL and a PFX (CertFile +
    CertPassword) on SChannel. }
  TPcTlsOptions = record
    CertFile: string;
    CertPassword: string;
    KeyFile: string;
    CaFile: string;
    /// Client: turns off the server's chain and hostname validation. The
    /// field is the negative one so that zero validates; for a lab only:
    /// without it the traffic is encrypted to whoever answers.
    SkipServerVerification: Boolean;
    /// The handshake's deadline per wait. 0 = PC_TLS_HANDSHAKE_TIMEOUT_DEFAULT;
    /// PC_TLS_HANDSHAKE_NO_TIMEOUT removes it, which must be said explicitly:
    /// without it, a peer that opens TCP and never sends a ClientHello holds a
    /// server thread forever.
    HandshakeTimeoutMs: Cardinal;
    Backend: TPcTlsBackend;
  end;

  { One established, bidirectional connection (client or server side). }
  TPcEndpoint = class
  public
    /// Completes whatever negotiation the endpoint needs before the first
    /// Read or Write: today only server-side TLS. Empty on plain TCP.
    ///
    /// It exists to take the handshake off the accepting thread: the caller
    /// is the connection's own thread, so a peer that stalls mid-handshake
    /// holds only itself, not the accept loop.
    procedure Handshake; virtual;
    /// Reads up to ACount bytes, blocking until at least one arrives; returns
    /// how many (1..ACount). EPcTransportClosed when the peer closed or
    /// CloseAbort was called.
    function Read(var ABuffer; ACount: Integer): Integer; virtual; abstract;
    /// Writes exactly ACount bytes, blocking until done.
    procedure WriteExactly(const ABuffer; ACount: Integer); virtual; abstract;
    /// Aborts pending IO and marks the endpoint closed. Thread-safe and
    /// idempotent; callable from any thread. The socket itself is released in
    /// the destructor.
    procedure CloseAbort; virtual; abstract;
    /// Puts a deadline on this endpoint's IO waits: after ATimeoutMs without
    /// the socket becoming ready, Read/WriteExactly raise EPcTransportTimeout
    /// instead of waiting forever. 0 removes it.
    ///
    /// It applies from the next wait on and counts per wait, not per
    /// operation: it answers "the peer stopped talking" (or stopped reading),
    /// it isn't a total budget. Call it from the thread that reads/writes.
    ///
    /// The default does NOTHING: a transport that doesn't implement it waits
    /// with no deadline. Every backend that TLS wraps must implement it, or
    /// the handshake deadline silently disappears.
    ///
    /// Sets the read and the write deadline alike (see SetReadDeadline).
    procedure SetIoDeadline(ATimeoutMs: Cardinal); virtual;
    /// The deadline of Read's waits alone; SetWriteDeadline, of
    /// WriteExactly's. Same rules as SetIoDeadline, one direction each.
    ///
    /// They exist for a full-duplex connection where the two directions want
    /// different answers: a pub/sub subscriber's reader waits for minutes
    /// with nothing wrong (silence is its normal state), while a writer stuck
    /// because the server stopped reading must give up. One deadline can't
    /// say both, and the reader and the writer setting it in turn would race.
    /// Each direction's value is touched only by the thread of that
    /// direction, so a reader and a writer may set theirs at the same time.
    ///
    /// The default raises EPcTransport: unlike SetIoDeadline, asking for one
    /// direction is explicit, and silently ignoring it would leave a wait
    /// without the deadline the caller relies on.
    procedure SetReadDeadline(ATimeoutMs: Cardinal); virtual;
    procedure SetWriteDeadline(ATimeoutMs: Cardinal); virtual;
    /// The peer's address as 'host:port' (IPv6 in brackets, as
    /// PcParseHostPort reads it). False when the transport has none (a local
    /// pipe) or the socket no longer answers.
    function TryPeerAddress(out AAddress: string): Boolean; virtual;
    /// The peer's verified identity (see TPcPeerIdentity). False without TLS
    /// and under TLS without a client certificate. Meaningful only after
    /// Handshake.
    function TryPeerIdentity(out AIdentity: TPcPeerIdentity): Boolean; virtual;
    /// Whether the peer sent anything not read yet (bytes, or its close),
    /// checked without waiting and without consuming it (1.31.0). For a
    /// connection pool: an idle connection with something pending was closed
    /// by the peer, or is out of step, and must not be reused. True also
    /// after CloseAbort and when the socket reports an error. Call it from
    /// the thread that reads, with no Read running.
    ///
    /// It doesn't wait on purpose: a 1 ms wait costs 15.5 ms on Windows (the
    /// timer's resolution; measured with WaitForSingleObject, 2026-11-10),
    /// more than a new TLS connection on loopback.
    ///
    /// A TLS endpoint answers for its raw socket: a record that carries no
    /// data (a close_notify, a late session ticket) counts as pending, and
    /// plaintext the session already decrypted doesn't. Both are the safe
    /// answer for a pool.
    ///
    /// The default raises EPcTransport: a transport that can't tell must
    /// say so rather than answer "nothing pending".
    function HasPendingInput: Boolean; virtual;
  end;

  { A server's listening point. }
  TPcListener = class
  public
    /// Waits for the next connection. Returns nil (no exception) once Close
    /// was called. Call it from ONE thread.
    function Accept: TPcEndpoint; virtual; abstract;
    /// Unblocks a pending Accept and refuses new ones. Thread-safe and
    /// idempotent. Free the listener only after joining the accepting thread.
    procedure Close; virtual; abstract;
    /// The port actually bound: the one the OS chose when the listener was
    /// asked for port 0.
    function Port: Word; virtual; abstract;
  end;

  { A TLS session over a stream of raw bytes, implemented by a backend
    (PascalCommon.Transport.SChannel, PascalCommon.Transport.OpenSSL) and used
    by PascalCommon.Transport.Tls; applications use TPcEndpoint instead. It
    owns the raw stream.

    Read returns 0 only for the peer's close_notify. EPcTransport* from the
    raw stream (closed, timeout) pass through unchanged, so a deadline or a
    CloseAbort keeps its class; TLS protocol failures raise EPcTls. Write
    writes everything or raises. One reader and one writer may run at once
    (the backend serializes what it must); writers are serialized by the
    caller. }
  TPcTlsSession = class(TStream)
  public
    /// Runs the handshake. Called once, by the thread that will read.
    procedure Negotiate; virtual; abstract;
    /// The client's identity, on a server session under mTLS, after
    /// Negotiate. False otherwise.
    function TryPeerIdentity(out AIdentity: TPcPeerIdentity): Boolean; virtual;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  { A server's TLS credentials, loaded once when listening (so a wrong
    password or file shows up at Listen, not at the first client) and shared
    by every connection. Each session keeps its own reference to what it
    needs, so the credentials may be freed while sessions are alive. }
  TPcTlsServerCredentials = class
  public
    /// A server session over ARaw, not negotiated yet; it owns ARaw (also
    /// when this raises).
    function NewSession(ARaw: TStream): TPcTlsSession; virtual; abstract;
  end;

  { TPcEndpoint as a TStream, for frame readers and writers. It doesn't own
    the endpoint. Not seekable (Seek returns 0). Read returns at least one
    byte or raises, like the endpoint: never 0, so ReadBuffer works. }
  TPcEndpointStream = class(TStream)
  private
    FEndpoint: TPcEndpoint;
  public
    constructor Create(AEndpoint: TPcEndpoint);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property Endpoint: TPcEndpoint read FEndpoint;
  end;

  { Raw buffers for getpeername/getsockname. sockaddr_in and sockaddr_in6
    have the SAME field layout on Windows and POSIX (family, port in network
    byte order, address); only the IPv6 family constant differs (23 on
    Windows, 10 on Linux), and each backend uses its own. Declared here, not
    imported from each compiler's socket unit, because the layout must be the
    same on both sides whatever those units call it. }
  TPcRawSockAddrIn = record
    sin_family: Word;
    sin_port: Word;               // network byte order (big-endian)
    sin_addr: array[0..3] of Byte;
    sin_zero: array[0..7] of Byte;
  end;

  TPcRawSockAddrIn6 = record
    sin6_family: Word;
    sin6_port: Word;              // network byte order
    sin6_flowinfo: LongWord;
    sin6_addr: array[0..15] of Byte;
    sin6_scope_id: LongWord;
  end;

  TPcRawSockAddrStorage = record
  case Integer of
    0: (Family: Word);
    1: (V4: TPcRawSockAddrIn);
    2: (V6: TPcRawSockAddrIn6);
    3: (Pad: array[0..127] of Byte); // as large as a real sockaddr_storage
  end;

const
  /// TPcTcpOptions.ConnectTimeoutMs = 0.
  PC_TCP_CONNECT_TIMEOUT_DEFAULT = 10000;
  /// Keep-alive: seconds between probes, and how many unanswered probes drop
  /// the connection. With KeepAliveSeconds = 20, a dead peer is noticed after
  /// about 20 + 3 * 5 = 35 s. Windows doesn't let a socket set the count
  /// (SIO_KEEPALIVE_VALS; it is fixed at 10 before Vista, 2 since).
  PC_TCP_KEEPALIVE_INTERVAL_SECONDS = 5;
  PC_TCP_KEEPALIVE_PROBE_COUNT = 3;
  /// The IPv4 family: the same value on Windows and POSIX, unlike IPv6.
  PC_AF_INET = 2;
  /// TPcTlsOptions.HandshakeTimeoutMs = 0. 15 s is generous for a handshake
  /// over a bad VPN: the target isn't a slow network, it's a peer that never
  /// talks.
  PC_TLS_HANDSHAKE_TIMEOUT_DEFAULT = 15000;
  /// Removes the handshake deadline (an explicit value on purpose).
  PC_TLS_HANDSHAKE_NO_TIMEOUT = Cardinal($FFFFFFFF);

/// Splits 'host:port'. Accepts IPv6 in brackets ('[::1]:5000') and '*' as a
/// shortcut for '0.0.0.0'. The port must be 1..65535. EPcTransport when
/// malformed.
procedure PcParseHostPort(const AAddress: string; out AHost: string;
  out APort: Word);

/// 'host:port' back from parts, with brackets around an IPv6 host.
function PcFormatHostPort(const AHost: string; APort: Word): string;

/// An IPv6 address as 8 hex groups without leading zeros and without the
/// '::' compression of the canonical form: longer, but still valid and
/// reconnectable, which is enough for TryPeerAddress.
function PcFormatIPv6(const AAddr: array of Byte): string;

/// 'a.b.c.d:port' or '[v6]:port' from a raw sockaddr; AInet6Family is the
/// platform's AF_INET6. False for any other family (AF_UNIX).
function PcFormatSockAddr(const AStorage: TPcRawSockAddrStorage;
  AInet6Family: Word; out AAddress: string): Boolean;

implementation

{ TPcEndpoint }

procedure TPcEndpoint.Handshake;
begin
  // Nothing to negotiate by default.
end;

procedure TPcEndpoint.SetIoDeadline(ATimeoutMs: Cardinal);
begin
  // No deadline by default (see the declaration).
end;

procedure TPcEndpoint.SetReadDeadline(ATimeoutMs: Cardinal);
begin
  raise EPcTransport.CreateFmt('%s has no separate read deadline', [ClassName]);
end;

procedure TPcEndpoint.SetWriteDeadline(ATimeoutMs: Cardinal);
begin
  raise EPcTransport.CreateFmt('%s has no separate write deadline', [ClassName]);
end;

function TPcEndpoint.TryPeerAddress(out AAddress: string): Boolean;
begin
  AAddress := '';
  Result := False;
end;

function TPcEndpoint.HasPendingInput: Boolean;
begin
  Result := True; // never reached; keeps the compilers quiet
  raise EPcTransport.Create(ClassName + ' cannot tell whether input is pending');
end;

function TPcEndpoint.TryPeerIdentity(out AIdentity: TPcPeerIdentity): Boolean;
begin
  // A transport without TLS has no peer certificate. An OS credential
  // (SO_PEERCRED, GetNamedPipeClientProcessId) is a uid/pid, not a name, and
  // would be wrong behind this API.
  AIdentity.CommonName := '';
  AIdentity.Subject := '';
  Result := False;
end;

{ TPcTlsSession }

function TPcTlsSession.TryPeerIdentity(out AIdentity: TPcPeerIdentity): Boolean;
begin
  AIdentity.CommonName := '';
  AIdentity.Subject := '';
  Result := False;
end;

function TPcTlsSession.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := 0; // not seekable
end;

{ TPcEndpointStream }

constructor TPcEndpointStream.Create(AEndpoint: TPcEndpoint);
begin
  inherited Create;
  FEndpoint := AEndpoint;
end;

function TPcEndpointStream.Read(var Buffer; Count: Longint): Longint;
begin
  if Count <= 0 then
    Exit(0);
  Result := FEndpoint.Read(Buffer, Count);
end;

function TPcEndpointStream.Write(const Buffer; Count: Longint): Longint;
begin
  if Count > 0 then
    FEndpoint.WriteExactly(Buffer, Count);
  Result := Count;
end;

function TPcEndpointStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := 0; // not seekable
end;

{ address helpers }

procedure PcParseHostPort(const AAddress: string; out AHost: string;
  out APort: Word);
var
  LSep, LPortVal, LErr: Integer;
  LPortStr: string;
begin
  AHost := '';
  APort := 0;
  if AAddress = '' then
    raise EPcTransport.Create('empty address');
  if AAddress[1] = '[' then
  begin
    // IPv6 literal: the separator is the ':' AFTER the ']', since the address
    // itself is full of ':'.
    LSep := Pos(']', AAddress);
    if LSep = 0 then
      raise EPcTransport.CreateFmt('IPv6 address without "]": %s', [AAddress]);
    AHost := Copy(AAddress, 2, LSep - 2);
    if (Length(AAddress) <= LSep) or (AAddress[LSep + 1] <> ':') then
      raise EPcTransport.CreateFmt('address without a port: %s', [AAddress]);
    LPortStr := Copy(AAddress, LSep + 2, MaxInt);
  end
  else
  begin
    LSep := LastDelimiter(':', AAddress);
    if LSep = 0 then
      raise EPcTransport.CreateFmt(
        'address without a port: %s (expected "host:port")', [AAddress]);
    AHost := Copy(AAddress, 1, LSep - 1);
    // An unbracketed IPv6 ('::1:5000') is ambiguous: refuse it rather than
    // guess where the address ends.
    if Pos(':', AHost) > 0 then
      raise EPcTransport.CreateFmt(
        'IPv6 address without brackets: %s (expected "[addr]:port")',
        [AAddress]);
    LPortStr := Copy(AAddress, LSep + 1, MaxInt);
  end;
  if AHost = '' then
    raise EPcTransport.CreateFmt('address without a host: %s', [AAddress]);
  if AHost = '*' then
    AHost := '0.0.0.0'; // "listen on every interface"
  Val(LPortStr, LPortVal, LErr);
  if (LPortStr = '') or (LErr <> 0) or (LPortVal < 1) or (LPortVal > 65535) then
    raise EPcTransport.CreateFmt('invalid port in %s: "%s" (1..65535)',
      [AAddress, LPortStr]);
  APort := Word(LPortVal);
end;

function PcFormatHostPort(const AHost: string; APort: Word): string;
begin
  if Pos(':', AHost) > 0 then
    Result := '[' + AHost + ']:' + IntToStr(APort)
  else
    Result := AHost + ':' + IntToStr(APort);
end;

function PcFormatIPv6(const AAddr: array of Byte): string;
var
  I: Integer;
  LGroup: Word;
begin
  Result := '';
  for I := 0 to 7 do
  begin
    LGroup := (Word(AAddr[I * 2]) shl 8) or AAddr[I * 2 + 1];
    if I > 0 then
      Result := Result + ':';
    Result := Result + LowerCase(IntToHex(LGroup, 1));
  end;
end;

function PcFormatSockAddr(const AStorage: TPcRawSockAddrStorage;
  AInet6Family: Word; out AAddress: string): Boolean;
begin
  AAddress := '';
  Result := True;
  if AStorage.Family = PC_AF_INET then
    AAddress := Format('%d.%d.%d.%d:%d',
      [AStorage.V4.sin_addr[0], AStorage.V4.sin_addr[1],
       AStorage.V4.sin_addr[2], AStorage.V4.sin_addr[3],
       Swap(AStorage.V4.sin_port)])
  else if AStorage.Family = AInet6Family then
    AAddress := Format('[%s]:%d',
      [PcFormatIPv6(AStorage.V6.sin6_addr), Swap(AStorage.V6.sin6_port)])
  else
    Result := False;
end;

end.
