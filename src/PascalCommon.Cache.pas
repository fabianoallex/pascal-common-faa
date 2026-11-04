unit PascalCommon.Cache;

{$I pascalcommon.inc}

(* A cache with expiry and tag invalidation: the contract a backend implements
  (IPcCacheStore), the cache an application uses (IPcCache, TPcCache) and a
  store in process memory (TPcMemoryCacheStore). The Redis store lives in
  pascal-redis-faa (Redis.Cache).

  The design, with the reasons for each decision, is docs/cache-design.md
  (decisions C1 to C12). In short:

  - Two layers (C3). A store only keeps strings with a TTL and tag counters;
    the rules (keys, tags, single-flight, failures, metrics) are written once,
    in TPcCache. Values are strings, in practice the application's DTO as
    JSON (C2).
  - Tags by generations (C4). Each tag has a counter in the store. Key reads
    the counters of the key's tags and puts them in the store key;
    Invalidate moves them forward, so the old entries are never read again
    and expire by their TTL. Nothing is deleted, and a reader that loaded old
    data before an invalidation writes it under a key nobody reads.
  - Store key: <name>:v:<application key>|<generations, comma-separated>.
    The generations never contain "|", so the LAST "|" separates them and two
    different (key, generations) pairs never give the same store key, even
    when the application key contains "|" or ",". Tag counters are
    <name>:tag:<tag> in the store. An application key always goes with the
    same tags: "product.list:7" built once with [category:7] and once with
    [products] could meet under the same generation numbers.
  - GetOrLoad runs the loader once per key among the threads of this process
    that miss it at the same time (single-flight, C5). If the loader raises,
    the thread that ran it gets the exception; each thread that waited gets
    an EPcCacheLoadError with the same message (one exception object can't
    be raised in several threads). Nothing is stored. A thread that misses
    just after a load ended may load again: no second read of the store to
    avoid it, which would cost a round trip on every miss.
  - The store is optional (C6). EPcCacheUnavailable from it (unreachable,
    timeout) is a miss on a read and ignored on a write; it goes to OnError
    and the store_errors metric, and the store is skipped for RetryAfterMs
    (1 s by default) so that a store that is down doesn't slow every request
    down with a connect attempt. Any other exception from a store is a bug
    and propagates. Invalidate and Remove always try the store, even in the
    pause, and never raise EPcCacheUnavailable: they run after a commit, and
    the TTL bounds the staleness when they fail.
  - Key returns '' when the tags' counters can't be read (store down or in
    the pause). TryGet, Put, GetOrLoad and Remove treat '' as a key that is
    never stored: GetOrLoad runs the loader without single-flight.
  - Metrics on PcMetrics (C9), labeled by the cache name only: pc.cache.hits,
    pc.cache.misses, pc.cache.loads, pc.cache.load_failures,
    pc.cache.store_errors and pc.cache.invalidations (in Prometheus,
    pc_cache_hits_total and so on, label "cache").

  Transactions (C7), which this unit can't enforce: invalidate after the
  commit, never before; don't Put what a transaction that also wrote has
  read; the TTL is the bound on staleness.

  TPcMemoryCacheStore (C8): one lock, entries with an expiry on TTicker
  (checked on read), the oldest by insertion dropped when full, after the
  expired ones (looked for at most once a second, so a full cache doesn't
  scan everything on every Put). With AMaxEntries = 0 it keeps nothing, not
  even tag counters. Tag counters are bounded too (AMaxTags, AMaxEntries by
  default; the least recently used dropped first): every new counter value,
  on creation or Bump, is the next value of one sequence for the store, so a
  counter created again is larger than any value any counter had, and
  dropping one only costs a miss on the keys built with it. Bump of a
  counter that doesn't exist does nothing, for the same reason.

  Dual-compiler: the callbacks follow PASCALCOMMON_FUNCREFS ("reference to"
  on Delphi, "of object" on FPC 3.2.2). The loader takes a string argument
  because a method can't capture the caller's local variables. OnError and
  RetryAfterMs are constructor parameters, not properties, so they never
  change while other threads use the cache. *)

interface

uses
  SysUtils,
  SyncObjs,
  Generics.Collections,
  PascalCommon.Metrics;

