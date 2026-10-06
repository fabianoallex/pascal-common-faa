program PascalCommon.UnitTests;

{ DUnitX runner for the unit tests.

  The sibling FPCUnit suite lives in tests/Unit/fpc — same coverage and
  identical test bodies: the files there are GENERATED from these by
  tools/gen_fpc_mirror.py (PascalCommon.DUnitXCompat exists for that). Always
  edit the DUnitX masters here and regenerate the mirror. }

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  PascalCommon.Version in '..\..\src\PascalCommon.Version.pas',
  PascalCommon.DUnitXCompat in 'PascalCommon.DUnitXCompat.pas',
  PascalCommon.Threading in '..\..\src\PascalCommon.Threading.pas',
  PascalCommon.SystemContext in '..\..\src\PascalCommon.SystemContext.pas',
  PascalCommon.ClockCache in '..\..\src\PascalCommon.ClockCache.pas',
  PascalCommon.Optionals in '..\..\src\PascalCommon.Optionals.pas',
  PascalCommon.ThreadPool in '..\..\src\PascalCommon.ThreadPool.pas',
  PascalCommon.SafeLog in '..\..\src\PascalCommon.SafeLog.pas',
  PascalJsonMapper.Json in '..\..\external\pascal-jsonmapper-faa\src\PascalJsonMapper.Json.pas',
  PascalJsonMapper.Mapper in '..\..\external\pascal-jsonmapper-faa\src\PascalJsonMapper.Mapper.pas',
  PascalCommon.JsonMapper.Optionals in '..\..\bridges\jsonmapper\PascalCommon.JsonMapper.Optionals.pas',
  PascalCommon.VersionTests in 'PascalCommon.VersionTests.pas',
  PascalCommon.ThreadingTests in 'PascalCommon.ThreadingTests.pas',
  PascalCommon.SystemContextTests in 'PascalCommon.SystemContextTests.pas',
  PascalCommon.ClockCacheTests in 'PascalCommon.ClockCacheTests.pas',
  PascalCommon.OptionalsTests in 'PascalCommon.OptionalsTests.pas',
  PascalCommon.ThreadPoolTests in 'PascalCommon.ThreadPoolTests.pas',
  PascalCommon.SafeLogTests in 'PascalCommon.SafeLogTests.pas',
  PascalCommon.JsonMapperOptionalsTests in 'PascalCommon.JsonMapperOptionalsTests.pas';

var
  runner: ITestRunner;
  results: IRunResults;
  logger: ITestLogger;
  nunitLogger: ITestLogger;
begin
  // Acceptance criterion on both sides: 0 leaks (FastMM here, heaptrc on FPC).
  ReportMemoryLeaksOnShutdown := True;
  try
    TDUnitX.CheckCommandLine;

    if TDUnitX.Options.Include = '' then
      TDUnitX.Options.Include := '.';

    runner := TDUnitX.CreateRunner;
    runner.UseRTTI := True;
    runner.FailsOnNoAsserts := False;

    if TDUnitX.Options.ConsoleMode <> TDunitXConsoleMode.Off then
    begin
      logger := TDUnitXConsoleLogger.Create(
        TDUnitX.Options.ConsoleMode = TDunitXConsoleMode.Quiet);
      runner.AddLogger(logger);
    end;

    nunitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
    runner.AddLogger(nunitLogger);

    results := runner.Execute;

    if not results.AllPassed then
      System.ExitCode := EXIT_ERRORS;

    if (TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause) and IsConsole then
    begin
      System.Write('Done.. press <Enter> key to quit.');
      System.Readln;
    end;
  except
    on E: Exception do
      System.Writeln(E.ClassName, ': ', E.Message);
  end;
end.
