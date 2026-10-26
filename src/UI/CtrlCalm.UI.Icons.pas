unit CtrlCalm.UI.Icons;

{
  Original Ctrl+Calm line icons, drawn as vectors with GDI+ (a Windows system
  component) so they stay crisp at every DPI. Each icon is designed on a
  24 x 24 grid with round caps and joins and a 1.6-unit stroke, then scaled to
  the target rectangle. No bitmaps, fonts or image libraries are involved.
}

interface

uses
  Winapi.Windows, System.Types, Vcl.Graphics, CtrlCalm.Core.Types;

type
  TCalmGlyph = (cgPlay, cgPause, cgStop, cgTimer, cgSettings, cgPlus, cgSpeaker,
    cgSpeakerMuted, cgStar, cgMore, cgReset, cgClose, cgChevronDown, cgChevronUp,
    cgLogo, cgCheck, cgWarning);

procedure DrawSoundIcon(DC: HDC; Id: TSoundId; const R: TRect; Color: TColor;
  StrokeScale: Single = 1.0);
procedure DrawGlyph(DC: HDC; Glyph: TCalmGlyph; const R: TRect; Color: TColor;
  StrokeScale: Single = 1.0);

/// <summary>Anti-aliased rounded rectangle fill and optional outline.</summary>
procedure FillRoundRect(DC: HDC; const R: TRect; Radius: Single; Fill: TColor;
  Border: TColor = clNone; BorderWidth: Single = 1.0; FillAlpha: Byte = 255);
procedure FillCircle(DC: HDC; CX, CY, Radius: Single; Fill: TColor; Alpha: Byte = 255);

implementation

uses
  System.SysUtils, System.Math, Winapi.GDIPAPI, Winapi.GDIPOBJ;

type
  TPainter = class
  private
    G: TGPGraphics;
    Pen: TGPPen;
    Brush: TGPSolidBrush;
    Color: TGPColor;
  public
    constructor Create(DC: HDC; const R: TRect; AColor: TColor; StrokeScale: Single);
    destructor Destroy; override;
    procedure Line(X1, Y1, X2, Y2: Single);
    procedure Lines(const P: array of Single);
    procedure Polygon(const P: array of Single; Filled: Boolean = False);
    procedure Arc(CX, CY, RX, RY, StartDeg, SweepDeg: Single);
    procedure Circle(CX, CY, R: Single; Filled: Boolean = False);
    procedure Bezier(X1, Y1, CX1, CY1, CX2, CY2, X2, Y2: Single);
    procedure Path(const Build: TProc<TGPGraphicsPath>; Filled: Boolean = False);
    procedure RoundRect(X, Y, W, H, Rad: Single; Filled: Boolean = False);
  end;

function GPColor(C: TColor; Alpha: Byte = 255): TGPColor;
var
  RGB: Cardinal;
begin
  RGB := ColorToRGB(C);
  Result := MakeColor(Alpha, GetRValue(RGB), GetGValue(RGB), GetBValue(RGB));
end;

{ TPainter }

constructor TPainter.Create(DC: HDC; const R: TRect; AColor: TColor; StrokeScale: Single);
var
  Size, Scale: Single;
begin
  inherited Create;
  G := TGPGraphics.Create(DC);
  G.SetSmoothingMode(SmoothingModeAntiAlias);
  G.SetPixelOffsetMode(PixelOffsetModeHalf);
  Size := Min(R.Width, R.Height);
  Scale := Size / 24;
  G.TranslateTransform(R.Left + (R.Width - Size) / 2, R.Top + (R.Height - Size) / 2);
  G.ScaleTransform(Scale, Scale);
  Color := GPColor(AColor);
  // Slightly heavier strokes at small sizes keep icons legible.
  Pen := TGPPen.Create(Color, IfThen(Size < 20, 1.9, 1.6) * StrokeScale);
  Pen.SetLineCap(LineCapRound, LineCapRound, DashCapRound);
  Pen.SetLineJoin(LineJoinRound);
  Brush := TGPSolidBrush.Create(Color);
end;

