unit CtrlCalm.Tests.Device;

{ Tests against the real XAudio2 output device. They play quietly (master at
  8%) and measure CPU, memory and glitches. Disabled with /nodevice. }

interface

/// <summary>Child-process mode used by the multi-process test.</summary>
function RunChild(const SettingsFile, SoundKey: string; Seconds: Integer): Integer;

implementation

uses
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.Classes, System.IOUtils,
  System.Diagnostics, System.Math,
  CtrlCalm.TestFramework, CtrlCalm.TestUtils, CtrlCalm.Core.Types, CtrlCalm.Core.Settings,
  CtrlCalm.Threading.Worker, CtrlCalm.Service, CtrlCalm.Audio.XAudio2, CtrlCalm.Tests.Audio;

function SoundsFolder: string;
var
  Dir: string;
  I: Integer;
begin
  Dir := ExtractFilePath(ParamStr(0));
  for I := 0 to 8 do
  begin
    if DirectoryExists(TPath.Combine(Dir, 'assets\sounds')) then
      Exit(TPath.Combine(Dir, 'assets\sounds'));
    Dir := ExtractFilePath(ExcludeTrailingPathDelimiter(Dir));
  end;
  Result := TPath.GetTempPath;
end;

function Skip: Boolean;
begin
  Result := not DeviceTestsEnabled or not CC_XAudio2Available;
  if Result then
    Report('Device', 'device tests skipped');
end;

function RunChild(const SettingsFile, SoundKey: string; Seconds: Integer): Integer;
var
  Svc: TCalmService;
  Id: TSoundId;
  Snap: TCalmSnapshot;
begin
  Result := 1;
  CoInitialize(nil);
  Svc := TCalmService.Create(SoundsFolder, SettingsFile, True);
  try
    Svc.SetMasterVolume(0.08);
    if TryParseSoundKey(SoundKey, Id) then
      Svc.SetSoundActive(Id, True);
    Svc.StartCountdown(Seconds + 30);
    PumpMessages(Seconds * 1000);
    Snap := Svc.Snapshot;
    Writeln(Format('child pid=%d sound=%s playing=%d status=%s timer=%d glitches=%d',
      [GetCurrentProcessId, SoundKey, Snap.PlayingCount, Snap.AudioStatusText, Ord(Snap.Timer.State),
       Snap.Glitches]));
    if (Snap.PlayingCount = 1) and (Snap.AudioStatus = asReady) and (Snap.Timer.State = trsRunning) then
      Result := 0;
  finally
    Svc.Free;
    CoUninitialize;
  end;
end;

