unit PascalCommon.Http;

{$I pascalcommon.inc}

{ One HTTP exchange behind an interface: a method, a URL, headers and a text
  body in; the status, the headers and the text body out. This unit is the
  contract and its pure helpers, with no socket code: PcNewHttpTransport
  (PascalCommon.Http.Client) is the client, TPcFakeHttpTransport
  (PascalCommon.Http.Fake) answers a test with no server.

  It came from pascal-api-infra-faa's PascalApi.HttpTransport (1.31.0,
  docs/http-design.md), which came from pascal-agenda-faa; pascal-search-faa
  was the second library to need it. The names follow this library's
  prefixes; pascal-api-infra-faa keeps its own as aliases.

  The contract (H6):
  - Every status is an answer, never an exception: a 401 or a 503 is for the
    caller to read. Redirects aren't followed: a 302 is an answer too.
  - EPcHttpTransport means there was no answer the client could read:
    refused, unreachable, a timeout, TLS, or an answer that isn't HTTP. The
    request may or may not have reached the server, so only the caller knows
    whether it may send it again. Its message names the method and the URL
    without its query (a query can carry what a log must not show).
  - Bodies are UTF-8 on the wire, both ways. An answer whose body isn't
    UTF-8 raises PascalCommon.Utf8's EPcTextEncoding, naming the URL.
  - POST, PUT and PATCH always carry a length ("Content-Length: 0" when the
    body is empty).
  - Send may be called from several threads at once.

  IPcHttpTransport has one method that takes a record on purpose: an
  interface freezes within a major version, and a new request field is an
  addition to the record, not to the interface. }

interface

uses
  SysUtils;

const
  /// A request with TimeoutMs 0 waits this long to connect and as long for
  /// each read or write.
  PC_HTTP_DEFAULT_TIMEOUT_MS = 15000;

type
  TPcHttpHeader = record
    Name: string;
    Value: string;
  end;

  TPcHttpHeaders = TArray<TPcHttpHeader>;

  TPcHttpRequest = record
    Method: string;
    /// http:// or https://. Path and query go as written: encode their
    /// parts with PascalCommon.Utf8's PcPercentEncode.
    Url: string;
    Headers: TPcHttpHeaders;
    Body: string;
    /// 0: PC_HTTP_DEFAULT_TIMEOUT_MS. Per wait, not for the whole exchange.
    TimeoutMs: Integer;
    class function Create(const AMethod, AUrl: string): TPcHttpRequest; static;
    procedure AddHeader(const AName, AValue: string);
    /// The first header named AName (any case); '' when absent.
    function Header(const AName: string): string;
  end;

  TPcHttpResponse = record
    Status: Integer;
    /// In the order received, duplicates kept.
    Headers: TPcHttpHeaders;
    Body: string;
    /// The first header named AName (any case); '' when absent.
    function Header(const AName: string): string;
  end;

  /// No answer: refused, unreachable, a timeout, TLS, or an answer that
  /// isn't HTTP.
  EPcHttpTransport = class(Exception);

  IPcHttpTransport = interface
    ['{9682D03B-3A5A-443B-B9E2-26933461B495}']
    /// Raises EPcHttpTransport when there was no answer, EPcTextEncoding when
    /// the answer's body isn't UTF-8, EArgumentException for a request that
    /// can't be sent as given (see PascalCommon.Http.Client).
    function Send(const ARequest: TPcHttpRequest): TPcHttpResponse;
  end;

  { An http or https URL split for a request (PcParseHttpUrl). }
  TPcHttpUrl = record
    /// 'http' or 'https', lower case.
    Scheme: string;
    /// The host as written, without the brackets of an IPv6 literal.
    Host: string;
    Port: Word;
    /// Path and query as the request line sends them; '/' when the URL has
    /// no path. Never the fragment.
    Target: string;
    function IsHttps: Boolean;
    /// The Host header: the host (an IPv6 one in brackets), plus ':port'
    /// when the port isn't the scheme's default.
    function HostHeader: string;
  end;