destructor TPainter.Destroy;
begin
  Brush.Free;
  Pen.Free;
  G.Free;
  inherited;
end;

procedure TPainter.Line(X1, Y1, X2, Y2: Single);
begin
  G.DrawLine(Pen, X1, Y1, X2, Y2);
end;

procedure TPainter.Lines(const P: array of Single);
var
  Pts: array of TGPPointF;
  I: Integer;
begin
  SetLength(Pts, Length(P) div 2);
  for I := 0 to High(Pts) do
    Pts[I] := MakePoint(P[I * 2], P[I * 2 + 1]);
  G.DrawLines(Pen, PGPPointF(@Pts[0]), Length(Pts));
end;

procedure TPainter.Polygon(const P: array of Single; Filled: Boolean);
var
  Pts: array of TGPPointF;
  I: Integer;
begin
  SetLength(Pts, Length(P) div 2);
  for I := 0 to High(Pts) do
    Pts[I] := MakePoint(P[I * 2], P[I * 2 + 1]);
  if Filled then
    G.FillPolygon(Brush, PGPPointF(@Pts[0]), Length(Pts));
  G.DrawPolygon(Pen, PGPPointF(@Pts[0]), Length(Pts));
end;

procedure TPainter.Arc(CX, CY, RX, RY, StartDeg, SweepDeg: Single);
begin
  G.DrawArc(Pen, CX - RX, CY - RY, RX * 2, RY * 2, StartDeg, SweepDeg);
end;

procedure TPainter.Circle(CX, CY, R: Single; Filled: Boolean);
begin
  if Filled then
    G.FillEllipse(Brush, CX - R, CY - R, R * 2, R * 2)
  else
    G.DrawEllipse(Pen, CX - R, CY - R, R * 2, R * 2);
end;

procedure TPainter.Bezier(X1, Y1, CX1, CY1, CX2, CY2, X2, Y2: Single);
begin
  G.DrawBezier(Pen, X1, Y1, CX1, CY1, CX2, CY2, X2, Y2);
end;

procedure TPainter.Path(const Build: TProc<TGPGraphicsPath>; Filled: Boolean);
var
  P: TGPGraphicsPath;
begin
  P := TGPGraphicsPath.Create;
  try
    Build(P);
    if Filled then
      G.FillPath(Brush, P);
    G.DrawPath(Pen, P);
  finally
    P.Free;
  end;
end;

procedure TPainter.RoundRect(X, Y, W, H, Rad: Single; Filled: Boolean);
begin
  Path(
    procedure(P: TGPGraphicsPath)
    var
      D: Single;
    begin
      D := Rad * 2;
      P.AddArc(X, Y, D, D, 180, 90);
      P.AddArc(X + W - D, Y, D, D, 270, 90);
      P.AddArc(X + W - D, Y + H - D, D, D, 0, 90);
      P.AddArc(X, Y + H - D, D, D, 90, 90);
      P.CloseFigure;
    end, Filled);
end;

{ Shared shapes }

procedure Cloud(P: TPainter; DY: Single);
begin
  // A cloud built from three arcs and a flat base.
  P.Path(
    procedure(Path: TGPGraphicsPath)
    begin
      Path.AddArc(3.5, 7.5 + DY, 7.0, 7.0, 90, 180);    // left lobe
      Path.AddArc(7.5, 3.5 + DY, 9.0, 9.0, 200, 160);   // top lobe
      Path.AddArc(13.5, 6.5 + DY, 7.0, 7.0, 270, 180);  // right lobe
      Path.CloseFigure;
    end);
end;

procedure FanBlade(P: TPainter; A: Single);
var
  C, S: Single;
  Path: TGPGraphicsPath;

  function X(PX, PY: Single): Single;
  begin
    Result := 12 + PX * C - PY * S;
  end;

  function Y(PX, PY: Single): Single;
  begin
    Result := 10 + PX * S + PY * C;
  end;

