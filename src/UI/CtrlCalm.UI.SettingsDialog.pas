unit CtrlCalm.UI.SettingsDialog;

{ Native settings dialog. Changes are applied with OK/Apply; playback keeps
  running while the dialog is open. Built in code (no DFM) from standard VCL
  controls so the IDE theming service can style it. }

interface

uses
  Winapi.Windows, Winapi.ShellAPI, System.SysUtils, System.Classes, System.Math,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Menus,
  Vcl.Clipbrd, Vcl.Graphics,
  CtrlCalm.Core.Types, CtrlCalm.Core.Settings, CtrlCalm.Service;

type
  TCalmSettingsForm = class(TForm)
  private
    FService: TCalmService;
    FPages: TPageControl;
    FY: Integer;
    FPage: TWinControl;
    // audio
    FMaster: TTrackBar;
    FFadeIn, FFadeOut, FCrossfade, FStartup, FFocusLoss: TComboBox;
    FDeviceErrors: TCheckBox;
    // timer
    FCountdownMin: TEdit;
    FCompletion, FFadeChoice, FFocusPreset, FBreakPreset: TComboBox;
    FNotify, FChime, FAutoNext: TCheckBox;
    FFocusMin, FShortMin, FLongMin, FLongEvery: TEdit;
    // appearance
    FFollowIde, FReduced: TCheckBox;
    FAccent, FLayout: TComboBox;
    // general
    FOpenAtStartup, FRestoreMix: TCheckBox;
    FHotKeys: array[TShortcutAction] of THotKey;
    FPresetIds: TStringList;
    function NewPage(const Caption: string): TTabSheet;
    function AddLabel(const Text: string; Bold: Boolean = False): TLabel;
    function AddCombo(const Caption: string; const Items: array of string): TComboBox;
    function AddCheck(const Caption: string): TCheckBox;
    function AddNumber(const Caption: string; Min, Max: Integer): TEdit;
    procedure AddButton(const Caption: string; Handler: TNotifyEvent; ALeft: Integer = -1);
    function S(V: Integer): Integer;
    procedure BuildAudio;
    procedure BuildTimer;
    procedure BuildAppearance;
    procedure BuildGeneral;
    procedure BuildAbout;
    procedure LoadValues;
    procedure ApplyValues;
    procedure OkClick(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
    procedure PreviewChimeClick(Sender: TObject);
    procedure OpenFolderClick(Sender: TObject);
    procedure CopyDiagnosticsClick(Sender: TObject);
  public
    constructor CreateFor(AOwner: TComponent; AService: TCalmService);
    destructor Destroy; override;
  end;

var
  /// <summary>Hook set by the IDE adapter to theme forms with the IDE theme.</summary>
  CalmPrepareForm: TProc<TCustomForm> = nil;
  /// <summary>Hook set by the IDE adapter to re-register shortcuts.</summary>
  CalmShortcutsChanged: TProc = nil;
  /// <summary>Folder holding LICENSES.md / ATTRIBUTION.md (set by the host).</summary>
  CalmAssetsFolder: string = '';
  /// <summary>The settings dialog while it is open (re-themed on IDE theme changes).</summary>
  CalmOpenSettingsForm: TCustomForm = nil;

procedure ShowCalmSettings(AService: TCalmService);

implementation

uses
  System.IOUtils, CtrlCalm.Persistence;

const
  FadeMsChoices: array[0..5] of Integer = (0, 500, 1000, 1500, 2000, 3000);
  FadeMsNames: array[0..5] of string = ('None', '0.5 s', '1 s', '1.5 s', '2 s', '3 s');
  CtrlCalmVersion = '1.0.0';

function IndexOfInt(const A: array of Integer; V, Default: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(A) do
    if A[I] = V then
      Exit(I);
  Result := Default;
end;

procedure ShowCalmSettings(AService: TCalmService);
var
  F: TCalmSettingsForm;
begin
  F := TCalmSettingsForm.CreateFor(Application, AService);
  try
    if Assigned(CalmPrepareForm) then
      CalmPrepareForm(F);
    CalmOpenSettingsForm := F;
    try
      F.ShowModal;
    finally
      CalmOpenSettingsForm := nil;
    end;
  finally
    F.Free;
  end;
end;

{ TCalmSettingsForm }

constructor TCalmSettingsForm.CreateFor(AOwner: TComponent; AService: TCalmService);
var
  Btn: TButton;
  Bottom: TPanel;
begin
  inherited CreateNew(AOwner);
  FService := AService;
  FPresetIds := TStringList.Create;
  Caption := 'Ctrl+Calm Settings';
  BorderStyle := bsDialog;
  Position := poMainFormCenter;
  ClientWidth := S(500);
  ClientHeight := S(560);
  Font.Name := 'Segoe UI';
  Font.Height := -MulDiv(9, CurrentPPI, 72);

  Bottom := TPanel.Create(Self);
  Bottom.Parent := Self;
  Bottom.Align := alBottom;
  Bottom.Height := S(48);
  Bottom.BevelOuter := bvNone;
  Bottom.ShowCaption := False;

  Btn := TButton.Create(Self);
  Btn.Parent := Bottom;
  Btn.Caption := 'OK';
  Btn.Default := True;
  Btn.SetBounds(ClientWidth - S(256), S(10), S(76), S(28));
  Btn.OnClick := OkClick;
  Btn := TButton.Create(Self);
  Btn.Parent := Bottom;
  Btn.Caption := 'Cancel';
  Btn.Cancel := True;
  Btn.ModalResult := mrCancel;
  Btn.SetBounds(ClientWidth - S(172), S(10), S(76), S(28));
  Btn := TButton.Create(Self);
  Btn.Parent := Bottom;
  Btn.Caption := '&Apply';
  Btn.SetBounds(ClientWidth - S(88), S(10), S(76), S(28));
  Btn.OnClick := ApplyClick;

  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;
  FPages.AlignWithMargins := True;
  FPages.Margins.SetBounds(S(8), S(8), S(8), 0);

  BuildAudio;
  BuildTimer;
  BuildAppearance;
  BuildGeneral;
  BuildAbout;
  FPages.ActivePageIndex := 0;
  LoadValues;
end;

destructor TCalmSettingsForm.Destroy;
begin
  FPresetIds.Free;
  inherited;
end;

function TCalmSettingsForm.S(V: Integer): Integer;
begin
  Result := MulDiv(V, CurrentPPI, 96);
end;

function TCalmSettingsForm.NewPage(const Caption: string): TTabSheet;
var
  Box: TScrollBox;
begin
  Result := TTabSheet.Create(Self);
  Result.PageControl := FPages;
  Result.Caption := Caption;
  // Each page scrolls, so long pages stay usable at high DPI.
  Box := TScrollBox.Create(Self);
  Box.Parent := Result;
  Box.Align := alClient;
  Box.BorderStyle := bsNone;
  Box.VertScrollBar.Tracking := True;
  Box.HorzScrollBar.Visible := False;
  FPage := Box;
  FY := S(12);
end;

function TCalmSettingsForm.AddLabel(const Text: string; Bold: Boolean): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := FPage;
  Result.Caption := Text;
  Result.Left := S(14);
  Result.Top := FY;
  if Bold then
  begin
    Result.Font.Style := [fsBold];
    if FY > S(20) then
      Result.Top := FY + S(6);
    FY := Result.Top + S(22);
  end
  else
    FY := FY + S(20);
end;

function TCalmSettingsForm.AddCombo(const Caption: string; const Items: array of string): TComboBox;
var
  L: TLabel;
  I: Integer;
begin
  L := TLabel.Create(Self);
  L.Parent := FPage;
  L.Caption := Caption;
  L.SetBounds(S(14), FY + S(4), S(190), S(20));
  Result := TComboBox.Create(Self);
  Result.Parent := FPage;
  Result.Style := csDropDownList;
  Result.SetBounds(S(210), FY, S(240), S(24));
  for I := 0 to High(Items) do
    Result.Items.Add(Items[I]);
  L.FocusControl := Result;
  FY := FY + S(30);
end;

function TCalmSettingsForm.AddCheck(const Caption: string): TCheckBox;
begin
  Result := TCheckBox.Create(Self);
  Result.Parent := FPage;
  Result.Caption := Caption;
  Result.SetBounds(S(14), FY, S(440), S(22));
  FY := FY + S(26);
end;

function TCalmSettingsForm.AddNumber(const Caption: string; Min, Max: Integer): TEdit;
var
  L: TLabel;
  UD: TUpDown;
begin
  L := TLabel.Create(Self);
  L.Parent := FPage;
  L.Caption := Caption;
  L.SetBounds(S(14), FY + S(4), S(190), S(20));
  Result := TEdit.Create(Self);
  Result.Parent := FPage;
  Result.NumbersOnly := True;
  Result.SetBounds(S(210), FY, S(60), S(24));
  UD := TUpDown.Create(Self);
  UD.Parent := FPage;
  UD.Associate := Result;
  UD.Min := Min;
  UD.Max := Max;
  L.FocusControl := Result;
  FY := FY + S(30);
end;

procedure TCalmSettingsForm.AddButton(const Caption: string; Handler: TNotifyEvent; ALeft: Integer);
var
  B: TButton;
begin
  B := TButton.Create(Self);
  B.Parent := FPage;
  B.Caption := Caption;
  if ALeft < 0 then
    ALeft := S(14);
  B.SetBounds(ALeft, FY, S(150), S(26));
  B.OnClick := Handler;
  FY := FY + S(34);
end;

procedure TCalmSettingsForm.BuildAudio;
var
  L: TLabel;
begin
  NewPage('Audio');
  AddLabel('Volume', True);
  L := TLabel.Create(Self);
  L.Parent := FPage;
  L.Caption := 'Master volume';
  L.SetBounds(S(14), FY + S(4), S(190), S(20));
  FMaster := TTrackBar.Create(Self);
  FMaster.Parent := FPage;
  FMaster.SetBounds(S(204), FY, S(250), S(30));
  FMaster.Max := 100;
  FMaster.Frequency := 10;
  FMaster.TickStyle := tsNone;
  FY := FY + S(36);
  AddLabel('Transitions', True);
  FFadeIn := AddCombo('Fade in', FadeMsNames);
  FFadeOut := AddCombo('Fade out', FadeMsNames);
  FCrossfade := AddCombo('Mix crossfade', FadeMsNames);
  AddLabel('Behavior', True);
  FStartup := AddCombo('When the IDE starts', ['Restore my mix, stay silent', 'Resume playback automatically']);
  FFocusLoss := AddCombo('When RAD Studio loses focus', ['Keep playing', 'Mute', 'Pause']);
  FDeviceErrors := AddCheck('Show audio device problems in the status bar');
end;

procedure TCalmSettingsForm.BuildTimer;
begin
  NewPage('Timer');
  AddLabel('Countdown', True);
  FCountdownMin := AddNumber('Default length (minutes)', 1, 1439);
  FCompletion := AddCombo('When the timer ends', ['Stop sounds', 'Fade out sounds', 'Keep playing']);
  FFadeChoice := AddCombo('Fade-out duration', ['5 seconds', '15 seconds', '30 seconds']);
  FNotify := AddCheck('Show a desktop notification');
  FChime := AddCheck('Play a short completion chime');
  AddButton('Preview chime', PreviewChimeClick, S(210));
  AddLabel('Pomodoro', True);
  FFocusMin := AddNumber('Focus (minutes)', 1, 240);
  FShortMin := AddNumber('Short break (minutes)', 1, 120);
  FLongMin := AddNumber('Long break (minutes)', 1, 240);
  FLongEvery := AddNumber('Long break after (sessions)', 1, 12);
  FAutoNext := AddCheck('Start the next session automatically');
  FFocusPreset := AddCombo('Mix during focus', []);
  FBreakPreset := AddCombo('Mix during breaks', []);
end;

procedure TCalmSettingsForm.BuildAppearance;
var
  A: TAccentPalette;
  Names: array of string;
begin
  NewPage('Appearance');
  AddLabel('Theme', True);
  FFollowIde := AddCheck('Follow the IDE theme (light, dark, custom)');
  SetLength(Names, Ord(High(TAccentPalette)) + 1);
  for A := Low(TAccentPalette) to High(TAccentPalette) do
    Names[Ord(A)] := AccentName(A);
  FAccent := AddCombo('Accent color', Names);
  AddLabel('Layout', True);
  FLayout := AddCombo('Panel layout', ['Automatic (by width)', 'Compact', 'Comfort', 'Expanded']);
  FReduced := AddCheck('Reduce motion (no hover highlights)');
  AddLabel('Windows high-contrast themes are always honored.');
end;

procedure TCalmSettingsForm.BuildGeneral;
var
  A: TShortcutAction;
  L: TLabel;
  E: TEdit;
begin
  NewPage('General');
  AddLabel('Startup', True);
  FOpenAtStartup := AddCheck('Open the Ctrl+Calm panel when RAD Studio starts');
  FRestoreMix := AddCheck('Restore the last mix (without playing it)');
  AddLabel('Keyboard shortcuts', True);
  for A := Low(TShortcutAction) to High(TShortcutAction) do
  begin
    L := TLabel.Create(Self);
    L.Parent := FPage;
    L.Caption := ShortcutActionName(A);
    L.SetBounds(S(14), FY + S(4), S(190), S(20));
    FHotKeys[A] := THotKey.Create(Self);
    FHotKeys[A].Parent := FPage;
    FHotKeys[A].SetBounds(S(210), FY, S(180), S(24));
    FHotKeys[A].InvalidKeys := [hcNone];
    FHotKeys[A].Modifiers := [hkCtrl, hkAlt];
    L.FocusControl := FHotKeys[A];
    FY := FY + S(30);
  end;
  AddLabel('No shortcut is assigned by default. Choose combinations the editor does not use.');
  AddLabel('Press Backspace in a field to clear it.');
  AddLabel('Configuration', True);
  E := TEdit.Create(Self);
  E.Parent := FPage;
  E.ReadOnly := True;
  E.Text := FService.SettingsFileName;
  E.SetBounds(S(14), FY, S(440), S(24));
  FY := FY + S(30);
  AddButton('Open folder', OpenFolderClick);
end;

procedure TCalmSettingsForm.BuildAbout;
var
  Memo: TMemo;
  Lic, Text: string;
begin
  NewPage('About');
  AddLabel('Ctrl+Calm ' + CtrlCalmVersion, True);
  AddLabel('Your IDE. Your Sound. Your Flow.');
  AddLabel('Offline ambient sounds and a focus timer for RAD Studio.');
  AddLabel('No accounts, no telemetry, no network access.');
  AddLabel('Licenses and acknowledgments', True);
  Memo := TMemo.Create(Self);
  Memo.Parent := FPage;
  Memo.ReadOnly := True;
  Memo.ScrollBars := ssVertical;
  Memo.WordWrap := True;
  Memo.SetBounds(S(14), FY, S(440), S(170));
  Lic := IncludeTrailingPathDelimiter(CalmAssetsFolder) + 'ATTRIBUTION.md';
  if (CalmAssetsFolder <> '') and FileExists(Lic) then
    try
      Text := TFile.ReadAllText(Lic, TEncoding.UTF8);
    except
      Text := 'Cannot read ' + Lic;
    end
  else
    Text := 'ATTRIBUTION.md was not found next to the sound files.';
  Memo.Lines.Text := Text;
  FY := FY + S(178);
  AddButton('Copy diagnostics', CopyDiagnosticsClick);
end;

procedure TCalmSettingsForm.LoadValues;
var
  St: TCalmSettings;
  F: TFavorite;
  A: TShortcutAction;

  procedure FillPresets(C: TComboBox; const Selected: string);
  var
    I: Integer;
  begin
    C.Items.Clear;
    C.Items.Add('(Keep current sounds)');
    for I := 0 to FPresetIds.Count - 1 do
      C.Items.Add(FPresetIds.ValueFromIndex[I]);
    C.ItemIndex := 0;
    for I := 0 to FPresetIds.Count - 1 do
      if FPresetIds.Names[I] = Selected then
        C.ItemIndex := I + 1;
  end;

begin
  St := FService.Settings;
  FMaster.Position := Round(St.Audio.MasterVolume * 100);
  FFadeIn.ItemIndex := IndexOfInt(FadeMsChoices, St.Audio.FadeInMs, 3);
  FFadeOut.ItemIndex := IndexOfInt(FadeMsChoices, St.Audio.FadeOutMs, 2);
  FCrossfade.ItemIndex := IndexOfInt(FadeMsChoices, St.Audio.PresetCrossfadeMs, 4);
  FStartup.ItemIndex := Ord(St.Audio.Startup);
  FFocusLoss.ItemIndex := Ord(St.Audio.FocusLoss);
  FDeviceErrors.Checked := St.Audio.ShowDeviceErrors;

  FCountdownMin.Text := IntToStr(Max(1, St.Timer.CountdownSec div 60));
  FCompletion.ItemIndex := Ord(St.Timer.Completion);
  FFadeChoice.ItemIndex := IndexOfInt(FadeChoicesSec, St.Timer.FadeOutSec, 1);
  FNotify.Checked := St.Timer.Notify;
  FChime.Checked := St.Timer.Chime;
  FFocusMin.Text := IntToStr(Max(1, St.Timer.Pomodoro.FocusSec div 60));
  FShortMin.Text := IntToStr(Max(1, St.Timer.Pomodoro.ShortBreakSec div 60));
  FLongMin.Text := IntToStr(Max(1, St.Timer.Pomodoro.LongBreakSec div 60));
  FLongEvery.Text := IntToStr(St.Timer.Pomodoro.LongBreakEvery);
  FAutoNext.Checked := St.Timer.Pomodoro.AutoStartNext;
  FPresetIds.Clear;
  for F in FService.Presets do
    FPresetIds.Add(F.Id + '=' + F.Name);
  FillPresets(FFocusPreset, St.Timer.FocusPresetId);
  FillPresets(FBreakPreset, St.Timer.BreakPresetId);

  FFollowIde.Checked := St.Appearance.FollowIdeTheme;
  FAccent.ItemIndex := Ord(St.Appearance.Accent);
  FLayout.ItemIndex := Ord(St.Appearance.Layout);
  FReduced.Checked := St.Appearance.ReducedMotion;

  FOpenAtStartup.Checked := St.General.OpenPanelAtStartup;
  FRestoreMix.Checked := St.General.RestoreLastPreset;
  for A := Low(TShortcutAction) to High(TShortcutAction) do
    FHotKeys[A].HotKey := St.Shortcuts[A];
end;

procedure TCalmSettingsForm.ApplyValues;
var
  Master: Single;
  FadeIn, FadeOut, Cross, Startup, Focus, CountMin, Completion, FadeSec, FocusM, ShortM, LongM,
    Every, Accent, Layout: Integer;
  DevErr, Notify, Chime, AutoNext, Follow, Reduced, OpenAt, Restore: Boolean;
  FocusId, BreakId: string;
  Keys: TShortcuts;
  A: TShortcutAction;
  OldKeys: TShortcuts;
  KeysChanged: Boolean;
begin
  Master := FMaster.Position / 100;
  FadeIn := FadeMsChoices[Max(0, FFadeIn.ItemIndex)];
  FadeOut := FadeMsChoices[Max(0, FFadeOut.ItemIndex)];
  Cross := FadeMsChoices[Max(0, FCrossfade.ItemIndex)];
  Startup := Max(0, FStartup.ItemIndex);
  Focus := Max(0, FFocusLoss.ItemIndex);
  DevErr := FDeviceErrors.Checked;
  CountMin := EnsureRange(StrToIntDef(FCountdownMin.Text, 25), 1, 1439);
  Completion := Max(0, FCompletion.ItemIndex);
  FadeSec := FadeChoicesSec[Max(0, FFadeChoice.ItemIndex)];
  Notify := FNotify.Checked;
  Chime := FChime.Checked;
  FocusM := EnsureRange(StrToIntDef(FFocusMin.Text, 25), 1, 240);
  ShortM := EnsureRange(StrToIntDef(FShortMin.Text, 5), 1, 120);
  LongM := EnsureRange(StrToIntDef(FLongMin.Text, 15), 1, 240);
  Every := EnsureRange(StrToIntDef(FLongEvery.Text, 4), 1, 12);
  AutoNext := FAutoNext.Checked;
  FocusId := '';
  if FFocusPreset.ItemIndex > 0 then
    FocusId := FPresetIds.Names[FFocusPreset.ItemIndex - 1];
  BreakId := '';
  if FBreakPreset.ItemIndex > 0 then
    BreakId := FPresetIds.Names[FBreakPreset.ItemIndex - 1];
  Follow := FFollowIde.Checked;
  Accent := Max(0, FAccent.ItemIndex);
  Layout := Max(0, FLayout.ItemIndex);
  Reduced := FReduced.Checked;
  OpenAt := FOpenAtStartup.Checked;
  Restore := FRestoreMix.Checked;
  OldKeys := FService.Settings.Shortcuts;
  KeysChanged := False;
  for A := Low(TShortcutAction) to High(TShortcutAction) do
  begin
    Keys[A] := FHotKeys[A].HotKey;
    if Keys[A] <> OldKeys[A] then
      KeysChanged := True;
  end;

  FService.SetMasterVolume(Master);
  FService.UpdateSettings(
    procedure(var St: TCalmSettings)
    begin
      St.Audio.FadeInMs := FadeIn;
      St.Audio.FadeOutMs := FadeOut;
      St.Audio.PresetCrossfadeMs := Cross;
      St.Audio.Startup := TStartupBehavior(Startup);
      St.Audio.FocusLoss := TFocusLossBehavior(Focus);
      St.Audio.ShowDeviceErrors := DevErr;
      St.Timer.CountdownSec := CountMin * 60;
      St.Timer.Completion := TTimerCompletionAction(Completion);
      St.Timer.FadeOutSec := FadeSec;
      St.Timer.Notify := Notify;
      St.Timer.Chime := Chime;
      St.Timer.Pomodoro.FocusSec := FocusM * 60;
      St.Timer.Pomodoro.ShortBreakSec := ShortM * 60;
      St.Timer.Pomodoro.LongBreakSec := LongM * 60;
      St.Timer.Pomodoro.LongBreakEvery := Every;
      St.Timer.Pomodoro.AutoStartNext := AutoNext;
      St.Timer.FocusPresetId := FocusId;
      St.Timer.BreakPresetId := BreakId;
      St.Appearance.FollowIdeTheme := Follow;
      St.Appearance.Accent := TAccentPalette(Accent);
      St.Appearance.Layout := TLayoutPreference(Layout);
      St.Appearance.ReducedMotion := Reduced;
      St.General.OpenPanelAtStartup := OpenAt;
      St.General.RestoreLastPreset := Restore;
      St.Shortcuts := Keys;
    end);
  if KeysChanged and Assigned(CalmShortcutsChanged) then
    CalmShortcutsChanged();
end;

procedure TCalmSettingsForm.OkClick(Sender: TObject);
begin
  ApplyValues;
  ModalResult := mrOk;
end;

procedure TCalmSettingsForm.ApplyClick(Sender: TObject);
begin
  ApplyValues;
end;

procedure TCalmSettingsForm.PreviewChimeClick(Sender: TObject);
begin
  FService.PreviewChime;
end;

procedure TCalmSettingsForm.OpenFolderClick(Sender: TObject);
begin
  ForceDirectories(ExtractFileDir(FService.SettingsFileName));
  ShellExecute(Handle, 'open', PChar(ExtractFileDir(FService.SettingsFileName)), nil, nil, SW_SHOWNORMAL);
end;

procedure TCalmSettingsForm.CopyDiagnosticsClick(Sender: TObject);
begin
  Clipboard.AsText := FService.DiagnosticsText;
end;

end.
