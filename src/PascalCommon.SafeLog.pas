unit PascalCommon.SafeLog;

{$I pascalcommon.inc}

{ SafeWriteln: Writeln to the console, guarded by one critical section for the
  whole process.

  Code that runs off the main thread (HTTP handlers, pipe and messaging
  callbacks, pool threads) must not call Writeln directly: under concurrency it
  corrupts the console output. Every library in the process must also share the
  same lock, or a line from one can still land in the middle of a line from
  another. That is why this lives here: pascal-db-faa (PascalDb.SafeLog) and
  delphi-api-infra-faa (Common.SafeLog) each had their own copy with their own
  lock, and an application using both had two locks guarding one console.

  In a binary without a console (no APPTYPE CONSOLE directive: Windows service,
  VCL/LCL/FMX application) there is no standard output, and Writeln(Output)
  raises EInOutError (105) on the first call. The IsConsole check turns
  SafeWriteln into a no-op in those binaries, so the same startup code serves
  both. The overload with Format checks IsConsole before formatting, so a
  formatting error doesn't surface there either. The consequence is that
  diagnostics that only go through here vanish silently in a service: anyone
  who needs persistent logging should log somewhere else (a file log, or the
  event callbacks pascal-db-faa offers), not rely on this. On FPC for Linux
  IsConsole is always True, and Writeln works there in any binary.

  FPC gotcha (docs/gotchas.md, gotcha 8): in FPC, Output is a threadvar. Each
  thread has its own text record and buffer over the same handle, and when
  standard output is not a terminal (a file, a pipe: Docker, systemd) the RTL
  doesn't flush it on Writeln. The lock alone then guards nothing: each thread's
  buffer goes out when it fills, in the middle of a line, whenever that thread
  next writes or ends. Measured 2026-10-06 on Debian bookworm FPC 3.2.2, 8
  threads writing 2,000 lines each under one lock, stdout to a file: 2,165 of
  16,000 lines corrupted; none with a Flush(Output) inside the lock. So on FPC
  SafeWriteln flushes before releasing the lock. Delphi's Output is a single
  global with one buffer, so the lock is enough there and nothing changed.

  The two copies this replaces, compared 2026-10-06 (pascal-db-faa v0.11.0,
  delphi-api-infra-faa v0.3.0): the same two overloads, the same bodies, the
  same global TCriticalSection created in initialization and freed in
  finalization, the same IsConsole checks. The differences were around the
  code, not in it: Common.SafeLog used namespaced units (System.SysUtils,
  System.SyncObjs) and no .inc, so it didn't build on FPC; its comments were in
  Portuguese and pointed to Common.FileLog for persistent logging, where
  PascalDb.SafeLog's pointed to the pool and migration event callbacks. Neither
  flushed on FPC, so both had the problem above. }

interface

/// Writes AText and a line break to the console, guarded by a lock shared by
/// the whole process. Safe to call from any thread; a no-op when not
/// IsConsole (see the unit header).
procedure SafeWriteln(const AText: string); overload;
/// Same as SafeWriteln(Format(AFormatStr, AArgs)), but when not IsConsole it
/// returns before formatting.
procedure SafeWriteln(const AFormatStr: string; const AArgs: array of const); overload;

implementation

uses
  SysUtils,
  SyncObjs;

var
  GConsoleLock: TCriticalSection;

procedure SafeWriteln(const AText: string);
begin
  // no console means no Output handle: Writeln would raise EInOutError (105)
  if not IsConsole then
    Exit;

  GConsoleLock.Enter;
  try
    Writeln(AText);
    {$IFDEF FPC}
    // Output is per thread on FPC: send this thread's buffer out while the
    // lock is held (unit header)
    Flush(Output);
    {$ENDIF}
  finally
    GConsoleLock.Leave;
  end;
end;

procedure SafeWriteln(const AFormatStr: string; const AArgs: array of const);
begin
  // check before Format: without a console, formatting is wasted work too
  if not IsConsole then
    Exit;

  SafeWriteln(Format(AFormatStr, AArgs));
end;

initialization
  GConsoleLock := TCriticalSection.Create;

finalization
  GConsoleLock.Free;

end.
