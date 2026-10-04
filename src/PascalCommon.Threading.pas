unit PascalCommon.Threading;

{$I pascalcommon.inc}

{ Portable atomic operations (PcAtomicXxx) and monotonic time in milliseconds
  (PcTickMs) and microseconds (PcTickUs), for Delphi and Free Pascal.

  Merged from the copies each library carried: PascalDb.Threading (Int64
  counters, PdbTickUs) and the shared part of Pipes/AMQP/Redis.Threading
  (32-bit Get/Set/CompareExchange, UInt64 ticks, PipeAtomicCompareExchange64
  and PipeAtomicAdd64). TInterlocked and TStopwatch are not used because
  neither exists in FPC; these are thin wrappers over each compiler's
  intrinsics (AtomicXxx in Delphi, InterLockedXxx in FPC).

  The 64-bit operations come in two overloads, Int64 and UInt64, because the
  donors disagree (pascal-db-faa counts in Int64, the others keep ticks in
  UInt64). A var parameter must match its type exactly, so the variable picks
  the overload and a literal second argument is never ambiguous. Both share
  one Int64 implementation: the UInt64 versions reinterpret the same 8 bytes.
  They matter on 32-bit targets, where a plain 64-bit load or store can be
  torn (read halfway through another thread's write).

  Arithmetic wraps around, with overflow and range checks off for this unit
  whatever the project says: the stored value wraps in hardware anyway, and a
  checked addition on the returned copy would raise after the shared value
  had already changed.

  FPC 3.2.2 declares the InterLocked*64 functions only for 64-bit CPUs (inside
  "ifdef cpu64" in rtl/inc/systemh.inc; i386 implements a 64-bit compare-
  exchange but doesn't export it). On FPC for a 32-bit CPU the 64-bit
  operations therefore go through one process-wide critical section. That is
  correct as long as every access to the variable goes through PcAtomic*64,
  which is the rule anyway. Delphi Win32 has AtomicCmpExchange on Int64.

  PcTickMs is GetTickCount64, which on Windows advances in steps of 15-16 ms
  (measured): fine for timeouts and idle ages, useless for timing something
  that takes 2 ms. PcTickUs reads QueryPerformanceCounter on Windows (10 MHz
  measured on Windows 11), TStopwatch's timestamp on Delphi elsewhere and
  CLOCK_MONOTONIC on FPC for Linux. On other FPC targets (macOS, the BSDs) it
  falls back to GetTickCount64 * 1000, so it has millisecond resolution there.
  The performance-counter frequency is read in the unit's initialization, not
  on first use. }

{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

interface

/// Increments/decrements atomically; returns the NEW value.
function PcAtomicInc(var ATarget: Integer): Integer;
function PcAtomicDec(var ATarget: Integer): Integer;
/// Atomic read of a shared Integer.
function PcAtomicGet(var ATarget: Integer): Integer;
/// Stores AValue atomically; returns the OLD value.
function PcAtomicSet(var ATarget: Integer; AValue: Integer): Integer;
/// Stores ANew only if the current value is AComparand; returns the OLD value
/// (classic compare-and-swap, for CAS loops).
function PcAtomicCompareExchange(var ATarget: Integer; ANew, AComparand: Integer): Integer;

/// Increments atomically; returns the NEW value.
function PcAtomicInc64(var ATarget: Int64): Int64; overload;
function PcAtomicInc64(var ATarget: UInt64): UInt64; overload;
/// Adds ADelta atomically; returns the NEW value.
function PcAtomicAdd64(var ATarget: Int64; ADelta: Int64): Int64; overload;
function PcAtomicAdd64(var ATarget: UInt64; ADelta: UInt64): UInt64; overload;
/// Atomic 64-bit read and write (never torn, also on 32-bit targets).
function PcAtomicRead64(var ATarget: Int64): Int64; overload;
function PcAtomicRead64(var ATarget: UInt64): UInt64; overload;
procedure PcAtomicWrite64(var ATarget: Int64; AValue: Int64); overload;
procedure PcAtomicWrite64(var ATarget: UInt64; AValue: UInt64); overload;
/// Stores ANew only if the current value is AComparand; returns the OLD value.
function PcAtomicCompareExchange64(var ATarget: Int64; ANew, AComparand: Int64): Int64; overload;
function PcAtomicCompareExchange64(var ATarget: UInt64; ANew, AComparand: UInt64): UInt64; overload;

/// Monotonic milliseconds (GetTickCount64), for timeouts and ages without
/// depending on the wall clock.
function PcTickMs: UInt64;

/// Monotonic microseconds, for timing short operations (see the unit header
/// for the source on each platform). Only differences between two calls mean
/// anything.
function PcTickUs: Int64;

implementation

uses
  {$IFDEF FPC}
    {$IFDEF PASCALCOMMON_WINDOWS}Windows,{$ENDIF}
    {$IFDEF LINUX}Linux, UnixType,{$ENDIF}
  {$ELSE}
  System.Diagnostics,
  {$ENDIF}
  SysUtils,
  Classes;

{$IF DEFINED(FPC) and not DEFINED(CPU64)}
  {$DEFINE PASCALCOMMON_ATOMIC64_LOCK}
{$IFEND}

{$IFDEF PASCALCOMMON_ATOMIC64_LOCK}
var
  G64Lock: TRTLCriticalSection;
{$ENDIF}

{ --- 32 bits --- }

function PcAtomicInc(var ATarget: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterLockedIncrement(ATarget);
  {$ELSE}
  Result := AtomicIncrement(ATarget);
  {$ENDIF}
end;

function PcAtomicDec(var ATarget: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterLockedDecrement(ATarget);
  {$ELSE}
  Result := AtomicDecrement(ATarget);
  {$ENDIF}
end;

function PcAtomicGet(var ATarget: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterlockedCompareExchange(ATarget, 0, 0);
  {$ELSE}
  Result := AtomicCmpExchange(ATarget, 0, 0);
  {$ENDIF}
end;

function PcAtomicSet(var ATarget: Integer; AValue: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterLockedExchange(ATarget, AValue);
  {$ELSE}
  Result := AtomicExchange(ATarget, AValue);
  {$ENDIF}
end;

function PcAtomicCompareExchange(var ATarget: Integer; ANew, AComparand: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterlockedCompareExchange(ATarget, ANew, AComparand);
  {$ELSE}
  Result := AtomicCmpExchange(ATarget, ANew, AComparand);
  {$ENDIF}
end;

{ --- 64 bits: the three primitives everything else is built on --- }

// Returns the OLD value.
function Cas64(var ATarget: Int64; ANew, AComparand: Int64): Int64;
begin
  {$IF DEFINED(PASCALCOMMON_ATOMIC64_LOCK)}
  EnterCriticalSection(G64Lock);
  try
    Result := ATarget;
    if Result = AComparand then
      ATarget := ANew;
  finally
    LeaveCriticalSection(G64Lock);
  end;
  {$ELSEIF DEFINED(FPC)}
  Result := InterlockedCompareExchange64(ATarget, ANew, AComparand);
  {$ELSE}
  Result := AtomicCmpExchange(ATarget, ANew, AComparand);
  {$IFEND}
end;

// Returns the OLD value.
function ExchangeAdd64(var ATarget: Int64; ADelta: Int64): Int64;
begin
  {$IF DEFINED(PASCALCOMMON_ATOMIC64_LOCK)}
  EnterCriticalSection(G64Lock);
  try
    Result := ATarget;
    ATarget := Result + ADelta;
  finally
    LeaveCriticalSection(G64Lock);
  end;
  {$ELSEIF DEFINED(FPC)}
  Result := InterLockedExchangeAdd64(ATarget, ADelta);
  {$ELSE}
  Result := AtomicIncrement(ATarget, ADelta) - ADelta;
  {$IFEND}
end;

// Returns the OLD value.
function Exchange64(var ATarget: Int64; AValue: Int64): Int64;
begin
  {$IF DEFINED(PASCALCOMMON_ATOMIC64_LOCK)}
  EnterCriticalSection(G64Lock);
  try
    Result := ATarget;
    ATarget := AValue;
  finally
    LeaveCriticalSection(G64Lock);
  end;
  {$ELSEIF DEFINED(FPC)}
  Result := InterLockedExchange64(ATarget, AValue);
  {$ELSE}
  Result := AtomicExchange(ATarget, AValue);
  {$IFEND}
end;

{ --- 64 bits: public API --- }

function PcAtomicInc64(var ATarget: Int64): Int64;
begin
  Result := ExchangeAdd64(ATarget, 1) + 1;
end;

function PcAtomicInc64(var ATarget: UInt64): UInt64;
begin
  Result := UInt64(ExchangeAdd64(PInt64(@ATarget)^, 1)) + 1;
end;

function PcAtomicAdd64(var ATarget: Int64; ADelta: Int64): Int64;
begin
  Result := ExchangeAdd64(ATarget, ADelta) + ADelta;
end;

function PcAtomicAdd64(var ATarget: UInt64; ADelta: UInt64): UInt64;
begin
  Result := UInt64(ExchangeAdd64(PInt64(@ATarget)^, Int64(ADelta))) + ADelta;
end;

function PcAtomicRead64(var ATarget: Int64): Int64;
begin
  Result := Cas64(ATarget, 0, 0);
end;

function PcAtomicRead64(var ATarget: UInt64): UInt64;
begin
  Result := UInt64(Cas64(PInt64(@ATarget)^, 0, 0));
end;

procedure PcAtomicWrite64(var ATarget: Int64; AValue: Int64);
begin
  Exchange64(ATarget, AValue);
end;

procedure PcAtomicWrite64(var ATarget: UInt64; AValue: UInt64);
begin
  Exchange64(PInt64(@ATarget)^, Int64(AValue));
end;

function PcAtomicCompareExchange64(var ATarget: Int64; ANew, AComparand: Int64): Int64;
begin
  Result := Cas64(ATarget, ANew, AComparand);
end;

function PcAtomicCompareExchange64(var ATarget: UInt64; ANew, AComparand: UInt64): UInt64;
begin
  Result := UInt64(Cas64(PInt64(@ATarget)^, Int64(ANew), Int64(AComparand)));
end;

{ --- Time --- }

function PcTickMs: UInt64;
begin
  {$IFDEF FPC}
  Result := GetTickCount64;
  {$ELSE}
  Result := TThread.GetTickCount64;
  {$ENDIF}
end;

{$IF DEFINED(FPC) and DEFINED(PASCALCOMMON_WINDOWS)}
var
  GPerfFrequency: Int64;
{$IFEND}

function PcTickUs: Int64;
{$IF DEFINED(FPC) and DEFINED(PASCALCOMMON_WINDOWS)}
var
  LCount: Int64;
begin
  QueryPerformanceCounter(LCount);
  Result := (LCount div GPerfFrequency) * 1000000 +
    (LCount mod GPerfFrequency) * 1000000 div GPerfFrequency;
end;
{$ELSEIF DEFINED(FPC) and DEFINED(LINUX)}
var
  LTime: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @LTime);
  Result := Int64(LTime.tv_sec) * 1000000 + LTime.tv_nsec div 1000;
end;
{$ELSEIF DEFINED(FPC)}
begin
  Result := Int64(GetTickCount64) * 1000;
end;
{$ELSE}
var
  LStamp: Int64;
begin
  LStamp := TStopwatch.GetTimeStamp;
  Result := (LStamp div TStopwatch.Frequency) * 1000000 +
    (LStamp mod TStopwatch.Frequency) * 1000000 div TStopwatch.Frequency;
end;
{$IFEND}

initialization
  {$IFDEF PASCALCOMMON_ATOMIC64_LOCK}
  InitCriticalSection(G64Lock);
  {$ENDIF}
  {$IF DEFINED(FPC) and DEFINED(PASCALCOMMON_WINDOWS)}
  QueryPerformanceFrequency(GPerfFrequency);
  {$IFEND}

finalization
  {$IFDEF PASCALCOMMON_ATOMIC64_LOCK}
  DoneCriticalSection(G64Lock);
  {$ENDIF}

end.
