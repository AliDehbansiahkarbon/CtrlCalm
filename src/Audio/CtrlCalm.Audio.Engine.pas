unit CtrlCalm.Audio.Engine;

{
  The low-level XAudio2 mixer.

  Threading contract: every public method must be called from ONE thread (the
  Ctrl+Calm worker). XAudio2 calls the voice/engine callbacks on its own audio
  thread; those callbacks only set an atomic flag and signal WakeEvent, they
  never touch engine state.

  Signal flow:  source voice (one per sound, own format) -> mastering voice
  Track gain  = SliderToGain(volume) * envelope^2 * pause^2   (per source voice)
  Master gain = SliderToGain(master) * mute * duck * headroom
  The optional completion chime is a separate source voice at unity gain, so it
  is never louder than the master level allows and is silent while muted.
}

interface

uses
  Winapi.Windows, Winapi.ActiveX, Winapi.MMSystem, System.SysUtils, System.Classes, System.Math,
  CtrlCalm.Core.Types, CtrlCalm.Audio.XAudio2, CtrlCalm.Audio.Wav, CtrlCalm.Audio.Sources;

type
  TAudioEngine = class;

  /// <summary>A linear ramp with a per-millisecond rate.</summary>
  TRamp = record
    Value: Single;
    Target: Single;
    RatePerMs: Single;
    procedure Init(V: Single);
    procedure MoveTo(ATarget: Single; DurationMs: Integer);
    /// <summary>Returns True while the ramp is still moving.</summary>
    function Advance(ElapsedMs: Single): Boolean;
    function Moving: Boolean; inline;
  end;

  TEngineTrack = class
  private
    FEngine: TAudioEngine;
    FId: TSoundId;
    FSource: IAudioSource;
    FFormat: TAudioFormat;
    FVoice: PIXAudio2SourceVoice;
    FCallback: TIXAudio2VoiceCallback;
    FBuffers: array of TBytes;
    FBufferFrames: Integer;
    FNextBuffer: Integer;
    FVoiceStarted: Boolean;
    FWanted: Boolean;       // logically active
    FVolume: TRamp;         // slider domain 0..1
    FEnvelope: TRamp;       // fade envelope 0..1
    FAppliedGain: Single;
    FError: string;
    FLoadAttempted: Boolean;
    function EnsureSource: Boolean;
    procedure Probe;
    function EnsureVoice: Boolean;
    procedure DestroyVoice;
    procedure Refill;
    procedure StartVoice;
    procedure StopVoice;
    function Gain: Single;
  public
    constructor Create(AEngine: TAudioEngine; AId: TSoundId);
    destructor Destroy; override;
    function State: TTrackState;
    property Id: TSoundId read FId;
    property Error: string read FError;
  end;

  TEngineStats = record
    Status: TAudioStatus;
    StatusText: string;
    PlayingCount: Integer;
    Glitches: Cardinal;
    LatencySamples: Cardinal;
    BufferedBytes: Int64;
  end;

  TAudioEngine = class
  private
    FWakeEvent: THandle;
    FXAudio: IXAudio2;
    FMaster: PIXAudio2MasteringVoice;
    FEngineCallback: TIXAudio2EngineCallback;
    FEngineRunning: Boolean;
    FDeviceLost: Integer;      // set by the audio thread (atomic)
    FStatus: TAudioStatus;
    FStatusText: string;
    FTracks: array[TSoundId] of TEngineTrack;
    FSoundsFolder: string;
    FCrossfadeMs: Integer;
    FMasterVolume: TRamp;
    FMute: TRamp;
    FDuck: TRamp;
    FPause: TRamp;
    FPaused: Boolean;
    FHeadroom: Single;
    FAppliedMaster: Single;
    FLastTick: UInt64;
    FIdleSince: UInt64;
    FRetryAt: UInt64;
    FRetryDelayMs: Cardinal;
    FChimeData: TArray<Single>;
    FChimeVoice: PIXAudio2SourceVoice;
    FChimeUntil: UInt64;
    FSeedBase: UInt64;
    FDeviceDisabled: Boolean;
    function DeviceUp: Boolean; inline;
    function OpenDevice: Boolean;
    procedure CloseDevice;
    procedure HandleDeviceLoss;
    function AnyWanted: Boolean;
    procedure UpdateMasterGain;
    procedure ScheduleRetry(Now: UInt64);
    procedure EnsureEngineStarted;
    function DefaultFadeMs: Integer;
  public
    /// <summary>WakeEvent is owned by the caller and is signalled whenever the
    /// engine needs Process to run (buffer consumed, device lost).</summary>
    constructor Create(AWakeEvent: THandle; const ASoundsFolder: string);
    destructor Destroy; override;

    procedure Activate(Id: TSoundId; Volume: Single; FadeMs: Integer);
    procedure Deactivate(Id: TSoundId; FadeMs: Integer);
    procedure SetVolume(Id: TSoundId; Volume: Single; RampMs: Integer = 120);
    procedure SetMasterVolume(Volume: Single; RampMs: Integer = 120);
    procedure SetMuted(Muted: Boolean; RampMs: Integer = 250);
    procedure SetDucked(Ducked: Boolean; RampMs: Integer = 600);
    procedure SetPaused(Paused: Boolean; FadeMs: Integer);
    procedure StopAll(FadeMs: Integer);
    procedure PlayChime;
    /// <summary>Validates every recorded sound's file header without opening
    /// it for streaming, so missing or damaged files show as unavailable before
    /// the user clicks them. Cheap: reads only the RIFF chunk headers.</summary>
    procedure ProbeSources;
    /// <summary>Runs the engine without opening an output device (automated
    /// tests on machines without audio). Track and fade logic still runs.</summary>
    procedure DisableDevice;

    /// <summary>Advances ramps, refills streaming buffers, handles device loss
    /// and retries. Returns the number of ms until Process must run again
    /// (INFINITE when only buffer completion can create new work).</summary>
    function Process: Cardinal;

    /// <summary>Destroys all voices and the engine. Idempotent.</summary>
    procedure Shutdown;

    function TrackState(Id: TSoundId): TTrackState;
    function TrackError(Id: TSoundId): string;
    function Stats: TEngineStats;

    property Status: TAudioStatus read FStatus;
    property StatusText: string read FStatusText;
    property Paused: Boolean read FPaused;
    /// <summary>Current automatic master reduction (1 = none).</summary>
    property Headroom: Single read FHeadroom;
    property CrossfadeMs: Integer read FCrossfadeMs write FCrossfadeMs;
    property SeedBase: UInt64 read FSeedBase write FSeedBase;
  end;