/// The first header named AName (any case).
function PcHttpFindHeader(const AHeaders: TPcHttpHeaders; const AName: string;
  out AValue: string): Boolean;

/// A header line ("Name: value") split at its first colon, both sides
/// trimmed. False for a line without a colon or without a name.
function PcHttpSplitHeaderLine(const ALine: string; out AHeader: TPcHttpHeader): Boolean;

/// POST, PUT and PATCH (any case): the methods that always carry a body.
function PcHttpMethodHasBody(const AMethod: string): Boolean;

/// GET, HEAD, OPTIONS, TRACE, PUT and DELETE (any case): the methods RFC 9110
/// calls idempotent, the only ones the client sends a second time (H5).
function PcHttpMethodIsIdempotent(const AMethod: string): Boolean;

/// AUrl without its query and fragment: what an error message may show.
function PcUrlWithoutQuery(const AUrl: string): string;

/// AUrl split for a request. EArgumentException for anything but http and
/// https, a missing host, user info ("user:pass@"), a port outside 1..65535,
/// and a character that must be percent-encoded (a space, a control
/// character, anything outside ASCII). An empty port ('http://h:/') is the
/// scheme's, as RFC 3986 says.
function PcParseHttpUrl(const AUrl: string): TPcHttpUrl;

implementation

function PcHttpFindHeader(const AHeaders: TPcHttpHeaders; const AName: string;
  out AValue: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AHeaders) do
    if SameText(AHeaders[I].Name, AName) then
    begin
      AValue := AHeaders[I].Value;
      Exit(True);
    end;
  AValue := '';
  Result := False;
end;

function PcHttpSplitHeaderLine(const ALine: string; out AHeader: TPcHttpHeader): Boolean;
var
  LColon: Integer;
begin
  LColon := Pos(':', ALine);
  AHeader.Name := '';
  AHeader.Value := '';
  if LColon = 0 then
    Exit(False);
  AHeader.Name := Trim(Copy(ALine, 1, LColon - 1));
  AHeader.Value := Trim(Copy(ALine, LColon + 1, MaxInt));
  Result := AHeader.Name <> '';
end;

function PcHttpMethodHasBody(const AMethod: string): Boolean;
begin
  Result := SameText(AMethod, 'POST') or SameText(AMethod, 'PUT') or SameText(AMethod, 'PATCH');
end;

function PcHttpMethodIsIdempotent(const AMethod: string): Boolean;
begin
  Result := SameText(AMethod, 'GET') or SameText(AMethod, 'HEAD') or
    SameText(AMethod, 'OPTIONS') or SameText(AMethod, 'TRACE') or
    SameText(AMethod, 'PUT') or SameText(AMethod, 'DELETE');
end;

function PcUrlWithoutQuery(const AUrl: string): string;
var
  I: Integer;
begin
  for I := 1 to Length(AUrl) do
    if (AUrl[I] = '?') or (AUrl[I] = '#') then
      Exit(Copy(AUrl, 1, I - 1));
  Result := AUrl;
end;

procedure BadUrl(const AUrl, AWhy: string);
begin
  raise EArgumentException.CreateFmt('"%s" is not a URL this client sends: %s',
    [PcUrlWithoutQuery(AUrl), AWhy]);
end;

function PcParseHttpUrl(const AUrl: string): TPcHttpUrl;
var
  I, LSep, LAuthEnd, LColon, LPort: Integer;
  LAuthority, LPortText, LRest: string;
