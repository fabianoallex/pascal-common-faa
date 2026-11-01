unit PascalCommon.Transport.OpenSSL;

{$I pascalcommon.inc}

{ The OpenSSL TLS backend (libssl/libcrypto, loaded at run time): a
  TPcTlsSession over a raw byte stream, client and server, with client
  certificates (mTLS), a private CA and the hostname or IP check. The only
  backend off Windows; on Windows it is chosen with TPcTlsOptions.Backend
  (docs/transport-design.md, T3).

  It came from pascal-pipes-faa's Pipes.Transport.OpenSSL, translated. Its
  bindings are declared here against the public ABI, for symbols with the
  same signature in 1.1.1 and 3.x. The libraries are loaded on the first TLS
  use, trying versioned names in order (3.x first): a program gets no link
  dependency, pays nothing until it uses TLS through this backend, and when
  the library is missing the error says so at that point.

  The engine works over a PAIR OF MEMORY BIOs, never over the socket:
  - The raw bytes still go through the raw stream (a TPcEndpointStream), so
    CloseAbort and the IO deadline of the endpoint below work as in plain
    TCP, on every OS.
  - An SSL object doesn't take concurrent SSL_read/SSL_write, and a reader
    thread reads while writers write. With memory BIOs no SSL_* call blocks,
    so FLock protects the SSL object and is NEVER held during socket IO: the
    ciphertext produced is drained under FLock and sent after releasing it,
    in order thanks to FSendLock (always taken before FLock).

  Changes from pipes:
  - One class for both sides; a server's SSL_CTX is built once when
    listening (certificate and key errors show up at Listen, as on SChannel)
    and shared by its sessions; SSL_new takes a reference to it, so the
    credentials may be freed before the sessions.
  - Failures of the raw stream (EPcTransportClosed, EPcTransportTimeout) pass
    through Read and Write; pipes turned every failure into EOF, which hid a
    deadline or a CloseAbort behind "closed by the peer".

  Kept from pipes, with its reasons:
  - IP versus name: an IP literal is checked with X509_VERIFY_PARAM_set1_ip_asc
    (SANs of type iPAddress); SSL_set1_host only looks at DNS SANs. 3.x
    accepts an IP in set1_host and hides the difference; 1.1.1 refused a
    certificate with IP:127.0.0.1 in its SAN (X509_V_ERR_HOSTNAME_MISMATCH,
    found by pipes on Android). set1_ip_asc returns 0 for a non-IP, which is
    the detector: IP first, then the name.
  - SSL_get_peer_certificate was renamed SSL_get1_peer_certificate in 3.x
    (a macro hides it in C, not for a run-time lookup): both are tried.
  - Android (Delphi): one library pair without a version suffix (the APK
    installer only extracts lib*.so), and the system's CA directories, since
    the compiled-in OPENSSLDIR doesn't exist on a device. Not tested here
    (this library has no Android tests, T4); pipes' device tests cover it.

  PKCS12 isn't used (a certificate of one's own is a PEM pair here, T7), so
  OpenSSL 3's default-provider trap doesn't apply yet. }

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  PascalCommon.Transport;

/// Loads libssl/libcrypto if not loaded yet. False with the reason when they
/// can't be found or lack a symbol; never raises.
function PcOpenSslAvailable(out AError: string): Boolean;

/// The loaded OpenSSL ('OpenSSL 3.0.13 30 Jan 2024 (libssl-3-x64.dll)'), or
/// '' before the first load.
function PcOpenSslInfo: string;

/// A client session over ARaw, not negotiated yet. ATargetName goes in SNI
/// and is checked against the certificate (as an IP when it is one). Loads
/// the library and reads CaFile and CertFile/KeyFile (PEM) now. Owns ARaw,
/// also when this raises.
function PcOpenSslClientSession(ARaw: TStream; const ATargetName: string;
  const AOptions: TPcTlsOptions): TPcTlsSession;

/// A server's credentials: CertFile + KeyFile (PEM) and, for mTLS, CaFile.
function PcOpenSslServerCredentials(
  const AOptions: TPcTlsOptions): TPcTlsServerCredentials;

implementation

{$IFDEF FPC}
uses
  dynlibs;
{$ELSE}
  {$IFDEF MSWINDOWS}
uses
  Windows;
  {$ENDIF}
{$ENDIF}

type
  // C 'long': 32 bits on Windows (LLP64), pointer-sized on Unix (LP64).
  {$IFDEF PASCALCOMMON_WINDOWS}
  TSslLong = LongInt;
  TSslULong = LongWord;
  {$ELSE}
  TSslLong = NativeInt;
  TSslULong = NativeUInt;
  {$ENDIF}

  TSslLibHandle = {$IFDEF FPC}TLibHandle{$ELSE}HMODULE{$ENDIF};