const
  EngineBufferMs = 400;
  EngineBufferCount = 4;
  EngineTickMs = 15;
  /// <summary>Combined RMS-equivalent gain above which the master is reduced.</summary>
  HeadroomCeiling = 1.5;

implementation

{ Callbacks: run on the XAudio2 thread. Keep them trivial. }

procedure VC_OnVoiceProcessingPassStart(This: Pointer; BytesRequired: UINT32); stdcall;
begin
end;

procedure VC_OnVoiceProcessingPassEnd(This: Pointer); stdcall;
begin
end;

procedure VC_OnStreamEnd(This: Pointer); stdcall;
begin
end;

procedure VC_OnBufferStart(This: Pointer; pBufferContext: Pointer); stdcall;
begin
end;

procedure VC_OnBufferEnd(This: Pointer; pBufferContext: Pointer); stdcall;
begin
  SetEvent(THandle(PIXAudio2VoiceCallback(This)^.Context));
end;

procedure VC_OnLoopEnd(This: Pointer; pBufferContext: Pointer); stdcall;
begin
end;

procedure VC_OnVoiceError(This: Pointer; pBufferContext: Pointer; Error: HRESULT); stdcall;
begin
  SetEvent(THandle(PIXAudio2VoiceCallback(This)^.Context));
end;

procedure EC_OnProcessingPassStart(This: Pointer); stdcall;
begin
end;

procedure EC_OnProcessingPassEnd(This: Pointer); stdcall;
begin
end;

procedure EC_OnCriticalError(This: Pointer; Error: HRESULT); stdcall;
var
  Engine: TAudioEngine;
