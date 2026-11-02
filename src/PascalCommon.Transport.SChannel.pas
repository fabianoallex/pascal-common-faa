unit PascalCommon.Transport.SChannel;

{$I pascalcommon.inc}

{ The SChannel TLS backend (Windows SSPI, secur32.dll and crypt32.dll): a
  TPcTlsSession over a raw byte stream, client and server, with client
  certificates (mTLS) and a private CA on both sides. Windows only; the unit
  compiles empty elsewhere.

  It came from pascal-pipes-faa's Pipes.Transport.Schannel, translated. No
  external DLL: SChannel ships with Windows, which is why it is the default
  there. Neither RTL declares SSPI, so the signatures, records and constants
  are declared here from the Win32 API specification.

  Changes from pipes:
  - A client with CaFile validates the server against THAT CA, with the
    hostname check. pipes' SChannel client ignored CaFile (its header said so)
    and only trusted the system store; OpenSSL already honored it.
  - One chain check (VerifyPeerChain) for both directions: build the chain
    with the CA file as an additional store, accept no defect but an untrusted
    root, require that root to be a certificate of the CA file, then the SSL
    policy (validity, EKU, and the host name for a server).
  - The root is compared with the CA file's certificates byte for byte.
    pipes used CERT_FIND_EXISTING, whose criterion Microsoft doesn't define
    (on Windows it compares the whole certificate, measured there with the
    "twin" CA; Wine's compares issuer + serial only, which would be a bypass).
  - The policy's auth type: AUTHTYPE_CLIENT = 1 and AUTHTYPE_SERVER = 2
    (wincrypt.h). pipes passed 2 to check a CLIENT certificate.
  - A lock around EncryptMessage, DecryptMessage and the shutdown token,
    never held during socket IO. docs/transport-design.md left open whether
    one context may encrypt on one thread while another decrypts; Microsoft's
    documentation doesn't say, so the calls are serialized. The cost is a lock
    per TLS record.
  - Every session holds its own reference to the certificate and the CA store
    (CertDuplicate*), so a listener may be freed while connections live.
  - Failures of the raw stream (EPcTransportClosed, EPcTransportTimeout) pass
    through; pipes turned them into EOF.
  - A client without a certificate answers SEC_I_INCOMPLETE_CREDENTIALS by
    going on without one, so the server refuses it under mTLS (an EPcTls
    there); pipes' client gave up first, and the server only saw a closed
    connection.

  Limits, as in pipes: SCHANNEL_CRED (version 4) negotiates up to TLS 1.2
  (TLS 1.3 needs SCH_CREDENTIALS); renegotiation requested by the peer is
  refused. The client validates against the system store through
  SCH_CRED_AUTO_CRED_VALIDATION when CaFile is empty. }

interface

{$IFDEF PASCALCOMMON_WINDOWS}

uses
  SysUtils,
  Classes,
  SyncObjs,
  Windows,
  PascalCommon.Transport;

const
  PC_SCHANNEL_BACKEND_INFO = 'SChannel (SSPI, native to Windows)';

/// A client session over ARaw, not negotiated yet (Negotiate runs the
/// handshake). ATargetName is the name sent in SNI and checked against the
/// certificate. Reads CertFile/CertPassword (a PFX, mTLS) and CaFile (PEM)
/// now, so a wrong file fails here. Owns ARaw, also when this raises.
function PcSChannelClientSession(ARaw: TStream; const ATargetName: string;
  const AOptions: TPcTlsOptions): TPcTlsSession;

/// A server's credentials: CertFile + CertPassword (a PFX with the private
/// key) and, for mTLS, CaFile (PEM). Raises EPcTls when a file can't be read.
function PcSChannelServerCredentials(
  const AOptions: TPcTlsOptions): TPcTlsServerCredentials;

{$ENDIF}

implementation

{$IFDEF PASCALCOMMON_WINDOWS}

{ --- SSPI / SChannel / crypt32 declarations -------------------------------- }

type
  SECURITY_STATUS = LongInt;

  PSecHandle = ^TSecHandle;
  TSecHandle = record
    dwLower: ULONG_PTR;
    dwUpper: ULONG_PTR;
  end;
  TCredHandle = TSecHandle;
  TCtxtHandle = TSecHandle;
  PCredHandle = PSecHandle;
  PCtxtHandle = PSecHandle;

  TSecPkgContext_StreamSizes = record
    cbHeader: ULONG;
    cbTrailer: ULONG;
    cbMaximumMessage: ULONG;
    cBuffers: ULONG;
    cbBlockSize: ULONG;
  end;

  TSecTimeStamp = Int64; // only received as out, ignored
  PSecTimeStamp = ^TSecTimeStamp;

  PSecBuffer = ^TSecBuffer;
  TSecBuffer = record
    cbBuffer: ULONG;
    BufferType: ULONG;
    pvBuffer: Pointer;
  end;

  PSecBufferDesc = ^TSecBufferDesc;
  TSecBufferDesc = record
    ulVersion: ULONG;
    cBuffers: ULONG;
    pBuffers: PSecBuffer;
  end;

  // SCHANNEL_CRED, version 4.
  TSChannelCred = record
    dwVersion: DWORD;
    cCreds: DWORD;
    paCred: Pointer;
    hRootStore: THandle;
    cMappers: DWORD;
    aphMappers: Pointer;
    cSupportedAlgs: DWORD;
    palgSupportedAlgs: Pointer;
    grbitEnabledProtocols: DWORD;
    dwMinimumCipherStrength: DWORD;
    dwMaximumCipherStrength: DWORD;
    dwSessionLifespan: DWORD;
    dwFlags: DWORD;
    dwCredFormat: DWORD;
  end;

  // CERT_CONTEXT (only the fields read here, in their real order).
  PCertContext = ^TCertContext;
  TCertContext = record
    dwCertEncodingType: DWORD;
    pbCertEncoded: PByte;
    cbCertEncoded: DWORD;
    pCertInfo: Pointer;
    hCertStore: THandle;
  end;

  TCryptDataBlob = record
    cbData: DWORD;
    pbData: Pointer;
  end;

  TCertTrustStatus = record
    dwErrorStatus: DWORD;
    dwInfoStatus: DWORD;
  end;

  PCertChainElement = ^TCertChainElement;
  TCertChainElement = record
    cbSize: DWORD;
    pCertContext: Pointer;
    // more fields follow; not read
  end;

  PCertSimpleChain = ^TCertSimpleChain;
  TCertSimpleChain = record
    cbSize: DWORD;
    TrustStatus: TCertTrustStatus;
    cElement: DWORD;
    rgpElement: Pointer; // ^array of PCertChainElement
  end;

  PCertChainContext = ^TCertChainContext;
  TCertChainContext = record
    cbSize: DWORD;
    TrustStatus: TCertTrustStatus;
    cChain: DWORD;
    rgpChain: Pointer;   // ^array of PCertSimpleChain
  end;

  TCertEnhKeyUsage = record
    cUsageIdentifier: DWORD;
    rgpszUsageIdentifier: Pointer;
  end;

  TCertUsageMatch = record
    dwType: DWORD;
    Usage: TCertEnhKeyUsage;
  end;

  TCertChainPara = record
    cbSize: DWORD;
    RequestedUsage: TCertUsageMatch;
  end;

  TCertChainPolicyPara = record
    cbSize: DWORD;
    dwFlags: DWORD;
    pvExtraPolicyPara: Pointer;
  end;

  TCertChainPolicyStatus = record
    cbSize: DWORD;
    dwError: DWORD;
    lChainIndex: LongInt;
    lElementIndex: LongInt;
    pvExtraPolicyStatus: Pointer;
  end;

  TSslExtraCertChainPolicyPara = record
    cbSize: DWORD;
    dwAuthType: DWORD;
    fdwChecks: DWORD;
    pwszServerName: PWideChar;
  end;

const
  UNISP_NAME = 'Microsoft Unified Security Protocol Provider';

  SECPKG_CRED_INBOUND = 1;
  SECPKG_CRED_OUTBOUND = 2;
  SECURITY_NATIVE_DREP = $10;
  SECBUFFER_VERSION = 0;
  SCHANNEL_CRED_VERSION = 4;

  SECBUFFER_EMPTY = 0;
  SECBUFFER_DATA = 1;
  SECBUFFER_TOKEN = 2;
  SECBUFFER_EXTRA = 5;
  SECBUFFER_STREAM_TRAILER = 6;
  SECBUFFER_STREAM_HEADER = 7;

  ISC_REQ_REPLAY_DETECT = $00000004;
  ISC_REQ_SEQUENCE_DETECT = $00000008;
  ISC_REQ_CONFIDENTIALITY = $00000010;
  ISC_REQ_ALLOCATE_MEMORY = $00000100;
  ISC_REQ_EXTENDED_ERROR = $00004000;
  ISC_REQ_STREAM = $00008000;
  HANDSHAKE_REQ = ISC_REQ_SEQUENCE_DETECT or ISC_REQ_REPLAY_DETECT or
    ISC_REQ_CONFIDENTIALITY or ISC_REQ_EXTENDED_ERROR or
    ISC_REQ_ALLOCATE_MEMORY or ISC_REQ_STREAM;

  ASC_REQ_MUTUAL_AUTH = $00000002;
  ASC_REQ_REPLAY_DETECT = $00000004;
  ASC_REQ_SEQUENCE_DETECT = $00000008;
  ASC_REQ_CONFIDENTIALITY = $00000010;
  ASC_REQ_ALLOCATE_MEMORY = $00000100;
  ASC_REQ_EXTENDED_ERROR = $00008000;
  ASC_REQ_STREAM = $00010000;
  ACCEPT_REQ = ASC_REQ_SEQUENCE_DETECT or ASC_REQ_REPLAY_DETECT or
    ASC_REQ_CONFIDENTIALITY or ASC_REQ_EXTENDED_ERROR or
    ASC_REQ_ALLOCATE_MEMORY or ASC_REQ_STREAM;

  SCH_CRED_NO_SYSTEM_MAPPER = $00000002;
  SCH_CRED_NO_SERVERNAME_CHECK = $00000004;
  SCH_CRED_MANUAL_CRED_VALIDATION = $00000008;
  SCH_CRED_NO_DEFAULT_CREDS = $00000010;
  SCH_CRED_AUTO_CRED_VALIDATION = $00000020;

  SECPKG_ATTR_STREAM_SIZES = 4;
  SECPKG_ATTR_REMOTE_CERT_CONTEXT = $53;

  // Error statuses have the high bit set: compare as Cardinal.
  SEC_E_OK = $00000000;
  SEC_I_CONTINUE_NEEDED = $00090312;
  SEC_I_CONTEXT_EXPIRED = $00090317;
  SEC_I_RENEGOTIATE = $00090321;
  SEC_I_INCOMPLETE_CREDENTIALS = $00090320;
  SEC_E_INCOMPLETE_MESSAGE = $80090318;
  SEC_E_NO_CREDENTIALS = $8009030E;

  SCHANNEL_SHUTDOWN = 1;

  RAW_CHUNK = 16384; // one socket read per round (a TLS record is ~16 KB)

  X509_ASN_ENCODING = 1;
  PKCS_7_ASN_ENCODING = $10000;
  CRYPT_EXPORTABLE = 1;
  CERT_KEY_PROV_INFO_PROP_ID = 2;
  CERT_STORE_PROV_MEMORY = 2;
  CERT_STORE_ADD_ALWAYS = 4;
  CRYPT_STRING_BASE64HEADER = 3; // PEM: base64 between -----BEGIN/END-----
  USAGE_MATCH_TYPE_AND = 0;
  // The one chain defect tolerated: the private CA isn't in Windows' root
  // store. The next check (the root is a certificate of the CA file) is what
  // replaces that trust, so tolerating it here loosens nothing.
  CERT_TRUST_IS_UNTRUSTED_ROOT = $00000020;
  CERT_CHAIN_POLICY_SSL = 4; // passed as MAKEINTRESOURCE, not as an OID
  CERT_CHAIN_POLICY_ALLOW_UNKNOWN_CA_FLAG = $00000010;
  AUTHTYPE_CLIENT = 1;
  AUTHTYPE_SERVER = 2;
  CERT_NAME_ATTR_TYPE = 3; // pvTypePara = the attribute's OID
  CERT_NAME_RDN_TYPE = 2;  // the whole subject as a readable DN
  szOID_COMMON_NAME = '2.5.4.3';
  szOID_PKIX_KP_SERVER_AUTH = '1.3.6.1.5.5.7.3.1';
  szOID_PKIX_KP_CLIENT_AUTH = '1.3.6.1.5.5.7.3.2';

function AcquireCredentialsHandleW(pszPrincipal, pszPackage: PWideChar;
  fCredentialUse: ULONG; pvLogonID, pAuthData, pGetKeyFn,
  pvGetKeyArgument: Pointer; phCredential: PCredHandle;
  ptsExpiry: PSecTimeStamp): SECURITY_STATUS; stdcall; external 'secur32.dll';
function InitializeSecurityContextW(phCredential: PCredHandle;
  phContext: PCtxtHandle; pszTargetName: PWideChar; fContextReq, Reserved1,
  TargetDataRep: ULONG; pInput: PSecBufferDesc; Reserved2: ULONG;
  phNewContext: PCtxtHandle; pOutput: PSecBufferDesc; pfContextAttr: PULONG;
  ptsExpiry: PSecTimeStamp): SECURITY_STATUS; stdcall; external 'secur32.dll';
function AcceptSecurityContext(phCredential: PCredHandle;
  phContext: PCtxtHandle; pInput: PSecBufferDesc; fContextReq: ULONG;
  TargetDataRep: ULONG; phNewContext: PCtxtHandle; pOutput: PSecBufferDesc;
  pfContextAttr: PULONG; ptsTimeStamp: PSecTimeStamp): SECURITY_STATUS;
  stdcall; external 'secur32.dll';
function QueryContextAttributesW(phContext: PCtxtHandle; ulAttribute: ULONG;
  pBuffer: Pointer): SECURITY_STATUS; stdcall; external 'secur32.dll';
function EncryptMessage(phContext: PCtxtHandle; fQOP: ULONG;
  pMessage: PSecBufferDesc; MessageSeqNo: ULONG): SECURITY_STATUS; stdcall;
  external 'secur32.dll';
function DecryptMessage(phContext: PCtxtHandle; pMessage: PSecBufferDesc;
  MessageSeqNo: ULONG; pfQOP: PULONG): SECURITY_STATUS; stdcall;
  external 'secur32.dll';
function ApplyControlToken(phContext: PCtxtHandle;
  pInput: PSecBufferDesc): SECURITY_STATUS; stdcall; external 'secur32.dll';
function DeleteSecurityContext(phContext: PCtxtHandle): SECURITY_STATUS;
  stdcall; external 'secur32.dll';
function FreeCredentialsHandle(phCredential: PCredHandle): SECURITY_STATUS;
  stdcall; external 'secur32.dll';
function FreeContextBuffer(pvContextBuffer: Pointer): SECURITY_STATUS;
  stdcall; external 'secur32.dll';

function PFXImportCertStore(pPFX: Pointer; szPassword: PWideChar;
  dwFlags: DWORD): THandle; stdcall; external 'crypt32.dll';
function CertEnumCertificatesInStore(hCertStore: THandle;
  pPrev: Pointer): Pointer; stdcall; external 'crypt32.dll';
function CertGetCertificateContextProperty(pCertContext: Pointer;
  dwPropId: DWORD; pvData: Pointer; var pcbData: DWORD): BOOL; stdcall;
  external 'crypt32.dll';
function CertDuplicateCertificateContext(pCertContext: Pointer): Pointer;
  stdcall; external 'crypt32.dll';
function CertFreeCertificateContext(pCertContext: Pointer): BOOL; stdcall;
  external 'crypt32.dll';
function CertDuplicateStore(hCertStore: THandle): THandle; stdcall;
  external 'crypt32.dll';
function CertCloseStore(hCertStore: THandle; dwFlags: DWORD): BOOL; stdcall;
  external 'crypt32.dll';
function CertOpenStore(lpszStoreProvider: PAnsiChar; dwEncodingType: DWORD;
  hCryptProv: THandle; dwFlags: DWORD; pvPara: Pointer): THandle; stdcall;
  external 'crypt32.dll';
function CertCreateCertificateContext(dwCertEncodingType: DWORD;
  pbCertEncoded: Pointer; cbCertEncoded: DWORD): Pointer; stdcall;
  external 'crypt32.dll';
function CertAddCertificateContextToStore(hCertStore: THandle;
  pCertContext: Pointer; dwAddDisposition: DWORD;
  ppStoreContext: Pointer): BOOL; stdcall; external 'crypt32.dll';
function CryptStringToBinaryA(pszString: PAnsiChar; cchString: DWORD;
  dwFlags: DWORD; pbBinary: Pointer; var pcbBinary: DWORD;
  pdwSkip, pdwFlags: Pointer): BOOL; stdcall; external 'crypt32.dll';
function CertGetCertificateChain(hChainEngine: THandle; pCertContext: Pointer;
  pTime: Pointer; hAdditionalStore: THandle; pChainPara: Pointer;
  dwFlags: DWORD; pvReserved: Pointer; var ppChainContext: Pointer): BOOL;
  stdcall; external 'crypt32.dll';
procedure CertFreeCertificateChain(pChainContext: Pointer); stdcall;
  external 'crypt32.dll';
// pszPolicyOID is an LPCSTR, but the built-in policies are MAKEINTRESOURCE(n):
// a small integer dressed as a pointer.
function CertVerifyCertificateChainPolicy(pszPolicyOID: Pointer;
  pChainContext: Pointer; pPolicyPara: Pointer;
  pPolicyStatus: Pointer): BOOL; stdcall; external 'crypt32.dll';
// Returns the size in CHARACTERS, the #0 included; 1 = an empty string.
function CertGetNameStringW(pCertContext: Pointer; dwType: DWORD;
  dwFlags: DWORD; pvTypePara: Pointer; pszNameString: PWideChar;
  cchNameString: DWORD): DWORD; stdcall; external 'crypt32.dll';

function StatusIs(AStatus: SECURITY_STATUS; AConst: Cardinal): Boolean; inline;
begin
  Result := Cardinal(AStatus) = AConst;
end;

function StatusFailed(AStatus: SECURITY_STATUS): Boolean; inline;
begin
  Result := AStatus < 0; // HRESULT-like
end;

{ --- certificates and stores ------------------------------------------------ }

function ReadFileBytes(const AFileName, AWhat: string): TBytes;
var
  LStream: TFileStream;
begin
  if not FileExists(AFileName) then
    raise EPcTls.CreateFmt('%s not found: %s', [AWhat, AFileName]);
  LStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, LStream.Size);
    if Length(Result) = 0 then
      raise EPcTls.CreateFmt('empty %s: %s', [AWhat, AFileName]);
    LStream.ReadBuffer(Result[0], Length(Result));
  finally
    LStream.Free;
  end;