type
  /// Base of this unit's exceptions; also raised when a store breaks the
  /// contract (Generations returning the wrong number of values).
  EPcCache = class(Exception);

  /// Raised by a store when its backend can't answer (unreachable, timeout,
  /// pool exhausted). TPcCache treats it as a miss.
  EPcCacheUnavailable = class(EPcCache);

  /// Raised by GetOrLoad in each thread that waited for another thread's
  /// load when the loader raised: the same message, the original class
  /// name in OriginalClassName.
  EPcCacheLoadError = class(EPcCache)
  private
    FOriginalClassName: string;
  public
    constructor Create(const AOriginalClassName, AMessage: string);
    property OriginalClassName: string read FOriginalClassName;
  end;

  /// What a backend implements. Thread-safe. A failure of the backend
  /// itself raises EPcCacheUnavailable; anything else is a bug and
  /// propagates.
  IPcCacheStore = interface
    ['{2AABB5B1-A0CC-4451-AAFE-25CEBDF16391}']
    function TryGet(const AKey: string; out AValue: string): Boolean;
    /// ATtlMs <= 0 removes AKey and stores nothing.
    procedure Put(const AKey, AValue: string; ATtlMs: Int64);
    procedure Delete(const AKey: string);
    /// The current values of the tag counters, in the order of ATags; a
    /// missing counter is created with a value larger than any it had.
    function Generations(const ATags: array of string): TArray<Int64>;
    /// Moves each counter forward (a missing one may stay missing).
    procedure Bump(const ATags: array of string);
  end;

  {$IFDEF PASCALCOMMON_FUNCREFS}
  /// Loads the value of a key on a miss. AArg is GetOrLoad's argument.
  TPcCacheLoadFunc = reference to function(const AArg: string): string;
  /// Told of a store failure (AError is valid only during the call). An
  /// exception raised here is ignored.
  TPcCacheErrorProc = reference to procedure(const ACacheName: string; AError: Exception);
  {$ELSE}
  TPcCacheLoadFunc = function(const AArg: string): string of object;
  TPcCacheErrorProc = procedure(const ACacheName: string; AError: Exception) of object;
  {$ENDIF}

  IPcCache = interface
    ['{478339F8-A196-4A38-B3F0-50703E7ACB64}']
    function Name: string;
    /// The store key for an application key and its tags. Reads the tags'
    /// counters (one round trip on Redis); none without tags. '' when they
    /// can't be read (see the unit header).
    function Key(const AKey: string; const ATags: array of string): string;
    function TryGet(const AStoreKey: string; out AValue: string): Boolean;
    /// ATtlSeconds <= 0 stores nothing.
    procedure Put(const AStoreKey, AValue: string; ATtlSeconds: Integer);
    /// TryGet; on a miss ALoader(AArg), once per key among the threads that
    /// miss it together, then Put.
    function GetOrLoad(const AStoreKey: string; ATtlSeconds: Integer;
      const ALoader: TPcCacheLoadFunc; const AArg: string): string;
    /// Every key built with one of these tags stops being read. Call it
    /// after the commit. Never raises EPcCacheUnavailable.
    procedure Invalidate(const ATags: array of string);
    /// Never raises EPcCacheUnavailable.
    procedure Remove(const AStoreKey: string);
  end;

  TPcCache = class(TInterfacedObject, IPcCache)
  private
    FStore: IPcCacheStore;
    FName: string;
    FValuePrefix: string;
    FTagPrefix: string;
    FOnError: TPcCacheErrorProc;
    FRetryAfterMs: Cardinal;
    FPausedUntilMs: UInt64;
    FWaiting: Integer;
    FLoadLock: TCriticalSection;
    FLoading: TDictionary<string, TObject>;
    FHits: TPcCounterSeries;
    FMisses: TPcCounterSeries;
    FLoads: TPcCounterSeries;
    FLoadFailures: TPcCounterSeries;
    FStoreErrors: TPcCounterSeries;
    FInvalidations: TPcCounterSeries;
    function StoreUsable: Boolean;
    procedure StoreFailed(AError: Exception);
    function TagKeys(const ATags: array of string): TArray<string>;
    function Load(const ALoader: TPcCacheLoadFunc; const AArg: string): string;
    function Lead(const AStoreKey: string; ATtlSeconds: Integer;
      const ALoader: TPcCacheLoadFunc; const AArg: string; AFlight: TObject): string;
    procedure EndFlight(const AStoreKey: string; AFlight: TObject);
    procedure ReleaseFlight(AFlight: TObject);
  public
    /// AName: 1 to 64 characters of [A-Za-z0-9_.-]; prefixes the keys (two
    /// caches can share one Redis) and labels the metrics. AOnError: told of
    /// each store failure. ARetryAfterMs: how long the store is skipped after
    /// a failure (0: never skipped).
    constructor Create(const AStore: IPcCacheStore; const AName: string;
      const AOnError: TPcCacheErrorProc = nil; ARetryAfterMs: Cardinal = 1000);
    destructor Destroy; override;
    function Name: string;
    function Key(const AKey: string; const ATags: array of string): string;
    function TryGet(const AStoreKey: string; out AValue: string): Boolean;
    procedure Put(const AStoreKey, AValue: string; ATtlSeconds: Integer);
    function GetOrLoad(const AStoreKey: string; ATtlSeconds: Integer;
      const ALoader: TPcCacheLoadFunc; const AArg: string): string;
    procedure Invalidate(const ATags: array of string);
    procedure Remove(const AStoreKey: string);
    /// Threads waiting now in GetOrLoad for another thread's load (every
    /// key). For monitoring and tests.
    function LoadsWaiting: Integer;
  end;

  /// An entry or a tag counter of TPcMemoryCacheStore, in a doubly linked
  /// list (oldest first). Internal to this unit.
  TPcCacheNode = class
  public
    Key: string;
    Value: string;
    ExpiresAtMs: UInt64;
    Generation: Int64;
    Prev: TPcCacheNode;
    Next: TPcCacheNode;
  end;

  /// Internal to this unit.
  TPcCacheNodeList = class
  private
    FHead: TPcCacheNode;
    FTail: TPcCacheNode;
  public
    destructor Destroy; override;
    procedure AddLast(ANode: TPcCacheNode);
    procedure Unlink(ANode: TPcCacheNode);
    procedure MoveToEnd(ANode: TPcCacheNode);
    property Head: TPcCacheNode read FHead;
  end;

  TPcMemoryCacheStore = class(TInterfacedObject, IPcCacheStore)
  private
    FLock: TCriticalSection;
    FMaxEntries: Integer;
    FMaxTags: Integer;
    FEntries: TDictionary<string, TPcCacheNode>;
    FEntryOrder: TPcCacheNodeList;
    FTags: TDictionary<string, TPcCacheNode>;
    FTagOrder: TPcCacheNodeList;
    FSequence: Int64;
    FSwept: Boolean;
    FLastSweepMs: UInt64;
    procedure RemoveEntry(ANode: TPcCacheNode);
    procedure MakeRoom(ANowMs: UInt64);
    function NextGeneration: Int64;
  public
    /// AMaxEntries: the most entries kept; 0 keeps nothing (a cache that is
    /// off). AMaxTags: the most tag counters kept; 0 or less means
    /// AMaxEntries.
    constructor Create(AMaxEntries: Integer; AMaxTags: Integer = 0);
    destructor Destroy; override;
    function TryGet(const AKey: string; out AValue: string): Boolean;
    procedure Put(const AKey, AValue: string; ATtlMs: Int64);
    procedure Delete(const AKey: string);
    function Generations(const ATags: array of string): TArray<Int64>;
    procedure Bump(const ATags: array of string);
    /// Entries held now, expired ones not yet removed included.
    function Count: Integer;
    /// Tag counters held now.
    function TagCount: Integer;
    property MaxEntries: Integer read FMaxEntries;
    property MaxTags: Integer read FMaxTags;
  end;

