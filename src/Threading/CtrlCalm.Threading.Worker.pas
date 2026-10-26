unit CtrlCalm.Threading.Worker;

{
  The dedicated Ctrl+Calm worker thread. Exactly one exists per IDE process
  (owned by TCalmService). It owns the audio engine and the focus timer, and is
  the only thread that touches either.

  Communication:
  - UI -> worker: Post() appends a TCalmCommand to a lock-protected queue and
    signals the wake event. Volume commands for the same target are coalesced
    in place so dragging a slider cannot flood the queue.
  - Worker -> UI: after any change the worker publishes an immutable
    TCalmSnapshot under a lock and invokes OnChanged (from the worker thread).
    The service turns that into a coalesced PostMessage to the main thread.
  - The worker waits on a single auto-reset event with a computed timeout:
    INFINITE when idle, ~15 ms only while a fade is in progress.
}

interface

uses
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections,
  CtrlCalm.Core.Types, CtrlCalm.Audio.Engine, CtrlCalm.Timer;

type
  TCalmCommandKind = (
    ckActivateSound, ckDeactivateSound, ckSetSoundVolume, ckSetMasterVolume,
    ckSetMuted, ckSetDucked, ckPlayAll, ckPauseAll, ckResumeAll, ckStopAll,
    ckApplyPreset, ckSetFades,
    ckStartTimer, ckStartPomodoro, ckPauseTimer, ckResumeTimer, ckCancelTimer,
    ckResetTimer, ckStartNextPhase, ckPlayChime, ckShutdown);

  TTimerOptions = record
    Completion: TTimerCompletionAction;
    FadeOutSec: Integer;
    Chime: Boolean;
    Notify: Boolean;
  end;

  TCalmCommand = record
    Kind: TCalmCommandKind;
    Seq: Int64;
    Sound: TSoundId;
    Value: Single;
    Flag: Boolean;
    Mix: TMix;
    HasMaster: Boolean;
    DurationMs: Integer;     // fades, crossfades
    Seconds: Integer;        // countdown length
    TimerOptions: TTimerOptions;
    Pomodoro: TPomodoroConfig;
    HasFocusMix, HasBreakMix: Boolean;
    FocusMix, BreakMix: TMix;
    FadeInMs, FadeOutMs: Integer;
  end;

  TCalmSnapshot = record
    Version: Int64;
    ProcessedSeq: Int64;
    // logical mix
    Active: TSoundFlags;
    Volumes: TSoundVolumes;
    MasterVolume: Single;
    Muted: Boolean;
    Paused: Boolean;
    // engine
    TrackStates: array[TSoundId] of TTrackState;
    TrackErrors: array[TSoundId] of string;
    AudioStatus: TAudioStatus;
    AudioStatusText: string;
    PlayingCount: Integer;
    Glitches: Cardinal;
    BufferedBytes: Int64;
    // timer
    Timer: TTimerSnapshot;
    TimerTakenTick: UInt64;
    TimerOptions: TTimerOptions;
    TimerEventSeq: Integer;
    TimerEvent: TTimerEvent;
    // diagnostics
    CommandsProcessed: Int64;
    WakeCount: Int64;
    function TimerRemainingNow: Int64;
  end;

  TCalmWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FQueue: TList<TCalmCommand>;
    FWake: TEvent;
    FAccepting: Boolean;
    FSeq: Int64;
    FSnapshot: TCalmSnapshot;
    FSnapLock: TCriticalSection;
    FOnChanged: TProc;
    FSoundsFolder: string;
    FAllowDevice: Boolean;
    FCommandLog: TList<TCalmCommandKind>;
    FLogCommands: Boolean;
    // worker-thread state
    FEngine: TAudioEngine;
    FTimer: TFocusTimer;
    FState: TCalmSnapshot;
    FFadeInMs, FFadeOutMs: Integer;
    FTimerOptions: TTimerOptions;
    FHasFocusMix, FHasBreakMix: Boolean;
    FFocusMix, FBreakMix: TMix;
    FDirty: Boolean;
    procedure Execute_Command(const C: TCalmCommand);
    procedure ApplyMix(const Mix: TMix; CrossfadeMs: Integer);
    procedure HandleTimerEvent(const E: TTimerEvent);
    procedure Publish;
    function Drain: TArray<TCalmCommand>;
    procedure RefreshEngineState;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASoundsFolder: string; AAllowDevice: Boolean = True);
    destructor Destroy; override;

    /// <summary>Thread-safe. Returns the command sequence number, or -1 if the
    /// worker no longer accepts commands (shutting down).</summary>
    function Post(const C: TCalmCommand): Int64;
    /// <summary>Thread-safe copy of the latest published state.</summary>
    function Snapshot: TCalmSnapshot;
    /// <summary>Stops accepting commands, asks the worker to shut the engine
    /// down in order, and waits for the thread to finish.</summary>
    procedure Shutdown;
    function QueueLength: Integer;
    function CommandLog: TArray<TCalmCommandKind>;

    property OnChanged: TProc read FOnChanged write FOnChanged;
    property LogCommands: Boolean read FLogCommands write FLogCommands;
  end;