end;

// A certificate with its private key, from a PFX. The caller frees it with
// CertFreeCertificateContext.
function LoadPfx(const AFileName, APassword: string): Pointer;
var
  LData: TBytes;
  LBlob: TCryptDataBlob;
  LStore: THandle;
  LCert, LFound: Pointer;
  LSize: DWORD;
  LPwd: UnicodeString;
begin
  LData := ReadFileBytes(AFileName, 'certificate');
  LBlob.cbData := Length(LData);
  LBlob.pbData := @LData[0];
  LPwd := UnicodeString(APassword);
  // CRYPT_EXPORTABLE: SChannel must be able to use the private key.
  LStore := PFXImportCertStore(@LBlob, PWideChar(LPwd), CRYPT_EXPORTABLE);
  if LStore = 0 then
    raise EPcTls.CreateFmt('PFXImportCertStore failed on %s (error %d): ' +
      'wrong password or damaged file', [AFileName, GetLastError]);
  try
    // A PFX often carries the whole chain; the one to use is the one with a
    // PRIVATE KEY. "The first one" may be the CA, and the handshake would
    // fail later, far from here.
    LFound := nil;
    LCert := CertEnumCertificatesInStore(LStore, nil);
    while LCert <> nil do
    begin
      LSize := 0;
      if CertGetCertificateContextProperty(LCert, CERT_KEY_PROV_INFO_PROP_ID,
           nil, LSize) then
      begin
        LFound := LCert;
        Break;
      end;
      LCert := CertEnumCertificatesInStore(LStore, LCert);
    end;
    if LFound = nil then
      raise EPcTls.CreateFmt('%s contains no certificate with a private key',
        [AFileName]);
    // Duplicated: the context must outlive the store.
    Result := CertDuplicateCertificateContext(LFound);
    // CertEnumCertificatesInStore holds LFound until the next call or until
    // freed; the loop broke out, so free it here.
    CertFreeCertificateContext(LFound);
  finally
    CertCloseStore(LStore, 0);
  end;