begin
  Engine := TAudioEngine(PIXAudio2EngineCallback(This)^.Context);
  AtomicExchange(Engine.FDeviceLost, 1);
  SetEvent(Engine.FWakeEvent);
end;

const
  VoiceCallbackVtbl: TIXAudio2VoiceCallbackVtbl = (
    OnVoiceProcessingPassStart: VC_OnVoiceProcessingPassStart;
    OnVoiceProcessingPassEnd: VC_OnVoiceProcessingPassEnd;
    OnStreamEnd: VC_OnStreamEnd;
    OnBufferStart: VC_OnBufferStart;
    OnBufferEnd: VC_OnBufferEnd;
    OnLoopEnd: VC_OnLoopEnd;
    OnVoiceError: VC_OnVoiceError);

  EngineCallbackVtbl: TIXAudio2EngineCallbackVtbl = (
    OnProcessingPassStart: EC_OnProcessingPassStart;
    OnProcessingPassEnd: EC_OnProcessingPassEnd;
    OnCriticalError: EC_OnCriticalError);

{ TRamp }

procedure TRamp.Init(V: Single);
begin
  Value := V;
  Target := V;
  RatePerMs := 0;
end;

procedure TRamp.MoveTo(ATarget: Single; DurationMs: Integer);
begin
  Target := ATarget;
  if DurationMs <= 0 then
  begin
    Value := ATarget;
    RatePerMs := 0;
  end
  else
    RatePerMs := Abs(Target - Value) / DurationMs;
end;

function TRamp.Advance(ElapsedMs: Single): Boolean;
var
  Step: Single;
begin
  if Value = Target then
    Exit(False);
  Step := RatePerMs * ElapsedMs;
  if (RatePerMs <= 0) or (Abs(Target - Value) <= Step) then
    Value := Target
  else if Target > Value then
    Value := Value + Step
  else
    Value := Value - Step;
  Result := Value <> Target;
end;

function TRamp.Moving: Boolean;
begin
  Result := Value <> Target;
end;

{ TEngineTrack }

constructor TEngineTrack.Create(AEngine: TAudioEngine; AId: TSoundId);
begin
  inherited Create;
  FEngine := AEngine;
  FId := AId;
  FVolume.Init(DefaultSoundVolume);
  FEnvelope.Init(0);
  FCallback.lpVtbl := @VoiceCallbackVtbl;
  FCallback.Context := Pointer(AEngine.FWakeEvent);
end;

destructor TEngineTrack.Destroy;
begin
  DestroyVoice;
  FSource := nil;
  inherited;
end;

function TEngineTrack.EnsureSource: Boolean;
var
  Def: TSoundDefinition;
  FileName: string;
begin
  if Assigned(FSource) then
    Exit(not FSource.Failed);
  if FLoadAttempted then
    Exit(False);
  FLoadAttempted := True;
  Def := SoundDef(FId);
  try
    if Def.Kind = skProcedural then
      FSource := TNoiseSource.Create(Def.Noise, FEngine.FSeedBase + UInt64(Ord(FId)) * 7919)
    else
    begin
      FileName := IncludeTrailingPathDelimiter(FEngine.FSoundsFolder) + Def.FileName;
      if not FileExists(FileName) then
      begin
        FError := 'Sound file not found: ' + Def.FileName;
        Exit(False);
      end;
      FSource := TLoopingWavSource.Create(FileName, FEngine.FCrossfadeMs);
    end;
    FFormat := FSource.Format;
    FError := '';
    Result := True;
  except
    on E: Exception do
    begin
      FSource := nil;
      FError := E.Message;
      Result := False;
    end;
  end;
end;

procedure TEngineTrack.Probe;
var
  Def: TSoundDefinition;
  FileName, Err: string;
  Info: TWavInfo;
begin
  if Assigned(FSource) or FLoadAttempted then
    Exit;
  Def := SoundDef(FId);
  if Def.Kind = skProcedural then
    Exit;
  FileName := IncludeTrailingPathDelimiter(FEngine.FSoundsFolder) + Def.FileName;
  if not FileExists(FileName) then
  begin
    FLoadAttempted := True;
    FError := 'Sound file not found: ' + Def.FileName;
  end
  else if not ParseWavFile(FileName, Info, Err) then
  begin
    FLoadAttempted := True;
    FError := Def.FileName + ': ' + Err;
  end;
