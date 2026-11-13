# HTTP client telemetry — design

Status: **step 5 done, 2026-11-13; tagged 1.33.0.** The user accepted the
recommendations and answered the three open questions the same day: `ResendCount` is added
(HT6); with no current span there is no span by default (HT3); pascal-agenda-faa keeps its own
spans (HT10). Implemented in `PascalCommon.Http.Telemetry`, with one change found while writing
it: `PcHttpMetricMethod` is case-sensitive (see HT1). Step 4: pascal-api-infra-faa 0.34.0 runs its MCP executor on it, with no change to the
interface here; the tag followed.

## Why

`PascalCommon.Http` (1.31.0) moves one HTTP exchange behind `IPcHttpTransport`. Nothing in this
library records it: no span, no metric, no `traceparent`. `PascalCommon.Tracing` and
`PascalCommon.Metrics` came here (1.6.0, 1.7.0) so the sibling libraries instrument themselves
the same way. pascal-db-faa, pascal-redis-faa and pascal-amqp-faa already do. Inside this
library, only `PascalCommon.Cache` records anything (`pc.cache.*`).

The client span around a `Send` has been written twice already, and the two copies differ:

| | pascal-api-infra-faa `TMcpHttpExecutor.Execute` (`src/horse/PascalApi.Horse.Mcp.pas`) | pascal-agenda-faa `TApiHttpClient.TrySend` (`src/Agenda.HttpClient.pas`) |
|---|---|---|
| No current span | no span; the caller's `traceparent` is forwarded | a root span in the request's trace (`StartSpanWith`) |
| Parent | `TPcTracing.Current` | an explicit parent (`StartChildSpan`) |
| URL attribute | `url.full`, **query included** | `url.path`, query dropped ("it may carry what a user typed") |
| Retries | — | one span per try, `http.request.resend_count` |
| Error | exception: `error.type` = class, `ssError`; status ≥ 400: `ssError` | the same, plus `error.type` = the status |
| Metric | none | none |

pascal-search-faa's Meilisearch and Typesense adapters would be the third copy. Under this
library's rule ("what at least two libraries use"), the instrumentation belongs here. The
semantic conventions are OpenTelemetry's (HTTP client spans and `http.client.request.duration`).
pascal-api-infra-faa's server side already follows them.

pascal-api-infra-faa's `docs/observability-design.md` put "automatic instrumentation of
outgoing HTTP calls the application makes on its own" out of its scope. This design is that
item.

## Decisions

### HT1 — a decorator in a unit of its own (accepted)

```pascal
unit PascalCommon.Http.Telemetry;

type
  TPcHttpTelemetryOptions = record
    /// True: no span and no traceparent; the metric is still recorded.
    NoSpans: Boolean;
    /// True: no metric.
    NoMetrics: Boolean;
    /// True: with no current span, the exchange is the root of a new trace
    /// (see HT3). False (zeroed): no span and no traceparent then.
    RootWhenNoParent: Boolean;
  end;

/// AInner, recorded: a client span and http.client.request.duration per Send.
function PcNewTracedHttpTransport(const AInner: IPcHttpTransport): IPcHttpTransport; overload;
function PcNewTracedHttpTransport(const AInner: IPcHttpTransport;
  const AOptions: TPcHttpTelemetryOptions): IPcHttpTransport; overload;

/// The method as a span name and metric label: one of RFC 9110's and PATCH,
/// exactly; '_OTHER' for any other (bounded cardinality).
function PcHttpMetricMethod(const AMethod: string): string;
```

- **Changed while implementing:** this said "in upper case", accepting any case. Methods are
  case-sensitive (RFC 9110), the conventions compare them exactly, and pascal-api-infra-faa's
  `MetricMethod` does too: `'get'` is `'_OTHER'`. Kept that way so that function can become a
  call to this one without changing a label.

