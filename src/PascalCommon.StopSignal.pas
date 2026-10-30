unit PascalCommon.StopSignal;

{$I pascalcommon.inc}

{ A console program's stop request: Ctrl+C, Ctrl+Break or the console
  closing on Windows; SIGINT or SIGTERM on Unix (Ctrl+C, docker stop,
  systemd). The handler only raises a flag: the program's loop asks
  PcStopRequested between passes, finishes the one it is in and shuts down
  in its own order.

  It came from pascal-agenda-faa (Agenda.StopSignal, its api and its worker)
  in 1.26.0, unchanged but for the names; promoted at the user's choice (its
  docs/design.md, "M7: design", decision 2). PcBlockStopSignals came with
  it from that application's api program, where it lived outside the unit.

  - Windows: SetConsoleCtrlHandler. The handler runs on a thread the system
    creates. When the console closes, the system ends the process as soon
    as the handler returns (and a few seconds later anyway), so for that one
    it waits for PcStopSignalDone, at most PC_STOP_CLOSE_WAIT_MS.
  - FPC on Unix: fpSignal. The handler only sets an integer (what a signal
    handler may do); the program's threads read it.
  - PcStopSleep sleeps in short slices, so a stop doesn't wait out a long
    sleep.
  - PcBlockStopSignals (FPC on Unix; nothing elsewhere) blocks SIGINT and
    SIGTERM on the calling thread, so the kernel hands them to another
    thread. The case it is for: a server whose main thread sits in accept.
    A signal delivered to that thread interrupts the accept (EINTR), and
    FPC 3.2.2's web application (fphttpapp, under Horse) takes that for an
    error and listens again: measured in pascal-agenda-faa on Linux, the
    process went on in accept after a SIGTERM, with the accepted
    connections in CLOSE_WAIT ("M5: under load" there; gotcha 14 here).
    So: install the
    handlers, start the thread that watches PcStopRequested and stops the
    server, then call PcBlockStopSignals on the thread that accepts. The
    order matters: a thread inherits the signal mask of the thread that
    creates it, so a watcher started after the block would block them too,
    and nobody would receive them. tools/test_stop_signal_docker.sh sends a
    real SIGTERM to a program built that way.

  Delphi for a non-Windows target is not covered (neither branch compiles
  there), as in the application it came from. }

interface

const
  /// Windows, console closing: how long the handler waits for the program's
  /// shutdown before returning (the system kills the process after ~5 s).
  PC_STOP_CLOSE_WAIT_MS = 4500;
  /// PcStopSleep's slice.
  PC_STOP_SLICE_MS = 50;

/// Installs the handlers; once, from the main thread, before the loop.
procedure PcStopSignalInstall;
/// Removes them (Windows) or restores the default action (Unix).
procedure PcStopSignalUninstall;
/// A stop was asked for (a signal or PcRequestStop).
function PcStopRequested: Boolean;
/// Asks for a stop from the program itself (a fatal error, a test).
procedure PcRequestStop;
/// Sleeps up to AMilliseconds, returning early on a stop; True when a stop
/// was asked for.
function PcStopSleep(AMilliseconds: Integer): Boolean;
/// The program finished shutting down: a handler waiting for it (Windows,
/// the console closing) may return.
procedure PcStopSignalDone;
/// FPC on Unix: blocks SIGINT and SIGTERM on the calling thread (and on the
/// threads it creates from then on), so they reach a thread started before.
/// Call it on the thread that accepts connections, after starting the
/// watcher. Does nothing on other platforms.
procedure PcBlockStopSignals;

implementation

uses
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  {$IFDEF FPC}{$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}{$ENDIF}
  SysUtils,
  PascalCommon.Threading;

var
  GStop: Integer = 0;
  GDone: Integer = 0;

function PcStopRequested: Boolean;
begin
  Result := PcAtomicGet(GStop) <> 0;
end;

procedure PcRequestStop;
begin
  PcAtomicSet(GStop, 1);
end;

procedure PcStopSignalDone;
begin
  PcAtomicSet(GDone, 1);
end;

function PcStopSleep(AMilliseconds: Integer): Boolean;
var
  LLeft, LSlice: Integer;
begin
  LLeft := AMilliseconds;
  while (LLeft > 0) and not PcStopRequested do
  begin
    LSlice := LLeft;
    if LSlice > PC_STOP_SLICE_MS then
      LSlice := PC_STOP_SLICE_MS;
    Sleep(LSlice);
    Dec(LLeft, LSlice);
  end;
  Result := PcStopRequested;
end;

{$IFDEF MSWINDOWS}
const
  // Windows' values (wincon.h); not every RTL version names all of them.
  STOP_CTRL_C = 0;
  STOP_CTRL_BREAK = 1;
  STOP_CTRL_CLOSE = 2;

function ConsoleHandler(ACtrlType: DWORD): BOOL; stdcall;
var
  LWaited: Integer;
begin
  Result := (ACtrlType = STOP_CTRL_C) or (ACtrlType = STOP_CTRL_BREAK) or
    (ACtrlType = STOP_CTRL_CLOSE);
  if not Result then
    Exit;
  PcRequestStop;
  if ACtrlType = STOP_CTRL_CLOSE then
  begin
    LWaited := 0;
    while (PcAtomicGet(GDone) = 0) and (LWaited < PC_STOP_CLOSE_WAIT_MS) do
    begin
      Sleep(PC_STOP_SLICE_MS);
      Inc(LWaited, PC_STOP_SLICE_MS);
    end;
  end;
end;

procedure PcStopSignalInstall;
begin
  if not SetConsoleCtrlHandler(@ConsoleHandler, True) then
    RaiseLastOSError;
end;

procedure PcStopSignalUninstall;
begin
  SetConsoleCtrlHandler(@ConsoleHandler, False);
end;

procedure PcBlockStopSignals;
begin
  // Windows delivers console events on a thread of their own.
end;
{$ENDIF}

{$IFDEF FPC}{$IFDEF UNIX}
procedure UnixStopHandler(ASignal: cint); cdecl;
begin
  PcAtomicSet(GStop, 1);
end;

procedure PcStopSignalInstall;
begin
  fpSignal(SIGINT, SignalHandler(@UnixStopHandler));
  fpSignal(SIGTERM, SignalHandler(@UnixStopHandler));
end;

procedure PcStopSignalUninstall;
begin
  // nil is SIG_DFL (0): the default action again.
  fpSignal(SIGINT, nil);
  fpSignal(SIGTERM, nil);
end;

procedure PcBlockStopSignals;
var
  LSet: TSigSet;
begin
  fpSigEmptySet(LSet);
  fpSigAddSet(LSet, SIGINT);
  fpSigAddSet(LSet, SIGTERM);
  fpSigProcMask(SIG_BLOCK, @LSet, nil);
end;
{$ENDIF}{$ENDIF}

end.