end;

function TEngineTrack.EnsureVoice: Boolean;
var
  Fmt: TWaveFormatEx;
  Hr: HRESULT;
  I, Bytes: Integer;
begin
  if Assigned(FVoice) then
    Exit(True);
  Result := False;
  if not FEngine.DeviceUp or not EnsureSource then
    Exit;
  Fmt := FFormat.ToWaveFormatEx;
  Hr := FEngine.FXAudio.CreateSourceVoice(FVoice, @Fmt, 0, XAUDIO2_DEFAULT_FREQ_RATIO,
    @FCallback, nil, nil);
  if Failed(Hr) then
  begin
    FVoice := nil;
    FError := Format('Cannot create voice (0x%.8x)', [Cardinal(Hr)]);
    Exit;
  end;
  FBufferFrames := MulDiv(FFormat.SampleRate, EngineBufferMs, 1000);
  Bytes := FBufferFrames * FFormat.BlockAlign;
  if Length(FBuffers) <> EngineBufferCount then
    SetLength(FBuffers, EngineBufferCount);
  for I := 0 to EngineBufferCount - 1 do
    if Length(FBuffers[I]) <> Bytes then
      SetLength(FBuffers[I], Bytes);
  FNextBuffer := 0;
  FVoiceStarted := False;
  FAppliedGain := -1;
  FVoice.lpVtbl.Voice.SetVolume(FVoice, 0, XAUDIO2_COMMIT_NOW);
  FAppliedGain := 0;
  Refill;
  Result := True;
end;

procedure TEngineTrack.DestroyVoice;
begin
  if Assigned(FVoice) then
  begin
    // DestroyVoice blocks until the audio thread has stopped using the voice,
    // so the buffers below are no longer referenced once it returns.
    FVoice.lpVtbl.Stop(FVoice, 0, XAUDIO2_COMMIT_NOW);
    FVoice.lpVtbl.Voice.DestroyVoice(FVoice);
    FVoice := nil;
  end;
  FVoiceStarted := False;
  FNextBuffer := 0;
end;

procedure TEngineTrack.Refill;
var
  St: TXAudio2VoiceState;
  Buf: TXAudio2Buffer;
  Queued: Cardinal;
begin
  if not Assigned(FVoice) or not Assigned(FSource) then
    Exit;
  FVoice.lpVtbl.GetState(FVoice, @St, XAUDIO2_VOICE_NOSAMPLESPLAYED);
  Queued := St.BuffersQueued;
  // Buffers are consumed in FIFO order, so with Queued < N the next ring slot
  // is guaranteed to be free.
  while Queued < EngineBufferCount do
  begin
    FSource.Fill(@FBuffers[FNextBuffer][0], FBufferFrames);
    Buf := Default(TXAudio2Buffer);
    Buf.AudioBytes := Length(FBuffers[FNextBuffer]);
    Buf.pAudioData := @FBuffers[FNextBuffer][0];
    if Failed(FVoice.lpVtbl.SubmitSourceBuffer(FVoice, @Buf, nil)) then
      Break;
    FNextBuffer := (FNextBuffer + 1) mod EngineBufferCount;
    Inc(Queued);
  end;
  if FSource.Failed and (FError = '') then
    FError := FSource.ErrorMessage;
end;

procedure TEngineTrack.StartVoice;
begin
  if Assigned(FVoice) and not FVoiceStarted then
  begin
    FEngine.EnsureEngineStarted;
    if Succeeded(FVoice.lpVtbl.Start(FVoice, 0, XAUDIO2_COMMIT_NOW)) then
      FVoiceStarted := True;
  end;
end;

procedure TEngineTrack.StopVoice;
begin
  // Stop keeps queued buffers, so a later Start resumes seamlessly.
  if Assigned(FVoice) and FVoiceStarted then
  begin
    FVoice.lpVtbl.Stop(FVoice, 0, XAUDIO2_COMMIT_NOW);
    FVoiceStarted := False;
  end;
end;