- **Not inside `PcNewHttpTransport`.** `PascalCommon.Http` has no dependency today, and
  `Http.Client` has only `Transport`. A decorator works over any `IPcHttpTransport`: the fake
  (tests without a socket), the client, or an `IPcHttpTransport` over `THTTPClient` that a
  caller keeps (H3 of `http-design.md`). It needs no change to the interface, which is frozen
  within the major version.
- **Opt-in at the transport, on by default in a library that builds one.** A library that
  builds its own transport (pascal-search-faa, one per engine configuration) wraps it always,
  as pascal-db-faa records every statement: spans cost almost nothing while `TPcTracing` isn't
  started (HT8). An application that builds its own transport wraps it or not.
- **Safe when zeroed**, like `TPcHttpOptions`: spans and the metric on, no root spans.
- What it loses: it can't see inside `Send` (the connection, the replay of H5). See HT7.

### HT2 — the span: OpenTelemetry's HTTP client conventions (accepted)

Per `Send`, on the calling thread, started and finished inside `Send` (so the thread rule of
`PascalCommon.Tracing` holds: a current span is finished where it started):

- `TPcTracing.StartSpan(Name, skClient)`. Its parent is the thread's current span, which is
  also the case of an explicit parent made current with `StartChildSpan`, as the agenda does.
