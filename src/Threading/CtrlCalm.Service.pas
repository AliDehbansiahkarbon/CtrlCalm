unit CtrlCalm.Service;

{
  TCalmService: the process-local lifecycle controller and the only object the
  UI talks to. All public members are main-thread only.

  It owns the worker thread, the settings store and a hidden message window.
  The worker's change notifications arrive as a single coalesced posted
  message on that window, so no worker code ever runs VCL code and nothing
  uses TThread.Synchronize/Queue (which can deadlock or outlive the package
  during unload). Destroying the service stops the worker first, then
  destroys the window, so no posted message can reach freed code.

  One instance per IDE process: the IDE package creates it lazily on first use
  and frees it when the package unloads. Separate IDE processes never share
  an instance; each has its own worker and engine.
}

interface

uses
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI, System.SysUtils, System.Classes,
  System.Generics.Collections,
  CtrlCalm.Core.Types, CtrlCalm.Core.Settings, CtrlCalm.Timer,
  CtrlCalm.Threading.Worker, CtrlCalm.Persistence;

type
  TCalmChange = (ccState, ccSettings, ccFavorites, ccTimerEvent);
  TCalmChanges = set of TCalmChange;
  TCalmListener = procedure(Changes: TCalmChanges) of object;

  TCalmService = class
  private
    FWorker: TCalmWorker;
    FStore: TSettingsStore;
    FSettings: TCalmSettings;
    FWnd: HWND;
    FNotifyPending: Integer;
    FListeners: TList<TCalmListener>;
    FSnapshot: TCalmSnapshot;
    FMix: TMix;
    FMaster: Single;
    FMuted: Boolean;
    FPaused: Boolean;
    FLastSentSeq: Int64;
    FLastTimerEventSeq: Integer;
    FSaveScheduled: Boolean;
    FBalloonVisible: Boolean;
    FIdeFocused: Boolean;
    FPausedByFocus: Boolean;
    FSoundsFolder: string;
    FLastPersistError: string;
    FLastTimerEvent: TTimerEvent;
    FShuttingDown: Boolean;
    FDispatching: Boolean;
    procedure WndProc(var Msg: TMessage);
    procedure WorkerChanged;
    procedure HandleWorkerNotification;
    procedure Notify(Changes: TCalmChanges);
    function Send(C: TCalmCommand): Int64;
    procedure ScheduleSave;
    procedure SaveNow;
    procedure ShowBalloon(const Title, Text: string);
    procedure HideBalloon;
    procedure Persist(const Mutator: TSettingsMutator; Changes: TCalmChanges);
    procedure SendFades;
    function TimerOptions: TTimerOptions;
    function MixForPreset(const Id: string; out Mix: TMix): Boolean;
  public
    constructor Create(const ASoundsFolder: string; const ASettingsFile: string = '';
      AAllowDevice: Boolean = True);
    destructor Destroy; override;

    procedure AddListener(const L: TCalmListener);
    procedure RemoveListener(const L: TCalmListener);

    // mixer
    function IsActive(Id: TSoundId): Boolean;
    function Volume(Id: TSoundId): Single;
    procedure ToggleSound(Id: TSoundId);
    procedure SetSoundActive(Id: TSoundId; Active: Boolean);
    procedure SetSoundVolume(Id: TSoundId; V: Single);
    procedure SetMasterVolume(V: Single);
    procedure SetMuted(Value: Boolean);
    procedure ToggleMute;
    procedure Play;
    procedure Pause;
    procedure TogglePlayPause;
    procedure StopAll;
    function CurrentMix: TMix;
    function HasActiveSounds: Boolean;

    // presets and favorites
    function Presets: TFavorites;      // built-ins followed by user favorites
    procedure ApplyPreset(const Preset: TFavorite);
    function SaveCurrentAsFavorite(const AName: string = ''): string;
    procedure RenameFavorite(const Id, NewName: string);
    procedure UpdateFavoriteFromCurrent(const Id: string);
    procedure DeleteFavorite(const Id: string);
    function DuplicateFavorite(const Id: string): string;
    function MatchingPresetId: string;

    // timer
    procedure StartCountdown(Seconds: Integer);
    procedure StartPomodoro;
    procedure PauseTimer;
    procedure ResumeTimer;
    procedure CancelTimer;
    procedure ResetTimer;
    procedure StartNextPhase;
    procedure PreviewChime;

    // settings
    procedure UpdateSettings(const Mutator: TSettingsMutator);
    procedure SetIdeFocused(Focused: Boolean);
    procedure ReloadSettings;

    // diagnostics
    function WorkerCpuTimeMs: Double;
    function DiagnosticsText: string;
    function SettingsFileName: string;

    property Snapshot: TCalmSnapshot read FSnapshot;
    property Settings: TCalmSettings read FSettings;
    property MasterVolume: Single read FMaster;
    property Muted: Boolean read FMuted;
    property Paused: Boolean read FPaused;
    property SoundsFolder: string read FSoundsFolder;
    property LastPersistError: string read FLastPersistError;
    property LastTimerEvent: TTimerEvent read FLastTimerEvent;
  end;

