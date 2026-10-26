unit CtrlCalm.IDE.Register;

{
  RAD Studio integration through the Open Tools API only:
  - a package wizard (IOTAWizard) registered with RegisterPackageWizard
  - a dockable tool window (INTACustomDockableForm, INTAServices270+)
  - a "Ctrl+Calm" submenu under Tools, built from TActions added to the IDE's
    action list with INTAServices.AddActionMenu, so shortcuts and toolbar
    customization work like any IDE command
  - IDE theme integration (IOTAIDEThemingServices and its notifier)

  Lifetime: everything is created in Register (package load) and destroyed in
  this unit's finalization (package unload / IDE exit), in reverse order. The
  audio service is created lazily on first use and destroyed last, after all
  UI that references it is gone; destroying it joins the worker thread, so no
  package code can run after unload.
}

interface

procedure Register;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IniFiles, System.Actions,
  Vcl.ActnList, Vcl.Menus, Vcl.Forms, Vcl.Controls, Vcl.ComCtrls, Vcl.ImgList,
  Winapi.Messages, System.StrUtils, Vcl.Themes, Vcl.ExtCtrls, Vcl.AppEvnts,
  ToolsAPI, DesignIntf,
  CtrlCalm.Core.Types, CtrlCalm.Core.Settings, CtrlCalm.Service, CtrlCalm.Persistence,
  CtrlCalm.UI.Theme, CtrlCalm.UI.MixerView, CtrlCalm.UI.SettingsDialog,
  CtrlCalm.IDE.HostFrame;

const
  DockIdentifier = 'CtrlCalmMixer';
  MenuName = 'CtrlCalmMenu';

type
  TCalmWizard = class(TNotifierObject, IOTAWizard)
  public
    function GetIDString: string;
    function GetName: string;
    function GetState: TWizardState;
    procedure Execute;
  end;

  TCalmDockableForm = class(TInterfacedObject, INTACustomDockableForm)
  public
    function GetCaption: string;
    function GetIdentifier: string;
    function GetFrameClass: TCustomFrameClass;
    procedure FrameCreated(AFrame: TCustomFrame);
    function GetMenuActionList: TCustomActionList;
    function GetMenuImageList: TCustomImageList;
    procedure CustomizePopupMenu(PopupMenu: TPopupMenu);
    function GetToolBarActionList: TCustomActionList;
    function GetToolBarImageList: TCustomImageList;
    procedure CustomizeToolBar(ToolBar: TToolBar);
    procedure SaveWindowState(Desktop: TCustomIniFile; const Section: string; IsProject: Boolean);
    procedure LoadWindowState(Desktop: TCustomIniFile; const Section: string);
    function GetEditState: TEditState;
    function EditAction(Action: TEditAction): Boolean;
  end;

  TCalmThemeNotifier = class(TNotifierObject, INTAIDEThemingServicesNotifier)
  public
    procedure ChangingTheme;
    procedure ChangedTheme;
  end;

  /// <summary>Owns the IDE-facing components (actions, menu, timers) and
  /// tracks the dockable form so it can be cleaned up safely.</summary>
  TCalmIdeController = class(TComponent)
  private
    FMenu: TMenuItem;
    FActShowHide, FActPlayPause, FActMute, FActTimer, FActSettings: TAction;
    FForm: TCustomForm;
    FView: TCalmMixerView;
    FAppEvents: TApplicationEvents;
    FStartupTimer: TTimer;
    FPendingTimerVisible: Boolean;
    FAutomationWnd: HWND;
    procedure AutomationWndProc(var Msg: TMessage);
    function NewAction(const Name, Caption, HintText: string; Handler: TNotifyEvent): TAction;
    procedure ShowHideExecute(Sender: TObject);
    procedure PlayPauseExecute(Sender: TObject);
    procedure MuteExecute(Sender: TObject);
    procedure TimerExecute(Sender: TObject);
    procedure SettingsExecute(Sender: TObject);
    procedure PlayPauseUpdate(Sender: TObject);
    procedure MuteUpdate(Sender: TObject);
    procedure ShowHideUpdate(Sender: TObject);
    procedure AppActivate(Sender: TObject);
    procedure AppDeactivate(Sender: TObject);
    procedure StartupTick(Sender: TObject);
    procedure OpenSettings(Sender: TObject);
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure InstallMenu;
    procedure RemoveMenu;
    procedure ApplyShortcuts; overload;
    procedure ApplyShortcuts(const S: TCalmSettings); overload;
    procedure ShowPanel(FocusTimer: Boolean = False);
    procedure AttachFrame(AFrame: TCustomFrame);
    procedure DestroyPanel;
    procedure ThemeChanged;
    property View: TCalmMixerView read FView;
  end;