const
  // (libcrypto, libssl) pairs, in order. Both handles are loaded explicitly:
  // on Windows GetProcAddress doesn't see dependencies (ERR_*/BIO_* live in
  // libcrypto). A DLL of the wrong architecture just fails to load.
  {$IFDEF PASCALCOMMON_WINDOWS}
  SSL_LIB_PAIRS: array[0..3, 0..1] of string = (
    ('libcrypto-3-x64.dll', 'libssl-3-x64.dll'),
    ('libcrypto-3.dll', 'libssl-3.dll'),
    ('libcrypto-1_1-x64.dll', 'libssl-1_1-x64.dll'),
    ('libcrypto-1_1.dll', 'libssl-1_1.dll'));
  {$ELSE}
    {$IFDEF ANDROID}
  SSL_LIB_PAIRS: array[0..0, 0..1] of string = (
    ('libcrypto.so', 'libssl.so'));
    {$ELSE}
  SSL_LIB_PAIRS: array[0..2, 0..1] of string = (
    ('libcrypto.so.3', 'libssl.so.3'),
    ('libcrypto.so.1.1', 'libssl.so.1.1'),
    ('libcrypto.so', 'libssl.so'));
    {$ENDIF}
  {$ENDIF}

  SSL_ERROR_WANT_READ = 2;
  SSL_ERROR_WANT_WRITE = 3;
  SSL_ERROR_ZERO_RETURN = 6;
  SSL_VERIFY_NONE = 0;
  SSL_VERIFY_PEER = 1;
  // Without it a server ASKS for a certificate but accepts a client with
  // none: mTLS that authenticates nothing.
  SSL_VERIFY_FAIL_IF_NO_PEER_CERT = 2;
  SSL_CTRL_SET_TLSEXT_HOSTNAME = 55;
  SSL_CTRL_SET_MIN_PROTO_VERSION = 123;
  TLSEXT_NAMETYPE_HOST_NAME = 0;
  TLS1_2_VERSION = $0303;
  SSL_FILETYPE_PEM = 1;
  X509_V_OK = 0;
  NID_commonName = 13;
  RAW_CHUNK = 16384;

var
  p_TLS_client_method: function: Pointer; cdecl;
  p_TLS_server_method: function: Pointer; cdecl;
  p_SSL_CTX_new: function(AMeth: Pointer): Pointer; cdecl;
  p_SSL_CTX_free: procedure(ACtx: Pointer); cdecl;
  p_SSL_CTX_ctrl: function(ACtx: Pointer; ACmd: Integer; ALarg: TSslLong;
    AParg: Pointer): TSslLong; cdecl;
  p_SSL_CTX_set_verify: procedure(ACtx: Pointer; AMode: Integer;
    ACallback: Pointer); cdecl;
  p_SSL_CTX_set_default_verify_paths: function(ACtx: Pointer): Integer; cdecl;
  p_SSL_CTX_load_verify_locations: function(ACtx: Pointer;
    ACAfile, ACApath: PAnsiChar): Integer; cdecl;
  p_SSL_CTX_use_certificate_chain_file: function(ACtx: Pointer;
    AFile: PAnsiChar): Integer; cdecl;
  p_SSL_CTX_use_PrivateKey_file: function(ACtx: Pointer; AFile: PAnsiChar;
    AType: Integer): Integer; cdecl;
  p_SSL_CTX_check_private_key: function(ACtx: Pointer): Integer; cdecl;
  p_SSL_new: function(ACtx: Pointer): Pointer; cdecl;
  p_SSL_free: procedure(ASsl: Pointer); cdecl;
  p_SSL_ctrl: function(ASsl: Pointer; ACmd: Integer; ALarg: TSslLong;
    AParg: Pointer): TSslLong; cdecl;
  p_SSL_set1_host: function(ASsl: Pointer; AHost: PAnsiChar): Integer; cdecl;
  p_SSL_get0_param: function(ASsl: Pointer): Pointer; cdecl;
  p_X509_VERIFY_PARAM_set1_ip_asc: function(AParam: Pointer;
    AIpAsc: PAnsiChar): Integer; cdecl;
  p_SSL_set_bio: procedure(ASsl: Pointer; ARbio, AWbio: Pointer); cdecl;
  p_SSL_set_connect_state: procedure(ASsl: Pointer); cdecl;
  p_SSL_set_accept_state: procedure(ASsl: Pointer); cdecl;
  p_SSL_do_handshake: function(ASsl: Pointer): Integer; cdecl;
  p_SSL_read: function(ASsl: Pointer; ABuf: Pointer; ANum: Integer): Integer; cdecl;
  p_SSL_write: function(ASsl: Pointer; ABuf: Pointer; ANum: Integer): Integer; cdecl;
  p_SSL_get_error: function(ASsl: Pointer; ARet: Integer): Integer; cdecl;
  p_SSL_shutdown: function(ASsl: Pointer): Integer; cdecl;
  p_SSL_get_verify_result: function(ASsl: Pointer): TSslLong; cdecl;
  p_SSL_get_peer_certificate: function(ASsl: Pointer): Pointer; cdecl;
  p_BIO_new: function(AMethod: Pointer): Pointer; cdecl;
  p_BIO_s_mem: function: Pointer; cdecl;
  p_BIO_free: function(ABio: Pointer): Integer; cdecl;
  p_BIO_read: function(ABio: Pointer; ABuf: Pointer; ALen: Integer): Integer; cdecl;
  p_BIO_write: function(ABio: Pointer; ABuf: Pointer; ALen: Integer): Integer; cdecl;
  p_BIO_ctrl_pending: function(ABio: Pointer): NativeUInt; cdecl;
  p_ERR_get_error: function: TSslULong; cdecl;
  p_ERR_error_string_n: procedure(AErr: TSslULong; ABuf: PAnsiChar;
    ALen: NativeUInt); cdecl;
  p_ERR_clear_error: procedure; cdecl;
  p_X509_free: procedure(ACert: Pointer); cdecl;
  p_X509_get_subject_name: function(ACert: Pointer): Pointer; cdecl;
  p_X509_NAME_get_text_by_NID: function(AName: Pointer; ANid: Integer;
    ABuf: PAnsiChar; ALen: Integer): Integer; cdecl;
  p_X509_NAME_oneline: function(AName: Pointer; ABuf: PAnsiChar;
    ALen: Integer): PAnsiChar; cdecl;
  p_OpenSSL_version: function(AType: Integer): PAnsiChar; cdecl; // optional

  // One load per process; the libraries are never unloaded. The lock is
  // created in initialization (never lazily).
  GLibLock: TCriticalSection;
  GLibLoaded: Boolean;
  GLibInfo: string;

