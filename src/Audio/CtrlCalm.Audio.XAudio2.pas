unit CtrlCalm.Audio.XAudio2;

{
  Minimal Delphi bindings for XAudio2 2.9 (xaudio2_9.dll, a Windows 10+ system
  component).

  Translated from the Windows SDK header um\xaudio2.h (10.0.26100.0). Only the
  declarations Ctrl+Calm needs are bound, but every vtable is declared in full
  and in header order so that slot offsets are exact.

  Binary-compatibility notes:
  - xaudio2.h wraps every structure in #pragma pack(push, 1); all records here
    are therefore "packed".
  - IXAudio2 derives from IUnknown and is bound as a Delphi interface.
  - IXAudio2Voice / SourceVoice / SubmixVoice / MasteringVoice and the two
    callback interfaces do NOT derive from IUnknown. They are bound as explicit
    vtable records whose entries take the object pointer ("This") as the first
    argument, exactly like the C declaration produced by DECLARE_INTERFACE.
  - All methods are __stdcall (STDMETHOD). On Win64 the single x64 calling
    convention applies and "stdcall" is ignored by the compiler.
}

interface

uses
  Winapi.Windows, Winapi.MMSystem;

const
  XAUDIO2_DLL = 'xaudio2_9.dll';

  IID_IXAudio2: TGUID = '{2B02E3CF-2E0B-4EC3-BE45-1B2A3FE7210D}';

  XAUDIO2_MAX_BUFFER_BYTES   = $80000000;
  XAUDIO2_MAX_QUEUED_BUFFERS = 64;
  XAUDIO2_MAX_VOLUME_LEVEL   = 16777216.0;
  XAUDIO2_DEFAULT_FREQ_RATIO = 2.0;

  XAUDIO2_COMMIT_NOW        = 0;
  XAUDIO2_COMMIT_ALL        = 0;
  XAUDIO2_NO_LOOP_REGION    = 0;
  XAUDIO2_LOOP_INFINITE     = 255;
  XAUDIO2_DEFAULT_CHANNELS  = 0;
  XAUDIO2_DEFAULT_SAMPLERATE = 0;

  XAUDIO2_DEBUG_ENGINE          = $0001;
  XAUDIO2_VOICE_NOPITCH         = $0002;
  XAUDIO2_VOICE_NOSRC           = $0004;
  XAUDIO2_VOICE_USEFILTER       = $0008;
  XAUDIO2_PLAY_TAILS            = $0020;
  XAUDIO2_END_OF_STREAM         = $0040;
  XAUDIO2_SEND_USEFILTER        = $0080;
  XAUDIO2_VOICE_NOSAMPLESPLAYED = $0100;
  XAUDIO2_STOP_ENGINE_WHEN_IDLE = $2000;
  XAUDIO2_1024_QUANTUM          = $8000;
  XAUDIO2_NO_VIRTUAL_AUDIO_CLIENT = $10000;

  XAUDIO2_DEFAULT_PROCESSOR = $00000001; // Processor1

  XAUDIO2_E_INVALID_CALL          = HRESULT($88960001);
  XAUDIO2_E_XMA_DECODER_ERROR     = HRESULT($88960002);
  XAUDIO2_E_XAPO_CREATION_FAILED  = HRESULT($88960003);
  XAUDIO2_E_DEVICE_INVALIDATED    = HRESULT($88960004);

  // AUDIO_STREAM_CATEGORY (audiosessiontypes.h)
  AudioCategory_Other = 0;
  AudioCategory_Media = 11;

  // NTDDI_WIN10_RS5, passed to XAudio2CreateWithVersionInfo.
  CC_NTDDI_WIN10_RS5 = $0A000006;

  WAVE_FORMAT_IEEE_FLOAT = $0003;
  WAVE_FORMAT_EXTENSIBLE = $FFFE;

