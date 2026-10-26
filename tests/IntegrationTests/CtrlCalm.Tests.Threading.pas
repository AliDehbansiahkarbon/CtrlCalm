unit CtrlCalm.Tests.Threading;

{ Worker thread and service tests. The worker runs with its audio device
  disabled here, so these tests are deterministic on any machine; device
  tests live in CtrlCalm.Tests.Device. }

interface

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils, System.Diagnostics,
  CtrlCalm.TestFramework, CtrlCalm.TestUtils, CtrlCalm.Core.Types, CtrlCalm.Core.Settings,
  CtrlCalm.Timer, CtrlCalm.Threading.Worker, CtrlCalm.Service, CtrlCalm.Persistence;

function WaitProcessed(W: TCalmWorker; Seq: Int64; TimeoutMs: Integer = 5000): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := GetTickCount64 + UInt64(TimeoutMs);
  repeat
    if W.Snapshot.ProcessedSeq >= Seq then
      Exit(True);
    Sleep(2);
  until GetTickCount64 > Deadline;
  Result := False;
end;

function Cmd(Kind: TCalmCommandKind; Sound: TSoundId = sndRain; Value: Single = 0): TCalmCommand;
begin
  Result := MakeCommand(Kind);
  Result.Sound := Sound;
  Result.Value := Value;
end;

function WaitFor(const Cond: TFunc<Boolean>; TimeoutMs: Integer): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := GetTickCount64 + UInt64(TimeoutMs);
  repeat
    if Cond() then
      Exit(True);
    PumpMessages(5);
  until GetTickCount64 > Deadline;
  Result := Cond();
end;