function MakeCommand(Kind: TCalmCommandKind): TCalmCommand;

implementation

uses
  System.Math;

function MakeCommand(Kind: TCalmCommandKind): TCalmCommand;
begin
  Result := Default(TCalmCommand);
  Result.Kind := Kind;
end;

{ TCalmSnapshot }

function TCalmSnapshot.TimerRemainingNow: Int64;
begin
  Result := Timer.RemainingMs;
  if Timer.State = trsRunning then
    Result := Max(Int64(0), Result - Int64(GetTickCount64 - TimerTakenTick));
end;

{ TCalmWorker }

constructor TCalmWorker.Create(const ASoundsFolder: string; AAllowDevice: Boolean);
var
  S: TSoundId;
begin
  FLock := TCriticalSection.Create;
  FSnapLock := TCriticalSection.Create;
  FQueue := TList<TCalmCommand>.Create;
  FCommandLog := TList<TCalmCommandKind>.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSoundsFolder := ASoundsFolder;
  FAllowDevice := AAllowDevice;
  FAccepting := True;
  FFadeInMs := 1500;
  FFadeOutMs := 1000;
  FState := Default(TCalmSnapshot);
  FState.MasterVolume := DefaultMasterVolume;
  FState.Paused := True; // nothing plays until the user asks
  for S := Low(TSoundId) to High(TSoundId) do
    FState.Volumes[S] := DefaultSoundVolume;
  FSnapshot := FState;
  inherited Create(False);
  NameThreadForDebugging('Ctrl+Calm worker');
end;

destructor TCalmWorker.Destroy;
begin
  Shutdown;
  inherited; // TThread.Destroy waits for Execute to return
  FWake.Free;
  FCommandLog.Free;
  FQueue.Free;
  FSnapLock.Free;
  FLock.Free;
end;

function TCalmWorker.Post(const C: TCalmCommand): Int64;
var
  I: Integer;
  Item: TCalmCommand;
  Coalesced: Boolean;
begin
  FLock.Enter;
  try
    if not FAccepting then
      Exit(-1);
    Inc(FSeq);
    Result := FSeq;
    Coalesced := False;
    if C.Kind in [ckSetSoundVolume, ckSetMasterVolume] then
      for I := FQueue.Count - 1 downto 0 do
      begin
        Item := FQueue[I];
        if (Item.Kind = C.Kind) and ((C.Kind = ckSetMasterVolume) or (Item.Sound = C.Sound)) then
        begin
          Item.Value := C.Value;
          Item.Seq := Result;
          FQueue[I] := Item;
          Coalesced := True;
          Break;
        end;
      end;
    if not Coalesced then
    begin
      Item := C;
      Item.Seq := Result;
      FQueue.Add(Item);
    end;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

function TCalmWorker.Drain: TArray<TCalmCommand>;
begin
  FLock.Enter;
  try
    Result := FQueue.ToArray;
    FQueue.Clear;
  finally
    FLock.Leave;
  end;
end;

function TCalmWorker.QueueLength: Integer;
begin
  FLock.Enter;
  try
    Result := FQueue.Count;
  finally
    FLock.Leave;
  end;
end;

function TCalmWorker.CommandLog: TArray<TCalmCommandKind>;
begin
  FLock.Enter;
  try
    Result := FCommandLog.ToArray;
  finally
    FLock.Leave;
  end;
end;

function TCalmWorker.Snapshot: TCalmSnapshot;
begin
  FSnapLock.Enter;
  try
    Result := FSnapshot;
  finally
    FSnapLock.Leave;
  end;
end;

procedure TCalmWorker.Shutdown;
var
  C: TCalmCommand;
begin
  FLock.Enter;
  try
    if not FAccepting then
      Exit;
    // 1. Stop accepting commands; the Shutdown command is the last one queued.
    FAccepting := False;
    Inc(FSeq);
    C := MakeCommand(ckShutdown);
    C.Seq := FSeq;
    FQueue.Add(C);
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
  if not Finished then
    WaitFor;
end;

procedure TCalmWorker.ApplyMix(const Mix: TMix; CrossfadeMs: Integer);
var
  S: TSoundId;