end;

// A memory store with the certificates of a PEM file (one or more). PEM so
// that a CA file is the same on both backends. The caller closes it.
function LoadCaStore(const AFileName: string): THandle;
const
  CBegin = '-----BEGIN CERTIFICATE-----';
  CEnd = '-----END CERTIFICATE-----';
var
  LRaw: TBytes;
  LAnsi, LBlock: AnsiString;
  LRest: string;
  LDer: TBytes;
  LDerLen: DWORD;
  LCert: Pointer;
  LStart, LStop, LCount: Integer;
begin
  LRaw := ReadFileBytes(AFileName, 'CA');
  SetString(LAnsi, PAnsiChar(@LRaw[0]), Length(LRaw));
  LRest := string(LAnsi); // PEM is ASCII
  Result := CertOpenStore(PAnsiChar(CERT_STORE_PROV_MEMORY), 0, 0, 0, nil);
  if Result = 0 then
    raise EPcTls.CreateFmt('CertOpenStore(memory) failed (error %d)',
      [GetLastError]);
  try
    LCount := 0;
    while True do
    begin
      LStart := Pos(CBegin, LRest);
      if LStart = 0 then
        Break;
      LRest := Copy(LRest, LStart, MaxInt);
      LStop := Pos(CEnd, LRest);
      if LStop = 0 then
        Break;
      LBlock := AnsiString(Copy(LRest, 1, LStop - 1 + Length(CEnd)));
      LRest := Copy(LRest, LStop + Length(CEnd), MaxInt);
      // crypt32 wants DER; CRYPT_STRING_BASE64HEADER handles the
      // -----BEGIN/END----- lines.
      LDerLen := 0;
      if not CryptStringToBinaryA(PAnsiChar(LBlock), Length(LBlock),
           CRYPT_STRING_BASE64HEADER, nil, LDerLen, nil, nil) then
        raise EPcTls.CreateFmt('%s does not look like valid PEM (error %d)',
          [AFileName, GetLastError]);
      SetLength(LDer, LDerLen);
      if not CryptStringToBinaryA(PAnsiChar(LBlock), Length(LBlock),
           CRYPT_STRING_BASE64HEADER, @LDer[0], LDerLen, nil, nil) then
        raise EPcTls.CreateFmt('could not decode %s (error %d)',
          [AFileName, GetLastError]);
      LCert := CertCreateCertificateContext(
        X509_ASN_ENCODING or PKCS_7_ASN_ENCODING, @LDer[0], LDerLen);
      if LCert = nil then
        raise EPcTls.CreateFmt('%s holds an invalid certificate (error %d)',
          [AFileName, GetLastError]);
      try
        if not CertAddCertificateContextToStore(Result, LCert,
             CERT_STORE_ADD_ALWAYS, nil) then
          raise EPcTls.CreateFmt('could not add %s to the store (error %d)',
            [AFileName, GetLastError]);
      finally
        CertFreeCertificateContext(LCert); // the store keeps its own reference
      end;
      Inc(LCount);
    end;
    if LCount = 0 then
      raise EPcTls.CreateFmt('%s holds no PEM certificate', [AFileName]);
  except
    CertCloseStore(Result, 0);
    raise;
  end;