function TEngineTrack.Gain: Single;
begin
  Result := SliderToGain(FVolume.Value) * Sqr(FEnvelope.Value) * Sqr(FEngine.FPause.Value);
end;

function TEngineTrack.State: TTrackState;
begin
  if FLoadAttempted and not Assigned(FSource) then
    Exit(tsUnavailable);
  if Assigned(FSource) and FSource.Failed then
    Exit(tsUnavailable);
  if FWanted then
  begin
    if FEnvelope.Value >= 1 then
      Result := tsPlaying
    else
      Result := tsStarting;
  end
  else if FEnvelope.Value > 0 then
    Result := tsStopping
  else
    Result := tsStopped;
end;

{ TAudioEngine }

constructor TAudioEngine.Create(AWakeEvent: THandle; const ASoundsFolder: string);
var
  S: TSoundId;
begin
  inherited Create;
  FWakeEvent := AWakeEvent;
  FSoundsFolder := ASoundsFolder;
  FCrossfadeMs := 1500;
  FSeedBase := UInt64(GetCurrentProcessId) shl 20 xor GetTickCount64;
  FEngineCallback.lpVtbl := @EngineCallbackVtbl;
  FEngineCallback.Context := Self;
  FMasterVolume.Init(DefaultMasterVolume);
  FMute.Init(1);
  FDuck.Init(1);
  FPause.Init(1);
  FHeadroom := 1;
  FAppliedMaster := -1;
  FStatus := asNotStarted;
  FStatusText := 'Audio idle';
  for S := Low(TSoundId) to High(TSoundId) do
    FTracks[S] := TEngineTrack.Create(Self, S);
  FChimeData := GenerateChime;
  FRetryDelayMs := 1000;
end;

destructor TAudioEngine.Destroy;
var
  S: TSoundId;
begin
  Shutdown;
  for S := Low(TSoundId) to High(TSoundId) do
    FreeAndNil(FTracks[S]);
  inherited;
end;

function TAudioEngine.DeviceUp: Boolean;
begin
  Result := Assigned(FXAudio) and Assigned(FMaster);
end;

function TAudioEngine.DefaultFadeMs: Integer;
begin
  Result := 1000;
end;

function TAudioEngine.OpenDevice: Boolean;
var
  Hr: HRESULT;
begin
  if DeviceUp then
    Exit(True);
  Result := False;
  if (FStatus = asShutDown) or FDeviceDisabled then
    Exit;
  if not CC_XAudio2Available then
  begin
    FStatus := asUnavailable;
    FStatusText := 'XAudio2 2.9 is not available on this system';
    Exit;
  end;
  Hr := CC_XAudio2Create(FXAudio, 0);
  if Failed(Hr) then
  begin
    FXAudio := nil;
    FStatus := asNoDevice;
    FStatusText := Format('Audio engine unavailable (0x%.8x)', [Cardinal(Hr)]);
    Exit;
  end;
  FXAudio.RegisterForCallbacks(@FEngineCallback);
  Hr := FXAudio.CreateMasteringVoice(FMaster, XAUDIO2_DEFAULT_CHANNELS,
    XAUDIO2_DEFAULT_SAMPLERATE, 0, nil, nil, AudioCategory_Media);
  if Failed(Hr) then
    Hr := FXAudio.CreateMasteringVoice(FMaster, XAUDIO2_DEFAULT_CHANNELS,
      XAUDIO2_DEFAULT_SAMPLERATE, 0, nil, nil, AudioCategory_Other);
  if Failed(Hr) then
  begin
    FMaster := nil;
    FXAudio.UnregisterForCallbacks(@FEngineCallback);
    FXAudio := nil;
    FStatus := asNoDevice;
    FStatusText := 'No audio output device';
    Exit;
  end;
  AtomicExchange(FDeviceLost, 0);
  FEngineRunning := True; // XAudio2Create starts the engine
  FAppliedMaster := -1;
  FStatus := asReady;
  FStatusText := 'Audio ready';
  FRetryDelayMs := 1000;
  UpdateMasterGain;
  Result := True;
end;

procedure TAudioEngine.CloseDevice;
var
  S: TSoundId;
