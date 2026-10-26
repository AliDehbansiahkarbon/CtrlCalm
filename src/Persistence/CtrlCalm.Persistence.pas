unit CtrlCalm.Persistence;

{
  JSON settings storage (format documented in docs/ARCHITECTURE.md).

  Concurrency policy for several IDE processes sharing one settings file:
  - Every read and every read-modify-write runs under a named mutex that is
    held only for the few milliseconds of file I/O. It serializes file access;
    it never prevents several IDE processes from running their own engines.
  - Writes go to a temporary file in the same folder, are flushed, and then
    atomically replace the target (MoveFileEx with REPLACE_EXISTING and
    WRITE_THROUGH), so readers never observe a half-written file.
  - Changes are applied as mutations of the latest file contents (Update),
    so one IDE adding a favorite cannot erase a favorite saved by another.
  - Only application-wide preferences are stored. Timer state is per process
    and is never written, so no instance can overwrite another's timer.
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.JSON,
  CtrlCalm.Core.Types, CtrlCalm.Core.Settings;

type
  TSettingsMutator = reference to procedure(var Settings: TCalmSettings);

  TLoadResult = (lrLoaded, lrDefaultsNoFile, lrRecoveredCorrupt);

  TSettingsStore = class
  private
    FFileName: string;
    FMutex: THandle;
    FLastError: string;
    function Lock: Boolean;
    procedure Unlock;
    function ReadFileLocked(out Settings: TCalmSettings): TLoadResult;
    function WriteFileLocked(const Settings: TCalmSettings): Boolean;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    /// <summary>Loads settings; never raises. Corrupt files are preserved as
    /// settings.corrupt-*.json and defaults are returned.</summary>
    function Load(out Settings: TCalmSettings): TLoadResult;
    /// <summary>Applies Mutator to the latest on-disk settings and writes the
    /// result atomically. Settings receives the merged result even when the
    /// write fails (for example, a read-only folder); LastError explains why.</summary>
    function Update(const Mutator: TSettingsMutator; out Settings: TCalmSettings): Boolean;
    property FileName: string read FFileName;
    property LastError: string read FLastError;
  end;

function DefaultSettingsFolder: string;
function DefaultSettingsFileName: string;

function SettingsToJson(const S: TCalmSettings): string;
/// <summary>Parses settings JSON. Missing keys keep their defaults; unknown keys
/// are ignored; out-of-range values are clamped. Raises on invalid JSON.</summary>
function SettingsFromJson(const Json: string): TCalmSettings;

implementation

uses
  System.Math, System.DateUtils, System.IOUtils, System.Hash, Vcl.Menus;

const
  LockTimeoutMs = 3000;

function DefaultSettingsFolder: string;
begin
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('APPDATA')) + 'CtrlCalm';
end;

function DefaultSettingsFileName: string;
begin
  Result := IncludeTrailingPathDelimiter(DefaultSettingsFolder) + 'settings.json';
end;

{ Enum <-> string helpers }

const
  AccentKeys: array[TAccentPalette] of string = ('ide', 'forest', 'ocean', 'softBlue', 'amber', 'violet');
  LayoutKeys: array[TLayoutPreference] of string = ('auto', 'compact', 'comfort', 'expanded');
  StartupKeys: array[TStartupBehavior] of string = ('restoreSilently', 'autoResume');
  FocusKeys: array[TFocusLossBehavior] of string = ('keepPlaying', 'mute', 'pause');
  CompletionKeys: array[TTimerCompletionAction] of string = ('stopSounds', 'fadeOut', 'keepPlaying');
  PolicyKeys: array[TMasterPolicy] of string = ('keepCurrent', 'useSaved');
  ModeKeys: array[TTimerMode] of string = ('countdown', 'pomodoro');

function IndexOfKey(const Keys: array of string; const Value: string; Default: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Keys) do
    if SameText(Keys[I], Value) then
      Exit(I);
  Result := Default;
