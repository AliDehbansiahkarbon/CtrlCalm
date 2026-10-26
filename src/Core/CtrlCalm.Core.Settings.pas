unit CtrlCalm.Core.Settings;

{ Settings, favorites and built-in presets. Plain value types (records and
  dynamic arrays) so that copies can be handed between threads safely. }

interface

uses
  System.SysUtils, System.Classes, CtrlCalm.Core.Types;

type
  TMasterPolicy = (mpKeepCurrent, mpUseSaved);

  TAccentPalette = (apIde, apForest, apOcean, apSoftBlue, apAmber, apViolet);

  TLayoutPreference = (lpAuto, lpCompact, lpComfort, lpExpanded);

  TStartupBehavior = (sbRestoreSilently, sbAutoResume);

  TFocusLossBehavior = (flKeepPlaying, flMute, flPause);

  TFavorite = record
    Id: string;               // GUID string for user favorites, 'builtin:*' for presets
    Name: string;
    BuiltIn: Boolean;
    Mix: TMix;
    MasterPolicy: TMasterPolicy;
    MasterVolume: Single;
    Accent: TAccentPalette;
    CreatedUtc: TDateTime;
    ModifiedUtc: TDateTime;
  end;

  TFavorites = TArray<TFavorite>;

  TShortcutAction = (saShowHide, saPlayPause, saMute, saTimer);
  TShortcuts = array[TShortcutAction] of TShortCut;

  TAudioSettings = record
    MasterVolume: Single;
    Muted: Boolean;
    SoundVolumes: TSoundVolumes;
    LastActive: TSoundFlags;     // sounds that were on when last saved
    FadeInMs: Integer;
    FadeOutMs: Integer;
    PresetCrossfadeMs: Integer;
    Startup: TStartupBehavior;
    FocusLoss: TFocusLossBehavior;
    ShowDeviceErrors: Boolean;
  end;

  TTimerSettings = record
    CountdownSec: Integer;
    Completion: TTimerCompletionAction;
    FadeOutSec: Integer;
    Notify: Boolean;
    Chime: Boolean;
    Pomodoro: TPomodoroConfig;
    FocusPresetId: string;       // '' = leave the mix unchanged
    BreakPresetId: string;
    Mode: TTimerMode;
  end;

  TAppearanceSettings = record
    FollowIdeTheme: Boolean;
    Accent: TAccentPalette;
    Layout: TLayoutPreference;
    ReducedMotion: Boolean;
  end;

  TGeneralSettings = record
    OpenPanelAtStartup: Boolean;
    RestoreLastPreset: Boolean;
    LastPresetId: string;
  end;

  TCalmSettings = record
    Version: Integer;
    Audio: TAudioSettings;
    Timer: TTimerSettings;
    Appearance: TAppearanceSettings;
    General: TGeneralSettings;
    Shortcuts: TShortcuts;
    Favorites: TFavorites;      // user favorites only; built-ins are not persisted
    class function Default: TCalmSettings; static;
    /// <summary>Clamps every value into its documented range.</summary>
    procedure Normalize;
    function FavoriteIndex(const Id: string): Integer;
  end;

const
  SettingsVersion = 1;
  FadeChoicesSec: array[0..2] of Integer = (5, 15, 30);
  TimerPresetMinutes: array[0..4] of Integer = (5, 15, 25, 45, 60);

function BuiltInPresets: TFavorites;
function FindPreset(const Settings: TCalmSettings; const Id: string; out Preset: TFavorite): Boolean;
function NewFavoriteId: string;
function MixFromPairs(const Pairs: array of const): TMix;

function AccentName(A: TAccentPalette): string;
function ShortcutActionName(A: TShortcutAction): string;
function ShortcutActionKey(A: TShortcutAction): string;

implementation

uses
  System.Math, System.DateUtils;

function AccentName(A: TAccentPalette): string;
const
  Names: array[TAccentPalette] of string = ('IDE accent', 'Forest green', 'Ocean teal',
    'Soft blue', 'Warm amber', 'Muted violet');
begin
  Result := Names[A];
end;

function ShortcutActionName(A: TShortcutAction): string;
const
  Names: array[TShortcutAction] of string = ('Show/hide Ctrl+Calm', 'Play/pause',
    'Toggle mute', 'Open timer');
begin
  Result := Names[A];
end;

function ShortcutActionKey(A: TShortcutAction): string;
const
  Keys: array[TShortcutAction] of string = ('showHide', 'playPause', 'mute', 'timer');
begin
  Result := Keys[A];
end;

function NewFavoriteId: string;
var
  G: TGUID;
begin
  CreateGUID(G);
  Result := LowerCase(Copy(G.ToString, 2, 36));
end;

function MixFromPairs(const Pairs: array of const): TMix;
var
  I: Integer;
  Id: TSoundId;
begin
  // Pairs: TSoundId ordinal, Extended volume, ...
  Result := TMix.Empty;
  I := 0;
  while I < High(Pairs) do
  begin
    Id := TSoundId(Pairs[I].VInteger);
    Result.Active[Id] := True;
    Result.Volumes[Id] := ClampVolume(Pairs[I + 1].VExtended^);
    Inc(I, 2);
  end;
end;

