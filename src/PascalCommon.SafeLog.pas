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

  SafeWriteln flushes Output before releasing the lock, on both compilers.
  When standard output is not a terminal (a file, a pipe: Docker, systemd, a
  Windows service wrapper) neither RTL flushes it on Writeln; the text buffer
  goes out only when it fills.

  FPC (docs/gotchas.md, gotcha 8): Output is a threadvar. Each thread has its
  own text record and 256-byte buffer over the same handle, so without the
  flush the lock guards nothing: each thread's buffer goes out when it fills,
  in the middle of a line, whenever that thread next writes or ends. Measured
  2026-10-06 on Debian bookworm FPC 3.2.2, 8 threads writing 2,000 lines each
  under one lock, stdout to a file: 2,165 of 16,000 lines corrupted; none with
  a Flush(Output) inside the lock.

  Delphi (gotcha 9): Output is one global, so lines don't interleave, but on
  Windows the RTL's TextOpen installs a flushing FlushFunc only when
  GetFileType reports a character device (a console); for a file or a pipe it
  is a no-op, and the buffer is 128 bytes. What reaches the handle is then the
  output so far cut down to a multiple of 128 bytes: the end of the last line
  waits for later output, and is lost if the process dies. Whether one line
  shows up whole depends only on where it ends relative to those 128-byte
  boundaries, not on its length. Seen from pascal-api-infra-faa on Delphi 12
  (Win32 and Win64), a server's stdout redirected to a file: a 300-byte
  access-log line stayed cut until the next one. Delphi on Linux flushes
  standard output on every Writeln already; the flush costs nothing there, nor
  on a console, where Writeln has just emptied the buffer. Flush(Output) (not
  the FlushFunc Writeln calls) goes through InOutFunc, so it writes in every
  case. Before 1.8.1 only the FPC build flushed.

  The two copies this replaces, compared 2026-10-06 (pascal-db-faa v0.11.0,
  delphi-api-infra-faa v0.3.0): the same two overloads, the same bodies, the
  same global TCriticalSection created in initialization and freed in
  finalization, the same IsConsole checks. The differences were around the
  code, not in it: Common.SafeLog used namespaced units (System.SysUtils,
  System.SyncObjs) and no .inc, so it didn't build on FPC; its comments were in
  Portuguese and pointed to Common.FileLog for persistent logging, where
  PascalDb.SafeLog's pointed to the pool and migration event callbacks. Neither
  flushed, so both had the problems above.

  PcSetSafeLogUtf8(True) (1.10.0, off by default) makes SafeWriteln write
  UTF-8 to a file or a pipe and UTF-16 to a Windows console, the same on both
  compilers (docs/gotchas.md, gotcha 11). By default neither RTL writes UTF-8
  on Windows: with stdout redirected, FPC writes in the console's code page
  (GetConsoleOutputCP, 850 here: 'caf'#$82) and Delphi in the ANSI code page
  (1252: 'caf'#$E9), and a character outside that code page becomes '?'. On a
  console both use the console's code page, so a character outside it (the
  euro sign under 850) becomes '?' too. Measured 2026-10-15 on FPC 3.2.2 and
  Delphi 12, Win64. It is opt-in because it changes the bytes a consumer's
  log already gets.

  A file or a pipe: the line goes through Output with its code page set to
  CP_UTF8 for that one Writeln and set back afterwards, inside the lock. So a
  program that reassigned Output still gets the line where it pointed Output,
  and Writeln calls outside SafeWriteln keep the old code page: a log fed by
  both mixes the two encodings. Setting the code page once at startup
  (SetTextCodePage(Output, CP_UTF8)) is not enough on FPC: Output is a
  threadvar, and another thread's Output starts with the console's code page
  again (measured: 'caf'#$C3#$A9 from the main thread, 'caf'#$82 from a
  TThread, in one file). On Delphi, Output is opened on the first write and
  keeps a code page set before that; when it was still 0 (not open yet), it
  is set back to DefaultSystemCodePage, the one Delphi's TextOpen picks for a
  file or a pipe, because 0 would make the next write reopen it.

  A Windows console: WriteConsoleW with the text as UTF-16, after flushing
  Output, so every character shows (measured by reading the screen back with
  ReadConsoleOutputCharacterW). UTF-8 bytes there show mojibake under 850,
  and SetConsoleOutputCP(CP_UTF8) changes the code page of the whole console,
  the parent shell's included. If WriteConsoleW fails before writing
  anything, the line goes the file-or-pipe way. Outside Windows only that way
  exists; it gives UTF-8 whatever the locale says. }

interface

/// Writes AText and a line break to the console, guarded by a lock shared by
/// the whole process. Safe to call from any thread; a no-op when not
/// IsConsole (see the unit header).
procedure SafeWriteln(const AText: string); overload;
/// Same as SafeWriteln(Format(AFormatStr, AArgs)), but when not IsConsole it
/// returns before formatting.
procedure SafeWriteln(const AFormatStr: string; const AArgs: array of const); overload;

