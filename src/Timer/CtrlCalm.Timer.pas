unit CtrlCalm.Timer;

{
  Countdown and Pomodoro state machine.

  Time is measured with a monotonic millisecond clock (GetTickCount64 by
  default; tests inject their own). Remaining time is always computed as
  Duration - Elapsed, where Elapsed accumulates finished run segments plus the
  current one, so the countdown never drifts with UI or worker scheduling.

  Sleep policy: GetTickCount64 keeps counting while Windows sleeps, so time
  spent in sleep or hibernation counts toward the timer. A timer that expired
  during sleep completes as soon as the worker wakes. Wall-clock adjustments
  (manual changes, DST, NTP) have no effect.

  Not thread-safe: owned by the Ctrl+Calm worker thread.
}

interface

uses
  System.SysUtils, CtrlCalm.Core.Types;

type
  TClockFunc = reference to function: UInt64;

  TTimerEventKind = (tekNone, tekCountdownCompleted, tekPhaseCompleted);

  TTimerEvent = record
    Kind: TTimerEventKind;
    EndedPhase: TPomodoroPhase;   // pomodoro only
    NextPhase: TPomodoroPhase;    // pomodoro only
    NextStarted: Boolean;         // pomodoro auto-start
  end;

  TTimerSnapshot = record
    Mode: TTimerMode;
    State: TTimerRunState;
    Phase: TPomodoroPhase;
    DurationMs: Int64;
    RemainingMs: Int64;
    CompletedFocusSessions: Integer;
    LongBreakEvery: Integer;
  end;

  ETimerError = class(Exception);

  TFocusTimer = class
  private
    FClock: TClockFunc;
    FMode: TTimerMode;
    FState: TTimerRunState;
    FDurationMs: Int64;
    FAccumulatedMs: Int64;
    FSegmentStart: UInt64;
    FPhase: TPomodoroPhase;
    FConfig: TPomodoroConfig;
    FCompletedFocus: Integer;
    function ElapsedMs(Now: UInt64): Int64;
    procedure BeginRun(DurationMs: Int64; Now: UInt64);
    function NextPhaseAfter(Phase: TPomodoroPhase): TPomodoroPhase;
  public
    constructor Create(const AClock: TClockFunc = nil);

    /// <summary>Starts a plain countdown. Raises ETimerError outside
    /// TimerMinSec..TimerMaxSec.</summary>
    procedure StartCountdown(DurationSec: Integer);
    procedure StartPomodoro(const Config: TPomodoroConfig);
    /// <summary>Starts the pending Pomodoro phase after a phase completed with
    /// auto-start disabled.</summary>
    procedure StartNextPhase;
    procedure Pause;
    procedure Resume;
    /// <summary>Stops the timer and returns to idle.</summary>
    procedure Cancel;
    /// <summary>Restarts the current countdown or phase from its full duration,
    /// keeping the running/paused state.</summary>
    procedure Reset;

    /// <summary>Checks for expiry. Must be called whenever the clock may have
    /// passed the deadline; returns at most one event per call.</summary>
    function Poll: TTimerEvent;
    /// <summary>Milliseconds until Poll can next produce an event, or
    /// Cardinal.MaxValue (INFINITE) when not running.</summary>
    function MsUntilDue: Cardinal;
    function RemainingMs: Int64;
    function Snapshot: TTimerSnapshot;

    property Mode: TTimerMode read FMode;
    property State: TTimerRunState read FState;
    property Phase: TPomodoroPhase read FPhase;
    property DurationMs: Int64 read FDurationMs;
    property CompletedFocusSessions: Integer read FCompletedFocus;
  end;

function FormatDuration(Ms: Int64; ForceHours: Boolean = False): string;

implementation

uses
  Winapi.Windows, System.Math;

function FormatDuration(Ms: Int64; ForceHours: Boolean): string;
var
  Total, H, M, S: Int64;
begin
  if Ms < 0 then
    Ms := 0;
  Total := (Ms + 999) div 1000; // show 00:01 until the last millisecond
  H := Total div 3600;
  M := (Total mod 3600) div 60;
  S := Total mod 60;
  if (H > 0) or ForceHours then
    Result := Format('%d:%.2d:%.2d', [H, M, S])
  else
    Result := Format('%.2d:%.2d', [M, S]);
end;

{ TFocusTimer }

constructor TFocusTimer.Create(const AClock: TClockFunc);
begin
  inherited Create;
  if Assigned(AClock) then
    FClock := AClock
  else
    FClock := function: UInt64 begin Result := GetTickCount64; end;
  FConfig := TPomodoroConfig.Default;
  FState := trsIdle;
end;

function TFocusTimer.ElapsedMs(Now: UInt64): Int64;
begin
  Result := FAccumulatedMs;
  if FState = trsRunning then
    Inc(Result, Int64(Now - FSegmentStart));
end;

