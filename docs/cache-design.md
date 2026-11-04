# Cache with expiry and tag invalidation — design

Status: **F1 done, 2026-11-04 (1.29.0)**: `PascalCommon.Cache`, green on Windows x64 and
Linux x86_64 and i386, 0 leaks, 40 runs of its suite at `--cpus=1` with 8 containers at once;
Delphi 12 CE Win32 and Win64 605/605, 0 leaks. Designed 2026-11-03: the user accepted every recommendation below as
written ("tudo conforme sugerido", 2026-11-03), C12 included. What F1 settled that the design
had left open is in "Decided in F1" below. Nothing is measured yet; the numbers quoted come
from other documents, each named where it is used.

## Where this came from

The user asked, in pascal-db-faa, whether a query cache fits that library. An outside proposal
(written by another assistant, given as input, not as an order) put the cache on the query:

```pascal
LResult := LQuery.Cached(300).WithTags(['products', 'category_1']).Open;
LFactory.Cache.ClearTags(['products']);
```

with an `ICacheStore` in pascal-db-faa (`PascalDb.Cache.Interfaces`), a `TNullCacheStore` and a
`TInMemoryCacheStore` there, a `TQueryCacheProxy` that hashes the SQL and the parameter values,
stores a snapshot of the result and replays it through `TMockQueryResult`, and a Redis store in
`adapters/cache-redis` (`pascal_db_faa_redis.lpk`) that indexes keys by tag in Redis sets.

Reviewing it against pascal-db-faa's code, the direction holds (the core sees only a contract,
a memory implementation, Redis outside), but the mechanics don't:

| The proposal | Problem, checked in pascal-db-faa's code | Here |
|---|---|---|
| `.Cached()` on `IQuery`, a hit skips the pool | an `IQuery` only exists through `IDBFactory.AcquireQuery(out AQuery; ...)`, which has already taken a pooled connection and opened a scope transaction: a hit can't skip what already happened. Changing `IQuery` also touches every adapter, the pool's `TQueryWrapper` and the mock | the cache sits **outside** the query, in the application's service: a hit takes nothing from the pool |
| key = hash of the SQL and of `IParams`' values | `IParams` can't list its names or values (on purpose: no parameter values in statement events). The proxy would have to intercept every setter (7 types × `Opt`/`Null`/`OptNull`/`Flags`) | the caller gives the key |
| a snapshot of `IQueryResult`, replayed by `TMockQueryResult` | `IQueryResult` has `FieldCount` and `FieldValue(i): Variant`, no column name or type: a snapshot can't be read back by name. A `Variant` written as text loses `Currency`, `Int64`, `TDateTime` and typed NULLs. The mock is test code | the application stores its **mapped DTO**, serialized (it also saves the mapping on a hit) |
| tags as Redis sets (`SADD`, `SMEMBERS`, then delete) | `SET` + `SADD` isn't atomic; members outlive their key's TTL; a slow reader can write old data back after the tags were cleared | **tag generations** (C4): invalidation is one `INCR`, a late writer writes under a key nobody reads |
| the store and the Redis adapter in pascal-db-faa | a cache isn't a database concern; pascal-api-infra-faa already writes its own (`TCachedTenantCatalog`); `adapters/cache-redis` would make pascal-db-faa's CI depend on Redis | contract and memory store **here**, Redis store in **pascal-redis-faa** (C1) |
| `procedure Set(...)` | `set` is a reserved word in both compilers (only `&Set` compiles) | `Put` |
| — | no rule for transactions: data read inside a transaction that wrote can be cached and then rolled back; invalidating before the commit lets a concurrent reader put the old value back | C7 |

## Why here