begin
  // Tracks already playing glide to their new level; tracks leaving the mix
  // fade out; new tracks fade in. Nothing that stays in the mix restarts.
  for S := Low(TSoundId) to High(TSoundId) do
  begin
    FState.Volumes[S] := ClampVolume(Mix.Volumes[S]);
    if Mix.Active[S] then
    begin
      if FState.Active[S] then
        FEngine.SetVolume(S, FState.Volumes[S], CrossfadeMs)
      else
        FEngine.Activate(S, FState.Volumes[S], CrossfadeMs);
      FState.Active[S] := True;
    end
    else if FState.Active[S] then
    begin
      FEngine.Deactivate(S, CrossfadeMs);
      FState.Active[S] := False;
    end;
  end;
end;

procedure TCalmWorker.HandleTimerEvent(const E: TTimerEvent);
begin
  case E.Kind of
    tekCountdownCompleted:
      case FTimerOptions.Completion of
        tcaStopSounds:
          begin
            FEngine.SetPaused(True, 250);
            FState.Paused := True;
          end;
        tcaFadeOut:
          begin
            FEngine.SetPaused(True, Max(1, FTimerOptions.FadeOutSec) * 1000);
            FState.Paused := True;
          end;
        tcaKeepPlaying: ;
      end;
    tekPhaseCompleted:
      if E.NextPhase = ppFocus then
      begin
        if FHasFocusMix then
          ApplyMix(FFocusMix, 3000);
      end
      else if FHasBreakMix then
        ApplyMix(FBreakMix, 3000);
  end;
  if FTimerOptions.Chime then
    FEngine.PlayChime;
  Inc(FState.TimerEventSeq);
  FState.TimerEvent := E;
end;

procedure TCalmWorker.Execute_Command(const C: TCalmCommand);
var
  S: TSoundId;
begin
  case C.Kind of
    ckActivateSound:
      begin
        FState.Volumes[C.Sound] := ClampVolume(C.Value);
        FState.Active[C.Sound] := True;
        FEngine.Activate(C.Sound, FState.Volumes[C.Sound], FFadeInMs);
      end;
    ckDeactivateSound:
      begin
        FState.Active[C.Sound] := False;
        FEngine.Deactivate(C.Sound, FFadeOutMs);
      end;
    ckSetSoundVolume:
      begin
        FState.Volumes[C.Sound] := ClampVolume(C.Value);
        FEngine.SetVolume(C.Sound, FState.Volumes[C.Sound]);
      end;
    ckSetMasterVolume:
      begin
        FState.MasterVolume := ClampVolume(C.Value);
        FEngine.SetMasterVolume(FState.MasterVolume);
      end;
    ckSetMuted:
      begin
        FState.Muted := C.Flag;
        FEngine.SetMuted(C.Flag);
      end;
    ckSetDucked:
      FEngine.SetDucked(C.Flag);
    ckPlayAll, ckResumeAll:
      begin
        FState.Paused := False;
        FEngine.SetPaused(False, FFadeInMs);
      end;
    ckPauseAll:
      begin
        FState.Paused := True;
        FEngine.SetPaused(True, FFadeOutMs);
      end;
    ckStopAll:
      begin
        for S := Low(TSoundId) to High(TSoundId) do
          FState.Active[S] := False;
        FEngine.StopAll(Max(C.DurationMs, 60));
      end;
    ckApplyPreset:
      begin
        if C.HasMaster then
        begin
          FState.MasterVolume := ClampVolume(C.Value);
          FEngine.SetMasterVolume(FState.MasterVolume, C.DurationMs);
        end;
        ApplyMix(C.Mix, C.DurationMs);
      end;
    ckSetFades:
      begin
        FFadeInMs := EnsureRange(C.FadeInMs, 0, 10000);
        FFadeOutMs := EnsureRange(C.FadeOutMs, 0, 10000);
      end;
    ckStartTimer:
      begin
        FTimerOptions := C.TimerOptions;
        FHasFocusMix := False;
        FHasBreakMix := False;
        if ValidTimerDuration(C.Seconds) then
          FTimer.StartCountdown(C.Seconds);
      end;
    ckStartPomodoro:
      begin
        FTimerOptions := C.TimerOptions;
        FHasFocusMix := C.HasFocusMix;
        FHasBreakMix := C.HasBreakMix;
        FFocusMix := C.FocusMix;
        FBreakMix := C.BreakMix;
        FTimer.StartPomodoro(C.Pomodoro);
        if FHasFocusMix then
          ApplyMix(FFocusMix, 2000);
      end;
    ckPauseTimer:
      FTimer.Pause;
    ckResumeTimer:
      FTimer.Resume;
    ckCancelTimer:
      FTimer.Cancel;
    ckResetTimer:
      FTimer.Reset;
    ckStartNextPhase:
      begin
        FTimer.StartNextPhase;
        if FTimer.Phase = ppFocus then
        begin
          if FHasFocusMix then
            ApplyMix(FFocusMix, 2000);
        end
        else if FHasBreakMix then
          ApplyMix(FBreakMix, 2000);
      end;
    ckPlayChime:
      FEngine.PlayChime;
    ckShutdown:
      Terminate;
  end;