type
  PXAudio2VoiceDetails = ^TXAudio2VoiceDetails;
  TXAudio2VoiceDetails = packed record
    CreationFlags: UINT32;
    ActiveFlags: UINT32;
    InputChannels: UINT32;
    InputSampleRate: UINT32;
  end;

  PXAudio2SendDescriptor = ^TXAudio2SendDescriptor;
  TXAudio2SendDescriptor = packed record
    Flags: UINT32;
    pOutputVoice: Pointer; // IXAudio2Voice*
  end;

  PXAudio2VoiceSends = ^TXAudio2VoiceSends;
  TXAudio2VoiceSends = packed record
    SendCount: UINT32;
    pSends: PXAudio2SendDescriptor;
  end;

  PXAudio2EffectDescriptor = ^TXAudio2EffectDescriptor;
  TXAudio2EffectDescriptor = packed record
    pEffect: Pointer; // IUnknown*
    InitialState: BOOL;
    OutputChannels: UINT32;
  end;

  PXAudio2EffectChain = ^TXAudio2EffectChain;
  TXAudio2EffectChain = packed record
    EffectCount: UINT32;
    pEffectDescriptors: PXAudio2EffectDescriptor;
  end;

  PXAudio2FilterParameters = ^TXAudio2FilterParameters;
  TXAudio2FilterParameters = packed record
    FilterType: UINT32; // XAUDIO2_FILTER_TYPE (C enum, 4 bytes)
    Frequency: Single;
    OneOverQ: Single;
  end;

  PXAudio2Buffer = ^TXAudio2Buffer;
  TXAudio2Buffer = packed record
    Flags: UINT32;
    AudioBytes: UINT32;
    pAudioData: PByte;
    PlayBegin: UINT32;
    PlayLength: UINT32;
    LoopBegin: UINT32;
    LoopLength: UINT32;
    LoopCount: UINT32;
    pContext: Pointer;
  end;

  PXAudio2VoiceState = ^TXAudio2VoiceState;
  TXAudio2VoiceState = packed record
    pCurrentBufferContext: Pointer;
    BuffersQueued: UINT32;
    SamplesPlayed: UINT64;
  end;

  PXAudio2PerformanceData = ^TXAudio2PerformanceData;
  TXAudio2PerformanceData = packed record
    AudioCyclesSinceLastQuery: UINT64;
    TotalCyclesSinceLastQuery: UINT64;
    MinimumCyclesPerQuantum: UINT32;
    MaximumCyclesPerQuantum: UINT32;
    MemoryUsageInBytes: UINT32;
    CurrentLatencyInSamples: UINT32;
    GlitchesSinceEngineStarted: UINT32;
    ActiveSourceVoiceCount: UINT32;
    TotalSourceVoiceCount: UINT32;
    ActiveSubmixVoiceCount: UINT32;
    ActiveResamplerCount: UINT32;
    ActiveMatrixMixCount: UINT32;
    ActiveXmaSourceVoices: UINT32;
    ActiveXmaStreams: UINT32;
  end;

  { IXAudio2Voice vtable (header order). }
  PIXAudio2VoiceVtbl = ^TIXAudio2VoiceVtbl;
  TIXAudio2VoiceVtbl = record
    GetVoiceDetails: procedure(This: Pointer; pVoiceDetails: PXAudio2VoiceDetails); stdcall;
    SetOutputVoices: function(This: Pointer; pSendList: PXAudio2VoiceSends): HRESULT; stdcall;
    SetEffectChain: function(This: Pointer; pEffectChain: PXAudio2EffectChain): HRESULT; stdcall;
    EnableEffect: function(This: Pointer; EffectIndex, OperationSet: UINT32): HRESULT; stdcall;
    DisableEffect: function(This: Pointer; EffectIndex, OperationSet: UINT32): HRESULT; stdcall;
    GetEffectState: procedure(This: Pointer; EffectIndex: UINT32; pEnabled: PBOOL); stdcall;
    SetEffectParameters: function(This: Pointer; EffectIndex: UINT32; pParameters: Pointer;
      ParametersByteSize, OperationSet: UINT32): HRESULT; stdcall;
    GetEffectParameters: function(This: Pointer; EffectIndex: UINT32; pParameters: Pointer;
      ParametersByteSize: UINT32): HRESULT; stdcall;
    SetFilterParameters: function(This: Pointer; pParameters: PXAudio2FilterParameters;
      OperationSet: UINT32): HRESULT; stdcall;
    GetFilterParameters: procedure(This: Pointer; pParameters: PXAudio2FilterParameters); stdcall;
    SetOutputFilterParameters: function(This: Pointer; pDestinationVoice: Pointer;
      pParameters: PXAudio2FilterParameters; OperationSet: UINT32): HRESULT; stdcall;
    GetOutputFilterParameters: procedure(This: Pointer; pDestinationVoice: Pointer;
      pParameters: PXAudio2FilterParameters); stdcall;
    SetVolume: function(This: Pointer; Volume: Single; OperationSet: UINT32): HRESULT; stdcall;
    GetVolume: procedure(This: Pointer; pVolume: PSingle); stdcall;
    SetChannelVolumes: function(This: Pointer; Channels: UINT32; pVolumes: PSingle;
      OperationSet: UINT32): HRESULT; stdcall;
    GetChannelVolumes: procedure(This: Pointer; Channels: UINT32; pVolumes: PSingle); stdcall;
    SetOutputMatrix: function(This: Pointer; pDestinationVoice: Pointer;
      SourceChannels, DestinationChannels: UINT32; pLevelMatrix: PSingle;
      OperationSet: UINT32): HRESULT; stdcall;
    GetOutputMatrix: procedure(This: Pointer; pDestinationVoice: Pointer;
      SourceChannels, DestinationChannels: UINT32; pLevelMatrix: PSingle); stdcall;
    DestroyVoice: procedure(This: Pointer); stdcall;
  end;

  { IXAudio2SourceVoice vtable: IXAudio2Voice methods followed by its own. }
  PIXAudio2SourceVoiceVtbl = ^TIXAudio2SourceVoiceVtbl;
  TIXAudio2SourceVoiceVtbl = record
    Voice: TIXAudio2VoiceVtbl;
    Start: function(This: Pointer; Flags, OperationSet: UINT32): HRESULT; stdcall;
    Stop: function(This: Pointer; Flags, OperationSet: UINT32): HRESULT; stdcall;
    SubmitSourceBuffer: function(This: Pointer; pBuffer: PXAudio2Buffer;
      pBufferWMA: Pointer): HRESULT; stdcall;
    FlushSourceBuffers: function(This: Pointer): HRESULT; stdcall;
    Discontinuity: function(This: Pointer): HRESULT; stdcall;
    ExitLoop: function(This: Pointer; OperationSet: UINT32): HRESULT; stdcall;
    GetState: procedure(This: Pointer; pVoiceState: PXAudio2VoiceState; Flags: UINT32); stdcall;
    SetFrequencyRatio: function(This: Pointer; Ratio: Single; OperationSet: UINT32): HRESULT; stdcall;
    GetFrequencyRatio: procedure(This: Pointer; pRatio: PSingle); stdcall;
    SetSourceSampleRate: function(This: Pointer; NewSourceSampleRate: UINT32): HRESULT; stdcall;
  end;

  { IXAudio2MasteringVoice vtable. }
  PIXAudio2MasteringVoiceVtbl = ^TIXAudio2MasteringVoiceVtbl;
  TIXAudio2MasteringVoiceVtbl = record
    Voice: TIXAudio2VoiceVtbl;
    GetChannelMask: function(This: Pointer; pChannelmask: PDWORD): HRESULT; stdcall;
  end;

  PIXAudio2SourceVoice = ^TIXAudio2SourceVoice;
  TIXAudio2SourceVoice = record
    lpVtbl: PIXAudio2SourceVoiceVtbl;
  end;

  PIXAudio2MasteringVoice = ^TIXAudio2MasteringVoice;
  TIXAudio2MasteringVoice = record
    lpVtbl: PIXAudio2MasteringVoiceVtbl;
  end;

  PIXAudio2SubmixVoice = Pointer;

  { IXAudio2EngineCallback, implemented by the client. }
  PIXAudio2EngineCallbackVtbl = ^TIXAudio2EngineCallbackVtbl;
  TIXAudio2EngineCallbackVtbl = record
    OnProcessingPassStart: procedure(This: Pointer); stdcall;
    OnProcessingPassEnd: procedure(This: Pointer); stdcall;
    OnCriticalError: procedure(This: Pointer; Error: HRESULT); stdcall;
  end;

  PIXAudio2EngineCallback = ^TIXAudio2EngineCallback;
  TIXAudio2EngineCallback = record
    lpVtbl: PIXAudio2EngineCallbackVtbl;
    Context: Pointer; // Ctrl+Calm extension: not seen by XAudio2.
  end;

  { IXAudio2VoiceCallback, implemented by the client. }
  PIXAudio2VoiceCallbackVtbl = ^TIXAudio2VoiceCallbackVtbl;
  TIXAudio2VoiceCallbackVtbl = record
    OnVoiceProcessingPassStart: procedure(This: Pointer; BytesRequired: UINT32); stdcall;
    OnVoiceProcessingPassEnd: procedure(This: Pointer); stdcall;
    OnStreamEnd: procedure(This: Pointer); stdcall;
    OnBufferStart: procedure(This: Pointer; pBufferContext: Pointer); stdcall;
    OnBufferEnd: procedure(This: Pointer; pBufferContext: Pointer); stdcall;
    OnLoopEnd: procedure(This: Pointer; pBufferContext: Pointer); stdcall;
    OnVoiceError: procedure(This: Pointer; pBufferContext: Pointer; Error: HRESULT); stdcall;
  end;

  PIXAudio2VoiceCallback = ^TIXAudio2VoiceCallback;
  TIXAudio2VoiceCallback = record
    lpVtbl: PIXAudio2VoiceCallbackVtbl;
    Context: Pointer; // Ctrl+Calm extension: not seen by XAudio2.
  end;

  IXAudio2 = interface(IUnknown)
    ['{2B02E3CF-2E0B-4EC3-BE45-1B2A3FE7210D}']
    function RegisterForCallbacks(pCallback: PIXAudio2EngineCallback): HRESULT; stdcall;
    procedure UnregisterForCallbacks(pCallback: PIXAudio2EngineCallback); stdcall;
    function CreateSourceVoice(out ppSourceVoice: PIXAudio2SourceVoice;
      pSourceFormat: PWaveFormatEx; Flags: UINT32; MaxFrequencyRatio: Single;
      pCallback: PIXAudio2VoiceCallback; pSendList: PXAudio2VoiceSends;
      pEffectChain: PXAudio2EffectChain): HRESULT; stdcall;
    function CreateSubmixVoice(out ppSubmixVoice: PIXAudio2SubmixVoice;
      InputChannels, InputSampleRate, Flags, ProcessingStage: UINT32;
      pSendList: PXAudio2VoiceSends; pEffectChain: PXAudio2EffectChain): HRESULT; stdcall;
    function CreateMasteringVoice(out ppMasteringVoice: PIXAudio2MasteringVoice;
      InputChannels, InputSampleRate, Flags: UINT32; szDeviceId: PWideChar;
      pEffectChain: PXAudio2EffectChain; StreamCategory: Integer): HRESULT; stdcall;
    function StartEngine: HRESULT; stdcall;
    procedure StopEngine; stdcall;
    function CommitChanges(OperationSet: UINT32): HRESULT; stdcall;
    procedure GetPerformanceData(pPerfData: PXAudio2PerformanceData); stdcall;
    procedure SetDebugConfiguration(pDebugConfiguration: Pointer; pReserved: Pointer); stdcall;
  end;