end;

function GetObj(Parent: TJSONObject; const Name: string): TJSONObject;
var
  V: TJSONValue;
begin
  Result := nil;
  if Parent = nil then
    Exit;
  V := Parent.GetValue(Name);
  if V is TJSONObject then
    Result := TJSONObject(V);
end;

function GetNum(Parent: TJSONObject; const Name: string; Default: Double): Double;
var
  V: TJSONValue;
begin
  Result := Default;
  if Parent = nil then
    Exit;
  V := Parent.GetValue(Name);
  if V is TJSONNumber then
    Result := TJSONNumber(V).AsDouble;
end;

function GetInt(Parent: TJSONObject; const Name: string; Default: Integer): Integer;
var
  D: Double;
begin
  D := GetNum(Parent, Name, Default);
  if IsNan(D) or (D > MaxInt) or (D < -MaxInt) then
    Result := Default
  else
    Result := Round(D);
end;

function GetBool(Parent: TJSONObject; const Name: string; Default: Boolean): Boolean;
var
  V: TJSONValue;
begin
  Result := Default;
  if Parent = nil then
    Exit;
  V := Parent.GetValue(Name);
  if V is TJSONBool then
    Result := TJSONBool(V).AsBoolean;
end;

function GetStr(Parent: TJSONObject; const Name, Default: string): string;
var
  V: TJSONValue;
begin
  Result := Default;
  if Parent = nil then
    Exit;
  V := Parent.GetValue(Name);
  if V is TJSONString then
    Result := TJSONString(V).Value;
end;

function GetDate(Parent: TJSONObject; const Name: string): TDateTime;
var
  S: string;
begin
  S := GetStr(Parent, Name, '');
  if (S = '') or not TryISO8601ToDate(S, Result, True) then
    Result := 0;
end;

function DateStr(D: TDateTime): string;
begin
  if D = 0 then
    Result := ''
  else
    Result := DateToISO8601(D, True);
end;

function NumPair(const Name: string; V: Double): TJSONPair;
begin
  Result := TJSONPair.Create(Name, TJSONNumber.Create(RoundTo(V, -4)));
end;

{ Mix }

function MixToJson(const Mix: TMix): TJSONArray;
var
  S: TSoundId;
  O: TJSONObject;
begin
  Result := TJSONArray.Create;
  for S := Low(TSoundId) to High(TSoundId) do
    if Mix.Active[S] then
    begin
      O := TJSONObject.Create;
      O.AddPair('sound', SoundKey(S));
      O.AddPair(NumPair('volume', Mix.Volumes[S]));
      Result.AddElement(O);
    end;
end;

function MixFromJson(V: TJSONValue): TMix;
var
  Item: TJSONValue;
  Id: TSoundId;
begin
  Result := TMix.Empty;
  if not (V is TJSONArray) then
    Exit;
  for Item in TJSONArray(V) do
    if (Item is TJSONObject) and TryParseSoundKey(GetStr(TJSONObject(Item), 'sound', ''), Id) then
    begin
      Result.Active[Id] := True;
      Result.Volumes[Id] := ClampVolume(GetNum(TJSONObject(Item), 'volume', DefaultSoundVolume));
    end;
end;

function SettingsToJson(const S: TCalmSettings): string;
var
  Root, Audio, Timer, Pomo, Appear, General, Keys, Vols, F: TJSONObject;
  Active, Favs: TJSONArray;
  Id: TSoundId;
  A: TShortcutAction;
  Fav: TFavorite;