const
  WM_CALM_CHANGED = WM_APP + $C47;
  SaveTimerId = 1;
  BalloonTimerId = 2;
  SaveDelayMs = 1500;
  BalloonMs = 10000;

function PhaseName(P: TPomodoroPhase): string;

implementation

uses
  System.Math, System.DateUtils, Vcl.Forms;

function SameFlags(const A, B: TSoundFlags): Boolean;
var
  S: TSoundId;
begin
  for S := Low(TSoundId) to High(TSoundId) do
    if A[S] <> B[S] then
      Exit(False);
  Result := True;
end;

function PhaseName(P: TPomodoroPhase): string;
begin
  case P of
    ppFocus: Result := 'Focus';
    ppShortBreak: Result := 'Short break';
  else
    Result := 'Long break';
  end;
end;

{ TCalmService }

constructor TCalmService.Create(const ASoundsFolder, ASettingsFile: string; AAllowDevice: Boolean);
var
  FileName: string;
  C: TCalmCommand;
  S: TSoundId;
begin
  inherited Create;
  FIdeFocused := True;
  FSoundsFolder := ASoundsFolder;
  FListeners := TList<TCalmListener>.Create;
  FileName := ASettingsFile;
  if FileName = '' then
    FileName := DefaultSettingsFileName;
  FStore := TSettingsStore.Create(FileName);
  FStore.Load(FSettings);
  FLastPersistError := FStore.LastError;

  FWnd := AllocateHWnd(WndProc);

  // Restore configuration silently: volumes and the last mix are restored,
  // but nothing plays unless auto-resume was deliberately enabled.
  FMix := TMix.Empty;
  FMix.Volumes := FSettings.Audio.SoundVolumes;
  if FSettings.General.RestoreLastPreset then
    FMix.Active := FSettings.Audio.LastActive;
  FMaster := FSettings.Audio.MasterVolume;
  FMuted := FSettings.Audio.Muted;
  FPaused := True;

  FWorker := TCalmWorker.Create(ASoundsFolder, AAllowDevice);
  FWorker.OnChanged := WorkerChanged;
  FSnapshot := FWorker.Snapshot;

  SendFades;
  C := MakeCommand(ckSetMasterVolume);
  C.Value := FMaster;
  Send(C);
  C := MakeCommand(ckSetMuted);
  C.Flag := FMuted;
  Send(C);
  // Arm the restored mix while paused: sources are prepared, nothing is heard.
  C := MakeCommand(ckApplyPreset);
  C.Mix := FMix;
  C.DurationMs := 0;
  Send(C);
  for S := Low(TSoundId) to High(TSoundId) do
    if not FMix.Active[S] then
    begin
      C := MakeCommand(ckSetSoundVolume);
      C.Sound := S;
      C.Value := FMix.Volumes[S];
      Send(C);
    end;
  if (FSettings.Audio.Startup = sbAutoResume) and (FMix.ActiveCount > 0) then
    Play;