procedure Register;
begin
  RegisterTest('Device', 'AllSoundsTogetherNoGlitchesLowCpu',
    procedure
    var
      Dir: string;
      Svc: TCalmService;
      S: TSoundId;
      Available, Playing: Integer;
      Snap: TCalmSnapshot;
      Cpu0, Cpu1: Double;
      Mem0, Mem1: UInt64;
      SW: TStopwatch;
      Peak, PeakMax: Single;
    begin
      if Skip then
        Exit;
      Dir := NewTempFolder('cc-dev');
      Svc := TCalmService.Create(SoundsFolder, TPath.Combine(Dir, 'settings.json'), True);
      try
        Svc.SetMasterVolume(0.08);
        PumpMessages(200);
        Available := 0;
        for S := Low(TSoundId) to High(TSoundId) do
          if Svc.Snapshot.TrackStates[S] <> tsUnavailable then
          begin
            Svc.SetSoundActive(S, True);
            Inc(Available);
          end;
        PumpMessages(2500); // fades complete
        Snap := Svc.Snapshot;
        Check(Snap.AudioStatus = asReady, 'device ready: ' + Snap.AudioStatusText);
        Playing := Snap.PlayingCount;
        CheckEquals(Available, Playing, 'every available sound plays');
        Cpu0 := Svc.WorkerCpuTimeMs;
        Mem0 := ProcessPrivateBytes;
        PeakMax := 0;
        SW := TStopwatch.StartNew;
        while SW.ElapsedMilliseconds < 10000 do
        begin
          PumpMessages(250);
          Peak := EndpointPeak;
          PeakMax := Max(PeakMax, Peak);
        end;
        Cpu1 := Svc.WorkerCpuTimeMs;
        Mem1 := ProcessPrivateBytes;
        Snap := Svc.Snapshot;
        Report('device.sounds', Format('%d of 16 available and playing simultaneously', [Playing]));
        Report('device.worker-cpu', Format('%.1f ms CPU over 10 s (%.3f%% of one core)',
          [Cpu1 - Cpu0, (Cpu1 - Cpu0) / 100]));
        Report('device.glitches', IntToStr(Snap.Glitches));
        Report('device.buffered', Format('%d KB in streaming buffers', [Snap.BufferedBytes div 1024]));
        Report('device.memory-delta-10s', Format('%d KB', [Int64(Mem1 - Mem0) div 1024]));
        Report('device.endpoint-peak', Format('%.4f', [PeakMax]));
        CheckEquals(0, Snap.Glitches, 'no audio glitches');
        Check(PeakMax > 0.0005, 'signal measured at the output device');
        Check((Cpu1 - Cpu0) < 500, 'worker uses under 5% of a core');
        Svc.StopAll;
        PumpMessages(1000);
        Cpu0 := Svc.WorkerCpuTimeMs;
        PumpMessages(5000);
        Cpu1 := Svc.WorkerCpuTimeMs;
        Report('device.idle-worker-cpu', Format('%.1f ms CPU over 5 s idle', [Cpu1 - Cpu0]));
        Check((Cpu1 - Cpu0) < 50, 'near-zero idle CPU');
      finally
        Svc.Free;
        TDirectory.Delete(Dir, True);
      end;
    end);

  RegisterTest('Device', 'RapidToggleAndSliderStress',
    procedure
    var
      Dir: string;
      Svc: TCalmService;
      I: Integer;
      S: TSoundId;
      Snap: TCalmSnapshot;
    begin
      if Skip then
        Exit;
      Dir := NewTempFolder('cc-stress');
      Svc := TCalmService.Create(SoundsFolder, TPath.Combine(Dir, 'settings.json'), True);
      try
        Svc.SetMasterVolume(0.05);
        for I := 1 to 400 do
        begin
          S := TSoundId(I mod 3 + Ord(sndWhiteNoise));
          Svc.ToggleSound(S);
          Svc.SetSoundVolume(S, (I mod 100) / 100);
          Svc.SetMasterVolume(0.02 + (I mod 7) / 100);
          if I mod 25 = 0 then
            PumpMessages(5);
        end;
        PumpMessages(2000);
        Snap := Svc.Snapshot;
        Check(Snap.AudioStatus in [asReady, asNotStarted], 'engine healthy: ' + Snap.AudioStatusText);
        CheckEquals(0, Snap.Glitches, 'no glitches under stress');
      finally
        Svc.Free;
        TDirectory.Delete(Dir, True);
      end;
    end);

  RegisterTest('Device', 'TwoProcessesPlayIndependently',
    procedure
    var
      Dir: string;
      SI: array[0..1] of TStartupInfo;
      PI: array[0..1] of TProcessInformation;
      Cmd: string;
      I: Integer;
      Code: DWORD;
      Keys: array[0..1] of string;
    begin
      if Skip then
        Exit;
      Dir := NewTempFolder('cc-procs');
      Keys[0] := 'white-noise';
      Keys[1] := 'brown-noise';
      for I := 0 to 1 do
      begin
        SI[I] := Default(TStartupInfo);
        SI[I].cb := SizeOf(TStartupInfo);
        Cmd := Format('"%s" /child "%s" %s 4', [ParamStr(0), TPath.Combine(Dir, 'p' + IntToStr(I) + '.json'), Keys[I]]);
        UniqueString(Cmd);
        Check(CreateProcess(nil, PChar(Cmd), nil, nil, True, 0, nil, nil, SI[I], PI[I]), 'spawn');
      end;
      for I := 0 to 1 do
      begin
        Check(WaitForSingleObject(PI[I].hProcess, 30000) = WAIT_OBJECT_0, 'child finished');
        GetExitCodeProcess(PI[I].hProcess, Code);
        CloseHandle(PI[I].hProcess);
        CloseHandle(PI[I].hThread);
        CheckEquals(0, Code, 'child ' + IntToStr(I) + ' played its own mix and timer');
      end;
      TDirectory.Delete(Dir, True);
    end);
end;

initialization
  Register;

end.