- **Name:** `PcHttpMetricMethod(Method)`, and `'HTTP'` when that is `'_OTHER'` (the
  conventions' rule).
- **Attributes:**
  - `http.request.method`: `PcHttpMetricMethod`;
  - `server.address`, `server.port`, `url.scheme`: from `PcParseHttpUrl`;
  - `url.full`: `PcUrlWithoutQuery(Url)`, never the query or the fragment;
  - `http.response.status_code`: when there was an answer;
  - `http.request.resend_count`: when the request says so (HT6).
- **Error:**
  - an exception sets `error.type` to its class name, `ssError` with its message, and is
    re-raised unchanged;
  - a status ≥ 400 sets `error.type` to the status and `ssError` without a message (the
    conventions: from 400 on for a client span);
  - every other status leaves the span `ssUnset`.
- **Propagation:** the request goes to the inner transport with `traceparent` set to
  `Span.TraceParent`, and `tracestate` when the span has one. The caller's request is `const`,
  so the decorator sends a copy.

The `url.full` without the query is the choice that is safe everywhere. An API key in a query
(some engines accept one) would otherwise go to the collector. The conventions allow redacting
it. pascal-agenda-faa's reason for `url.path` is the same, so it loses nothing.

### HT3 — no current span: no span, unless asked (accepted)

With `TPcTracing.Current = nil`:

- **Zeroed options (accepted):** no span and no `traceparent`. The metric is still recorded.
  This is what the MCP executor does today.
- **`RootWhenNoParent`:** a root span (`StartSpan` starts a new trace), with its `traceparent`
  sent.

The reason is the OTLP exporter. `TOtlpHttpExporter` (pascal-api-infra-faa) sends its batches
through an `IPcHttpTransport`, on the batch processor's thread, where there is no current span.
If that transport were wrapped with root spans on, every export would make a span, and every
span would make another export, without end. Making that the default would be a trap. With the
recommended default, a wrapped exporter transport only records its metric
(`server.address` = the collector), which is useful. The unit's header and a gotcha say:
**never wrap the exporter's transport with `RootWhenNoParent`.**

The alternative is root spans by default (a desktop client with no server span would then see
its calls). It is the agenda's behavior today, but the agenda doesn't create a plain root: it
reuses its own request's trace id. That is better done by the agenda opening one span around
its retries (HT10). It is rejected as a default because of the loop.

### HT4 — a request that already has `traceparent` is the caller's (accepted)

When the request carries `traceparent` (any case), the decorator **opens no span and changes no
header**. It still records the metric. A caller that sets it is managing the context by hand.
The MCP executor forwards the client's `traceparent` when there is no current span. Replacing
that header, or opening a span whose id isn't the one sent, would break the chain.

The alternative is to open the span anyway and overwrite the header. That hides the caller's
choice, and there would be two sources of truth for the trace.

### HT5 — the metric: `http.client.request.duration` (accepted)

On `PcMetrics`, looked up once when the decorator is built:

| Metric | Kind | Unit | Labels | Buckets |
|---|---|---|---|---|
| `http.client.request.duration` | histogram | `s` | `http.request.method`, `server.address`, `server.port`, `url.scheme`, `http.response.status_code`, `error.type` | `PC_DURATION_BUCKETS` |

- Its description is required (`promtool` rejects a metric without help text, as
  pascal-api-infra-faa's CI found).
- Duration from `PcTickUs`, never the wall clock. It is measured around the inner `Send`, so it
  includes connecting, the replay and reading the body.
- **Absent values are `''`**: no status when there was no answer, and no `error.type` on
  success. An empty Prometheus label is the same as no label, the conventions' "absent", as
  pascal-api-infra-faa already does for `http.route`.
- **Cardinality:** the method is bounded by `_OTHER`, and the host and port by the services a
  process talks to. The path never goes into a label.
- **A clash:** `TPcMetricRegistry` raises `EPcMetrics` when one name is registered with other
  labels. An application that already registers its own `http.client.request.duration`
  (none found in the family) would get the error when the decorator is built, which is a
  programming error, as the registry intends.
- Each `Send` finds its series with `Labels([...])`: a dictionary lookup under the family's
  lock. HT8 measures it.

### HT6 — `http.request.resend_count` from the request (accepted)

Only the caller knows it is retrying, as the agenda does on 429 and 503. Recommended: add
`ResendCount: Integer` to `TPcHttpRequest`, set to 0 by `TPcHttpRequest.Create`, and used only
by the decorator (attribute when > 0). The client ignores it.

- It is an addition to a record, allowed within the major version. A record built without
  `Create` has the field uninitialized, as `TimeoutMs` already has. The comment says so, and
  `Create` is the documented way.
- **Alternative (rejected 2026-11-13):** none, so a caller that retries loses the attribute.
  The user chose to add the field.

### HT7 — the replay of H5 stays invisible to the decorator; connection metrics later (accepted)

The client sends an idempotent request a second time when a reused connection failed before the
answer (H5). The decorator sees one `Send`, one span and one duration. The conventions count
resends made by the client as `resend_count` too. Reporting it would need a field in
`TPcHttpResponse`, and that is the wrong shape: an `IPcHttpTransport` written elsewhere (the
`THTTPClient` one of H3) returns its result record without setting a field it doesn't know
about. In Delphi the `Integer` would then be whatever was in that memory. So no field.

**Phase 2, only on a need:** the client records its pool on `PcMetrics` itself, as pascal-db-faa
records its pool (measured there at a few hundred nanoseconds, no switch):

| Metric | Kind | Unit | Labels |
|---|---|---|---|
| `http.client.open_connections` | up-down counter | `{connection}` | `http.connection.state` (`idle`/`active`), `server.address`, `server.port`, `url.scheme` |
| `http.client.connection.duration` | histogram | `s` | `server.address`, `server.port`, `url.scheme` |
| `pc.http.client.replays` | counter | `{request}` | `server.address`, `server.port` |

That makes `Http.Client` depend on `Metrics`, a unit of this library with no dependency of its
own. It isn't part of this design's first release.

### HT8 — cost (accepted: measure, no switch unless it shows)

With tracing not started, a span still makes ids (`PcNewSpanId`, from the OS random source)
and a `traceparent`. That is the contract of `PascalCommon.Tracing`: propagation works without
exporting. The MCP executor and the agenda already pay it. The histogram costs a series lookup
and an observation.

Measured in step 3 against `.ci/probe-http/HttpClientTiming.lpr`: the fake transport with and
without the decorator (tracing off, on with ratio 0, on with ratio 1), and the pooled loopback
exchange (0.14–0.44 ms today). The target is an overhead below 1% of a pooled loopback exchange.
If it shows, the decorator checks `TPcTracing.Enabled` before making ids. That changes only
whether a `traceparent` is sent while tracing is off, and it would be a decision taken then.

### HT9 — tests over the fake (accepted)

`tests/Unit/HttpTelemetryTests.pas` (mirrored for FPC by `tools/gen_fpc_mirror.py`), with
`TPcTracing.Start(..., AAutoFlush = False)` and a capturing exporter, `FlushNow`, `Shutdown` in
`TearDown`:

- a span under the current one: kind, name, every attribute, and the `traceparent` the fake
  received is the span's;
- `url.full` has no query and no fragment;
- 404 and 503 are errors with `error.type` = the status; 302 and 200 are not;
- an exception (`Fail` on the fake) gives `error.type` = `EPcHttpTransport`, `ssError`, and is
  re-raised as the same class;
- no current span: no span and no header (zeroed); a root span with `RootWhenNoParent`;
- a request with its own `traceparent`: sent unchanged, no span;
- `NoSpans` and `NoMetrics`;
- `ResendCount` > 0 becomes the attribute;
- `PcHttpMetricMethod`: the nine methods in any case, `_OTHER`, and the span name `HTTP`;
- the histogram's series and count with the right labels, `''` for the absent ones (on a
  registry the test creates, or `PcMetrics` read before and after);
- 8 threads at once, each with its own current span: each request carries its own thread's
  trace (the copy of the request isn't shared).

Then the usual acceptance: FPC Windows and Linux (`--cpus=1`, three runners at once, because the
decorator is called from many threads), Delphi 12 CE Win32 and Win64, 0 leaks. The Delphi
`PascalCommon.UnitTests` project is close to CE's size limit (`CLAUDE.md`). If the new suite
brings the "EULA Reminder" back, the HTTP suites move to a project of their own, as the time
zones did.

### HT10 — consumers (asked before starting, each in its own repository)

- **pascal-api-infra-faa (MCP executor):** wraps its transport. `Execute` stops opening its
  span. With no current span it sets the client's `traceparent` itself (HT4 keeps it). Its
  error log stays. `PascalApi.Otlp`'s transport is **not** wrapped, or is wrapped with zeroed
  options (metric only, HT3). `tools/otlp_check.py`'s MCP chain (server -> client -> server)
  must pass unchanged, which tests HT2 against a real collector.
- **pascal-agenda-faa: unchanged** (the user, 2026-11-13). Moving it would have turned a
  request without a parent (today a root span per try, sharing the request's trace id) into one
  span around its tries with the tries as children: one more span per trace. It keeps its own
  spans in `TrySend` and doesn't wrap its transport (wrapping it too would give two client spans
  per try; HT4 keeps them apart only because the agenda sets `traceparent` itself, but the
  metric would still be recorded). If it ever moves, `ResendCount` is already there for its
  retries.
- **pascal-search-faa:** each adapter wraps the transport it builds (HT1).
- **pascal-email-faa** (0.1.0, not on the original list): the SES adapter wraps its transport,
  its own or the one given to `Create`; the `traceparent` is added after the SigV4 signature,
  outside `SignedHeaders` (its finding 13, reasoned, not measured against AWS). Its own `email
  send` span (internal for SES) is the `POST`'s parent.
- `using-faa-libraries` skill: a line on the decorator and the exporter trap.

### HT11 — version and release (accepted)

- **1.33.0**: a minor version, additions only. It adds the unit `PascalCommon.Http.Telemetry`,
  `PcHttpMetricMethod` and `TPcHttpRequest.ResendCount` (HT6, if accepted). The unit goes in
  `pascal_common_faa.lpk`, with no new dependency (`Tracing`, `Metrics`, `Http` and `Threading`
  are already in it).
- As with H11, the tag waits until the MCP executor runs on it (HT10). A mistake found there is
  still free to fix.
- pascal-api-infra-faa's `MetricMethod` can then become a call to `PcHttpMetricMethod`
  (the same rule), in its own release.

## Measured in step 3

2026-11-13, FPC 3.2.2 Win64 `-O2`, 200 000 `Send`s on one thread, over a transport that answers
200 with no work (0.02 µs per `Send`), µs per `Send`, two runs (programs in the session's
scratchpad, not kept):

| | µs |
|---|---|
| traced, tracing off, no current span (metric only) | 1.9 |
| traced, tracing off, under a span | 3.2–3.5 |
| traced, tracing on, ratio 0, under a span | 3.2–3.7 |
| traced, tracing on, ratio 1, under a span (exported) | 4.3–5.1 |

The parts: `PcParseHttpUrl` 0.36, the series lookup and observation 0.89, a span id 0.11, a
child span started and finished 0.75. The rest is copying the headers, formatting the
`traceparent` and the six attributes.

Against the pooled loopback exchanges of `http-design.md` (0.14–0.44 ms), 3.3 µs is 0.8–2.4%:
above HT8's 1% on plain http over loopback, below it on https. Over a network, where an
exchange takes milliseconds, it doesn't show. HT8's fallback (skip the ids while tracing is
off) would save about 0.2 µs (two ids), so it isn't worth changing what is sent: **no switch**,
the open point is closed. If a hot loopback caller ever needs it, the cheap gains are caching
the parsed URL's labels per transport and keeping the series per label set.

## Order

1. This design: the user's decisions.
2. Here: the unit, the tests, gotcha (exporter loop), README, CHANGELOG, version. Done
   2026-11-13: FPC Windows 709/709, FPC Linux 619/619 in three containers at once at
   `--cpus=1`, 0 leaks. Delphi 12 CE Win32 and Win64: built by the user in the IDE.
3. The measurement of HT8: done (above).
4. pascal-api-infra-faa on it (HT10), with `otlp_check.py`; asked before starting. Then the tag.
   Done 2026-11-13: pascal-api-infra-faa 0.34.0, 505 unit tests, 0 leaks, on FPC Windows and
   Linux and Delphi 12 Win32/Win64; its HTTP scenarios on all four (Delphi: samples 01 and 02);
   the collector in its CI script got the MCP chain with the new attributes (`url.full` without
   the query, `server.address`, `server.port`, the status), checked by `otlp_check.py`.
5. pascal-search-faa, in its own session (pascal-agenda-faa stays as it is, HT10). Done
   2026-11-13: pascal-search-faa 0.3.0 wraps both adapters' transports (the one given to `New`
   too); Meilisearch's task polls go through a second decorator with `NoSpans` over the same
   inner transport, and each wait is one internal span of its own (`meilisearch.wait_task`).
   Its `docs/design.md`, section 13; FPC Windows and Linux, Delphi 12 Win32/Win64, 0 leaks.
6. pascal-email-faa, in its own session. Done 2026-11-13 (0.1.0, not released): the SES
   adapter wraps its transport as pascal-search-faa does; every sender also records an `email
   send` span and `pascalemail.*` metrics of its own. Its `docs/design.md`, section 13 (E30-E35);
   FPC Windows and Linux, Delphi 12 Win32/Win64, 0 leaks.
7. Phase 2 (HT7), only when a pool problem asks for it.

## Open points

- ~~**HT6:** grow `TPcHttpRequest` with `ResendCount`, or not.~~ Yes (the user, 2026-11-13).
- ~~**HT3:** is a root span by default ever wanted (a desktop client)?~~ No: an option only (the
  user, 2026-11-13).
- ~~**HT10:** does pascal-agenda-faa move onto the decorator?~~ No, it keeps its own spans (the
  user, 2026-11-13).
- ~~**HT8:** whether to skip the ids while tracing is off depends on the measurement.~~ No:
  it would save about 0.2 µs of 3.3 (step 3, above).
- Span events (an exception as an `exception` event) are still missing from
  `PascalCommon.Tracing` (pascal-api-infra-faa, phase C "not done"). They would add the stack
  trace for an `EPcHttpTransport`. That is not part of this design.
