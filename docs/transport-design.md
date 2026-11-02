# TCP and TLS transport — design

Status: **released in 1.27.0 (2026-11-01, step 4).** Steps 1 to 3 done on both compilers:
this library, then pascal-pipes-faa and pascal-redis-faa moved onto it; before the release
pipes ran again on step 3's change (FPC Windows, Linux with OpenSSL 3 and 1.1.1). Next: step 5
(amqp, then kafka). Phase K0 of pascal-kafka-faa's `docs/design.md` (its decision 1, taken by the user on
2026-11-01: "vamos extrair"). The user accepted decisions T1–T8 as recommended the same day
("segue recomendados"). Where step 1 stands: "Step 1, TCP" below.

## Why

The family has three copies of a TCP + TLS layer, and pascal-kafka-faa would be the fourth.
Under this library's rule ("what at least two libraries use") the layer belongs here.

| Library | Units | Lines | Origin and scope |
|---|---|---|---|
| pascal-amqp-faa | `AMQP.Transport`, `.Tls` (SChannel), `.OpenSSL` | ~2 150 | the first one. Client and server (`TAMQPTcpListener`, `CreateServer` for the broker); `ssockets` on FPC, `System.Net.Socket` on Delphi; no socket timeouts (AMQP has heartbeats) |
| pascal-redis-faa | `Redis.Transport`, `.Tls`, `.OpenSSL` | ~1 800 | a renamed copy of amqp's (its OpenSSL unit says so), client only, plus `SO_RCVTIMEO`/`SO_SNDTIMEO`. Measured: 38 lines differ from amqp's SChannel unit and 161 from its OpenSSL unit, nearly all the server role amqp has and redis doesn't |
| pascal-pipes-faa | `Pipes.Transport` (abstract endpoint), `.Tcp`, `.Tls`, `.Schannel`, `.OpenSSL`, `.Posix`, plus Named Pipe, Unix socket and Android | ~4 800 without the local ones | written separately, later and further: raw WinSock2 / `BaseUnix` sockets with event/poll waits, a deadline per wait, `CloseAbort` from any thread, keep-alive, IPv6, `getaddrinfo`; TLS client and server, a private CA (PEM) on both backends, client certificates (mTLS), hostname and IP checks, a handshake timeout, the verified peer identity |

