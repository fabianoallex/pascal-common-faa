program PascalCommonUnitTestsFpc;

{ FPCUnit runner for the unit tests. Same coverage as the DUnitX suite
  (tests/Unit/PascalCommon.UnitTests.dpr): the fixtures in tests/Unit/fpc are
  generated from the DUnitX masters by tools/gen_fpc_mirror.py.

  Console (text output), when called with any parameter:
    .\PascalCommonUnitTestsFpc.exe --all --format=plain
  GUI (test tree + green/red bar), with no parameters:
    .\PascalCommonUnitTestsFpc.exe
  Outside Windows it always runs in console mode (no LCL/widgetset). }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  // Without cwstring, FPC on Unix converts a WideString Variant back to
  // string one byte per character (Latin-1), ignoring the UTF-8 code page
  // (pascal-db-faa, "Runtime requirements for FPC applications").
  cwstring,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Interfaces, Forms, GuiTestRunner,
  {$ENDIF}
  Classes, consoletestrunner, testregistry,
  PascalCommon.VersionTests;

var
  ConsoleApp: TTestRunner;
begin
  // Plain FPC console: DefaultSystemCodePage isn't UTF-8 by default, and the
  // tests' non-ASCII literals would be transcoded wrongly.
  SetMultiByteConversionCodePage(CP_UTF8);

  {$IFDEF MSWINDOWS}
  if ParamCount = 0 then
  begin
    Application.Initialize;
    Application.CreateForm(TGUITestRunner, TestRunner);
    Application.Run;
  end
  else
  {$ENDIF}
  begin
    DefaultFormat := fPlain;
    DefaultRunAllTests := True;
    ConsoleApp := TTestRunner.Create(nil);
    try
      ConsoleApp.Initialize;
      ConsoleApp.Title := 'pascal-common-faa - unit tests (FPCUnit)';
      ConsoleApp.Run;
    finally
      ConsoleApp.Free;
    end;
  end;
end.
