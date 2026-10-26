unit CtrlCalm.UI.MixerView;

{
  The complete Ctrl+Calm mixer: header, presets, collapsible timer, sound
  tiles and status footer. Used unchanged by the IDE dockable window and by the
  standalone development harness.

  Layout is computed by Relayout from the client width in 96-DPI units:
    compact   (< 300 DIP)  two-row header, single-column row tiles
    comfort   (300-560)    one-row header, card grid, columns from width
    expanded  (>= 560)     larger cards and spacing
  The user can pin a mode in Settings > Appearance.
}

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.Math, System.StrUtils, Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.Menus, Vcl.ExtCtrls,
  CtrlCalm.Core.Types, CtrlCalm.Core.Settings, CtrlCalm.Timer, CtrlCalm.Threading.Worker, CtrlCalm.Service,
  CtrlCalm.UI.Theme, CtrlCalm.UI.Icons, CtrlCalm.UI.Controls, CtrlCalm.UI.TimerPanel;

type
  TLayoutMode = (lmCompact, lmComfort, lmExpanded);

  TCalmTileHost = class(TCalmControl)
  protected
    procedure Paint; override;
  end;

  TCalmMixerView = class(TCalmControl)
  private
    FService: TCalmService;
    FPlay, FStop, FMute, FTimerBtn, FSettingsBtn: TCalmIconButton;
    FMaster: TCalmSlider;
    FChips: TList;
    FSaveChip: TCalmChip;
    FTimerPanel: TCalmTimerPanel;
    FTimerVisible: Boolean;
    FScroll: TScrollBox;
    FTileHost: TCalmTileHost;
    FTiles: array[TSoundId] of TCalmSoundTile;
    FPresetMenu: TPopupMenu;
    FMode: TLayoutMode;
    FLogoRect, FStatusRect, FPresetLabelRect: TRect;
    FHeaderBottom: Integer;
    FHeaderTimerTick: TTimer;
    FOnOpenSettings: TNotifyEvent;
    FStatusText: string;
    FStatusWarning: Boolean;
    FLayingOut: Boolean;
    FAccent: TAccentPalette;
    procedure ServiceChanged(Changes: TCalmChanges);
    procedure BuildChips;
    procedure UpdateFromService;
    procedure UpdateStatus;
    procedure UpdateTimerButton;
    procedure Relayout;
    procedure LayoutTiles;
    function EffectiveMode: TLayoutMode;
    procedure TileToggle(Sender: TObject; Id: TSoundId);
    procedure TileVolume(Sender: TObject; Id: TSoundId; Volume: Single);
    procedure PlayClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure MuteClick(Sender: TObject);
    procedure MasterChange(Sender: TObject);
    procedure TimerClick(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
    procedure ChipClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure PresetMenuPopup(Sender: TObject);
    procedure MenuRename(Sender: TObject);
    procedure MenuUpdate(Sender: TObject);
    procedure MenuDuplicate(Sender: TObject);
    procedure MenuDelete(Sender: TObject);
    procedure HeaderTick(Sender: TObject);
    procedure TimerHeightChanged(Sender: TObject);
    function MenuChip: TCalmChip;
    function MakeButton(G: TCalmGlyph; const HintText: string; K: TCalmButtonKind): TCalmIconButton;
    procedure CMStyleChanged(var Msg: TMessage); message CM_STYLECHANGED;
    procedure WMSettingChange(var Msg: TMessage); message WM_SETTINGCHANGE;
    procedure CMShowingChanged(var Msg: TMessage); message CM_SHOWINGCHANGED;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
  public
    constructor Create(AOwner: TComponent; AService: TCalmService); reintroduce;
    destructor Destroy; override;
    procedure RefreshTheme;
    procedure ShowTimer(AVisible: Boolean);
    procedure ToggleTimer;
    property TimerVisible: Boolean read FTimerVisible;
    property LayoutMode: TLayoutMode read FMode;
    property OnOpenSettings: TNotifyEvent read FOnOpenSettings write FOnOpenSettings;
  end;

implementation

uses
  Vcl.Dialogs;

{ TCalmTileHost }

procedure TCalmTileHost.Paint;
begin
  PaintBackground(ClientRect);
end;

{ TCalmMixerView }

constructor TCalmMixerView.Create(AOwner: TComponent; AService: TCalmService);
var
  Id: TSoundId;
  Item: TMenuItem;
begin
  inherited Create(AOwner);
  FService := AService;
  TabStop := False;
  ControlStyle := ControlStyle + [csAcceptsControls];
  FChips := TList.Create;

  FPlay := MakeButton(cgPlay, 'Play', bkPrimary);
  FPlay.OnClick := PlayClick;
  FStop := MakeButton(cgStop, 'Stop all sounds', bkGhost);
  FStop.OnClick := StopClick;
  FMute := MakeButton(cgSpeaker, 'Mute', bkGhost);
  FMute.OnClick := MuteClick;
  FMaster := TCalmSlider.Create(Self);
  FMaster.Parent := Self;
  FMaster.AccessibleName := 'Master volume';
  FMaster.OnChange := MasterChange;
  FTimerBtn := MakeButton(cgTimer, 'Focus timer', bkGhost);
  FTimerBtn.OnClick := TimerClick;
  FSettingsBtn := MakeButton(cgSettings, 'Ctrl+Calm settings', bkGhost);
  FSettingsBtn.OnClick := SettingsClick;

  FPresetMenu := TPopupMenu.Create(Self);
  FPresetMenu.OnPopup := PresetMenuPopup;
  Item := TMenuItem.Create(FPresetMenu); Item.Caption := 'Rename...'; Item.OnClick := MenuRename; Item.Tag := 1;
  FPresetMenu.Items.Add(Item);
  Item := TMenuItem.Create(FPresetMenu); Item.Caption := 'Update with current mix'; Item.OnClick := MenuUpdate; Item.Tag := 2;
  FPresetMenu.Items.Add(Item);
  Item := TMenuItem.Create(FPresetMenu); Item.Caption := 'Duplicate'; Item.OnClick := MenuDuplicate; Item.Tag := 3;
  FPresetMenu.Items.Add(Item);
  Item := TMenuItem.Create(FPresetMenu); Item.Caption := '-';
  FPresetMenu.Items.Add(Item);
  Item := TMenuItem.Create(FPresetMenu); Item.Caption := 'Delete'; Item.OnClick := MenuDelete; Item.Tag := 4;
  FPresetMenu.Items.Add(Item);

  FSaveChip := TCalmChip.Create(Self);
  FSaveChip.Parent := Self;
  FSaveChip.Text := '+ Save mix';
  FSaveChip.Hint := 'Save the current sounds and levels as a favorite';
  FSaveChip.OnClick := SaveClick;

  FTimerPanel := TCalmTimerPanel.Create(Self, FService);
  FTimerPanel.Parent := Self;
  FTimerPanel.Visible := False;
  FTimerPanel.OnHeightChanged := TimerHeightChanged;

  FScroll := TScrollBox.Create(Self);
  FScroll.Parent := Self;
  FScroll.BorderStyle := bsNone;
  FScroll.HorzScrollBar.Visible := False;
  FScroll.VertScrollBar.Tracking := True;
  FScroll.VertScrollBar.Smooth := True;
  FScroll.ParentBackground := False;
  FScroll.TabStop := False;

  FTileHost := TCalmTileHost.Create(Self);
  FTileHost.Parent := FScroll;
  FTileHost.TabStop := False;
  for Id := Low(TSoundId) to High(TSoundId) do
  begin
    FTiles[Id] := TCalmSoundTile.Create(Self, Id);
    FTiles[Id].Parent := FTileHost;
    FTiles[Id].OnToggle := TileToggle;
    FTiles[Id].OnVolume := TileVolume;
    FTiles[Id].TabOrder := Ord(Id);
  end;

  FHeaderTimerTick := TTimer.Create(Self);
  FHeaderTimerTick.Enabled := False;
  FHeaderTimerTick.Interval := 500;
  FHeaderTimerTick.OnTimer := HeaderTick;

  FAccent := FService.Settings.Appearance.Accent;
  BuildChips;
  RefreshTheme;
  FService.AddListener(ServiceChanged);
  UpdateFromService;
end;

destructor TCalmMixerView.Destroy;
begin
  if Assigned(FService) then
    FService.RemoveListener(ServiceChanged);
  FChips.Free;
  inherited;
end;

function TCalmMixerView.MakeButton(G: TCalmGlyph; const HintText: string; K: TCalmButtonKind): TCalmIconButton;
begin
  Result := TCalmIconButton.Create(Self);
  Result.Parent := Self;
  Result.Glyph := G;
  Result.Hint := HintText;
  Result.Kind := K;
end;

procedure TCalmMixerView.RefreshTheme;
var
  P: TCalmPalette;
  I: Integer;
  Id: TSoundId;
begin
  FAccent := FService.Settings.Appearance.Accent;
  CalmReducedMotion := FService.Settings.Appearance.ReducedMotion;
  P := BuildPalette(FAccent, FService.Settings.Appearance.FollowIdeTheme);
  SetPalette(P);
  FPlay.SetPalette(P);
  FStop.SetPalette(P);
  FMute.SetPalette(P);
  FMaster.SetPalette(P);
  FTimerBtn.SetPalette(P);
  FSettingsBtn.SetPalette(P);
  FSaveChip.SetPalette(P);
  for I := 0 to FChips.Count - 1 do
    TCalmChip(FChips[I]).SetPalette(P);
  FTimerPanel.SetPalette(P);
  FTileHost.SetPalette(P);
  for Id := Low(TSoundId) to High(TSoundId) do
    FTiles[Id].SetPalette(P);
  FScroll.Color := P.Background;
  Invalidate;
end;

procedure TCalmMixerView.CMStyleChanged(var Msg: TMessage);
begin
  inherited;
  RefreshTheme;
end;

procedure TCalmMixerView.WMSettingChange(var Msg: TMessage);
begin
  inherited;
  RefreshTheme; // high-contrast toggles arrive here
end;

procedure TCalmMixerView.CMShowingChanged(var Msg: TMessage);
begin
  inherited;
  UpdateTimerButton;
  if Showing then
    FTimerPanel.Refresh;
end;

procedure TCalmMixerView.BuildChips;
var
  I: Integer;
  Chip: TCalmChip;
  F: TFavorite;
begin
  for I := FChips.Count - 1 downto 0 do
    TObject(FChips[I]).Free;
  FChips.Clear;
  for F in FService.Presets do
  begin
    Chip := TCalmChip.Create(Self);
    Chip.Parent := Self;
    Chip.Text := F.Name;
    Chip.ItemId := F.Id;
    Chip.UserItem := not F.BuiltIn;
    if F.BuiltIn then
    begin
      Chip.DotColor := AccentColor(F.Accent, Palette.Dark);
      Chip.Hint := F.Name + ' (built-in preset)' + sLineBreak + 'Right-click to duplicate.';
    end
    else
      Chip.Hint := F.Name + ' (your favorite)' + sLineBreak + 'Right-click to rename, update, duplicate or delete.';
    Chip.OnClick := ChipClick;
    Chip.PopupMenu := FPresetMenu;
    Chip.SetPalette(Palette);
    FChips.Add(Chip);
  end;
end;

procedure TCalmMixerView.ServiceChanged(Changes: TCalmChanges);
begin
  if ccFavorites in Changes then
  begin
    BuildChips;
    Relayout;
  end;
  if ccSettings in Changes then
  begin
    if (FService.Settings.Appearance.Accent <> FAccent) or
       (FService.Settings.Appearance.ReducedMotion <> CalmReducedMotion) then
    begin
      RefreshTheme;
      BuildChips;
    end;
    Relayout;
    FTimerPanel.Refresh;
  end;
  UpdateFromService;
  if (ccState in Changes) and FTimerVisible then
    FTimerPanel.Refresh;
  if (ccTimerEvent in Changes) and not FTimerVisible and
     (FService.LastTimerEvent.Kind = tekPhaseCompleted) and not FService.LastTimerEvent.NextStarted then
    ShowTimer(True); // the next Pomodoro phase needs an explicit start
end;

procedure TCalmMixerView.UpdateFromService;
var
  Id: TSoundId;
  Snap: TCalmSnapshot;
  Matching: string;
  I: Integer;
begin
  Snap := FService.Snapshot;
  for Id := Low(TSoundId) to High(TSoundId) do
    FTiles[Id].SetState(FService.IsActive(Id), FService.IsActive(Id) and FService.Paused,
      Snap.TrackStates[Id] = tsUnavailable, Snap.TrackErrors[Id], FService.Volume(Id));

  if FService.Paused then
  begin
    FPlay.Glyph := cgPlay;
    FPlay.Hint := IfThen(FService.HasActiveSounds, 'Play', 'Play (choose a sound first)');
  end
  else
  begin
    FPlay.Glyph := cgPause;
    FPlay.Hint := 'Pause';
  end;
  FPlay.Enabled := FService.HasActiveSounds or not FService.Paused;
  FStop.Enabled := FService.HasActiveSounds;
  if FService.Muted then
  begin
    FMute.Glyph := cgSpeakerMuted;
    FMute.Hint := 'Unmute';
  end
  else
  begin
    FMute.Glyph := cgSpeaker;
    FMute.Hint := 'Mute';
  end;
  FMaster.Value := FService.MasterVolume;
  FMaster.Hint := Format('Master volume: %d%%', [Round(FService.MasterVolume * 100)]);

  Matching := FService.MatchingPresetId;
  for I := 0 to FChips.Count - 1 do
    TCalmChip(FChips[I]).Selected := (Matching <> '') and (TCalmChip(FChips[I]).ItemId = Matching);
  FSaveChip.Enabled := FService.HasActiveSounds;

  UpdateTimerButton;
  UpdateStatus;
end;

procedure TCalmMixerView.UpdateStatus;
var
  Snap: TCalmSnapshot;
  N: Integer;
  Text, Noun: string;
  Warn: Boolean;
begin
  Snap := FService.Snapshot;
  N := FService.CurrentMix.ActiveCount;
  if N = 1 then
    Noun := 'sound'
  else
    Noun := 'sounds';
  Warn := False;
  if (Snap.AudioStatus in [asNoDevice, asRecovering, asUnavailable]) and (N > 0) and not FService.Paused and
     FService.Settings.Audio.ShowDeviceErrors then
  begin
    Text := Snap.AudioStatusText;
    Warn := True;
  end
  else if N = 0 then
    Text := 'Choose a sound to begin'
  else if FService.Paused then
    Text := Format('Paused - %d %s ready', [N, Noun])
  else if FService.Muted then
    Text := Format('Muted - %d %s playing', [N, Noun])
  else
    Text := Format('Playing %d %s', [N, Noun]);
  if FService.LastPersistError <> '' then
  begin
    Text := Text + ' - settings not saved';
    Warn := True;
  end;
  if (Text <> FStatusText) or (Warn <> FStatusWarning) then
  begin
    FStatusText := Text;
    FStatusWarning := Warn;
    if HandleAllocated then
      InvalidateRect(Handle, @FStatusRect, False);
  end;
end;

procedure TCalmMixerView.UpdateTimerButton;
var
  Snap: TCalmSnapshot;
  Running: Boolean;
  Cap: string;
begin
  Snap := FService.Snapshot;
  Running := Snap.Timer.State in [trsRunning, trsPaused];
  if Running then
  begin
    Cap := FormatDuration(Snap.TimerRemainingNow);
    if Snap.Timer.State = trsPaused then
      FTimerBtn.Hint := 'Focus timer (paused) - ' + Cap
    else
      FTimerBtn.Hint := 'Focus timer - ' + Cap + ' left';
  end
  else
  begin
    Cap := '';
    FTimerBtn.Hint := 'Focus timer';
  end;
  FTimerBtn.Checked := FTimerVisible;
  if Cap <> FTimerBtn.CaptionText then
  begin
    FTimerBtn.CaptionText := Cap;
    Relayout;
  end;
  FHeaderTimerTick.Enabled := (Snap.Timer.State = trsRunning) and Showing;
end;

procedure TCalmMixerView.TimerHeightChanged(Sender: TObject);
begin
  if not FLayingOut then
    Relayout;
end;

procedure TCalmMixerView.HeaderTick(Sender: TObject);
begin
  UpdateTimerButton;
end;

function TCalmMixerView.EffectiveMode: TLayoutMode;
var
  Dip: Integer;
begin
  case FService.Settings.Appearance.Layout of
    lpCompact: Exit(lmCompact);
    lpComfort: Exit(lmComfort);
    lpExpanded: Exit(lmExpanded);
  end;
  Dip := MulDiv(ClientWidth, 96, CurrentPPI);
  if Dip < 300 then
    Result := lmCompact
  else if Dip < 560 then
    Result := lmComfort
  else
    Result := lmExpanded;
end;

procedure TCalmMixerView.Relayout;
var
  Pad, Gap, BtnH, X, Y, W, RightX, ChipH, ChipW, I, TimerH, FooterH, LogoW: Integer;
  Chip: TCalmChip;

  procedure PlaceRight(C: TControl; AW, AH: Integer; ATop: Integer);
  begin
    Dec(RightX, AW);
    C.SetBounds(RightX, ATop, AW, AH);
    Dec(RightX, Gap);
  end;

begin
  if FLayingOut or (ClientWidth <= 0) or not HandleAllocated then
    Exit;
  FLayingOut := True;
  try
    FMode := EffectiveMode;
    case FMode of
      lmCompact:
        begin
          Pad := S(8);
          Gap := S(4);
        end;
      lmComfort:
        begin
          Pad := S(12);
          Gap := S(6);
        end;
    else
      Pad := S(18);
      Gap := S(8);
    end;
    BtnH := S(32);
    W := ClientWidth - Pad * 2;
    Y := Pad;

    // Header
    Canvas.Font.Name := CalmFontName;
    Canvas.Font.Height := -MulDiv(11, CurrentPPI, 72);
    Canvas.Font.Style := [fsBold];
    LogoW := S(22) + S(8) + Canvas.TextWidth('Ctrl+Calm');
    FLogoRect := Rect(Pad, Y, Pad + LogoW, Y + BtnH);
    RightX := Pad + W;
    PlaceRight(FSettingsBtn, BtnH, BtnH, Y);
    FTimerBtn.Height := BtnH;
    PlaceRight(FTimerBtn, Max(BtnH, FTimerBtn.PreferredWidth), BtnH, Y);
    // Use two header rows in compact mode, or whenever one row would leave
    // the master volume slider too short to be comfortable.
    if (FMode = lmCompact) or
       (RightX - (FLogoRect.Right + S(16) + (BtnH + S(4)) + Gap + BtnH * 2 + Gap) < S(110)) then
    begin
      // Row 1: logo, timer, settings. Row 2: transport and master volume.
      Inc(Y, BtnH + Gap);
      X := Pad;
      FPlay.SetBounds(X, Y, BtnH + S(4), BtnH + S(4));
      Inc(X, BtnH + S(4) + Gap);
      FStop.SetBounds(X, Y + S(2), BtnH, BtnH);
      Inc(X, BtnH + Gap);
      FMute.SetBounds(X, Y + S(2), BtnH, BtnH);
      Inc(X, BtnH);
      FMaster.SetBounds(X, Y + S(2), Max(S(40), Pad + W - X), BtnH);
      Y := Y + BtnH + S(4);
    end
    else
    begin
      X := FLogoRect.Right + S(16);
      FPlay.SetBounds(X, Y - S(2), BtnH + S(4), BtnH + S(4));
      Inc(X, BtnH + S(4) + Gap);
      FStop.SetBounds(X, Y, BtnH, BtnH);
      Inc(X, BtnH + Gap);
      FMute.SetBounds(X, Y, BtnH, BtnH);
      Inc(X, BtnH);
      FMaster.SetBounds(X, Y, Max(S(60), Min(S(220), RightX - X)), BtnH);
      Inc(Y, BtnH);
    end;
    FHeaderBottom := Y + Gap;
    Y := FHeaderBottom + Gap;

    // Presets: a wrapping row of chips
    ChipH := S(26);
    FPresetLabelRect := Rect(Pad, Y, Pad + W, Y + S(16));
    Inc(Y, S(18));
    X := Pad;
    for I := 0 to FChips.Count do
    begin
      if I < FChips.Count then
        Chip := TCalmChip(FChips[I])
      else
        Chip := FSaveChip;
      ChipW := Min(Chip.PreferredWidth, W);
      if (X > Pad) and (X + ChipW > Pad + W) then
      begin
        X := Pad;
        Inc(Y, ChipH + Gap);
      end;
      Chip.SetBounds(X, Y, ChipW, ChipH);
      Inc(X, ChipW + Gap);
    end;
    Inc(Y, ChipH + Pad);

    // Timer (collapsible)
    if FTimerVisible then
    begin
      FTimerPanel.Width := W;
      TimerH := FTimerPanel.PreferredHeight(W);
      FTimerPanel.SetBounds(Pad, Y, W, TimerH);
      FTimerPanel.Visible := True;
      Inc(Y, TimerH + Pad);
    end
    else
      FTimerPanel.Visible := False;

    // Tiles fill the rest, above a one-line footer
    FooterH := S(24);
    FScroll.SetBounds(Pad - S(2), Y, W + S(4), Max(S(40), ClientHeight - Y - FooterH));
    FStatusRect := Rect(Pad, ClientHeight - FooterH, Pad + W, ClientHeight - S(4));
    LayoutTiles;
  finally
    FLayingOut := False;
  end;
  Invalidate;
end;

procedure TCalmMixerView.LayoutTiles;
var
  Avail, Cols, Rows, TileW, TileH, Gap, I, MinW, X, Y, HostH: Integer;
  Id: TSoundId;
  Style: TTileStyle;
  Count: Integer;

  procedure Compute;
  begin
    Cols := Max(1, (Avail + Gap) div (MinW + Gap));
    if Style = tsRow then
      Cols := Min(Cols, 2);
    Cols := Min(Cols, 8);
    // In wide layouts prefer a column count that leaves no ragged last row
    // (16 sounds: 4 or 8 columns) when it costs only one column.
    if (Cols >= 5) and (Count mod Cols <> 0) and (Count mod (Cols - 1) = 0) then
      Dec(Cols);
    TileW := (Avail - Gap * (Cols - 1)) div Cols;
    Rows := (Ord(High(TSoundId)) + Cols) div Cols;
    HostH := Rows * TileH + (Rows - 1) * Gap;
  end;

begin
  Avail := FScroll.ClientWidth;
  if Avail <= 0 then
    Exit;
  Count := Ord(High(TSoundId)) + 1;
  case FMode of
    lmCompact:
      begin
        Style := tsRow;
        Gap := S(4);
        MinW := S(150);
        TileH := S(44);
      end;
    lmComfort:
      begin
        Style := tsCard;
        Gap := S(6);
        MinW := S(112);
        TileH := S(104);
      end;
  else
    Style := tsCard;
    Gap := S(10);
    MinW := S(136);
    TileH := S(120);
  end;
  Compute;
  // A vertical scrollbar takes width: recompute once with the reduced width.
  if (HostH > FScroll.ClientHeight) and not FScroll.VertScrollBar.IsScrollBarVisible then
  begin
    Dec(Avail, GetSystemMetrics(SM_CXVSCROLL));
    Compute;
  end;
  FTileHost.SetBounds(0, -FScroll.VertScrollBar.Position, Avail, HostH);
  I := 0;
  for Id := Low(TSoundId) to High(TSoundId) do
  begin
    X := (I mod Cols) * (TileW + Gap);
    Y := (I div Cols) * (TileH + Gap);
    FTiles[Id].Style := Style;
    FTiles[Id].SetBounds(X, Y, TileW, TileH);
    FTiles[Id].Invalidate;
    Inc(I);
  end;
  FScroll.VertScrollBar.Increment := TileH div 2;
end;

procedure TCalmMixerView.Resize;
begin
  inherited;
  Relayout;
end;

procedure TCalmMixerView.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  if isDpiChange then
    Relayout;
end;

procedure TCalmMixerView.Paint;
var
  R, MR: TRect;
begin
  PaintBackground(ClientRect);
  // Logo mark and product name
  MR := Rect(FLogoRect.Left, FLogoRect.Top + (FLogoRect.Height - S(22)) div 2, FLogoRect.Left + S(22), 0);
  MR.Bottom := MR.Top + S(22);
  DrawGlyph(Canvas.Handle, cgLogo, MR, Palette.Accent);
  R := Rect(MR.Right + S(8), FLogoRect.Top, FLogoRect.Right + S(4), FLogoRect.Bottom);
  DrawTextIn('Ctrl+Calm', R, Palette.Text, DT_SINGLELINE or DT_VCENTER or DT_LEFT, 11, True);
  // Divider under the header
  Canvas.Pen.Color := Palette.Border;
  Canvas.MoveTo(FLogoRect.Left, FHeaderBottom);
  Canvas.LineTo(ClientWidth - FLogoRect.Left, FHeaderBottom);
  DrawTextIn('MIXES', FPresetLabelRect, Palette.TextMuted, DT_SINGLELINE or DT_LEFT or DT_TOP, 7, True);
  // Footer status
  if FStatusWarning then
    DrawTextIn(FStatusText, FStatusRect, Palette.Warning, DT_SINGLELINE or DT_LEFT or DT_VCENTER, 8)
  else
    DrawTextIn(FStatusText, FStatusRect, Palette.TextMuted, DT_SINGLELINE or DT_LEFT or DT_VCENTER, 8);
end;

procedure TCalmMixerView.TileToggle(Sender: TObject; Id: TSoundId);
begin
  FService.ToggleSound(Id);
end;

procedure TCalmMixerView.TileVolume(Sender: TObject; Id: TSoundId; Volume: Single);
begin
  FService.SetSoundVolume(Id, Volume);
end;

procedure TCalmMixerView.PlayClick(Sender: TObject);
begin
  FService.TogglePlayPause;
end;

procedure TCalmMixerView.StopClick(Sender: TObject);
begin
  FService.StopAll;
end;

procedure TCalmMixerView.MuteClick(Sender: TObject);
begin
  FService.ToggleMute;
end;

procedure TCalmMixerView.MasterChange(Sender: TObject);
begin
  FService.SetMasterVolume(FMaster.Value);
end;

procedure TCalmMixerView.ShowTimer(AVisible: Boolean);
begin
  if FTimerVisible = AVisible then
    Exit;
  FTimerVisible := AVisible;
  if AVisible then
    FTimerPanel.Refresh;
  UpdateTimerButton;
  Relayout;
  if AVisible and FTimerPanel.Showing then
    FTimerPanel.FocusPrimary;
end;

procedure TCalmMixerView.ToggleTimer;
begin
  ShowTimer(not FTimerVisible);
end;

procedure TCalmMixerView.TimerClick(Sender: TObject);
begin
  ToggleTimer;
end;

procedure TCalmMixerView.SettingsClick(Sender: TObject);
begin
  if Assigned(FOnOpenSettings) then
    FOnOpenSettings(Self);
end;

procedure TCalmMixerView.ChipClick(Sender: TObject);
var
  F: TFavorite;
begin
  if FindPreset(FService.Settings, TCalmChip(Sender).ItemId, F) then
    FService.ApplyPreset(F);
end;

procedure TCalmMixerView.SaveClick(Sender: TObject);
begin
  if FService.HasActiveSounds then
    FService.SaveCurrentAsFavorite('');
end;

function TCalmMixerView.MenuChip: TCalmChip;
begin
  if FPresetMenu.PopupComponent is TCalmChip then
    Result := TCalmChip(FPresetMenu.PopupComponent)
  else
    Result := nil;
end;

procedure TCalmMixerView.PresetMenuPopup(Sender: TObject);
var
  Chip: TCalmChip;
  I: Integer;
  User: Boolean;
begin
  Chip := MenuChip;
  User := Assigned(Chip) and Chip.UserItem;
  for I := 0 to FPresetMenu.Items.Count - 1 do
    if FPresetMenu.Items[I].Tag = 3 then
      FPresetMenu.Items[I].Visible := Assigned(Chip)
    else
      FPresetMenu.Items[I].Visible := User;
  if User then
    FPresetMenu.Items[1].Enabled := FService.HasActiveSounds;
end;

procedure TCalmMixerView.MenuRename(Sender: TObject);
var
  Chip: TCalmChip;
  Name: string;
begin
  Chip := MenuChip;
  if not Assigned(Chip) then
    Exit;
  Name := Chip.Text;
  if InputQuery('Rename mix', 'Name:', Name) and (Trim(Name) <> '') then
    FService.RenameFavorite(Chip.ItemId, Name);
end;

procedure TCalmMixerView.MenuUpdate(Sender: TObject);
var
  Chip: TCalmChip;
begin
  Chip := MenuChip;
  if Assigned(Chip) then
    FService.UpdateFavoriteFromCurrent(Chip.ItemId);
end;

procedure TCalmMixerView.MenuDuplicate(Sender: TObject);
var
  Chip: TCalmChip;
begin
  Chip := MenuChip;
  if Assigned(Chip) then
    FService.DuplicateFavorite(Chip.ItemId);
end;

procedure TCalmMixerView.MenuDelete(Sender: TObject);
var
  Chip: TCalmChip;
begin
  Chip := MenuChip;
  if Assigned(Chip) and
     (MessageDlg(Format('Delete the mix "%s"?', [Chip.Text]), mtConfirmation, [mbYes, mbNo], 0) = mrYes) then
    FService.DeleteFavorite(Chip.ItemId);
end;

end.