- **More than one library would write it.** pascal-api-infra-faa has `TCachedTenantCatalog`
  (another catalog's answers for a TTL, on `TTicker`) and its messaging guide shows a hand-made
  Redis cache in a handler (`GetCacheOrCompute`, `docs/guide/messaging.md`). Applications on
  pascal-db-faa want "a cache in front of a slow query", shared by every instance (Redis) or local
  to the process (memory).
- **`TClockCache` isn't this.** It is a fixed-size flyweight cache with no expiry, built for the
  optionals' interface instances; it stays as it is. Whether the memory store can sit on it is an
  open point (C8).
- **This library's rule is "what at least two libraries need".** Today there is one hand-written
  cache (pascal-api-infra-faa) and a wish (pascal-db-faa's applications). Writing it here before a
  second library adopts it follows the AES-GCM precedent (written here ahead of a second user, at
  the user's choice, 2026-10-18): **the user decides** (C12).

## Decisions

### C1 — where each part lives (recommended)

| Part | Library | Unit |
|---|---|---|
| contract (`IPcCacheStore`, `IPcCache`), the tag layer, single-flight, failure policy, memory store | pascal-common-faa | `PascalCommon.Cache` |
| Redis store | pascal-redis-faa (already depends on pascal-common-faa) | `Redis.Cache` (`TRedisCacheStore`) |
| a cached query helper | pascal-db-faa, **not in the first phases** | C11 |

No Null store: "no cache" is not creating one (the service gets `nil` and skips it) or a memory
store with a capacity of 0. A Null object would hide a missing configuration.

### C2 — values are strings (recommended)

The value is a `string`, in practice JSON from pascal-jsonmapper-faa. It matches how the
applications already serialize DTOs and keeps the Redis store to `SetEx`/`TryGet` as they are.
On FPC that `string` is UTF-8 under the runtime rule every `*-faa` application already follows
(a UTF-8 default code page); the Redis store sends and reads its bytes as they are.

Alternative: `TBytes`, which takes binary formats too, at the cost of a conversion on every call
for the JSON case. Adding a `TBytes` pair later is additive.

### C3 — two layers: a small store, a cache on top (recommended)

A backend implements only the store, as a pascal-db-faa adapter only wraps its driver; the rules
(keys, tags, single-flight, failures, metrics) are written once, in `TPcCache`.

```pascal
type
  /// What a backend implements. Thread-safe. Failures of the backend itself
  /// (unreachable, timeout) raise EPcCacheUnavailable; anything else is a bug
  /// and propagates.
  IPcCacheStore = interface
    function TryGet(const AKey: string; out AValue: string): Boolean;
    procedure Put(const AKey, AValue: string; ATtlMs: Int64);
    procedure Delete(const AKey: string);
    /// Current values of the tag counters, in order; a missing counter is
    /// created (C4) and its new value returned.
    function Generations(const ATags: array of string): TArray<Int64>;
    /// Moves each counter forward.
    procedure Bump(const ATags: array of string);
  end;

  TPcCacheLoadFunc = function(const AArg: string): string
    {$IFDEF PASCALCOMMON_FUNCREFS} reference to {$ELSE} of object {$ENDIF};
  // (the real declaration follows the pattern of the other public callbacks)

  IPcCache = interface
    /// The store key for an application key and its tags (reads the tags'
    /// generations: one round trip on Redis, C4).
    function Key(const AKey: string; const ATags: array of string): string;
    function TryGet(const AStoreKey: string; out AValue: string): Boolean;
    procedure Put(const AStoreKey, AValue: string; ATtlSeconds: Integer);
    /// TryGet, else ALoader(AArg) once per key in this process (C5), then Put.
    function GetOrLoad(const AStoreKey: string; ATtlSeconds: Integer;
      const ALoader: TPcCacheLoadFunc; const AArg: string): string;
    /// Every key built with one of these tags stops being read (C4).
    procedure Invalidate(const ATags: array of string);
    procedure Remove(const AStoreKey: string);
  end;
```

`TPcCache.Create(AStore, AName)`: `AName` labels the metrics (C9) and prefixes the keys, so two
caches can share one Redis.

### C4 — tag invalidation by generations (recommended)

Each tag has a counter. `Key` reads the counters of the key's tags and puts them in the store
key; `Invalidate` moves the counters forward. Nothing is deleted: entries built under an old
generation are never read again and expire by their TTL.

```
app:tag:products            -> 3
app:tag:category:7          -> 12
app:v:product.list:7|3,12   -> {"items":[...]}      (TTL 300 s)

Invalidate(['category:7'])  -> INCR app:tag:category:7      (13)
Key(...)                    -> app:v:product.list:7|3,13    (miss: the loader runs)
```

Why it is safe against the races the sets had: a reader that read generation 12, then loaded old
data from the database, writes it under `...|12`; once the counter is 13 nobody reads `...|12`.
What is left is the time between the commit and the `INCR` (C7), during which readers still get
the old entry.

Counters on Redis: no TTL, and **a missing counter starts at the current Unix time in
milliseconds, not at 0** (created with `SET NX`, then read). If Redis evicts or loses a counter
(restart without persistence, `maxmemory` eviction), starting again at 0 would bring back entries
written under 0, 1, 2... that are still within their TTL. Starting at the clock makes a reborn
counter larger than any value it had, as long as that tag was invalidated fewer than 1000 times a
second on average since its counter was created (a counter that started at T0 and was bumped n
times is at T0 + n; one reborn at T1 is larger when n < T1 − T0 in ms). See "Open points".

Cost: one read of the counters per `Key` (`MGET` of every tag, one round trip) on top of the
value's `GET`. A Lua script could do both in one round trip; measure before adding it. Keys with
no tags read no counter.

Memory store: the counters are a dictionary in the process, lost together with the values on a
restart. It drops counters while running, to bound them (C8), so it has the same reset problem
and solves it the same way, with a sequence instead of the clock.

### C5 — `GetOrLoad`: single-flight in the process (recommended)

When many threads miss the same key at once, the first runs the loader, the others wait for its
result (one lock and one entry per key being loaded). Distributed single-flight (a lock in Redis
so only one instance loads) is out: pascal-redis-faa's `TRedisLock` exists if an application
needs it.

- The loader is a method on FPC 3.2.2 (no closures), so it takes a `string` argument: a method
  can't capture the service's local variables. Delphi-only users can pass a closure
  (`PASCALCOMMON_FUNCREFS`).
- A loader exception reaches **every** waiting thread (re-raised as a new exception of the same
  message in each, since one exception object can't be raised in several threads; exact form to
  decide in F1), and nothing is stored.
- "Not found" is the application's to encode (an empty JSON array, `null`): no negative caching
  in the cache itself, which would need a sentinel the values could collide with.

### C6 — the store is optional: its failures are misses (recommended)

A cache that is down must not take the application down. In `TPcCache`:

- `TryGet`/`Key` raising `EPcCacheUnavailable` is a miss (`GetOrLoad` runs the loader);
- `Put` raising it is ignored;
- each failure goes to an `OnError` callback and a metric (C9);
- after a failure the store is **skipped for a while** (1 s by default, then retried by the next
  call). pascal-api-infra-faa's messaging guide measured, with Redis unreachable, about 2 s of
  connect attempt on **every** request; without the pause, a down cache makes every request slow.
- only `EPcCacheUnavailable` is swallowed. The Redis store maps pascal-redis-faa's connection
  failures to it (`ERedisConnectionLost`, `ERedisTimeout`, pool exhausted); an `ERedisReplyError`
  or `ERedisTypeError` is a bug and propagates, as that guide recommends.

`Invalidate` failing is different: the value is stale until its TTL. It doesn't raise (it runs
after a commit, C7, and turning a committed write into an error response is worse), it goes to
`OnError`, and **the TTL is the documented bound on staleness**. An application that can't live
with that bound shouldn't cache that data.

### C7 — transactions: rules for the caller (recommended)

This library knows no database, so the rules are documented here and in the usage guide, not
enforced:

1. **Invalidate after the commit**, never before (otherwise a concurrent reader puts the old
   value back before the new one is visible).
2. **Don't `Put` what a transaction that also wrote has read**: it may be rolled back. Read for
   the cache outside write transactions (a hit or a load in its own read-only scope).
3. Staleness between the commit and the invalidation, and when the invalidation fails (C6), is
   bounded by the TTL.

pascal-db-faa could later offer an after-commit hook on `ITransaction` so rule 1 happens by
itself (it has none today); it would also fit the outbox. Not part of this design.

### C8 — the memory store (recommended)

`TPcMemoryCacheStore.Create(AMaxEntries)`:

- expiry on `TTicker` (monotonic and replaceable in tests), checked on read: an expired entry is
  a miss and is removed;
- when full, `Put` first drops expired entries, then the oldest by insertion. Simple and
  predictable; whether a G-Clock (`TClockCache`) is worth it here is an open point to measure
  with a real workload, not to assume;
- one lock (`TCriticalSection`) for the dictionary; shards only if contention is measured;
- `AMaxEntries = 0`: stores nothing (every read misses), for a configuration that turns the cache
  off without `nil` checks. It also keeps **no tag counters**: `Generations` returns 0 for every
  tag and `Bump` does nothing, otherwise a tag per row (`product:123`) would grow a dictionary in
  a cache that is off. Single-flight and the metrics still work (`TPcCache` doesn't know the
  store is off): concurrent misses of one key still make one load, and the metrics show every
  read missing.
- **Tag counters are bounded too.** A new counter starts at the next value of one sequence for
  the whole store, not at 0, so a counter created again is always larger than any value a counter
  had before (the same guarantee as C4's clock start on Redis, without the clock). That makes
  dropping a counter safe at any time: the only cost is that the keys built with it miss once.
  When the counters reach their limit (`AMaxEntries` by default), `Generations` drops counters
  before creating one, those not read or bumped for longest first.

### C9 — metrics (recommended)

Counters on `PcMetrics`, labeled only by the cache's name (never the key: the cardinality would
grow with the data): hits, misses, loads, load failures, store errors, invalidations. Names in
this library's style for its own metrics; OpenTelemetry has no semantic convention for an
application cache. Spans: none by default (a hit is microseconds); the loader's own work (a
database query) already has pascal-db-faa's.

### C10 — keys (recommended)

- Store key = cache name + `:v:` + application key + `|` + the generations, comma-separated
  (see "Decided in F1"). The application key
  is used as it is, so it can be read in Redis (`SCAN app:v:product.*`).
- **No secrets in keys**: they show in `MONITOR`, `SCAN` and slow logs. A key built from a token
  or a password hash is the application's bug; hash it first (`PcSha256`) if it must depend on
  one.
- Tags are few per key (each one is a counter read); a tag per row (`product:123`) is fine, a
  dozen tags per key is a sign of the wrong granularity.

### C11 — pascal-db-faa: nothing in the first phases (recommended)

Caching the application's DTO covers the cases seen so far. A helper that caches raw rows
(`PdbCachedOpen(Factory, Cache, Key, Tags, Ttl, Sql, ParamNames, ParamValues): IQueryResult`,
taking a connection only on a miss and returning an in-memory result) needs `IQueryResult` to
give each column's name and type (`FieldName(i)`, `FieldType(i)`: additive, but the three
adapters and the mock change) and a serialization of typed rows. Only with a concrete need.

