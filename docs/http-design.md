# HTTP client transport — design

Status: **step 4 done, 2026-11-10; tagged 1.31.0.** The user accepted H1–H11 on 2026-11-10 and confirmed that no
current caller needs a proxy (H3). Implemented in 1.31.0 (`PascalCommon.Http`, `.Http.Client`,
`.Http.Fake`; `EPcTextEncoding`/`PcUtf8BytesToString`; `TPcEndpoint.HasPendingInput`), with one
change to H5 found while implementing it (the check before reuse; see H5 and "Measured in step
3"). Step 4: pascal-api-infra-faa 0.33.0 runs on it through aliases (H9), with no change to the
interface here; pascal-agenda-faa passes unchanged (its suites, client check and desktop smoke
on FPC Windows). Step 5: the brief for pascal-search-faa is in that repository's `prompt/`.

## Why

`PascalApi.HttpTransport` (pascal-api-infra-faa) is one HTTP exchange behind an interface:
method, URL, headers and a text body in; status, headers and text body out. It came from
pascal-agenda-faa (0.31.0), where three copies of the same switch between compilers had grown.
Its users today are pascal-api-infra-faa (`PascalApi.Otlp`, the MCP executor) and
pascal-agenda-faa (`Agenda.HttpClient`, `Agenda.HttpSession`, `Agenda.Client`, the desktop
client). pascal-search-faa is a second library that needs it: its Meilisearch and Typesense
adapters speak HTTP + JSON. Under this library's rule ("what at least two libraries use"), the
transport belongs here. The user took that decision before this design.

Two more reasons came from pascal-search-faa's probe (its `.ci/probe-engines/findings.md`,
40–42) and from this repository's probe (`.ci/probe-http/findings.md`, git-ignored; numbers
below refer to it):

- **On FPC, https isn't verified.** fphttpclient accepts a self-signed certificate and a host
  name the certificate doesn't name (finding 3). A man in the middle gets the search engines'
  API keys and the OTLP/MCP/agenda tokens.
- **On FPC, https often doesn't load at all.** FPC 3.2.2's `openssl.pas` finds OpenSSL 3 only
  through the unversioned `libssl.so` (`libssl-dev`) on Linux, and not at all on Windows, where
  it knows only the 1.1 DLL names (findings 1 and 2).
- **On FPC, an answer that isn't HTTP can come back as status 0** with no exception (finding 5),
  against the contract.
- **The package.** `pascal_api_infra_faa_client.lpk` requires pascal-jsonmapper-faa; a library
  that wants only the transport carries the mapper with it.

## Decisions

### H1 — three units here; OTLP, MCP and JSON stay in pascal-api-infra-faa (recommended)