function SslLoadLib(const AName: string): TSslLibHandle;
begin
  {$IFDEF FPC}
  Result := dynlibs.LoadLibrary(AName);
  {$ELSE}
  Result := LoadLibrary(PChar(AName));
  {$ENDIF}
end;

procedure SslFreeLib(AHandle: TSslLibHandle);
begin
  {$IFDEF FPC}
  dynlibs.FreeLibrary(AHandle);
  {$ELSE}
  FreeLibrary(AHandle);
  {$ENDIF}
end;

function SslGetProc(AHandle: TSslLibHandle; const AName: string): Pointer;
begin
  {$IFDEF FPC}
  Result := GetProcedureAddress(AHandle, AName);
  {$ELSE}
    {$IFDEF MSWINDOWS}
  // Winapi.Windows.GetProcAddress takes an LPCSTR; symbol names are ASCII.
  Result := GetProcAddress(AHandle, PAnsiChar(AnsiString(AName)));
    {$ELSE}
  Result := GetProcAddress(AHandle, PChar(AName));
    {$ENDIF}
  {$ENDIF}
end;

function SslMustGet(AHandle: TSslLibHandle; const AName, ALib: string): Pointer;
begin
  Result := SslGetProc(AHandle, AName);
  if Result = nil then
    raise EPcTls.CreateFmt('symbol %s not found in %s (incompatible OpenSSL?)',
      [AName, ALib]);
end;

procedure EnsureOpenSsl;
var
  I: Integer;
  LCrypto, LSsl: TSslLibHandle;
  LCryptoName, LSslName, LTried: string;
