unit CtrlCalm.TestUtils;

{ Helpers shared by the test suites: WAV file builders, temporary folders and
  a minimal binding to the default render endpoint's peak meter (Core Audio,
  mmdeviceapi.h / endpointvolume.h) used to prove that sound reaches the
  device. Test-only code; never linked into the IDE package. }

interface

uses
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.Classes, System.IOUtils;

type
  TSampleFunc = reference to function(Frame, Channel: Integer): SmallInt;

  TWavBuilder = class
  private
    FStream: TMemoryStream;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Bytes(const B: array of Byte);
    procedure Tag(const T: AnsiString);
    procedure U32(V: Cardinal);
    procedure U16(V: Word);
    procedure Fmt(Tag, Channels: Word; Rate: Cardinal; Bits: Word);
    procedure FmtExtensible(Channels: Word; Rate: Cardinal; Bits: Word; const SubFormat: TGUID);
    procedure Chunk(const Id: AnsiString; Size: Cardinal; PayloadBytes: Integer = -1);
    procedure Data(Frames, Channels: Integer; const F: TSampleFunc; DeclaredBytes: Int64 = -1);
    /// <summary>Writes "RIFF", size, "WAVE" in front of the body built so far.</summary>
    procedure SaveRiff(const FileName: string; RiffSize: Int64 = -1);
    function Body: TMemoryStream;
  end;

const
  SubtypePCM: TGUID = '{00000001-0000-0010-8000-00AA00389B71}';
  SubtypeFloat: TGUID = '{00000003-0000-0010-8000-00AA00389B71}';

function NewTempFolder(const Prefix: string): string;
procedure WriteSimpleWav(const FileName: string; Rate, Channels, Frames: Integer; const F: TSampleFunc);

/// <summary>Peak level (0..1) of the default render endpoint, or -1 if it
/// cannot be read.</summary>
function EndpointPeak: Single;
/// <summary>Peak level of the audio sessions owned by a process on the default
/// render endpoint, or -1 if the process has no session there.</summary>
function ProcessSessionPeak(ProcessId: DWORD): Single;
function ProcessPrivateBytes: UInt64;

implementation

uses
  Winapi.PsAPI;

{ TWavBuilder }

constructor TWavBuilder.Create;
begin
  FStream := TMemoryStream.Create;
end;

destructor TWavBuilder.Destroy;
begin
  FStream.Free;
  inherited;
end;

function TWavBuilder.Body: TMemoryStream;
begin
  Result := FStream;
end;

procedure TWavBuilder.Bytes(const B: array of Byte);
begin
  if Length(B) > 0 then
    FStream.WriteBuffer(B[0], Length(B));
end;

procedure TWavBuilder.Tag(const T: AnsiString);
begin
  FStream.WriteBuffer(T[1], 4);
end;

procedure TWavBuilder.U32(V: Cardinal);
begin
  FStream.WriteBuffer(V, 4);
end;

procedure TWavBuilder.U16(V: Word);
begin
  FStream.WriteBuffer(V, 2);
end;

procedure TWavBuilder.Fmt(Tag, Channels: Word; Rate: Cardinal; Bits: Word);
begin
  Self.Tag('fmt ');
  U32(16);
  U16(Tag);
  U16(Channels);
  U32(Rate);
  U32(Rate * Channels * (Bits div 8));
  U16(Channels * (Bits div 8));
  U16(Bits);
end;

procedure TWavBuilder.FmtExtensible(Channels: Word; Rate: Cardinal; Bits: Word; const SubFormat: TGUID);
begin
  Tag('fmt ');
  U32(40);
  U16($FFFE);
  U16(Channels);
  U32(Rate);
  U32(Rate * Channels * (Bits div 8));
  U16(Channels * (Bits div 8));
  U16(Bits);
  U16(22);
  U16(Bits);
  U32(3);
  FStream.WriteBuffer(SubFormat, SizeOf(TGUID));
end;

procedure TWavBuilder.Chunk(const Id: AnsiString; Size: Cardinal; PayloadBytes: Integer);
var
  B: TBytes;
begin
  Tag(Id);
  U32(Size);
  if PayloadBytes < 0 then
    PayloadBytes := Size + (Size and 1);
  SetLength(B, PayloadBytes);
  if PayloadBytes > 0 then
  begin
    FillChar(B[0], PayloadBytes, $AB);
    FStream.WriteBuffer(B[0], PayloadBytes);
  end;
end;

procedure TWavBuilder.Data(Frames, Channels: Integer; const F: TSampleFunc; DeclaredBytes: Int64);
var
  I, C: Integer;
  S: SmallInt;
