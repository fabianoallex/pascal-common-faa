program PascalCommonStopSignalProbe;

{ A program that stops on SIGTERM the way a server should, for
  tools/test_stop_signal_docker.sh: FPC on Linux only.

  It is shaped like pascal-agenda-faa's api ("M5: under load" there): the
  handlers installed, a watcher thread started that waits for
  PcStopRequested, then PcBlockStopSignals on the main thread, which then
  sits in a blocking call (select on a pipe, standing in for the server's
  accept). On a stop the watcher writes to the pipe, as the api's watcher
  wakes the accept with a fake connection. With the block, the kernel hands
  SIGTERM to the watcher and the main thread's select is never interrupted;
  without it (--no-block) the signal usually lands on the main thread and
  its select fails with EINTR, the error FPC's web application took for a
  reason to listen again. The script asserts the first case and only
  reports the second (which thread gets an unblocked signal is the
  kernel's choice).

  Output, one fact per line, for the script to grep:
    ready <pid>
    watcher saw the stop: yes|no
    main interrupted: yes|no
  Exit code 0 when the watcher saw the stop and, in the default mode, the
  main thread wasn't interrupted. Built with heaptrc by the script: 0
  unfreed blocks expected. }

{$mode delphi}{$H+}

uses
  cthreads,
  Classes,
  SysUtils,
  BaseUnix,
  PascalCommon.Threading,
  PascalCommon.StopSignal;

type
  TWatcher = class(TThread)
  protected
    procedure Execute; override;
  public
    WakeFd: cint;
  end;

var
  GSawStop: Integer = 0;

procedure TWatcher.Execute;
var
  LByte: Byte;
begin
  while not Terminated and not PcStopRequested do
    PcStopSleep(200);
  if PcStopRequested then
    PcAtomicSet(GSawStop, 1);
  LByte := 1;
  fpWrite(WakeFd, LByte, 1);
end;

function Answer(AValue: Boolean): string;
begin
  if AValue then
    Result := 'yes'
  else
    Result := 'no';
end;

var
  LPipe: TFilDes;
  LWatcher: TWatcher;
  LSet: TFDSet;
  LBlock, LInterrupted: Boolean;
  LReady: cint;
begin
  LBlock := ParamStr(1) <> '--no-block';
  if fpPipe(LPipe) <> 0 then
    Halt(2);
  PcStopSignalInstall;
  LWatcher := TWatcher.Create(True);
  LWatcher.WakeFd := LPipe[1];
  LWatcher.Start;
  // After the watcher exists: a thread inherits its creator's mask.
  if LBlock then
    PcBlockStopSignals;
  Writeln('ready ', fpGetPid);
  Flush(Output);

  LInterrupted := False;
  repeat
    fpFD_ZERO(LSet);
    fpFD_SET(LPipe[0], LSet);
    LReady := fpSelect(LPipe[0] + 1, @LSet, nil, nil, nil);
    if (LReady < 0) and (fpGetErrno = ESysEINTR) then
      LInterrupted := True;
  until LReady > 0;

  LWatcher.WaitFor;
  LWatcher.Free;
  PcStopSignalDone;
  PcStopSignalUninstall;
  fpClose(LPipe[0]);
  fpClose(LPipe[1]);

  Writeln('watcher saw the stop: ', Answer(PcAtomicGet(GSawStop) <> 0));
  Writeln('main interrupted: ', Answer(LInterrupted));
  if (PcAtomicGet(GSawStop) = 0) or (LBlock and LInterrupted) then
    ExitCode := 1;
end.
