unit CtrlCalm.Tests.Persistence;

interface

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils, System.JSON,
  System.Threading, System.SyncObjs, Vcl.Menus,
  CtrlCalm.TestFramework, CtrlCalm.TestUtils, CtrlCalm.Core.Types, CtrlCalm.Core.Settings,
  CtrlCalm.Persistence;

function SampleFavorite(const Name: string): TFavorite;
begin
  Result := Default(TFavorite);
  Result.Id := NewFavoriteId;
  Result.Name := Name;
  Result.Mix := TMix.Empty;
  Result.Mix.Active[sndRain] := True;
  Result.Mix.Volumes[sndRain] := 0.42;
  Result.Mix.Active[sndBrownNoise] := True;
  Result.Mix.Volumes[sndBrownNoise] := 0.3;
  Result.MasterPolicy := mpUseSaved;
  Result.MasterVolume := 0.55;
  Result.Accent := apOcean;
  Result.CreatedUtc := EncodeDate(2026, 10, 9) + EncodeTime(12, 0, 0, 0);
  Result.ModifiedUtc := Result.CreatedUtc;
end;

procedure Register;
begin
  RegisterTest('Persistence', 'RoundTripAllSections',
    procedure
    var
      A, B: TCalmSettings;
      Json: string;
    begin
      A := TCalmSettings.Default;
      A.Audio.MasterVolume := 0.62;
      A.Audio.Muted := True;
      A.Audio.SoundVolumes[sndFan] := 0.11;
      A.Audio.LastActive[sndStream] := True;
      A.Audio.FadeInMs := 2000;
      A.Audio.Startup := sbAutoResume;
      A.Audio.FocusLoss := flMute;
      A.Timer.CountdownSec := 45 * 60;
      A.Timer.Completion := tcaFadeOut;
      A.Timer.FadeOutSec := 30;
      A.Timer.Pomodoro.FocusSec := 50 * 60;
      A.Timer.Pomodoro.AutoStartNext := True;
      A.Timer.FocusPresetId := 'builtin:deep-focus';
      A.Timer.Mode := tmPomodoro;
      A.Appearance.Accent := apViolet;
      A.Appearance.Layout := lpExpanded;
      A.General.OpenPanelAtStartup := True;
      A.Shortcuts[saPlayPause] := ShortCut(Ord('P'), [ssCtrl, ssAlt, ssShift]);
      A.Favorites := [SampleFavorite('Night shift'), SampleFavorite('Unicode '#$00DC#$00EF' '#$2615' mix')];
      Json := SettingsToJson(A);
      B := SettingsFromJson(Json);
      CheckNear(0.62, B.Audio.MasterVolume, 1E-4);
      Check(B.Audio.Muted);
      CheckNear(0.11, B.Audio.SoundVolumes[sndFan], 1E-4);
      Check(B.Audio.LastActive[sndStream] and not B.Audio.LastActive[sndRain]);
      CheckEquals(2000, B.Audio.FadeInMs);
      Check(B.Audio.Startup = sbAutoResume);
      Check(B.Audio.FocusLoss = flMute);
      CheckEquals(45 * 60, B.Timer.CountdownSec);
      Check(B.Timer.Completion = tcaFadeOut);
      CheckEquals(30, B.Timer.FadeOutSec);
      CheckEquals(50 * 60, B.Timer.Pomodoro.FocusSec);
      Check(B.Timer.Pomodoro.AutoStartNext);
      CheckEquals('builtin:deep-focus', B.Timer.FocusPresetId);
      Check(B.Timer.Mode = tmPomodoro);
      Check(B.Appearance.Accent = apViolet);
      Check(B.Appearance.Layout = lpExpanded);
      Check(B.General.OpenPanelAtStartup);
      CheckEquals(A.Shortcuts[saPlayPause], B.Shortcuts[saPlayPause], 'shortcut');
      CheckEquals(2, Length(B.Favorites));
      CheckEquals('Unicode '#$00DC#$00EF' '#$2615' mix', B.Favorites[1].Name);
      CheckEquals(A.Favorites[0].Id, B.Favorites[0].Id);
      Check(B.Favorites[0].Mix.SameAs(A.Favorites[0].Mix), 'mix');
      Check(B.Favorites[0].MasterPolicy = mpUseSaved);
      CheckNear(0.55, B.Favorites[0].MasterVolume, 1E-4);
      Check(B.Favorites[0].Accent = apOcean);
      CheckNear(A.Favorites[0].CreatedUtc, B.Favorites[0].CreatedUtc, 1 / 86400, 'created');
    end);

  RegisterTest('Persistence', 'BackwardCompatibleAndTolerant',
    procedure
    var
      S: TCalmSettings;
    begin
      // An older/minimal file: missing sections keep defaults, unknown keys
      // and wrong types are ignored, out-of-range values are clamped.
      S := SettingsFromJson('{"version":0,"audio":{"masterVolume":5,"fadeInMs":"fast",' +
        '"soundVolumes":{"rain":0.7,"unknown-sound":1}},"futureFeature":{"x":1},' +
        '"timer":{"countdownSec":0,"completion":"explode"},"favorites":[{"name":"Old",' +
        '"sounds":[{"sound":"rain","volume":0.4},{"sound":"nope","volume":1}]},42]}');
      CheckNear(1, S.Audio.MasterVolume, 0, 'clamped');
      CheckEquals(1500, S.Audio.FadeInMs, 'wrong type ignored');
      CheckNear(0.7, S.Audio.SoundVolumes[sndRain], 1E-4);
      CheckEquals(25 * 60, S.Timer.CountdownSec, 'invalid duration replaced');
      Check(S.Timer.Completion = tcaStopSounds, 'unknown enum -> default');
      CheckEquals(1, Length(S.Favorites));
      Check(S.Favorites[0].Id <> '', 'id generated');
      CheckEquals(1, S.Favorites[0].Mix.ActiveCount, 'unknown sound skipped');
      CheckEquals(SettingsVersion, S.Version);
    end);

  RegisterTest('Persistence', 'InvalidJsonRaisesInParser',
    procedure
    begin
      CheckRaises(procedure begin SettingsFromJson('{"audio": '); end, Exception, 'truncated');
      CheckRaises(procedure begin SettingsFromJson('[1,2,3]'); end, Exception, 'not an object');
      CheckRaises(procedure begin SettingsFromJson(''); end, Exception, 'empty');
    end);

  RegisterTest('Persistence', 'CorruptFileRecoveredAndPreserved',
    procedure
    var
      Dir, FileName: string;
      Store: TSettingsStore;
      S: TCalmSettings;
      Backups: TArray<string>;
    begin
      Dir := NewTempFolder('cc-corrupt');
      FileName := TPath.Combine(Dir, 'settings.json');
      TFile.WriteAllText(FileName, '{ this is not json', TEncoding.UTF8);
      Store := TSettingsStore.Create(FileName);
      try
        Check(Store.Load(S) = lrRecoveredCorrupt, 'recovered');
        CheckNear(DefaultMasterVolume, S.Audio.MasterVolume, 1E-6, 'defaults');
        Backups := TDirectory.GetFiles(Dir, 'settings.corrupt-*.json');
        CheckEquals(1, Length(Backups), 'damaged file kept for diagnosis');
        Check(Store.LastError <> '', 'diagnostic message');
        Check(Store.Update(procedure(var X: TCalmSettings) begin X.Audio.MasterVolume := 0.4; end, S));
        Check(Store.Load(S) = lrLoaded);
        CheckNear(0.4, S.Audio.MasterVolume, 1E-4);
      finally
        Store.Free;
        TDirectory.Delete(Dir, True);
      end;
    end);

  RegisterTest('Persistence', 'FavoritesCrudThroughStore',
    procedure
    var
      Dir: string;
      Store: TSettingsStore;
      S: TCalmSettings;
      F: TFavorite;
      I: Integer;
    begin
      Dir := NewTempFolder('cc-crud');
      Store := TSettingsStore.Create(TPath.Combine(Dir, 'settings.json'));
      try
        F := SampleFavorite('A');
        for I := 1 to 6 do
          Store.Update(procedure(var X: TCalmSettings)
            var
              N: TFavorite;
            begin
              N := SampleFavorite('Mix ' + IntToStr(Length(X.Favorites) + 1));
              X.Favorites := X.Favorites + [N];
            end, S);
        CheckEquals(6, Length(S.Favorites), 'create (more than five)');
        F := S.Favorites[2];
        Store.Update(procedure(var X: TCalmSettings)
          begin
            X.Favorites[X.FavoriteIndex(F.Id)].Name := 'Renamed';
          end, S);
        Store.Load(S);
        CheckEquals('Renamed', S.Favorites[2].Name, 'rename persisted');
        Store.Update(procedure(var X: TCalmSettings)
          begin
            Delete(X.Favorites, X.FavoriteIndex(F.Id), 1);
          end, S);
        Store.Load(S);
        CheckEquals(5, Length(S.Favorites), 'delete persisted');
        CheckEquals(-1, S.FavoriteIndex(F.Id));
        CheckEquals(0, Length(TDirectory.GetFiles(Dir, '*.tmp-*')), 'no temp files left');
      finally
        Store.Free;
        TDirectory.Delete(Dir, True);
      end;
    end);

  RegisterTest('Persistence', 'ConcurrentWritersLoseNothing',
    procedure
    const
      Writers = 4;
      PerWriter = 25;
    var
      Dir, FileName: string;
      Threads: array[0..Writers - 1] of TThread;
      I: Integer;
      Store: TSettingsStore;
      S: TCalmSettings;
      Errors: Integer;
    begin
      // Separate store instances model separate IDE processes sharing a file.
      Dir := NewTempFolder('cc-concurrent');
      FileName := TPath.Combine(Dir, 'settings.json');
      Errors := 0;
      for I := 0 to Writers - 1 do
        Threads[I] := TThread.CreateAnonymousThread(
          procedure
          var
            St: TSettingsStore;
            K: Integer;
            Merged: TCalmSettings;
          begin
            St := TSettingsStore.Create(FileName);
            try
              for K := 1 to PerWriter do
                if not St.Update(
                  procedure(var X: TCalmSettings)
                  begin
                    X.Favorites := X.Favorites + [SampleFavorite('w')];
                  end, Merged) then
                  AtomicIncrement(Errors);
            finally
              St.Free;
            end;
          end);
      for I := 0 to Writers - 1 do
      begin
        Threads[I].FreeOnTerminate := False;
        Threads[I].Start;
      end;
      for I := 0 to Writers - 1 do
      begin
        Threads[I].WaitFor;
        Threads[I].Free;
      end;
      Store := TSettingsStore.Create(FileName);
      try
        Check(Store.Load(S) = lrLoaded, 'file valid after concurrent writes');
        CheckEquals(0, Errors, 'write errors');
        CheckEquals(Writers * PerWriter, Length(S.Favorites), 'no lost writes');
      finally
        Store.Free;
        TDirectory.Delete(Dir, True);
      end;
    end);

  RegisterTest('Persistence', 'ReadOnlyFileReportsErrorKeepsChange',
    procedure
    var
      Dir, FileName: string;
      Store: TSettingsStore;
      S: TCalmSettings;
    begin
      Dir := NewTempFolder('cc-readonly');
      FileName := TPath.Combine(Dir, 'settings.json');
      Store := TSettingsStore.Create(FileName);
      try
        Check(Store.Update(procedure(var X: TCalmSettings) begin X.Audio.MasterVolume := 0.2; end, S));
        SetFileAttributes(PChar(FileName), FILE_ATTRIBUTE_READONLY);
        Check(not Store.Update(procedure(var X: TCalmSettings) begin X.Audio.MasterVolume := 0.9; end, S),
          'write must fail on a read-only file');
        Check(Store.LastError <> '', 'error explained');
        CheckNear(0.9, S.Audio.MasterVolume, 1E-4, 'merged result still returned');
        Store.Load(S);
        CheckNear(0.2, S.Audio.MasterVolume, 1E-4, 'file unchanged');
      finally
        SetFileAttributes(PChar(FileName), FILE_ATTRIBUTE_NORMAL);
        Store.Free;
        TDirectory.Delete(Dir, True);
      end;
    end);

  RegisterTest('Persistence', 'MissingFileGivesDefaults',
    procedure
    var
      Store: TSettingsStore;
      S: TCalmSettings;
    begin
      Store := TSettingsStore.Create(TPath.Combine(TPath.GetTempPath, 'cc-does-not-exist\settings.json'));
      try
        Check(Store.Load(S) = lrDefaultsNoFile);
        Check(S.Audio.Startup = sbRestoreSilently);
      finally
        Store.Free;
      end;
    end);
end;

initialization
  Register;

end.