begin
  // No fast path outside the lock: called once per TLS connection, and a
  // double check without a barrier isn't safe on weakly ordered CPUs.
  GLibLock.Enter;
  try
    if GLibLoaded then
      Exit;
    LCrypto := 0;
    LSsl := 0;
    LSslName := '';
    LCryptoName := '';
    LTried := '';
    for I := Low(SSL_LIB_PAIRS) to High(SSL_LIB_PAIRS) do
    begin
      if LTried <> '' then
        LTried := LTried + ', ';
      LTried := LTried + SSL_LIB_PAIRS[I][1];
      LCrypto := SslLoadLib(SSL_LIB_PAIRS[I][0]);
      if LCrypto = 0 then
        Continue;
      LSsl := SslLoadLib(SSL_LIB_PAIRS[I][1]);
      if LSsl = 0 then
      begin
        SslFreeLib(LCrypto);
        LCrypto := 0;
        Continue;
      end;
      LCryptoName := SSL_LIB_PAIRS[I][0];
      LSslName := SSL_LIB_PAIRS[I][1];
      Break;
    end;
    if LSslName = '' then
      raise EPcTls.CreateFmt('OpenSSL not found (tried: %s). Install ' +
        'libssl/libcrypto, or use another TLS backend.', [LTried]);
    try
      p_TLS_client_method := SslMustGet(LSsl, 'TLS_client_method', LSslName);
      p_TLS_server_method := SslMustGet(LSsl, 'TLS_server_method', LSslName);
      p_SSL_CTX_new := SslMustGet(LSsl, 'SSL_CTX_new', LSslName);
      p_SSL_CTX_free := SslMustGet(LSsl, 'SSL_CTX_free', LSslName);
      p_SSL_CTX_ctrl := SslMustGet(LSsl, 'SSL_CTX_ctrl', LSslName);
      p_SSL_CTX_set_verify := SslMustGet(LSsl, 'SSL_CTX_set_verify', LSslName);
      p_SSL_CTX_set_default_verify_paths :=
        SslMustGet(LSsl, 'SSL_CTX_set_default_verify_paths', LSslName);
      p_SSL_CTX_load_verify_locations :=
        SslMustGet(LSsl, 'SSL_CTX_load_verify_locations', LSslName);
      p_SSL_CTX_use_certificate_chain_file :=
        SslMustGet(LSsl, 'SSL_CTX_use_certificate_chain_file', LSslName);
      p_SSL_CTX_use_PrivateKey_file :=
        SslMustGet(LSsl, 'SSL_CTX_use_PrivateKey_file', LSslName);
      p_SSL_CTX_check_private_key :=
        SslMustGet(LSsl, 'SSL_CTX_check_private_key', LSslName);
      p_SSL_new := SslMustGet(LSsl, 'SSL_new', LSslName);
      p_SSL_free := SslMustGet(LSsl, 'SSL_free', LSslName);
      p_SSL_ctrl := SslMustGet(LSsl, 'SSL_ctrl', LSslName);
      p_SSL_set1_host := SslMustGet(LSsl, 'SSL_set1_host', LSslName);
      p_SSL_get0_param := SslMustGet(LSsl, 'SSL_get0_param', LSslName);
      p_SSL_set_bio := SslMustGet(LSsl, 'SSL_set_bio', LSslName);
      p_SSL_set_connect_state := SslMustGet(LSsl, 'SSL_set_connect_state', LSslName);
      p_SSL_set_accept_state := SslMustGet(LSsl, 'SSL_set_accept_state', LSslName);
      p_SSL_do_handshake := SslMustGet(LSsl, 'SSL_do_handshake', LSslName);
      p_SSL_read := SslMustGet(LSsl, 'SSL_read', LSslName);
      p_SSL_write := SslMustGet(LSsl, 'SSL_write', LSslName);
      p_SSL_get_error := SslMustGet(LSsl, 'SSL_get_error', LSslName);
      p_SSL_shutdown := SslMustGet(LSsl, 'SSL_shutdown', LSslName);
      p_SSL_get_verify_result := SslMustGet(LSsl, 'SSL_get_verify_result', LSslName);
      // 3.x renamed it; 1.1 only has the old name. One of them must exist,
      // or the peer's identity would silently be empty under mTLS.
      p_SSL_get_peer_certificate := SslGetProc(LSsl, 'SSL_get1_peer_certificate');
      if not Assigned(p_SSL_get_peer_certificate) then
        p_SSL_get_peer_certificate :=
          SslMustGet(LSsl, 'SSL_get_peer_certificate', LSslName);
      p_X509_VERIFY_PARAM_set1_ip_asc :=
        SslMustGet(LCrypto, 'X509_VERIFY_PARAM_set1_ip_asc', LCryptoName);
      p_BIO_new := SslMustGet(LCrypto, 'BIO_new', LCryptoName);
      p_BIO_s_mem := SslMustGet(LCrypto, 'BIO_s_mem', LCryptoName);
      p_BIO_free := SslMustGet(LCrypto, 'BIO_free', LCryptoName);
      p_BIO_read := SslMustGet(LCrypto, 'BIO_read', LCryptoName);
      p_BIO_write := SslMustGet(LCrypto, 'BIO_write', LCryptoName);
      p_BIO_ctrl_pending := SslMustGet(LCrypto, 'BIO_ctrl_pending', LCryptoName);
      p_ERR_get_error := SslMustGet(LCrypto, 'ERR_get_error', LCryptoName);
      p_ERR_error_string_n := SslMustGet(LCrypto, 'ERR_error_string_n', LCryptoName);
      p_ERR_clear_error := SslMustGet(LCrypto, 'ERR_clear_error', LCryptoName);
      p_X509_free := SslMustGet(LCrypto, 'X509_free', LCryptoName);
      p_X509_get_subject_name :=
        SslMustGet(LCrypto, 'X509_get_subject_name', LCryptoName);
      p_X509_NAME_get_text_by_NID :=
        SslMustGet(LCrypto, 'X509_NAME_get_text_by_NID', LCryptoName);
      p_X509_NAME_oneline := SslMustGet(LCrypto, 'X509_NAME_oneline', LCryptoName);
      p_OpenSSL_version := SslGetProc(LCrypto, 'OpenSSL_version');
    except
      // A symbol is missing: unload, so each new attempt doesn't pile up a
      // load reference.
      SslFreeLib(LSsl);
      SslFreeLib(LCrypto);
      raise;
    end;
    if Assigned(p_OpenSSL_version) then
      GLibInfo := Format('%s (%s)',
        [string(AnsiString(p_OpenSSL_version(0))), LSslName])
    else
      GLibInfo := Format('OpenSSL (%s)', [LSslName]);
    GLibLoaded := True;
  finally
    GLibLock.Leave;
  end;
end;

function PcOpenSslAvailable(out AError: string): Boolean;
begin
  AError := '';
  try
    EnsureOpenSsl;
    Result := True;
  except
    on E: Exception do
    begin
      AError := E.Message;
      Result := False;
    end;
  end;
end;

function PcOpenSslInfo: string;
begin
  GLibLock.Enter;
  try
    Result := GLibInfo;
  finally
    GLibLock.Leave;
  end;
end;

// The most recent error in OpenSSL's queue ('' when empty).
function LastSslErrorText: string;
var
  LCode: TSslULong;
  LBuf: array[0..255] of AnsiChar;
begin
  Result := '';
  LCode := p_ERR_get_error();
  if LCode = 0 then
    Exit;
  LBuf[0] := #0;
  p_ERR_error_string_n(LCode, @LBuf[0], SizeOf(LBuf));
  Result := string(AnsiString(PAnsiChar(@LBuf[0])));
end;

function SslFailureText(AErr: Integer): string;
begin
  Result := LastSslErrorText;
  if Result = '' then
    Result := Format('SSL_get_error=%d', [AErr]);
