unit PascalCommon.WinHeap;

{$I pascalcommon.inc}

{ Delphi on Windows: the program's memory goes to the Windows process heap
  instead of the RTL's memory manager. It must be the FIRST unit in the
  program's uses (the .dpr), before SysUtils and everything else; nothing on
  FPC.

  It came from pascal-agenda-faa (Agenda.WinHeap, its api and its worker)
  in 1.26.0, unchanged but for the names; promoted at the user's choice (its
  docs/design.md, "M7: design", decision 3) rather than kept as a snippet,
  because the snippet is easy to copy wrong: it has to be the first unit and
  must allocate nothing before it switches.

  Measured in pascal-db-faa (its gotcha 55, 2026-10-28, from
  pascal-agenda-faa's load test): with the RTL's manager a Delphi program
  with several threads gained no throughput over one thread (FireDAC on
  SQLite, about 2,100 operations a second with 1, 8 or 32 threads; Zeos the
  same), while FPC's SQLdb went from 2,120 to 9,177. The process heap
  (Windows' low fragmentation heap) took FireDAC to 6,214 with 32 threads,
  with nothing else changed. The RTL's manager has one lock for all its
  medium blocks.

  It installs only when nothing was allocated yet (a block the RTL's
  manager gave can't be freed here), which holds for the first unit of the
  uses; otherwise it leaves the RTL's manager in place and says so in
  PcMemoryManagerName, which a program shows in its startup log to see
  that it took. MEMORY_MANAGER=default in the environment keeps the RTL's
  manager too, for comparing the two (read from the process environment
  only, through the API: a string would allocate, and a .env file isn't
  loaded yet at that point).

  No leak report through this manager (ReportMemoryLeaksOnShutdown is the
  RTL's): a test program doesn't put it first. This library's test runner
  links it late on purpose, and its test checks it did not install there.
  FPC: nothing (its manager is another one, and Linux has no such heap). }

interface

/// Which memory manager the program runs on, for its startup log:
/// 'windows heap'; 'delphi (MEMORY_MANAGER=default)'; 'delphi (blocks
/// allocated before PascalCommon.WinHeap)' when it wasn't the first unit;
/// 'delphi' on Delphi for another platform; 'fpc' on FPC.
function PcMemoryManagerName: string;

implementation

{$IF DEFINED(MSWINDOWS) and not DEFINED(FPC)}
uses
  Windows;

var
  GHeap: THandle;
  GName: string;

function HeapGet(Size: NativeInt): Pointer;
begin
  Result := HeapAlloc(GHeap, 0, Size);
end;

function HeapAllocZero(Size: NativeInt): Pointer;
begin
  Result := HeapAlloc(GHeap, HEAP_ZERO_MEMORY, Size);
end;

function HeapRelease(P: Pointer): Integer;
begin
  if HeapFree(GHeap, 0, P) then
    Result := 0
  else
    Result := 1;
end;

function HeapResize(P: Pointer; Size: NativeInt): Pointer;
begin
  Result := HeapReAlloc(GHeap, 0, P, Size);
end;

function NothingAllocated: Boolean;
var
  LState: TMemoryManagerState;
  I: Integer;
begin
  GetMemoryManagerState(LState);
  Result := (LState.AllocatedMediumBlockCount = 0) and (LState.AllocatedLargeBlockCount = 0);
  for I := Low(LState.SmallBlockTypeStates) to High(LState.SmallBlockTypeStates) do
    if LState.SmallBlockTypeStates[I].AllocatedBlockCount <> 0 then
      Result := False;
end;

function KeepDefault: Boolean;
var
  LBuf: array[0..15] of WideChar;
begin
  Result := (GetEnvironmentVariableW('MEMORY_MANAGER', LBuf, Length(LBuf)) = 7) and
    (LBuf[0] = 'd') and (LBuf[1] = 'e') and (LBuf[2] = 'f') and (LBuf[3] = 'a') and
    (LBuf[4] = 'u') and (LBuf[5] = 'l') and (LBuf[6] = 't');
end;

procedure Install;
var
  LManager: TMemoryManagerEx;
begin
  // No string assignment before the switch: that would allocate.
  if KeepDefault then
    Exit;
  if not NothingAllocated then
    Exit;
  GHeap := GetProcessHeap;
  GetMemoryManager(LManager);
  LManager.GetMem := HeapGet;
  LManager.AllocMem := HeapAllocZero;
  LManager.FreeMem := HeapRelease;
  LManager.ReallocMem := HeapResize;
  SetMemoryManager(LManager);
end;

function PcMemoryManagerName: string;
begin
  Result := GName;
end;

initialization
  Install;
  if GHeap <> 0 then
    GName := 'windows heap'
  else if KeepDefault then
    GName := 'delphi (MEMORY_MANAGER=default)'
  else
    GName := 'delphi (blocks allocated before PascalCommon.WinHeap)';
{$ELSE}
function PcMemoryManagerName: string;
begin
  {$IFDEF FPC}
  Result := 'fpc';
  {$ELSE}
  Result := 'delphi';
  {$ENDIF}
end;
{$IFEND}
end.