implementation

uses
  PascalCommon.Threading,
  PascalCommon.SystemContext;

const
  WAIT_FOREVER = Cardinal($FFFFFFFF);
  /// The memory store looks for expired entries, when full, at most this
  /// often.
  SWEEP_INTERVAL_MS = 1000;

type
  /// A load in progress (GetOrLoad). Refs and the dictionary entry are
  /// guarded by TPcCache.FLoadLock; the result fields are written by the
  /// loading thread before Done is set and read by the others after.
  TPcCacheFlight = class
  public
    Done: TEvent;
    Refs: Integer;
    Value: string;
    Failed: Boolean;
    ErrorClassName: string;
    ErrorMessage: string;
    constructor Create;
    destructor Destroy; override;
  end;

constructor TPcCacheFlight.Create;
begin
  inherited Create;
  Done := TEvent.Create(nil, True, False, '');
end;

destructor TPcCacheFlight.Destroy;
begin
  Done.Free;
  inherited Destroy;
end;

{ EPcCacheLoadError }

constructor EPcCacheLoadError.Create(const AOriginalClassName, AMessage: string);
begin
  inherited Create(AMessage);
  FOriginalClassName := AOriginalClassName;
end;

{ TPcCache }

procedure CheckCacheName(const AName: string);
var
  I: Integer;