### C12 — written ahead of a second library? (the user's choice)

Options: (a) build F1 now, as was done for AES-GCM; (b) wait until pascal-api-infra-faa moves
`TCachedTenantCatalog` onto it or an application asks. Recommendation: (a), with
pascal-api-infra-faa's tenant catalog as the first consumer to validate the contract.

## Decided in F1 (2026-11-04)

- **Store key**: `<name>:v:<key>|<g1>,<g2>`, the generations separated by commas, not by `|` as
  C4's example had. With `|` between the generations, the key `a|1` with its tag at 2 and the
  key `a` with two tags at 1 and 2 gave the same store key. The generations never contain `|`,
  so the last `|` separates them and the store key is unambiguous. A key without tags ends in
  `|`.
- **`Key` when the counters can't be read** (store down or in the pause): it returns `''`, and
  `TryGet`, `Put`, `GetOrLoad` and `Remove` treat `''` as a key that is never stored; `GetOrLoad`
  then runs the loader, without single-flight.
- **A loader's exception (C5)**: the thread that ran it gets the original; each thread that
  waited gets `EPcCacheLoadError`, with the same message and the original class name in
  `OriginalClassName`.
- **`OnError` and the pause (C6)** are constructor parameters, `TPcCache.Create(Store, Name,
  OnError = nil, RetryAfterMs = 1000)`, so they never change while threads use the cache.
  `OnError(CacheName, E)`; an exception it raises is ignored. `Invalidate` and `Remove` try the
  store even during the pause.
