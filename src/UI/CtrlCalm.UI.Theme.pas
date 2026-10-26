unit CtrlCalm.UI.Theme;

{
  Derives the Ctrl+Calm palette from the active (IDE) style so the panel sits
  naturally beside RAD Studio's own tool windows in light and dark themes, and
  falls back to pure system colors under Windows high contrast.
}

interface

uses
  Winapi.Windows, System.SysUtils, Vcl.Graphics, Vcl.Themes, CtrlCalm.Core.Settings;

type
  TCalmPalette = record
    Dark: Boolean;
    HighContrast: Boolean;
    Background: TColor;
    Surface: TColor;
    SurfaceHover: TColor;
    Border: TColor;
    Text: TColor;
    TextMuted: TColor;
    Accent: TColor;
    AccentSoft: TColor;
    AccentText: TColor;
    Track: TColor;
    Focus: TColor;
    Warning: TColor;
  end;

  TStyleServicesProvider = reference to function: TCustomStyleServices;

var
  /// <summary>Set by the IDE adapter to IOTAIDEThemingServices.StyleServices.
  /// Defaults to the application's active VCL style.</summary>
  CalmStyleServicesProvider: TStyleServicesProvider = nil;
  /// <summary>Settings > Appearance > Reduce motion: controls skip hover highlights.</summary>
  CalmReducedMotion: Boolean = False;

function CurrentStyleServices: TCustomStyleServices;
function BuildPalette(Accent: TAccentPalette; FollowIde: Boolean = True): TCalmPalette;
function IsHighContrast: Boolean;
function Blend(A, B: TColor; T: Single): TColor;
function Luminance(C: TColor): Single;
function AccentColor(Accent: TAccentPalette; Dark: Boolean): TColor;

implementation

uses
  System.Math;

function CurrentStyleServices: TCustomStyleServices;
begin
  Result := nil;
  if Assigned(CalmStyleServicesProvider) then
    try
      Result := CalmStyleServicesProvider();
    except
      Result := nil;
    end;
  if Result = nil then
    Result := StyleServices;
end;

function IsHighContrast: Boolean;
var
  HC: THighContrast;
begin
  HC := Default(THighContrast);
  HC.cbSize := SizeOf(HC);
  Result := SystemParametersInfo(SPI_GETHIGHCONTRAST, SizeOf(HC), @HC, 0) and
    (HC.dwFlags and HCF_HIGHCONTRASTON <> 0);
end;

function Blend(A, B: TColor; T: Single): TColor;
var
  CA, CB: Cardinal;
begin
  CA := ColorToRGB(A);
  CB := ColorToRGB(B);
  T := EnsureRange(T, 0, 1);
  Result := RGB(
    Round(GetRValue(CA) + (GetRValue(CB) - GetRValue(CA)) * T),
    Round(GetGValue(CA) + (GetGValue(CB) - GetGValue(CA)) * T),
    Round(GetBValue(CA) + (GetBValue(CB) - GetBValue(CA)) * T));
end;

function Luminance(C: TColor): Single;
var
  V: Cardinal;
begin
  V := ColorToRGB(C);
  Result := (0.2126 * GetRValue(V) + 0.7152 * GetGValue(V) + 0.0722 * GetBValue(V)) / 255;
end;

function AccentColor(Accent: TAccentPalette; Dark: Boolean): TColor;
const
  // Restrained, calm accents. Dark variants are lighter for contrast on dark panels.
  LightSet: array[TAccentPalette] of TColor = (clNone, $005B7D2E, $00827C12, $00A56E3A, $00006AB2, $00A85A6D);
  DarkSet: array[TAccentPalette] of TColor = (clNone, $0097C45C, $00C8C34C, $00E0A87E, $003CA3E8, $00E096A7);
begin
  if Dark then
    Result := DarkSet[Accent]
  else
    Result := LightSet[Accent];
end;

function BuildPalette(Accent: TAccentPalette; FollowIde: Boolean): TCalmPalette;
var
  SS: TCustomStyleServices;
begin
  Result := Default(TCalmPalette);
  Result.HighContrast := IsHighContrast;
  if Result.HighContrast then
  begin
    Result.Background := ColorToRGB(clWindow);
    Result.Text := ColorToRGB(clWindowText);
    Result.Dark := Luminance(Result.Background) < 0.5;
    Result.Surface := Result.Background;
    Result.SurfaceHover := Result.Background;
    Result.Border := Result.Text;
    Result.TextMuted := Result.Text;
    Result.Accent := ColorToRGB(clHighlight);
    Result.AccentSoft := Result.Background;
    Result.AccentText := ColorToRGB(clHighlightText);
    Result.Track := Result.Text;
    Result.Focus := Result.Text;
    Result.Warning := Result.Text;
    Exit;
  end;

  SS := nil;
  if FollowIde then
    SS := CurrentStyleServices;
  if (SS <> nil) and SS.Enabled and not SS.IsSystemStyle then
  begin
    Result.Background := SS.GetSystemColor(clBtnFace);
    Result.Text := SS.GetStyleFontColor(sfPanelTextNormal);
    if Result.Text = clNone then
      Result.Text := SS.GetSystemColor(clWindowText);
  end
  else
  begin
    Result.Background := ColorToRGB(clBtnFace);
    Result.Text := ColorToRGB(clWindowText);
  end;
  Result.Background := ColorToRGB(Result.Background);
  Result.Text := ColorToRGB(Result.Text);
  Result.Dark := Luminance(Result.Background) < 0.5;

  if Result.Dark then
  begin
    Result.Surface := Blend(Result.Background, Result.Text, 0.06);
    Result.SurfaceHover := Blend(Result.Background, Result.Text, 0.11);
    Result.Border := Blend(Result.Background, Result.Text, 0.16);
    Result.Track := Blend(Result.Background, Result.Text, 0.24);
  end
  else
  begin
    Result.Surface := Blend(Result.Background, clWhite, 0.55);
    Result.SurfaceHover := Blend(Result.Background, Result.Text, 0.06);
    Result.Border := Blend(Result.Background, Result.Text, 0.14);
    Result.Track := Blend(Result.Background, Result.Text, 0.2);
  end;
  Result.TextMuted := Blend(Result.Text, Result.Background, 0.42);

  if Accent = apIde then
  begin
    if (SS <> nil) and SS.Enabled and not SS.IsSystemStyle then
      Result.Accent := ColorToRGB(SS.GetSystemColor(clHighlight))
    else
      Result.Accent := ColorToRGB(clHighlight);
  end
  else
    Result.Accent := AccentColor(Accent, Result.Dark);
  Result.AccentSoft := Blend(Result.Surface, Result.Accent, IfThen(Result.Dark, 0.2, 0.13));
  if Luminance(Result.Accent) > 0.55 then
    Result.AccentText := $00202020
  else
    Result.AccentText := clWhite;
  Result.Focus := Result.Accent;
  Result.Warning := IfThen(Result.Dark, $004DB8F0, $00006CC8);
end;

end.