begin
  // Order: source voices -> mastering voice -> engine.
  for S := Low(TSoundId) to High(TSoundId) do
    if Assigned(FTracks[S]) then
      FTracks[S].DestroyVoice;
  if Assigned(FChimeVoice) then
  begin
    FChimeVoice.lpVtbl.Stop(FChimeVoice, 0, XAUDIO2_COMMIT_NOW);
    FChimeVoice.lpVtbl.Voice.DestroyVoice(FChimeVoice);
    FChimeVoice := nil;
  end;
  if Assigned(FMaster) then
  begin
    FMaster.lpVtbl.Voice.DestroyVoice(FMaster);
    FMaster := nil;
  end;
  if Assigned(FXAudio) then
  begin
    FXAudio.StopEngine;
    FXAudio.UnregisterForCallbacks(@FEngineCallback);
    FXAudio := nil; // final Release; joins XAudio2's internal threads
  end;
  FEngineRunning := False;
end;

procedure TAudioEngine.HandleDeviceLoss;
begin
  CloseDevice;
  FStatus := asRecovering;
  FStatusText := 'Audio device lost - reconnecting';
  ScheduleRetry(GetTickCount64);
end;

procedure TAudioEngine.ScheduleRetry(Now: UInt64);
begin
  FRetryAt := Now + FRetryDelayMs;
  FRetryDelayMs := Min(FRetryDelayMs * 2, 5000);
end;

procedure TAudioEngine.EnsureEngineStarted;
begin
  if DeviceUp and not FEngineRunning then
    if Succeeded(FXAudio.StartEngine) then
      FEngineRunning := True;
end;

function TAudioEngine.AnyWanted: Boolean;
var
  S: TSoundId;
begin
  for S := Low(TSoundId) to High(TSoundId) do
    if FTracks[S].FWanted and not FPaused then
      Exit(True);
  Result := False;
end;

procedure TAudioEngine.Activate(Id: TSoundId; Volume: Single; FadeMs: Integer);
var
  T: TEngineTrack;
begin
  T := FTracks[Id];
  T.FVolume.MoveTo(ClampVolume(Volume), 0);
  if not T.EnsureSource then
  begin
    T.FWanted := False;
    Exit;
  end;
  T.FWanted := True;
  T.FEnvelope.MoveTo(1, FadeMs);
  if not FPaused then
  begin
    if not DeviceUp and (FStatus <> asRecovering) then
      if not OpenDevice then
        ScheduleRetry(GetTickCount64);
    if T.EnsureVoice then
      T.StartVoice;
  end;
end;

procedure TAudioEngine.Deactivate(Id: TSoundId; FadeMs: Integer);
var
  T: TEngineTrack;
begin
  T := FTracks[Id];
  T.FWanted := False;
  T.FEnvelope.MoveTo(0, FadeMs);
end;

procedure TAudioEngine.SetVolume(Id: TSoundId; Volume: Single; RampMs: Integer);
begin
  FTracks[Id].FVolume.MoveTo(ClampVolume(Volume), RampMs);
end;

procedure TAudioEngine.SetMasterVolume(Volume: Single; RampMs: Integer);
begin
  FMasterVolume.MoveTo(ClampVolume(Volume), RampMs);
end;

procedure TAudioEngine.SetMuted(Muted: Boolean; RampMs: Integer);
begin
  FMute.MoveTo(IfThen(Muted, 0, 1), RampMs);
end;

procedure TAudioEngine.SetDucked(Ducked: Boolean; RampMs: Integer);
begin
  FDuck.MoveTo(IfThen(Ducked, 0, 1), RampMs);
end;

procedure TAudioEngine.SetPaused(Paused: Boolean; FadeMs: Integer);
var
  S: TSoundId;
begin
  if Paused = FPaused then
    Exit;
  FPaused := Paused;
  if Paused then
    FPause.MoveTo(0, FadeMs)
  else
  begin
    FPause.MoveTo(1, FadeMs);
    if AnyWanted and not DeviceUp and (FStatus <> asRecovering) then
      OpenDevice;
    for S := Low(TSoundId) to High(TSoundId) do
      if FTracks[S].FWanted or (FTracks[S].FEnvelope.Value > 0) then
        if FTracks[S].EnsureVoice then
          FTracks[S].StartVoice;
  end;
