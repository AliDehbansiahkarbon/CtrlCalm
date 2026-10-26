program IdeProbe;

{
  Automated smoke test of the installed Ctrl+Calm package inside a real RAD
  Studio IDE. It drives the IDE only through its window and menu handles
  (WM_COMMAND on menu items, mouse messages on the plugin's own controls) and
  measures the IDE process's audio session on the default output device.

  Usage: IdeProbe <path-to-bds.exe> <screenshot-folder> [seconds-per-step]
  Exit code 0 = all checks passed. The IDE is started with -ns -np and closed
  with WM_CLOSE at the end.
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows, Winapi.Messages, Winapi.ActiveX, System.SysUtils, System.Classes,
  System.Generics.Collections, System.Generics.Defaults, System.Math, System.StrUtils,
  Winapi.PsAPI, Vcl.Graphics, Vcl.Imaging.pngimage,
  CtrlCalm.TestUtils in '..\..\Common\CtrlCalm.TestUtils.pas';

function PrintWindow(hwnd: HWND; hdcBlt: HDC; nFlags: UINT): BOOL; stdcall;
  external user32 name 'PrintWindow';

var
  Failures: Integer = 0;
  StepMs: Integer = 3000;
  ShotDir: string;
  IdePid: DWORD;
  MainWnd: HWND;

procedure Log(const S: string);
begin
  Writeln(FormatDateTime('hh:nn:ss ', Now), S);
end;

procedure Check(Cond: Boolean; const What: string);
begin
  if Cond then
    Log('PASS  ' + What)
  else
  begin
    Log('FAIL  ' + What);
    Inc(Failures);
  end;
end;

function WindowText(W: HWND): string;
var
  Buf: array[0..511] of Char;
begin
  SetString(Result, Buf, GetWindowText(W, Buf, Length(Buf)));
end;

function WindowClass(W: HWND): string;
var
  Buf: array[0..255] of Char;
begin
  SetString(Result, Buf, GetClassName(W, Buf, Length(Buf)));
end;

type
  TFindCtx = record
    Pid: DWORD;
    ClassName, Caption: string;
    Found: TList<HWND>;
  end;
  PFindCtx = ^TFindCtx;

function EnumTop(W: HWND; L: LPARAM): BOOL; stdcall;
var
  Ctx: PFindCtx;
  P: DWORD;
begin
  Ctx := PFindCtx(L);
  GetWindowThreadProcessId(W, P);
  if (P = Ctx.Pid) and ((Ctx.ClassName = '') or SameText(WindowClass(W), Ctx.ClassName)) and
     ((Ctx.Caption = '') or (Pos(Ctx.Caption, WindowText(W)) > 0)) then
    Ctx.Found.Add(W);
  Result := True;
end;

function EnumChild(W: HWND; L: LPARAM): BOOL; stdcall;
var
  Ctx: PFindCtx;
begin
  Ctx := PFindCtx(L);
  if ((Ctx.ClassName = '') or SameText(WindowClass(W), Ctx.ClassName)) and
     ((Ctx.Caption = '') or (Pos(Ctx.Caption, WindowText(W)) > 0)) then
    Ctx.Found.Add(W);
  Result := True;
end;

function FindWindows(const AClass, ACaption: string; Parent: HWND = 0): TArray<HWND>;
var
  Ctx: TFindCtx;
begin
  Ctx.Pid := IdePid;
  Ctx.ClassName := AClass;
  Ctx.Caption := ACaption;
  Ctx.Found := TList<HWND>.Create;
  try
    if Parent = 0 then
      EnumWindows(@EnumTop, LPARAM(@Ctx))
    else
      EnumChildWindows(Parent, @EnumChild, LPARAM(@Ctx));
    Result := Ctx.Found.ToArray;
  finally
    Ctx.Found.Free;
  end;
end;

function FindAnywhere(const AClass: string): TArray<HWND>;
var
  Top: HWND;
  All: TList<HWND>;
  W: HWND;
begin
  All := TList<HWND>.Create;
  try
    for Top in FindWindows('', '') do
    begin
      if SameText(WindowClass(Top), AClass) then
        All.Add(Top);
      for W in FindWindows(AClass, '', Top) do
        All.Add(W);
    end;
    Result := All.ToArray;
  finally
    All.Free;
  end;
end;

function StripAmp(const S: string): string;
begin
  Result := StringReplace(S, '&', '', [rfReplaceAll]);
  if Pos(#9, Result) > 0 then
    Result := Copy(Result, 1, Pos(#9, Result) - 1);
end;

function MenuItemText(M: HMENU; Index: Integer): string;
var
  Buf: array[0..255] of Char;
  Info: TMenuItemInfo;
begin
  Info := Default(TMenuItemInfo);
  Info.cbSize := SizeOf(Info);
  Info.fMask := MIIM_STRING;
  Info.dwTypeData := Buf;
  Info.cch := Length(Buf);
  if GetMenuItemInfo(M, Index, True, Info) then
    SetString(Result, Buf, Info.cch)
  else
    Result := '';
  Result := StripAmp(Result);
end;

/// <summary>Finds a menu item by path ("Tools|Ctrl+Calm|Show/Hide Mixer") and
/// returns its command id, or 0.</summary>
function FindMenuCommand(const Path: string; out Caption: string): UINT;
var
  Parts: TArray<string>;
  M: HMENU;
  I, K: Integer;
  Found: Boolean;
begin
  Result := 0;
  Parts := Path.Split(['|']);
  M := GetMenu(MainWnd);
  for K := 0 to High(Parts) do
  begin
    if M = 0 then
      Exit;
    // VCL fills sub-menus lazily on WM_INITMENUPOPUP.
    SendMessage(MainWnd, WM_INITMENUPOPUP, WPARAM(M), 0);
    Found := False;
    for I := 0 to GetMenuItemCount(M) - 1 do
      if StartsText(Parts[K], MenuItemText(M, I)) then
      begin
        Found := True;
        Caption := MenuItemText(M, I);
        if K = High(Parts) then
          Exit(GetMenuItemID(M, I));
        M := GetSubMenu(M, I);
        Break;
      end;
    if not Found then
      Exit;
  end;
end;

var
  AutoWnd: HWND;

function Automation(const Cmd: string): NativeInt;
var
  Data: TCopyDataStruct;
  R: DWORD_PTR;
begin
  Data.dwData := 0;
  Data.cbData := Length(Cmd) * SizeOf(Char);
  Data.lpData := PChar(Cmd);
  if SendMessageTimeout(AutoWnd, WM_COPYDATA, 0, LPARAM(@Data), SMTO_ABORTIFHUNG, 10000, @R) = 0 then
    Exit(-2);
  Result := NativeInt(R);
end;

/// <summary>Executes a Ctrl+Calm IDE action, i.e. exactly what its menu item does.</summary>
function RunAction(const Name: string): Boolean;
begin
  Result := Automation('exec:' + Name) = 1;
  Log(Format('action %s -> %s', [Name, BoolToStr(Result, True)]));
end;

function RunMenu(const Path: string): Boolean;
var
  Id: UINT;
  Cap: string;
begin
  Id := FindMenuCommand(Path, Cap);
  Result := (Id <> 0) and (Id <> UINT(-1));
  if Result then
    PostMessage(MainWnd, WM_COMMAND, Id, 0);
  Log(Format('menu %s -> id %d (%s)', [Path, Integer(Id), Cap]));
end;

procedure Pump(Ms: Integer);
begin
  Sleep(Ms);
end;

procedure Shot(W: HWND; const Name: string);
var
  R: TRect;
  Bmp: TBitmap;
  Png: TPngImage;
begin
  if (W = 0) or not GetWindowRect(W, R) or (R.Width <= 0) then
    Exit;
  Bmp := TBitmap.Create;
  try
    Bmp.PixelFormat := pf24bit;
    Bmp.SetSize(R.Width, R.Height);
    // Render only this window (never copy the screen, which could capture
    // other applications). Some composited IDE windows render blank this way.
    PrintWindow(W, Bmp.Canvas.Handle, 0);
    Png := TPngImage.Create;
    try
      Png.Assign(Bmp);
      Png.SaveToFile(IncludeTrailingPathDelimiter(ShotDir) + Name + '.png');
    finally
      Png.Free;
    end;
  finally
    Bmp.Free;
  end;
  Log('screenshot ' + Name);
end;

procedure ClickWindow(W: HWND);
var
  R: TRect;
  P: LPARAM;
begin
  GetClientRect(W, R);
  // Click the upper part of the tile (its body, not the level bar).
  P := MakeLParam(R.Width div 2, R.Height div 3);
  PostMessage(W, WM_LBUTTONDOWN, MK_LBUTTON, P);
  PostMessage(W, WM_LBUTTONUP, 0, P);
end;

function TilesInOrder: TArray<HWND>;
var
  L: TList<HWND>;
begin
  L := TList<HWND>.Create;
  try
    L.AddRange(FindAnywhere('TCalmSoundTile'));
    L.Sort(TComparer<HWND>.Construct(
      function(const A, B: HWND): Integer
      var
        RA, RB: TRect;
      begin
        GetWindowRect(A, RA);
        GetWindowRect(B, RB);
        Result := CompareValue(RA.Top, RB.Top);
        if Result = 0 then
          Result := CompareValue(RA.Left, RB.Left);
      end));
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function AveragePeak(Ms: Integer): Single;
var
  Deadline: UInt64;
  N: Integer;
  P: Single;
begin
  Result := 0;
  N := 0;
  Deadline := GetTickCount64 + UInt64(Ms);
  while GetTickCount64 < Deadline do
  begin
    P := ProcessSessionPeak(IdePid);
    if P >= 0 then
    begin
      Result := Result + P;
      Inc(N);
    end;
    Sleep(100);
  end;
  if N > 0 then
    Result := Result / N
  else
    Result := -1;
end;

function MixerWindow: HWND;
var
  Hosts: TArray<HWND>;
  W: HWND;
begin
  Result := 0;
  Hosts := FindAnywhere('TCalmMixerView');
  if Length(Hosts) > 0 then
  begin
    W := Hosts[0];
    // Walk up to the dockable form (or its dock host) for screenshots.
    while (GetParent(W) <> 0) and (GetParent(W) <> MainWnd) do
      W := GetParent(W);
    Result := W;
  end;
end;

function Visible(W: HWND): Boolean;
begin
  Result := (W <> 0) and IsWindowVisible(W);
end;

var
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd, Bds: string;
  T0: UInt64;
  Tiles: TArray<HWND>;
  Mixer, View: HWND;
  Peak: Single;
  Code: DWORD;
  Wins: TArray<HWND>;

  PMC: PROCESS_MEMORY_COUNTERS;
begin
  if ParamCount < 2 then
  begin
    Writeln('Usage: IdeProbe <bds.exe> <screenshot-folder> [seconds-per-step]');
    Halt(2);
  end;
  Bds := ParamStr(1);
  ShotDir := ParamStr(2);
  StepMs := StrToIntDef(ParamStr(3), 3) * 1000;
  ForceDirectories(ShotDir);
  CoInitialize(nil);


  SI := Default(TStartupInfo);
  SI.cb := SizeOf(SI);
  Cmd := Format('"%s" -pDelphi -ns -np', [Bds]);
  UniqueString(Cmd);
  T0 := GetTickCount64;
  SetEnvironmentVariable('CTRLCALM_AUTOMATION', '1'); // inherited by the IDE
  if not CreateProcess(nil, PChar(Cmd), nil, nil, False, 0, nil, nil, SI, PI) then
    RaiseLastOSError;
  IdePid := PI.dwProcessId;
  Log(Format('started %s pid %d', [Bds, IdePid]));
  WaitForInputIdle(PI.hProcess, 120000);

  // Wait for the main window and for the IDE to settle.
  MainWnd := 0;
  repeat
    Wins := FindWindows('TAppBuilder', '');
    if Length(Wins) > 0 then
      MainWnd := Wins[0];
    Sleep(500);
  until ((MainWnd <> 0) and IsWindowVisible(MainWnd)) or (GetTickCount64 - T0 > 180000);
  Check(MainWnd <> 0, 'IDE main window appeared');
  Sleep(8000);
  Log(Format('IDE ready after %d ms', [GetTickCount64 - T0]));

  Wins := FindWindows('', 'CtrlCalm.Automation');
  AutoWnd := 0;
  if Length(Wins) > 0 then
    AutoWnd := Wins[0];
  Check(AutoWnd <> 0, 'Ctrl+Calm package loaded (automation endpoint found)');
  Check(Automation('menu') = 1005, Format('Tools > Ctrl+Calm submenu with 5 actions (%d)', [Automation('menu')]));
  Automation('menudump');
  Check(RunAction('CtrlCalmShowHideAction'), 'Show/Hide Mixer action');
  Sleep(StepMs);
  Mixer := MixerWindow;
  Check(Visible(Mixer), 'mixer panel opened');
  Shot(Mixer, 'ide-01-opened');

  Tiles := TilesInOrder;
  Check(Length(Tiles) = 16, Format('16 sound tiles present (%d)', [Length(Tiles)]));
  if Length(Tiles) = 16 then
  begin
    ClickWindow(Tiles[0]);   // Rain
    ClickWindow(Tiles[15]);  // Brown Noise
    ClickWindow(Tiles[8]);   // Fireplace
    Sleep(StepMs);
    Peak := AveragePeak(2000);
    Log(Format('IDE audio session peak while playing: %.4f', [Peak]));
    Check(Peak > 0.001, 'IDE process is playing audio');
    Shot(Mixer, 'ide-02-playing');

    Check(Automation('playing') = 1, 'service reports playing');
    Check(RunAction('CtrlCalmShowHideAction'), 'hide via action');
    Sleep(1500);
    Check(not Visible(MixerWindow), 'panel hidden');
    Peak := AveragePeak(2000);
    Log(Format('peak while hidden: %.4f', [Peak]));
    Check(Peak > 0.001, 'audio keeps playing while the panel is hidden');

    Check(RunAction('CtrlCalmTimerAction'), 'Focus Timer action');
    Sleep(StepMs);
    Mixer := MixerWindow;
    Check(Visible(Mixer), 'panel shown again with the timer');
    Shot(Mixer, 'ide-03-timer');

    Check(RunAction('CtrlCalmPlayPauseAction'), 'Play/Pause action');
    Sleep(2500);
    Peak := AveragePeak(1500);
    Log(Format('peak after pause: %.4f', [Peak]));
    Check(Peak < 0.001, 'paused: no audio');
    View := 0;
    Wins := FindAnywhere('TCalmMixerView');
    if Length(Wins) > 0 then
      View := Wins[0];
    Check(View <> 0, 'mixer view handle');
  end;

  PMC := Default(PROCESS_MEMORY_COUNTERS);
  PMC.cb := SizeOf(PMC);
  if GetProcessMemoryInfo(PI.hProcess, @PMC, SizeOf(PMC)) then
    Log(Format('IDE working set %d MB', [PMC.WorkingSetSize div 1048576]));

  // Graceful exit.
  T0 := GetTickCount64;
  PostMessage(MainWnd, WM_CLOSE, 0, 0);
  if WaitForSingleObject(PI.hProcess, 60000) <> WAIT_OBJECT_0 then
  begin
    Check(False, 'IDE exited within 60 s');
    TerminateProcess(PI.hProcess, 1);
  end
  else
  begin
    GetExitCodeProcess(PI.hProcess, Code);
    Log(Format('IDE exited in %d ms with code %d', [GetTickCount64 - T0, Code]));
    Check(Code = 0, 'IDE exit code 0 (no crash on unload)');
  end;
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);
  CoUninitialize;
  Log(Format('%d failure(s)', [Failures]));
  ExitCode := Failures;
end.