end;

// True when AStore holds a certificate with exactly ACert's bytes.
function StoreHoldsCert(AStore: THandle; ACert: Pointer): Boolean;
var
  LCur: Pointer;
  LWant, LHave: PCertContext;
begin
  Result := False;
  LWant := PCertContext(ACert);
  LCur := CertEnumCertificatesInStore(AStore, nil);
  while LCur <> nil do
  begin
    LHave := PCertContext(LCur);
    if (LHave^.cbCertEncoded = LWant^.cbCertEncoded)
      and CompareMem(LHave^.pbCertEncoded, LWant^.pbCertEncoded,
        LWant^.cbCertEncoded) then
    begin
      CertFreeCertificateContext(LCur); // stops the enumeration
      Exit(True);
    end;
    LCur := CertEnumCertificatesInStore(AStore, LCur);
  end;
end;

// One of the certificate's names: the attribute ATypePara (an OID) or, with
// nil, the whole subject. '' when absent.
function CertName(ACert: Pointer; AType: DWORD; ATypePara: Pointer): string;
var
  LLen: DWORD;
  LBuf: array of WideChar;
begin
  Result := '';
  LLen := CertGetNameStringW(ACert, AType, 0, ATypePara, nil, 0);
  if LLen <= 1 then
    Exit;
  SetLength(LBuf, LLen);
  if CertGetNameStringW(ACert, AType, 0, ATypePara, @LBuf[0], LLen) <= 1 then
    Exit;
  {$IFDEF FPC}
  // string is AnsiString on FPC: an implicit conversion would go through the
  // system code page and lose an accented CN. UTF-8, explicitly.
  Result := UTF8Encode(WideCharToString(PWideChar(@LBuf[0])));
  {$ELSE}
  Result := WideCharToString(PWideChar(@LBuf[0]));
  {$ENDIF}
end;

{ --- the session ----------------------------------------------------------- }

type
  TPcSChannelSession = class(TPcTlsSession)
  private
    FRaw: TStream;              // owned
    FServer: Boolean;
    FCred: TCredHandle;
    FCtxt: TCtxtHandle;
    FCredValid: Boolean;
    FCtxtValid: Boolean;
    FNegotiated: Boolean;
    FStreamSizes: TSecPkgContext_StreamSizes;
    // UnicodeString on both compilers: SSPI is wide, and string is
    // AnsiString on FPC.
    FTargetName: UnicodeString;
    FVerifyPeer: Boolean;       // client: check the server
    FOwnCert: Pointer;          // own certificate (a reference of ours) or nil
    FCaStore: THandle;          // the CA file's store (a reference of ours) or 0
    // Serializes the calls that use the context (see the unit's header).
    FCtxLock: SyncObjs.TCriticalSection; // qualified: Windows has a record of that name
    // Plaintext already decrypted, waiting for Read.
    FPlain: TBytes;
    FPlainPos: Integer;
    FPlainEnd: Integer;
    // Ciphertext read and not processed yet (SECBUFFER_EXTRA included).
    FCipher: TBytes;
    FCipherLen: Integer;
    // Set once in VerifyPeerChain (server side) and never changed: that is
    // what lets another thread read it without a lock.
    FPeerIdentity: TPcPeerIdentity;
    FHasPeerIdentity: Boolean;
    procedure RecvRaw;
    procedure SendAll(APtr: Pointer; ALen: Integer);
    procedure AcquireCred;
    procedure ClientHandshake;
    procedure ServerHandshake;
    procedure QuerySizes;
    procedure VerifyPeerChain;
    procedure FillPlain;
    procedure ShutdownTls;
  public
    /// Takes ownership of ARaw, ACert and ACaStore.
    constructor Create(ARaw: TStream; AServer: Boolean;
      const ATargetName: string; AVerifyPeer: Boolean; ACert: Pointer;
      ACaStore: THandle);
    destructor Destroy; override;
    procedure Negotiate; override;
    function TryPeerIdentity(out AIdentity: TPcPeerIdentity): Boolean; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
  end;

  TPcSChannelServerCredentials = class(TPcTlsServerCredentials)
  private
    FCert: Pointer;
    FCaStore: THandle;
  public
    constructor Create(ACert: Pointer; ACaStore: THandle);
    destructor Destroy; override;
    function NewSession(ARaw: TStream): TPcTlsSession; override;
  end;

constructor TPcSChannelSession.Create(ARaw: TStream; AServer: Boolean;
  const ATargetName: string; AVerifyPeer: Boolean; ACert: Pointer;
  ACaStore: THandle);
begin
  inherited Create;
  // Ownership first: if anything below raises, the destructor frees these.
  FRaw := ARaw;
  FOwnCert := ACert;
  FCaStore := ACaStore;
  FServer := AServer;
  FTargetName := UnicodeString(ATargetName);
  FVerifyPeer := AVerifyPeer;
  FCtxLock := SyncObjs.TCriticalSection.Create;
  SetLength(FCipher, RAW_CHUNK);
end;

destructor TPcSChannelSession.Destroy;
begin
  try
    if FCtxtValid and FNegotiated then
      ShutdownTls;
  except
    // best effort
  end;
  if FCtxtValid then
    DeleteSecurityContext(@FCtxt);
  if FCredValid then
    FreeCredentialsHandle(@FCred);
  if FOwnCert <> nil then
    CertFreeCertificateContext(FOwnCert);
  if FCaStore <> 0 then
    CertCloseStore(FCaStore, 0);
  FRaw.Free;
  FCtxLock.Free;
  inherited;
end;

procedure TPcSChannelSession.Negotiate;
begin
  if FNegotiated then
    Exit;
  AcquireCred;
  if FServer then
    ServerHandshake
  else
    ClientHandshake;
  QuerySizes;
  // The handshake ends "successfully" even with a certificate we don't trust
  // (manual validation): this step is what refuses it, before FNegotiated.
  if (FServer and (FCaStore <> 0))
    or ((not FServer) and FVerifyPeer and (FCaStore <> 0)) then
    VerifyPeerChain;
  FNegotiated := True;