end;

destructor TCalmService.Destroy;
begin
  FShuttingDown := True;
  try
    if FSaveScheduled then
      SaveNow;
  except
  end;
  // Worker first (ordered audio shutdown + thread join), then the window.
  if Assigned(FWorker) then
  begin
    FWorker.OnChanged := nil;
    FWorker.Shutdown;
    FreeAndNil(FWorker);
  end;
  HideBalloon;
  if FWnd <> 0 then
  begin
    KillTimer(FWnd, SaveTimerId);
    KillTimer(FWnd, BalloonTimerId);
    DeallocateHWnd(FWnd);
    FWnd := 0;
  end;
  FreeAndNil(FStore);
  FreeAndNil(FListeners);
  inherited;
end;

procedure TCalmService.AddListener(const L: TCalmListener);
begin
  if not FListeners.Contains(L) then
    FListeners.Add(L);
end;

procedure TCalmService.RemoveListener(const L: TCalmListener);
begin
  if Assigned(FListeners) then
    FListeners.Remove(L);
end;

procedure TCalmService.Notify(Changes: TCalmChanges);
var
  Snapshot: TArray<TCalmListener>;
  L: TCalmListener;
begin
  if FShuttingDown or (Changes = []) then
    Exit;
  Snapshot := FListeners.ToArray; // listeners may unregister while notified
  for L in Snapshot do
    if FListeners.Contains(L) then
      try
        L(Changes);
      except
        Application.HandleException(Self);
      end;
end;

function TCalmService.Send(C: TCalmCommand): Int64;
begin
  Result := -1;
  if Assigned(FWorker) then
    Result := FWorker.Post(C);
  if Result > 0 then
    FLastSentSeq := Result;
end;

procedure TCalmService.WorkerChanged;
begin
  // Worker thread: coalesce into at most one pending message.
  if AtomicCmpExchange(FNotifyPending, 1, 0) = 0 then
    if not PostMessage(FWnd, WM_CALM_CHANGED, 0, 0) then
      AtomicExchange(FNotifyPending, 0);
end;

procedure TCalmService.WndProc(var Msg: TMessage);
begin
  try
    case Msg.Msg of
      WM_CALM_CHANGED:
        begin
          AtomicExchange(FNotifyPending, 0);
          HandleWorkerNotification;
        end;
      WM_TIMER:
        if Msg.WParam = SaveTimerId then
        begin
          KillTimer(FWnd, SaveTimerId);
          SaveNow;
        end
        else if Msg.WParam = BalloonTimerId then
        begin
          KillTimer(FWnd, BalloonTimerId);
          HideBalloon;
        end;
    else
      Msg.Result := DefWindowProc(FWnd, Msg.Msg, Msg.WParam, Msg.LParam);
    end;
  except
    // never propagate into the IDE message loop
  end;
end;

procedure TCalmService.HandleWorkerNotification;
var
  Changes: TCalmChanges;
  E: TTimerEvent;
  Title, Text: string;
  Info: TFlashWInfo;
