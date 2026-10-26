unit CtrlCalm.Tests.Core;

interface

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  CtrlCalm.TestFramework, CtrlCalm.Core.Types, CtrlCalm.Core.Settings;

procedure Register;
begin
  RegisterTest('Core', 'CatalogHas16UniqueStableSounds',
    procedure
    var
      S: TSoundId;
      Keys, Files: TDictionary<string, Boolean>;
      D: TSoundDefinition;
    begin
      Keys := TDictionary<string, Boolean>.Create;
      Files := TDictionary<string, Boolean>.Create;
      try
        CheckEquals(16, Ord(High(TSoundId)) + 1, 'sound count');
        for S := Low(TSoundId) to High(TSoundId) do
        begin
          D := SoundDef(S);
          CheckEquals(Ord(S) + 1, D.Number, 'catalog number');
          Check(D.Key <> '', 'key');
          Check(D.Name <> '', 'name');
          Check(not Keys.ContainsKey(D.Key), 'duplicate key ' + D.Key);
          Keys.Add(D.Key, True);
          if D.Kind = skRecorded then
          begin
            Check(D.FileName <> '', 'file for ' + D.Key);
            Check(not Files.ContainsKey(D.FileName), 'duplicate file');
            Files.Add(D.FileName, True);
          end;
        end;
        Check(SoundDef(sndWhiteNoise).Kind = skProcedural);
        Check(SoundDef(sndPinkNoise).Kind = skProcedural);
        Check(SoundDef(sndBrownNoise).Kind = skProcedural);
      finally
        Files.Free;
        Keys.Free;
      end;
    end);

  RegisterTest('Core', 'SoundKeysRoundTrip',
    procedure
    var
      S, P: TSoundId;
    begin
      for S := Low(TSoundId) to High(TSoundId) do
      begin
        Check(TryParseSoundKey(SoundKey(S), P), SoundKey(S));
        Check(P = S);
        Check(TryParseSoundKey(UpperCase(SoundKey(S)), P), 'case-insensitive');
      end;
      Check(not TryParseSoundKey('ocean', P), 'unknown key');
      Check(not TryParseSoundKey('', P), 'empty key');
    end);

  RegisterTest('Core', 'VolumeClampAndTaper',
    procedure
    var
      I: Integer;
      Prev, G: Single;
    begin
      CheckNear(0, ClampVolume(NaN), 0, 'NaN');
      CheckNear(0, ClampVolume(-5), 0);
      CheckNear(1, ClampVolume(7), 0);
      CheckNear(0, SliderToGain(0), 0);
      CheckNear(1, SliderToGain(1), 1E-6);
      Prev := -1;
      for I := 0 to 100 do
      begin
        G := SliderToGain(I / 100);
        Check(G > Prev, 'taper must be strictly increasing');
        Check(G <= I / 100 + 1E-6, 'taper never exceeds linear');
        Prev := G;
      end;
      // About -9.6 dB at the half-way point.
      CheckNear(-9.63, 20 * Log10(SliderToGain(0.5)), 0.1, 'half-way level');
    end);

  RegisterTest('Core', 'MixSameAsIgnoresInactiveVolumes',
    procedure
    var
      A, B: TMix;
    begin
      A := TMix.Empty;
      B := TMix.Empty;
      A.Active[sndRain] := True;
      B.Active[sndRain] := True;
      A.Volumes[sndRain] := 0.4;
      B.Volumes[sndRain] := 0.402;
      A.Volumes[sndWind] := 0.1;
      B.Volumes[sndWind] := 0.9;
      Check(A.SameAs(B), 'inactive volume differences are irrelevant');
      B.Volumes[sndRain] := 0.5;
      Check(not A.SameAs(B), 'active volume differs');
      CheckEquals(1, A.ActiveCount);
    end);

  RegisterTest('Core', 'BuiltInPresetsAreConservative',
    procedure
    var
      P: TFavorite;
      S: TSoundId;
      Names: string;
      Sum: Double;
    begin
      Names := '';
      for P in BuiltInPresets do
      begin
        Names := Names + P.Name + ';';
        Check(P.BuiltIn, 'flag');
        Check(P.Id.StartsWith('builtin:'), 'id prefix');
        Check(P.Mix.ActiveCount >= 2, 'combination');
        Sum := 0;
        for S := Low(TSoundId) to High(TSoundId) do
          if P.Mix.Active[S] then
          begin
            Check(P.Mix.Volumes[S] <= 0.5, P.Name + ' level too high');
            Sum := Sum + Sqr(SliderToGain(P.Mix.Volumes[S]));
          end;
        Check(Sqrt(Sum) < 1.5, P.Name + ' would trigger the headroom limiter');
      end;
      Check(Pos('Deep Focus;', Names) > 0, 'Deep Focus');
      Check(Pos('Coffee & Code;', Names) > 0, 'Coffee & Code');
      Check(Pos('Calm Coding;', Names) > 0, 'Calm Coding');
      Check(BuiltInPresets[0].Mix.Active[sndBrownNoise] and BuiltInPresets[0].Mix.Active[sndRain]);
      Check(BuiltInPresets[1].Mix.Active[sndCoffeeShop] and BuiltInPresets[1].Mix.Active[sndRain]);
      Check(BuiltInPresets[2].Mix.Active[sndForest] and BuiltInPresets[2].Mix.Active[sndStream] and
        BuiltInPresets[2].Mix.Active[sndWind]);
    end);

  RegisterTest('Core', 'SettingsDefaultsAreSafe',
    procedure
    var
      S: TCalmSettings;
      A: TShortcutAction;
    begin
      S := TCalmSettings.Default;
      CheckNear(0.3, S.Audio.MasterVolume, 1E-6, 'conservative master');
      Check(S.Audio.Startup = sbRestoreSilently, 'never auto-plays by default');
      Check(S.Timer.Completion = tcaStopSounds, 'simple focus timer default');
      Check(not S.Timer.Pomodoro.AutoStartNext, 'auto start disabled');
      CheckEquals(25 * 60, S.Timer.Pomodoro.FocusSec);
      CheckEquals(5 * 60, S.Timer.Pomodoro.ShortBreakSec);
      CheckEquals(15 * 60, S.Timer.Pomodoro.LongBreakSec);
      CheckEquals(4, S.Timer.Pomodoro.LongBreakEvery);
      for A := Low(TShortcutAction) to High(TShortcutAction) do
        CheckEquals(0, S.Shortcuts[A], 'no shortcut reserved by default');
    end);

  RegisterTest('Core', 'SettingsNormalizeClamps',
    procedure
    var
      S: TCalmSettings;
      F: TFavorite;
    begin
      S := TCalmSettings.Default;
      S.Audio.MasterVolume := 9;
      S.Audio.FadeInMs := -50;
      S.Audio.SoundVolumes[sndRain] := -1;
      S.Timer.CountdownSec := 0;
      S.Timer.Pomodoro.LongBreakEvery := 99;
      F := Default(TFavorite);
      F.Name := '  ';
      S.Favorites := [F];
      S.Normalize;
      CheckNear(1, S.Audio.MasterVolume, 0);
      CheckEquals(0, S.Audio.FadeInMs);
      CheckNear(0, S.Audio.SoundVolumes[sndRain], 0);
      CheckEquals(25 * 60, S.Timer.CountdownSec);
      CheckEquals(4, S.Timer.Pomodoro.LongBreakEvery);
      Check(S.Favorites[0].Id <> '', 'id assigned');
      CheckEquals('My mix', S.Favorites[0].Name);
    end);
end;

initialization
  Register;

end.