var
  GController: TCalmIdeController;
  GDockable: INTACustomDockableForm;
  GThemeNotifierIndex: Integer = -1;
  GService: TCalmService;
  GShuttingDown: Boolean;

{ Helpers }

function ThemingServices: IOTAIDEThemingServices;
begin
  if not Supports(BorlandIDEServices, IOTAIDEThemingServices, Result) then
    Result := nil;
end;

function PackageFolder: string;
var
  Buf: array[0..MAX_PATH] of Char;
begin
  SetString(Result, Buf, GetModuleFileName(HInstance, Buf, Length(Buf)));
  Result := ExtractFilePath(Result);
end;

/// <summary>Finds the bundled sounds: next to the package (installed layout),
/// or in the repository's assets\sounds when running a development build.</summary>
function FindSoundsFolder: string;
var
  Dir, Env: string;
  I: Integer;
begin
  Env := GetEnvironmentVariable('CTRLCALM_SOUNDS');
  if (Env <> '') and DirectoryExists(Env) then
    Exit(Env);
  // Installed layout: <install>\Win32\CtrlCalm370.bpl with <install>\sounds.
  Dir := PackageFolder;
  for I := 0 to 1 do
  begin
    if FileExists(Dir + 'sounds\manifest.json') then
      Exit(Dir + 'sounds');
    Dir := ExtractFilePath(ExcludeTrailingPathDelimiter(Dir));
  end;
  // Development layout: build\RAD13\Win32\Releasein inside the repository.
  Dir := PackageFolder;
  for I := 0 to 7 do
  begin
    if DirectoryExists(Dir + 'assets\sounds') then
      Exit(Dir + 'assets\sounds');
    Dir := ExtractFilePath(ExcludeTrailingPathDelimiter(Dir));
    if Dir = '' then
      Break;
  end;
  Result := PackageFolder + 'sounds';
end;

function FindMenuItem(Parent: TMenuItem; const Name: string): TMenuItem;
var
  I: Integer;
begin
  for I := 0 to Parent.Count - 1 do
    if SameText(Parent.Items[I].Name, Name) then
      Exit(Parent.Items[I]);
  Result := nil;
end;

function Service: TCalmService;
var
  Folder: string;
begin
  if (GService = nil) and not GShuttingDown then
  begin
    Folder := FindSoundsFolder;
    CalmAssetsFolder := ExtractFileDir(Folder);
    GService := TCalmService.Create(Folder);
  end;
  Result := GService;
end;

{ TCalmWizard }

function TCalmWizard.GetIDString: string;
begin
  Result := 'CtrlCalm.Wizard';
end;

function TCalmWizard.GetName: string;
begin
  Result := 'Ctrl+Calm';
end;

function TCalmWizard.GetState: TWizardState;
begin
  Result := [wsEnabled];
end;

procedure TCalmWizard.Execute;
begin
end;

{ TCalmDockableForm }

function TCalmDockableForm.GetCaption: string;
begin
  Result := 'Ctrl+Calm';
end;

function TCalmDockableForm.GetIdentifier: string;
begin
  Result := DockIdentifier;
end;

function TCalmDockableForm.GetFrameClass: TCustomFrameClass;
begin
  Result := TCalmHostFrame;
end;

procedure TCalmDockableForm.FrameCreated(AFrame: TCustomFrame);
begin
  if Assigned(GController) then
    GController.AttachFrame(AFrame);
end;

function TCalmDockableForm.GetMenuActionList: TCustomActionList;
begin
  Result := nil;
end;

function TCalmDockableForm.GetMenuImageList: TCustomImageList;
begin
  Result := nil;
end;

procedure TCalmDockableForm.CustomizePopupMenu(PopupMenu: TPopupMenu);
begin
end;

function TCalmDockableForm.GetToolBarActionList: TCustomActionList;
begin
  Result := nil;
end;

function TCalmDockableForm.GetToolBarImageList: TCustomImageList;
begin
  Result := nil;
end;

procedure TCalmDockableForm.CustomizeToolBar(ToolBar: TToolBar);
begin
end;

procedure TCalmDockableForm.SaveWindowState(Desktop: TCustomIniFile; const Section: string;
  IsProject: Boolean);