begin
  if (AName = '') or (Length(AName) > 64) then
    raise EArgumentException.CreateFmt('Invalid cache name "%s"', [AName]);
  for I := 1 to Length(AName) do
    if not CharInSet(AName[I], ['A'..'Z', 'a'..'z', '0'..'9', '_', '.', '-']) then
      raise EArgumentException.CreateFmt('Invalid cache name "%s"', [AName]);
end;

constructor TPcCache.Create(const AStore: IPcCacheStore; const AName: string;
  const AOnError: TPcCacheErrorProc; ARetryAfterMs: Cardinal);

  function Series(const AMetric, AUnit, ADescription: string): TPcCounterSeries;
  begin
    Result := PcMetrics.Counter(AMetric, AUnit, ADescription, ['cache']).Labels([AName]);
  end;

begin
  inherited Create;
  if AStore = nil then
    raise EArgumentException.Create('TPcCache needs a store');
  CheckCacheName(AName);
  FStore := AStore;
  FName := AName;
  FValuePrefix := AName + ':v:';
  FTagPrefix := AName + ':tag:';
  FOnError := AOnError;
  FRetryAfterMs := ARetryAfterMs;
  FLoadLock := TCriticalSection.Create;
  FLoading := TDictionary<string, TObject>.Create;
  FHits := Series('pc.cache.hits', '{hit}', 'Cache reads that found a value');
  FMisses := Series('pc.cache.misses', '{miss}',
    'Cache reads that found nothing, store failures included');
  FLoads := Series('pc.cache.loads', '{load}', 'Loader runs after a miss (GetOrLoad)');
  FLoadFailures := Series('pc.cache.load_failures', '{load}', 'Loader runs that raised');
  FStoreErrors := Series('pc.cache.store_errors', '{error}',
    'Calls to the cache store that failed because it was unavailable');
  FInvalidations := Series('pc.cache.invalidations', '{invalidation}',
    'Invalidate calls');
end;

destructor TPcCache.Destroy;
begin
  FLoading.Free;
  FLoadLock.Free;
  inherited Destroy;
end;

function TPcCache.Name: string;
begin
  Result := FName;
end;

function TPcCache.StoreUsable: Boolean;
begin
  Result := TTicker.NowMs >= PcAtomicRead64(FPausedUntilMs);
end;

procedure TPcCache.StoreFailed(AError: Exception);
begin
  FStoreErrors.Inc;
  if FRetryAfterMs > 0 then
    PcAtomicWrite64(FPausedUntilMs, TTicker.NowMs + FRetryAfterMs);
  if Assigned(FOnError) then
    try
      FOnError(FName, AError);
    except
      // A failing log callback must not turn a cache failure into an error.
    end;
end;

function TPcCache.TagKeys(const ATags: array of string): TArray<string>;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(ATags));
  for I := 0 to High(ATags) do
    Result[I] := FTagPrefix + ATags[I];
end;

function TPcCache.Key(const AKey: string; const ATags: array of string): string;
var
  LGenerations: TArray<Int64>;
  I: Integer;
begin
  Result := FValuePrefix + AKey + '|';
  if Length(ATags) = 0 then
    Exit;
  if not StoreUsable then
    Exit('');
  try
    LGenerations := FStore.Generations(TagKeys(ATags));
  except
    on E: EPcCacheUnavailable do
    begin
      StoreFailed(E);
      Exit('');
    end;
  end;
  if Length(LGenerations) <> Length(ATags) then
    raise EPcCache.CreateFmt('Cache store returned %d generations for %d tags',
      [Length(LGenerations), Length(ATags)]);
  for I := 0 to High(LGenerations) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + IntToStr(LGenerations[I]);
  end;