- **TTL**: `Put` with 0 or less stores nothing (and in the store, removes the key).
- **Metrics (C9)**: `pc.cache.hits`, `pc.cache.misses`, `pc.cache.loads`,
  `pc.cache.load_failures`, `pc.cache.store_errors`, `pc.cache.invalidations`, label `cache`
  (Prometheus: `pc_cache_hits_total{cache="app"}`...). A read that a store failure turned into a
  miss counts as a miss and as a store error.
- **Memory store (C8)**: entries in insertion order in a linked list (O(1) to drop the oldest);
  when full, it looks for expired entries at most once a second (a full scan), then drops the
  oldest. Tag counters are a list in use order: `Generations` and `Bump` move a counter to the
  end, and the least recently used is dropped. `Bump` takes a new value from the store's
  sequence (not +1), which is what keeps a counter created again above any value any counter
  had; `Bump` of a counter that doesn't exist does nothing. `AMaxTags` is a second constructor
  parameter (0: `AMaxEntries`).
- **`TPcCache.LoadsWaiting`**: the threads waiting now for another thread's load. Added so the
  single-flight test releases the loader once every other thread is waiting, instead of hoping
  after a `Sleep`; also useful as a gauge.
- **For the Redis store (F2)**: `Bump` of a missing counter must not create it at 1 (`INCR` on a
  missing key does); create it from the clock as C4 says, or leave it missing.