begin
  Root := TJSONObject.Create;
  try
    Root.AddPair(NumPair('version', S.Version));

    Audio := TJSONObject.Create;
    Audio.AddPair(NumPair('masterVolume', S.Audio.MasterVolume));
    Audio.AddPair('muted', TJSONBool.Create(S.Audio.Muted));
    Vols := TJSONObject.Create;
    Active := TJSONArray.Create;
    for Id := Low(TSoundId) to High(TSoundId) do
    begin
      Vols.AddPair(NumPair(SoundKey(Id), S.Audio.SoundVolumes[Id]));
      if S.Audio.LastActive[Id] then
        Active.Add(SoundKey(Id));
    end;
    Audio.AddPair('soundVolumes', Vols);
    Audio.AddPair('lastActive', Active);
    Audio.AddPair(NumPair('fadeInMs', S.Audio.FadeInMs));
    Audio.AddPair(NumPair('fadeOutMs', S.Audio.FadeOutMs));
    Audio.AddPair(NumPair('presetCrossfadeMs', S.Audio.PresetCrossfadeMs));
    Audio.AddPair('startup', StartupKeys[S.Audio.Startup]);
    Audio.AddPair('focusLoss', FocusKeys[S.Audio.FocusLoss]);
    Audio.AddPair('showDeviceErrors', TJSONBool.Create(S.Audio.ShowDeviceErrors));
    Root.AddPair('audio', Audio);

    Timer := TJSONObject.Create;
    Timer.AddPair('mode', ModeKeys[S.Timer.Mode]);
    Timer.AddPair(NumPair('countdownSec', S.Timer.CountdownSec));
    Timer.AddPair('completion', CompletionKeys[S.Timer.Completion]);
    Timer.AddPair(NumPair('fadeOutSec', S.Timer.FadeOutSec));
    Timer.AddPair('notify', TJSONBool.Create(S.Timer.Notify));
    Timer.AddPair('chime', TJSONBool.Create(S.Timer.Chime));
    Pomo := TJSONObject.Create;
    Pomo.AddPair(NumPair('focusSec', S.Timer.Pomodoro.FocusSec));
    Pomo.AddPair(NumPair('shortBreakSec', S.Timer.Pomodoro.ShortBreakSec));
    Pomo.AddPair(NumPair('longBreakSec', S.Timer.Pomodoro.LongBreakSec));
    Pomo.AddPair(NumPair('longBreakEvery', S.Timer.Pomodoro.LongBreakEvery));
    Pomo.AddPair('autoStartNext', TJSONBool.Create(S.Timer.Pomodoro.AutoStartNext));
    Pomo.AddPair('focusPresetId', S.Timer.FocusPresetId);
    Pomo.AddPair('breakPresetId', S.Timer.BreakPresetId);
    Timer.AddPair('pomodoro', Pomo);
    Root.AddPair('timer', Timer);

    Appear := TJSONObject.Create;
    Appear.AddPair('followIdeTheme', TJSONBool.Create(S.Appearance.FollowIdeTheme));
    Appear.AddPair('accent', AccentKeys[S.Appearance.Accent]);
    Appear.AddPair('layout', LayoutKeys[S.Appearance.Layout]);
    Appear.AddPair('reducedMotion', TJSONBool.Create(S.Appearance.ReducedMotion));
    Root.AddPair('appearance', Appear);

    General := TJSONObject.Create;
    General.AddPair('openPanelAtStartup', TJSONBool.Create(S.General.OpenPanelAtStartup));
    General.AddPair('restoreLastPreset', TJSONBool.Create(S.General.RestoreLastPreset));
    General.AddPair('lastPresetId', S.General.LastPresetId);
    Root.AddPair('general', General);

    Keys := TJSONObject.Create;
    for A := Low(TShortcutAction) to High(TShortcutAction) do
      Keys.AddPair(ShortcutActionKey(A), ShortCutToText(S.Shortcuts[A]));
    Root.AddPair('shortcuts', Keys);

    Favs := TJSONArray.Create;
    for Fav in S.Favorites do
    begin
      F := TJSONObject.Create;
      F.AddPair('id', Fav.Id);
      F.AddPair('name', Fav.Name);
      F.AddPair('sounds', MixToJson(Fav.Mix));
      F.AddPair('masterPolicy', PolicyKeys[Fav.MasterPolicy]);
      F.AddPair(NumPair('masterVolume', Fav.MasterVolume));
      F.AddPair('accent', AccentKeys[Fav.Accent]);
      F.AddPair('created', DateStr(Fav.CreatedUtc));
      F.AddPair('modified', DateStr(Fav.ModifiedUtc));
      Favs.AddElement(F);
    end;
    Root.AddPair('favorites', Favs);

    Result := Root.Format(2);
  finally
    Root.Free;
  end;
