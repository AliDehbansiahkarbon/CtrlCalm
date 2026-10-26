unit CtrlCalm.Tests.Timer;

interface

implementation

uses
  System.SysUtils, CtrlCalm.TestFramework, CtrlCalm.Core.Types, CtrlCalm.Timer;

type
  TFakeClock = class
    Now: UInt64;
    function Func: TClockFunc;
  end;

function TFakeClock.Func: TClockFunc;
begin
  Result := function: UInt64 begin Result := Now; end;
end;

procedure WithTimer(const Body: TProc<TFocusTimer, TFakeClock>);
var
  C: TFakeClock;
  T: TFocusTimer;
begin
  C := TFakeClock.Create;
  C.Now := 1000000;
  T := TFocusTimer.Create(C.Func());
  try
    Body(T, C);
  finally
    T.Free;
    C.Free;
  end;
end;

procedure Register;
begin
  RegisterTest('Timer', 'StartPauseResumeExpire',
    procedure
    begin
      WithTimer(
        procedure(T: TFocusTimer; C: TFakeClock)
        var
          E: TTimerEvent;
        begin
          T.StartCountdown(10);
          Check(T.State = trsRunning);
          CheckEquals(10000, T.RemainingMs);
          Inc(C.Now, 1000);
          CheckEquals(9000, T.RemainingMs);
          T.Pause;
          Inc(C.Now, 60000); // paused time does not count
          CheckEquals(9000, T.RemainingMs, 'paused');
          Check(T.MsUntilDue = Cardinal(-1), 'no wake-up while paused');
          T.Resume;
          CheckEquals(9000, T.MsUntilDue);
          Inc(C.Now, 8999);
          Check(T.Poll.Kind = tekNone, 'one ms early');
          Inc(C.Now, 1);
          E := T.Poll;
          Check(E.Kind = tekCountdownCompleted, 'expired');
          Check(T.State = trsCompleted);
          CheckEquals(0, T.RemainingMs);
          Check(T.Poll.Kind = tekNone, 'event fires once');
        end);
    end);

  RegisterTest('Timer', 'ZeroAndOutOfRangeDurationsRejected',
    procedure
    begin
      WithTimer(
        procedure(T: TFocusTimer; C: TFakeClock)
        begin
          CheckRaises(procedure begin T.StartCountdown(0); end, ETimerError, 'zero');
          CheckRaises(procedure begin T.StartCountdown(-5); end, ETimerError, 'negative');
          CheckRaises(procedure begin T.StartCountdown(TimerMaxSec + 1); end, ETimerError, 'too long');
          Check(T.State = trsIdle, 'state unchanged after rejection');
          Check(not ValidTimerDuration(0));
          Check(ValidTimerDuration(1));
          Check(ValidTimerDuration(TimerMaxSec));
        end);
    end);

  RegisterTest('Timer', 'LongDurationDoesNotDrift',
    procedure
    begin
      WithTimer(
        procedure(T: TFocusTimer; C: TFakeClock)
        var
          I: Integer;
        begin
          T.StartCountdown(TimerMaxSec);
          // Thousands of irregular polls (as from a busy worker) must not
          // change the result: remaining is always derived from the clock.
          for I := 1 to 5000 do
          begin
            Inc(C.Now, 17 + I mod 13);
            T.Poll;
          end;
          CheckEquals(Int64(TimerMaxSec) * 1000 - Int64(C.Now - 1000000), T.RemainingMs);
          Inc(C.Now, UInt64(TimerMaxSec) * 1000);
          Check(T.Poll.Kind = tekCountdownCompleted);
        end);
    end);

  RegisterTest('Timer', 'CancelAndReset',
    procedure
    begin
      WithTimer(
        procedure(T: TFocusTimer; C: TFakeClock)
        begin
          T.StartCountdown(60);
          Inc(C.Now, 30000);
          T.Reset;
          CheckEquals(60000, T.RemainingMs, 'reset restarts the full duration');
          Check(T.State = trsRunning, 'reset keeps running');
          T.Pause;
          Inc(C.Now, 5000);
          T.Reset;
          Check(T.State = trsPaused, 'reset keeps paused');
          CheckEquals(60000, T.RemainingMs);
          T.Cancel;
          Check(T.State = trsIdle);
          Inc(C.Now, 120000);
          Check(T.Poll.Kind = tekNone, 'cancelled timer never fires');
        end);
    end);

  RegisterTest('Timer', 'SleepCountsAndExpiresOnWake',
    procedure
    begin
      WithTimer(
        procedure(T: TFocusTimer; C: TFakeClock)
        begin
          T.StartCountdown(25 * 60);
          // GetTickCount64 includes time spent in sleep: emulate an 8 h sleep.
          Inc(C.Now, UInt64(8) * 3600 * 1000);
          Check(T.Poll.Kind = tekCountdownCompleted, 'completes right after resume');
        end);
    end);

  RegisterTest('Timer', 'PomodoroCycleWithManualStart',
    procedure
    begin
      WithTimer(
        procedure(T: TFocusTimer; C: TFakeClock)
        var
          Cfg: TPomodoroConfig;
          E: TTimerEvent;
          I: Integer;
          Expected: array[0..7] of TPomodoroPhase;
        begin
          Cfg := TPomodoroConfig.Default;
          Cfg.FocusSec := 10;
          Cfg.ShortBreakSec := 2;
          Cfg.LongBreakSec := 5;
          Cfg.LongBreakEvery := 4;
          T.StartPomodoro(Cfg);
          Check(T.Phase = ppFocus);
          Expected[0] := ppShortBreak; Expected[1] := ppFocus;
          Expected[2] := ppShortBreak; Expected[3] := ppFocus;
          Expected[4] := ppShortBreak; Expected[5] := ppFocus;
          Expected[6] := ppLongBreak;  Expected[7] := ppFocus;
          for I := 0 to 7 do
          begin
            Inc(C.Now, UInt64(Cfg.PhaseSeconds(T.Phase)) * 1000);
            E := T.Poll;
            Check(E.Kind = tekPhaseCompleted, 'phase end ' + IntToStr(I));
            Check(E.NextPhase = Expected[I], 'next phase ' + IntToStr(I));
            Check(not E.NextStarted, 'manual start');
            Check(T.State = trsCompleted, 'waiting for start');
            Inc(C.Now, 60000); // waiting does not consume the next phase
            Check(T.Poll.Kind = tekNone);
            T.StartNextPhase;
            Check(T.State = trsRunning);
          end;
          CheckEquals(4, T.CompletedFocusSessions);
        end);
    end);

  RegisterTest('Timer', 'PomodoroAutoStartDoesNotCascadeAfterSleep',
    procedure
    begin
      WithTimer(
        procedure(T: TFocusTimer; C: TFakeClock)
        var
          Cfg: TPomodoroConfig;
          E: TTimerEvent;
        begin
          Cfg := TPomodoroConfig.Default;
          Cfg.AutoStartNext := True;
          T.StartPomodoro(Cfg);
          Inc(C.Now, UInt64(10) * 3600 * 1000);
          E := T.Poll;
          Check(E.Kind = tekPhaseCompleted);
          Check(E.NextStarted);
          Check(T.Phase = ppShortBreak);
          CheckEquals(5 * 60 * 1000, T.RemainingMs, 'next phase starts at wake-up time');
          Check(T.Poll.Kind = tekNone, 'no cascade');
        end);
    end);

  RegisterTest('Timer', 'PomodoroConfigNormalized',
    procedure
    var
      C: TPomodoroConfig;
    begin
      C := TPomodoroConfig.Default;
      C.FocusSec := 0;
      C.LongBreakEvery := 0;
      C := C.Normalized;
      CheckEquals(25 * 60, C.FocusSec);
      CheckEquals(4, C.LongBreakEvery);
    end);

  RegisterTest('Timer', 'FormatDuration',
    procedure
    begin
      CheckEquals('25:00', FormatDuration(25 * 60 * 1000));
      CheckEquals('00:01', FormatDuration(1));
      CheckEquals('00:00', FormatDuration(0));
      CheckEquals('1:00:00', FormatDuration(3600 * 1000));
      CheckEquals('23:59:59', FormatDuration(Int64(TimerMaxSec) * 1000));
      CheckEquals('0:05:00', FormatDuration(300000, True));
    end);
end;

initialization
  Register;

end.