## Found in F3 (2026-11-04)

pascal-api-infra-faa's `TCachedTenantCatalog` (0.32.0), the first consumer of the contract. What
it showed is written down here; the catalog doesn't work around any of it.

- **Reading a key creates its tags' counters, and on Redis they never go away.** `Key` reads
  `Generations`, which creates a missing counter (C4; `TRedisCacheStore`: `SET NX`, no TTL). When
  a tag comes from client input, every distinct value a client sends leaves one key in Redis for
  good, even when no value is ever stored under it. The catalog's case: `Find` builds its key
  with the tag `tenant:<id>` before it knows whether the tenant exists, and it stores found
  tenants only (a login can name any id), so each unknown id a client tries leaves a counter
  `<name>:tag:tenant:<id>`. The memory store bounds its counters (C8); Redis doesn't. C10's "a
  tag per row is fine" holds for rows that exist, not for ids a client chooses. The catalog
  limits what an id can be (`ValidTenantId`: `[a-z0-9-]`, 1 to 40 characters), not how many.
  Options, for the user to decide (none taken):
  - (a) **a TTL on the counters in Redis** (a day, say), set when one is created. Safe by C4's own
    argument: a counter that expires is born again from the clock, above any value it had, so
    entries written under the old value are never read; the cost is one miss per key per counter
    lifetime. A counter that is read often could have its TTL renewed, at the price of a write on
    a read.
  - (b) `Generations` doesn't create a missing counter: `Key` returns `''` (a miss, as with a store
    that is down) and `Put` creates the counters. The first read of a key would then miss twice.
  - (c) leave it, documented (what pascal-api-infra-faa 0.32.0 does: the class comment says so).

  Recommendation: (a).