| Unit | Holds |
|---|---|
| `PascalCommon.Http` | the contract and pure helpers: `TPcHttpHeader`, `TPcHttpHeaders`, `TPcHttpRequest`, `TPcHttpResponse`, `EPcHttpTransport`, `IPcHttpTransport`, `PC_HTTP_DEFAULT_TIMEOUT_MS`, `PcHttpFindHeader`, `PcHttpSplitHeaderLine`, `PcHttpMethodHasBody`, `PcUrlWithoutQuery`, `PcParseHttpUrl` |
| `PascalCommon.Http.Client` | `TPcHttpOptions`, `PcNewHttpTransport` and the client of H2 over `PascalCommon.Transport` |
| `PascalCommon.Http.Fake` | `TPcFakeHttpTransport`, `EPcFakeHttpTransport` (pascal-api-infra-faa's fake, renamed) |

The contract unit has no socket code, as `PascalCommon.Transport` has none (its step 1). A
caller's tests that use the fake therefore don't link the client.

- The names follow this repository's prefixes. `THttpHeader` becomes `TPcHttpHeader`, and
  pascal-api-infra-faa keeps its name as an alias (H9).
- `IPcHttpTransport` keeps the one-method interface (`Send`). An interface freezes within a major
  version (`CLAUDE.md`). One method that takes a record is the shape that survives that: a new
  request field is an addition to the record, not to the interface.
- **Out:** OTLP and MCP (pascal-api-infra-faa), JSON (the caller's mapper), and any retry policy
  beyond H5's one replay. Every unit goes in `pascal_common_faa.lpk`, with no new dependency.

### H2 — FPC: a small HTTP/1.1 client over `PascalCommon.Transport` (recommended)

fphttpclient was measured before being set aside (findings 1–5):

- it can't load OpenSSL 3 on Windows, nor on Debian 12 as it comes;
- `VerifyPeerCert` sets `SSL_VERIFY_PEER` and nothing else. Without `CertCA` it refuses even a
  public certificate (no default store). With the private CA it **accepts a wrong host name**
  (F10). A refusal says only "Connect to host:port failed.";
- fixing that means a name check in `OnVerifySSLCertificate` over FPC's own openssl unit, plus
  replacing its library loading. That rewrites `PascalCommon.Transport.OpenSSL`, which already
  verifies the chain and the name, loads OpenSSL 3 and 1.1, and passed its tests on Windows and
  Linux (finding 6).

What the client implements, and nothing more:

- **Request:** `METHOD path?query HTTP/1.1`, then `Host` (with the port when it isn't the
  scheme's default), the caller's headers, and `Content-Length`. The body is written in one
  `WriteExactly` after the head. `Content-Length` is always sent for POST/PUT/PATCH (0 when
  empty, as today), and for other methods only when there is a body.
- **Response:**
  - status line `HTTP/1.x NNN reason`;
  - headers, with duplicates kept in order. An obsolete folded line (obs-fold) is an invalid
    answer;
  - 1xx answers other than 101 are skipped;
  - body framing: by `Transfer-Encoding: chunked` (trailers read and dropped), by
    `Content-Length`, or by reading to close. HEAD, 204 and 304 have no body. Any other
    transfer coding (`gzip, chunked`) is refused as not HTTP: the client never asks for one,
    and returning the body still encoded would be wrong (added in step 3).
- **Deadlines:** `TimeoutMs` (0 = 15 s, as today). It is the connect budget, and the deadline of
  every wait to read and to write. It is per wait, not a total for the exchange (the meaning it
  has today, and `SetIoDeadline`'s).
- **Limits:** a head larger than 64 KiB and a body larger than `MaxResponseBytes` (H4) are
  "not an HTTP answer this client accepts" (H6).
- **Not in this version:**
  - redirects (never followed; a 3xx is an answer, as today);
  - compression (no `Accept-Encoding` is sent);
  - proxies, HTTP/2, `Expect: 100-continue`, cookies, authentication schemes. Headers are the
    caller's.

### H3 — Delphi: the same client, not `THTTPClient` (recommended)

Measured with Delphi 12 Win32 and Win64 (findings 8–12):

- `THTTPClient` validates against the Windows store only. A private CA would have to be installed
  in Windows, which is an administrator's change to the machine, not a configuration of the
  application.
- `OnValidateServerCertificate` fires only after WinHTTP refused. It gets names, serial and
  modulus, but not the certificate's bytes or chain.
- Accepting there turns off the CA, name, date and usage checks all at once (D11 accepts a wrong
  name) and costs a second connection.
- So "trust this CA" can only be "trust this issuer **name**", which a self-signed certificate can
  copy (`tests/pki/twin*` is that case). The requirement "a private CA, verified" can't be met on
  Delphi with it.

With the client of H2 on both compilers:

- the same TLS options on both compilers (CA file, mTLS, the backend);
- the same messages;
- the same behavior on a non-HTTP answer;
- the same keep-alive (H5);
- one test suite for both.

`PcTlsConnect` over SChannel answered every case as on FPC (finding 13).

**What Delphi loses.** None of it is used by a current caller: the code shows none, and the user
confirmed it on 2026-11-10 ("não existe nenhum cliente atual que precise de proxy"):

- WinHTTP's proxy settings. Not measured whether Delphi 12's `THTTPClient` uses the system proxy
  by default.
- HTTP/2.
- Transparent decompression.
- Windows integrated authentication (NTLM/Negotiate).

If a caller turns out to need one of them, the alternative is an `IPcHttpTransport` over
`THTTPClient`, kept in the caller (the interface makes that a few dozen lines). It is not
carried here, because its TLS options would differ from the client's.

### H4 — options on the transport, safe when zeroed (recommended)

```pascal
type
  TPcHttpOptions = record
    /// TLS for https URLs. Zeroed: the system store and the host name are
    /// checked. CaFile: trust this CA instead (PEM). CertFile/KeyFile/
    /// CertPassword: a client certificate (mTLS). Backend: tbDefault,
    /// tbSChannel, tbOpenSsl (T3 of transport-design.md).
    Tls: TPcTlsOptions;
    /// 0 = PC_HTTP_MAX_RESPONSE_DEFAULT (64 MiB).
    MaxResponseBytes: Int64;
    /// True: one connection per exchange (no pool, H5).
    NoKeepAlive: Boolean;
    /// Idle connections kept per host. 0 = 4.
    MaxIdlePerHost: Integer;
    /// An idle connection older than this is closed, not reused. 0 = 4000.
    IdleTimeoutMs: Cardinal;
  end;

function PcNewHttpTransport: IPcHttpTransport; overload;              // zeroed options
function PcNewHttpTransport(const AOptions: TPcHttpOptions): IPcHttpTransport; overload;
```

- **Per transport, not per request.** One configured transport is one client of one service:
  the search adapter builds one per engine configuration. TLS settings per request would make
  pooled connections ambiguous.
- **Turning verification off** is `Tls.SkipServerVerification`, which already exists with that
  name in the whole family and is documented as "for a lab only". A second name for the same
  switch (`InsecureSkipVerify`) would leave two to search for. Recommended: keep the one name,
  and have this unit's documentation say plainly that it is insecure.
- **mTLS** comes for free from `TPcTlsOptions`. Kafka-style clusters need it; nobody here asked.
- On Linux, the system store is `/etc/ssl/certs`. A slim image without `ca-certificates` refuses
  every public site (finding 6: the `fpc322-bookworm` image has no store at all). The README gets
  that line.

### H5 — keep-alive: a small pool per transport (recommended)

Measured (finding 7, loopback, ms per exchange):

| | New verified TLS connection | Kept-alive connection |
|---|---|---|
| OpenSSL, Linux | 7.4–8.7 | 0.31 |
| SChannel, FPC | 7.8 | 0.17 |
| SChannel, Delphi | 8–13.5 | 0.25–0.31 |

- On a network, a new connection also costs two more round trips.
- Meilisearch polls `/tasks/{uid}` up to ~40 times per write.
- **Delphi already reuses connections today**: WinHTTP pools them across `THTTPClient` instances
  (finding 12). A client without a pool would make pascal-agenda-faa's desktop client and
  `PascalApi.Otlp` slower than they are on Delphi now.

How the pool works:

- **Ownership:** each transport owns its pool. It is keyed by scheme + host + port, and holds idle
  connections LIFO, up to `MaxIdlePerHost`. A connection is used by one `Send` at a time. A lock
  guards only the idle lists, never a socket wait, so `Send` stays callable from many threads at
  once.
- **Back to the pool:** a connection returns only after its whole answer was read. It doesn't
  return when the answer said `Connection: close`, came from HTTP/1.0 without keep-alive, or was
  framed by close. Destroying the transport closes the idle connections.
- **Before reuse:** an idle connection older than `IdleTimeoutMs` is closed. A younger one is
  checked with `TPcEndpoint.HasPendingInput` (new in 1.31.0), which peeks at the socket without
  waiting (`recv` with `MSG_PEEK` on the non-blocking socket). Nothing pending means it is alive;
  the server's close or a stray byte means it is discarded.
  - **Changed while implementing.** This said "a 1 ms read check": a read with a 1 ms deadline,
    where a timeout means alive. On Windows a 1 ms wait costs **15.5 ms**
    (`WaitForSingleObject(…, 1)` × 100, measured 2026-11-10, `.ci/probe-http/wait`): the
    timer's resolution. That is more than a new TLS connection on loopback (7.8 ms), so the
    check would have cost the pool its point. Gotcha 18.
  - On a TLS endpoint the peek is on the raw socket. A record without data (a close_notify, a
    late session ticket) counts as pending, which only costs a new connection. TLS 1.3 tickets
    arrive before the first answer and are read with it, so a pooled connection has none left.
- **A burst larger than the pool:** with `MaxIdlePerHost` below the number of threads sending at
  once, connections coming back together close the extra ones, and the next burst opens new
  ones. 8 threads with the default 4 opened 9 connections in the tests; with
  `MaxIdlePerHost = 8`, never more than 8.
- **One replay:** if a **reused** connection fails before the first byte of the answer, the
  request is sent again once on a new connection. This applies only to idempotent methods (GET,
  HEAD, OPTIONS, PUT, DELETE). POST and PATCH are never sent twice: that failure is
  `EPcHttpTransport`, and the caller decides, as today.
- **Default idle timeout:** 4 s, below Meilisearch's keep-alive (5 s is actix-web's default,
  read in its documentation, not measured). Typesense's and the OTLP collectors' values were not
  checked. The 1 ms check covers a server that closes sooner.

Separate from this, and not part of this work: on OpenSSL, about 6 ms of each new verified
connection goes into verification (verified 8.7 ms against 2.8 ms skipped). The numbers fit a new
`SSL_CTX` loading the CA file on every connect, but that wasn't instrumented. Caching the client
context in `PascalCommon.Transport.OpenSSL` would help every library on it. It is a candidate for
a later minor version, measured first.

### H6 — the contract: today's, with the non-HTTP answer fixed (recommended)

Kept from `PascalApi.HttpTransport`:

- every status is an answer;
- `EPcHttpTransport` only when there was no answer (refused, unreachable, a timeout, TLS);
- the message names the method and the URL without its query;
- UTF-8 bodies both ways;
- POST/PUT/PATCH always carry a length;
- no redirects;
- callable from several threads.

Changed or added:

- **An answer that isn't HTTP raises `EPcHttpTransport`** on both compilers. That covers a bad
  status line, a connection closed before the status line, a chunk size that doesn't parse, a
  body shorter than its `Content-Length`, and a head or body over the limits. Today FPC gives
  status 0 for the closed case (finding 5); Delphi already raises (finding 9).
- **The message keeps the cause's class and text**, as today: `GET https://h/p: no answer
  (EPcTls: the server's certificate was refused (X509 error 64; ...))`. A refused certificate now
  says why. fphttpclient said "Connect ... failed", and `THTTPClient` "Server Certificate Invalid
  or not present".
- **Headers the transport owns** (`Host`, `Content-Length`, `Transfer-Encoding`, `Connection`)
  raise `EArgumentException` when a request sets them. That is a programming error. Ignoring it
  silently would send something other than what the caller wrote.
- **URL:** `http` and `https` only, user info refused, IPv6 literals in brackets. Path and query
  are sent as given: the caller encodes them with `PcPercentEncode`, as the search adapters
  already plan. A character that must be encoded (a space, a control character, anything
  outside ASCII) raises `EArgumentException` instead of being sent. An empty port
  (`http://h:/`) is the scheme's (RFC 3986).

### H7 — the encoding exception comes here too (recommended)

A response body that isn't UTF-8 raises pascal-api-infra-faa's `ETextEncodingException` today.
`PascalApi.Otlp` catches it (`PascalApi.Otlp.pas:264`), and `PascalApi.Http` maps it to 400.

This library would add `EPcTextEncoding` and `PcUtf8BytesToString(ABytes, AWhat)`, which raises
it, to `PascalCommon.Utf8`. pascal-api-infra-faa then declares
`ETextEncodingException = EPcTextEncoding` and makes `PaUtf8BytesToString` call the new function,
so every existing `except on ETextEncodingException` still catches it.

The alternative is a new HTTP-only class. Then the body error the infra's code catches today
would stop being caught.

### H8 — the fake moves as it is (recommended)

`TPcFakeHttpTransport` is pascal-api-infra-faa's `TFakeHttpTransport` with this library's names.
It is thread-safe, answers from a queue (`Answer`, `Fail`) and records the requests. A `Send`
with the queue empty raises `EPcFakeHttpTransport` (the test's failure, not a lost connection).
It stays in `src/`, so an application's tests use it too.

### H9 — pascal-api-infra-faa keeps its names as aliases (step 4, asked before starting)

As `PascalApi.Crypto` did:

- `PascalApi.HttpTransport` becomes aliases and one-line wrappers:
  - `TTransportRequest = TPcHttpRequest`, `TTransportResponse = TPcHttpResponse`;
  - `THttpHeaders`, `EHttpTransport = EPcHttpTransport`, `IHttpTransport = IPcHttpTransport`;
  - `HTTP_DEFAULT_TIMEOUT_MS`, and `NewHttpTransport` calling `PcNewHttpTransport`.
- `PascalApi.HttpTypes.THttpHeader = TPcHttpHeader`. That unit then has one `uses`, which breaks
  its "keep uses empty" note. The note was there to keep pascal-db-faa out, and pascal-common-faa
  is already required.
- `PascalApi.HttpTransport.Fake` becomes aliases too.
- pascal-agenda-faa compiles unchanged; its suites and the desktop smoke are the check.

What a user of those libraries sees changes, and goes in their CHANGELOG and gotchas:

- **On FPC, https is now verified.** An OTLP collector or MCP endpoint with a self-signed or
  private-CA certificate stops working until it is configured. pascal-api-infra-faa's OTLP and
  MCP settings gain a TLS field (an addition there).
- **On FPC, OpenSSL 3 loads without `libssl-dev`, and on Windows too** (findings 1 and 2).
- **A non-HTTP answer raises** (finding 5).
- **On Delphi, the client is no longer WinHTTP** (H3's list).
- **The interface's GUID** becomes `IPcHttpTransport`'s. Code that names the interface doesn't
  notice.

### H10 — tests on loopback, no Docker (recommended)

Servers in the test process, on `PcTcpListen`/`PcTlsListen`, as in the probe but one thread per
connection (the probe's one-at-a-time servers distorted two Delphi numbers, finding 13). The
probe's `selfsrv` and `other` certificates move to `tests/pki`, with their rows in its README.
TLS fixtures run per backend: tbDefault, plus tbOpenSsl on Windows, as `TlsTransportTests` does.

- **TLS:**
  - a private CA with the right name gives 200;
  - the system store refuses the private CA;
  - a self-signed certificate is refused;
  - a wrong name is refused;
  - `SkipServerVerification` accepts the self-signed one;
  - the refusal's message carries the cause.
- **Answers that aren't HTTP:** http to a TLS port, a garbage line, a close before the status
  line, a truncated body, a chunk size that doesn't parse, oversized head and body.
- **Framing:** `Content-Length`, chunked with trailers, read to close, HEAD, 204, 1xx before the
  answer, duplicate headers, a 302 not followed.
- **Bodies:** `'São Paulo'` both ways, invalid UTF-8 raising `EPcTextEncoding`, an empty POST
  sending `Content-Length: 0`.
- **Deadlines:** a server that never answers raises in about `TimeoutMs`; the connect budget
  holds against a closed port.
- **Pool:**
  - sequential exchanges reuse one connection (the server counts them);
  - a server that closes idle connections triggers the replay of a GET;
  - a POST that hits the same failure is not replayed;
  - `Connection: close` isn't pooled;
  - `NoKeepAlive` opens one connection per exchange;
  - 8 threads at once give right answers and no more connections than threads.
- **Fake:** pascal-api-infra-faa's tests, ported. **URL and helper** tests without sockets.
- Linux at `--cpus=1` with three runners at once, as this repository requires of anything
  concurrent.

### H11 — version and release (recommended)

- **1.31.0**: a minor version, additions only (three units, `EPcTextEncoding` and
  `PcUtf8BytesToString`).
- As T8 did for the transport, the tag waits until pascal-api-infra-faa runs on it (step 4).
  A mistake in the interface found in that migration is then still free to fix.
- pascal-search-faa can develop against the branch meanwhile.

## Measured in step 3

`.ci/probe-http/HttpClientTiming.lpr` (git-ignored), FPC 3.2.2, loopback, 200 sequential GETs,
ms per exchange, https verified against the test CA. The pooled column includes the
`HasPendingInput` check before each reuse.

| | Pooled (1 connection) | `NoKeepAlive` (200 connections) |
|---|---|---|
| http, Windows | 0.14 | 0.57 |
| http, Linux (Debian 12) | 0.22 | 0.45 |
| https, Windows, SChannel | 0.27 | 7.81 |
| https, Windows, OpenSSL 3.2 | 0.44 | 10.40 |
| https, Linux, OpenSSL 3.0 | 0.28 | 8.20 |

heaptrc: 0 unfreed blocks on both. The suites: FPC Windows 687/687, Linux 597/597, Delphi 12 CE
Win32 and Win64 687/687 (651 + 36 in the time zone project), 0 leaks; the
HTTP, TCP and TLS suites 10 times each in 3 containers at once at `--cpus=1`, 120 runs green.

The `--cpus=1` runs found one race before release: `Release` read the clock before taking the
pool's lock, so a connection put back meanwhile by another thread, stamped later, made the
unsigned age wrap around and was dropped as expired (8 threads opened 9 connections, 5 runs in
160). The clock is now read under the lock; `THttpClientTests` then passed 160 runs in 4
containers at once.

## Order

1. Probe: done (`.ci/probe-http`).
2. This design: the user's decisions.
3. Here: the units, the tests on FPC Windows, FPC Linux (Debian 12, `--cpus=1`) and Delphi
   Win32/Win64 (built by the user in the IDE). Then `docs/plan.md` and the CHANGELOG.
4. pascal-api-infra-faa on it (H9), and check pascal-agenda-faa; asked before starting. Then tag
   1.31.0, and update the minimum-version matrix of the `using-faa-libraries` skill.
5. What to take back to pascal-search-faa: the minimum version, unit names, a CA file
   configuration, and the fake.

## Open points

- ~~**H3:** does any current caller need a proxy, integrated authentication or HTTP/2?~~ No
  (the user, 2026-11-10).
- **H5:** Typesense's and the OTLP collectors' keep-alive timeouts (not checked). The check's
  cost is measured above: it is inside the 0.27 ms of a pooled exchange.
- **The `SSL_CTX` per connection** on OpenSSL (H5, last paragraph): a candidate for later.