begin
  if Assigned(GController) and Assigned(GController.View) then
    Desktop.WriteBool(Section, 'TimerVisible', GController.View.TimerVisible);
end;

procedure TCalmDockableForm.LoadWindowState(Desktop: TCustomIniFile; const Section: string);
begin
  if Assigned(GController) then
  begin
    GController.FPendingTimerVisible := Desktop.ReadBool(Section, 'TimerVisible', False);
    if Assigned(GController.View) then
      GController.View.ShowTimer(GController.FPendingTimerVisible);
  end;
end;

function TCalmDockableForm.GetEditState: TEditState;
begin
  Result := [];
end;

function TCalmDockableForm.EditAction(Action: TEditAction): Boolean;
begin
  Result := False;
end;

{ TCalmThemeNotifier }

procedure TCalmThemeNotifier.ChangingTheme;
begin
end;

procedure TCalmThemeNotifier.ChangedTheme;
begin
  if Assigned(GController) then
    GController.ThemeChanged;
end;

{ TCalmIdeController }

constructor TCalmIdeController.Create(AOwner: TComponent);
begin
  inherited;
  FActShowHide := NewAction('CtrlCalmShowHideAction', 'Show/Hide &Mixer',
    'Show or hide the Ctrl+Calm sound mixer', ShowHideExecute);
  FActShowHide.OnUpdate := ShowHideUpdate;
  FActPlayPause := NewAction('CtrlCalmPlayPauseAction', '&Play',
    'Play or pause Ctrl+Calm sounds', PlayPauseExecute);
  FActPlayPause.OnUpdate := PlayPauseUpdate;
  FActMute := NewAction('CtrlCalmMuteAction', '&Mute', 'Mute or unmute Ctrl+Calm', MuteExecute);
  FActMute.OnUpdate := MuteUpdate;
  FActTimer := NewAction('CtrlCalmTimerAction', 'Focus &Timer...', 'Open the Ctrl+Calm focus timer',
    TimerExecute);
  FActSettings := NewAction('CtrlCalmSettingsAction', '&Settings...', 'Ctrl+Calm settings',
    SettingsExecute);

  FAppEvents := TApplicationEvents.Create(Self);
  FAppEvents.OnActivate := AppActivate;
  FAppEvents.OnDeactivate := AppDeactivate;

  FStartupTimer := TTimer.Create(Self);
  FStartupTimer.Interval := 2000;
  FStartupTimer.OnTimer := StartupTick;

  // Opt-in automation endpoint for the integration test (tests/IntegrationTests/
  // IdeProbe). It exists only when the IDE was started with CTRLCALM_AUTOMATION=1
  // and accepts WM_COPYDATA commands from the same desktop session.
  if GetEnvironmentVariable('CTRLCALM_AUTOMATION') = '1' then
  begin
    FAutomationWnd := AllocateHWnd(AutomationWndProc);
    SetWindowText(FAutomationWnd, 'CtrlCalm.Automation');
  end;
end;

destructor TCalmIdeController.Destroy;
begin
  if FAutomationWnd <> 0 then
    DeallocateHWnd(FAutomationWnd);
  inherited;
end;

procedure DumpMenu(Lines: TStrings; Item: TMenuItem; const Indent: string);
var
  I: Integer;
  A: string;
begin
  if Item = nil then
    Exit;
  if Assigned(Item.Action) then
    A := Item.Action.Name
  else
    A := '-';
  Lines.Add(Format('%s%s [%s] action=%s parent=%s', [Indent, Item.Caption, Item.Name, A,
    IfThen(Assigned(Item.Parent), Item.Parent.Name, 'nil')]));
  for I := 0 to Item.Count - 1 do
    DumpMenu(Lines, Item.Items[I], Indent + '  ');
end;

procedure TCalmIdeController.AutomationWndProc(var Msg: TMessage);
var
  NTA: INTAServices;
  Lines: TStringList;
  Data: PCopyDataStruct;
  Cmd: string;
  I, Items: Integer;
  C: TComponent;