begin
  Result.Scheme := '';
  Result.Host := '';
  Result.Port := 0;
  Result.Target := '';
  for I := 1 to Length(AUrl) do
    if (AUrl[I] <= ' ') or (Ord(AUrl[I]) >= 127) then
      BadUrl(AUrl, Format('the character at %d must be percent-encoded', [I]));
  LSep := Pos('://', AUrl);
  if LSep = 0 then
    BadUrl(AUrl, 'no scheme (http:// or https://)');
  Result.Scheme := LowerCase(Copy(AUrl, 1, LSep - 1));
  if Result.Scheme = 'http' then
    Result.Port := 80
  else if Result.Scheme = 'https' then
    Result.Port := 443
  else
    BadUrl(AUrl, 'only http and https');
  LRest := Copy(AUrl, LSep + 3, MaxInt);
  LAuthEnd := Length(LRest) + 1;
  for I := 1 to Length(LRest) do
    if (LRest[I] = '/') or (LRest[I] = '?') or (LRest[I] = '#') then
    begin
      LAuthEnd := I;
      Break;
    end;
  LAuthority := Copy(LRest, 1, LAuthEnd - 1);
  LRest := Copy(LRest, LAuthEnd, MaxInt);
  if Pos('@', LAuthority) > 0 then
    BadUrl(AUrl, 'user info in a URL is not sent; use a header');
  LPortText := '';
  if (LAuthority <> '') and (LAuthority[1] = '[') then
  begin
    I := Pos(']', LAuthority);
    if I = 0 then
      BadUrl(AUrl, 'an IPv6 host without its closing "]"');
    Result.Host := Copy(LAuthority, 2, I - 2);
    LAuthority := Copy(LAuthority, I + 1, MaxInt);
    if LAuthority <> '' then
    begin
      if LAuthority[1] <> ':' then
        BadUrl(AUrl, 'text after the IPv6 host');
      LPortText := Copy(LAuthority, 2, MaxInt); // '' = the default
    end;
  end
  else
  begin
    LColon := Pos(':', LAuthority);
    if LColon > 0 then
    begin
      LPortText := Copy(LAuthority, LColon + 1, MaxInt); // '' = the default
      Result.Host := Copy(LAuthority, 1, LColon - 1);
    end
    else
      Result.Host := LAuthority;
  end;
  if Result.Host = '' then
    BadUrl(AUrl, 'no host');
  if LPortText <> '' then
  begin
    LPort := 0;
    for I := 1 to Length(LPortText) do
    begin
      if (LPortText[I] < '0') or (LPortText[I] > '9') or (LPort > 65535) then
      begin
        LPort := -1;
        Break;
      end;
      LPort := LPort * 10 + Ord(LPortText[I]) - Ord('0');
    end;
    if (LPort < 1) or (LPort > 65535) then
      BadUrl(AUrl, 'the port must be 1..65535');
    Result.Port := Word(LPort);
  end;
  I := Pos('#', LRest);
  if I > 0 then
    LRest := Copy(LRest, 1, I - 1);
  if LRest = '' then
    LRest := '/'
  else if LRest[1] = '?' then
    LRest := '/' + LRest;
  Result.Target := LRest;
end;

{ TPcHttpUrl }

function TPcHttpUrl.IsHttps: Boolean;
begin
  Result := Scheme = 'https';
end;

function TPcHttpUrl.HostHeader: string;
begin
  if Pos(':', Host) > 0 then
    Result := '[' + Host + ']'
  else
    Result := Host;
  if (IsHttps and (Port <> 443)) or (not IsHttps and (Port <> 80)) then
    Result := Result + ':' + IntToStr(Port);
end;

{ TPcHttpRequest }

class function TPcHttpRequest.Create(const AMethod, AUrl: string): TPcHttpRequest;
begin
  Result.Method := AMethod;
  Result.Url := AUrl;
  Result.Headers := nil;
  Result.Body := '';
  Result.TimeoutMs := 0;
end;

procedure TPcHttpRequest.AddHeader(const AName, AValue: string);
var
  N: Integer;
begin
  N := Length(Headers);
  SetLength(Headers, N + 1);
  Headers[N].Name := AName;
  Headers[N].Value := AValue;
end;

function TPcHttpRequest.Header(const AName: string): string;
begin
  PcHttpFindHeader(Headers, AName, Result);
end;

{ TPcHttpResponse }

function TPcHttpResponse.Header(const AName: string): string;
begin
  PcHttpFindHeader(Headers, AName, Result);
end;

end.