end;

// Points the context at the SYSTEM trust store (CaFile empty). On Android the
// compiled-in OPENSSLDIR doesn't exist on a device; the system's CAs live in
// one of these hashed directories (the APEX one on Android 14+).
function ApplyDefaultTrustStore(ACtx: Pointer): Boolean;
{$IFDEF ANDROID}
const
  ANDROID_CA_DIRS: array[0..1] of string = (
    '/apex/com.android.conscrypt/cacerts',
    '/system/etc/security/cacerts');
var
  I: Integer;
  LDir: AnsiString;
{$ENDIF}
begin
  {$IFDEF ANDROID}
  for I := Low(ANDROID_CA_DIRS) to High(ANDROID_CA_DIRS) do
  begin
    // DirectoryExists isn't redundant: a directory lookup is registered (and
    // returns 1) even when the directory doesn't exist.
    if not DirectoryExists(ANDROID_CA_DIRS[I]) then
      Continue;
    LDir := AnsiString(ANDROID_CA_DIRS[I]);
    if p_SSL_CTX_load_verify_locations(ACtx, nil, PAnsiChar(LDir)) = 1 then
      Exit(True);
  end;
  {$ENDIF}
  Result := p_SSL_CTX_set_default_verify_paths(ACtx) = 1;
end;

// Certificate + key into a context: a server's identity, or a client's
// certificate for mTLS.
procedure LoadIdentity(ACtx: Pointer; const AOptions: TPcTlsOptions);
var
  LCert, LKey: AnsiString;
begin
  if AOptions.KeyFile = '' then
    raise EPcTls.CreateFmt('certificate %s has no KeyFile (OpenSSL takes a ' +
      'PEM certificate and key)', [AOptions.CertFile]);
  LCert := AnsiString(AOptions.CertFile);
  LKey := AnsiString(AOptions.KeyFile);
  if p_SSL_CTX_use_certificate_chain_file(ACtx, PAnsiChar(LCert)) <> 1 then
    raise EPcTls.CreateFmt('could not load certificate %s (%s)',
      [AOptions.CertFile, LastSslErrorText]);
  if p_SSL_CTX_use_PrivateKey_file(ACtx, PAnsiChar(LKey),
       SSL_FILETYPE_PEM) <> 1 then
    raise EPcTls.CreateFmt('could not load key %s (%s)',
      [AOptions.KeyFile, LastSslErrorText]);
  // A swapped pair would only fail in the handshake, far from the cause.
  if p_SSL_CTX_check_private_key(ACtx) <> 1 then
    raise EPcTls.CreateFmt('key %s does not match certificate %s (%s)',
      [AOptions.KeyFile, AOptions.CertFile, LastSslErrorText]);
end;

procedure LoadCa(ACtx: Pointer; const ACaFile: string);
var
  LCa: AnsiString;
begin
  LCa := AnsiString(ACaFile);
  if p_SSL_CTX_load_verify_locations(ACtx, PAnsiChar(LCa), nil) <> 1 then
    raise EPcTls.CreateFmt('could not load CA %s (%s)',
      [ACaFile, LastSslErrorText]);
end;

function NewCtx(AServer: Boolean): Pointer;
begin
  if AServer then
    Result := p_SSL_CTX_new(p_TLS_server_method())
  else
    Result := p_SSL_CTX_new(p_TLS_client_method());
  if Result = nil then
    raise EPcTls.CreateFmt('SSL_CTX_new failed (%s)', [LastSslErrorText]);
  // TLS 1.2 at least, as on SChannel.
  p_SSL_CTX_ctrl(Result, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil);
end;

type
  TPcOpenSslSession = class(TPcTlsSession)
  private
    FRaw: TStream;          // owned
    FServer: Boolean;
    FCtx: Pointer;          // SSL_CTX*
    FOwnsCtx: Boolean;      // client: ours; server: the credentials'
    FSsl: Pointer;          // SSL*, owns both BIOs after SSL_set_bio
    FBioIn: Pointer;        // memory BIO: network -> SSL
    FBioOut: Pointer;       // memory BIO: SSL -> network
    FTargetName: AnsiString;
    FVerifyPeer: Boolean;   // client: check the server
    FNegotiated: Boolean;
    // Protects the SSL object; never held during socket IO.
    FLock: TCriticalSection;
    // Orders the sending of drained ciphertext (records out of order break
    // the connection). Always taken BEFORE FLock.
    FSendLock: TCriticalSection;
    // Set once at the end of Negotiate, immutable after: read without a lock.
    FPeerIdentity: TPcPeerIdentity;
    FHasPeerIdentity: Boolean;
    function DrainBioOut: TBytes;
    procedure SendRaw(const AData: TBytes);
    procedure FlushBioOutBestEffort;
    function ReadRawIntoBio: Boolean;
    procedure CreateSsl;
    procedure SetupClient;
    procedure CapturePeerIdentity;
    procedure ShutdownTls;
  public
    /// Owns ARaw. ACtx: a server context (a reference is taken by SSL_new)
    /// or nil for a client, which builds its own.
    constructor Create(ARaw: TStream; AServer: Boolean; ACtx: Pointer;
      const ATargetName: string; const AOptions: TPcTlsOptions);
    destructor Destroy; override;
    procedure Negotiate; override;
    function TryPeerIdentity(out AIdentity: TPcPeerIdentity): Boolean; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
  end;

  TPcOpenSslServerCredentials = class(TPcTlsServerCredentials)
  private
    FCtx: Pointer;
    FOptions: TPcTlsOptions;
  public
    constructor Create(const AOptions: TPcTlsOptions);
    destructor Destroy; override;
    function NewSession(ARaw: TStream): TPcTlsSession; override;
  end;