/// Turns UTF-8 output on or off for SafeWriteln (off by default): UTF-8 to a
/// file or a pipe, UTF-16 through WriteConsoleW to a Windows console (see the
/// unit header). Call it once at startup; it holds for every thread. Writeln
/// calls outside SafeWriteln are not affected.
procedure PcSetSafeLogUtf8(AEnabled: Boolean);
/// Whether SafeWriteln writes UTF-8 (PcSetSafeLogUtf8).
function PcSafeLogUtf8: Boolean;

implementation

uses
  {$IFDEF PASCALCOMMON_WINDOWS}
  {$IFDEF FPC}
  Windows,
  {$ELSE}
  Winapi.Windows,
  {$ENDIF}
  {$ENDIF}
  SysUtils,
  SyncObjs;

{$IFDEF PASCALCOMMON_WINDOWS}
const
  // characters per WriteConsoleW call: older consoles reject one call much
  // larger than 64 KB
  CONSOLE_CHUNK = 8192;
{$ENDIF}

var
  GConsoleLock: TCriticalSection;
  // read and written only under GConsoleLock
  GUtf8: Boolean;

{$IFDEF PASCALCOMMON_WINDOWS}
// The console handle Output writes to, or 0 when Output goes to a file, a
// pipe, a device of the program's own, or nowhere (no console attached).
function OutputConsoleHandle: THandle;
var
  LHandle: THandle;
  LMode: DWORD;
begin
  Result := 0;
  if TTextRec(Output).Mode = fmOutput then
    LHandle := THandle(TTextRec(Output).Handle)
  else if (TTextRec(Output).Mode = fmClosed) and (TTextRec(Output).Name[0] = #0) then
    // Delphi opens the standard Output on its first write
    LHandle := GetStdHandle(STD_OUTPUT_HANDLE)
  else
    Exit;
  if GetConsoleMode(LHandle, LMode) then
    Result := LHandle;
end;

// Writes AText and a line break to the console as UTF-16. False only when
// nothing was written, so the caller can still write the line another way.
function WriteConsoleLine(AHandle: THandle; const AText: string): Boolean;
var
  LText: UnicodeString;
  P: PWideChar;
  LLeft, LChunk: Integer;
  LWritten: DWORD;
begin
  LText := UnicodeString(AText) + sLineBreak;
  P := PWideChar(LText);
  LLeft := Length(LText);
  while LLeft > 0 do
  begin
    LChunk := LLeft;
    if LChunk > CONSOLE_CHUNK then
    begin
      LChunk := CONSOLE_CHUNK;
      // don't split a surrogate pair between two calls
      if (P[LChunk - 1] >= #$D800) and (P[LChunk - 1] <= #$DBFF) then
        Dec(LChunk);
    end;
    LWritten := 0;
    if not WriteConsoleW(AHandle, P, LChunk, LWritten, nil) or (LWritten = 0) then
      Break;
    Inc(P, LWritten);
    Dec(LLeft, LWritten);
  end;
  Result := LLeft < Length(LText);
end;
{$ENDIF}

// Writeln(AText) through Output with its code page set to CP_UTF8 for this
// one line, then flushed (unit header).
procedure WritelnUtf8ToText(const AText: string);
var
  LOldCodePage: Word;
begin
  LOldCodePage := TTextRec(Output).CodePage;
  TTextRec(Output).CodePage := CP_UTF8;
  try
    Writeln(AText);
    Flush(Output);
  finally
    {$IFNDEF FPC}
    // 0: Delphi hadn't opened Output yet; give it the code page its TextOpen
    // picks for a file or a pipe, since 0 would make the next write reopen it
    if LOldCodePage = 0 then
      LOldCodePage := DefaultSystemCodePage;
    {$ENDIF}
    TTextRec(Output).CodePage := LOldCodePage;
  end;
end;

procedure WritelnUtf8(const AText: string);
{$IFDEF PASCALCOMMON_WINDOWS}
var
  LConsole: THandle;
{$ENDIF}
begin
  {$IFDEF PASCALCOMMON_WINDOWS}
  LConsole := OutputConsoleHandle;
  if LConsole <> 0 then
  begin
    // whatever an earlier Write left in the buffer goes out first
    if TTextRec(Output).Mode = fmOutput then
      Flush(Output);
    if WriteConsoleLine(LConsole, AText) then
      Exit;
  end;
  {$ENDIF}
  WritelnUtf8ToText(AText);
end;

procedure SafeWriteln(const AText: string);
begin
  // no console means no Output handle: Writeln would raise EInOutError (105)
  if not IsConsole then
    Exit;

  GConsoleLock.Enter;
  try
    if GUtf8 then
      WritelnUtf8(AText)
    else
    begin
      Writeln(AText);
      // a file or a pipe isn't flushed by Writeln on either compiler, and
      // Output is per thread on FPC: send the buffer out while the lock is
      // held (unit header)
      Flush(Output);
    end;
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

procedure PcSetSafeLogUtf8(AEnabled: Boolean);
begin
  GConsoleLock.Enter;
  try
    GUtf8 := AEnabled;
  finally
    GConsoleLock.Leave;
  end;
end;

function PcSafeLogUtf8: Boolean;
begin
  GConsoleLock.Enter;
  try
    Result := GUtf8;
  finally
    GConsoleLock.Leave;
  end;
end;

initialization
  GConsoleLock := TCriticalSection.Create;

finalization
  GConsoleLock.Free;

end.
