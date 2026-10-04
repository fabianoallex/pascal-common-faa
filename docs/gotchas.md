# Gotchas

Symptom → cause → fix, numbered; new ones go at the end and keep the numbering. Gotchas
inherited with code moved from another library point to their number there (e.g.
"pascal-db-faa gotcha 1").

## 1. FPC 32-bit: `Identifier not found "InterLockedIncrement64"`

**Symptom.** A unit that compiles on FPC x86_64 fails on FPC i386 (Win32, Linux-32) with
`Identifier not found "InterLockedIncrement64"` (likewise `InterLockedExchangeAdd64`,
`InterLockedExchange64`, `InterlockedCompareExchange64`). Measured 2026-10-04 on FPC 3.2.2 i386
(Debian bookworm) with `PascalDb.Threading`; the `*64` atomics in `Pipes/AMQP/Redis.Threading`
use the same functions.

**Cause.** FPC 3.2.2 declares the 64-bit `InterLocked*` functions only inside `{$ifdef cpu64}`
in `rtl/inc/systemh.inc`. i386 implements a 64-bit compare-exchange in `rtl/i386/i386.inc` but
doesn't export it. Delphi Win32 has no such gap: `AtomicCmpExchange` and friends accept `Int64`.

**Fix.** `PascalCommon.Threading` routes the 64-bit operations through one critical section on
FPC when `CPU64` is not defined (`PASCALCOMMON_ATOMIC64_LOCK`). Correct as long as every access
to the variable goes through `PcAtomic*64`. `tools/ci-test.sh` runs the suite on i386 too, so
that path is compiled and tested.