end;

function SettingsFromJson(const Json: string): TCalmSettings;
var
  RootValue, V, Item: TJSONValue;
  Root, Audio, Timer, Pomo, Appear, General, Keys, Vols, F: TJSONObject;
  Id: TSoundId;
  A: TShortcutAction;
  Fav: TFavorite;
  Text: string;
begin
  Result := TCalmSettings.Default;
  RootValue := TJSONObject.ParseJSONValue(Json, False, True);
  try
    if not (RootValue is TJSONObject) then
      raise EJSONException.Create('Settings root must be a JSON object');
    Root := TJSONObject(RootValue);

    Audio := GetObj(Root, 'audio');
    if Assigned(Audio) then
    begin
      Result.Audio.MasterVolume := GetNum(Audio, 'masterVolume', Result.Audio.MasterVolume);
      Result.Audio.Muted := GetBool(Audio, 'muted', False);
      Vols := GetObj(Audio, 'soundVolumes');
      for Id := Low(TSoundId) to High(TSoundId) do
        Result.Audio.SoundVolumes[Id] := GetNum(Vols, SoundKey(Id), DefaultSoundVolume);
      V := Audio.GetValue('lastActive');
      if V is TJSONArray then
        for Item in TJSONArray(V) do
          if (Item is TJSONString) and TryParseSoundKey(TJSONString(Item).Value, Id) then
            Result.Audio.LastActive[Id] := True;
      Result.Audio.FadeInMs := GetInt(Audio, 'fadeInMs', Result.Audio.FadeInMs);
      Result.Audio.FadeOutMs := GetInt(Audio, 'fadeOutMs', Result.Audio.FadeOutMs);
      Result.Audio.PresetCrossfadeMs := GetInt(Audio, 'presetCrossfadeMs', Result.Audio.PresetCrossfadeMs);
      Result.Audio.Startup := TStartupBehavior(IndexOfKey(StartupKeys, GetStr(Audio, 'startup', ''), 0));
      Result.Audio.FocusLoss := TFocusLossBehavior(IndexOfKey(FocusKeys, GetStr(Audio, 'focusLoss', ''), 0));
      Result.Audio.ShowDeviceErrors := GetBool(Audio, 'showDeviceErrors', True);
    end;

    Timer := GetObj(Root, 'timer');
    if Assigned(Timer) then
    begin
      Result.Timer.Mode := TTimerMode(IndexOfKey(ModeKeys, GetStr(Timer, 'mode', ''), 0));
      Result.Timer.CountdownSec := GetInt(Timer, 'countdownSec', Result.Timer.CountdownSec);
      Result.Timer.Completion := TTimerCompletionAction(IndexOfKey(CompletionKeys,
        GetStr(Timer, 'completion', ''), 0));
      Result.Timer.FadeOutSec := GetInt(Timer, 'fadeOutSec', Result.Timer.FadeOutSec);
      Result.Timer.Notify := GetBool(Timer, 'notify', True);
      Result.Timer.Chime := GetBool(Timer, 'chime', True);
      Pomo := GetObj(Timer, 'pomodoro');
      if Assigned(Pomo) then
      begin
        Result.Timer.Pomodoro.FocusSec := GetInt(Pomo, 'focusSec', Result.Timer.Pomodoro.FocusSec);
        Result.Timer.Pomodoro.ShortBreakSec := GetInt(Pomo, 'shortBreakSec', Result.Timer.Pomodoro.ShortBreakSec);
        Result.Timer.Pomodoro.LongBreakSec := GetInt(Pomo, 'longBreakSec', Result.Timer.Pomodoro.LongBreakSec);
        Result.Timer.Pomodoro.LongBreakEvery := GetInt(Pomo, 'longBreakEvery', Result.Timer.Pomodoro.LongBreakEvery);
        Result.Timer.Pomodoro.AutoStartNext := GetBool(Pomo, 'autoStartNext', False);
        Result.Timer.FocusPresetId := GetStr(Pomo, 'focusPresetId', '');
        Result.Timer.BreakPresetId := GetStr(Pomo, 'breakPresetId', '');
      end;
    end;

    Appear := GetObj(Root, 'appearance');
    if Assigned(Appear) then
    begin
      Result.Appearance.FollowIdeTheme := GetBool(Appear, 'followIdeTheme', True);
      Result.Appearance.Accent := TAccentPalette(IndexOfKey(AccentKeys, GetStr(Appear, 'accent', ''),
        Ord(Result.Appearance.Accent)));
      Result.Appearance.Layout := TLayoutPreference(IndexOfKey(LayoutKeys, GetStr(Appear, 'layout', ''), 0));
      Result.Appearance.ReducedMotion := GetBool(Appear, 'reducedMotion', False);
    end;

    General := GetObj(Root, 'general');
    if Assigned(General) then
    begin
      Result.General.OpenPanelAtStartup := GetBool(General, 'openPanelAtStartup', False);
      Result.General.RestoreLastPreset := GetBool(General, 'restoreLastPreset', True);
      Result.General.LastPresetId := GetStr(General, 'lastPresetId', '');
    end;

    Keys := GetObj(Root, 'shortcuts');
    if Assigned(Keys) then
      for A := Low(TShortcutAction) to High(TShortcutAction) do
      begin
        Text := GetStr(Keys, ShortcutActionKey(A), '');
        if Text <> '' then
          Result.Shortcuts[A] := TextToShortCut(Text);
      end;

    V := Root.GetValue('favorites');
    if V is TJSONArray then
      for Item in TJSONArray(V) do
      begin
        if not (Item is TJSONObject) then
          Continue;
        F := TJSONObject(Item);
        Fav := Default(TFavorite);
        Fav.Id := GetStr(F, 'id', '');
        Fav.Name := GetStr(F, 'name', '');
        Fav.Mix := MixFromJson(F.GetValue('sounds'));
        Fav.MasterPolicy := TMasterPolicy(IndexOfKey(PolicyKeys, GetStr(F, 'masterPolicy', ''), 0));
        Fav.MasterVolume := GetNum(F, 'masterVolume', DefaultMasterVolume);
        Fav.Accent := TAccentPalette(IndexOfKey(AccentKeys, GetStr(F, 'accent', ''), 0));
        Fav.CreatedUtc := GetDate(F, 'created');
        Fav.ModifiedUtc := GetDate(F, 'modified');
        // Ignore entries whose id was already loaded.
        if (Fav.Id <> '') and (Result.FavoriteIndex(Fav.Id) >= 0) then
          Continue;
        Result.Favorites := Result.Favorites + [Fav];
      end;
  finally
    RootValue.Free;
  end;
  Result.Normalize;