begin
  C := Cos(A);
  S := Sin(A);
  Path := TGPGraphicsPath.Create;
  try
    Path.AddBezier(X(1.4, 0), Y(1.4, 0), X(3, -2.5), Y(3, -2.5), X(6, -2), Y(6, -2), X(6.2, 0), Y(6.2, 0));
    Path.AddBezier(X(6.2, 0), Y(6.2, 0), X(5, 1.8), Y(5, 1.8), X(3, 1.2), Y(3, 1.2), X(1.4, 0), Y(1.4, 0));
    P.G.DrawPath(P.Pen, Path);
  finally
    Path.Free;
  end;
end;

procedure DrawSoundIconImpl(P: TPainter; Id: TSoundId);
var
  I: Integer;
const
  WhiteBars: array[0..6] of Single = (7, 5, 8, 6, 7, 5, 8);
  PinkBars: array[0..6] of Single = (11, 9, 8, 7, 6, 5, 4);
  BrownBars: array[0..6] of Single = (13, 10, 7, 5, 3.5, 2.5, 2);
begin
  case Id of
    sndRain:
      begin
        Cloud(P, -1);
        P.Line(8, 16, 7, 19);
        P.Line(12, 16, 11, 20.5);
        P.Line(16, 16, 15, 19);
      end;
    sndThunderstorm:
      begin
        Cloud(P, -1);
        P.Lines([13, 14.5, 10.5, 18, 13.5, 18, 11, 21.5]);
        P.Line(7.5, 16, 6.5, 18.5);
        P.Line(17, 16, 16, 18.5);
      end;
    sndWind:
      begin
        P.Path(
          procedure(Path: TGPGraphicsPath)
          begin
            Path.AddLine(3.0, 9.0, 14.0, 9.0);
            Path.AddArc(12.0, 4.5, 4.5, 4.5, 90, -270);
          end);
        P.Path(
          procedure(Path: TGPGraphicsPath)
          begin
            Path.AddLine(3.0, 13.0, 18.0, 13.0);
            Path.AddArc(16.0, 13.0, 5.0, 5.0, 270, 270);
          end);
        P.Line(3, 17, 10, 17);
      end;
    sndForest:
      begin
        P.Polygon([8, 3.5, 3.5, 11, 6, 11, 2.5, 17, 13.5, 17, 10, 11, 12.5, 11]);
        P.Line(8, 17, 8, 20.5);
        P.Polygon([16, 7, 12.8, 12.5, 14.5, 12.5, 12, 17, 20, 17, 17.5, 12.5, 19.2, 12.5]);
        P.Line(16, 17, 16, 20.5);
        P.Line(2.5, 20.5, 21.5, 20.5);
      end;
    sndLeaves:
      begin
        P.Path(
          procedure(Path: TGPGraphicsPath)
          begin
            Path.AddBezier(5.0, 19.0, 4.0, 10.0, 10.0, 4.0, 20.0, 4.0);
            Path.AddBezier(20.0, 4.0, 20.0, 14.0, 14.0, 20.0, 5.0, 19.0);
          end);
        P.Bezier(5, 19, 9, 15, 13, 11, 17, 7);
        P.Line(10.5, 13.5, 10.5, 9.5);
        P.Line(13.5, 10.5, 16.5, 10.5);
        P.Line(3, 21, 5, 19);
      end;
    sndStream:
      for I := 0 to 2 do
        P.Path(
          procedure(Path: TGPGraphicsPath)
          var
            Y: Single;
          begin
            Y := 7 + I * 5;
            Path.AddBezier(3.0, Y, 6.0, Y - 2.5, 8.0, Y - 2.5, 10.5, Y);
            Path.AddBezier(10.5, Y, 13.0, Y + 2.5, 15.5, Y + 2.5, 18.0, Y);
            Path.AddBezier(18.0, Y, 19.5, Y - 1.5, 20.5, Y - 1.5, 21.0, Y - 1.0);
          end);
    sndSeaside:
      begin
        P.Path(
          procedure(Path: TGPGraphicsPath)
          begin
            Path.AddBezier(2.5, 16.0, 6.0, 16.0, 7.0, 6.0, 13.5, 6.0);
            Path.AddBezier(13.5, 6.0, 17.0, 6.0, 18.0, 9.0, 16.5, 11.0);
            Path.AddBezier(16.5, 11.0, 15.0, 9.0, 12.0, 10.0, 12.5, 13.0);
            Path.AddBezier(12.5, 13.0, 13.0, 15.5, 17.0, 16.0, 21.5, 16.0);
          end);
        P.Bezier(2.5, 20, 6, 18.5, 9, 18.5, 12, 20);
        P.Bezier(12, 20, 15, 21.5, 18, 21.5, 21.5, 20);
      end;
    sndWater:
      begin
        P.Path(
          procedure(Path: TGPGraphicsPath)
          begin
            Path.AddBezier(12.0, 3.0, 9.0, 7.5, 6.5, 10.5, 6.5, 13.5);
            Path.AddArc(6.5, 8.0, 11.0, 11.0, 180, -180);
            Path.AddBezier(17.5, 13.5, 17.5, 10.5, 15.0, 7.5, 12.0, 3.0);
          end);
        P.Arc(12, 13.5, 3, 3, 90, 90);
        P.Arc(12, 21, 9, 1.8, 200, 140);
      end;
    sndFireplace:
      begin
        P.Path(
          procedure(Path: TGPGraphicsPath)
          begin
            Path.AddBezier(12.0, 3.0, 13.0, 7.0, 17.5, 8.5, 17.0, 13.0);
            Path.AddBezier(17.0, 13.0, 16.7, 16.0, 14.5, 17.5, 12.0, 17.5);
            Path.AddBezier(12.0, 17.5, 9.0, 17.5, 7.0, 15.5, 7.0, 13.0);
            Path.AddBezier(7.0, 13.0, 7.0, 10.5, 9.0, 9.5, 9.5, 7.5);
            Path.AddBezier(9.5, 7.5, 10.5, 9.0, 10.5, 10.5, 10.0, 11.5);
            Path.AddBezier(10.0, 11.5, 12.0, 10.0, 12.5, 6.5, 12.0, 3.0);
          end);
        P.Line(4, 21, 20, 19);
        P.Line(4, 19, 20, 21);
      end;
    sndSummerNight:
      begin
        P.Path(
          procedure(Path: TGPGraphicsPath)
          begin
            Path.AddArc(3.0, 4.0, 14.0, 14.0, 290, -300);
            Path.AddArc(7.5, 2.0, 11.0, 11.0, 130, 140);
          end);
        P.Line(18, 4, 18, 8);
        P.Line(16, 6, 20, 6);
        P.Circle(20.5, 12, 0.6, True);
        P.Circle(15, 2.8, 0.5, True);
      end;
    sndCoffeeShop:
      begin
        P.Path(
          procedure(Path: TGPGraphicsPath)
          begin
            Path.AddLine(4.0, 10.0, 16.0, 10.0);
            Path.AddLine(16.0, 10.0, 16.0, 15.0);
            Path.AddArc(10.0, 13.0, 6.0, 6.0, 0, 90);
            Path.AddLine(13.0, 19.0, 7.0, 19.0);
            Path.AddArc(4.0, 13.0, 6.0, 6.0, 90, 90);
            Path.CloseFigure;
          end);
        P.Arc(16.5, 13, 2.8, 2.6, 270, 180);
        P.Line(3, 21.5, 17, 21.5);
        P.Bezier(8, 7.5, 7, 6, 9, 5, 8, 3);
        P.Bezier(12, 7.5, 11, 6, 13, 5, 12, 3);
      end;
    sndTrain:
      begin
        P.RoundRect(5, 3, 14, 15, 3);
        P.Line(5.5, 11, 18.5, 11);
        P.Line(10, 6, 14, 6);
        P.Circle(8.5, 14.5, 0.9, True);
        P.Circle(15.5, 14.5, 0.9, True);
        P.Line(8, 18, 5, 21.5);
        P.Line(16, 18, 19, 21.5);
        P.Line(6.5, 20, 17.5, 20);
      end;
    sndFan:
      begin
        P.Circle(12, 10, 8);
        P.Circle(12, 10, 1.4);
        for I := 0 to 2 do
          FanBlade(P, DegToRad(I * 120 - 90));
        P.Line(12, 18, 12, 21);
        P.Line(8, 21.5, 16, 21.5);
      end;
    sndWhiteNoise:
      for I := 0 to 6 do
        P.Line(4 + I * 2.66, 12 - WhiteBars[I] / 2, 4 + I * 2.66, 12 + WhiteBars[I] / 2);
    sndPinkNoise:
      for I := 0 to 6 do
        P.Line(4 + I * 2.66, 12 - PinkBars[I] / 2, 4 + I * 2.66, 12 + PinkBars[I] / 2);
    sndBrownNoise:
      for I := 0 to 6 do
        P.Line(4 + I * 2.66, 12 - BrownBars[I] / 2, 4 + I * 2.66, 12 + BrownBars[I] / 2);
  end;
