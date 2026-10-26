program CtrlCalmHarness;

{
  Development harness: runs the production Ctrl+Calm service, engine, timer
  and mixer view in a plain VCL window, without loading the IDE package.
  Not shipped and never required at runtime.

  Command line (all optional):
    /style:<name>        load a VCL style from the RAD Studio Redist folder,
                         e.g. /style:"Windows11 Modern Dark"
    /size:<w>x<h>        client size in 96-DPI units (default 420x720)
    /ppi:<n>             simulate a monitor DPI (120, 144, 168, 192)
    /screenshot:<file>   save a PNG of the window after /delay ms, then exit
    /delay:<ms>          default 1500
    /timer               open the timer panel
    /activate:a,b        turn on sounds by key (e.g. rain,brown-noise)
    /settings:<file>     use a separate settings file (default: harness-settings.json)
    /silent              do not open an audio device
}

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.IOUtils,
  Vcl.Forms, Vcl.Controls, Vcl.Graphics, Vcl.Themes, Vcl.Styles, Vcl.ExtCtrls,
  Vcl.Imaging.pngimage,
  CtrlCalm.Core.Types, CtrlCalm.Core.Settings, CtrlCalm.Service, CtrlCalm.Persistence,
  CtrlCalm.UI.MixerView, CtrlCalm.UI.SettingsDialog;

type
  THarnessForm = class(TForm)
  private
    FService: TCalmService;
    FView: TCalmMixerView;
    FShotTimer: TTimer;
    FShotFile: string;
    FPendingPPI: Integer;
    procedure OpenSettings(Sender: TObject);
    procedure TakeShot(Sender: TObject);
    procedure AppActivate(Sender: TObject);
    procedure AppDeactivate(Sender: TObject);
    procedure FormClosed(Sender: TObject; var Action: TCloseAction);
  protected
    procedure DoShow; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

type
  TErrorLog = class
    class procedure HandleException(Sender: TObject; E: Exception);
  end;

procedure Trace(const S: string);
begin
  if FindCmdLineSwitch('trace') then
    TFile.AppendAllText(TPath.Combine(TPath.GetTempPath, 'CtrlCalmHarness.log'),
      FormatDateTime('hh:nn:ss.zzz ', Now) + S + sLineBreak);
end;

class procedure TErrorLog.HandleException(Sender: TObject; E: Exception);
begin
  TFile.AppendAllText(TPath.Combine(TPath.GetTempPath, 'CtrlCalmHarness.log'),
    FormatDateTime('hh:nn:ss ', Now) + E.ClassName + ': ' + E.Message + sLineBreak);
end;

function SwitchValue(const Name: string; out Value: string): Boolean;
var
  I: Integer;
  P: string;
begin
  for I := 1 to ParamCount do
  begin
    P := ParamStr(I);
    if SameText(P, '/' + Name) then
    begin
      Value := '';
      Exit(True);
    end;
    if P.StartsWith('/' + Name + ':', True) then
    begin
      Value := P.Substring(Length(Name) + 2).DeQuotedString('"');
      Exit(True);
    end;
  end;
  Result := False;
end;

function FindSoundsFolder: string;
var
  Dir: string;
  I: Integer;
begin
  Dir := ExtractFilePath(ParamStr(0));
  for I := 0 to 8 do
  begin
    if DirectoryExists(TPath.Combine(Dir, 'assets\sounds')) then
      Exit(TPath.Combine(Dir, 'assets\sounds'));
    Dir := ExtractFilePath(ExcludeTrailingPathDelimiter(Dir));
    if Dir = '' then
      Break;
  end;
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'sounds');
end;

{ THarnessForm }

var
  GSoundsFolder, GSettingsFile: string;
  GSilent: Boolean;

constructor THarnessForm.Create(AOwner: TComponent);
var
  V, Key: string;
  W, H: Integer;
  Preset: TFavorite;
  Id: TSoundId;