end;

function TPcCache.TryGet(const AStoreKey: string; out AValue: string): Boolean;
begin
  AValue := '';
  Result := False;
  if (AStoreKey <> '') and StoreUsable then
    try
      Result := FStore.TryGet(AStoreKey, AValue);
    except
      on E: EPcCacheUnavailable do
      begin
        StoreFailed(E);
        Result := False;
      end;
    end;
  if Result then
    FHits.Inc
  else
  begin
    AValue := '';
    FMisses.Inc;
  end;
end;

procedure TPcCache.Put(const AStoreKey, AValue: string; ATtlSeconds: Integer);
begin
  if (AStoreKey = '') or (ATtlSeconds <= 0) or not StoreUsable then
    Exit;
  try
    FStore.Put(AStoreKey, AValue, Int64(ATtlSeconds) * 1000);
  except
    on E: EPcCacheUnavailable do
      StoreFailed(E);
  end;
end;

function TPcCache.Load(const ALoader: TPcCacheLoadFunc; const AArg: string): string;
begin
  FLoads.Inc;
  try
    Result := ALoader(AArg);
  except
    FLoadFailures.Inc;
    raise;
  end;
end;

procedure TPcCache.EndFlight(const AStoreKey: string; AFlight: TObject);
begin
  FLoadLock.Enter;
  try
    FLoading.Remove(AStoreKey);
  finally
    FLoadLock.Leave;
  end;
  TPcCacheFlight(AFlight).Done.SetEvent;
end;

procedure TPcCache.ReleaseFlight(AFlight: TObject);
var
  LFree: Boolean;
begin
  FLoadLock.Enter;
  try
    Dec(TPcCacheFlight(AFlight).Refs);
    LFree := TPcCacheFlight(AFlight).Refs = 0;
  finally
    FLoadLock.Leave;
  end;
  if LFree then
    AFlight.Free;
end;

function TPcCache.Lead(const AStoreKey: string; ATtlSeconds: Integer;
  const ALoader: TPcCacheLoadFunc; const AArg: string; AFlight: TObject): string;
var
  LFlight: TPcCacheFlight;
begin
  LFlight := TPcCacheFlight(AFlight);
  try
    Result := Load(ALoader, AArg);
  except
    on E: Exception do
    begin
      LFlight.Failed := True;
      LFlight.ErrorClassName := E.ClassName;
      LFlight.ErrorMessage := E.Message;
      EndFlight(AStoreKey, LFlight);
      raise;
    end
    else
    begin
      // Something raised that isn't an Exception: the waiters must still wake.
      LFlight.Failed := True;
      LFlight.ErrorClassName := 'TObject';
      LFlight.ErrorMessage := 'The cache loader raised an object that is not an Exception';
      EndFlight(AStoreKey, LFlight);
      raise;
    end;
  end;
  // Stored before the flight ends, so a thread that misses after it ended
  // finds the value instead of loading again.
  try
    LFlight.Value := Result;
    Put(AStoreKey, Result, ATtlSeconds);
  finally
    EndFlight(AStoreKey, LFlight);
  end;
end;

function TPcCache.GetOrLoad(const AStoreKey: string; ATtlSeconds: Integer;
  const ALoader: TPcCacheLoadFunc; const AArg: string): string;
var
  LObject: TObject;
  LFlight: TPcCacheFlight;
  LLeader: Boolean;
begin
  if TryGet(AStoreKey, Result) then
    Exit;
  if AStoreKey = '' then
    Exit(Load(ALoader, AArg));
  FLoadLock.Enter;
  try
    LLeader := not FLoading.TryGetValue(AStoreKey, LObject);
    if LLeader then
    begin
      LFlight := TPcCacheFlight.Create;
      FLoading.Add(AStoreKey, LFlight);
    end
    else
      LFlight := TPcCacheFlight(LObject);
    Inc(LFlight.Refs);
  finally
    FLoadLock.Leave;
  end;
  try
    if LLeader then
      Result := Lead(AStoreKey, ATtlSeconds, ALoader, AArg, LFlight)
    else
    begin
      PcAtomicInc(FWaiting);
      try
        LFlight.Done.WaitFor(WAIT_FOREVER);
      finally
        PcAtomicDec(FWaiting);
      end;
      if LFlight.Failed then
        raise EPcCacheLoadError.Create(LFlight.ErrorClassName, LFlight.ErrorMessage);
      Result := LFlight.Value;
    end;
  finally
    ReleaseFlight(LFlight);
  end;