begin
  if Msg.Msg <> WM_COPYDATA then
  begin
    Msg.Result := DefWindowProc(FAutomationWnd, Msg.Msg, Msg.WParam, Msg.LParam);
    Exit;
  end;
  Msg.Result := 0;
  try
    Data := PCopyDataStruct(Msg.LParam);
    SetString(Cmd, PChar(Data.lpData), Data.cbData div SizeOf(Char));
    if Cmd = 'menu' then
    begin
      // 1000 when the submenu sits under the IDE's Tools menu, plus the
      // number of items that are bound to Ctrl+Calm actions.
      Items := 0;
      if Assigned(FMenu) then
        for I := 0 to FMenu.Count - 1 do
          if FMenu.Items[I].Action is TAction then
            Inc(Items);
      if Assigned(FMenu) and Assigned(FMenu.Parent) and SameText(FMenu.Parent.Name, 'ToolsMenu') then
        Inc(Items, 1000);
      Msg.Result := Items;
    end
    else if Cmd.StartsWith('exec:') then
    begin
      C := FindComponent(Cmd.Substring(5));
      if C is TAction then
      begin
        TAction(C).Update;
        if TAction(C).Execute then
          Msg.Result := 1;
      end;
    end
    else if Cmd = 'menudump' then
    begin
      Lines := TStringList.Create;
      try
        DumpMenu(Lines, FMenu, '');
        if Supports(BorlandIDEServices, INTAServices, NTA) then
          DumpMenu(Lines, FindMenuItem(NTA.MainMenu.Items, 'ToolsMenu'), 'T ');
        Lines.SaveToFile(IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) + 'CtrlCalmMenu.txt');
      finally
        Lines.Free;
      end;
      Msg.Result := 1;
    end
    else if Cmd = 'playing' then
      Msg.Result := Ord(Assigned(GService) and not GService.Paused)
    else if Cmd = 'visible' then
      Msg.Result := Ord(Assigned(FForm) and FForm.Visible);
  except
    Msg.Result := -1;
  end;
end;

function TCalmIdeController.NewAction(const Name, Caption, HintText: string; Handler: TNotifyEvent): TAction;
begin
  Result := TAction.Create(Self);
  Result.Name := Name;
  Result.Caption := Caption;
  Result.Hint := HintText;
  Result.Category := 'Ctrl+Calm';
  Result.OnExecute := Handler;
end;

procedure TCalmIdeController.InstallMenu;
var
  NTA: INTAServices;
  Tools, Options: TMenuItem;

  procedure AddItem(A: TAction);
  var
    Item: TMenuItem;
  begin
    // The action joins the IDE's main action list, so it appears in the IDE's
    // keyboard-shortcut and toolbar customization like any other command.
    A.ActionList := NTA.ActionList;
    Item := TMenuItem.Create(Self);
    Item.Name := A.Name + 'Item';
    Item.Action := A;
    FMenu.Add(Item);
  end;

var
  Sep: TMenuItem;
begin
  if not Supports(BorlandIDEServices, INTAServices, NTA) then
    Exit;
  FMenu := TMenuItem.Create(Self);
  FMenu.Name := MenuName;
  FMenu.Caption := 'Ctrl+&Calm';
  FMenu.FreeNotification(Self);
  AddItem(FActShowHide);
  AddItem(FActPlayPause);
  AddItem(FActMute);
  AddItem(FActTimer);
  Sep := TMenuItem.Create(Self);
  Sep.Caption := '-';
  FMenu.Add(Sep);
  AddItem(FActSettings);

  NTA.MenuBeginUpdate;
  try
    // Tools > Ctrl+Calm, at the top of the Tools menu (before Options). The
    // end of the Tools menu is rebuilt by the IDE from the user's configured
    // external tools, which removes items appended there.
    Tools := FindMenuItem(NTA.MainMenu.Items, 'ToolsMenu');
    if Assigned(Tools) then
    begin
      Options := FindMenuItem(Tools, 'ToolsOptionsItem');
      if Assigned(Options) then
        Tools.Insert(Options.MenuIndex, FMenu)
      else
        Tools.Insert(0, FMenu);
    end
    else
      NTA.MainMenu.Items.Add(FMenu);
  finally
    NTA.MenuEndUpdate;
  end;
end;

procedure TCalmIdeController.RemoveMenu;
var
  I: Integer;
begin
  // Free the menu items first so the IDE menu never references freed actions,
  // then detach the actions from the IDE action list.
  FreeAndNil(FMenu);
  for I := ComponentCount - 1 downto 0 do
    if Components[I] is TAction then
      TAction(Components[I]).ActionList := nil;
end;

procedure TCalmIdeController.ApplyShortcuts;
begin
  if GService <> nil then
    ApplyShortcuts(GService.Settings);
end;

