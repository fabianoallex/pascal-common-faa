# pascal-common-faa

Base library shared by the `*-faa` libraries — [pascal-db-faa](https://github.com/fabianoallex/pascal-db-faa),
pascal-named-pipes-faa, pascal-amqp-faa, pascal-redis-faa — for **Delphi and Lazarus/Free Pascal**
(dual-compiler, FPC 3.2.2).

> **Status: under construction.** Nothing has been released yet. See [`docs/plan.md`](docs/plan.md)
> for what is coming and in which order.

## What it will contain

- **Optional and nullable types** (`IOptXxx`, `INullXxx`, `IOptNullXxx` for String, Integer,
  Int64, Single, Double, Currency, TDateTime, Boolean and TGUID), shared so that a value read
  from a message or a request can be handed to the database layer as is.
- **Portable atomics and monotonic time** (`PcAtomicInc`, `PcAtomicRead64`, `PcTickMs`,
  `PcTickUs`...): `TInterlocked` and `TStopwatch` don't exist in FPC.
- **A monitor and a thread pool** (`TPcMonitor`, `TPcThreadPool`).
- **A clock/sleep context** (`IClock`, `ISleep`) that tests can replace, and a bounded cache
  (`TClockCache`).
- An optional bridge to [pascal-jsonmapper-faa](https://github.com/fabianoallex/pascal-jsonmapper-faa)
  for the optional types.

## Version check

A library that depends on this one states the minimum version it needs, so an application
with an older copy gets a clear build error:

```pascal
uses PascalCommon.Version;

{$IF PASCALCOMMON_VERSION < 10400}
  {$MESSAGE FATAL 'my-library needs pascal-common-faa 1.4 or later'}
{$IFEND}
```

## License

MIT — see [LICENSE](LICENSE).