{ TPcOpenSslSession }

constructor TPcOpenSslSession.Create(ARaw: TStream; AServer: Boolean;
  ACtx: Pointer; const ATargetName: string; const AOptions: TPcTlsOptions);
begin
  inherited Create;
  FRaw := ARaw; // first: the destructor frees it if anything below raises
  FLock := TCriticalSection.Create;
  FSendLock := TCriticalSection.Create;
  FServer := AServer;
  FTargetName := AnsiString(ATargetName);
  FVerifyPeer := not AOptions.SkipServerVerification;
  if AServer then
  begin
    FCtx := ACtx;
    FOwnsCtx := False;
    CreateSsl;
    p_SSL_set_accept_state(FSsl);
  end
  else
  begin
    FCtx := NewCtx(False);
    FOwnsCtx := True;
    if FVerifyPeer then
    begin
      p_SSL_CTX_set_verify(FCtx, SSL_VERIFY_PEER, nil);
      if AOptions.CaFile <> '' then
        LoadCa(FCtx, AOptions.CaFile) // a private CA instead of the system's
      else if not ApplyDefaultTrustStore(FCtx) then
        raise EPcTls.CreateFmt('could not open the system trust store (%s)',
          [LastSslErrorText]);
    end
    else
      p_SSL_CTX_set_verify(FCtx, SSL_VERIFY_NONE, nil);
    if AOptions.CertFile <> '' then
      LoadIdentity(FCtx, AOptions); // mTLS
    CreateSsl;
    SetupClient;
  end;
end;

destructor TPcOpenSslSession.Destroy;
begin
  try
    if (FSsl <> nil) and FNegotiated then
      ShutdownTls;
  except
    // best effort
  end;
  if FSsl <> nil then
    p_SSL_free(FSsl) // frees both BIOs too
  else
  begin
    if FBioIn <> nil then
      p_BIO_free(FBioIn);
    if FBioOut <> nil then
      p_BIO_free(FBioOut);
  end;
  if FOwnsCtx and (FCtx <> nil) then
    p_SSL_CTX_free(FCtx);
  FRaw.Free;
  FSendLock.Free;
  FLock.Free;
  inherited;
end;

procedure TPcOpenSslSession.CreateSsl;
begin
  // BIOs before the SSL: if SSL_new fails, FSsl is nil and the destructor
  // frees the BIOs; SSL_set_bio (which doesn't fail) hands them to the SSL.
  FBioIn := p_BIO_new(p_BIO_s_mem());
  FBioOut := p_BIO_new(p_BIO_s_mem());
  if (FBioIn = nil) or (FBioOut = nil) then
    raise EPcTls.Create('BIO_new(BIO_s_mem) failed');
  FSsl := p_SSL_new(FCtx);
  if FSsl = nil then
    raise EPcTls.CreateFmt('SSL_new failed (%s)', [LastSslErrorText]);
  p_SSL_set_bio(FSsl, FBioIn, FBioOut);
end;

procedure TPcOpenSslSession.SetupClient;
var
  LParam: Pointer;
  LIsIp: Boolean;
begin
  if FTargetName <> '' then
  begin
    // SNI (SSL_set_tlsext_host_name is a macro over SSL_ctrl).
    p_SSL_ctrl(FSsl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_HOST_NAME,
      PAnsiChar(FTargetName));
    if FVerifyPeer then
    begin
      // IP first, then the name (see the unit's header).
      LParam := p_SSL_get0_param(FSsl);
      LIsIp := (LParam <> nil)
        and (p_X509_VERIFY_PARAM_set1_ip_asc(LParam, PAnsiChar(FTargetName)) = 1);
      if not LIsIp then
        if p_SSL_set1_host(FSsl, PAnsiChar(FTargetName)) <> 1 then
          raise EPcTls.Create('SSL_set1_host failed');
    end;
  end;
  p_SSL_set_connect_state(FSsl);
end;

// Empties FBioOut. Call with FLock held; the SENDING happens outside it.
function TPcOpenSslSession.DrainBioOut: TBytes;
var
  LTotal, LN: Integer;
begin
  Result := nil;
  LTotal := 0;
  while p_BIO_ctrl_pending(FBioOut) > 0 do
  begin
    SetLength(Result, LTotal + RAW_CHUNK);
    LN := p_BIO_read(FBioOut, @Result[LTotal], RAW_CHUNK);
    if LN <= 0 then
      Break;
    Inc(LTotal, LN);
  end;
  SetLength(Result, LTotal);
end;

// Sends everything through the raw stream. Call WITHOUT FLock.
procedure TPcOpenSslSession.SendRaw(const AData: TBytes);
begin
  if Length(AData) > 0 then
    FRaw.WriteBuffer(AData[0], Length(AData));