end;

procedure DrawSoundIcon(DC: HDC; Id: TSoundId; const R: TRect; Color: TColor; StrokeScale: Single);
var
  P: TPainter;
begin
  if (R.Width <= 0) or (R.Height <= 0) then
    Exit;
  P := TPainter.Create(DC, R, Color, StrokeScale);
  try
    DrawSoundIconImpl(P, Id);
  finally
    P.Free;
  end;
end;

procedure DrawGlyphImpl(P: TPainter; Glyph: TCalmGlyph);
var
  I: Integer;
  A: Single;
begin
  case Glyph of
    cgPlay:
      P.Polygon([8.5, 5.5, 18.5, 12, 8.5, 18.5], True);
    cgPause:
      begin
        P.RoundRect(7, 5.5, 3.2, 13, 1, True);
        P.RoundRect(13.8, 5.5, 3.2, 13, 1, True);
      end;
    cgStop:
      P.RoundRect(6.5, 6.5, 11, 11, 2, True);
    cgTimer:
      begin
        P.Circle(12, 13.5, 7.5);
        P.Line(12, 13.5, 12, 9.5);
        P.Line(12, 13.5, 14.5, 15);
        P.Line(10, 3, 14, 3);
        P.Line(12, 3, 12, 6);
        P.Line(18.5, 6.5, 19.8, 7.8);
      end;
    cgSettings:
      begin
        P.Circle(12, 12, 3);
        for I := 0 to 7 do
        begin
          A := DegToRad(I * 45);
          P.Line(12 + Cos(A) * 6.2, 12 + Sin(A) * 6.2, 12 + Cos(A) * 8.8, 12 + Sin(A) * 8.8);
        end;
        P.Circle(12, 12, 6.2);
      end;
    cgPlus:
      begin
        P.Line(12, 5, 12, 19);
        P.Line(5, 12, 19, 12);
      end;
    cgSpeaker, cgSpeakerMuted:
      begin
        P.Polygon([4, 9.5, 7.5, 9.5, 12, 5.5, 12, 18.5, 7.5, 14.5, 4, 14.5]);
        if Glyph = cgSpeaker then
        begin
          P.Arc(12.5, 12, 3.5, 3.5, -50, 100);
          P.Arc(12.5, 12, 7, 7, -50, 100);
        end
        else
        begin
          P.Line(15.5, 9.5, 20.5, 14.5);
          P.Line(20.5, 9.5, 15.5, 14.5);
        end;
      end;
    cgStar:
      P.Polygon([12, 3.5, 14.5, 9, 20.5, 9.5, 16, 13.5, 17.3, 19.5, 12, 16.4, 6.7, 19.5, 8, 13.5,
        3.5, 9.5, 9.5, 9]);
    cgMore:
      begin
        P.Circle(6, 12, 1.2, True);
        P.Circle(12, 12, 1.2, True);
        P.Circle(18, 12, 1.2, True);
      end;
    cgReset:
      begin
        P.Arc(12, 12, 7, 7, -60, 300);
        P.Lines([15.5, 3.5, 15.5, 6.8, 19, 6.8]);
      end;
    cgClose:
      begin
        P.Line(6.5, 6.5, 17.5, 17.5);
        P.Line(17.5, 6.5, 6.5, 17.5);
      end;
    cgChevronDown:
      P.Lines([6, 9.5, 12, 15.5, 18, 9.5]);
    cgChevronUp:
      P.Lines([6, 14.5, 12, 8.5, 18, 14.5]);
    cgCheck:
      P.Lines([5.5, 12.5, 10, 17, 18.5, 7.5]);
    cgWarning:
      begin
        P.Polygon([12, 3.5, 21, 19.5, 3, 19.5]);
        P.Line(12, 9.5, 12, 14);
        P.Circle(12, 16.8, 0.6, True);
      end;
    cgLogo:
      begin
        // Ctrl+Calm mark: a rounded key cap holding a calm wave.
        P.RoundRect(2.5, 2.5, 19, 19, 5);
        P.Bezier(6, 13, 8, 9.5, 10, 9.5, 12, 12);
        P.Bezier(12, 12, 14, 14.5, 16, 14.5, 18, 11);
      end;
  end;