procedure TCalmIdeController.ApplyShortcuts(const S: TCalmSettings);
begin
  FActShowHide.ShortCut := S.Shortcuts[saShowHide];
  FActPlayPause.ShortCut := S.Shortcuts[saPlayPause];
  FActMute.ShortCut := S.Shortcuts[saMute];
  FActTimer.ShortCut := S.Shortcuts[saTimer];
end;

procedure TCalmIdeController.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if Operation = opRemove then
  begin
    if AComponent = FMenu then
      FMenu := nil
    else if AComponent = FForm then
    begin
      FForm := nil;
      FView := nil;
    end
    else if AComponent = FView then
      FView := nil;
  end;
end;

procedure TCalmIdeController.AttachFrame(AFrame: TCustomFrame);
var
  F: TCustomForm;
  Th: IOTAIDEThemingServices;
begin
  if GShuttingDown or (Service = nil) then
    Exit;
  F := GetParentForm(AFrame);
  if Assigned(F) and (F <> FForm) then
  begin
    FForm := F;
    FForm.FreeNotification(Self);
  end;
  FView := TCalmMixerView.Create(AFrame, Service);
  FView.Parent := AFrame;
  FView.Align := alClient;
  FView.OnOpenSettings := OpenSettings;
  FView.FreeNotification(Self);
  FView.ShowTimer(FPendingTimerVisible);
  Th := ThemingServices;
  if Assigned(Th) and Th.IDEThemingEnabled and Assigned(FForm) then
    Th.ApplyTheme(FForm);
  FView.RefreshTheme;
end;

procedure TCalmIdeController.ShowPanel(FocusTimer: Boolean);
var
  NTA: INTAServices;
  F: TCustomForm;
begin
  if not Assigned(FForm) then
  begin
    if Supports(BorlandIDEServices, INTAServices, NTA) and Assigned(GDockable) then
    begin
      // CreateDockableForm shows the form and calls FrameCreated.
      FPendingTimerVisible := FocusTimer or FPendingTimerVisible;
      F := NTA.CreateDockableForm(GDockable);
      if not Assigned(FForm) and Assigned(F) then
      begin
        FForm := F;
        FForm.FreeNotification(Self);
      end;
    end;
  end
  else
  begin
    FForm.Show;
    FForm.BringToFront;
  end;
  if FocusTimer and Assigned(FView) then
    FView.ShowTimer(True);
  if Assigned(FForm) and FForm.Visible and FForm.CanFocus then
    FForm.SetFocus;
end;

procedure TCalmIdeController.DestroyPanel;
begin
  if Assigned(FForm) then
  begin
    FForm.RemoveFreeNotification(Self);
    FreeAndNil(FForm); // also frees the frame and the view
  end;
  FView := nil;
end;

procedure TCalmIdeController.ThemeChanged;
var
  Th: IOTAIDEThemingServices;
begin
  Th := ThemingServices;
  if Assigned(Th) and Th.IDEThemingEnabled and Assigned(FForm) then
    Th.ApplyTheme(FForm);
  if Assigned(FView) then
    FView.RefreshTheme;
  // An open settings dialog follows the switch immediately.
  if Assigned(CalmOpenSettingsForm) and Assigned(CalmPrepareForm) then
    CalmPrepareForm(CalmOpenSettingsForm);
end;

procedure TCalmIdeController.ShowHideExecute(Sender: TObject);
begin
  if Assigned(FForm) and FForm.Visible then
    FForm.Hide // playback and the timer keep running
  else
    ShowPanel;
end;

procedure TCalmIdeController.ShowHideUpdate(Sender: TObject);
begin
  FActShowHide.Checked := Assigned(FForm) and FForm.Visible;
end;

procedure TCalmIdeController.PlayPauseExecute(Sender: TObject);
begin
  if Service.HasActiveSounds then
    Service.TogglePlayPause
  else
    ShowPanel; // nothing to play yet: show the mixer instead
end;

procedure TCalmIdeController.PlayPauseUpdate(Sender: TObject);
begin
  if Assigned(GService) and not GService.Paused then
    FActPlayPause.Caption := '&Pause'
  else
    FActPlayPause.Caption := '&Play';
end;

procedure TCalmIdeController.MuteExecute(Sender: TObject);
begin
  Service.ToggleMute;
end;

procedure TCalmIdeController.MuteUpdate(Sender: TObject);
begin
  FActMute.Checked := Assigned(GService) and GService.Muted;
end;

procedure TCalmIdeController.TimerExecute(Sender: TObject);
begin
  ShowPanel(True);
end;