end;

function TPcSChannelSession.TryPeerIdentity(
  out AIdentity: TPcPeerIdentity): Boolean;
begin
  Result := FHasPeerIdentity;
  if Result then
    AIdentity := FPeerIdentity
  else
    Result := inherited TryPeerIdentity(AIdentity);
end;

procedure TPcSChannelSession.AcquireCred;
var
  LCred: TSChannelCred;
  LCertArray: array[0..0] of Pointer;
  LStatus: SECURITY_STATUS;
  LUse: ULONG;
begin
  FillChar(LCred, SizeOf(LCred), 0);
  LCred.dwVersion := SCHANNEL_CRED_VERSION;
  if FOwnCert <> nil then
  begin
    LCertArray[0] := FOwnCert;
    LCred.cCreds := 1;
    LCred.paCred := @LCertArray[0];
  end;
  if FServer then
  begin
    LUse := SECPKG_CRED_INBOUND;
    LCred.dwFlags := SCH_CRED_NO_SYSTEM_MAPPER;
    // hRootStore does NOT make SChannel validate the client's chain: it only
    // builds the list of acceptable CAs sent in the CertificateRequest.
    // VerifyPeerChain does the validation, after the handshake.
    if FCaStore <> 0 then
      LCred.hRootStore := FCaStore;
  end
  else
  begin
    LUse := SECPKG_CRED_OUTBOUND;
    if FVerifyPeer and (FCaStore = 0) then
      LCred.dwFlags := SCH_CRED_AUTO_CRED_VALIDATION // the system store
    else
      // No check, or our own after the handshake (VerifyPeerChain, which
      // also checks the name).
      LCred.dwFlags := SCH_CRED_MANUAL_CRED_VALIDATION or
        SCH_CRED_NO_SERVERNAME_CHECK;
    // Don't add SCH_CRED_NO_DEFAULT_CREDS with a certificate: it forbids
    // SChannel to present one, and the certificate would be silently ignored.
    if FOwnCert = nil then
      LCred.dwFlags := LCred.dwFlags or SCH_CRED_NO_DEFAULT_CREDS;
  end;
  // grbitEnabledProtocols = 0: SChannel chooses (up to TLS 1.2 with this
  // structure).
  LStatus := AcquireCredentialsHandleW(nil, UNISP_NAME, LUse, nil, @LCred,
    nil, nil, @FCred, nil);
  if StatusFailed(LStatus) then
    raise EPcTls.CreateFmt('AcquireCredentialsHandle failed (0x%.8x)',
      [Cardinal(LStatus)]);
  FCredValid := True;
end;

// Reads one block and appends it to FCipher. The raw stream raises on close
// or deadline; that exception passes through.
procedure TPcSChannelSession.RecvRaw;
var
  LRead: Integer;
begin
  if Length(FCipher) - FCipherLen < RAW_CHUNK then
    SetLength(FCipher, FCipherLen + RAW_CHUNK);
  LRead := FRaw.Read(FCipher[FCipherLen], RAW_CHUNK);
  if LRead <= 0 then
    raise EPcTransportClosed.Create('connection closed during TLS');
  Inc(FCipherLen, LRead);
end;

procedure TPcSChannelSession.SendAll(APtr: Pointer; ALen: Integer);
begin
  if ALen > 0 then
    FRaw.WriteBuffer(APtr^, ALen);
end;

procedure TPcSChannelSession.ClientHandshake;
var
  LInBuf: array[0..1] of TSecBuffer;
  LOutBuf: array[0..0] of TSecBuffer;
  LInDesc, LOutDesc: TSecBufferDesc;
  LAttr: ULONG;
  LStatus: SECURITY_STATUS;
  LTarget: PWideChar;
  LReadMore: Boolean;
  LExtra: Integer;
begin
  LTarget := nil;
  if FTargetName <> '' then
    LTarget := PWideChar(FTargetName);

  // First call: no input token; produces the ClientHello.
  LOutBuf[0].cbBuffer := 0;
  LOutBuf[0].BufferType := SECBUFFER_TOKEN;
  LOutBuf[0].pvBuffer := nil;
  LOutDesc.ulVersion := SECBUFFER_VERSION;
  LOutDesc.cBuffers := 1;
  LOutDesc.pBuffers := @LOutBuf[0];
  LStatus := InitializeSecurityContextW(@FCred, nil, LTarget, HANDSHAKE_REQ,
    0, SECURITY_NATIVE_DREP, nil, 0, @FCtxt, @LOutDesc, @LAttr, nil);
  if not StatusIs(LStatus, SEC_I_CONTINUE_NEEDED) then
  begin
    if LOutBuf[0].pvBuffer <> nil then
      FreeContextBuffer(LOutBuf[0].pvBuffer);
    raise EPcTls.CreateFmt('initial InitializeSecurityContext failed (0x%.8x)',
      [Cardinal(LStatus)]);
  end;
  FCtxtValid := True;
  if (LOutBuf[0].cbBuffer > 0) and (LOutBuf[0].pvBuffer <> nil) then
  begin
    try
      SendAll(LOutBuf[0].pvBuffer, LOutBuf[0].cbBuffer);
    finally
      FreeContextBuffer(LOutBuf[0].pvBuffer);
    end;
  end;

  // Feed the server's answers until SEC_E_OK. Read more only when the buffer
  // is empty or the record arrived incomplete.
  LReadMore := True;
  while True do
  begin
    if LReadMore or (FCipherLen = 0) then
      RecvRaw;
    LInBuf[0].cbBuffer := FCipherLen;
    LInBuf[0].BufferType := SECBUFFER_TOKEN;
    LInBuf[0].pvBuffer := @FCipher[0];
    LInBuf[1].cbBuffer := 0;
    LInBuf[1].BufferType := SECBUFFER_EMPTY;
    LInBuf[1].pvBuffer := nil;
    LInDesc.ulVersion := SECBUFFER_VERSION;
    LInDesc.cBuffers := 2;
    LInDesc.pBuffers := @LInBuf[0];
    LOutBuf[0].cbBuffer := 0;
    LOutBuf[0].BufferType := SECBUFFER_TOKEN;
    LOutBuf[0].pvBuffer := nil;

    LStatus := InitializeSecurityContextW(@FCred, @FCtxt, LTarget,
      HANDSHAKE_REQ, 0, SECURITY_NATIVE_DREP, @LInDesc, 0, @FCtxt, @LOutDesc,
      @LAttr, nil);

    // An output token may come even with SEC_E_OK (or with a failure: an
    // alert for the peer).
    if (LOutBuf[0].cbBuffer > 0) and (LOutBuf[0].pvBuffer <> nil) then
    begin
      try
        SendAll(LOutBuf[0].pvBuffer, LOutBuf[0].cbBuffer);
      finally
        FreeContextBuffer(LOutBuf[0].pvBuffer);
      end;
    end;

    if StatusIs(LStatus, SEC_E_INCOMPLETE_MESSAGE) then
    begin
      LReadMore := True; // keep FCipher and read more
      Continue;
    end;
    if StatusIs(LStatus, SEC_I_INCOMPLETE_CREDENTIALS) then
    begin
      // The server asked for a certificate and we have none (or none it
      // accepts). Call again with the same input: the handshake goes on
      // without one (SCH_CRED_NO_DEFAULT_CREDS), and refusing is the
      // server's call. pipes raised here, so its server never saw the
      // attempt.
      LReadMore := False;
      Continue;
    end;
    if StatusIs(LStatus, SEC_I_CONTINUE_NEEDED) or StatusIs(LStatus, SEC_E_OK) then
    begin
      // Bytes not consumed (the next record) are in SECBUFFER_EXTRA, at the
      // END of the input buffer.
      if LInBuf[1].BufferType = SECBUFFER_EXTRA then
      begin
        LExtra := LInBuf[1].cbBuffer;
        if LExtra > 0 then
          Move(FCipher[FCipherLen - LExtra], FCipher[0], LExtra);
        FCipherLen := LExtra;
      end
      else
        FCipherLen := 0;
      if StatusIs(LStatus, SEC_E_OK) then
        Break;
      LReadMore := FCipherLen = 0;
      Continue;
    end;
    raise EPcTls.CreateFmt('TLS handshake failed (0x%.8x)', [Cardinal(LStatus)]);
  end;