end;

// The read path's flush (rare: an answer to a post-handshake message that
// SSL_read produced). Best effort: if a writer holds FSendLock (perhaps
// blocked in a send), its own drain takes this along; a failed send shows up
// again on the next Read/Write.
procedure TPcOpenSslSession.FlushBioOutBestEffort;
var
  LOut: TBytes;
begin
  if not FSendLock.TryEnter then
    Exit;
  try
    FLock.Enter;
    try
      LOut := DrainBioOut;
    finally
      FLock.Leave;
    end;
    try
      SendRaw(LOut);
    except
      // see above
    end;
  finally
    FSendLock.Leave;
  end;
end;

// Reads one block (blocking, WITHOUT FLock: this is where the reader waits)
// and feeds the engine. False at the end of the raw stream; its exceptions
// (closed, deadline) pass through.
function TPcOpenSslSession.ReadRawIntoBio: Boolean;
var
  LBuf: array[0..RAW_CHUNK - 1] of Byte;
  LRead: Integer;
begin
  LRead := FRaw.Read(LBuf[0], RAW_CHUNK);
  if LRead <= 0 then
    Exit(False);
  FLock.Enter;
  try
    if p_BIO_write(FBioIn, @LBuf[0], LRead) <> LRead then
      raise EPcTls.Create('BIO_write failed');
  finally
    FLock.Leave;
  end;
  Result := True;
end;

procedure TPcOpenSslSession.Negotiate;
var
  LRet, LErr: Integer;
  LVerify: TSslLong;
  LOut: TBytes;
begin
  if FNegotiated then
    Exit;
  // No other thread knows the session yet: locks only for form.
  p_ERR_clear_error();
  while True do
  begin
    FLock.Enter;
    try
      LRet := p_SSL_do_handshake(FSsl);
      LOut := DrainBioOut;
    finally
      FLock.Leave;
    end;
    SendRaw(LOut); // ClientHello, Finished, alerts...
    if LRet = 1 then
      Break;
    LErr := p_SSL_get_error(FSsl, LRet);
    case LErr of
      SSL_ERROR_WANT_READ:
        if not ReadRawIntoBio then
          raise EPcTransportClosed.Create(
            'connection closed during the TLS handshake');
      SSL_ERROR_WANT_WRITE:
        ; // already drained
    else
      begin
        LVerify := p_SSL_get_verify_result(FSsl);
        if (not FServer) and FVerifyPeer and (LVerify <> X509_V_OK) then
          raise EPcTls.CreateFmt('the server''s certificate was refused ' +
            '(X509 error %d; %s)', [Integer(LVerify), SslFailureText(LErr)]);
        if FServer and (LVerify <> X509_V_OK) then
          raise EPcTls.CreateFmt('mTLS: the client''s certificate was ' +
            'refused (X509 error %d; %s)', [Integer(LVerify), SslFailureText(LErr)]);
        raise EPcTls.CreateFmt('TLS handshake failed (%s)',
          [SslFailureText(LErr)]);
      end;
    end;
  end;
  // With SSL_VERIFY_PEER + FAIL_IF_NO_PEER_CERT on a server, getting here
  // means the client's certificate was validated against CaFile.
  if FServer then
    CapturePeerIdentity;
  FNegotiated := True;
end;

function SslNameText(AName: Pointer; ANid: Integer): string;
var
  LBuf: array[0..255] of AnsiChar;
begin
  Result := '';
  if p_X509_NAME_get_text_by_NID(AName, ANid, @LBuf[0], SizeOf(LBuf)) > 0 then
    Result := string(AnsiString(PAnsiChar(@LBuf[0])));
end;

procedure TPcOpenSslSession.CapturePeerIdentity;
var
  LCert, LName: Pointer;
  LBuf: array[0..511] of AnsiChar;
begin
  // Without mTLS the client presents nothing: no identity, not an error.
  LCert := p_SSL_get_peer_certificate(FSsl);
  if LCert = nil then
    Exit;
  try
    LName := p_X509_get_subject_name(LCert);
    if LName = nil then
      Exit;
    FPeerIdentity.CommonName := SslNameText(LName, NID_commonName);
    if p_X509_NAME_oneline(LName, @LBuf[0], SizeOf(LBuf)) <> nil then
      FPeerIdentity.Subject := string(AnsiString(PAnsiChar(@LBuf[0])));
    FHasPeerIdentity := True;
  finally
    p_X509_free(LCert); // both getter names take a reference
  end;
end;

function TPcOpenSslSession.TryPeerIdentity(
  out AIdentity: TPcPeerIdentity): Boolean;
begin
  Result := FHasPeerIdentity;
  if Result then
    AIdentity := FPeerIdentity
  else
    Result := inherited TryPeerIdentity(AIdentity);
end;

function TPcOpenSslSession.Read(var Buffer; Count: Longint): Longint;
var
  LRet, LErr: Integer;
  LHasOut: Boolean;