begin
  if FShuttingDown or not Assigned(FWorker) or FDispatching then
    Exit;
  FDispatching := True;
  try
    FSnapshot := FWorker.Snapshot;
    Changes := [ccState];
    // Adopt the worker's logical state only once it has processed every command
    // sent so far; otherwise a stale snapshot would undo a click in flight.
    if FSnapshot.ProcessedSeq >= FLastSentSeq then
    begin
      if not SameFlags(FMix.Active, FSnapshot.Active) then
        ScheduleSave;
      FMix.Active := FSnapshot.Active;
      FMix.Volumes := FSnapshot.Volumes;
      FMaster := FSnapshot.MasterVolume;
      FMuted := FSnapshot.Muted;
      FPaused := FSnapshot.Paused;
    end;
    if FSnapshot.TimerEventSeq <> FLastTimerEventSeq then
    begin
      FLastTimerEventSeq := FSnapshot.TimerEventSeq;
      E := FSnapshot.TimerEvent;
      FLastTimerEvent := E;
      Include(Changes, ccTimerEvent);
      if FSnapshot.TimerOptions.Notify then
      begin
        if E.Kind = tekCountdownCompleted then
        begin
          Title := 'Ctrl+Calm - Timer finished';
          case FSnapshot.TimerOptions.Completion of
            tcaStopSounds: Text := 'Your focus session is complete. Sounds stopped.';
            tcaFadeOut: Text := 'Your focus session is complete. Sounds are fading out.';
          else
            Text := 'Your focus session is complete.';
          end;
        end
        else
        begin
          Title := 'Ctrl+Calm - ' + PhaseName(E.EndedPhase) + ' finished';
          if E.NextStarted then
            Text := PhaseName(E.NextPhase) + ' has started.'
          else
            Text := 'Next up: ' + PhaseName(E.NextPhase) + '.';
        end;
        ShowBalloon(Title, Text);
        if (Application <> nil) and (Application.MainFormHandle <> 0) and
           (GetForegroundWindow <> Application.MainFormHandle) then
        begin
          Info := Default(TFlashWInfo);
          Info.cbSize := SizeOf(Info);
          Info.hwnd := Application.MainFormHandle;
          Info.dwFlags := FLASHW_TRAY or FLASHW_TIMERNOFG;
          Info.uCount := 3;
          FlashWindowEx(Info);
        end;
      end;
    end;
    Notify(Changes);
  finally
    FDispatching := False;
  end;
end;

procedure TCalmService.ShowBalloon(const Title, Text: string);
var
  Data: TNotifyIconData;
begin
  Data := Default(TNotifyIconData);
  Data.cbSize := SizeOf(Data);
  Data.Wnd := FWnd;
  Data.uID := 1;
  Data.uFlags := NIF_ICON or NIF_TIP or NIF_INFO;
  if (Application <> nil) and (Application.Icon <> nil) and (Application.Icon.Handle <> 0) then
    Data.hIcon := Application.Icon.Handle
  else
    Data.hIcon := LoadIcon(0, IDI_INFORMATION);
  StrPLCopy(Data.szTip, 'Ctrl+Calm', Length(Data.szTip) - 1);
  StrPLCopy(Data.szInfoTitle, Title, Length(Data.szInfoTitle) - 1);
  StrPLCopy(Data.szInfo, Text, Length(Data.szInfo) - 1);
  Data.dwInfoFlags := NIIF_INFO or NIIF_NOSOUND; // Ctrl+Calm plays its own chime
  if FBalloonVisible then
    Shell_NotifyIcon(NIM_MODIFY, @Data)
  else
    FBalloonVisible := Shell_NotifyIcon(NIM_ADD, @Data);
  if FBalloonVisible then
    SetTimer(FWnd, BalloonTimerId, BalloonMs, nil);
end;

procedure TCalmService.HideBalloon;
var
  Data: TNotifyIconData;
begin
  if not FBalloonVisible then
    Exit;
  Data := Default(TNotifyIconData);
  Data.cbSize := SizeOf(Data);
  Data.Wnd := FWnd;
  Data.uID := 1;
  Shell_NotifyIcon(NIM_DELETE, @Data);
  FBalloonVisible := False;
end;

procedure TCalmService.ScheduleSave;
begin
  if FShuttingDown and not FSaveScheduled then
    Exit;
  FSaveScheduled := True;
  if FWnd <> 0 then
    SetTimer(FWnd, SaveTimerId, SaveDelayMs, nil);
end;