- **`GetOrLoad` can't leave a result out.** It stores whatever the loader returns (C5: "not
  found" is the application's to encode). A cache of found answers only has no value to store
  for a miss, so the catalog uses `TryGet` + `Put` and loses single-flight: requests that miss one
  tenant at once each query the control database, as before the cache (once per tenant per TTL,
  so it doesn't matter there). A loader that can say "don't store this"
  (`function(const AArg: string; out AValue: string): Boolean`, False: nothing stored, the
  caller told) would keep single-flight for such a cache. Additive; not needed yet.
- **A tag on every key can't also be what drops the aggregates.** The catalog's keys are each
  tenant (tags `tenants`, `tenant:<id>`) and the list of all (`tenants`). `Invalidate(id)` must
  drop that tenant and the list and keep every other tenant; moving `tenants` drops them all, so
  the list has a tag of its own (`tenants.list`) that a change to any tenant moves. Not a
  problem of the contract; a pattern for "Usage": one tag for everything, one per item, one per
  aggregate that a change to any item invalidates.
- **A hit on Redis is two round trips** (`MGET` of the tags, then `GET`). The catalog is read on
  every authenticated request; its old dictionary cost none. Not measured end to end; the pair
  in one script (C4's open point) would make it one. With the catalog's own memory store (its
  default), there is no round trip.
- **What worked as designed.** The failure policy needed no code in the catalog: a store down is
  a miss, `OnError` once, then the pause; `Invalidate` doesn't raise. Measured through
  pascal-api-infra-faa's messaging guide (FPC 3.2.2/Windows, Redis unreachable, nothing on the
  port): the first request paid the connect attempt, about 2 s per address the host resolves to
  (4.1 s for `localhost`, `::1` then `127.0.0.1`; 2.0 s for `127.0.0.1`), the next ones within the
  1 s pause took 3 ms, the first after it paid again; without the cache every request paid it.
  So C6's "about 2 s on every request" is per address, and the pause makes it one request per
  pause-plus-attempt. `Key` returning `''` needed no special case (the read misses, `Put` does
  nothing). Two catalogs on one `IPcCache` see each other's `Invalidate` (a unit test there),
  which retires the Pub/Sub the catalog's comment suggested. Values as strings (C2): the catalog
  writes its record as JSON with pascal-jsonmapper-faa's writer and parser (the mapper reads
  classes; the tenant is a record), and a value that doesn't decode is a miss.

## Usage

```pascal
function TProductService.ListByCategory(ACategoryId: Integer): TProductList;
var
  LKey, LJson: string;
begin
  LKey := FCache.Key('product.list:' + IntToStr(ACategoryId),
    ['products', 'category:' + IntToStr(ACategoryId)]);
  if FCache.TryGet(LKey, LJson) then
    Exit(JsonToProducts(LJson));                       // hit: no pool, no database
  Result := FRepository.ListByCategory(ACategoryId);   // miss: the usual query
  FCache.Put(LKey, ProductsToJson(Result), 300);
end;

procedure TProductService.UpdatePrice(AProductId, ACategoryId: Integer; APrice: Currency);
begin
  FRepository.UpdatePrice(AProductId, APrice);        // commits inside
  FCache.Invalidate(['category:' + IntToStr(ACategoryId)]);   // after the commit (C7)
end;
```

With single-flight (C5), the loader as a method:

```pascal
function TProductService.LoadCategory(const AArg: string): string;
begin
  Result := ProductsToJson(FRepository.ListByCategory(StrToInt(AArg)));
end;

LJson := FCache.GetOrLoad(LKey, 300, LoadCategory, IntToStr(ACategoryId));
```

Composition root:

```pascal
if Config.UseRedis then
  LStore := TRedisCacheStore.Create(RedisPool)     // pascal-redis-faa
else
  LStore := TPcMemoryCacheStore.Create(10000);
FCache := TPcCache.Create(LStore, 'app');
```

## Tests