procedure TFocusTimer.BeginRun(DurationMs: Int64; Now: UInt64);
begin
  FDurationMs := DurationMs;
  FAccumulatedMs := 0;
  FSegmentStart := Now;
  FState := trsRunning;
end;

function TFocusTimer.NextPhaseAfter(Phase: TPomodoroPhase): TPomodoroPhase;
begin
  if Phase = ppFocus then
  begin
    if (FCompletedFocus > 0) and (FCompletedFocus mod FConfig.LongBreakEvery = 0) then
      Result := ppLongBreak
    else
      Result := ppShortBreak;
  end
  else
    Result := ppFocus;
end;

procedure TFocusTimer.StartCountdown(DurationSec: Integer);
begin
  if not ValidTimerDuration(DurationSec) then
    raise ETimerError.CreateFmt('Timer duration must be between 1 second and 23:59:59 (got %d s)',
      [DurationSec]);
  FMode := tmCountdown;
  BeginRun(Int64(DurationSec) * 1000, FClock());
end;

procedure TFocusTimer.StartPomodoro(const Config: TPomodoroConfig);
begin
  FConfig := Config.Normalized;
  FMode := tmPomodoro;
  FPhase := ppFocus;
  FCompletedFocus := 0;
  BeginRun(Int64(FConfig.FocusSec) * 1000, FClock());
end;

procedure TFocusTimer.StartNextPhase;
begin
  if (FMode = tmPomodoro) and (FState = trsCompleted) then
    BeginRun(Int64(FConfig.PhaseSeconds(FPhase)) * 1000, FClock());
end;

procedure TFocusTimer.Pause;
var
  Now: UInt64;
begin
  if FState <> trsRunning then
    Exit;
  Now := FClock();
  FAccumulatedMs := ElapsedMs(Now);
  FState := trsPaused;
end;

procedure TFocusTimer.Resume;
begin
  if FState <> trsPaused then
    Exit;
  FSegmentStart := FClock();
  FState := trsRunning;
end;

procedure TFocusTimer.Cancel;
begin
  FState := trsIdle;
  FAccumulatedMs := 0;
  if FMode = tmPomodoro then
  begin
    FPhase := ppFocus;
    FCompletedFocus := 0;
  end;
end;

procedure TFocusTimer.Reset;
begin
  if FState in [trsRunning, trsPaused] then
  begin
    FAccumulatedMs := 0;
    FSegmentStart := FClock();
  end;
end;

function TFocusTimer.RemainingMs: Int64;
begin
  case FState of
    trsRunning, trsPaused:
      Result := Max(Int64(0), FDurationMs - ElapsedMs(FClock()));
    trsCompleted:
      if FMode = tmPomodoro then
        Result := Int64(FConfig.PhaseSeconds(FPhase)) * 1000
      else
        Result := 0;
  else
    Result := FDurationMs;
  end;
end;

function TFocusTimer.MsUntilDue: Cardinal;
var
  R: Int64;
begin
  if FState <> trsRunning then
    Exit(INFINITE);
  R := FDurationMs - ElapsedMs(FClock());
  if R <= 0 then
    Result := 0
  else
    Result := Cardinal(Min(R, Int64(MaxInt)));
end;

function TFocusTimer.Poll: TTimerEvent;
var
  Now: UInt64;
  Ended: TPomodoroPhase;
begin
  Result := Default(TTimerEvent);
  if FState <> trsRunning then
    Exit;
  Now := FClock();
  if ElapsedMs(Now) < FDurationMs then
    Exit;

  if FMode = tmCountdown then
  begin
    FAccumulatedMs := FDurationMs;
    FState := trsCompleted;
    Result.Kind := tekCountdownCompleted;
    Exit;
  end;

  Ended := FPhase;
  if Ended = ppFocus then
    Inc(FCompletedFocus);
  FPhase := NextPhaseAfter(Ended);
  Result.Kind := tekPhaseCompleted;
  Result.EndedPhase := Ended;
  Result.NextPhase := FPhase;
  if FConfig.AutoStartNext then
  begin
    // The next phase starts now rather than at the old deadline, so a phase
    // that elapsed during sleep does not cascade through several phases.
    BeginRun(Int64(FConfig.PhaseSeconds(FPhase)) * 1000, Now);
    Result.NextStarted := True;
  end
  else
  begin
    FDurationMs := Int64(FConfig.PhaseSeconds(FPhase)) * 1000;
    FAccumulatedMs := 0;
    FState := trsCompleted;
  end;
end;

function TFocusTimer.Snapshot: TTimerSnapshot;
begin
  Result.Mode := FMode;
  Result.State := FState;
  Result.Phase := FPhase;
  Result.DurationMs := FDurationMs;
  Result.RemainingMs := RemainingMs;
  Result.CompletedFocusSessions := FCompletedFocus;
  Result.LongBreakEvery := FConfig.LongBreakEvery;
end;

end.