end;

procedure TPcSChannelSession.ServerHandshake;
var
  LInBuf: array[0..1] of TSecBuffer;
  LOutBuf: array[0..0] of TSecBuffer;
  LInDesc, LOutDesc: TSecBufferDesc;
  LAttr: ULONG;
  LStatus: SECURITY_STATUS;
  LCtxPtr: PCtxtHandle;
  LReadMore: Boolean;
  LExtra: Integer;
  LReq: ULONG;
begin
  // The server never talks first: it waits for the ClientHello.
  LReq := ACCEPT_REQ;
  if FCaStore <> 0 then
    LReq := LReq or ASC_REQ_MUTUAL_AUTH; // only then does SChannel ask for one
  LReadMore := True;
  while True do
  begin
    if LReadMore or (FCipherLen = 0) then
      RecvRaw;
    // A TLS client's first byte is a handshake record (0x16). Anything else
    // (a plaintext client on a TLS port: amqp's protocol header, an HTTP
    // request) is refused now. AcceptSecurityContext would read it as the
    // header of a record still incomplete and wait for the rest until the
    // handshake deadline (15 s, measured by pascal-amqp-faa), where OpenSSL
    // refuses at once (1.27.1).
    if (not FCtxtValid) and (FCipher[0] <> $16) then
      raise EPcTls.CreateFmt('not a TLS client: the first byte is 0x%.2x, ' +
        'not a handshake record (0x16)', [FCipher[0]]);
    LInBuf[0].cbBuffer := FCipherLen;
    LInBuf[0].BufferType := SECBUFFER_TOKEN;
    LInBuf[0].pvBuffer := @FCipher[0];
    LInBuf[1].cbBuffer := 0;
    LInBuf[1].BufferType := SECBUFFER_EMPTY;
    LInBuf[1].pvBuffer := nil;
    LInDesc.ulVersion := SECBUFFER_VERSION;
    LInDesc.cBuffers := 2;
    LInDesc.pBuffers := @LInBuf[0];
    LOutBuf[0].cbBuffer := 0;
    LOutBuf[0].BufferType := SECBUFFER_TOKEN;
    LOutBuf[0].pvBuffer := nil;
    LOutDesc.ulVersion := SECBUFFER_VERSION;
    LOutDesc.cBuffers := 1;
    LOutDesc.pBuffers := @LOutBuf[0];
    if FCtxtValid then
      LCtxPtr := @FCtxt
    else
      LCtxPtr := nil;

    LStatus := AcceptSecurityContext(@FCred, LCtxPtr, @LInDesc, LReq,
      SECURITY_NATIVE_DREP, @FCtxt, @LOutDesc, @LAttr, nil);

    if (LOutBuf[0].cbBuffer > 0) and (LOutBuf[0].pvBuffer <> nil) then
    begin
      try
        SendAll(LOutBuf[0].pvBuffer, LOutBuf[0].cbBuffer);
      finally
        FreeContextBuffer(LOutBuf[0].pvBuffer);
      end;
    end;

    if StatusIs(LStatus, SEC_E_INCOMPLETE_MESSAGE) then
    begin
      LReadMore := True;
      Continue;
    end;
    if StatusIs(LStatus, SEC_I_CONTINUE_NEEDED) or StatusIs(LStatus, SEC_E_OK) then
    begin
      FCtxtValid := True;
      if LInBuf[1].BufferType = SECBUFFER_EXTRA then
      begin
        LExtra := LInBuf[1].cbBuffer;
        if LExtra > 0 then
          Move(FCipher[FCipherLen - LExtra], FCipher[0], LExtra);
        FCipherLen := LExtra;
      end
      else
        FCipherLen := 0;
      if StatusIs(LStatus, SEC_E_OK) then
        Break;
      LReadMore := FCipherLen = 0;
      Continue;
    end;
    raise EPcTls.CreateFmt('TLS handshake (server) failed (0x%.8x)',
      [Cardinal(LStatus)]);
  end;
end;

procedure TPcSChannelSession.QuerySizes;
var
  LStatus: SECURITY_STATUS;
begin
  LStatus := QueryContextAttributesW(@FCtxt, SECPKG_ATTR_STREAM_SIZES,
    @FStreamSizes);
  if StatusFailed(LStatus) then
    raise EPcTls.CreateFmt('QueryContextAttributes(STREAM_SIZES) failed ' +
      '(0x%.8x)', [Cardinal(LStatus)]);
end;

procedure TPcSChannelSession.VerifyPeerChain;
var
  LRemote: Pointer;
  LStatus: SECURITY_STATUS;
  LUsageOid, LOidCn: AnsiString;
  LUsage: array[0..0] of PAnsiChar;
  LPara: TCertChainPara;
  LChain: Pointer;
  LCtx: PCertChainContext;
  LSimple: PCertSimpleChain;
  LElem: PCertChainElement;
  LPolicyPara: TCertChainPolicyPara;
  LSslPara: TSslExtraCertChainPolicyPara;
  LPolicyStatus: TCertChainPolicyStatus;
  LErrors: DWORD;
  LWho: string;