What pascal-kafka-faa needs from the layer: client TLS with SNI and hostname verification
(Kafka's `ssl.endpoint.identification.algorithm=https` is on by default), **a private CA**
(most self-hosted clusters use one) and **client certificates** (mTLS is one of Kafka's usual
authentication modes). It also needs a connect timeout, one thread blocked in `Read` while
others write, and `Close` from another thread to unblock that reader. Only pipes' layer has
all of it. amqp and redis have neither a private CA nor client certificates: they trust the
system store only.

## Decisions

### T1 — the base is pipes' implementation (recommended)

Take pipes' TCP, TLS, SChannel, OpenSSL and POSIX units as the starting point, translated
into English, and add what amqp and redis have that it lacks. The other way round (start from
amqp's and add the private CA, mTLS, the deadline, IPv6 and keep-alive) rewrites most of what
pipes already measured.

What amqp and redis bring in:

- amqp's server role over OpenSSL (`CreateServer` with a PEM chain and key) is already in pipes
  (`TPipeTlsListener`); nothing new there. Check that the broker's needs are covered: a
  listener on port 0 that reports its port (amqp's tests use it).
- redis's send timeout: pipes' deadline covers waits for writing too (`SetIoDeadline`). Check
  it against redis's integration test where the server stops reading.
- The gotchas each copy found, at the point where each is handled (`rtl-gotchas.md` in the
  `dual-compiler-delphi-lazarus` skill): `TCP_NODELAY` on every socket, `MSG_NOSIGNAL`,
  Delphi's socket timeouts applied only after connecting (moot with raw sockets, but its
  integration test stays), OpenSSL 3's default provider.

### T2 — the API: an abstract endpoint, a stream adapter, factories (recommended)

```pascal
type
  EPcTransport        = class(Exception);
  EPcTransportClosed  = class(EPcTransport);   // peer closed, or CloseAbort was called
  EPcTransportTimeout = class(EPcTransport);   // a wait passed its deadline
  EPcTls              = class(EPcTransport);   // handshake, certificate, library not found

  TPcEndpoint = class                          // one established connection
  public
    procedure Handshake; virtual;              // server-side TLS: on the connection's thread
    function Read(var ABuffer; ACount: Integer): Integer; virtual; abstract;
    procedure WriteExactly(const ABuffer; ACount: Integer); virtual; abstract;
    procedure CloseAbort; virtual; abstract;   // any thread, idempotent
    procedure SetIoDeadline(ATimeoutMs: Cardinal); virtual;
    function TryPeerAddress(out AAddress: string): Boolean; virtual;
    function TryPeerIdentity(out AIdentity: TPcPeerIdentity): Boolean; virtual;
  end;

  TPcListener = class
  public
    function Accept: TPcEndpoint; virtual; abstract;   // nil after Close
    procedure Close; virtual; abstract;
    function Port: Word; virtual; abstract;            // the real port after binding to 0
  end;

  TPcEndpointStream = class(TStream);                  // for frame readers; doesn't own it

function PcTcpConnect(const AHost: string; APort: Word;
  const AOptions: TPcTcpOptions): TPcEndpoint;
function PcTlsConnect(const AHost: string; APort: Word;
  const AOptions: TPcTcpOptions; const ATls: TPcTlsOptions): TPcEndpoint;
function PcTcpListen(const ABindAddress: string; APort: Word;
  const AOptions: TPcTcpOptions): TPcListener;
function PcTlsListen(const ABindAddress: string; APort: Word;
  const AOptions: TPcTcpOptions; const ATls: TPcTlsOptions): TPcListener;
function PcTlsWrap(AInner: TPcEndpoint; const AHost: string;
  const ATls: TPcTlsOptions): TPcEndpoint;             // TLS over any endpoint (pipes' Android TCP)
```

`TPcTcpOptions` holds `ConnectTimeoutMs`, `KeepAliveSeconds` and `NoDelay` (default True).
`TPcTlsOptions` is pipes' `TPipeTlsOptions` (`CertFile`, `CertPassword`, `KeyFile`, `CaFile`,
`SkipServerVerification`, `HandshakeTimeoutMs`) plus `Backend` (T3). It keeps pipes' rule that
a zeroed record is the safe one.

The base type is an abstract class, not an interface. This library freezes a public interface
within a major version but lets a class gain methods, and the endpoint will gain some (a
Kafka request timeout, for instance, may want a deadline per operation). redis and amqp read
through `TPcEndpointStream`, as they read through their socket streams today. pipes uses
`TPcEndpoint` directly.

**Where the lines fall:**

- **Here:** TCP, TLS, address parsing, the backend's name and runtime detail (the
  `XxxTlsBackendName/Info` the three libraries have).
- **In each library:** its frames, its own exceptions (T6), its retry policy (T5), pipes'
  Named Pipe, Unix socket and Android transports (T4), and the `ptLocal/ptTcp/ptTls` choice.

### T3 — the TLS backend is chosen at run time, with no compile define (recommended)

Today each library has a define (`REDIS_OPENSSL`, `AMQP_OPENSSL`, `PIPES_OPENSSL`) that swaps
SChannel for OpenSSL on Windows. A define doesn't work well in a package. A consumer's `-d`
doesn't reach `pascal_common_faa.lpk`, which Lazarus compiles with the package's own options.
One application would also need the same choice for every library.

The OpenSSL backend loads libssl/libcrypto dynamically in all three copies. Compiling it in
costs nothing until it's used. So:

- **Windows:** both backends compiled. `TPcTlsOptions.Backend`: `tbDefault` (SChannel),
  `tbSChannel`, `tbOpenSsl`.
- **Linux and other POSIX targets:** OpenSSL only. Asking for SChannel raises `EPcTls`.
- Each library keeps its define, and the define now only changes its default to `tbOpenSsl`.
  Its existing build modes keep working.
- On Windows, one test run covers both backends (today a second build is needed).

Not measured yet: whether an application that never uses OpenSSL gains a visible size or
start-up cost from the backend being linked. Measure it in the first build.

### T4 — Android stays in pipes (recommended)

This library has no Android code and no Android tests. pipes' Android TCP endpoint
(`Pipes.Transport.Android`, bionic's `getaddrinfo` quirks) stays there as a `TPcEndpoint`
subclass, and TLS reaches it through `PcTlsWrap`. Moving it later, if a second library wants
Android, is an addition.

### T5 — connect makes one attempt per address; retries stay in the libraries (recommended)

pipes' `TcpPipeConnect` retries until a deadline, because a local IPC server may still be
starting. That is policy, not transport. redis reconnects with its own backoff, and Kafka has
`reconnect.backoff.ms`. Here, `PcTcpConnect` resolves the name and tries each address
(IPv6 and IPv4, in `getaddrinfo`'s order) once, inside `ConnectTimeoutMs` as a whole. pipes
keeps its retry loop around it.

### T6 — the libraries keep their exceptions (recommended)

A consumer of redis catches `ERedisTls` and `ERedisTimeout` today, and amqp's catches
`EAMQPTls`. Each library catches `EPcTransport*` at its boundary and raises its own class with
the same message, so no catch block changes. Kafka declares its own from the start. The
messages are in English here (this library's rule), so redis's and pipes' Portuguese transport
messages change text. Message text isn't a contract, but each library's CHANGELOG says so.

### T7 — certificate formats as pipes has them, for now (recommended)

- A CA file is PEM on both backends (pipes converts it for SChannel with
  `CryptStringToBinaryA`).
- A certificate and key of one's own are a PEM pair on OpenSSL and a PFX with password on
  SChannel. That asymmetry stays in the first version and is documented.
- PFX on OpenSSL (PKCS12) can come later. It has the known trap of OpenSSL 3's default
  provider (`native-library-interop.md` in the skill).

Kafka users often hold a JKS keystore, which neither backend reads. The Kafka README explains
the `keytool`/`openssl` conversion.

### T8 — released only once two libraries run on it (recommended)

A public class here freezes within the major version. The units are written on a branch and
released (a minor version, 1.27.0 or later) only after pipes, the code's origin, and redis, the
smallest consumer, pass their whole suites on it on both compilers. A mistake in the API found
during those migrations is then still free to fix.

## Migration order

1. **This library:** the units, translated, with pipes' transport and TLS tests and its
   `tests/pki` certificates moved here as loopback tests. No Docker and no external server
   are needed.
2. **pipes** moves to them. Its local transports subclass `TPcEndpoint`, and its old unit
   names stay one minor version as wrappers.
3. **redis** moves next. It gains a private CA and mTLS (`TRedisConnectionParams` gets
   `TlsCaFile`/`TlsCertFile`... as an addition).
4. **Release** this library (T8).
5. **amqp**, client and broker, then **kafka**, which is written on it from the start.

## Tests

- **Loopback, in process:** plain TCP and TLS client and server on port 0. Large transfers
  across many TLS records; one thread in `Read` while another writes; `CloseAbort` from a third
  thread unblocking both; the deadline on read, on write (a peer that stops reading) and on
  the handshake (a peer that sends nothing); mTLS accepted and refused; a wrong hostname
  refused; `SkipServerVerification`; IPv6 loopback where the machine has it.
- **Both backends on Windows in one run** (T3), and also crossed: an OpenSSL client against an
  SChannel server and the reverse.
- **Linux:** `tools/test_fpc_docker.sh`, OpenSSL 3 on Debian 12 (the provider trap) and on the
  newest Debian.
- **Mirrors:** DUnitX and FPCUnit through `tools/gen_fpc_mirror.py`; 0 leaks on heaptrc and
  FastMM.

## Open points to measure

- **SChannel with a reader and a writer at once.** *Closed in step 1 by serializing the
  context calls; see "Step 1, TLS".* The original question: OpenSSL's backend in all three copies has
  two locks (`FLock`, `FSendLock`) for exactly that case. No copy of the SChannel backend has
  a lock, and no copy's comments say why. amqp and pipes do read and write at the same time over
  SChannel; whether that is safe by Microsoft's rules or only hasn't failed yet is not known.
  Add a stress test in step 1 before relying on it.
- pipes' SChannel unit header still says "mTLS ... fora desta primeira versão", while its code
  has client certificates (`PFXImportCertStore`). Fix the comment on the way in. *Done: the
  header here describes what the unit does.*
- The size and start-up cost of T3.

## Step 1, TCP (2026-11-01)

Units: `PascalCommon.Transport` (the contract: exceptions, `TPcPeerIdentity`, `TPcTcpOptions`,
`TPcEndpoint`, `TPcListener`, `TPcEndpointStream`, `PcParseHostPort`/`PcFormatHostPort`/
`PcFormatIPv6`/`PcFormatSockAddr`), `PascalCommon.Transport.Tcp` (`PcTcpConnect`,
`PcTcpListen`, the WinSock endpoint and listener) and `PascalCommon.Transport.Posix` (the fd
endpoint and listener on FPC/Unix). Tests: `PascalCommon.TransportTests` (19, no socket) and
`PascalCommon.TcpTransportTests` (17, loopback on port 0). Green with 0 leaks on FPC 3.2.2
Windows and on FPC 3.2.2 Linux (Debian 12 container), also three Linux runners at once with
`--cpus=1`. Delphi 12 Win32 and Win64: 456 tests, 0 failures, 0 leaks (built in the IDE, run
from the console).
Not released, by T8: no version bump, the CHANGELOG lists it under Unreleased.

Where the code differs from T2's sketch or from pipes, and why:

- **`TPcTcpOptions.Nagle` instead of `NoDelay`.** T2 asked for `NoDelay` with default True and
  also for pipes' rule that a zeroed record is the safe one. A Boolean can't be both, so the
  field is the negative one: `Nagle = False` (zero) means TCP_NODELAY on every socket.
  `ConnectTimeoutMs = 0` means `PC_TCP_CONNECT_TIMEOUT_DEFAULT` (10 s), for the same reason.
- **`PcTcpConnect`/`PcTcpListen` live in `PascalCommon.Transport.Tcp`**, not in
  `PascalCommon.Transport`, so the contract unit has no socket API and the TLS unit can depend on
  both without a cycle. `PcTcpListen('')` and `('*')` bind `0.0.0.0`.
- **`PcParseHostPort` refuses an unbracketed IPv6 with a port** (`'::1:5000'`), which pipes read
  as host `::1`, port 5000. It is ambiguous (also a valid address with no port). pipes' wrapper
  in step 2 must keep its own behavior if any configuration relies on it.
- **The POSIX endpoint and listener take any stream fd** and are public, with an `OnAccepted`
  hook on the listener for per-socket options, so pipes' Unix socket transport can hand its
  AF_UNIX fd to them in step 2 instead of keeping a copy.
- **POSIX: `MSG_DONTWAIT` on `recv`/`send`.** Without it the write deadline never fired on a
  large write (gotcha 15): a bug pipes also has.
- **Windows: one wake event per direction.** pipes' reader and writer share the socket's one
  WSAEVENT, and `WSAEnumNetworkEvents` resets it. An `FD_WRITE` that lands between a writer's
  `WSAEWOULDBLOCK` and its wait can be taken by a reader already waiting, and the writer sleeps
  until the next network event: forever in a request-reply exchange. Whoever enumerates now
  passes the other direction's events on (`FReadWake`/`FWriteWake`). This fix is reasoned, not
  reproduced: the window is a few microseconds, and the request-reply and full-duplex tests pass
  with and without it (3 runs each, Windows). The same question for SChannel is the open point
  below.
- **WSAStartup in `initialization`**, not on first use as in pipes (this library's rule on lazy
  shared state).

Tests not yet written from the "Tests" list: everything TLS, and both backends in one run.
Connect timeout against a host that drops the SYN isn't tested: it needs an address that
blackholes, which a loopback-only suite doesn't have; the closed-port test checks that the
budget is respected (Windows retries a refused SYN on loopback for about 2 s, so with a 1 s
budget it ends as a timeout there and as a refusal on Linux).

## Step 1, TLS (2026-11-01)

Units: `PascalCommon.Transport` gained `TPcTlsBackend`, `TPcTlsOptions`, the
`PC_TLS_HANDSHAKE_*` constants and two base classes for the backends (`TPcTlsSession`, a
`TStream` over the raw bytes, and `TPcTlsServerCredentials`, loaded once per listener);
`PascalCommon.Transport.Tls` (`PcTlsConnect`, `PcTlsListen`, `PcTlsWrap`, `TPcTlsEndpoint`,
`TPcTlsListener`, `PcTlsResolveBackend`, `PcTlsBackendName`, `PcTlsBackendInfo`);
`PascalCommon.Transport.SChannel` (Windows) and `PascalCommon.Transport.OpenSSL` (everywhere).
`tests/pki` came from pipes (two files renamed into English). Tests:
`PascalCommon.TlsTransportTests`, 22 per pair of backends: tbDefault on both sides, and on
Windows also OpenSSL-OpenSSL and both crossings in the same run (88 on Windows).

Measured: FPC 3.2.2 Windows x64, 544 tests, 0 leaks (OpenSSL 3 from Git's `mingw64in`); FPC
3.2.2 Linux (Debian 12, OpenSSL 3), 478 tests, 0 leaks, also three runners at once with
`--cpus=1`; FPC 3.2.0 on Debian 11 with OpenSSL 1.1.1 (image `fpc-bullseye-ssl`), 478, 0 leaks.
Delphi 12 Win32 and Win64: 544 tests, 0 failures, 0 leaks (built in the IDE, run from the
console); the Win32 run loaded a 32-bit OpenSSL 3 found in `C:\Windows\SysWOW64`, so the
OpenSSL fixtures ran there too. Two mutations of the SChannel checks were caught: the root comparison forced to true (the
self-signed client test fails; another CA and the twin CA are refused earlier, by the chain)
and the server name left out of the SSL policy (the wrong-name test fails).

Where the code differs from pipes, and why:

- **SChannel client with a private CA.** pipes' SChannel client ignored `CaFile` (its header
  said so) and trusted only the system store, which T7 and Kafka's private CAs need. It now
  validates manually after the handshake, like the server's mTLS check: chain with the CA file as
  an additional store, no defect but an untrusted root, the root must be one of the CA file's
  certificates, then the SSL policy with the host name (`pwszServerName`). The IP SAN
  (`127.0.0.1`) matches through the policy too (measured on Windows 11).
- **The root is compared byte for byte** with the CA file's certificates, not with
  `CERT_FIND_EXISTING` (whose criterion Microsoft doesn't define; Wine's is issuer + serial).
- **`AUTHTYPE_CLIENT` is 1** (wincrypt.h). pipes passed 2 (`AUTHTYPE_SERVER`) to check a client
  certificate; it passed its tests, but it asked the wrong question.
- **SChannel: `SEC_I_INCOMPLETE_CREDENTIALS`** (the server asks for a certificate the client
  doesn't have) continues the handshake without one, so the server refuses it with `EPcTls`.
  pipes' client gave up and the server only saw a closed connection. Found by the crossed
  fixture (SChannel client, OpenSSL server).
- **SChannel concurrency, the open point below: closed by serializing.** A lock around
  `EncryptMessage`, `DecryptMessage` and the shutdown token, never held during socket IO. The
  full-duplex TLS test (4 MB each way, a reader and a writer on each endpoint, every pair of
  backends) passes; it doesn't prove the unlocked version was unsafe, and this one doesn't
  depend on knowing.
- **The raw stream's failures keep their class** through both backends: a deadline is
  `EPcTransportTimeout` and a `CloseAbort` is `EPcTransportClosed`, during the handshake and
  after. pipes' backends turned every failure into EOF ("closed by the peer").
- **`TPcTlsEndpoint.SetIoDeadline` reaches the TCP endpoint.** pipes' TLS endpoint didn't
  override it, so a deadline on a TLS connection silently did nothing.
- **Server credentials are loaded once at Listen on both backends**; on OpenSSL that is one
  `SSL_CTX` shared by the sessions (`SSL_new` takes a reference), so a wrong key or certificate
  fails at Listen, as SChannel's did. Each session holds its own reference to what it uses, so a
  listener may be freed while its connections live.
- **Read or Write on a server endpoint before `Handshake` raises `EPcTls`.**
- **The OpenSSL unit keeps pipes' Android branches** (`{$IFDEF ANDROID}`: library names and
  the system CA directories), for `PcTlsWrap` over pipes' Android endpoint (T4). Not tested
  here.

On Windows without a loadable OpenSSL, the three OpenSSL fixtures print a notice and pass;
SChannel's still run. That path wasn't exercised on this machine (both builds found an
OpenSSL). Off Windows, OpenSSL missing fails every TLS test.

Still open: T3's size and start-up cost (not measured); PFX on OpenSSL (T7, later).

## Step 2, pipes (2026-11-01)

pascal-pipes-faa runs on these units (its `docs/ARQUITETURA.md` section 26). What it keeps:
the Named Pipe and Android endpoints as `TPcEndpoint` subclasses (T4), the Unix socket built
there and handed to `TPcPosixSocketEndpoint`/`TPcPosixSocketListener` (its copy is gone), the
connect retry loop (T5) and its own exceptions through a facade that wraps the `TPcEndpoint`
and translates `EPcTransport*` (T6). Its `TlsOptions` record is now an alias of
`TPcTlsOptions`, with the backend chosen at run time; `PIPES_OPENSSL` only changes its
default (T3).

Measured on pipes: FPC 3.2.2 Windows x64, 137 unit and 170 integration tests (146 before:
its TLS suite now runs a second time with tbOpenSsl in the same run), 0 leaks; FPC 3.2.2
Linux (Debian 12, OpenSSL 3) and FPC 3.2.0 on Debian 11 (OpenSSL 1.1.1), 137 and 146, 0
leaks. Delphi 12 Win32 and Win64: 137 and 170, 0 failures, 0 leaks. The first Delphi run exposed a
pre-existing bug in pipes' reconnect counter, which the faster handshake made frequent (its
`docs/ARQUITETURA.md` 26.6.1); nothing in these units.

Found in the API while migrating, fixed here:

- **`EPcTransportRefused`.** `PcTcpConnect` raised plain `EPcTransport` both for a refused
  connect and for a name that doesn't resolve; T5's retry loop could only tell them apart by
  the message. Test: `Connect_ClosedPort_IsRefused` (a 6 s budget, longer than Windows' ~2 s
  of SYN retries on loopback).
- **`PcTlsListenOver`.** A TLS server over any `TPcListener`. `TPcTlsListener.Create` was
  public, but server credentials could only be built inside `PascalCommon.Transport.Tls`, so
  pipes' Android listener had no TLS server. Takes ownership of the inner listener, also
  when it raises. Tests: `ListenOver_AnyListener_RoundTrip`,
  `ListenOver_WithoutCertificate_RaisesAndFreesTheInner`, per pair of backends.
- **`PascalCommon.Transport.Tcp` on Delphi off Windows.** `PascalCommon.Transport.Tls` uses
  it, and its non-Windows branch is FPC-only, so pipes' Android build couldn't reach
  `PcTlsWrap`. That branch now compiles there with `PcTcpConnect`/`PcTcpListen` raising.
  Not compiled for Android (Delphi CE has no command-line build); pipes' device suite will
  show it.

Not changed, decided on pipes' side: `PcParseHostPort` keeps refusing `'::1:5000'`; pipes'
own parser still reads it as before for one minor version.

## Step 3, redis (2026-11-01)

pascal-redis-faa runs on these units (its `docs/DECISOES.md` section 53, branch
`transport-common`). `Redis.Connection` connects with `PcTcpConnect` + `PcTlsWrap` and reads
through `TPcEndpointStream`; it is the exception boundary (T6): no `EPcTransport*` leaves the
library, each becomes the `ERedis*` that already left it, with this library's message.
`TRedisParams` gained `TlsCaFile`, `TlsCertFile`, `TlsKeyFile`, `TlsCertPassword` and
`TlsBackend`; `REDIS_OPENSSL` only changes the default (T3). Redis's two TLS units are empty
wrappers for one minor version, as pipes'.

Measured on redis: FPC 3.2.2 Windows x64, 483 unit and 76 integration tests, 0 leaks, in both
build modes; FPC 3.2.2 Linux (Debian 12), the same, also three runners at once with `--cpus=1`
(18 of 18 runs). Its SmokeTest against a real Redis 7.2, which now validates the server against a
private CA and does mTLS: 170 steps over TLS on Windows (both backends in one run) and 165 on
Linux (OpenSSL 3.0). Delphi 12 Win32 and Win64, Debug (SChannel) and OpenSSL configurations:
483 and 76, 0 failures, 0 leaks, SmokeTest 170 over TLS, in all four (built in the IDE, run from
the console). This library's own Delphi suite with the three new tests: not run yet.

Found in the API while migrating, fixed here:

- **One deadline per direction (`SetReadDeadline`, `SetWriteDeadline`).** redis had
  `SO_RCVTIMEO` and `SO_SNDTIMEO` apart, and its pub/sub subscriber needs both: the reader
  waits with no deadline (silence is a channel's normal state) while a `SUBSCRIBE` written to a
  server that stopped reading must give up. `SetIoDeadline` sets one value for both directions,
  and the reader and the writer setting it in turn would race. T1 expected the shared deadline
  to cover redis's send timeout; it covers the timeout, not the split. Each value is written
  only by its direction's thread. Tests: `SetWriteDeadline_WriterGivesUpWhileTheReaderWaitsOn`
  and `SetReadDeadline_OnlyTheReadTimesOut` (TCP), `SetReadDeadline_ReadTimesOutThroughTls`
  (per pair of backends); the first fails when `SetWriteDeadline` also sets the read deadline.
  redis's integration suite has the same shape over `TRedisConnection`, and fails when the
  connection uses `SetIoDeadline` instead.

T1's check ("the integration test where the server stops reading"): redis had no such test.
It has two now, against a listener in the process that accepts and never reads (Redis 7 ships
`DEBUG SLEEP` disabled). A fixed write of 64 MB didn't block on Windows loopback, even with
the connection accepted: the tests write 16 MB chunks until the deadline fires, as
`TEndlessWriter` does here (32 MB went through in one measured run).

## Sources

- The three copies as of 2026-11-01: pascal-amqp-faa `201aba7`, pascal-redis-faa `b0c52da`,
  pascal-named-pipes-faa `e8c5397`.
- pascal-kafka-faa `docs/design.md`, decision 1 and section 4.