end;

{ TSettingsStore }

constructor TSettingsStore.Create(const AFileName: string);
var
  Name: string;
begin
  inherited Create;
  FFileName := ExpandFileName(AFileName);
  // One mutex per settings file, local to the user session.
  Name := 'Local\CtrlCalm.Settings.' + THashMD5.GetHashString(LowerCase(FFileName));
  FMutex := CreateMutex(nil, False, PChar(Name));
end;

destructor TSettingsStore.Destroy;
begin
  if FMutex <> 0 then
    CloseHandle(FMutex);
  inherited;
end;

function TSettingsStore.Lock: Boolean;
var
  R: DWORD;
begin
  if FMutex = 0 then
    Exit(True); // degrade to unsynchronized rather than fail
  R := WaitForSingleObject(FMutex, LockTimeoutMs);
  // WAIT_ABANDONED: a previous holder died; the mutex is now owned and the file is
  // still consistent thanks to atomic replacement.
  Result := (R = WAIT_OBJECT_0) or (R = WAIT_ABANDONED);
  if not Result then
    FLastError := 'Timed out waiting for the settings lock';
end;

procedure TSettingsStore.Unlock;
begin
  if FMutex <> 0 then
    ReleaseMutex(FMutex);
end;

function TSettingsStore.ReadFileLocked(out Settings: TCalmSettings): TLoadResult;
var
  Text, Backup: string;