/// <summary>Creates an XAudio2 2.9 engine. Loads xaudio2_9.dll from System32 only.
/// Returns a failure HRESULT (never raises) when XAudio2 is unavailable.</summary>
function CC_XAudio2Create(out Engine: IXAudio2; Flags: UINT32 = 0): HRESULT;

/// <summary>True when xaudio2_9.dll can be loaded on this system.</summary>
function CC_XAudio2Available: Boolean;

implementation

const
  LOAD_LIBRARY_SEARCH_SYSTEM32 = $00000800;

type
  TXAudio2CreateWithVersionInfo = function(out ppXAudio2: IXAudio2; Flags: UINT32;
    XAudio2Processor: UINT32; ntddiVersion: DWORD): HRESULT; stdcall;
  TXAudio2CreateFn = function(out ppXAudio2: IXAudio2; Flags: UINT32;
    XAudio2Processor: UINT32): HRESULT; stdcall;

var
  GLock: TRTLCriticalSection;
  GModule: HMODULE = 0;
  GCreateWithVersion: TXAudio2CreateWithVersionInfo = nil;
  GCreate: TXAudio2CreateFn = nil;
  GLoadAttempted: Boolean = False;

// The module is loaded once per process and intentionally never freed, matching
// the inline XAudio2Create helper in xaudio2.h. XAudio2 may keep internal worker
// threads alive briefly after the last Release, so unloading it is unsafe.
procedure EnsureLoaded;
begin
  EnterCriticalSection(GLock);
  try
    if GLoadAttempted then
      Exit;
    GLoadAttempted := True;
    GModule := LoadLibraryEx(XAUDIO2_DLL, 0, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if GModule = 0 then
      Exit;
    @GCreateWithVersion := GetProcAddress(GModule, 'XAudio2CreateWithVersionInfo');
    if not Assigned(GCreateWithVersion) then
      @GCreate := GetProcAddress(GModule, 'XAudio2Create');
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function CC_XAudio2Available: Boolean;
begin
  EnsureLoaded;
  Result := Assigned(GCreateWithVersion) or Assigned(GCreate);
end;

function CC_XAudio2Create(out Engine: IXAudio2; Flags: UINT32): HRESULT;
begin
  Engine := nil;
  EnsureLoaded;
  if Assigned(GCreateWithVersion) then
    Result := GCreateWithVersion(Engine, Flags, XAUDIO2_DEFAULT_PROCESSOR, CC_NTDDI_WIN10_RS5)
  else if Assigned(GCreate) then
    Result := GCreate(Engine, Flags, XAUDIO2_DEFAULT_PROCESSOR)
  else
    Result := HResultFromWin32(ERROR_MOD_NOT_FOUND);
  if Failed(Result) then
    Engine := nil;
end;

initialization
  InitializeCriticalSection(GLock);

finalization
  DeleteCriticalSection(GLock);

end.