function Preset(const Id, Name: string; Accent: TAccentPalette; const Mix: TMix): TFavorite;
begin
  Result := Default(TFavorite);
  Result.Id := 'builtin:' + Id;
  Result.Name := Name;
  Result.BuiltIn := True;
  Result.Mix := Mix;
  Result.MasterPolicy := mpKeepCurrent;
  Result.MasterVolume := DefaultMasterVolume;
  Result.Accent := Accent;
end;

function BuiltInPresets: TFavorites;
begin
  // Conservative levels: the loudest layer sits at 0.5 and supporting layers
  // well below it, so built-ins never trip the engine's headroom limiter.
  Result := [
    Preset('deep-focus', 'Deep Focus', apSoftBlue,
      MixFromPairs([Ord(sndBrownNoise), 0.45, Ord(sndRain), 0.35, Ord(sndForest), 0.2])),
    Preset('coffee-and-code', 'Coffee & Code', apAmber,
      MixFromPairs([Ord(sndCoffeeShop), 0.5, Ord(sndRain), 0.25])),
    Preset('calm-coding', 'Calm Coding', apForest,
      MixFromPairs([Ord(sndForest), 0.4, Ord(sndStream), 0.35, Ord(sndWind), 0.2])),
    Preset('rainy-night', 'Rainy Night', apViolet,
      MixFromPairs([Ord(sndRain), 0.45, Ord(sndThunderstorm), 0.2, Ord(sndFireplace), 0.3])),
    Preset('seaside-breeze', 'Seaside Breeze', apOcean,
      MixFromPairs([Ord(sndSeaside), 0.45, Ord(sndWind), 0.2]))
  ];
end;

function FindPreset(const Settings: TCalmSettings; const Id: string; out Preset: TFavorite): Boolean;
var
  F: TFavorite;
begin
  for F in BuiltInPresets do
    if F.Id = Id then
    begin
      Preset := F;
      Exit(True);
    end;
  for F in Settings.Favorites do
    if F.Id = Id then
    begin
      Preset := F;
      Exit(True);
    end;
  Result := False;
end;

{ TCalmSettings }

class function TCalmSettings.Default: TCalmSettings;
var
  S: TSoundId;
begin
  Result := System.Default(TCalmSettings);
  Result.Version := SettingsVersion;
  with Result.Audio do
  begin
    MasterVolume := DefaultMasterVolume;
    Muted := False;
    for S := Low(TSoundId) to High(TSoundId) do
    begin
      SoundVolumes[S] := DefaultSoundVolume;
      LastActive[S] := False;
    end;
    FadeInMs := 1500;
    FadeOutMs := 1000;
    PresetCrossfadeMs := 2000;
    Startup := sbRestoreSilently;
    FocusLoss := flKeepPlaying;
    ShowDeviceErrors := True;
  end;
  with Result.Timer do
  begin
    CountdownSec := 25 * 60;
    Completion := tcaStopSounds;
    FadeOutSec := 15;
    Notify := True;
    Chime := True;
    Pomodoro := TPomodoroConfig.Default;
    FocusPresetId := '';
    BreakPresetId := '';
    Mode := tmCountdown;
  end;
  with Result.Appearance do
  begin
    FollowIdeTheme := True;
    Accent := apForest;
    Layout := lpAuto;
    ReducedMotion := False;
  end;
  with Result.General do
  begin
    OpenPanelAtStartup := False;
    RestoreLastPreset := True;
    LastPresetId := '';
  end;
  // No shortcuts are reserved by default: they are opt-in to avoid clashing
  // with editor key bindings.
  FillChar(Result.Shortcuts, SizeOf(Result.Shortcuts), 0);
  Result.Favorites := nil;
end;

procedure TCalmSettings.Normalize;
var
  S: TSoundId;
  I: Integer;
begin
  Version := SettingsVersion;
  Audio.MasterVolume := ClampVolume(Audio.MasterVolume);
  for S := Low(TSoundId) to High(TSoundId) do
    Audio.SoundVolumes[S] := ClampVolume(Audio.SoundVolumes[S]);
  Audio.FadeInMs := EnsureRange(Audio.FadeInMs, 0, 10000);
  Audio.FadeOutMs := EnsureRange(Audio.FadeOutMs, 0, 10000);
  Audio.PresetCrossfadeMs := EnsureRange(Audio.PresetCrossfadeMs, 0, 10000);
  if not ValidTimerDuration(Timer.CountdownSec) then
    Timer.CountdownSec := 25 * 60;
  Timer.FadeOutSec := EnsureRange(Timer.FadeOutSec, 1, 120);
  Timer.Pomodoro := Timer.Pomodoro.Normalized;
  for I := 0 to High(Favorites) do
  begin
    Favorites[I].BuiltIn := False;
    if Favorites[I].Id = '' then
      Favorites[I].Id := NewFavoriteId;
    if Trim(Favorites[I].Name) = '' then
      Favorites[I].Name := 'My mix';
    Favorites[I].MasterVolume := ClampVolume(Favorites[I].MasterVolume);
    for S := Low(TSoundId) to High(TSoundId) do
      Favorites[I].Mix.Volumes[S] := ClampVolume(Favorites[I].Mix.Volumes[S]);
  end;
end;

function TCalmSettings.FavoriteIndex(const Id: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Favorites) do
    if Favorites[I].Id = Id then
      Exit(I);
  Result := -1;
end;

end.