- **Here** (mirrored DUnitX/FPCUnit like the other suites, 0 leaks on both compilers): expiry
  with a fake `TTicker`; eviction when full; tags (a key with two tags misses after either is
  invalidated, a key with other tags still hits); single-flight (N threads on one key, the loader
  runs once, every thread gets its value; a loader that raises reaches every thread and stores
  nothing); the failure policy with a fake store that raises `EPcCacheUnavailable` (miss, ignored
  `Put`, `OnError`, the pause, then a retry) and one that raises something else (propagates);
  `AMaxEntries = 0` (every read misses, no counter is kept after many distinct tags, a load still
  runs once for concurrent misses); the counter limit (a dropped counter comes back larger, and
  an entry written under its old value isn't read).
- **pascal-redis-faa**, against its Redis container: the same store cases; a counter deleted
  (as eviction would) comes back larger than any value it had and an entry written before isn't
  read; the error mapping with the server stopped.
- Concurrency runs at `--cpus=1` with several containers at once, as for the time zones and the
  pool: races in single-flight show there first.

## Open points to measure

- C4: the clock start of a reborn counter against a tag invalidated more than 1000 times a
  second on average (its counter passes the clock); if it matters, start at `max(clock, last seen)` kept by
  the process, or use a random 63-bit start.
- C4: `MGET` + `GET` (two round trips) against one Lua script, on a real network. Measured in
  F2 for the store alone (pascal-redis-faa, Docker Desktop on Windows, ~0.5 ms a round trip):
  `MGET`, a read-and-create script and `MULTI`/`SET NX`/`INCR`/`EXEC` all cost one round trip,
  no difference above the noise, so the store reads with `MGET`. The `MGET` + `GET` pair in one
  script is `TPcCache`'s and was not measured.
- C8: lock contention of the memory store with 8 to 32 threads; insertion order against G-Clock
  on a hit rate taken from an application.
- C5: the cost of the per-key entry when there are many distinct keys at once.
- C2: a value with non-ASCII text through Redis on FPC/Linux and Delphi (round trip byte for
  byte). FPC on Windows and Linux done in F2 (`'São Paulo'` checked as bytes on the server, both
  ways) and on Delphi 12 Win32 and Win64.

## Phases

| Phase | Where | What | Done when |
|---|---|---|---|
| F1 | here | `PascalCommon.Cache`: contracts, `TPcCache`, `TPcMemoryCacheStore`, tests | suites green on FPC (Windows, Linux x86_64 and i386) and Delphi 12 CE Win32/Win64, 0 leaks; minor release — **FPC done 2026-11-04 (1.29.0)**: 605/605 on Windows x64, 527/527 on Linux x86_64 and i386 (26 cache tests), 0 leaks; 40 runs of the cache suite green at `--cpus=1` with 8 containers at once. Delphi 12 CE Win32 and Win64: 605/605, 0 leaks |
| F2 | pascal-redis-faa | `Redis.Cache` (`TRedisCacheStore`) on that release | its integration tests green against Redis, Linux and Windows — **FPC done 2026-11-04 (pascal-redis-faa 0.5.0)**: 11 cache tests, integration 87/87 on Windows x64 and Linux x86_64, 0 leaks; 20 runs at `--cpus=1` with 4 containers at once. `Generations` is `MGET` (a missing counter: `SET NX` from the client's clock and the `MGET` of the missing ones in the same pipeline); `Bump` is a Lua script that increments only a counter that exists, so a missing one stays missing. Delphi 12 CE Win32 and Win64 (Debug and OpenSSL): integration 87/87, 0 leaks. Its `docs/DECISOES.md`, section 54 |
| F3 | pascal-api-infra-faa | `TCachedTenantCatalog` on `IPcCache`; the messaging guide's example rewritten | its suites green; first consumer of the contract — **Done 2026-11-04 (pascal-api-infra-faa 0.32.0)**: FPC: 503 unit tests (9 for the catalog) on Windows x64 and Linux, 0 leaks; HTTP scenarios green, sample 03 with the catalog in Redis on two instances. What it showed: "Found in F3". Delphi 12 CE Win32 and Win64: 503/503, 0 leaks, HTTP scenarios green (the catalog in Redis on two instances too) |
| F4 | pascal-db-faa | C11, only if an application needs raw rows cached | — |

## Sources

- pascal-db-faa: `src/PascalDb.Interfaces.pas` (`IQuery`, `IQueryResult`, `IParams`,
  `IDBFactory.AcquireQuery`), `src/PascalDb.Pool.pas` (`TQueryWrapper`), `src/PascalDb.Mock.pas`
  (`TMockQueryResult`).
- pascal-api-infra-faa: `src/PascalApi.Tenancy.pas` (`TCachedTenantCatalog`),
  `docs/guide/messaging.md` ("Where the server is optional": ~2 s per request with Redis down).
- pascal-redis-faa: `src/Redis.Commands.Strings.pas` (`SetEx`, `TryGet`, `Incr`, `MGet`),
  `Redis.Lock` (`TRedisLock`).
- This library: `src/PascalCommon.ClockCache.pas`, `src/PascalCommon.SystemContext.pas`
  (`TTicker`), `src/PascalCommon.Metrics.pas`.