end;

procedure TAudioEngine.StopAll(FadeMs: Integer);
var
  S: TSoundId;
begin
  for S := Low(TSoundId) to High(TSoundId) do
    Deactivate(S, FadeMs);
end;

procedure TAudioEngine.ProbeSources;
var
  S: TSoundId;
begin
  for S := Low(TSoundId) to High(TSoundId) do
    FTracks[S].Probe;
end;

procedure TAudioEngine.DisableDevice;
begin
  CloseDevice;
  FDeviceDisabled := True;
  FStatus := asUnavailable;
  FStatusText := 'Audio output disabled';
end;

procedure TAudioEngine.PlayChime;
var
  Fmt: TWaveFormatEx;
  Buf: TXAudio2Buffer;
begin
  if not DeviceUp and not OpenDevice then
    Exit;
  if not Assigned(FChimeVoice) then
  begin
    Fmt := Default(TWaveFormatEx);
    Fmt.wFormatTag := WAVE_FORMAT_IEEE_FLOAT;
    Fmt.nChannels := 1;
    Fmt.nSamplesPerSec := 48000;
    Fmt.wBitsPerSample := 32;
    Fmt.nBlockAlign := 4;
    Fmt.nAvgBytesPerSec := 48000 * 4;
    if Failed(FXAudio.CreateSourceVoice(FChimeVoice, @Fmt, 0, XAUDIO2_DEFAULT_FREQ_RATIO,
      nil, nil, nil)) then
    begin
      FChimeVoice := nil;
      Exit;
    end;
  end;
  FChimeVoice.lpVtbl.Stop(FChimeVoice, 0, XAUDIO2_COMMIT_NOW);
  FChimeVoice.lpVtbl.FlushSourceBuffers(FChimeVoice);
  Buf := Default(TXAudio2Buffer);
  Buf.Flags := XAUDIO2_END_OF_STREAM;
  Buf.AudioBytes := Length(FChimeData) * SizeOf(Single);
  Buf.pAudioData := @FChimeData[0];
  if Succeeded(FChimeVoice.lpVtbl.SubmitSourceBuffer(FChimeVoice, @Buf, nil)) then
  begin
    EnsureEngineStarted;
    FChimeVoice.lpVtbl.Start(FChimeVoice, 0, XAUDIO2_COMMIT_NOW);
    FChimeUntil := GetTickCount64 + 2000;
  end;
end;

procedure TAudioEngine.UpdateMasterGain;
var
  S: TSoundId;
  SumSq, G, P: Double;
begin
  // Uncorrelated ambient tracks add in power. Reduce the master smoothly once the
  // combined gain passes HeadroomCeiling so that enabling many sounds cannot
  // drive the mix into clipping.
  SumSq := 0;
  for S := Low(TSoundId) to High(TSoundId) do
  begin
    G := FTracks[S].Gain;
    SumSq := SumSq + G * G;
  end;
  P := Sqrt(SumSq);
  if P > HeadroomCeiling then
    FHeadroom := HeadroomCeiling / P
  else
    FHeadroom := 1;
  if not DeviceUp then
    Exit;
  G := SliderToGain(FMasterVolume.Value) * FMute.Value * FDuck.Value * FHeadroom;
  if Abs(G - FAppliedMaster) > 1E-5 then
  begin
    FMaster.lpVtbl.Voice.SetVolume(FMaster, G, XAUDIO2_COMMIT_NOW);
    FAppliedMaster := G;
  end;
end;

function TAudioEngine.Process: Cardinal;
var
  Now: UInt64;
  Elapsed: Single;
  S: TSoundId;
  T: TEngineTrack;
  Moving: Boolean;
  G: Single;
  AnyStarted: Boolean;