begin
  if FServer then
    LWho := 'mTLS: the client'
  else
    LWho := 'the server';
  // 0. The certificate the peer presented. With ASC_REQ_MUTUAL_AUTH SChannel
  // ASKS for one but completes the handshake without it: refused here.
  LRemote := nil;
  LStatus := QueryContextAttributesW(@FCtxt, SECPKG_ATTR_REMOTE_CERT_CONTEXT,
    @LRemote);
  if StatusIs(LStatus, SEC_E_NO_CREDENTIALS) or (LRemote = nil) then
    raise EPcTls.Create(LWho + ' presented no certificate');
  if StatusFailed(LStatus) then
    raise EPcTls.CreateFmt('%s''s certificate could not be read (0x%.8x)',
      [LWho, Cardinal(LStatus)]);
  try
    // 1. Build the chain. The CA file is an ADDITIONAL store: it supplies the
    // issuer but doesn't make it trusted; that is step 3.
    if FServer then
      LUsageOid := szOID_PKIX_KP_CLIENT_AUTH
    else
      LUsageOid := szOID_PKIX_KP_SERVER_AUTH;
    LOidCn := szOID_COMMON_NAME;
    LUsage[0] := PAnsiChar(LUsageOid);
    FillChar(LPara, SizeOf(LPara), 0);
    LPara.cbSize := SizeOf(LPara);
    LPara.RequestedUsage.dwType := USAGE_MATCH_TYPE_AND;
    LPara.RequestedUsage.Usage.cUsageIdentifier := 1;
    LPara.RequestedUsage.Usage.rgpszUsageIdentifier := @LUsage[0];
    LChain := nil;
    if not CertGetCertificateChain(0, LRemote, nil, FCaStore, @LPara, 0, nil,
         LChain) then
      raise EPcTls.CreateFmt('CertGetCertificateChain failed (error %d)',
        [GetLastError]);
    try
      LCtx := PCertChainContext(LChain);
      // 2. Any defect refuses: expired, revoked, bad signature, wrong usage.
      // Except "untrusted root", expected for a private CA and settled by 3.
      LErrors := LCtx^.TrustStatus.dwErrorStatus and
        (not DWORD(CERT_TRUST_IS_UNTRUSTED_ROOT));
      if LErrors <> 0 then
        raise EPcTls.CreateFmt('%s''s certificate chain is invalid ' +
          '(dwErrorStatus 0x%.8x)', [LWho, LErrors]);
      // 3. What actually authenticates: the ROOT of the chain built must be
      // a certificate of the CA file. Without it, a peer that sent its leaf
      // plus its own self-signed CA would build a sound chain with only
      // UNTRUSTED_ROOT and pass step 2.
      if LCtx^.cChain < 1 then
        raise EPcTls.Create(LWho + '''s certificate chain is empty');
      LSimple := PCertSimpleChain(PPointer(LCtx^.rgpChain)^);
      if LSimple^.cElement < 1 then
        raise EPcTls.Create(LWho + '''s certificate chain has no elements');
      LElem := PCertChainElement(PPointer(PByte(LSimple^.rgpElement) +
        (LSimple^.cElement - 1) * SizeOf(Pointer))^);
      if not StoreHoldsCert(FCaStore, LElem^.pCertContext) then
        raise EPcTls.Create(LWho + '''s certificate does not chain up to ' +
          'the configured CA');
      // 4. The SSL policy: validity, EKU and, for a server, the host name.
      // ALLOW_UNKNOWN_CA because the root's trust was settled in step 3.
      FillChar(LSslPara, SizeOf(LSslPara), 0);
      LSslPara.cbSize := SizeOf(LSslPara);
      if FServer then
        LSslPara.dwAuthType := AUTHTYPE_CLIENT
      else
      begin
        LSslPara.dwAuthType := AUTHTYPE_SERVER;
        if FTargetName <> '' then
          LSslPara.pwszServerName := PWideChar(FTargetName);
      end;
      FillChar(LPolicyPara, SizeOf(LPolicyPara), 0);
      LPolicyPara.cbSize := SizeOf(LPolicyPara);
      LPolicyPara.dwFlags := CERT_CHAIN_POLICY_ALLOW_UNKNOWN_CA_FLAG;
      LPolicyPara.pvExtraPolicyPara := @LSslPara;
      FillChar(LPolicyStatus, SizeOf(LPolicyStatus), 0);
      LPolicyStatus.cbSize := SizeOf(LPolicyStatus);
      if not CertVerifyCertificateChainPolicy(
           Pointer(NativeUInt(CERT_CHAIN_POLICY_SSL)), LChain, @LPolicyPara,
           @LPolicyStatus) then
        raise EPcTls.CreateFmt('CertVerifyCertificateChainPolicy failed ' +
          '(error %d)', [GetLastError]);
      if LPolicyStatus.dwError <> 0 then
        raise EPcTls.CreateFmt('%s''s certificate was refused by the SSL ' +
          'policy (0x%.8x)', [LWho, LPolicyStatus.dwError]);
      // Here, and only here, the identity can be trusted.
      if FServer then
      begin
        FPeerIdentity.CommonName := CertName(LRemote, CERT_NAME_ATTR_TYPE,
          PAnsiChar(LOidCn));
        FPeerIdentity.Subject := CertName(LRemote, CERT_NAME_RDN_TYPE, nil);
        FHasPeerIdentity := True;
      end;
    finally
      CertFreeCertificateChain(LChain);
    end;
  finally
    // QueryContextAttributes(REMOTE_CERT_CONTEXT) returns a reference of ours.
    CertFreeCertificateContext(LRemote);
  end;
end;

// Decrypts from FCipher until FPlain has data, or the peer's close_notify
// (FPlainEnd = 0 on return).
procedure TPcSChannelSession.FillPlain;
var
  LBuf: array[0..3] of TSecBuffer;
  LDesc: TSecBufferDesc;
  LStatus: SECURITY_STATUS;
  I, LExtra: Integer;
  LData, LExtraBuf: PSecBuffer;
begin
  while True do
  begin
    if FCipherLen = 0 then
      RecvRaw;
    LBuf[0].cbBuffer := FCipherLen;
    LBuf[0].BufferType := SECBUFFER_DATA;
    LBuf[0].pvBuffer := @FCipher[0];
    for I := 1 to 3 do
    begin
      LBuf[I].cbBuffer := 0;
      LBuf[I].BufferType := SECBUFFER_EMPTY;
      LBuf[I].pvBuffer := nil;
    end;
    LDesc.ulVersion := SECBUFFER_VERSION;
    LDesc.cBuffers := 4;
    LDesc.pBuffers := @LBuf[0];

    FCtxLock.Enter;
    try
      LStatus := DecryptMessage(@FCtxt, @LDesc, 0, nil);
    finally
      FCtxLock.Leave;
    end;

    if StatusIs(LStatus, SEC_E_INCOMPLETE_MESSAGE) then
    begin
      RecvRaw;
      Continue;
    end;
    if StatusIs(LStatus, SEC_I_CONTEXT_EXPIRED) then
    begin
      FCipherLen := 0;
      FPlainPos := 0;
      FPlainEnd := 0;
      Exit; // close_notify: end of stream
    end;
    if StatusIs(LStatus, SEC_I_RENEGOTIATE) then
      raise EPcTls.Create('TLS renegotiation requested by the peer is not ' +
        'supported');
    if not StatusIs(LStatus, SEC_E_OK) then
      raise EPcTls.CreateFmt('DecryptMessage failed (0x%.8x)',
        [Cardinal(LStatus)]);

    LData := nil;
    LExtraBuf := nil;
    for I := 0 to 3 do
      if (LBuf[I].BufferType = SECBUFFER_DATA) and (LData = nil) then
        LData := @LBuf[I]
      else if (LBuf[I].BufferType = SECBUFFER_EXTRA) and (LExtraBuf = nil) then
        LExtraBuf := @LBuf[I];
    FPlainPos := 0;
    FPlainEnd := 0;
    if (LData <> nil) and (LData^.cbBuffer > 0) then
    begin
      if Length(FPlain) < Integer(LData^.cbBuffer) then
        SetLength(FPlain, LData^.cbBuffer);
      Move(PByte(LData^.pvBuffer)^, FPlain[0], LData^.cbBuffer);
      FPlainEnd := LData^.cbBuffer;
    end;
    // The rest belongs to the next record: move it to the start.
    if LExtraBuf <> nil then
    begin
      LExtra := LExtraBuf^.cbBuffer;
      if LExtra > 0 then
        Move(PByte(LExtraBuf^.pvBuffer)^, FCipher[0], LExtra);
      FCipherLen := LExtra;
    end
    else
      FCipherLen := 0;
    if FPlainEnd > 0 then
      Exit;
    // A record without application data: decrypt the next one.
  end;
end;

function TPcSChannelSession.Read(var Buffer; Count: Longint): Longint;
var
  LAvail: Integer;
begin
  if Count <= 0 then
    Exit(0);
  if not FNegotiated then
    raise EPcTls.Create('TLS read before the handshake');
  if FPlainPos >= FPlainEnd then
  begin
    FillPlain;
    if FPlainPos >= FPlainEnd then
      Exit(0); // close_notify
  end;
  LAvail := FPlainEnd - FPlainPos;
  if LAvail > Count then
    LAvail := Count;
  Move(FPlain[FPlainPos], Buffer, LAvail);
  Inc(FPlainPos, LAvail);
  Result := LAvail;
end;

function TPcSChannelSession.Write(const Buffer; Count: Longint): Longint;
var
  LBuf: array[0..3] of TSecBuffer;
  LDesc: TSecBufferDesc;
  LStatus: SECURITY_STATUS;
  LChunk, LOffset, LTotal: Integer;
  LRec: TBytes;
  P: PByte;
begin
  if not FNegotiated then
    raise EPcTls.Create('TLS write before the handshake');
  P := @Buffer;
  LOffset := 0;
  while LOffset < Count do
  begin
    LChunk := Count - LOffset;
    if LChunk > Integer(FStreamSizes.cbMaximumMessage) then
      LChunk := Integer(FStreamSizes.cbMaximumMessage);
    // A record is header + plaintext + trailer, contiguous.
    SetLength(LRec, Integer(FStreamSizes.cbHeader) + LChunk +
      Integer(FStreamSizes.cbTrailer));
    Move(P[LOffset], LRec[FStreamSizes.cbHeader], LChunk);
    LBuf[0].cbBuffer := FStreamSizes.cbHeader;
    LBuf[0].BufferType := SECBUFFER_STREAM_HEADER;
    LBuf[0].pvBuffer := @LRec[0];
    LBuf[1].cbBuffer := LChunk;
    LBuf[1].BufferType := SECBUFFER_DATA;
    LBuf[1].pvBuffer := @LRec[FStreamSizes.cbHeader];
    LBuf[2].cbBuffer := FStreamSizes.cbTrailer;
    LBuf[2].BufferType := SECBUFFER_STREAM_TRAILER;
    LBuf[2].pvBuffer := @LRec[Integer(FStreamSizes.cbHeader) + LChunk];
    LBuf[3].cbBuffer := 0;
    LBuf[3].BufferType := SECBUFFER_EMPTY;
    LBuf[3].pvBuffer := nil;
    LDesc.ulVersion := SECBUFFER_VERSION;
    LDesc.cBuffers := 4;
    LDesc.pBuffers := @LBuf[0];
    FCtxLock.Enter;
    try
      LStatus := EncryptMessage(@FCtxt, 0, @LDesc, 0);
    finally
      FCtxLock.Leave;
    end;
    if StatusFailed(LStatus) then
      raise EPcTls.CreateFmt('EncryptMessage failed (0x%.8x)',
        [Cardinal(LStatus)]);
    // EncryptMessage adjusts the sizes; send the three, contiguous.
    LTotal := Integer(LBuf[0].cbBuffer) + Integer(LBuf[1].cbBuffer) +
      Integer(LBuf[2].cbBuffer);
    SendAll(@LRec[0], LTotal);
    Inc(LOffset, LChunk);
  end;
  Result := Count;
end;

procedure TPcSChannelSession.ShutdownTls;
var
  LToken: DWORD;
  LCtrlBuf, LOutBuf: TSecBuffer;
  LCtrlDesc, LOutDesc: TSecBufferDesc;
  LAttr: ULONG;
  LStatus: SECURITY_STATUS;
  LTarget: PWideChar;
begin
  // Best effort: tell the peer (close_notify).
  LToken := SCHANNEL_SHUTDOWN;
  LCtrlBuf.cbBuffer := SizeOf(LToken);
  LCtrlBuf.BufferType := SECBUFFER_TOKEN;
  LCtrlBuf.pvBuffer := @LToken;
  LCtrlDesc.ulVersion := SECBUFFER_VERSION;
  LCtrlDesc.cBuffers := 1;
  LCtrlDesc.pBuffers := @LCtrlBuf;
  LOutBuf.cbBuffer := 0;
  LOutBuf.BufferType := SECBUFFER_TOKEN;
  LOutBuf.pvBuffer := nil;
  LOutDesc.ulVersion := SECBUFFER_VERSION;
  LOutDesc.cBuffers := 1;
  LOutDesc.pBuffers := @LOutBuf;
  LTarget := nil;
  if FTargetName <> '' then
    LTarget := PWideChar(FTargetName);
  FCtxLock.Enter;
  try
    if StatusFailed(ApplyControlToken(@FCtxt, @LCtrlDesc)) then
      Exit;
    if FServer then
      LStatus := AcceptSecurityContext(@FCred, @FCtxt, nil, ACCEPT_REQ,
        SECURITY_NATIVE_DREP, @FCtxt, @LOutDesc, @LAttr, nil)
    else
      LStatus := InitializeSecurityContextW(@FCred, @FCtxt, LTarget,
        HANDSHAKE_REQ, 0, SECURITY_NATIVE_DREP, nil, 0, @FCtxt, @LOutDesc,
        @LAttr, nil);
  finally
    FCtxLock.Leave;
  end;
  if (LOutBuf.cbBuffer > 0) and (LOutBuf.pvBuffer <> nil) then
  begin
    try
      if not StatusFailed(LStatus) then
        SendAll(LOutBuf.pvBuffer, LOutBuf.cbBuffer);
    finally
      FreeContextBuffer(LOutBuf.pvBuffer);
    end;
  end;
end;

{ TPcSChannelServerCredentials }

constructor TPcSChannelServerCredentials.Create(ACert: Pointer;
  ACaStore: THandle);
begin
  inherited Create;
  FCert := ACert;
  FCaStore := ACaStore;
end;

destructor TPcSChannelServerCredentials.Destroy;
begin
  if FCert <> nil then
    CertFreeCertificateContext(FCert);
  if FCaStore <> 0 then
    CertCloseStore(FCaStore, 0);
  inherited;
end;

function TPcSChannelServerCredentials.NewSession(ARaw: TStream): TPcTlsSession;
var
  LCa: THandle;
begin
  LCa := 0;
  if FCaStore <> 0 then
    LCa := CertDuplicateStore(FCaStore);
  Result := TPcSChannelSession.Create(ARaw, True, '', False,
    CertDuplicateCertificateContext(FCert), LCa);
end;

{ factories }

function PcSChannelClientSession(ARaw: TStream; const ATargetName: string;
  const AOptions: TPcTlsOptions): TPcTlsSession;
var
  LCert: Pointer;
  LCa: THandle;
begin
  LCert := nil;
  LCa := 0;
  try
    // Credentials first, so a wrong password or path names its file here.
    if AOptions.CertFile <> '' then
      LCert := LoadPfx(AOptions.CertFile, AOptions.CertPassword);
    if (AOptions.CaFile <> '') and not AOptions.SkipServerVerification then
      LCa := LoadCaStore(AOptions.CaFile);
  except
    if LCert <> nil then
      CertFreeCertificateContext(LCert);
    ARaw.Free;
    raise;
  end;
  Result := TPcSChannelSession.Create(ARaw, False, ATargetName,
    not AOptions.SkipServerVerification, LCert, LCa);
end;

function PcSChannelServerCredentials(
  const AOptions: TPcTlsOptions): TPcTlsServerCredentials;
var
  LCert: Pointer;
  LCa: THandle;
begin
  if AOptions.CertFile = '' then
    raise EPcTls.Create('a TLS server needs a certificate (CertFile: a PFX ' +
      'on SChannel)');
  LCert := LoadPfx(AOptions.CertFile, AOptions.CertPassword);
  LCa := 0;
  try
    if AOptions.CaFile <> '' then
      LCa := LoadCaStore(AOptions.CaFile);
  except
    CertFreeCertificateContext(LCert);
    raise;
  end;
  Result := TPcSChannelServerCredentials.Create(LCert, LCa);
end;

{$ENDIF}

end.