end;

procedure DrawGlyph(DC: HDC; Glyph: TCalmGlyph; const R: TRect; Color: TColor; StrokeScale: Single);
var
  P: TPainter;
begin
  if (R.Width <= 0) or (R.Height <= 0) then
    Exit;
  P := TPainter.Create(DC, R, Color, StrokeScale);
  try
    DrawGlyphImpl(P, Glyph);
  finally
    P.Free;
  end;
end;

procedure FillRoundRect(DC: HDC; const R: TRect; Radius: Single; Fill: TColor; Border: TColor;
  BorderWidth: Single; FillAlpha: Byte);
var
  G: TGPGraphics;
  Path: TGPGraphicsPath;
  Brush: TGPSolidBrush;
  Pen: TGPPen;
  X, Y, W, H, D, Inset: Single;
begin
  if (R.Width <= 0) or (R.Height <= 0) then
    Exit;
  G := TGPGraphics.Create(DC);
  Path := TGPGraphicsPath.Create;
  try
    G.SetSmoothingMode(SmoothingModeAntiAlias);
    G.SetPixelOffsetMode(PixelOffsetModeHalf);
    Inset := IfThen(Border <> clNone, BorderWidth / 2, 0);
    X := R.Left + Inset;
    Y := R.Top + Inset;
    W := R.Width - Inset * 2;
    H := R.Height - Inset * 2;
    D := Min(Radius * 2, Min(W, H));
    Path.AddArc(X, Y, D, D, 180, 90);
    Path.AddArc(X + W - D, Y, D, D, 270, 90);
    Path.AddArc(X + W - D, Y + H - D, D, D, 0, 90);
    Path.AddArc(X, Y + H - D, D, D, 90, 90);
    Path.CloseFigure;
    if Fill <> clNone then
    begin
      Brush := TGPSolidBrush.Create(GPColor(Fill, FillAlpha));
      try
        G.FillPath(Brush, Path);
      finally
        Brush.Free;
      end;
    end;
    if Border <> clNone then
    begin
      Pen := TGPPen.Create(GPColor(Border), BorderWidth);
      try
        G.DrawPath(Pen, Path);
      finally
        Pen.Free;
      end;
    end;
  finally
    Path.Free;
    G.Free;
  end;
end;

procedure FillCircle(DC: HDC; CX, CY, Radius: Single; Fill: TColor; Alpha: Byte);
var
  G: TGPGraphics;
  Brush: TGPSolidBrush;
begin
  G := TGPGraphics.Create(DC);
  Brush := TGPSolidBrush.Create(GPColor(Fill, Alpha));
  try
    G.SetSmoothingMode(SmoothingModeAntiAlias);
    G.SetPixelOffsetMode(PixelOffsetModeHalf);
    G.FillEllipse(Brush, CX - Radius, CY - Radius, Radius * 2, Radius * 2);
  finally
    Brush.Free;
    G.Free;
  end;
end;

end.