end;

procedure TPcCache.Invalidate(const ATags: array of string);
begin
  if Length(ATags) = 0 then
    Exit;
  FInvalidations.Inc;
  try
    FStore.Bump(TagKeys(ATags));
  except
    on E: EPcCacheUnavailable do
      StoreFailed(E);
  end;
end;

procedure TPcCache.Remove(const AStoreKey: string);
begin
  if AStoreKey = '' then
    Exit;
  try
    FStore.Delete(AStoreKey);
  except
    on E: EPcCacheUnavailable do
      StoreFailed(E);
  end;
end;

function TPcCache.LoadsWaiting: Integer;
begin
  Result := PcAtomicGet(FWaiting);
end;

{ TPcCacheNodeList }

destructor TPcCacheNodeList.Destroy;
var
  LNode, LNext: TPcCacheNode;
begin
  LNode := FHead;
  while LNode <> nil do
  begin
    LNext := LNode.Next;
    LNode.Free;
    LNode := LNext;
  end;
  inherited Destroy;
end;

procedure TPcCacheNodeList.AddLast(ANode: TPcCacheNode);
begin
  ANode.Prev := FTail;
  ANode.Next := nil;
  if FTail <> nil then
    FTail.Next := ANode
  else
    FHead := ANode;
  FTail := ANode;
end;

procedure TPcCacheNodeList.Unlink(ANode: TPcCacheNode);
begin
  if ANode.Prev <> nil then
    ANode.Prev.Next := ANode.Next
  else
    FHead := ANode.Next;
  if ANode.Next <> nil then
    ANode.Next.Prev := ANode.Prev
  else
    FTail := ANode.Prev;
  ANode.Prev := nil;
  ANode.Next := nil;
end;

procedure TPcCacheNodeList.MoveToEnd(ANode: TPcCacheNode);
begin
  if FTail = ANode then
    Exit;
  Unlink(ANode);
  AddLast(ANode);
end;

{ TPcMemoryCacheStore }

constructor TPcMemoryCacheStore.Create(AMaxEntries: Integer; AMaxTags: Integer);
begin
  inherited Create;
  if AMaxEntries < 0 then
    AMaxEntries := 0;
  FMaxEntries := AMaxEntries;
  if AMaxTags <= 0 then
    AMaxTags := AMaxEntries;
  FMaxTags := AMaxTags;
  FLock := TCriticalSection.Create;
  FEntries := TDictionary<string, TPcCacheNode>.Create;
  FEntryOrder := TPcCacheNodeList.Create;
  FTags := TDictionary<string, TPcCacheNode>.Create;
  FTagOrder := TPcCacheNodeList.Create;
end;

destructor TPcMemoryCacheStore.Destroy;
begin
  // The lists own the nodes; the dictionaries only point at them.
  FEntryOrder.Free;
  FTagOrder.Free;
  FEntries.Free;
  FTags.Free;
  FLock.Free;
  inherited Destroy;
end;

function TPcMemoryCacheStore.NextGeneration: Int64;
begin
  Inc(FSequence);
  Result := FSequence;
end;

procedure TPcMemoryCacheStore.RemoveEntry(ANode: TPcCacheNode);
begin
  FEntries.Remove(ANode.Key);
  FEntryOrder.Unlink(ANode);
  ANode.Free;
end;

procedure TPcMemoryCacheStore.MakeRoom(ANowMs: UInt64);
var
  LNode, LNext: TPcCacheNode;
begin
  if (not FSwept) or (ANowMs < FLastSweepMs) or (ANowMs - FLastSweepMs >= SWEEP_INTERVAL_MS) then
  begin
    FSwept := True;
    FLastSweepMs := ANowMs;
    LNode := FEntryOrder.Head;
    while LNode <> nil do
    begin
      LNext := LNode.Next;
      if ANowMs >= LNode.ExpiresAtMs then
        RemoveEntry(LNode);
      LNode := LNext;
    end;
  end;
  while (FEntries.Count >= FMaxEntries) and (FEntryOrder.Head <> nil) do
    RemoveEntry(FEntryOrder.Head);