begin
  Result := INFINITE;
  if FStatus = asShutDown then
    Exit;
  Now := GetTickCount64;
  if FLastTick = 0 then
    FLastTick := Now;
  Elapsed := Min(Now - FLastTick, 250);
  FLastTick := Now;

  if AtomicCmpExchange(FDeviceLost, 0, 0) <> 0 then
    HandleDeviceLoss;

  if not DeviceUp and AnyWanted and (Now >= FRetryAt) and (FStatus in [asRecovering, asNoDevice]) then
  begin
    if OpenDevice then
    begin
      for S := Low(TSoundId) to High(TSoundId) do
        if FTracks[S].FWanted then
        begin
          FTracks[S].FEnvelope.Value := 0; // fade back in after recovery
          FTracks[S].FEnvelope.MoveTo(1, DefaultFadeMs);
          if FTracks[S].EnsureVoice then
            FTracks[S].StartVoice;
        end;
    end
    else
      ScheduleRetry(Now);
  end;

  Moving := FMasterVolume.Advance(Elapsed);
  Moving := FMute.Advance(Elapsed) or Moving;
  Moving := FDuck.Advance(Elapsed) or Moving;
  Moving := FPause.Advance(Elapsed) or Moving;

  AnyStarted := False;
  for S := Low(TSoundId) to High(TSoundId) do
  begin
    T := FTracks[S];
    Moving := T.FVolume.Advance(Elapsed) or Moving;
    Moving := T.FEnvelope.Advance(Elapsed) or Moving;
    if not Assigned(T.FVoice) then
      Continue;
    G := T.Gain;
    if Abs(G - T.FAppliedGain) > 1E-5 then
    begin
      T.FVoice.lpVtbl.Voice.SetVolume(T.FVoice, G, XAUDIO2_COMMIT_NOW);
      T.FAppliedGain := G;
    end;
    // A finished fade-out (or a completed global pause) stops the voice; its
    // queued buffers stay valid so a later start resumes without a gap.
    if (not T.FWanted and (T.FEnvelope.Value <= 0)) or (FPaused and (FPause.Value <= 0)) then
      T.StopVoice;
    if T.FVoiceStarted then
    begin
      AnyStarted := True;
      T.Refill;
    end;
  end;
  UpdateMasterGain;

  // Stop the XAudio2 engine thread when nothing has played for a while.
  if AnyStarted or (Now < FChimeUntil) then
    FIdleSince := 0
  else if FEngineRunning then
  begin
    if FIdleSince = 0 then
      FIdleSince := Now
    else if Now - FIdleSince > 3000 then
    begin
      FXAudio.StopEngine;
      FEngineRunning := False;
    end;
  end;

  if Moving then
    Result := EngineTickMs
  else if FEngineRunning and not AnyStarted then
    Result := 1000; // idle countdown to engine stop
  if not DeviceUp and AnyWanted and (FStatus in [asRecovering, asNoDevice]) then
  begin
    if FRetryAt > Now then
      Result := Min(Result, Cardinal(FRetryAt - Now))
    else
      Result := Min(Result, Cardinal(EngineTickMs));
  end;
end;

procedure TAudioEngine.Shutdown;
begin
  if FStatus = asShutDown then
    Exit;
  CloseDevice;
  FStatus := asShutDown;
  FStatusText := 'Audio stopped';
end;

function TAudioEngine.TrackState(Id: TSoundId): TTrackState;
begin
  Result := FTracks[Id].State;
end;

function TAudioEngine.TrackError(Id: TSoundId): string;
begin
  Result := FTracks[Id].Error;
end;

function TAudioEngine.Stats: TEngineStats;
var
  Perf: TXAudio2PerformanceData;
  S: TSoundId;
begin
  Result := Default(TEngineStats);
  Result.Status := FStatus;
  Result.StatusText := FStatusText;
  for S := Low(TSoundId) to High(TSoundId) do
  begin
    if FTracks[S].FVoiceStarted then
      Inc(Result.PlayingCount);
    if Assigned(FTracks[S].FVoice) then
      Inc(Result.BufferedBytes, Int64(EngineBufferCount) * Length(FTracks[S].FBuffers[0]));
  end;
  if DeviceUp then
  begin
    Perf := Default(TXAudio2PerformanceData);
    FXAudio.GetPerformanceData(@Perf);
    Result.Glitches := Perf.GlitchesSinceEngineStarted;
    Result.LatencySamples := Perf.CurrentLatencyInSamples;
  end;
end;

end.