procedure TCalmService.SaveNow;
var
  Mix: TMix;
  Master: Single;
  Mute: Boolean;
begin
  FSaveScheduled := False;
  Mix := FMix;
  Master := FMaster;
  Mute := FMuted;
  Persist(
    procedure(var S: TCalmSettings)
    begin
      S.Audio.MasterVolume := Master;
      S.Audio.Muted := Mute;
      S.Audio.SoundVolumes := Mix.Volumes;
      S.Audio.LastActive := Mix.Active;
    end, []);
end;

procedure TCalmService.Persist(const Mutator: TSettingsMutator; Changes: TCalmChanges);
var
  Merged: TCalmSettings;
begin
  if FStore.Update(Mutator, Merged) then
  begin
    FSettings := Merged;
    FLastPersistError := '';
  end
  else
  begin
    // Read-only or locked storage: keep working with the in-memory copy.
    Mutator(FSettings);
    FSettings.Normalize;
    FLastPersistError := FStore.LastError;
  end;
  Notify(Changes);
end;

procedure TCalmService.SendFades;
var
  C: TCalmCommand;
begin
  C := MakeCommand(ckSetFades);
  C.FadeInMs := FSettings.Audio.FadeInMs;
  C.FadeOutMs := FSettings.Audio.FadeOutMs;
  Send(C);
end;

function TCalmService.IsActive(Id: TSoundId): Boolean;
begin
  Result := FMix.Active[Id];
end;

function TCalmService.Volume(Id: TSoundId): Single;
begin
  Result := FMix.Volumes[Id];
end;

procedure TCalmService.SetSoundActive(Id: TSoundId; Active: Boolean);
var
  C: TCalmCommand;
begin
  if Active and (FSnapshot.TrackStates[Id] = tsUnavailable) then
  begin
    Notify([ccState]); // let the UI show the reason
    Exit;
  end;
  if FMix.Active[Id] = Active then
    Exit;
  FMix.Active[Id] := Active;
  if Active then
  begin
    C := MakeCommand(ckActivateSound);
    C.Sound := Id;
    C.Value := FMix.Volumes[Id];
    Send(C);
    // Choosing a sound is an explicit request to hear it.
    if FPaused then
      Play;
  end
  else
  begin
    C := MakeCommand(ckDeactivateSound);
    C.Sound := Id;
    Send(C);
  end;
  ScheduleSave;
  Notify([ccState]);
end;

procedure TCalmService.ToggleSound(Id: TSoundId);
begin
  if FMix.Active[Id] and FPaused then
    Play // an armed-but-paused sound starts on click
  else
    SetSoundActive(Id, not FMix.Active[Id]);
end;

procedure TCalmService.SetSoundVolume(Id: TSoundId; V: Single);
var
  C: TCalmCommand;
begin
  V := ClampVolume(V);
  if Abs(FMix.Volumes[Id] - V) < 0.0005 then
    Exit;
  FMix.Volumes[Id] := V;
  C := MakeCommand(ckSetSoundVolume);
  C.Sound := Id;
  C.Value := V;
  Send(C);
  ScheduleSave;
  Notify([ccState]);
end;

procedure TCalmService.SetMasterVolume(V: Single);
var
  C: TCalmCommand;
begin
  V := ClampVolume(V);
  if Abs(FMaster - V) < 0.0005 then
    Exit;
  FMaster := V;
  C := MakeCommand(ckSetMasterVolume);
  C.Value := V;
  Send(C);
  ScheduleSave;
  Notify([ccState]);
end;

procedure TCalmService.SetMuted(Value: Boolean);
var
  C: TCalmCommand;
begin
  if FMuted = Value then
    Exit;
  FMuted := Value;
  C := MakeCommand(ckSetMuted);
  C.Flag := Value;
  Send(C);
  ScheduleSave;
  Notify([ccState]);
end;

procedure TCalmService.ToggleMute;
begin
  SetMuted(not FMuted);
