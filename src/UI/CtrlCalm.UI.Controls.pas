unit CtrlCalm.UI.Controls;

{ Reusable custom-painted VCL controls: slider, icon button, chip and the
  sound tile. All metrics are in 96-DPI units and scaled with CurrentPPI. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.Math, Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.Menus,
  CtrlCalm.Core.Types, CtrlCalm.Core.Settings, CtrlCalm.UI.Theme, CtrlCalm.UI.Icons;

type
  TCalmControl = class(TCustomControl)
  private
    FPalette: TCalmPalette;
    FBackColor: TColor;
    FHover: Boolean;
    FPressed: Boolean;
    procedure CMMouseEnter(var Msg: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
    procedure CMEnabledChanged(var Msg: TMessage); message CM_ENABLEDCHANGED;
    procedure WMEraseBkgnd(var Msg: TWMEraseBkgnd); message WM_ERASEBKGND;
  protected
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure HoverChanged; virtual;
    function S(V: Integer): Integer; inline;
    function SF(V: Single): Single; inline;
    procedure PaintBackground(const R: TRect);
    procedure DrawFocusRing(const R: TRect; Radius: Single);
    procedure DrawTextIn(const Text: string; R: TRect; Color: TColor; Flags: Cardinal;
      Size: Integer = 0; Bold: Boolean = False);
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetPalette(const P: TCalmPalette); virtual;
    property Palette: TCalmPalette read FPalette;
    property Hover: Boolean read FHover;
    property Pressed: Boolean read FPressed write FPressed;
    /// <summary>Color behind the control's rounded shape; clNone uses the
    /// palette background. Set it when the parent paints a different surface.</summary>
    property BackColor: TColor read FBackColor write FBackColor;
  end;

  TCalmSlider = class(TCalmControl)
  private
    FValue: Single;
    FDragging: Boolean;
    FOnChange: TNotifyEvent;
    FAccessibleName: string;
    procedure SetValue(V: Single);
    function TrackRect: TRect;
    function ValueFromX(X: Integer): Single;
    procedure WMGetDlgCode(var Msg: TWMGetDlgCode); message WM_GETDLGCODE;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure ChangeValue(V: Single);
  public
    constructor Create(AOwner: TComponent); override;
    property Value: Single read FValue write SetValue;
    property AccessibleName: string read FAccessibleName write FAccessibleName;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  TCalmButtonKind = (bkGhost, bkPrimary, bkOutline);

  TCalmIconButton = class(TCalmControl)
  private
    FGlyph: TCalmGlyph;
    FKind: TCalmButtonKind;
    FChecked: Boolean;
    FCaptionText: string;
    FGlyphScale: Single;
    procedure SetGlyph(G: TCalmGlyph);
    procedure SetChecked(V: Boolean);
    procedure SetCaptionText(const V: string);
    procedure SetKind(V: TCalmButtonKind);
    procedure WMGetDlgCode(var Msg: TWMGetDlgCode); message WM_GETDLGCODE;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    /// <summary>Preferred width for the current caption at the current DPI.</summary>
    function PreferredWidth: Integer;
    property Glyph: TCalmGlyph read FGlyph write SetGlyph;
    property Kind: TCalmButtonKind read FKind write SetKind;
    property Checked: Boolean read FChecked write SetChecked;
    property CaptionText: string read FCaptionText write SetCaptionText;
    property GlyphScale: Single read FGlyphScale write FGlyphScale;
    property OnClick;
    property PopupMenu;
  end;

  TCalmChip = class(TCalmControl)
  private
    FSelected: Boolean;
    FText: string;
    FDotColor: TColor;
    FUserItem: Boolean;
    FTag2: string;
    procedure SetSelected(V: Boolean);
    procedure SetText(const V: string);
    procedure WMGetDlgCode(var Msg: TWMGetDlgCode); message WM_GETDLGCODE;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    function PreferredWidth: Integer;
    property Selected: Boolean read FSelected write SetSelected;
    property Text: string read FText write SetText;
    property DotColor: TColor read FDotColor write FDotColor;
    property UserItem: Boolean read FUserItem write FUserItem;
    property ItemId: string read FTag2 write FTag2;
    property OnClick;
    property PopupMenu;
  end;

  TTileStyle = (tsRow, tsCard);

  TSoundTileEvent = procedure(Sender: TObject; Id: TSoundId) of object;
  TSoundVolumeEvent = procedure(Sender: TObject; Id: TSoundId; Volume: Single) of object;

  /// <summary>One sound: click the body to toggle, drag the bottom (card) or
  /// right (row) slider zone to set its level. Space/Enter toggles, arrow keys
  /// change the level. State is shown by fill, border, a check mark and the
  /// visible slider, never by color alone.</summary>
  TCalmSoundTile = class(TCalmControl)
  private
    FSound: TSoundId;
    FActive: Boolean;
    FArmed: Boolean;          // active but globally paused
    FUnavailable: Boolean;
    FReason: string;
    FVolume: Single;
    FStyle: TTileStyle;
    FDragging: Boolean;
    FDownInSlider: Boolean;
    FOnToggle: TSoundTileEvent;
    FOnVolume: TSoundVolumeEvent;
    function SliderRect: TRect;
    function SliderTrack: TRect;
    function IconRect: TRect;
    procedure SetVolumeFromX(X: Integer);
    procedure UpdateHint;
    procedure WMGetDlgCode(var Msg: TWMGetDlgCode); message WM_GETDLGCODE;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure ChangeVolume(V: Single);
  public
    constructor Create(AOwner: TComponent; ASound: TSoundId); reintroduce;
    procedure SetState(AActive, AArmed, AUnavailable: Boolean; const AReason: string; AVolume: Single);
    property Sound: TSoundId read FSound;
    property Active: Boolean read FActive;
    property Volume: Single read FVolume;
    property Style: TTileStyle read FStyle write FStyle;
    property OnToggle: TSoundTileEvent read FOnToggle write FOnToggle;
    property OnVolume: TSoundVolumeEvent read FOnVolume write FOnVolume;
  end;

/// <summary>Preferred UI font for Ctrl+Calm text (Segoe UI Variable/Segoe UI
/// ship with every supported Windows version).</summary>
function CalmFontName: string;

implementation

var
  GFontName: string;

function CalmFontName: string;
begin
  if GFontName = '' then
  begin
    if Screen.Fonts.IndexOf('Segoe UI Variable Text') >= 0 then
      GFontName := 'Segoe UI Variable Text'
    else
      GFontName := 'Segoe UI';
  end;
  Result := GFontName;
end;

{ TCalmControl }

constructor TCalmControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque] - [csParentBackground];
  DoubleBuffered := True;
  ParentShowHint := False;
  ShowHint := True;
  FPalette := BuildPalette(apForest);
  FBackColor := clNone;
end;

function TCalmControl.S(V: Integer): Integer;
begin
  Result := MulDiv(V, CurrentPPI, 96);
end;

function TCalmControl.SF(V: Single): Single;
begin
  Result := V * CurrentPPI / 96;
end;

procedure TCalmControl.SetPalette(const P: TCalmPalette);
begin
  FPalette := P;
  Invalidate;
end;

procedure TCalmControl.CMMouseEnter(var Msg: TMessage);
begin
  inherited;
  if not FHover and not CalmReducedMotion then
  begin
    FHover := True;
    HoverChanged;
  end;
end;

procedure TCalmControl.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  if FHover then
  begin
    FHover := False;
    FPressed := False;
    HoverChanged;
  end;
end;

procedure TCalmControl.CMEnabledChanged(var Msg: TMessage);
begin
  inherited;
  Invalidate;
end;

procedure TCalmControl.WMEraseBkgnd(var Msg: TWMEraseBkgnd);
begin
  Msg.Result := 1; // everything is painted in Paint (double buffered)
end;

procedure TCalmControl.HoverChanged;
begin
  Invalidate;
end;

procedure TCalmControl.DoEnter;
begin
  inherited;
  Invalidate;
end;

procedure TCalmControl.DoExit;
begin
  inherited;
  Invalidate;
end;

procedure TCalmControl.PaintBackground(const R: TRect);
begin
  Canvas.Brush.Style := bsSolid;
  if FBackColor <> clNone then
    Canvas.Brush.Color := FBackColor
  else
    Canvas.Brush.Color := FPalette.Background;
  Canvas.FillRect(R);
end;

procedure TCalmControl.DrawFocusRing(const R: TRect; Radius: Single);
begin
  if Focused and Enabled then
    FillRoundRect(Canvas.Handle, R, Radius, clNone, FPalette.Focus, SF(2));
end;

procedure TCalmControl.DrawTextIn(const Text: string; R: TRect; Color: TColor; Flags: Cardinal;
  Size: Integer; Bold: Boolean);
begin
  Canvas.Font.Name := CalmFontName;
  if Size = 0 then
    Size := 9;
  Canvas.Font.Height := -MulDiv(Size, CurrentPPI, 72);
  if Bold then
    Canvas.Font.Style := [fsBold]
  else
    Canvas.Font.Style := [];
  Canvas.Font.Color := Color;
  Canvas.Brush.Style := bsClear;
  Winapi.Windows.DrawText(Canvas.Handle, PChar(Text), Length(Text), R,
    Flags or DT_NOPREFIX or DT_END_ELLIPSIS);
end;

{ TCalmSlider }

constructor TCalmSlider.Create(AOwner: TComponent);
begin
  inherited;
  TabStop := True;
  Width := 120;
  Height := 24;
  FValue := 0.5;
end;

procedure TCalmSlider.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  Msg.Result := DLGC_WANTARROWS;
end;

procedure TCalmSlider.SetValue(V: Single);
begin
  V := ClampVolume(V);
  if V <> FValue then
  begin
    FValue := V;
    Invalidate;
  end;
end;

procedure TCalmSlider.ChangeValue(V: Single);
begin
  V := ClampVolume(V);
  if Abs(V - FValue) < 0.0001 then
    Exit;
  FValue := V;
  Hint := Format('%s: %d%%', [FAccessibleName, Round(V * 100)]);
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TCalmSlider.TrackRect: TRect;
var
  Pad: Integer;
begin
  Pad := S(8);
  Result := Rect(Pad, Height div 2 - S(2), Width - Pad, Height div 2 + S(2));
end;

function TCalmSlider.ValueFromX(X: Integer): Single;
var
  T: TRect;
begin
  T := TrackRect;
  if T.Width <= 0 then
    Exit(FValue);
  Result := ClampVolume((X - T.Left) / T.Width);
end;

procedure TCalmSlider.Paint;
var
  T, Fill: TRect;
  CX: Integer;
  R: Single;
  Active: TColor;
begin
  PaintBackground(ClientRect);
  T := TrackRect;
  Active := IfThen(Enabled, FPalette.Accent, FPalette.TextMuted);
  FillRoundRect(Canvas.Handle, T, T.Height / 2, FPalette.Track);
  CX := T.Left + Round(T.Width * FValue);
  Fill := Rect(T.Left, T.Top, CX, T.Bottom);
  if Fill.Width > 0 then
    FillRoundRect(Canvas.Handle, Fill, T.Height / 2, Active);
  R := SF(IfThen(Hover or FDragging or Focused, 7, 6));
  FillCircle(Canvas.Handle, CX, Height / 2, R + SF(1.5), FPalette.Background);
  FillCircle(Canvas.Handle, CX, Height / 2, R, Active);
  if Focused then
    FillRoundRect(Canvas.Handle, Rect(Round(CX - R - SF(3.5)), Round(Height / 2 - R - SF(3.5)),
      Round(CX + R + SF(3.5)), Round(Height / 2 + R + SF(3.5))), R + SF(3.5), clNone, FPalette.Focus, SF(1.5));
end;

procedure TCalmSlider.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if (Button = mbLeft) and Enabled then
  begin
    if CanFocus then
      SetFocus;
    FDragging := True;
    ChangeValue(ValueFromX(X));
  end;
end;

procedure TCalmSlider.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FDragging then
    ChangeValue(ValueFromX(X));
end;

procedure TCalmSlider.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FDragging then
  begin
    FDragging := False;
    Invalidate;
  end;
end;

function TCalmSlider.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if Enabled then
    ChangeValue(FValue + Sign(WheelDelta) * 0.05);
end;

procedure TCalmSlider.KeyDown(var Key: Word; Shift: TShiftState);
var
  Step: Single;
begin
  inherited;
  Step := IfThen(ssShift in Shift, 0.1, 0.02);
  case Key of
    VK_LEFT, VK_DOWN: ChangeValue(FValue - Step);
    VK_RIGHT, VK_UP: ChangeValue(FValue + Step);
    VK_PRIOR: ChangeValue(FValue + 0.1);
    VK_NEXT: ChangeValue(FValue - 0.1);
    VK_HOME: ChangeValue(0);
    VK_END: ChangeValue(1);
  else
    Exit;
  end;
  Key := 0;
end;

{ TCalmIconButton }

constructor TCalmIconButton.Create(AOwner: TComponent);
begin
  inherited;
  TabStop := True;
  Width := 32;
  Height := 32;
  FGlyphScale := 0.6;
end;

procedure TCalmIconButton.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  Msg.Result := 0;
end;

procedure TCalmIconButton.SetGlyph(G: TCalmGlyph);
begin
  if G <> FGlyph then
  begin
    FGlyph := G;
    Invalidate;
  end;
end;

procedure TCalmIconButton.SetChecked(V: Boolean);
begin
  if V <> FChecked then
  begin
    FChecked := V;
    Invalidate;
  end;
end;

procedure TCalmIconButton.SetCaptionText(const V: string);
begin
  if V <> FCaptionText then
  begin
    FCaptionText := V;
    Invalidate;
  end;
end;

procedure TCalmIconButton.SetKind(V: TCalmButtonKind);
begin
  FKind := V;
  Invalidate;
end;

function TCalmIconButton.PreferredWidth: Integer;
begin
  if FCaptionText = '' then
    Exit(Height);
  Canvas.Font.Name := CalmFontName;
  Canvas.Font.Height := -MulDiv(9, CurrentPPI, 72);
  Canvas.Font.Style := [];
  Result := Height + Canvas.TextWidth(FCaptionText) + S(10);
end;

procedure TCalmIconButton.Paint;
var
  R, GR, TR: TRect;
  Fg, Bg, Bd: TColor;
  Radius: Single;
  GS: Integer;
begin
  PaintBackground(ClientRect);
  R := ClientRect;
  InflateRect(R, -S(1), -S(1));
  Radius := IfThen(FCaptionText = '', Min(R.Width, R.Height) / 2, SF(8));
  Bg := clNone;
  Bd := clNone;
  Fg := FPalette.Text;
  case FKind of
    bkPrimary:
      begin
        Bg := FPalette.Accent;
        if Pressed then
          Bg := Blend(Bg, FPalette.Background, 0.25)
        else if Hover then
          Bg := Blend(Bg, FPalette.Text, 0.12);
        Fg := FPalette.AccentText;
      end;
    bkOutline:
      begin
        Bd := FPalette.Border;
        if Hover then
          Bg := FPalette.SurfaceHover;
        if FChecked then
        begin
          Bg := FPalette.AccentSoft;
          Bd := FPalette.Accent;
        end;
      end;
  else
    if FChecked then
      Bg := FPalette.AccentSoft
    else if Pressed then
      Bg := FPalette.Border
    else if Hover then
      Bg := FPalette.SurfaceHover;
    if FChecked then
      Fg := FPalette.Accent;
  end;
  if not Enabled then
    Fg := FPalette.TextMuted;
  if (Bg <> clNone) or (Bd <> clNone) then
    FillRoundRect(Canvas.Handle, R, Radius, Bg, Bd, SF(1));
  GS := Round(Min(R.Width, R.Height) * FGlyphScale);
  if FCaptionText = '' then
    GR := Rect(R.Left + (R.Width - GS) div 2, R.Top + (R.Height - GS) div 2, 0, 0)
  else
    GR := Rect(R.Left + S(8), R.Top + (R.Height - GS) div 2, 0, 0);
  GR.Right := GR.Left + GS;
  GR.Bottom := GR.Top + GS;
  DrawGlyph(Canvas.Handle, FGlyph, GR, Fg);
  if FCaptionText <> '' then
  begin
    TR := Rect(GR.Right + S(6), R.Top, R.Right - S(6), R.Bottom);
    DrawTextIn(FCaptionText, TR, Fg, DT_SINGLELINE or DT_VCENTER or DT_LEFT);
  end;
  DrawFocusRing(R, Radius);
end;

procedure TCalmIconButton.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
  begin
    Pressed := True;
    Invalidate;
  end;
end;

procedure TCalmIconButton.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  WasPressed: Boolean;
begin
  WasPressed := Pressed;
  Pressed := False;
  Invalidate;
  inherited; // csClickEvents fires OnClick
  if WasPressed then ;
end;

procedure TCalmIconButton.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited;
  if (Key in [VK_SPACE, VK_RETURN]) and Enabled then
  begin
    Key := 0;
    Click;
  end;
end;

{ TCalmChip }

constructor TCalmChip.Create(AOwner: TComponent);
begin
  inherited;
  TabStop := True;
  Height := 26;
  Width := 80;
  FDotColor := clNone;
end;

procedure TCalmChip.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  Msg.Result := 0;
end;

procedure TCalmChip.SetSelected(V: Boolean);
begin
  if V <> FSelected then
  begin
    FSelected := V;
    Invalidate;
  end;
end;

procedure TCalmChip.SetText(const V: string);
begin
  FText := V;
  Hint := V;
  Invalidate;
end;

function TCalmChip.PreferredWidth: Integer;
begin
  // Measured bold so the chip does not need to grow when it becomes selected.
  Canvas.Font.Name := CalmFontName;
  Canvas.Font.Height := -MulDiv(9, CurrentPPI, 72);
  Canvas.Font.Style := [fsBold];
  Result := Canvas.TextWidth(FText) + S(24);
  if (FDotColor <> clNone) or FUserItem then
    Inc(Result, S(12));
end;

procedure TCalmChip.Paint;
var
  R, TR, GR: TRect;
  Bg, Bd, Fg: TColor;
begin
  PaintBackground(ClientRect);
  R := ClientRect;
  InflateRect(R, -S(1), -S(1));
  Fg := FPalette.Text;
  Bd := FPalette.Border;
  Bg := FPalette.Surface;
  if FSelected then
  begin
    Bg := FPalette.AccentSoft;
    Bd := FPalette.Accent;
  end
  else if Pressed then
    Bg := FPalette.Border
  else if Hover then
    Bg := FPalette.SurfaceHover;
  FillRoundRect(Canvas.Handle, R, R.Height / 2, Bg, Bd, SF(IfThen(FSelected, 1.5, 1)));
  TR := Rect(R.Left + S(10), R.Top, R.Right - S(10), R.Bottom);
  if FUserItem then
  begin
    GR := Rect(TR.Left - S(2), R.Top + (R.Height - S(12)) div 2, TR.Left + S(10), 0);
    GR.Bottom := GR.Top + S(12);
    DrawGlyph(Canvas.Handle, cgStar, GR, IfThen(FSelected, FPalette.Accent, FPalette.TextMuted), 0.9);
    Inc(TR.Left, S(12));
  end
  else if FDotColor <> clNone then
  begin
    FillCircle(Canvas.Handle, TR.Left + SF(3), R.Top + R.Height / 2, SF(3), FDotColor);
    Inc(TR.Left, S(12));
  end;
  DrawTextIn(FText, TR, Fg, DT_SINGLELINE or DT_VCENTER or DT_CENTER, 9, FSelected);
  DrawFocusRing(R, R.Height / 2);
end;

procedure TCalmChip.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
  begin
    Pressed := True;
    Invalidate;
  end;
end;

procedure TCalmChip.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  Pressed := False;
  Invalidate;
  inherited;
end;

procedure TCalmChip.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited;
  if Key in [VK_SPACE, VK_RETURN] then
  begin
    Key := 0;
    Click;
  end
  else if (Key = VK_APPS) or ((Key = VK_F10) and (ssShift in Shift)) then
  begin
    Key := 0;
    if Assigned(PopupMenu) then
    begin
      PopupMenu.PopupComponent := Self;
      with ClientToScreen(Point(0, Height)) do
        PopupMenu.Popup(X, Y);
    end;
  end;
end;

{ TCalmSoundTile }

constructor TCalmSoundTile.Create(AOwner: TComponent; ASound: TSoundId);
begin
  inherited Create(AOwner);
  FSound := ASound;
  FVolume := DefaultSoundVolume;
  TabStop := True;
  Width := 132;
  Height := 108;
  FStyle := tsCard;
  UpdateHint;
end;

procedure TCalmSoundTile.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  Msg.Result := DLGC_WANTARROWS;
end;

procedure TCalmSoundTile.UpdateHint;
var
  Def: TSoundDefinition;
begin
  Def := SoundDef(FSound);
  if FUnavailable then
    Hint := Def.Name + ' - unavailable' + sLineBreak + FReason
  else if FActive then
    Hint := Format('%s - %d%%%s%s', [Def.Name, Round(FVolume * 100), sLineBreak,
      'Click to stop. Drag the bar or use the arrow keys to change the level.'])
  else
    Hint := Def.Name + ' - ' + Def.Description + sLineBreak + 'Click to play.';
end;

procedure TCalmSoundTile.SetState(AActive, AArmed, AUnavailable: Boolean; const AReason: string;
  AVolume: Single);
begin
  if FDragging then
    AVolume := FVolume; // never fight the user's drag
  if (AActive = FActive) and (AArmed = FArmed) and (AUnavailable = FUnavailable) and
     (AReason = FReason) and (Abs(AVolume - FVolume) < 0.0005) then
    Exit;
  FActive := AActive;
  FArmed := AArmed;
  FUnavailable := AUnavailable;
  FReason := AReason;
  FVolume := AVolume;
  UpdateHint;
  Invalidate;
end;

function TCalmSoundTile.IconRect: TRect;
var
  Sz: Integer;
begin
  if FStyle = tsCard then
  begin
    Sz := Min(S(34), Height div 3);
    Result := Rect((Width - Sz) div 2, S(14), 0, 0);
  end
  else
  begin
    Sz := Min(S(22), Height - S(12));
    Result := Rect(S(12), (Height - Sz) div 2, 0, 0);
  end;
  Result.Right := Result.Left + Sz;
  Result.Bottom := Result.Top + Sz;
end;

function TCalmSoundTile.SliderRect: TRect;
begin
  if FStyle = tsCard then
    Result := Rect(S(10), Height - S(26), Width - S(10), Height - S(6))
  else
    Result := Rect(Width - Max(S(70), Width * 2 div 5) - S(8), 0, Width - S(8), Height);
end;

function TCalmSoundTile.SliderTrack: TRect;
var
  R: TRect;
begin
  R := SliderRect;
  Result := Rect(R.Left + S(6), (R.Top + R.Bottom) div 2 - S(2), R.Right - S(6),
    (R.Top + R.Bottom) div 2 + S(2));
end;

procedure TCalmSoundTile.Paint;
var
  R, IR, NR, T, Fill: TRect;
  Bg, Bd, Fg, IconColor: TColor;
  Def: TSoundDefinition;
  CX: Integer;
  BW, Radius: Single;
  Label_: string;
begin
  PaintBackground(ClientRect);
  Def := SoundDef(FSound);
  R := ClientRect;
  InflateRect(R, -S(2), -S(2));
  Radius := SF(10);
  Bg := FPalette.Surface;
  Bd := FPalette.Border;
  BW := 1;
  Fg := FPalette.Text;
  IconColor := FPalette.TextMuted;
  if FUnavailable then
  begin
    Fg := FPalette.TextMuted;
    IconColor := Blend(FPalette.TextMuted, FPalette.Background, 0.4);
  end
  else if FActive then
  begin
    Bg := FPalette.AccentSoft;
    Bd := FPalette.Accent;
    BW := IfThen(FArmed, 1, 1.5);
    IconColor := FPalette.Accent;
    if FArmed then
      Bg := FPalette.Surface;
  end;
  if Hover and not FUnavailable then
    Bg := Blend(Bg, FPalette.Text, IfThen(FPalette.Dark, 0.05, 0.04));
  FillRoundRect(Canvas.Handle, R, Radius, Bg, Bd, SF(BW));

  IR := IconRect;
  DrawSoundIcon(Canvas.Handle, FSound, IR, IconColor);

  Label_ := Def.Name;
  if FStyle = tsCard then
  begin
    NR := Rect(R.Left + S(6), IR.Bottom + S(6), R.Right - S(6), IR.Bottom + S(26));
    DrawTextIn(Label_, NR, Fg, DT_SINGLELINE or DT_CENTER or DT_VCENTER, 9, FActive);
  end
  else
  begin
    NR := Rect(IR.Right + S(10), R.Top, SliderRect.Left - S(4), R.Bottom);
    DrawTextIn(Label_, NR, Fg, DT_SINGLELINE or DT_LEFT or DT_VCENTER, 9, FActive);
  end;

  // Status mark (not color-only): check when playing, pause bars when armed,
  // warning when unavailable.
  if FUnavailable then
    DrawGlyph(Canvas.Handle, cgWarning, Rect(R.Right - S(20), R.Top + S(6), R.Right - S(6), R.Top + S(20)),
      FPalette.Warning)
  else if FActive then
  begin
    if FArmed then
      DrawGlyph(Canvas.Handle, cgPause, Rect(R.Right - S(18), R.Top + S(6), R.Right - S(6), R.Top + S(18)),
        FPalette.TextMuted)
    else
      DrawGlyph(Canvas.Handle, cgCheck, Rect(R.Right - S(19), R.Top + S(5), R.Right - S(5), R.Top + S(19)),
        FPalette.Accent, 1.2);
  end;

  // Level bar: only for active sounds, so idle tiles stay quiet.
  if FActive and not FUnavailable then
  begin
    T := SliderTrack;
    FillRoundRect(Canvas.Handle, T, T.Height / 2, FPalette.Track);
    CX := T.Left + Round(T.Width * FVolume);
    Fill := Rect(T.Left, T.Top, CX, T.Bottom);
    if Fill.Width > 0 then
      FillRoundRect(Canvas.Handle, Fill, T.Height / 2, IfThen(FArmed, FPalette.TextMuted, FPalette.Accent));
    FillCircle(Canvas.Handle, CX, (T.Top + T.Bottom) / 2, SF(IfThen(FDragging or Hover, 6.5, 5.5)) + SF(1.5),
      Bg);
    FillCircle(Canvas.Handle, CX, (T.Top + T.Bottom) / 2, SF(IfThen(FDragging or Hover, 6.5, 5.5)),
      IfThen(FArmed, FPalette.TextMuted, FPalette.Accent));
  end
  else if (FStyle = tsCard) and not FUnavailable and Hover then
  begin
    NR := Rect(R.Left, Height - S(26), R.Right, Height - S(6));
    DrawTextIn('Click to play', NR, FPalette.TextMuted, DT_SINGLELINE or DT_CENTER or DT_VCENTER, 8);
  end
  else if FUnavailable and (FStyle = tsCard) then
  begin
    NR := Rect(R.Left, Height - S(26), R.Right, Height - S(6));
    DrawTextIn('Unavailable', NR, FPalette.TextMuted, DT_SINGLELINE or DT_CENTER or DT_VCENTER, 8);
  end;

  if Focused then
  begin
    InflateRect(R, -S(2), -S(2));
    FillRoundRect(Canvas.Handle, R, Radius - SF(2), clNone, FPalette.Focus, SF(1.5));
  end;
end;

procedure TCalmSoundTile.SetVolumeFromX(X: Integer);
var
  T: TRect;
begin
  T := SliderTrack;
  if T.Width > 0 then
    ChangeVolume((X - T.Left) / T.Width);
end;

procedure TCalmSoundTile.ChangeVolume(V: Single);
begin
  V := ClampVolume(V);
  if Abs(V - FVolume) < 0.0001 then
    Exit;
  FVolume := V;
  UpdateHint;
  Invalidate;
  if Assigned(FOnVolume) then
    FOnVolume(Self, FSound, V);
end;

procedure TCalmSoundTile.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button <> mbLeft then
    Exit;
  if CanFocus then
    SetFocus;
  FDownInSlider := FActive and PtInRect(SliderRect, Point(X, Y));
  if FDownInSlider then
  begin
    FDragging := True;
    SetVolumeFromX(X);
  end
  else
  begin
    Pressed := True;
    Invalidate;
  end;
end;

procedure TCalmSoundTile.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FDragging then
    SetVolumeFromX(X);
end;

procedure TCalmSoundTile.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  WasPressed: Boolean;
begin
  inherited;
  if Button <> mbLeft then
    Exit;
  WasPressed := Pressed;
  Pressed := False;
  if FDragging then
  begin
    FDragging := False;
    Invalidate;
    Exit;
  end;
  Invalidate;
  if WasPressed and PtInRect(ClientRect, Point(X, Y)) and Assigned(FOnToggle) then
    FOnToggle(Self, FSound);
end;

function TCalmSoundTile.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  // Only adjust when the pointer is over an active tile; otherwise let the
  // scroll box scroll.
  Result := False;
  if FActive and Hover then
  begin
    ChangeVolume(FVolume + Sign(WheelDelta) * 0.05);
    Result := True;
  end;
end;

procedure TCalmSoundTile.KeyDown(var Key: Word; Shift: TShiftState);
var
  Step: Single;
begin
  inherited;
  Step := IfThen(ssShift in Shift, 0.1, 0.05);
  case Key of
    VK_SPACE, VK_RETURN:
      if Assigned(FOnToggle) then
        FOnToggle(Self, FSound);
    VK_LEFT, VK_DOWN:
      if FActive then ChangeVolume(FVolume - Step) else Exit;
    VK_RIGHT, VK_UP:
      if FActive then ChangeVolume(FVolume + Step) else Exit;
  else
    Exit;
  end;
  Key := 0;
end;

end.