procedure Register;
begin
  RegisterTest('Threading', 'RepeatedStartStop',
    procedure
    var
      I: Integer;
      W: TCalmWorker;
      SW: TStopwatch;
    begin
      SW := TStopwatch.StartNew;
      for I := 1 to 25 do
      begin
        W := TCalmWorker.Create(TPath.GetTempPath, False);
        if Odd(I) then
          W.Post(Cmd(ckActivateSound, sndPinkNoise, 0.5));
        W.Free;
      end;
      Report('worker.start-stop x25', Format('%d ms total', [SW.ElapsedMilliseconds]));
      Check(SW.ElapsedMilliseconds < 10000, 'start/stop must be fast');
    end);

  RegisterTest('Threading', 'CommandQueueKeepsOrder',
    procedure
    var
      W: TCalmWorker;
      Sent: TArray<TCalmCommandKind>;
      Log: TArray<TCalmCommandKind>;
      K: TCalmCommandKind;
      Seq: Int64;
      I: Integer;
    begin
      W := TCalmWorker.Create(TPath.GetTempPath, False);
      try
        W.LogCommands := True;
        Sent := [ckSetFades, ckActivateSound, ckSetMuted, ckPlayAll, ckStartTimer, ckPauseTimer,
          ckResumeTimer, ckDeactivateSound, ckPauseAll, ckCancelTimer, ckStopAll];
        Seq := 0;
        for K in Sent do
        begin
          if K = ckStartTimer then
          begin
            var C := Cmd(K);
            C.Seconds := 60;
            Seq := W.Post(C);
          end
          else
            Seq := W.Post(Cmd(K, sndBrownNoise, 0.5));
        end;
        Check(WaitProcessed(W, Seq), 'processed');
        Log := W.CommandLog;
        CheckEquals(Length(Sent), Length(Log), 'count');
        for I := 0 to High(Sent) do
          Check(Log[I] = Sent[I], 'order at ' + IntToStr(I));
      finally
        W.Free;
      end;
    end);

  RegisterTest('Threading', 'RapidVolumeCommandsCoalesce',
    procedure
    const
      N = 20000;
    var
      W: TCalmWorker;
      I: Integer;
      Seq: Int64;
      Snap: TCalmSnapshot;
    begin
      W := TCalmWorker.Create(TPath.GetTempPath, False);
      try
        W.Post(Cmd(ckActivateSound, sndWhiteNoise, 0.5));
        for I := 1 to N do
        begin
          Seq := W.Post(Cmd(ckSetSoundVolume, sndWhiteNoise, I / N));
          W.Post(Cmd(ckSetMasterVolume, sndRain, 1 - I / N));
        end;
        Seq := W.Post(Cmd(ckSetSoundVolume, sndWhiteNoise, 0.25));
        Check(WaitProcessed(W, Seq), 'processed');
        Snap := W.Snapshot;
        CheckNear(0.25, Snap.Volumes[sndWhiteNoise], 1E-6, 'last value wins');
        CheckNear(0, Snap.MasterVolume, 1E-6, 'last master value');
        Report('worker.coalescing', Format('%d volume commands posted, %d executed',
          [N * 2 + 2, Snap.CommandsProcessed]));
        Check(Snap.CommandsProcessed < N, 'commands were coalesced');
      finally
        W.Free;
      end;
    end);

  RegisterTest('Threading', 'ShutdownUnderLoad',
    procedure
    var
      W: TCalmWorker;
      I: Integer;
      SW: TStopwatch;
      S: TSoundId;
    begin
      W := TCalmWorker.Create(TPath.GetTempPath, False);
      for I := 1 to 3000 do
        for S := sndWhiteNoise to sndBrownNoise do
        begin
          W.Post(Cmd(ckActivateSound, S, 0.5));
          W.Post(Cmd(ckDeactivateSound, S));
        end;
      SW := TStopwatch.StartNew;
      W.Free; // must not hang or crash with thousands of commands pending
      Report('worker.shutdown-under-load', Format('%d ms', [SW.ElapsedMilliseconds]));
      Check(SW.ElapsedMilliseconds < 5000, 'bounded shutdown');
    end);

  RegisterTest('Threading', 'PostAfterShutdownIsRejected',
    procedure
    var
      W: TCalmWorker;
    begin
      W := TCalmWorker.Create(TPath.GetTempPath, False);
      try
        W.Shutdown;
        CheckEquals(-1, W.Post(Cmd(ckPlayAll)), 'no commands after shutdown');
        Check(W.Snapshot.AudioStatus = asShutDown, 'engine shut down');
      finally
        W.Free;
      end;
    end);

  RegisterTest('Threading', 'PartialInitializationCleansUp',
    procedure
    var
      W: TCalmWorker;
    begin
      // Nonexistent sounds folder and an immediate shutdown before any command.
      W := TCalmWorker.Create('Z:\does\not\exist', False);
      W.Free;
      W := TCalmWorker.Create('Z:\does\not\exist', False);
      W.Post(Cmd(ckActivateSound, sndRain, 0.5)); // unavailable sound
      W.Free;
    end);

  RegisterTest('Threading', 'TimerRunsInWorkerAndStopsSounds',
    procedure
    var
      W: TCalmWorker;
      C: TCalmCommand;
      Seq: Int64;
      Deadline: UInt64;
      Snap: TCalmSnapshot;
    begin
      W := TCalmWorker.Create(TPath.GetTempPath, False);
      try
        W.Post(Cmd(ckActivateSound, sndBrownNoise, 0.5));
        W.Post(Cmd(ckPlayAll));
        C := Cmd(ckStartTimer);
        C.Seconds := 1;
        C.TimerOptions.Completion := tcaStopSounds;
        Seq := W.Post(C);
        Check(WaitProcessed(W, Seq));
        Check(W.Snapshot.Timer.State = trsRunning, 'running');
        Check(not W.Snapshot.Paused, 'playing');
        Deadline := GetTickCount64 + 3000;
        repeat
          Sleep(20);
          Snap := W.Snapshot;
        until (Snap.Timer.State = trsCompleted) or (GetTickCount64 > Deadline);
        Check(Snap.Timer.State = trsCompleted, 'completed without any UI');
        CheckEquals(1, Snap.TimerEventSeq, 'one completion event');
        Check(Snap.Paused, 'sounds stopped at completion');
        Check(Snap.Active[sndBrownNoise], 'mix kept for the next session');
      finally
        W.Free;
      end;
    end);

  RegisterTest('Service', 'ClickPlaysAndStateReconciles',
    procedure
    var
      Dir: string;
      Svc: TCalmService;
    begin
      Dir := NewTempFolder('cc-svc');
      Svc := TCalmService.Create(Dir, TPath.Combine(Dir, 'settings.json'), False);
      try
        Check(Svc.Paused, 'starts silent');
        Svc.ToggleSound(sndPinkNoise);
        Check(Svc.IsActive(sndPinkNoise) and not Svc.Paused, 'optimistic state');
        Check(WaitFor(function: Boolean
          begin
            Result := Svc.Snapshot.ProcessedSeq > 0;
          end, 3000));
        PumpMessages(300);
        Check(Svc.IsActive(sndPinkNoise), 'still active after reconcile');
        Check(not Svc.Paused, 'still playing after reconcile');
        Check(not Svc.Snapshot.Paused, 'worker agrees');
        Svc.TogglePlayPause;
        PumpMessages(300);
        Check(Svc.Paused and Svc.Snapshot.Paused, 'paused');
        Svc.ToggleSound(sndPinkNoise); // armed sound: click resumes
        PumpMessages(300);
        Check(not Svc.Paused and Svc.IsActive(sndPinkNoise), 'resumed');
        Svc.StopAll;
        PumpMessages(300);
        Check(not Svc.HasActiveSounds, 'stopped');
      finally
        Svc.Free;
        TDirectory.Delete(Dir, True);
      end;
    end);

  RegisterTest('Service', 'FavoritesPersistAcrossInstances',
    procedure
    var
      Dir, Id, Dup: string;
      Svc: TCalmService;
      F: TFavorite;
    begin
      Dir := NewTempFolder('cc-fav');
      Svc := TCalmService.Create(Dir, TPath.Combine(Dir, 'settings.json'), False);
      try
        Svc.SetSoundActive(sndBrownNoise, True);
        Svc.SetSoundVolume(sndBrownNoise, 0.33);
        Id := Svc.SaveCurrentAsFavorite('Evening');
        Svc.RenameFavorite(Id, 'Late evening');
        Svc.SetSoundActive(sndWhiteNoise, True);
        Svc.UpdateFavoriteFromCurrent(Id);
        Dup := Svc.DuplicateFavorite(Id);
        Check(Dup <> '', 'duplicated');
        Svc.DeleteFavorite(Dup);
      finally
        Svc.Free;
      end;
      Svc := TCalmService.Create(Dir, TPath.Combine(Dir, 'settings.json'), False);
      try
        CheckEquals(1, Length(Svc.Settings.Favorites), 'one favorite');
        Check(FindPreset(Svc.Settings, Id, F));
        CheckEquals('Late evening', F.Name);
        Check(F.Mix.Active[sndBrownNoise] and F.Mix.Active[sndWhiteNoise], 'updated mix');
        CheckNear(0.33, F.Mix.Volumes[sndBrownNoise], 1E-3);
        // Startup restores the mix silently.
        Check(Svc.Paused, 'no automatic playback');
        Check(Svc.IsActive(sndBrownNoise), 'last mix restored');
        Svc.ApplyPreset(F);
        Check(not Svc.Paused, 'applying a favorite plays it');
        CheckEquals(F.Id, Svc.MatchingPresetId, 'favorite highlighted');
      finally
        Svc.Free;
        TDirectory.Delete(Dir, True);
      end;
    end);

  RegisterTest('Service', 'TwoInstancesAreIndependent',
    procedure
    var
      Dir: string;
      A, B: TCalmService;
    begin
      Dir := NewTempFolder('cc-two');
      A := TCalmService.Create(Dir, TPath.Combine(Dir, 'a.json'), False);
      B := TCalmService.Create(Dir, TPath.Combine(Dir, 'b.json'), False);
      try
        A.SetSoundActive(sndWhiteNoise, True);
        B.SetSoundActive(sndBrownNoise, True);
        A.StartCountdown(600);
        PumpMessages(400);
        Check(A.Snapshot.Active[sndWhiteNoise] and not A.Snapshot.Active[sndBrownNoise], 'A mix');
        Check(B.Snapshot.Active[sndBrownNoise] and not B.Snapshot.Active[sndWhiteNoise], 'B mix');
        Check(A.Snapshot.Timer.State = trsRunning, 'A timer');
        Check(B.Snapshot.Timer.State = trsIdle, 'B timer untouched');
        FreeAndNil(A); // one "IDE" exits
        B.SetSoundVolume(sndBrownNoise, 0.7);
        PumpMessages(300);
        CheckNear(0.7, B.Snapshot.Volumes[sndBrownNoise], 1E-4, 'B keeps working');
      finally
        A.Free;
        B.Free;
        TDirectory.Delete(Dir, True);
      end;
    end);
end;

initialization
  Register;

end.