end;

procedure TCalmService.Play;
begin
  FPausedByFocus := False;
  if not FPaused then
    Exit;
  FPaused := False;
  Send(MakeCommand(ckPlayAll));
  Notify([ccState]);
end;

procedure TCalmService.Pause;
begin
  if FPaused then
    Exit;
  FPaused := True;
  Send(MakeCommand(ckPauseAll));
  Notify([ccState]);
end;

procedure TCalmService.TogglePlayPause;
begin
  if FPaused then
  begin
    if FMix.ActiveCount > 0 then
      Play;
  end
  else
    Pause;
end;

procedure TCalmService.StopAll;
var
  S: TSoundId;
  C: TCalmCommand;
begin
  for S := Low(TSoundId) to High(TSoundId) do
    FMix.Active[S] := False;
  C := MakeCommand(ckStopAll);
  C.DurationMs := 250;
  Send(C);
  ScheduleSave;
  Notify([ccState]);
end;

function TCalmService.CurrentMix: TMix;
begin
  Result := FMix;
end;

function TCalmService.HasActiveSounds: Boolean;
begin
  Result := FMix.ActiveCount > 0;
end;

function TCalmService.Presets: TFavorites;
begin
  Result := BuiltInPresets + FSettings.Favorites;
end;

procedure TCalmService.ApplyPreset(const Preset: TFavorite);
var
  C: TCalmCommand;
  S: TSoundId;
  Mix: TMix;
  Id: string;
begin
  Mix := FMix;
  for S := Low(TSoundId) to High(TSoundId) do
  begin
    Mix.Active[S] := Preset.Mix.Active[S] and (FSnapshot.TrackStates[S] <> tsUnavailable);
    if Preset.Mix.Active[S] then
      Mix.Volumes[S] := Preset.Mix.Volumes[S];
  end;
  FMix := Mix;
  C := MakeCommand(ckApplyPreset);
  C.Mix := Mix;
  C.DurationMs := FSettings.Audio.PresetCrossfadeMs;
  if Preset.MasterPolicy = mpUseSaved then
  begin
    C.HasMaster := True;
    C.Value := Preset.MasterVolume;
    FMaster := Preset.MasterVolume;
  end;
  Send(C);
  if FPaused and (Mix.ActiveCount > 0) then
    Play;
  Id := Preset.Id;
  Persist(procedure(var S: TCalmSettings) begin S.General.LastPresetId := Id; end, []);
  ScheduleSave;
  Notify([ccState]);
end;

function TCalmService.MatchingPresetId: string;
var
  F: TFavorite;
begin
  if FMix.ActiveCount = 0 then
    Exit('');
  // Prefer the last applied preset when several match.
  for F in Presets do
    if (F.Id = FSettings.General.LastPresetId) and F.Mix.SameAs(FMix) then
      Exit(F.Id);
  for F in Presets do
    if F.Mix.SameAs(FMix) then
      Exit(F.Id);
  Result := '';
end;

function TCalmService.SaveCurrentAsFavorite(const AName: string): string;
var
  NewId, Name: string;
  Master: Single;
  Mix: TMix;
  N: Integer;
begin
  NewId := NewFavoriteId;
  Name := Trim(AName);
  if Name = '' then
  begin
    N := Length(FSettings.Favorites) + 1;
    Name := Format('My mix %d', [N]);
  end;
  Mix := FMix;
  Master := FMaster;
  Persist(
    procedure(var S: TCalmSettings)
    var
      F: TFavorite;
    begin
      F := Default(TFavorite);
      F.Id := NewId;
      F.Name := Name;
      F.Mix := Mix;
      F.MasterPolicy := mpKeepCurrent;
      F.MasterVolume := Master;
      F.Accent := apIde;
      F.CreatedUtc := TTimeZone.Local.ToUniversalTime(Now);
      F.ModifiedUtc := F.CreatedUtc;
      S.Favorites := S.Favorites + [F];
      S.General.LastPresetId := NewId;
    end, [ccFavorites]);
  Result := NewId;