begin
  if Count <= 0 then
    Exit(0);
  if not FNegotiated then
    raise EPcTls.Create('TLS read before the handshake');
  while True do
  begin
    FLock.Enter;
    try
      p_ERR_clear_error();
      LRet := p_SSL_read(FSsl, @Buffer, Count);
      if LRet > 0 then
        LErr := 0
      else
        LErr := p_SSL_get_error(FSsl, LRet);
      LHasOut := p_BIO_ctrl_pending(FBioOut) > 0;
    finally
      FLock.Leave;
    end;
    if LHasOut then
      FlushBioOutBestEffort;
    if LRet > 0 then
      Exit(LRet);
    case LErr of
      SSL_ERROR_WANT_READ:
        if not ReadRawIntoBio then
          raise EPcTransportClosed.Create('connection closed by the peer');
      SSL_ERROR_ZERO_RETURN:
        Exit(0); // close_notify
    else
      raise EPcTls.CreateFmt('TLS read failed (%s)', [SslFailureText(LErr)]);
    end;
  end;
end;

function TPcOpenSslSession.Write(const Buffer; Count: Longint): Longint;
var
  LOffset, LChunk, LRet, LErr, LWaitedMs: Integer;
  P: PByte;
  LOut: TBytes;
begin
  if not FNegotiated then
    raise EPcTls.Create('TLS write before the handshake');
  P := @Buffer;
  LOffset := 0;
  while LOffset < Count do
  begin
    // A chunk and a flush per round bound FBioOut's memory.
    LChunk := Count - LOffset;
    if LChunk > RAW_CHUNK then
      LChunk := RAW_CHUNK;
    LWaitedMs := 0;
    repeat
      FSendLock.Enter;
      try
        FLock.Enter;
        try
          p_ERR_clear_error();
          LRet := p_SSL_write(FSsl, @P[LOffset], LChunk);
          if LRet <= 0 then
            LErr := p_SSL_get_error(FSsl, LRet)
          else
            LErr := 0;
          LOut := DrainBioOut;
        finally
          FLock.Leave;
        end;
        SendRaw(LOut); // outside FLock; FSendLock keeps the order
      finally
        FSendLock.Leave;
      end;
      if LRet > 0 then
        Break;
      case LErr of
        SSL_ERROR_WANT_READ:
          begin
            // The engine needs input (renegotiation, post-handshake); the
            // reader thread feeds FBioIn. Wait and retry.
            Sleep(5);
            Inc(LWaitedMs, 5);
            if LWaitedMs > 10000 then
              raise EPcTransportTimeout.Create(
                'timed out waiting for the peer during a TLS write');
          end;
        SSL_ERROR_WANT_WRITE:
          ; // drained already; retry
      else
        raise EPcTls.CreateFmt('TLS write failed (%s)', [SslFailureText(LErr)]);
      end;
    until False;
    Inc(LOffset, LRet); // a memory BIO takes everything: the whole chunk
  end;
  Result := Count;
end;

procedure TPcOpenSslSession.ShutdownTls;
var
  LOut: TBytes;
begin
  // Best effort: tell the peer (close_notify).
  FSendLock.Enter;
  try
    FLock.Enter;
    try
      p_SSL_shutdown(FSsl);
      LOut := DrainBioOut;
    finally
      FLock.Leave;
    end;
    try
      SendRaw(LOut);
    except
      // the peer may be gone
    end;
  finally
    FSendLock.Leave;
  end;
end;

{ TPcOpenSslServerCredentials }

constructor TPcOpenSslServerCredentials.Create(const AOptions: TPcTlsOptions);
begin
  inherited Create;
  FOptions := AOptions;
  FCtx := NewCtx(True);
  LoadIdentity(FCtx, AOptions);
  if AOptions.CaFile <> '' then
  begin
    // mTLS: only a client with a certificate from this CA gets in.
    LoadCa(FCtx, AOptions.CaFile);
    p_SSL_CTX_set_verify(FCtx,
      SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT, nil);
  end
  else
    p_SSL_CTX_set_verify(FCtx, SSL_VERIFY_NONE, nil);
end;

destructor TPcOpenSslServerCredentials.Destroy;
begin
  // Sessions hold their own reference (SSL_new): freeing here is safe.
  if FCtx <> nil then
    p_SSL_CTX_free(FCtx);
  inherited;
end;

function TPcOpenSslServerCredentials.NewSession(ARaw: TStream): TPcTlsSession;
begin
  Result := TPcOpenSslSession.Create(ARaw, True, FCtx, '', FOptions);
end;

{ factories }

function PcOpenSslClientSession(ARaw: TStream; const ATargetName: string;
  const AOptions: TPcTlsOptions): TPcTlsSession;
begin
  try
    EnsureOpenSsl;
  except
    ARaw.Free;
    raise;
  end;
  // From here the session owns ARaw (its destructor runs if Create raises).
  Result := TPcOpenSslSession.Create(ARaw, False, nil, ATargetName, AOptions);
end;

function PcOpenSslServerCredentials(
  const AOptions: TPcTlsOptions): TPcTlsServerCredentials;
begin
  if (AOptions.CertFile = '') or (AOptions.KeyFile = '') then
    raise EPcTls.Create('a TLS server needs a certificate and a key ' +
      '(CertFile and KeyFile, PEM, on OpenSSL)');
  EnsureOpenSsl;
  Result := TPcOpenSslServerCredentials.Create(AOptions);
end;

initialization
  GLibLock := TCriticalSection.Create;

finalization
  GLibLock.Free;

end.