end;

procedure TCalmWorker.RefreshEngineState;
var
  S: TSoundId;
  St: TEngineStats;
  NewState: TTrackState;
  Timer: TTimerSnapshot;
begin
  for S := Low(TSoundId) to High(TSoundId) do
  begin
    NewState := FEngine.TrackState(S);
    if NewState <> FState.TrackStates[S] then
    begin
      FState.TrackStates[S] := NewState;
      FDirty := True;
    end;
    if FState.TrackErrors[S] <> FEngine.TrackError(S) then
    begin
      FState.TrackErrors[S] := FEngine.TrackError(S);
      FDirty := True;
    end;
    // An unavailable sound cannot stay logically active.
    if (NewState = tsUnavailable) and FState.Active[S] then
    begin
      FState.Active[S] := False;
      FDirty := True;
    end;
  end;
  St := FEngine.Stats;
  if (St.Status <> FState.AudioStatus) or (St.StatusText <> FState.AudioStatusText) or
     (St.PlayingCount <> FState.PlayingCount) then
    FDirty := True;
  FState.AudioStatus := St.Status;
  FState.AudioStatusText := St.StatusText;
  FState.PlayingCount := St.PlayingCount;
  FState.Glitches := St.Glitches;
  FState.BufferedBytes := St.BufferedBytes;
  Timer := FTimer.Snapshot;
  if (Timer.State <> FState.Timer.State) or (Timer.Mode <> FState.Timer.Mode) or
     (Timer.Phase <> FState.Timer.Phase) or (Timer.DurationMs <> FState.Timer.DurationMs) then
    FDirty := True;
  FState.Timer := Timer;
  FState.TimerTakenTick := GetTickCount64;
  FState.TimerOptions := FTimerOptions;
end;

procedure TCalmWorker.Publish;
var
  Notify: TProc;
begin
  FSnapLock.Enter;
  try
    Inc(FState.Version);
    FSnapshot := FState;
  finally
    FSnapLock.Leave;
  end;
  FDirty := False;
  Notify := FOnChanged;
  if Assigned(Notify) then
    try
      Notify();
    except
      // never let a notification failure take down the worker
    end;
end;

procedure TCalmWorker.Execute;
var
  Commands: TArray<TCalmCommand>;
  C: TCalmCommand;
  Wait, TimerWait: Cardinal;
  E: TTimerEvent;
  ComInit: HRESULT;
begin
  ComInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    try
      FEngine := TAudioEngine.Create(FWake.Handle, FSoundsFolder);
      if not FAllowDevice then
        FEngine.DisableDevice;
      FEngine.SetPaused(True, 0);
      FEngine.ProbeSources;
      FTimer := TFocusTimer.Create;
      RefreshEngineState;
      Publish;
      while not Terminated do
      begin
        Commands := Drain;
        for C in Commands do
        begin
          try
            Execute_Command(C);
          except
            // a failing command must not stop the worker; state stays consistent
          end;
          FState.ProcessedSeq := Max(FState.ProcessedSeq, C.Seq); // coalescing reorders seqs
          Inc(FState.CommandsProcessed);
          FDirty := True;
          if FLogCommands then
          begin
            FLock.Enter;
            try
              FCommandLog.Add(C.Kind);
            finally
              FLock.Leave;
            end;
          end;
          if Terminated then
            Break;
        end;
        if Terminated then
          Break;

        Wait := FEngine.Process;
        E := FTimer.Poll;
        if E.Kind <> tekNone then
        begin
          HandleTimerEvent(E);
          FDirty := True;
          Wait := Min(Wait, Cardinal(EngineTickMs)); // let the fade start immediately
        end;
        TimerWait := FTimer.MsUntilDue;
        Wait := Min(Wait, TimerWait);
        RefreshEngineState;
        if FDirty then
          Publish;
        Inc(FState.WakeCount);
        FWake.WaitFor(Wait);
      end;
    except
      // last-resort guard: the worker must never raise into the IDE process
    end;
  finally
    // Ordered shutdown: cancel the timer, stop voices, destroy voices,
    // mastering voice and engine (TAudioEngine.Shutdown), then leave COM.
    try
      if Assigned(FTimer) then
        FTimer.Cancel;
      if Assigned(FEngine) then
        FEngine.Shutdown;
      if Assigned(FEngine) then
        RefreshEngineState;
      FState.Paused := True;
      Publish;
    except
    end;
    FreeAndNil(FTimer);
    FreeAndNil(FEngine);
    if Succeeded(ComInit) then
      CoUninitialize;
  end;
end;

end.