begin
  Tag('data');
  if DeclaredBytes < 0 then
    DeclaredBytes := Int64(Frames) * Channels * 2;
  U32(Cardinal(DeclaredBytes));
  for I := 0 to Frames - 1 do
    for C := 0 to Channels - 1 do
    begin
      S := F(I, C);
      FStream.WriteBuffer(S, 2);
    end;
end;

procedure TWavBuilder.SaveRiff(const FileName: string; RiffSize: Int64);
var
  Dst: TFileStream;
  Hdr: AnsiString;
  Size: Cardinal;
begin
  Dst := TFileStream.Create(FileName, fmCreate);
  try
    Hdr := 'RIFF';
    Dst.WriteBuffer(Hdr[1], 4);
    if RiffSize < 0 then
      RiffSize := FStream.Size + 4;
    Size := Cardinal(RiffSize);
    Dst.WriteBuffer(Size, 4);
    Hdr := 'WAVE';
    Dst.WriteBuffer(Hdr[1], 4);
    FStream.Position := 0;
    Dst.CopyFrom(FStream, FStream.Size);
  finally
    Dst.Free;
  end;
end;

function NewTempFolder(const Prefix: string): string;
var
  G: TGUID;
begin
  CreateGUID(G);
  Result := TPath.Combine(TPath.GetTempPath, Prefix + '-' + Copy(G.ToString, 2, 8));
  ForceDirectories(Result);
end;

procedure WriteSimpleWav(const FileName: string; Rate, Channels, Frames: Integer; const F: TSampleFunc);
var
  B: TWavBuilder;
begin
  B := TWavBuilder.Create;
  try
    B.Fmt(1, Channels, Rate, 16);
    B.Data(Frames, Channels, F);
    B.SaveRiff(FileName);
  finally
    B.Free;
  end;
end;

{ Endpoint meter (test-only Core Audio bindings, from the Windows SDK headers) }

const
  CLSID_MMDeviceEnumerator: TGUID = '{BCDE0395-E52F-467C-8E3D-C4579291692E}';
  eRender = 0;
  eConsole = 0;

type
  IMMDevice = interface(IUnknown)
    ['{D666063F-1587-4E43-81F1-B948E807363F}']
    function Activate(const iid: TGUID; dwClsCtx: DWORD; pActivationParams: Pointer;
      out ppInterface): HRESULT; stdcall;
    function OpenPropertyStore(stgmAccess: DWORD; out ppProperties: IUnknown): HRESULT; stdcall;
    function GetId(out ppstrId: PWideChar): HRESULT; stdcall;
    function GetState(out pdwState: DWORD): HRESULT; stdcall;
  end;

  IMMDeviceEnumerator = interface(IUnknown)
    ['{A95664D2-9614-4F35-A746-DE8DB63617E6}']
    function EnumAudioEndpoints(dataFlow: Integer; dwStateMask: DWORD; out ppDevices: IUnknown): HRESULT; stdcall;
    function GetDefaultAudioEndpoint(dataFlow, role: Integer; out ppEndpoint: IMMDevice): HRESULT; stdcall;
    function GetDevice(pwstrId: PWideChar; out ppDevice: IMMDevice): HRESULT; stdcall;
    function RegisterEndpointNotificationCallback(pClient: Pointer): HRESULT; stdcall;
    function UnregisterEndpointNotificationCallback(pClient: Pointer): HRESULT; stdcall;
  end;

  IAudioMeterInformation = interface(IUnknown)
    ['{C02216F6-8C67-4B5B-9D00-D008E73E0064}']
    function GetPeakValue(out pfPeak: Single): HRESULT; stdcall;
    function GetMeteringChannelCount(out pnChannelCount: UINT): HRESULT; stdcall;
    function GetChannelsPeakValues(u32ChannelCount: UINT32; afPeakValues: PSingle): HRESULT; stdcall;
    function QueryHardwareSupport(out pdwHardwareSupportMask: DWORD): HRESULT; stdcall;
  end;

