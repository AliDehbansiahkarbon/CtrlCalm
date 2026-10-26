program CtrlCalmTests;

{
  Ctrl+Calm automated tests (no external framework required).

  Usage: CtrlCalmTests [filter] [/nodevice]
    filter     run only tests whose "Suite.Name" contains this text
    /nodevice  skip tests that open the real audio output device
  Exit code: number of failed tests.
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows, Winapi.ActiveX, System.SysUtils,
  CtrlCalm.TestFramework in 'Common\CtrlCalm.TestFramework.pas',
  CtrlCalm.TestUtils in 'Common\CtrlCalm.TestUtils.pas',
  CtrlCalm.Tests.Core in 'CoreTests\CtrlCalm.Tests.Core.pas',
  CtrlCalm.Tests.Audio in 'AudioTests\CtrlCalm.Tests.Audio.pas',
  CtrlCalm.Tests.Assets in 'AudioTests\CtrlCalm.Tests.Assets.pas',
  CtrlCalm.Tests.Timer in 'TimerTests\CtrlCalm.Tests.Timer.pas',
  CtrlCalm.Tests.Persistence in 'PersistenceTests\CtrlCalm.Tests.Persistence.pas',
  CtrlCalm.Tests.Threading in 'IntegrationTests\CtrlCalm.Tests.Threading.pas',
  CtrlCalm.Tests.Device in 'IntegrationTests\CtrlCalm.Tests.Device.pas';

var
  Filter: string;
  I: Integer;
begin
  if SameText(ParamStr(1), '/child') then
  begin
    ExitCode := RunChild(ParamStr(2), ParamStr(3), StrToIntDef(ParamStr(4), 3));
    Exit;
  end;
  CoInitialize(nil);
  try
    Filter := '';
    for I := 1 to ParamCount do
      if SameText(ParamStr(I), '/nodevice') then
        DeviceTestsEnabled := False
      else
        Filter := ParamStr(I);
    Writeln(Format('Ctrl+Calm tests - %d-bit, %s', [SizeOf(Pointer) * 8,
      FormatDateTime('yyyy-mm-dd hh:nn', Now)]));
    Writeln;
    ExitCode := RunAllTests(Filter);
  finally
    CoUninitialize;
  end;
end.