end;

procedure TCalmService.RenameFavorite(const Id, NewName: string);
var
  Name: string;
begin
  Name := Trim(NewName);
  if Name = '' then
    Exit;
  Persist(
    procedure(var S: TCalmSettings)
    var
      I: Integer;
    begin
      I := S.FavoriteIndex(Id);
      if I >= 0 then
      begin
        S.Favorites[I].Name := Name;
        S.Favorites[I].ModifiedUtc := TTimeZone.Local.ToUniversalTime(Now);
      end;
    end, [ccFavorites]);
end;

procedure TCalmService.UpdateFavoriteFromCurrent(const Id: string);
var
  Mix: TMix;
  Master: Single;
begin
  Mix := FMix;
  Master := FMaster;
  Persist(
    procedure(var S: TCalmSettings)
    var
      I: Integer;
    begin
      I := S.FavoriteIndex(Id);
      if I >= 0 then
      begin
        S.Favorites[I].Mix := Mix;
        S.Favorites[I].MasterVolume := Master;
        S.Favorites[I].ModifiedUtc := TTimeZone.Local.ToUniversalTime(Now);
      end;
    end, [ccFavorites]);
end;

procedure TCalmService.DeleteFavorite(const Id: string);
begin
  Persist(
    procedure(var S: TCalmSettings)
    var
      I: Integer;
    begin
      I := S.FavoriteIndex(Id);
      if I >= 0 then
        Delete(S.Favorites, I, 1);
      if S.General.LastPresetId = Id then
        S.General.LastPresetId := '';
      if S.Timer.FocusPresetId = Id then
        S.Timer.FocusPresetId := '';
      if S.Timer.BreakPresetId = Id then
        S.Timer.BreakPresetId := '';
    end, [ccFavorites]);
end;

function TCalmService.DuplicateFavorite(const Id: string): string;
var
  Source: TFavorite;
  NewId: string;
begin
  Result := '';
  if not FindPreset(FSettings, Id, Source) then
    Exit;
  NewId := NewFavoriteId;
  Persist(
    procedure(var S: TCalmSettings)
    var
      F: TFavorite;
    begin
      F := Source;
      F.Id := NewId;
      F.BuiltIn := False;
      F.Name := Source.Name + ' (copy)';
      F.CreatedUtc := TTimeZone.Local.ToUniversalTime(Now);
      F.ModifiedUtc := F.CreatedUtc;
      S.Favorites := S.Favorites + [F];
    end, [ccFavorites]);
  Result := NewId;
end;

function TCalmService.TimerOptions: TTimerOptions;
begin
  Result.Completion := FSettings.Timer.Completion;
  Result.FadeOutSec := FSettings.Timer.FadeOutSec;
  Result.Chime := FSettings.Timer.Chime;
  Result.Notify := FSettings.Timer.Notify;
end;

function TCalmService.MixForPreset(const Id: string; out Mix: TMix): Boolean;
var
  F: TFavorite;
begin
  Result := (Id <> '') and FindPreset(FSettings, Id, F);
  if Result then
    Mix := F.Mix;
end;

procedure TCalmService.StartCountdown(Seconds: Integer);
var
  C: TCalmCommand;
  Sec: Integer;
begin
  if not ValidTimerDuration(Seconds) then
    Exit;
  C := MakeCommand(ckStartTimer);
  C.Seconds := Seconds;
  C.TimerOptions := TimerOptions;
  Send(C);
  Sec := Seconds;
  Persist(
    procedure(var S: TCalmSettings)
    begin
      S.Timer.CountdownSec := Sec;
      S.Timer.Mode := tmCountdown;
    end, []);
end;

procedure TCalmService.StartPomodoro;
var
  C: TCalmCommand;