type
  IAudioSessionControl = interface(IUnknown)
    ['{F4B1A599-7266-4319-A8CA-E70ACB11E8CD}']
    function GetState(out pRetVal: Integer): HRESULT; stdcall;
    function GetDisplayName(out pRetVal: PWideChar): HRESULT; stdcall;
    function SetDisplayName(Value: PWideChar; EventContext: PGUID): HRESULT; stdcall;
    function GetIconPath(out pRetVal: PWideChar): HRESULT; stdcall;
    function SetIconPath(Value: PWideChar; EventContext: PGUID): HRESULT; stdcall;
    function GetGroupingParam(out pRetVal: TGUID): HRESULT; stdcall;
    function SetGroupingParam(const Override_: TGUID; EventContext: PGUID): HRESULT; stdcall;
    function RegisterAudioSessionNotification(NewNotifications: IUnknown): HRESULT; stdcall;
    function UnregisterAudioSessionNotification(NewNotifications: IUnknown): HRESULT; stdcall;
  end;

  IAudioSessionControl2 = interface(IAudioSessionControl)
    ['{BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D}']
    function GetSessionIdentifier(out pRetVal: PWideChar): HRESULT; stdcall;
    function GetSessionInstanceIdentifier(out pRetVal: PWideChar): HRESULT; stdcall;
    function GetProcessId(out pRetVal: DWORD): HRESULT; stdcall;
    function IsSystemSoundsSession: HRESULT; stdcall;
    function SetDuckingPreference(optOut: BOOL): HRESULT; stdcall;
  end;

  IAudioSessionEnumerator = interface(IUnknown)
    ['{E2F5BB11-0570-40CA-ACDD-3AA01277DEE8}']
    function GetCount(out SessionCount: Integer): HRESULT; stdcall;
    function GetSession(SessionCount: Integer; out Session: IAudioSessionControl): HRESULT; stdcall;
  end;

  IAudioSessionManager = interface(IUnknown)
    ['{BFA971F1-4D5E-40BB-935E-967039BFBEE4}']
    function GetAudioSessionControl(AudioSessionGuid: PGUID; StreamFlags: DWORD;
      out SessionControl: IAudioSessionControl): HRESULT; stdcall;
    function GetSimpleAudioVolume(AudioSessionGuid: PGUID; StreamFlags: DWORD;
      out AudioVolume: IUnknown): HRESULT; stdcall;
  end;

  IAudioSessionManager2 = interface(IAudioSessionManager)
    ['{77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F}']
    function GetSessionEnumerator(out SessionEnum: IAudioSessionEnumerator): HRESULT; stdcall;
    function RegisterSessionNotification(SessionNotification: IUnknown): HRESULT; stdcall;
    function UnregisterSessionNotification(SessionNotification: IUnknown): HRESULT; stdcall;
    function RegisterDuckNotification(sessionID: PWideChar; duckNotification: IUnknown): HRESULT; stdcall;
    function UnregisterDuckNotification(duckNotification: IUnknown): HRESULT; stdcall;
  end;

function ProcessSessionPeak(ProcessId: DWORD): Single;
var
  Enum: IMMDeviceEnumerator;
  Dev: IMMDevice;
  Mgr: IAudioSessionManager2;
  Sessions: IAudioSessionEnumerator;
  Ctl: IAudioSessionControl;
  Ctl2: IAudioSessionControl2;
  Meter: IAudioMeterInformation;
  I, N: Integer;
  Pid: DWORD;
  Peak: Single;
begin
  Result := -1;
  if Failed(CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL, IMMDeviceEnumerator, Enum)) or
     Failed(Enum.GetDefaultAudioEndpoint(eRender, eConsole, Dev)) or
     Failed(Dev.Activate(IAudioSessionManager2, CLSCTX_ALL, nil, Mgr)) or
     Failed(Mgr.GetSessionEnumerator(Sessions)) or Failed(Sessions.GetCount(N)) then
    Exit;
  for I := 0 to N - 1 do
    if Succeeded(Sessions.GetSession(I, Ctl)) and Supports(Ctl, IAudioSessionControl2, Ctl2) and
       Succeeded(Ctl2.GetProcessId(Pid)) and (Pid = ProcessId) and
       Supports(Ctl, IAudioMeterInformation, Meter) and Succeeded(Meter.GetPeakValue(Peak)) then
      if Peak > Result then
        Result := Peak;
end;

function EndpointPeak: Single;
var
  Enum: IMMDeviceEnumerator;
  Dev: IMMDevice;
  Meter: IAudioMeterInformation;
begin
  Result := -1;
  if Failed(CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL, IMMDeviceEnumerator, Enum)) then
    Exit;
  if Failed(Enum.GetDefaultAudioEndpoint(eRender, eConsole, Dev)) then
    Exit;
  if Failed(Dev.Activate(IAudioMeterInformation, CLSCTX_ALL, nil, Meter)) then
    Exit;
  if Failed(Meter.GetPeakValue(Result)) then
    Result := -1;
end;

function ProcessPrivateBytes: UInt64;
var
  C: PROCESS_MEMORY_COUNTERS_EX;
begin
  C := Default(PROCESS_MEMORY_COUNTERS_EX);
  C.cb := SizeOf(C);
  if GetProcessMemoryInfo(GetCurrentProcess, @C, SizeOf(C)) then
    Result := C.PrivateUsage
  else
    Result := 0;
end;

end.