begin
  inherited CreateNew(AOwner);
  Caption := 'Ctrl+Calm - development harness';
  Position := poScreenCenter;
  W := 420;
  H := 720;
  if SwitchValue('size', V) and (Pos('x', V) > 0) then
  begin
    W := StrToIntDef(Copy(V, 1, Pos('x', V) - 1), W);
    H := StrToIntDef(Copy(V, Pos('x', V) + 1, MaxInt), H);
  end;
  ClientWidth := MulDiv(W, Screen.PixelsPerInch, 96);
  ClientHeight := MulDiv(H, Screen.PixelsPerInch, 96);

  CalmAssetsFolder := ExtractFileDir(GSoundsFolder);
  FService := TCalmService.Create(GSoundsFolder, GSettingsFile, not GSilent);
  FView := TCalmMixerView.Create(Self, FService);
  FView.Parent := Self;
  FView.Align := alClient;
  FView.OnOpenSettings := OpenSettings;
  OnClose := FormClosed;
  Application.OnActivate := AppActivate;
  Application.OnDeactivate := AppDeactivate;

  if SwitchValue('ppi', V) then
    FPendingPPI := StrToIntDef(V, 0);
  if SwitchValue('timer', V) then
    FView.ShowTimer(True);
  if SwitchValue('activate', V) then
    for Key in V.Split([',']) do
      if TryParseSoundKey(Trim(Key), Id) then
        FService.SetSoundActive(Id, True);
  // /volume:rain=0.7,forest=0.3  (levels for the screenshot)
  if SwitchValue('volume', V) then
    for Key in V.Split([',']) do
      if (Pos('=', Key) > 0) and TryParseSoundKey(Trim(Copy(Key, 1, Pos('=', Key) - 1)), Id) then
        FService.SetSoundVolume(Id, StrToFloatDef(Copy(Key, Pos('=', Key) + 1, MaxInt), 0.5,
          TFormatSettings.Invariant));
  // /preset:builtin:deep-focus
  if SwitchValue('preset', V) then
    if FindPreset(FService.Settings, V, Preset) then
      FService.ApplyPreset(Preset);
  // /save:Name  (saves the current mix as a favorite)
  if SwitchValue('save', V) then
    FService.SaveCurrentAsFavorite(V);
  // /starttimer:<seconds>  /pomodoro
  if SwitchValue('starttimer', V) then
    FService.StartCountdown(StrToIntDef(V, 1500));
  if SwitchValue('pomodoro', V) then
    FService.StartPomodoro;

  if SwitchValue('screenshot', FShotFile) then
  begin
    FShotTimer := TTimer.Create(Self);
    FShotTimer.Interval := 1500;
    if SwitchValue('delay', V) then
      FShotTimer.Interval := StrToIntDef(V, 1500);
    FShotTimer.OnTimer := TakeShot;
  end;
end;

destructor THarnessForm.Destroy;
begin
  // The view unregisters from the service; the service then stops the worker.
  FreeAndNil(FView);
  FreeAndNil(FService);
  inherited;
end;

procedure THarnessForm.DoShow;
begin
  inherited;
  // Simulated monitor DPI. With Scaled = True, VCL reports the real monitor
  // DPI (GetDpiForWindow); turning it off lets the view run at the given PPI
  // through the same ChangeScale path a monitor change uses.
  if (FPendingPPI > 0) and (FPendingPPI <> FView.CurrentPPI) then
  begin
    Scaled := False;
    FView.ScaleForPPI(FPendingPPI);
    FPendingPPI := 0;
    Trace(Format('form ppi=%d view ppi=%d', [CurrentPPI, FView.CurrentPPI]));
  end;
end;

procedure THarnessForm.AppActivate(Sender: TObject);
begin
  FService.SetIdeFocused(True);
end;

procedure THarnessForm.AppDeactivate(Sender: TObject);
begin
  FService.SetIdeFocused(False);
end;

procedure THarnessForm.FormClosed(Sender: TObject; var Action: TCloseAction);
begin
  Application.Terminate;
end;

procedure THarnessForm.OpenSettings(Sender: TObject);
begin
  ShowCalmSettings(FService);
end;

procedure THarnessForm.TakeShot(Sender: TObject);
var
  Bmp: TBitmap;
  Png: TPngImage;
begin
  FShotTimer.Enabled := False;
  Trace('shot ' + FShotFile);
  Bmp := TBitmap.Create;
  try
    Bmp.PixelFormat := pf24bit;
    Bmp.SetSize(ClientWidth, ClientHeight);
    Bmp.Canvas.Lock;
    try
      // Render the client area (works even when the window is covered).
      PaintTo(Bmp.Canvas.Handle, 0, 0);
    finally
      Bmp.Canvas.Unlock;
    end;
    Png := TPngImage.Create;
    try
      Png.Assign(Bmp);
      ForceDirectories(ExtractFileDir(ExpandFileName(FShotFile)));
      Png.SaveToFile(FShotFile);
    finally
      Png.Free;
    end;
  finally
    Bmp.Free;
  end;
  Trace('shot saved');
  Close;
end;

var
  V, StyleFile, SettingsFile: string;
  F: THarnessForm;
begin
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  ReportMemoryLeaksOnShutdown := FindCmdLineSwitch('leaks');
  Application.Initialize;
  Application.OnException := TErrorLog.HandleException;
  if SwitchValue('style', V) and (V <> '') then
  begin
    StyleFile := TPath.Combine(GetEnvironmentVariable('BDS'), 'Redist\styles\vcl\' + V + '.vsf');
    if not FileExists(StyleFile) then
      StyleFile := 'C:\Program Files (x86)\Embarcadero\Studio\37.0\Redist\styles\vcl\' + V + '.vsf';
    if FileExists(StyleFile) then
      TStyleManager.SetStyle(TStyleManager.LoadFromFile(StyleFile));
  end;
  if not SwitchValue('settings', SettingsFile) then
    SettingsFile := TPath.Combine(DefaultSettingsFolder, 'harness-settings.json');
  Trace('start');
  GSoundsFolder := FindSoundsFolder;
  GSettingsFile := SettingsFile;
  GSilent := SwitchValue('silent', V);
  Application.MainFormOnTaskbar := True;
  try
    Application.CreateForm(THarnessForm, F);
  except
    on E: Exception do
    begin
      TErrorLog.HandleException(nil, E);
      raise;
    end;
  end;
  Trace('created');
  Application.Run;
  Trace('run ended');
end.