begin
  C := MakeCommand(ckStartPomodoro);
  C.Pomodoro := FSettings.Timer.Pomodoro;
  C.TimerOptions := TimerOptions;
  // Pomodoro phase changes never stop the sounds; they only switch mixes.
  C.TimerOptions.Completion := tcaKeepPlaying;
  C.HasFocusMix := MixForPreset(FSettings.Timer.FocusPresetId, C.FocusMix);
  C.HasBreakMix := MixForPreset(FSettings.Timer.BreakPresetId, C.BreakMix);
  Send(C);
  if C.HasFocusMix and FPaused then
    Play;
  Persist(procedure(var S: TCalmSettings) begin S.Timer.Mode := tmPomodoro; end, []);
end;

procedure TCalmService.PauseTimer;
begin
  Send(MakeCommand(ckPauseTimer));
end;

procedure TCalmService.ResumeTimer;
begin
  Send(MakeCommand(ckResumeTimer));
end;

procedure TCalmService.CancelTimer;
begin
  Send(MakeCommand(ckCancelTimer));
end;

procedure TCalmService.ResetTimer;
begin
  Send(MakeCommand(ckResetTimer));
end;

procedure TCalmService.StartNextPhase;
begin
  Send(MakeCommand(ckStartNextPhase));
end;

procedure TCalmService.PreviewChime;
begin
  Send(MakeCommand(ckPlayChime));
end;

procedure TCalmService.UpdateSettings(const Mutator: TSettingsMutator);
begin
  Persist(Mutator, [ccSettings]);
  SendFades;
end;

procedure TCalmService.ReloadSettings;
begin
  FStore.Load(FSettings);
  Notify([ccSettings, ccFavorites]);
end;

procedure TCalmService.SetIdeFocused(Focused: Boolean);
var
  C: TCalmCommand;
begin
  if FIdeFocused = Focused then
    Exit;
  FIdeFocused := Focused;
  case FSettings.Audio.FocusLoss of
    flMute:
      begin
        C := MakeCommand(ckSetDucked);
        C.Flag := not Focused;
        Send(C);
      end;
    flPause:
      if not Focused and not FPaused then
      begin
        Pause;
        FPausedByFocus := True;
      end
      else if Focused and FPausedByFocus then
        Play;
  end;
end;

function TCalmService.WorkerCpuTimeMs: Double;
var
  Creation, ExitT, Kernel, User: TFileTime;
begin
  Result := 0;
  if Assigned(FWorker) and GetThreadTimes(FWorker.Handle, Creation, ExitT, Kernel, User) then
    Result := (Int64(Kernel) + Int64(User)) / 10000;
end;

function TCalmService.SettingsFileName: string;
begin
  Result := FStore.FileName;
end;

function TCalmService.DiagnosticsText: string;
var
  S: TSoundId;
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('Ctrl+Calm diagnostics');
    Lines.Add('Process id: ' + IntToStr(GetCurrentProcessId));
    Lines.Add('Audio: ' + FSnapshot.AudioStatusText);
    Lines.Add(Format('Playing voices: %d, buffered audio: %d KB, glitches: %d',
      [FSnapshot.PlayingCount, FSnapshot.BufferedBytes div 1024, FSnapshot.Glitches]));
    Lines.Add(Format('Worker CPU time: %.0f ms, wakes: %d, commands: %d',
      [WorkerCpuTimeMs, FSnapshot.WakeCount, FSnapshot.CommandsProcessed]));
    Lines.Add('Sounds folder: ' + FSoundsFolder);
    Lines.Add('Settings file: ' + FStore.FileName);
    if FLastPersistError <> '' then
      Lines.Add('Settings: ' + FLastPersistError);
    for S := Low(TSoundId) to High(TSoundId) do
      if FSnapshot.TrackErrors[S] <> '' then
        Lines.Add(SoundDef(S).Name + ': ' + FSnapshot.TrackErrors[S]);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

end.