procedure TCalmIdeController.SettingsExecute(Sender: TObject);
begin
  OpenSettings(Self);
end;

procedure TCalmIdeController.OpenSettings(Sender: TObject);
begin
  if Service <> nil then
    ShowCalmSettings(Service);
end;

procedure TCalmIdeController.AppActivate(Sender: TObject);
begin
  if Assigned(GService) then
    GService.SetIdeFocused(True);
end;

procedure TCalmIdeController.AppDeactivate(Sender: TObject);
begin
  if Assigned(GService) then
    GService.SetIdeFocused(False);
end;

procedure TCalmIdeController.StartupTick(Sender: TObject);
var
  S: TCalmSettings;
  Store: TSettingsStore;
begin
  FStartupTimer.Enabled := False;
  if GShuttingDown then
    Exit;
  // Read preferences without starting the audio worker. The worker is only
  // created now if the user asked for it (open panel / auto-resume);
  // otherwise it starts on first use.
  Store := TSettingsStore.Create(DefaultSettingsFileName);
  try
    Store.Load(S);
  finally
    Store.Free;
  end;
  ApplyShortcuts(S);
  if S.Audio.Startup = sbAutoResume then
    Service;
  if S.General.OpenPanelAtStartup and not Assigned(FForm) then
    ShowPanel;
end;

{ Registration }

procedure Register;
var
  NTA: INTAServices;
  Th: IOTAIDEThemingServices;
begin
  RegisterPackageWizard(TCalmWizard.Create);

  CalmStyleServicesProvider :=
    function: TCustomStyleServices
    var
      T: IOTAIDEThemingServices;
    begin
      Result := nil;
      T := ThemingServices;
      if Assigned(T) and T.IDEThemingEnabled then
        Result := T.StyleServices;
    end;
  CalmPrepareForm :=
    procedure(F: TCustomForm)
    var
      T: IOTAIDEThemingServices;
      SS: TCustomStyleServices;
    begin
      T := ThemingServices;
      if not (Assigned(T) and T.IDEThemingEnabled) then
        Exit;
      // Bind the form to the IDE's *current* style explicitly; otherwise a
      // form can keep the style that was active when its class was registered.
      SS := T.StyleServices;
      if Assigned(SS) and (SS.Name <> '') and (TStyleManager.Style[SS.Name] <> nil) then
        TForm(F).StyleName := SS.Name;
      T.ApplyTheme(F);
      F.Invalidate;
    end;
  CalmShortcutsChanged :=
    procedure
    begin
      if Assigned(GController) then
        GController.ApplyShortcuts;
    end;

  GController := TCalmIdeController.Create(nil);
  try
    GController.InstallMenu;
  except
    // A menu problem must not prevent the package from loading; the panel
    // can still be restored from the desktop layout.
  end;

  Th := ThemingServices;
  if Assigned(Th) then
  begin
    Th.RegisterFormClass(TCalmSettingsForm);
    GThemeNotifierIndex := Th.AddNotifier(TCalmThemeNotifier.Create);
  end;

  // Registering during Register lets the IDE restore the window from the
  // saved desktop layout.
  GDockable := TCalmDockableForm.Create;
  if Supports(BorlandIDEServices, INTAServices, NTA) then
    NTA.RegisterDockableForm(GDockable);
end;

procedure Unregister;
var
  NTA: INTAServices;
  Th: IOTAIDEThemingServices;
begin
  GShuttingDown := True;
  // Reverse order of Register. Each step is guarded: a failure in one step
  // must not prevent the remaining cleanup.
  try
    if Assigned(GController) then
    begin
      GController.FStartupTimer.Enabled := False;
      GController.RemoveMenu;
      GController.DestroyPanel;
    end;
  except
  end;
  try
    if Assigned(GDockable) and Supports(BorlandIDEServices, INTAServices, NTA) then
      NTA.UnregisterDockableForm(GDockable);
  except
  end;
  GDockable := nil;
  try
    Th := ThemingServices;
    if Assigned(Th) and (GThemeNotifierIndex >= 0) then
      Th.RemoveNotifier(GThemeNotifierIndex);
  except
  end;
  GThemeNotifierIndex := -1;
  FreeAndNil(GController);
  CalmStyleServicesProvider := nil;
  CalmPrepareForm := nil;
  CalmShortcutsChanged := nil;
  // Last: stops the worker (ordered audio shutdown) and joins its thread.
  FreeAndNil(GService);
end;

initialization

finalization
  Unregister;

end.