begin
  Settings := TCalmSettings.Default;
  if not FileExists(FFileName) then
    Exit(lrDefaultsNoFile);
  try
    Text := TFile.ReadAllText(FFileName, TEncoding.UTF8);
    Settings := SettingsFromJson(Text);
    Result := lrLoaded;
  except
    on E: Exception do
    begin
      FLastError := 'Settings file was unreadable and has been reset: ' + E.Message;
      Backup := ChangeFileExt(FFileName, '') + '.corrupt-' +
        FormatDateTime('yyyymmdd-hhnnss', Now) + '.json';
      // Keep the damaged file for diagnosis; ignore failures (read-only media).
      MoveFileEx(PChar(FFileName), PChar(Backup), MOVEFILE_REPLACE_EXISTING);
      Settings := TCalmSettings.Default;
      Result := lrRecoveredCorrupt;
    end;
  end;
end;

function TSettingsStore.WriteFileLocked(const Settings: TCalmSettings): Boolean;
var
  Temp: string;
  Bytes: TBytes;
  H: THandle;
  Written: DWORD;
  Attempt: Integer;
begin
  Result := False;
  try
    ForceDirectories(ExtractFileDir(FFileName));
    Temp := FFileName + '.tmp-' + IntToStr(GetCurrentProcessId);
    Bytes := TEncoding.UTF8.GetBytes(SettingsToJson(Settings));
    H := CreateFile(PChar(Temp), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if H = INVALID_HANDLE_VALUE then
      RaiseLastOSError;
    try
      if (Length(Bytes) > 0) and
         (not WriteFile(H, Bytes[0], Length(Bytes), Written, nil) or (Written <> DWORD(Length(Bytes)))) then
        RaiseLastOSError;
      FlushFileBuffers(H);
    finally
      CloseHandle(H);
    end;
    for Attempt := 1 to 5 do
    begin
      if MoveFileEx(PChar(Temp), PChar(FFileName), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
        Exit(True);
      Sleep(20 * Attempt); // transient sharing violation (antivirus, indexer)
    end;
    FLastError := 'Cannot replace settings file: ' + SysErrorMessage(GetLastError);
    DeleteFile(Temp);
  except
    on E: Exception do
    begin
      FLastError := 'Cannot save settings: ' + E.Message;
      if Temp <> '' then
        DeleteFile(Temp);
    end;
  end;
end;

function TSettingsStore.Load(out Settings: TCalmSettings): TLoadResult;
begin
  FLastError := '';
  if not Lock then
  begin
    Settings := TCalmSettings.Default;
    Exit(lrDefaultsNoFile);
  end;
  try
    Result := ReadFileLocked(Settings);
  finally
    Unlock;
  end;
end;

function TSettingsStore.Update(const Mutator: TSettingsMutator; out Settings: TCalmSettings): Boolean;
begin
  FLastError := '';
  if not Lock then
  begin
    Settings := TCalmSettings.Default;
    Exit(False);
  end;
  try
    ReadFileLocked(Settings);
    Mutator(Settings);
    Settings.Normalize;
    Result := WriteFileLocked(Settings);
  finally
    Unlock;
  end;
end;

end.