end;

function TPcMemoryCacheStore.TryGet(const AKey: string; out AValue: string): Boolean;
var
  LNode: TPcCacheNode;
  LNowMs: UInt64;
begin
  AValue := '';
  Result := False;
  if FMaxEntries = 0 then
    Exit;
  LNowMs := TTicker.NowMs;
  FLock.Enter;
  try
    if not FEntries.TryGetValue(AKey, LNode) then
      Exit;
    if LNowMs >= LNode.ExpiresAtMs then
    begin
      RemoveEntry(LNode);
      Exit;
    end;
    AValue := LNode.Value;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TPcMemoryCacheStore.Put(const AKey, AValue: string; ATtlMs: Int64);
var
  LNode: TPcCacheNode;
  LNowMs: UInt64;
begin
  if FMaxEntries = 0 then
    Exit;
  LNowMs := TTicker.NowMs;
  FLock.Enter;
  try
    if FEntries.TryGetValue(AKey, LNode) then
    begin
      if ATtlMs <= 0 then
        RemoveEntry(LNode)
      else
      begin
        LNode.Value := AValue;
        LNode.ExpiresAtMs := LNowMs + UInt64(ATtlMs);
        FEntryOrder.MoveToEnd(LNode);
      end;
      Exit;
    end;
    if ATtlMs <= 0 then
      Exit;
    if FEntries.Count >= FMaxEntries then
      MakeRoom(LNowMs);
    LNode := TPcCacheNode.Create;
    LNode.Key := AKey;
    LNode.Value := AValue;
    LNode.ExpiresAtMs := LNowMs + UInt64(ATtlMs);
    FEntryOrder.AddLast(LNode);
    FEntries.Add(AKey, LNode);
  finally
    FLock.Leave;
  end;
end;

procedure TPcMemoryCacheStore.Delete(const AKey: string);
var
  LNode: TPcCacheNode;
begin
  if FMaxEntries = 0 then
    Exit;
  FLock.Enter;
  try
    if FEntries.TryGetValue(AKey, LNode) then
      RemoveEntry(LNode);
  finally
    FLock.Leave;
  end;
end;

function TPcMemoryCacheStore.Generations(const ATags: array of string): TArray<Int64>;
var
  I: Integer;
  LNode: TPcCacheNode;
begin
  Result := nil;
  SetLength(Result, Length(ATags));
  for I := 0 to High(Result) do
    Result[I] := 0;
  if FMaxEntries = 0 then
    Exit;
  FLock.Enter;
  try
    for I := 0 to High(ATags) do
    begin
      if FTags.TryGetValue(ATags[I], LNode) then
        FTagOrder.MoveToEnd(LNode)
      else
      begin
        while (FTags.Count >= FMaxTags) and (FTagOrder.Head <> nil) do
        begin
          LNode := FTagOrder.Head;
          FTags.Remove(LNode.Key);
          FTagOrder.Unlink(LNode);
          LNode.Free;
        end;
        LNode := TPcCacheNode.Create;
        LNode.Key := ATags[I];
        LNode.Generation := NextGeneration;
        FTagOrder.AddLast(LNode);
        FTags.Add(LNode.Key, LNode);
      end;
      Result[I] := LNode.Generation;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TPcMemoryCacheStore.Bump(const ATags: array of string);
var
  I: Integer;
  LNode: TPcCacheNode;
begin
  if FMaxEntries = 0 then
    Exit;
  FLock.Enter;
  try
    for I := 0 to High(ATags) do
      if FTags.TryGetValue(ATags[I], LNode) then
      begin
        LNode.Generation := NextGeneration;
        FTagOrder.MoveToEnd(LNode);
      end;
  finally
    FLock.Leave;
  end;
end;

function TPcMemoryCacheStore.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FEntries.Count;
  finally
    FLock.Leave;
  end;
end;

function TPcMemoryCacheStore.TagCount: Integer;
begin
  FLock.Enter;
  try
    Result := FTags.Count;
  finally
    FLock.Leave;
  end;
end;

end.
