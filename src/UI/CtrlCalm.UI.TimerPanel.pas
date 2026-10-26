unit CtrlCalm.UI.TimerPanel;

{ The focus timer view: countdown and Pomodoro. Timekeeping lives in the
  worker (CtrlCalm.Timer); this panel only displays snapshots and sends
  commands, and its display TTimer runs only while a timer is running. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.Math, System.StrUtils, Vcl.Controls, Vcl.Graphics, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  CtrlCalm.Core.Types, CtrlCalm.Core.Settings, CtrlCalm.Timer, CtrlCalm.Threading.Worker, CtrlCalm.Service,
  CtrlCalm.UI.Theme, CtrlCalm.UI.Icons, CtrlCalm.UI.Controls;

type
  TCalmTimerPanel = class(TCalmControl)
  private
    FService: TCalmService;
    FModeCountdown, FModePomodoro: TCalmChip;
    FPresetChips: array[0..4] of TCalmChip;
    FHours, FMinutes, FSeconds: TEdit;
    FHoursUD, FMinutesUD, FSecondsUD: TUpDown;
    FCompletion: TComboBox;
    FStart, FPauseResume, FReset, FCancel, FNext: TCalmIconButton;
    FTick: TTimer;
    FMode: TTimerMode;
    FUpdating: Boolean;
    FDisplayRect: TRect;
    FStatusRect: TRect;
    FLastDisplay: string;
    FOnHeightChanged: TNotifyEvent;
    function MakeButton(G: TCalmGlyph; const Cap, HintText: string; K: TCalmButtonKind): TCalmIconButton;
    function MakeEdit(Max: Integer; out UD: TUpDown): TEdit;
    procedure ModeClick(Sender: TObject);
    procedure PresetClick(Sender: TObject);
    procedure StartClick(Sender: TObject);
    procedure PauseResumeClick(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure CompletionChange(Sender: TObject);
    procedure EditChange(Sender: TObject);
    procedure TickTimer(Sender: TObject);
    function EnteredSeconds: Integer;
    procedure SetEnteredSeconds(Sec: Integer);
    function DisplayText(out Status: string): string;
    procedure LayoutControls;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure CreateWnd; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
  public
    constructor Create(AOwner: TComponent; AService: TCalmService); reintroduce;
    procedure SetPalette(const P: TCalmPalette); override;
    procedure Refresh;
    function PreferredHeight(AWidth: Integer): Integer;
    function PresetRowsHeight(AWidth: Integer): Integer;
    procedure FocusPrimary;
    /// <summary>Raised when the content changed so that PreferredHeight
    /// differs from the current height (for example a mode switch).</summary>
    property OnHeightChanged: TNotifyEvent read FOnHeightChanged write FOnHeightChanged;
  end;

function TimerStatusText(const Snap: TCalmSnapshot): string;

implementation

function TimerStatusText(const Snap: TCalmSnapshot): string;
begin
  case Snap.Timer.State of
    trsIdle: Result := 'Ready';
    trsRunning:
      if (Snap.Timer.Mode = tmPomodoro) and (Snap.Timer.Phase = ppFocus) then
        Result := Format('Focus - session %d of %d', [
          (Snap.Timer.CompletedFocusSessions mod Max(1, Snap.Timer.LongBreakEvery)) + 1,
          Snap.Timer.LongBreakEvery])
      else if Snap.Timer.Mode = tmPomodoro then
        Result := PhaseName(Snap.Timer.Phase)
      else
        Result := 'Running';
    trsPaused: Result := 'Paused';
  else
    if Snap.Timer.Mode = tmPomodoro then
      Result := 'Up next: ' + PhaseName(Snap.Timer.Phase)
    else
      Result := 'Time is up';
  end;
end;

{ TCalmTimerPanel }

constructor TCalmTimerPanel.Create(AOwner: TComponent; AService: TCalmService);
var
  I: Integer;
begin
  inherited Create(AOwner);
  FService := AService;
  TabStop := False;
  FMode := FService.Settings.Timer.Mode;

  FModeCountdown := TCalmChip.Create(Self);
  FModeCountdown.Parent := Self;
  FModeCountdown.Text := 'Countdown';
  FModeCountdown.Hint := 'Simple countdown timer';
  FModeCountdown.OnClick := ModeClick;
  FModePomodoro := TCalmChip.Create(Self);
  FModePomodoro.Parent := Self;
  FModePomodoro.Text := 'Pomodoro';
  FModePomodoro.Hint := 'Focus and break sessions (configure in Settings)';
  FModePomodoro.OnClick := ModeClick;

  for I := 0 to High(FPresetChips) do
  begin
    FPresetChips[I] := TCalmChip.Create(Self);
    FPresetChips[I].Parent := Self;
    FPresetChips[I].Text := IntToStr(TimerPresetMinutes[I]) + ' min';
    FPresetChips[I].Tag := TimerPresetMinutes[I] * 60;
    FPresetChips[I].Hint := Format('Set the timer to %d minutes', [TimerPresetMinutes[I]]);
    FPresetChips[I].OnClick := PresetClick;
  end;

  FHours := MakeEdit(23, FHoursUD);
  FHours.Hint := 'Hours';
  FMinutes := MakeEdit(59, FMinutesUD);
  FMinutes.Hint := 'Minutes';
  FSeconds := MakeEdit(59, FSecondsUD);
  FSeconds.Hint := 'Seconds';

  FCompletion := TComboBox.Create(Self);
  FCompletion.Parent := Self;
  FCompletion.Style := csDropDownList;
  FCompletion.Hint := 'What happens when the countdown ends';
  FCompletion.ShowHint := True;
  FCompletion.OnChange := CompletionChange;

  FStart := MakeButton(cgPlay, 'Start', 'Start the timer', bkPrimary);
  FStart.OnClick := StartClick;
  FPauseResume := MakeButton(cgPause, 'Pause', 'Pause the timer', bkOutline);
  FPauseResume.OnClick := PauseResumeClick;
  FReset := MakeButton(cgReset, '', 'Restart from the full duration', bkGhost);
  FReset.OnClick := ResetClick;
  FCancel := MakeButton(cgClose, '', 'Cancel the timer', bkGhost);
  FCancel.OnClick := CancelClick;
  FNext := MakeButton(cgPlay, 'Start next', 'Start the next Pomodoro session', bkPrimary);
  FNext.OnClick := NextClick;

  FTick := TTimer.Create(Self);
  FTick.Enabled := False;
  FTick.Interval := 250;
  FTick.OnTimer := TickTimer;

  SetEnteredSeconds(FService.Settings.Timer.CountdownSec);
end;

procedure TCalmTimerPanel.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  // Children have their new PPI only now; measure and place them again.
  if isDpiChange then
    LayoutControls;
end;

procedure TCalmTimerPanel.CreateWnd;
begin
  inherited;
  Refresh;
end;

function TCalmTimerPanel.MakeButton(G: TCalmGlyph; const Cap, HintText: string;
  K: TCalmButtonKind): TCalmIconButton;
begin
  Result := TCalmIconButton.Create(Self);
  Result.Parent := Self;
  Result.Glyph := G;
  Result.CaptionText := Cap;
  Result.Hint := HintText;
  Result.Kind := K;
  Result.GlyphScale := 0.5;
end;

function TCalmTimerPanel.MakeEdit(Max: Integer; out UD: TUpDown): TEdit;
begin
  Result := TEdit.Create(Self);
  Result.Parent := Self;
  Result.NumbersOnly := True;
  Result.MaxLength := 2;
  Result.Alignment := taCenter;
  Result.ShowHint := True;
  Result.OnChange := EditChange;
  UD := TUpDown.Create(Self);
  UD.Parent := Self;
  UD.Associate := Result;
  UD.Min := 0;
  UD.Max := Max;
  UD.Wrap := True;
end;

procedure TCalmTimerPanel.SetPalette(const P: TCalmPalette);
var
  I: Integer;
  C: TControl;
begin
  inherited;
  // Children sit on the panel's surface, not on the window background.
  for I := 0 to ControlCount - 1 do
  begin
    C := Controls[I];
    if C is TCalmControl then
      TCalmControl(C).BackColor := P.Surface;
  end;
  FModeCountdown.SetPalette(P);
  FModePomodoro.SetPalette(P);
  for I := 0 to High(FPresetChips) do
    FPresetChips[I].SetPalette(P);
  FStart.SetPalette(P);
  FPauseResume.SetPalette(P);
  FReset.SetPalette(P);
  FCancel.SetPalette(P);
  FNext.SetPalette(P);
end;

function TCalmTimerPanel.EnteredSeconds: Integer;
begin
  Result := StrToIntDef(FHours.Text, 0) * 3600 + StrToIntDef(FMinutes.Text, 0) * 60 +
    StrToIntDef(FSeconds.Text, 0);
end;

procedure TCalmTimerPanel.SetEnteredSeconds(Sec: Integer);
begin
  FUpdating := True;
  try
    FHoursUD.Position := Sec div 3600;
    FMinutesUD.Position := (Sec mod 3600) div 60;
    FSecondsUD.Position := Sec mod 60;
    FHours.Text := IntToStr(Sec div 3600);
    FMinutes.Text := Format('%.2d', [(Sec mod 3600) div 60]);
    FSeconds.Text := Format('%.2d', [Sec mod 60]);
  finally
    FUpdating := False;
  end;
end;

procedure TCalmTimerPanel.ModeClick(Sender: TObject);
var
  M: TTimerMode;
begin
  if Sender = FModePomodoro then
    M := tmPomodoro
  else
    M := tmCountdown;
  if FService.Snapshot.Timer.State in [trsRunning, trsPaused] then
    Exit; // switching modes would silently discard a running timer
  FMode := M;
  FService.UpdateSettings(procedure(var S: TCalmSettings) begin S.Timer.Mode := M; end);
  Refresh;
end;

procedure TCalmTimerPanel.PresetClick(Sender: TObject);
begin
  SetEnteredSeconds(TCalmChip(Sender).Tag);
  Refresh;
  Invalidate;
end;

procedure TCalmTimerPanel.StartClick(Sender: TObject);
var
  Sec: Integer;
begin
  if FMode = tmPomodoro then
    FService.StartPomodoro
  else
  begin
    Sec := EnteredSeconds;
    if not ValidTimerDuration(Sec) then
    begin
      FLastDisplay := '';
      Invalidate;
      Exit;
    end;
    FService.StartCountdown(Sec);
  end;
end;

procedure TCalmTimerPanel.PauseResumeClick(Sender: TObject);
begin
  if FService.Snapshot.Timer.State = trsPaused then
    FService.ResumeTimer
  else
    FService.PauseTimer;
end;

procedure TCalmTimerPanel.ResetClick(Sender: TObject);
begin
  FService.ResetTimer;
end;

procedure TCalmTimerPanel.CancelClick(Sender: TObject);
begin
  FService.CancelTimer;
end;

procedure TCalmTimerPanel.NextClick(Sender: TObject);
begin
  FService.StartNextPhase;
end;

procedure TCalmTimerPanel.CompletionChange(Sender: TObject);
var
  Idx: Integer;
begin
  if FUpdating then
    Exit;
  Idx := FCompletion.ItemIndex;
  FService.UpdateSettings(
    procedure(var S: TCalmSettings)
    begin
      case Idx of
        0: S.Timer.Completion := tcaStopSounds;
        1: S.Timer.Completion := tcaFadeOut;
        2: S.Timer.Completion := tcaKeepPlaying;
      end;
    end);
end;

procedure TCalmTimerPanel.EditChange(Sender: TObject);
begin
  if not FUpdating then
    Invalidate;
end;

procedure TCalmTimerPanel.TickTimer(Sender: TObject);
var
  Status, Text: string;
begin
  Text := DisplayText(Status);
  if Text <> FLastDisplay then
  begin
    FLastDisplay := Text;
    InvalidateRect(Handle, @FDisplayRect, False);
  end;
end;

function TCalmTimerPanel.DisplayText(out Status: string): string;
var
  Snap: TCalmSnapshot;
  Sec: Integer;
begin
  Snap := FService.Snapshot;
  if (Snap.Timer.State = trsIdle) or (Snap.Timer.Mode <> FMode) and (Snap.Timer.State = trsIdle) then
  begin
    if FMode = tmPomodoro then
      Sec := FService.Settings.Timer.Pomodoro.FocusSec
    else
      Sec := EnteredSeconds;
    if (FMode = tmCountdown) and not ValidTimerDuration(Sec) then
      Status := 'Choose a duration between 0:00:01 and 23:59:59'
    else if FMode = tmPomodoro then
      with FService.Settings.Timer.Pomodoro do
        Status := Format('%d min focus, %d / %d min breaks',
          [FocusSec div 60, ShortBreakSec div 60, LongBreakSec div 60])
    else
      Status := 'Ready';
    Result := FormatDuration(Int64(Sec) * 1000);
  end
  else
  begin
    Result := FormatDuration(Snap.TimerRemainingNow);
    Status := TimerStatusText(Snap);
  end;
end;

procedure TCalmTimerPanel.Refresh;
var
  Snap: TCalmSnapshot;
  Running, Active, Completed, Pomo: Boolean;
  I, Sel: Integer;
  Comp: TTimerCompletionAction;
begin
  if not HandleAllocated then
    Exit; // combo box items need a window; CreateWnd calls Refresh again
  Snap := FService.Snapshot;
  Active := Snap.Timer.State in [trsRunning, trsPaused];
  if Active or (Snap.Timer.State = trsCompleted) then
    FMode := Snap.Timer.Mode;
  Pomo := FMode = tmPomodoro;
  Running := Snap.Timer.State = trsRunning;
  Completed := Snap.Timer.State = trsCompleted;

  FModeCountdown.Selected := not Pomo;
  FModePomodoro.Selected := Pomo;
  FModeCountdown.Enabled := not Active;
  FModePomodoro.Enabled := not Active;

  Sel := EnteredSeconds;
  for I := 0 to High(FPresetChips) do
  begin
    FPresetChips[I].Visible := not Pomo and not Active;
    FPresetChips[I].Selected := FPresetChips[I].Tag = Sel;
  end;
  FHours.Visible := not Pomo and not Active;
  FMinutes.Visible := FHours.Visible;
  FSeconds.Visible := FHours.Visible;
  FHoursUD.Visible := FHours.Visible;
  FMinutesUD.Visible := FHours.Visible;
  FSecondsUD.Visible := FHours.Visible;

  FUpdating := True;
  try
    FCompletion.Items.BeginUpdate;
    try
      FCompletion.Items.Clear;
      FCompletion.Items.Add('When done: stop sounds');
      FCompletion.Items.Add(Format('When done: fade out (%d s)', [FService.Settings.Timer.FadeOutSec]));
      FCompletion.Items.Add('When done: keep playing');
    finally
      FCompletion.Items.EndUpdate;
    end;
    Comp := FService.Settings.Timer.Completion;
    FCompletion.ItemIndex := Ord(Comp);
  finally
    FUpdating := False;
  end;
  FCompletion.Visible := not Pomo;

  FStart.Visible := not Active and not (Pomo and Completed);
  FStart.CaptionText := IfThen(Pomo, 'Start focus', 'Start');
  FPauseResume.Visible := Active;
  if Snap.Timer.State = trsPaused then
  begin
    FPauseResume.Glyph := cgPlay;
    FPauseResume.CaptionText := 'Resume';
    FPauseResume.Hint := 'Resume the timer';
  end
  else
  begin
    FPauseResume.Glyph := cgPause;
    FPauseResume.CaptionText := 'Pause';
    FPauseResume.Hint := 'Pause the timer';
  end;
  FReset.Visible := Active;
  FCancel.Visible := Active or (Pomo and Completed);
  FNext.Visible := Pomo and Completed;
  if FNext.Visible then
    FNext.CaptionText := 'Start ' + LowerCase(PhaseName(Snap.Timer.Phase));

  FTick.Enabled := Running and Showing;
  FLastDisplay := '';
  LayoutControls;
  Invalidate;
  if Visible and Assigned(FOnHeightChanged) and (Width > 0) and (Height <> PreferredHeight(Width)) then
    FOnHeightChanged(Self);
end;

function TCalmTimerPanel.PresetRowsHeight(AWidth: Integer): Integer;
var
  X, I, Left0, W, Rows: Integer;
begin
  // Mirrors the wrapping in LayoutControls.
  Left0 := S(12);
  W := AWidth - Left0 * 2;
  X := Left0;
  Rows := 1;
  for I := 0 to High(FPresetChips) do
  begin
    if (X > Left0) and (X + FPresetChips[I].PreferredWidth > Left0 + W) then
    begin
      X := Left0;
      Inc(Rows);
    end;
    Inc(X, FPresetChips[I].PreferredWidth + S(6));
  end;
  if X + S(6) + (S(30) + S(20)) * 3 > Left0 + W then
    Inc(Rows);
  Result := Rows * S(26) + (Rows - 1) * S(8);
end;

function TCalmTimerPanel.PreferredHeight(AWidth: Integer): Integer;
begin
  Result := S(12) + S(28) + S(8) + S(48) + S(18) + S(10);   // mode chips, display, status
  if FHours.Visible then
    Inc(Result, PresetRowsHeight(AWidth) + S(10));
  if FCompletion.Visible then
    Inc(Result, S(28) + S(8));
  Inc(Result, S(34) + S(12));
end;

procedure TCalmTimerPanel.LayoutControls;
var
  X, Y, W, I, EW, Gap, Left0, RowH: Integer;

  procedure Place(C: TControl; AW: Integer);
  begin
    C.SetBounds(X, Y, AW, RowH);
    Inc(X, AW + Gap);
  end;

begin
  if (Width <= 0) or not HandleAllocated then
    Exit;
  // Standard controls get an explicit, DPI-scaled font so they always match
  // the custom-painted ones.
  for I := 0 to ControlCount - 1 do
    if (Controls[I] is TEdit) or (Controls[I] is TComboBox) then
    begin
      TEdit(Controls[I]).ParentFont := False;
      TEdit(Controls[I]).Font.Name := CalmFontName;
      TEdit(Controls[I]).Font.Height := -MulDiv(9, CurrentPPI, 72);
    end;
  Gap := S(6);
  Left0 := S(12);
  W := Width - Left0 * 2;
  RowH := S(28);

  X := Left0;
  Y := S(12);
  Place(FModeCountdown, FModeCountdown.PreferredWidth);
  Place(FModePomodoro, FModePomodoro.PreferredWidth);
  Inc(Y, RowH + S(8));

  FDisplayRect := Rect(Left0, Y, Left0 + W, Y + S(48));
  FStatusRect := Rect(Left0, FDisplayRect.Bottom, Left0 + W, FDisplayRect.Bottom + S(18));
  Y := FStatusRect.Bottom + S(10);

  if FHours.Visible then
  begin
    X := Left0;
    RowH := S(26);
    for I := 0 to High(FPresetChips) do
    begin
      if (X > Left0) and (X + FPresetChips[I].PreferredWidth > Left0 + W) then
      begin
        X := Left0;
        Inc(Y, RowH + S(8));
      end;
      Place(FPresetChips[I], FPresetChips[I].PreferredWidth);
    end;
    EW := S(30);
    // Hours/minutes/seconds go on the same row when they fit, else wrap.
    if X + S(6) + (EW + S(20)) * 3 > Left0 + W then
    begin
      X := Left0;
      Inc(Y, RowH + S(8));
    end
    else
      Inc(X, S(6));
    RowH := S(26);
    FHours.SetBounds(X, Y, EW, RowH);
    FHoursUD.SetBounds(X + EW, Y, S(16), RowH);
    Inc(X, EW + S(16) + S(4));
    FMinutes.SetBounds(X, Y, EW, RowH);
    FMinutesUD.SetBounds(X + EW, Y, S(16), RowH);
    Inc(X, EW + S(16) + S(4));
    FSeconds.SetBounds(X, Y, EW, RowH);
    FSecondsUD.SetBounds(X + EW, Y, S(16), RowH);
    Inc(Y, RowH + S(10));
  end;

  if FCompletion.Visible then
  begin
    FCompletion.SetBounds(Left0, Y, Min(W, S(260)), S(26));
    Inc(Y, S(28) + S(8));
  end;

  X := Left0;
  RowH := S(32);
  if FStart.Visible then
    Place(FStart, Max(S(96), FStart.PreferredWidth));
  if FNext.Visible then
    Place(FNext, Max(S(110), FNext.PreferredWidth));
  if FPauseResume.Visible then
    Place(FPauseResume, Max(S(96), FPauseResume.PreferredWidth));
  if FReset.Visible then
    Place(FReset, RowH);
  if FCancel.Visible then
    Place(FCancel, RowH);
end;

procedure TCalmTimerPanel.Resize;
begin
  inherited;
  LayoutControls;
end;

procedure TCalmTimerPanel.Paint;
var
  R: TRect;
  Status, Text: string;
begin
  PaintBackground(ClientRect);
  R := ClientRect;
  InflateRect(R, -S(2), -S(2));
  FillRoundRect(Canvas.Handle, R, SF(10), Palette.Surface, Palette.Border, SF(1));
  Text := DisplayText(Status);
  FLastDisplay := Text;
  Canvas.Font.Name := CalmFontName;
  Canvas.Font.Height := -MulDiv(26, CurrentPPI, 72);
  Canvas.Font.Style := [];
  Canvas.Font.Color := IfThen(FService.Snapshot.Timer.State = trsRunning, Palette.Accent, Palette.Text);
  Canvas.Brush.Style := bsClear;
  R := FDisplayRect;
  DrawText(Canvas.Handle, PChar(Text), Length(Text), R, DT_SINGLELINE or DT_LEFT or DT_VCENTER or DT_NOPREFIX);
  DrawTextIn(Status, FStatusRect, Palette.TextMuted, DT_SINGLELINE or DT_LEFT or DT_TOP, 9);
end;

procedure TCalmTimerPanel.FocusPrimary;
begin
  if FStart.Visible and FStart.CanFocus then
    FStart.SetFocus
  else if FPauseResume.Visible and FPauseResume.CanFocus then
    FPauseResume.SetFocus;
end;

end.
